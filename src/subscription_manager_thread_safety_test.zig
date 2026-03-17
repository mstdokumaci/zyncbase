// Thread-safety exploration and stress tests for SubscriptionManager.
//
const std = @import("std");
const testing = std.testing;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const Subscription = @import("subscription_manager.zig").Subscription;
const QueryFilter = @import("subscription_manager.zig").QueryFilter;
const Condition = @import("subscription_manager.zig").Condition;
const Row = @import("subscription_manager.zig").Row;
const RowChange = @import("subscription_manager.zig").RowChange;
const SubscriptionId = @import("subscription_manager.zig").SubscriptionId;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeEmptySub(id: SubscriptionId, ns: []const u8, coll: []const u8) Subscription {
    return Subscription{
        .id = id,
        .namespace = ns,
        .collection = coll,
        .filter = QueryFilter{ .conditions = &[_]Condition{}, .or_conditions = null },
        .sort = null,
        .connection_id = id,
    };
}

// ---------------------------------------------------------------------------
// Bug Condition Exploration Test 1:
//   Two threads each call `subscribe` 1000 times on the same manager.
//   On unfixed code TSan will report a data race on AutoHashMap.metadata.
// ---------------------------------------------------------------------------

const ConcurrentSubscribeCtx = struct {
    mgr: *SubscriptionManager,
    base_id: SubscriptionId,
    count: usize,
    err: ?anyerror = null,
};

fn concurrentSubscribeWorker(ctx: *ConcurrentSubscribeCtx) void {
    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        const id = ctx.base_id + @as(SubscriptionId, @intCast(i));
        const sub = makeEmptySub(id, "ns-race", "coll-race");
        ctx.mgr.subscribe(sub) catch |err| {
            ctx.err = err;
            return;
        };
    }
}

// **Property 1 — Bug Condition**: Concurrent writes to SubscriptionManager
// are serialized (no data race).
//
// Two threads each call `subscribe` 1000 times with unique IDs on the same
// SubscriptionManager instance.
//
// UNFIXED: TSan reports a data race on `subscriptions` or `index` metadata.
// FIXED:   Both threads complete; all 2000 subscriptions are registered.
//
test "concurrent subscribe: two threads each subscribe 1000 times" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    const count = 1000;

    var ctx_a = ConcurrentSubscribeCtx{ .mgr = mgr, .base_id = 0, .count = count };
    var ctx_b = ConcurrentSubscribeCtx{ .mgr = mgr, .base_id = count, .count = count };

    const thread_a = try std.Thread.spawn(.{}, concurrentSubscribeWorker, .{&ctx_a});
    const thread_b = try std.Thread.spawn(.{}, concurrentSubscribeWorker, .{&ctx_b});

    thread_a.join();
    thread_b.join();

    // Both workers must have completed without error.
    try testing.expectEqual(@as(?anyerror, null), ctx_a.err);
    try testing.expectEqual(@as(?anyerror, null), ctx_b.err);

    // After the fix all 2000 subscriptions must be present.
    try testing.expectEqual(@as(usize, count * 2), mgr.subscriptions.count());
}

// ---------------------------------------------------------------------------
// Bug Condition Exploration Test 2:
//   One thread subscribes in a loop; another calls findMatchingSubscriptions
//   concurrently.  On unfixed code TSan will report a read-write race on the
//   index ArrayList or AutoHashMap metadata.
// ---------------------------------------------------------------------------

const SubscribeLoopCtx = struct {
    mgr: *SubscriptionManager,
    base_id: SubscriptionId,
    count: usize,
    done: std.atomic.Value(bool),
    err: ?anyerror,

    fn init(mgr: *SubscriptionManager, base_id: SubscriptionId, count: usize) @This() {
        return .{
            .mgr = mgr,
            .base_id = base_id,
            .count = count,
            .done = std.atomic.Value(bool).init(false),
            .err = null,
        };
    }
};

fn subscribeLoopWorker(ctx: *SubscribeLoopCtx) void {
    var i: usize = 0;
    while (i < ctx.count) : (i += 1) {
        const id = ctx.base_id + @as(SubscriptionId, @intCast(i));
        const sub = makeEmptySub(id, "ns-rw", "coll-rw");
        ctx.mgr.subscribe(sub) catch |err| {
            ctx.err = err;
            ctx.done.store(true, .release);
            return;
        };
    }
    ctx.done.store(true, .release);
}

