const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RecordChange = @import("subscription_engine.zig").RecordChange;
const query_ast = @import("query_ast.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

test "SubscriptionEngine: concurrent subscribe and handleRecordChange" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const thread_count: usize = 4;
    const subs_per_thread: usize = 100;
    const total_subs = thread_count * subs_per_thread;

    var threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const run_subscribe = struct {
        fn run(engine_ptr: *SubscriptionEngine, start_id: u32, sub_count: u32, alloc: std.mem.Allocator) void {
            var filter = qth.makeFilterWithConditions(alloc, &[_]query_ast.Condition{
                .{ .field_index = 3, .op = .eq, .value = tth.valBool(true), .field_type = .boolean, .items_type = null },
            }) catch @panic("OOM");
            defer filter.deinit(alloc);

            var i: u32 = 0;
            while (i < sub_count) : (i += 1) {
                const conn_id = start_id + i;
                _ = engine_ptr.subscribe(1, 0, filter, conn_id, 1) catch @panic("subscribe failed");
            }
        }
    }.run;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, run_subscribe, .{
            &engine,
            @as(u32, @intCast(i * subs_per_thread)),
            @as(u32, @intCast(subs_per_thread)),
            allocator,
        });
    }

    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
    try testing.expectEqual(@as(u32, total_subs), engine.active_subs.count());

    // Concurrent handleRecordChange with match count verification
    const ThreadResult = struct {
        count: u64,
    };
    var results: [thread_count]ThreadResult = [_]ThreadResult{.{ .count = 0 }} ** thread_count;

    const run_handle = struct {
        fn run(engine_ptr: *SubscriptionEngine, alloc: std.mem.Allocator, result: *ThreadResult) void {
            var r = tth.recordFromValues(alloc, &.{tth.valBool(true)}) catch @panic("recordFromValues failed");
            defer r.deinit(alloc);

            const change = RecordChange{
                .namespace_id = 1,
                .table_index = 0,
                .operation = .update,
                .new_record = r,
                .old_record = null,
            };

            var local_count: u64 = 0;
            for (0..100) |_| {
                const matches = engine_ptr.handleRecordChange(change, alloc) catch @panic("handleRecordChange failed");
                local_count += matches.len;
                alloc.free(matches);
            }
            result.count = local_count;
        }
    }.run;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, run_handle, .{ &engine, allocator, &results[i] });
    }

    for (threads) |t| t.join();

    // Each of 400 subscribers is matched 100 times per call = 40,000 matches per thread
    // 4 threads = 160,000 total matches
    var total: u64 = 0;
    for (results) |r| total += r.count;
    const expected: u64 = total_subs * 100 * thread_count;
    try testing.expectEqual(expected, total);
}

test "SubscriptionEngine: concurrent unsubscribe with multi-group contention" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const thread_count: usize = 4;
    const subs_per_thread: usize = 100;

    // Each thread subscribes with its own filter (different values) to the same collection.
    // This creates 4 groups that all share the same groups_by_collection entry,
    // so concurrent unsubscribes contend on the shared collection-index list.
    var threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const run_subscribe = struct {
        fn run(engine_ptr: *SubscriptionEngine, start_id: u32, sub_count: u32, alloc: std.mem.Allocator) void {
            // Each thread uses a unique filter value so groups don't merge
            var filter = qth.makeFilterWithConditions(alloc, &[_]query_ast.Condition{
                .{ .field_index = 2, .op = .eq, .value = tth.valInt(@intCast(start_id + 1)), .field_type = .integer, .items_type = null },
            }) catch @panic("OOM");
            defer filter.deinit(alloc);

            var i: u32 = 0;
            while (i < sub_count) : (i += 1) {
                const conn_id = start_id + i;
                _ = engine_ptr.subscribe(1, 0, filter, conn_id, 1) catch @panic("subscribe failed");
            }
        }
    }.run;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, run_subscribe, .{
            &engine,
            @as(u32, @intCast(i * subs_per_thread)),
            @as(u32, @intCast(subs_per_thread)),
            allocator,
        });
    }

    for (threads) |t| t.join();

    // 4 groups (one per distinct filter), all on the same collection (1, 0)
    try testing.expectEqual(@as(u32, thread_count), engine.groups.count());
    try testing.expectEqual(@as(u32, thread_count * subs_per_thread), engine.active_subs.count());

    // Verify single collection-index entry contains all 4 groups
    const coll_key = @import("subscription_engine.zig").CollectionKey{ .namespace_id = 1, .table_index = 0 };
    const coll_groups = engine.groups_by_collection.get(coll_key) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, thread_count), coll_groups.items.len);

    // Concurrent unsubscribe: each thread unsubscribes its own 100 subscribers.
    // All threads contend on the shared groups_by_collection list when removing groups.
    const run_unsubscribe = struct {
        fn run(engine_ptr: *SubscriptionEngine, start_id: u32, sub_count: u32) void { // zwanzig-disable-line: unused-parameter
            for (0..sub_count) |i| {
                const conn_id = start_id + @as(u32, @intCast(i));
                engine_ptr.unsubscribe(conn_id, 1);
            }
        }
    }.run;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, run_unsubscribe, .{
            &engine,
            @as(u32, @intCast(i * subs_per_thread)),
            @as(u32, @intCast(subs_per_thread)),
        });
    }

    for (threads) |t| t.join();

    // All groups torn down: every subscriber was the last in its group,
    // so each unsubscribe removed its group from all 4 indexes.
    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.groups_by_filter.count());
    try testing.expect(engine.groups_by_collection.get(coll_key) == null);
    try testing.expectEqual(@as(u32, 0), engine.active_subs.count());
}
