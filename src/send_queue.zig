const std = @import("std");
const Allocator = std.mem.Allocator;
const mpscQueue = @import("queues/mpsc_queue.zig").mpscQueue;

pub const Entry = struct {
    conn_id: u64,
    data: []const u8,

    pub fn free(self: *Entry, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

pub const send_queue = mpscQueue(Entry);
