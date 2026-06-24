const std = @import("std");
const testing = std.testing;
const mpscQueue = @import("mpsc_queue.zig").mpscQueue;

const TestEntry = struct {
    id: u64,
    msg: []const u8,

    pub fn free(self: *TestEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.msg);
    }
};

test "MpscQueue: empty queue" {
    const alloc = testing.allocator;
    var q = try mpscQueue(TestEntry).init(alloc);
    defer q.deinit();

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "MpscQueue: push and pop single entry" {
    const alloc = testing.allocator;
    var q = try mpscQueue(TestEntry).init(alloc);
    defer q.deinit();

    try q.push(.{ .id = 42, .msg = try alloc.dupe(u8, "hello") });
    try testing.expect(q.hasItems());

    const entry = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 42), entry.id);
    try testing.expectEqualStrings("hello", entry.msg);
    alloc.free(entry.msg);

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "MpscQueue: push multiple entries preserves FIFO order" {
    const alloc = testing.allocator;
    var q = try mpscQueue(TestEntry).init(alloc);
    defer q.deinit();

    try q.push(.{ .id = 1, .msg = try alloc.dupe(u8, "first") });
    try q.push(.{ .id = 2, .msg = try alloc.dupe(u8, "second") });
    try q.push(.{ .id = 3, .msg = try alloc.dupe(u8, "third") });

    const e1 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 1), e1.id);
    try testing.expectEqualStrings("first", e1.msg);
    alloc.free(e1.msg);

    const e2 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 2), e2.id);
    try testing.expectEqualStrings("second", e2.msg);
    alloc.free(e2.msg);

    const e3 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 3), e3.id);
    try testing.expectEqualStrings("third", e3.msg);
    alloc.free(e3.msg);

    try testing.expect(q.pop() == null);
}

test "MpscQueue: pop after drain returns null" {
    const alloc = testing.allocator;
    var q = try mpscQueue(TestEntry).init(alloc);
    defer q.deinit();

    try q.push(.{ .id = 1, .msg = try alloc.dupe(u8, "a") });
    try q.push(.{ .id = 2, .msg = try alloc.dupe(u8, "b") });

    while (q.pop()) |entry| {
        alloc.free(entry.msg);
    }

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "MpscQueue: deinit frees remaining entries via free fn" {
    const alloc = testing.allocator;
    var q = try mpscQueue(TestEntry).init(alloc);

    try q.push(.{ .id = 1, .msg = try alloc.dupe(u8, "unconsumed1") });
    try q.push(.{ .id = 2, .msg = try alloc.dupe(u8, "unconsumed2") });
    try q.push(.{ .id = 3, .msg = try alloc.dupe(u8, "unconsumed3") });

    q.deinit();
}
