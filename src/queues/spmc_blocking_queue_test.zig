const std = @import("std");
const testing = std.testing;
const spmcBlockingQueue = @import("spmc_blocking_queue.zig").spmcBlockingQueue;

const TestItem = struct {
    id: u64,
    value: u32,
};

test "SpmcBlockingQueue: empty queue" {
    const alloc = testing.allocator;
    var q = spmcBlockingQueue(TestItem).init(alloc);
    defer q.deinit();

    try testing.expect(q.popTimed(0) == null);
}

test "SpmcBlockingQueue: push and pop single item" {
    const alloc = testing.allocator;
    var q = spmcBlockingQueue(TestItem).init(alloc);
    defer q.deinit();

    try q.push(.{ .id = 42, .value = 100 });

    const popped = q.popTimed(0) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 42), popped.id);
    try testing.expectEqual(@as(u32, 100), popped.value);
}

test "SpmcBlockingQueue: push and pop multiple items FIFO" {
    const alloc = testing.allocator;
    var q = spmcBlockingQueue(TestItem).init(alloc);
    defer q.deinit();

    try q.push(.{ .id = 1, .value = 10 });
    try q.push(.{ .id = 2, .value = 20 });
    try q.push(.{ .id = 3, .value = 30 });

    const a = q.popTimed(0) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 1), a.id);

    const b = q.popTimed(0) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 2), b.id);

    const c = q.popTimed(0) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u64, 3), c.id);

    try testing.expect(q.popTimed(0) == null);
}

test "SpmcBlockingQueue: deinit frees remaining items" {
    const alloc = testing.allocator;
    var q = spmcBlockingQueue(TestItem).init(alloc);

    try q.push(.{ .id = 1, .value = 100 });
    try q.push(.{ .id = 2, .value = 200 });
    try q.push(.{ .id = 3, .value = 300 });

    q.deinit();
}
