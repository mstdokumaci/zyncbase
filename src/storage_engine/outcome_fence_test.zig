const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const SendQueueType = @import("../connection/send_queue.zig").SendQueue;
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const Notifier = @import("../threading/notifier.zig").Notifier;
const OutcomeFence = @import("outcome_fence.zig").OutcomeFence;

const testing = std.testing;

const Harness = struct {
    ms: MemoryStrategy,
    send_queue: SendQueueType,
    notified: std.atomic.Value(u32),

    fn init(self: *Harness) !void {
        try self.ms.init();
        errdefer self.ms.deinit();
        self.send_queue = try SendQueueType.init(self.ms.generalAllocator());
        self.notified = .init(0);
    }

    fn deinit(self: *Harness) void {
        while (self.send_queue.popFrom(0)) |entry| entry.deinit();
        self.send_queue.deinit();
        self.ms.deinit();
    }

    fn create(self: *Harness) !*OutcomeFence {
        return OutcomeFence.create(&self.ms, &self.send_queue, Notifier.init(notify, &self.notified));
    }

    fn notify(ctx: ?*anyopaque) void {
        const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
        _ = counter.fetchAdd(1, .monotonic);
    }

    /// Pops every queued outcome into `out` as its request id and releases it.
    fn drainIds(self: *Harness, out: []u64) !usize {
        var n: usize = 0;
        while (self.send_queue.popFrom(0)) |entry| {
            defer entry.deinit();
            var reader: std.Io.Reader = .fixed(entry.data);
            const outcome = try msgpack.decode(testing.allocator, &reader);
            defer outcome.free(testing.allocator);
            const id = (try outcome.mapGet("id")) orelse return error.MissingId;
            try testing.expectEqual(@as(u64, 7), entry.conn_id);
            out[n] = id.uint;
            n += 1;
        }
        return n;
    }
};

test "OutcomeFence: publishes in add order once the last reference drops" {
    var h: Harness = undefined;
    try h.init();
    // MemoryStrategy.deinit asserts the fence arena went back to the pool.
    defer h.deinit();

    const fence = try h.create();
    fence.add(.{ .conn_id = 7, .msg_id = 3 }, null, null);
    fence.add(.{ .conn_id = 7, .msg_id = 1 }, error.PermissionDenied, 0);
    fence.add(.{ .conn_id = 7, .msg_id = 2 }, null, null);
    fence.retain(); // two change jobs
    fence.retain();

    fence.release(); // writer
    fence.release();
    try testing.expect(!h.send_queue.hasItems());
    try testing.expectEqual(@as(u32, 0), h.notified.load(.monotonic));

    fence.release(); // last job
    try testing.expectEqual(@as(u32, 1), h.notified.load(.monotonic));
    var ids: [3]u64 = undefined;
    try testing.expectEqual(@as(usize, 3), try h.drainIds(&ids));
    try testing.expectEqualSlices(u64, &.{ 3, 1, 2 }, &ids);
}

test "OutcomeFence: concurrent releases publish exactly once" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    const job_count = 8;
    for (0..100) |_| {
        const fence = try h.create();
        fence.add(.{ .conn_id = 7, .msg_id = 1 }, null, null);
        for (0..job_count) |_| fence.retain();

        var threads: [job_count]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, OutcomeFence.release, .{fence});
        fence.release();
        for (threads) |t| t.join();

        var ids: [2]u64 = undefined;
        try testing.expectEqual(@as(usize, 1), try h.drainIds(&ids));
    }
    try testing.expectEqual(@as(u32, 100), h.notified.load(.monotonic));
}
