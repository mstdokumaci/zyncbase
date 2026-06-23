const std = @import("std");
const testing = std.testing;
const SendQueue = @import("send_queue.zig").SendQueue;

test "SendQueue: empty queue" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    try testing.expect(!sq.hasItems());
    try testing.expect(sq.pop() == null);
}

test "SendQueue: push and pop single entry" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    try sq.push(42, "hello");
    try testing.expect(sq.hasItems());

    const entry = sq.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 42), entry.conn_id);
    try testing.expectEqualStrings("hello", entry.data);
    alloc.free(entry.data);

    try testing.expect(!sq.hasItems());
    try testing.expect(sq.pop() == null);
}

test "SendQueue: push multiple entries preserves FIFO order" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    try sq.push(1, "first");
    try sq.push(2, "second");
    try sq.push(3, "third");

    const e1 = sq.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 1), e1.conn_id);
    try testing.expectEqualStrings("first", e1.data);
    alloc.free(e1.data);

    const e2 = sq.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 2), e2.conn_id);
    try testing.expectEqualStrings("second", e2.data);
    alloc.free(e2.data);

    const e3 = sq.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 3), e3.conn_id);
    try testing.expectEqualStrings("third", e3.data);
    alloc.free(e3.data);

    try testing.expect(sq.pop() == null);
}

test "SendQueue: pop after drain returns null" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    try sq.push(1, "a");
    try sq.push(2, "b");

    while (sq.pop()) |entry| {
        alloc.free(entry.data);
    }

    try testing.expect(!sq.hasItems());
    try testing.expect(sq.pop() == null);
}

test "SendQueue: deinit frees remaining entries" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);

    try sq.push(1, "unconsumed1");
    try sq.push(2, "unconsumed2");
    try sq.push(3, "unconsumed3");

    sq.deinit();
}

test "SendQueue: data is duplicated on push" {
    const alloc = testing.allocator;
    var sq = try SendQueue.init(alloc);
    defer sq.deinit();

    var original = try alloc.dupe(u8, "original");
    defer alloc.free(original);

    try sq.push(1, original);

    original[0] = 'X';

    const entry = sq.pop() orelse return error.TestFailed;
    try testing.expectEqualStrings("original", entry.data);
    alloc.free(entry.data);
}
