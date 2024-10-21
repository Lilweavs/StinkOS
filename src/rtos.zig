const std = @import("std");

pub inline fn enableInterrupts() void {
    asm volatile ("cpsie i" ::: "memory");
}

pub inline fn disableInterrupts() void {
    asm volatile ("cpsid i" ::: "memory");
}

// Thread Control Block (TCB)
const SCB_SHPR3: *volatile u32 = @as(*volatile u32, @ptrFromInt(0xE000ED20));
const SCB_ICSR: *volatile u32 = @as(*volatile u32, @ptrFromInt(0xE000ED04));

pub fn init() void {
    SCB_SHPR3.* |= 0x00FF00000;
    idle_stack[idle_stack.len - 1] = (1 << 24);
    idle_stack[idle_stack.len - 2] = @intFromPtr(@as(ThreadHandler, mainIdle));
    idle_thread.stack_ptr = @intFromPtr(&idle_stack[idle_stack.len - 16]);
}

pub const ThreadHandler = *const fn () void;

export var curr_thread: ?*volatile Thread = null;
export var next_thread: *volatile Thread = undefined;

var thread_queue = ThreadQueue{};

var idle_stack: [40]u32 = undefined;
var idle_thread = Thread{
    .stack = &idle_stack,
    .stack_ptr = 0,
};

pub const Thread = struct {
    const Self = @This();
    stack: []u32 = undefined,
    stack_ptr: u32 = undefined,
    timeout: u32 = 0,

    pub fn start(self: *Self) void {
        disableInterrupts();
        thread_queue.startThread(self);
        enableInterrupts();
    }

    pub fn stop(self: *Self) void {
        disableInterrupts();
        thread_queue.stopThread(self);
        enableInterrupts();
    }
};

const ThreadQueue = struct {
    const Self = @This();
    threads: [8]*Thread = undefined,
    size: u32 = 0,
    index: u32 = 0,
    num_active: u32 = 0,
    thread_state: u32 = 0,

    pub fn addThreadToQueue(self: *Self, thread: *Thread) void {
        self.threads[self.size] = thread;
        self.size += 1;
    }

    pub fn sleepCurrentThread(self: *Self) void {
        self.sleepThread(self.index);
    }

    pub fn startThread(self: *Self, thread_to_start: *Thread) void {
        for (self.threads, 0..) |thread, i| {
            if (thread == thread_to_start) {
                thread_to_start.timeout = 0;
                self.enableThread(i);
                return;
            }
        }
    }

    pub fn stopThread(self: *Self, thread_to_stop: *Thread) void {
        for (self.threads, 0..) |thread, i| {
            if (thread == thread_to_stop) {
                self.disableThread(i);
                return;
            }
        }
    }

    pub fn getNextThread(self: *Self) *Thread {
        if (self.thread_state == 0) return &idle_thread;

        while ((self.thread_state & (@as(u32, 1) << @as(u5, @intCast(self.index)))) == 0) {
            self.index = @mod(self.index + 1, self.num_active);
        }

        return self.threads[self.index];
    }

    inline fn wakeThread(self: *Self, index: u32) void {
        self.thread_state |= (@as(u32, 1) << @as(u5, @intCast(index)));
    }

    inline fn sleepThread(self: *Self, index: u32) void {
        self.thread_state &= ~(@as(u32, 1) << @as(u5, @intCast(index)));
    }

    fn enableThread(self: *Self, index: u32) void {
        self.wakeThread(index);
        self.num_active += 1;
    }

    fn disableThread(self: *Self, index: u32) void {
        if (self.size == 0) return;

        self.sleepThread(index);

        if (self.num_active > 1) {
            std.mem.swap(*Thread, &self.threads[index], &self.threads[self.num_active - 1]);

            if ((self.thread_state & (@as(u32, 1) << @intCast(self.num_active - 1))) != 0) {
                self.thread_state |= (@as(u32, 1) << @intCast(self.index));
            }

            self.index = index;
        }
        self.num_active -= 1;
    }
};

pub fn rtosTick() void {
    for (0..thread_queue.num_active) |i| {
        if (thread_queue.threads[i].timeout == 0) continue;
        thread_queue.threads[i].timeout -= 1;
        if (thread_queue.threads[i].timeout == 0) {
            thread_queue.thread_state |= (@as(u32, 1) << @as(u5, @intCast(i)));
        }
    }
}

pub fn schedule() void {
    next_thread = thread_queue.getNextThread();

    if (curr_thread == null or next_thread != curr_thread) {
        SCB_ICSR.* |= (1 << 28);
    }
}

pub fn sleep(ms: u32) void {
    disableInterrupts();
    curr_thread.?.timeout = ms;
    thread_queue.sleepCurrentThread();
    schedule();
    enableInterrupts();
}

fn mainIdle() void {
    while (true) {
        asm volatile ("nop");
    }
}

pub fn threadInitAndStart(thread_handler: ThreadHandler, thread: *Thread, stack: []u32) void {
    threadInit(thread_handler, thread, stack);
    thread.start();
}

pub fn threadInit(thread_handler: ThreadHandler, thread: *Thread, stack: []u32) void {
    stack.ptr[stack.len - 1] = 0x1 << 24; // xPSR
    stack.ptr[stack.len - 2] = @intFromPtr(thread_handler); //PC
    stack.ptr[stack.len - 3] = 0x0000000E; // LR
    stack.ptr[stack.len - 4] = 0x0000000C; // R12
    stack.ptr[stack.len - 5] = 0x00000003; // R3
    stack.ptr[stack.len - 6] = 0x00000002; // R2
    stack.ptr[stack.len - 7] = 0x00000001; // R1
    stack.ptr[stack.len - 8] = 0x00000000; // R0
    stack.ptr[stack.len - 9] = 0x0000000B; // R11
    stack.ptr[stack.len - 10] = 0x0000000A; // R10
    stack.ptr[stack.len - 11] = 0x00000009; // R9
    stack.ptr[stack.len - 12] = 0x00000008; // R8
    stack.ptr[stack.len - 13] = 0x00000007; // R7
    stack.ptr[stack.len - 14] = 0x00000006; // R6
    stack.ptr[stack.len - 15] = 0x00000005; // R5
    stack.ptr[stack.len - 16] = 0x00000004; // R4

    for (17..stack.len) |i| {
        stack.ptr[stack.len - i] = 0xDEADBEEF;
    }

    thread.stack_ptr = @intFromPtr(&stack.ptr[stack.len - 16]);
    thread_queue.addThreadToQueue(thread);
}

export fn PendSV_Handler() void {
    asm volatile (
        \\    CPSID   I
        \\    LDR     R1,=curr_thread
        \\    LDR     R1,[R1]
        \\    CMP.W   R1,#0
        \\    BEQ.N   SwitchThread
        \\    PUSH    {R4-R11}
        \\    STR     SP,[R1,#0x08]
        \\  SwitchThreadStack:
        \\    LDR     R3,=next_thread
        \\    LDR     R3,[R3]
        \\    LDR     SP,[R3,#0x08]
    );

    curr_thread = next_thread;

    asm volatile (
        \\    POP     {R4-R11}
        \\    CPSIE   I
        \\    BX      LR
    );
}
