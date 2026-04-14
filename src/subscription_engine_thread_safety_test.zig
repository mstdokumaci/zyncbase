const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RowChange = @import("subscription_engine.zig").RowChange;
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");

test "SubscriptionEngine: concurrent subscribe and handleRowChange" {
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
            _ = alloc;
            const filter = query_parser.QueryFilter{
                .conditions = &[_]query_parser.Condition{
                    .{
                        .field = "status",
                        .op = .eq,
                        .field_type = .boolean,
                        .canonical_value = .{ .boolean = true },
                    },
                },
            };

            var i: u32 = 0;
            while (i < sub_count) : (i += 1) {
                const conn_id = start_id + i;
                _ = engine_ptr.subscribe("ns", "coll", filter, conn_id, 1) catch @panic("subscribe failed");
            }
            _ = alloc;
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

    // Concurrent handleRowChange
    const run_handle = struct {
        fn run(engine_ptr: *SubscriptionEngine, alloc: std.mem.Allocator) void {
            var row = msgpack.Payload.mapPayload(alloc);
            defer row.free(alloc);
            row.map.putString("status", msgpack.Payload.boolToPayload(true)) catch return;

            const change = RowChange{
                .namespace = "ns",
                .collection = "coll",
                .operation = .update,
                .new_row = row,
                .old_row = null,
            };

            for (0..100) |_| {
                const matches = engine_ptr.handleRowChange(change, alloc) catch @panic("handleRowChange failed");
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

    const filter = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{
                .field = "active",
                .op = .eq,
                .field_type = .boolean,
                .canonical_value = .{ .boolean = true },
            },
        },
    };

    const count = 400;
    for (0..count) |i| {
        _ = try engine.subscribe("n", "c", filter, i, 1);
    }

    const thread_count = 4;
    var threads = try allocator.alloc(std.Thread, thread_count);
    defer allocator.free(threads);

    const run_unsubscribe = struct {
        fn run(engine_ptr: *SubscriptionEngine, start_id: u32, sub_count: u32) void {
            _ = sub_count;
            for (0..400) |i| {
                const conn_id = start_id + @as(u32, @intCast(i));
                engine_ptr.unsubscribe(conn_id, 1) catch |err| {
                    if (err != error.SubscriptionNotFound) @panic("unexpected error");
                };
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
