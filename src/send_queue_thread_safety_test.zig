const std = @import("std");
const testing = std.testing;
const SendQueue = @import("send_queue.zig").SendQueue;
const Allocator = std.mem.Allocator;

test "SendQueue: multiple producers single consumer" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    const thread_count = 4;
    const items_per_thread = 1000;
    const total_items = thread_count * items_per_thread;

    const ProducerContext = struct {
        sq: *SendQueue,
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
                const conn_id = ctx.thread_id * 10000 + i;
                var buf: [32]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "msg-{}-{}", .{ ctx.thread_id, i }) catch return error.TestFailed;
                try ctx.sq.push(conn_id, msg);
            }
        }
    }.run;

    for (0..thread_count) |i| {
        const ctx = try alloc.create(ProducerContext);
        ctx.* = .{
            .sq = &sq,
            .thread_id = @intCast(i),
            .count = items_per_thread,
        };
        contexts[i] = ctx;
        threads[i] = try std.Thread.spawn(.{}, producer, .{ctx});
    }

    for (0..thread_count) |i| {
        threads[i].join();
        alloc.destroy(contexts[i]);
    }

    var received: usize = 0;
    while (sq.pop()) |entry| {
        alloc.free(entry.data);
        received += 1;
    }

    try testing.expectEqual(total_items, received);
}

test "SendQueue: concurrent push and pop stress" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    const producer_count = 3;
    const items_per_producer = 500;

    const ProducerContext = struct {
        sq: *SendQueue,
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
                try ctx.sq.push(i, "stress");
            }
        }
    }.run;

    const ConsumerContext = struct {
        sq: *SendQueue,
        alloc: Allocator,
        consumed: std.atomic.Value(usize),
        total_expected: usize,
    };

    const consumer = struct {
        fn run(ctx: *ConsumerContext) void {
            while (ctx.consumed.load(.acquire) < ctx.total_expected) {
                while (ctx.sq.pop()) |entry| {
                    ctx.alloc.free(entry.data);
                    _ = ctx.consumed.fetchAdd(1, .acq_rel);
                }
            }
            while (ctx.sq.pop()) |entry| {
                ctx.alloc.free(entry.data);
                _ = ctx.consumed.fetchAdd(1, .acq_rel);
            }
        }
    }.run;

    for (0..producer_count) |i| {
        const ctx = try alloc.create(ProducerContext);
        ctx.* = .{ .sq = &sq, .count = items_per_producer };
        producer_contexts[i] = ctx;
        threads[i] = try std.Thread.spawn(.{}, producer, .{ctx});
    }

    var consumer_ctx = try alloc.create(ConsumerContext);
    consumer_ctx.* = .{
        .sq = &sq,
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

test "SendQueue: push during drain" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    try sq.push(1, "initial1");
    try sq.push(2, "initial2");

    const drained_first = sq.pop() orelse return error.TestFailed;
    alloc.free(drained_first.data);

    try sq.push(3, "during_drain");
    try sq.push(4, "after_push");

    var count: usize = 0;
    while (sq.pop()) |entry| {
        alloc.free(entry.data);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}
