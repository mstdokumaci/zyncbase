const memory_strategy = @import("../memory/strategy.zig");
const mpscQueue = @import("../queues/mpsc_queue.zig").mpscQueue;

const ArenaHandle = memory_strategy.ArenaHandle;

pub const Delivery = struct {
    conn_id: u64,
    data: []const u8,
};

pub const Entry = struct {
    conn_id: u64,
    data: []const u8,
    arena: ArenaHandle,
    /// Non-null for a batched subscription-fanout entry. The `data` slices in
    /// `items` point into the same arena and use the same lifetime as `data`.
    items: ?[]const Delivery = null,

    pub fn deinit(self: *const Entry) void {
        self.arena.release();
    }

    /// The queue allocates its node from this owner, so the arena must
    /// outlive the entry — the caller holds a reference across the push.
    pub fn owner(self: Entry) ArenaHandle {
        return self.arena;
    }
};

pub const send_queue = mpscQueue(Entry, ArenaHandle);
