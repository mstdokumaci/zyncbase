const std = @import("std");

const memory_strategy = @import("../memory/strategy.zig");
const mpscQueue = @import("mpsc_queue.zig").mpscQueue;

const testing = std.testing;
const ArenaHandle = memory_strategy.ArenaHandle;
const MemoryStrategy = memory_strategy.MemoryStrategy;

const TestEntry = struct {
    id: u64,
    msg: []const u8,
    arena: ArenaHandle,

    pub fn owner(self: TestEntry) ArenaHandle {
        return self.arena;
    }
};

const queue_type = mpscQueue(TestEntry, ArenaHandle);

/// Enqueue one entry the way production producers do: acquire a deferred
/// arena, encode into it, take a reference for the queue, then drop the
/// producer's own reference.
fn pushEntry(q: *queue_type, ms: *MemoryStrategy, id: u64, msg: []const u8) !void {
    const handle = try ms.acquireArenaDeferred();
    defer handle.release();
    const owned = try handle.allocator().dupe(u8, msg);
    handle.retain();
    try q.push(.{ .id = id, .msg = owned, .arena = handle });
}

test "MpscQueue: empty queue" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);
    defer q.deinit();

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "MpscQueue: push and pop single entry" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);
    defer q.deinit();

    try pushEntry(&q, &ms, 42, "hello");
    try testing.expect(q.hasItems());

    const entry = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 42), entry.id);
    try testing.expectEqualStrings("hello", entry.msg);
    entry.arena.release();

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "MpscQueue: push multiple entries preserves FIFO order" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);

    try pushEntry(&q, &ms, 1, "first");
    try pushEntry(&q, &ms, 2, "second");
    try pushEntry(&q, &ms, 3, "third");

    const e1 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 1), e1.id);
    try testing.expectEqualStrings("first", e1.msg);
    e1.arena.release();

    const e2 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 2), e2.id);
    try testing.expectEqualStrings("second", e2.msg);
    e2.arena.release();

    const e3 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 3), e3.id);
    try testing.expectEqualStrings("third", e3.msg);
    e3.arena.release();

    try testing.expect(q.pop() == null);
    q.deinit();
    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}

test "MpscQueue: pop after drain returns null" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);
    defer q.deinit();

    try pushEntry(&q, &ms, 1, "a");
    try pushEntry(&q, &ms, 2, "b");

    while (q.pop()) |entry| {
        entry.arena.release();
    }

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
}

test "MpscQueue: drain releases remaining entries" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);

    try pushEntry(&q, &ms, 1, "unconsumed1");
    try pushEntry(&q, &ms, 2, "unconsumed2");
    try pushEntry(&q, &ms, 3, "unconsumed3");

    while (q.pop()) |entry| {
        entry.arena.release();
    }

    q.deinit();
    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}

// A node lives in the entry's own arena, so once `head` advances onto it the
// node's address is only meaningful while that arena is retained. Nothing else
// holds the head: releasing the popped entry must not be the last reference.
test "MpscQueue: the queue holds a reference to the head node's owner" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);

    try pushEntry(&q, &ms, 1, "one");
    try pushEntry(&q, &ms, 2, "two");

    // Two arenas outstanding: one per queued entry.
    try testing.expectEqual(@as(u32, 2), ms.arena_pool.active_count.load(.acquire));

    const e1 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 1), e1.id);
    // `head` now points into the node of this entry's arena.
    e1.arena.release();

    // Still two: the queue's own head reference keeps the first arena alive.
    // Without it the arena would return to the pool here, and `head` would
    // dangle into memory the next producer is free to reuse.
    try testing.expectEqual(@as(u32, 2), ms.arena_pool.active_count.load(.acquire));

    const e2 = q.pop() orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 2), e2.id);
    try testing.expectEqualStrings("two", e2.msg);
    e2.arena.release();

    try testing.expect(q.pop() == null);
    q.deinit();
    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}

// Producers batch: subscription and presence workers push every matched
// subscriber through one handle, so several queued nodes share an arena.
test "MpscQueue: entries sharing one owner arena stay intact" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);

    const first = try ms.acquireArenaDeferred();
    const alloc = first.allocator();

    const ids = [_]u64{ 10, 11, 12 };
    for (ids) |id| {
        const owned = try alloc.dupe(u8, "batched");
        first.retain();
        try q.push(.{ .id = id, .msg = owned, .arena = first });
    }
    first.release();

    for (ids) |id| {
        const entry = q.pop() orelse return error.TestFailed;
        try testing.expectEqual(id, entry.id);
        try testing.expectEqualStrings("batched", entry.msg);
        entry.arena.release();
    }

    try testing.expect(q.pop() == null);
    q.deinit();
    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}

// Mirrors the server shutdown path: drain, pop to empty, release each entry,
// then deinit. Every arena reference taken during the run must come back.
test "MpscQueue: shutdown drain leaves no arenas outstanding" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);

    try pushEntry(&q, &ms, 1, "one");
    try pushEntry(&q, &ms, 2, "two");

    const e1 = q.pop() orelse return error.TestFailed;
    e1.arena.release();

    const e2 = q.pop() orelse return error.TestFailed;
    e2.arena.release();

    try testing.expect(!q.hasItems());
    try testing.expect(q.pop() == null);
    q.deinit();

    try testing.expectEqual(@as(u32, 0), ms.arena_pool.active_count.load(.acquire));
}

// Per-message cost is 56 bytes of arena that is never handed back, since
// reset(.retain_capacity) cannot shrink. Recycled arenas must settle at the
// high-water mark rather than growing with every iteration.
test "MpscQueue: retained arena capacity stays bounded across iterations" {
    var ms: MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var q = try queue_type.init(testing.allocator);
    defer q.deinit();

    var settled_capacity: usize = 0;
    for (0..200) |round| {
        try pushEntry(&q, &ms, round, "payload-payload-payload");
        const entry = q.pop() orelse return error.TestFailed;
        const capacity = entry.arena.arena.queryCapacity();
        entry.arena.release();

        if (round < 50) continue; // let the pool reach steady state first
        if (settled_capacity == 0) {
            settled_capacity = capacity;
        } else {
            try testing.expect(capacity <= settled_capacity);
        }
    }
    try testing.expect(settled_capacity > 0);
}
