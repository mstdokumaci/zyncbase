const mpscQueue = @import("queues/mpsc_queue.zig").mpscQueue;
const memory_strategy = @import("memory_strategy.zig");
const ArenaHandle = memory_strategy.ArenaHandle;

pub const Entry = struct {
    conn_id: u64,
    data: []const u8,
    arena: ArenaHandle,

    pub fn deinit(self: *const Entry) void {
        self.arena.release();
    }
};

pub const send_queue = mpscQueue(Entry, memory_strategy.MemoryStrategy.IndexPool);
