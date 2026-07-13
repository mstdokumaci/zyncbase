const std = @import("std");
const testing = std.testing;
const mpscQueue = @import("mpsc_queue.zig").mpscQueue;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;

const TestEntry = struct {
    id: u64,
    msg: []const u8,

    pub fn free(self: *TestEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.msg);
    }
};

const AllocPool = MemoryStrategy.AllocPool;
const queue_type = mpscQueue(TestEntry, AllocPool);
const PoolType = AllocPool(queue_type.Node);

test "MpscQueue: multiple producers single consumer" {
    const alloc = testing.allocator;
    var pool = PoolType.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    const thread_count = 4;
    const items_per_thread = 1000;
    const total_items = thread_count * items_per_thread;

    const ProducerContext = struct {
        q: *queue_type,
        allocator: std.mem.Allocator,
        thread_id: u64,
        count: usize,
    };

    var threads = try alloc.alloc(std.Thread, thread_count);
    defer alloc.free(threads);
    var contexts = try alloc.alloc(*ProducerContext, thread_count);
    defer alloc.free(contexts);

    const producer = struct {
        fn run(ctx: *ProducerContext) !void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                var buf: [32]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "msg-{}-{}", .{ ctx.thread_id, i }) catch return error.TestFailed;
                try ctx.q.push(.{ .id = ctx.thread_id * 10000 + i, .msg = try ctx.allocator.dupe(u8, msg) });
            }
        }
    }.run;

    for (0..thread_count) |i| {
        const ctx = try alloc.create(ProducerContext);
        ctx.* = .{ .q = &q, .allocator = alloc, .thread_id = @intCast(i), .count = items_per_thread };
        contexts[i] = ctx;
        threads[i] = try std.Thread.spawn(.{}, producer, .{ctx});
    }

    for (0..thread_count) |i| {
        threads[i].join();
        alloc.destroy(contexts[i]);
    }

    var received: usize = 0;
    while (q.pop()) |entry| {
        alloc.free(entry.msg);
        received += 1;
    }

    try testing.expectEqual(total_items, received);
}

test "MpscQueue: concurrent push and pop stress" {
    const alloc = testing.allocator;
    var pool = PoolType.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    const producer_count = 3;
    const items_per_producer = 500;

    const ProducerContext = struct {
        q: *queue_type,
        allocator: std.mem.Allocator,
        count: usize,
    };

    var threads = try alloc.alloc(std.Thread, producer_count + 1);
    defer alloc.free(threads);
    var producer_contexts = try alloc.alloc(*ProducerContext, producer_count);
    defer alloc.free(producer_contexts);

    const producer = struct {
        fn run(ctx: *ProducerContext) !void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                try ctx.q.push(.{ .id = i, .msg = try ctx.allocator.dupe(u8, "stress") });
            }
        }
    }.run;

    const ConsumerContext = struct {
        q: *queue_type,
        alloc: std.mem.Allocator,
        consumed: std.atomic.Value(usize),
        total_expected: usize,
    };

    const consumer = struct {
        fn run(ctx: *ConsumerContext) void {
            while (ctx.consumed.load(.acquire) < ctx.total_expected) {
                if (ctx.q.pop()) |entry| {
                    ctx.alloc.free(entry.msg);
                    _ = ctx.consumed.fetchAdd(1, .acq_rel);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            while (ctx.q.pop()) |entry| {
                ctx.alloc.free(entry.msg);
                _ = ctx.consumed.fetchAdd(1, .acq_rel);
            }
        }
    }.run;

    for (0..producer_count) |i| {
        const ctx = try alloc.create(ProducerContext);
        ctx.* = .{ .q = &q, .allocator = alloc, .count = items_per_producer };
        producer_contexts[i] = ctx;
        threads[i] = try std.Thread.spawn(.{}, producer, .{ctx});
    }

    var consumer_ctx = try alloc.create(ConsumerContext);
    consumer_ctx.* = .{
        .q = &q,
        .alloc = alloc,
        .consumed = std.atomic.Value(usize).init(0),
        .total_expected = producer_count * items_per_producer,
    };
    threads[producer_count] = try std.Thread.spawn(.{}, consumer, .{consumer_ctx});

    for (0..producer_count + 1) |i| {
        threads[i].join();
    }
    const final_consumed = consumer_ctx.consumed.load(.acquire);
    for (producer_contexts) |ctx| alloc.destroy(ctx);
    alloc.destroy(consumer_ctx);

    try testing.expectEqual(producer_count * items_per_producer, final_consumed);
}

test "MpscQueue: push during drain" {
    const alloc = testing.allocator;
    var pool = PoolType.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    try q.push(.{ .id = 1, .msg = try alloc.dupe(u8, "initial1") });
    try q.push(.{ .id = 2, .msg = try alloc.dupe(u8, "initial2") });

    const drained_first = q.pop() orelse return error.TestFailed;
    alloc.free(drained_first.msg);

    try q.push(.{ .id = 3, .msg = try alloc.dupe(u8, "during_drain") });
    try q.push(.{ .id = 4, .msg = try alloc.dupe(u8, "after_push") });

    var count: usize = 0;
    while (q.pop()) |entry| {
        alloc.free(entry.msg);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}
