const std = @import("std");
const testing = std.testing;
const spscQueue = @import("spsc_queue.zig").spscQueue;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;

const queue_type = spscQueue(u32, MemoryStrategy.AllocPool); // zwanzig-disable-line: identifier-style
const pool_type = MemoryStrategy.AllocPool(queue_type.Node);

fn failingPoolFn(comptime Node: type) type { // zwanzig-disable-line: unused-parameter identifier-style
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        should_fail: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn acquire(self: *Self) !*Node {
            if (self.should_fail) return error.OutOfMemory;
            return self.allocator.create(Node);
        }

        pub fn release(self: *Self, node: *Node) void {
            self.allocator.destroy(node);
        }
    };
}

const failing_queue_type = spscQueue(u32, failingPoolFn); // zwanzig-disable-line: identifier-style
const failing_pool_type = failingPoolFn(failing_queue_type.Node);

test "SpscQueue: empty queue" {
    const alloc = testing.allocator;
    var pool = pool_type.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "SpscQueue: single push and pop" {
    const alloc = testing.allocator;
    var pool = pool_type.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    try q.push(42);
    try testing.expect(q.hasItems());

    const val = q.pop() orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u32, 42), val);

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "SpscQueue: FIFO ordering across multiple pushes" {
    const alloc = testing.allocator;
    var pool = pool_type.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    for (0..10) |i| {
        try q.push(@intCast(i));
    }
    try testing.expect(q.hasItems());

    for (0..10) |i| {
        const val = q.pop() orelse return error.TestExpectedValue;
        try testing.expectEqual(@as(u32, @intCast(i)), val);
    }

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "SpscQueue: deinit releases only the stub node" {
    const alloc = testing.allocator;
    var pool = pool_type.init(alloc);
    var q = try queue_type.init(&pool);

    try q.push(1);
    try q.push(2);
    try q.push(3);

    // deinit only releases the stub — callers must drain first
    _ = q.pop();
    _ = q.pop();
    _ = q.pop();
    try testing.expect(!q.hasItems());

    q.deinit();
}

test "SpscQueue: hasItems reflects queue state" {
    const alloc = testing.allocator;
    var pool = pool_type.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    try testing.expect(!q.hasItems());
    try q.push(10);
    try testing.expect(q.hasItems());
    _ = q.pop();
    try testing.expect(!q.hasItems());
}

test "SpscQueue: pool acquire failure propagates as error from push" {
    const alloc = testing.allocator;
    var pool = failing_pool_type.init(alloc);
    var q = try failing_queue_type.init(&pool);
    defer q.deinit();

    pool.should_fail = true;
    try testing.expectError(error.OutOfMemory, q.push(1));
}

test "SpscQueue: concurrent single-producer single-consumer" {
    const alloc = testing.allocator;
    var pool = pool_type.init(alloc);
    var q = try queue_type.init(&pool);
    defer q.deinit();

    const count: u32 = 1000;

    const Producer = struct {
        fn run(queue: *queue_type, n: u32) void {
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                queue.push(i) catch {
                    std.log.err("SpscQueue producer push failed at {}", .{i});
                    return;
                };
            }
        }
    };

    const Consumer = struct {
        fn run(queue: *queue_type, n: u32, out: *u32) void {
            var received: u32 = 0;
            while (received < n) {
                if (queue.pop()) |v| {
                    if (v != received) {
                        std.log.err("SpscQueue consumer expected {} got {}", .{ received, v });
                    }
                    received += 1;
                }
            }
            out.* = received;
        }
    };

    var received: u32 = 0;
    const producer = try std.Thread.spawn(.{}, Producer.run, .{ &q, count });
    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ &q, count, &received });
    producer.join();
    consumer.join();

    try testing.expectEqual(count, received);
    try testing.expect(!q.hasItems());
}