const FindLoopCtx = struct {
    mgr: *SubscriptionManager,
    allocator: std.mem.Allocator,
    writer_done: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

fn findLoopWorker(ctx: *FindLoopCtx) void {
    var row = Row.init(ctx.allocator);
    defer row.deinit();
    row.put("data", .{ .string = "test" }) catch |err| {
        ctx.err = err;
        return;
    };

    const change = RowChange{
        .namespace = "ns-rw",
        .collection = "coll-rw",
        .operation = .insert,
        .old_row = null,
        .new_row = row,
    };

    // Keep reading until the writer is done.
    while (!ctx.writer_done.load(.acquire)) {
        const matches = ctx.mgr.findMatchingSubscriptions(change) catch |err| {
            ctx.err = err;
            return;
        };
        ctx.allocator.free(matches);
    }
    // One final read after writer finishes.
    const matches = ctx.mgr.findMatchingSubscriptions(change) catch |err| {
        ctx.err = err;
        return;
    };
    ctx.allocator.free(matches);
}

// **Property 1 — Bug Condition**: Concurrent subscribe + findMatchingSubscriptions
// does not produce a data race.
//
// One thread subscribes 1000 times; another calls findMatchingSubscriptions
// in a tight loop until the writer is done.
//
// UNFIXED: TSan reports a read-write race on `index` ArrayList or AutoHashMap.
// FIXED:   Both threads complete without error; no torn reads.
//
test "concurrent subscribe+find: subscribe and findMatchingSubscriptions race" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    var writer_ctx = SubscribeLoopCtx.init(mgr, 0, 1000);

    var reader_ctx = FindLoopCtx{
        .mgr = mgr,
        .allocator = allocator,
        .writer_done = &writer_ctx.done,
    };

    const writer_thread = try std.Thread.spawn(.{}, subscribeLoopWorker, .{&writer_ctx});
    const reader_thread = try std.Thread.spawn(.{}, findLoopWorker, .{&reader_ctx});

    writer_thread.join();
    reader_thread.join();

    try testing.expectEqual(@as(?anyerror, null), writer_ctx.err);
    try testing.expectEqual(@as(?anyerror, null), reader_ctx.err);
}

// ---------------------------------------------------------------------------
// Preservation Property Tests (Task 2)
//   These run single-threaded and establish the behavioral baseline.
//   They PASS on unfixed code and must continue to pass after the fix.
// ---------------------------------------------------------------------------

// **Property 2 — Preservation**: subscribe then findMatchingSubscriptions
// returns the subscription ID.
//
test "preservation: subscribe then findMatchingSubscriptions returns id" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    const sub = makeEmptySub(42, "ns1", "coll1");
    try mgr.subscribe(sub);

    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("data", .{ .string = "x" });

    const change = RowChange{
        .namespace = "ns1",
        .collection = "coll1",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    const matches = try mgr.findMatchingSubscriptions(change);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(SubscriptionId, 42), matches[0]);
}

test "preservation: unsubscribe removes subscription" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    const sub = makeEmptySub(7, "ns1", "coll1");
    try mgr.subscribe(sub);
    try mgr.unsubscribe(7);

    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("data", .{ .string = "x" });

    const change = RowChange{
        .namespace = "ns1",
        .collection = "coll1",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    const matches = try mgr.findMatchingSubscriptions(change);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 0), matches.len);
    try testing.expectEqual(@as(u32, 0), mgr.subscriptions.count());
}

test "preservation: findMatchingSubscriptions unknown namespace returns empty" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("data", .{ .string = "x" });

    const change = RowChange{
        .namespace = "no-such-ns",
        .collection = "no-such-coll",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    const matches = try mgr.findMatchingSubscriptions(change);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "preservation: evaluateFilter with empty filter returns true" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    var row = Row.init(allocator);
    defer row.deinit();
    try row.put("anything", .{ .string = "value" });

    const filter = QueryFilter{ .conditions = &[_]Condition{}, .or_conditions = null };
    try testing.expect(mgr.evaluateFilter(filter, row));

    // Also true for a completely empty row.
    var empty_row = Row.init(allocator);
    defer empty_row.deinit();
    try testing.expect(mgr.evaluateFilter(filter, empty_row));
}

test "preservation: unsubscribe unknown id returns SubscriptionNotFound" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    const result = mgr.unsubscribe(99999);
    try testing.expectError(error.SubscriptionNotFound, result);
}
