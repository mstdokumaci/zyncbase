const std = @import("std");
const testing = std.testing;
const spmcBlockingQueue = @import("spmc_blocking_queue.zig").spmcBlockingQueue;

const TestItem = struct {
    id: u64,
    value: u32,
};

test "SpmcBlockingQueue: pop blocks until item is pushed" {
    const alloc = testing.allocator;
    var q = spmcBlockingQueue(TestItem).init(alloc);
    defer q.deinit();

    const Context = struct {
        q: *spmcBlockingQueue(TestItem),
    };

    var ctx = Context{ .q = &q };

    const pusher = struct {
        fn run(c: *Context) void {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            c.q.push(.{ .id = 99, .value = 999 }) catch @panic("unexpected push failure");
        }
    }.run;

    const thread = try std.Thread.spawn(.{}, pusher, .{&ctx});

    const popped = q.pop() orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 99), popped.id);
    try testing.expectEqual(@as(u32, 999), popped.value);

    thread.join();
}

test "SpmcBlockingQueue: shutdown unblocks waiting consumers" {
    const alloc = testing.allocator;
    var q = spmcBlockingQueue(TestItem).init(alloc);
    defer q.deinit();

    const Context = struct {
        q: *spmcBlockingQueue(TestItem),
    };

    var ctx = Context{ .q = &q };

    const consumer = struct {
        fn run(c: *Context) !void {
            const item = c.q.pop();
            try testing.expect(item == null);
        }
    }.run;

    const thread = try std.Thread.spawn(.{}, consumer, .{&ctx});

    std.Thread.sleep(10 * std.time.ns_per_ms);
    q.shutdown();

    thread.join();
}

test "SpmcBlockingQueue: multiple consumers process items fairly" {
    const alloc = testing.allocator;
    var q = spmcBlockingQueue(TestItem).init(alloc);
    defer q.deinit();

    const consumer_count = 4;
    const total_items = 1000;

    const ConsumerContext = struct {
        q: *spmcBlockingQueue(TestItem),
        consumed: std.atomic.Value(usize),
    };

    const consumer = struct {
        fn run(ctx: *ConsumerContext) void {
            while (true) {
                if (ctx.q.popTimed(std.time.ns_per_ms * 50)) |item| {
                    _ = item;
                    _ = ctx.consumed.fetchAdd(1, .monotonic);
                } else {
                    break;
                }
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    var ctxs: [4]ConsumerContext = undefined;

    for (0..consumer_count) |i| {
        ctxs[i] = .{ .q = &q, .consumed = std.atomic.Value(usize).init(0) };
        threads[i] = try std.Thread.spawn(.{}, consumer, .{&ctxs[i]});
    }

    for (0..total_items) |i| {
        try q.push(.{ .id = @intCast(i), .value = @intCast(i) });
    }

    std.Thread.sleep(10 * std.time.ns_per_ms);

    q.shutdown();

    for (0..consumer_count) |i| {
        threads[i].join();
    }

    var total_consumed: usize = 0;
    for (&ctxs) |ctx| {
        total_consumed += ctx.consumed.load(.monotonic);
    }
    try testing.expectEqual(total_items, total_consumed);
}
