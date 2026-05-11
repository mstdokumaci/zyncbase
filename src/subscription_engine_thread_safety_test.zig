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

    const thread_count = 4;
    const subs_per_thread = 100;
    const total_subs = thread_count * subs_per_thread;

    var threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const run_subscribe = struct {
        fn run(engine_ptr: *SubscriptionEngine, start_id: u32, sub_count: u32, alloc: std.mem.Allocator) void {
            var filter = qth.makeFilterWithConditions(alloc, &[_]query_ast.Condition{
                .{ .field_index = 2, .op = .eq, .value = tth.valBool(true), .field_type = .boolean, .items_type = null },
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

    // Concurrent handleRecordChange
    const run_handle = struct {
        fn run(engine_ptr: *SubscriptionEngine, alloc: std.mem.Allocator) void {
            var r = tth.recordFromValues(alloc, &.{tth.valBool(true)}) catch return;
            defer r.deinit(alloc);

            const change = RecordChange{
                .namespace_id = 1,
                .table_index = 0,
                .operation = .update,
                .new_record = r,
                .old_record = null,
            };

            for (0..100) |_| {
                const matches = engine_ptr.handleRecordChange(change, alloc) catch @panic("handleRecordChange failed");
                alloc.free(matches);
            }
        }
    }.run;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, run_handle, .{ &engine, allocator });
    }

    for (threads) |t| t.join();
}

test "SubscriptionEngine: concurrent unsubscribe" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 2, .op = .eq, .value = tth.valBool(true), .field_type = .boolean, .items_type = null },
    });
    defer filter.deinit(allocator);

    const count = 400;
    for (0..count) |i| {
        _ = try engine.subscribe(1, 0, filter, i, 1);
    }

    const thread_count = 4;
    var threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const run_unsubscribe = struct {
        fn run(engine_ptr: *SubscriptionEngine, start_id: u32, sub_count: u32) void {
            _ = sub_count;
            for (0..400) |i| {
                const conn_id = start_id + @as(u32, @intCast(i));
                engine_ptr.unsubscribe(conn_id, 1);
            }
        }
    }.run;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, run_unsubscribe, .{
            &engine,
            @as(u32, @intCast(i * (count / thread_count))),
            @as(u32, @intCast(count / thread_count)),
        });
    }

    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.active_subs.count());
}
