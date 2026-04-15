const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RowChange = @import("subscription_engine.zig").RowChange;
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");

test "SubscriptionEngine: handleRowChange performance" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const group_count = 100;
    const subs_per_group = 10;

    // Create filters with different conditions
    for (0..group_count) |i| {
        var buf: [32]u8 = undefined;
        const field_name = try std.fmt.bufPrint(&buf, "field_{d}", .{i % 10});

        const filter = query_parser.QueryFilter{
            .conditions = &[_]query_parser.Condition{
                .{ .field = try allocator.dupe(u8, field_name), .op = .eq, .value = msgpack.Payload.intToPayload(@as(i64, @intCast(i % 5))), .field_type = .integer, .items_type = null },
            },
        };
        // Note: we'll leak strings in filters if we don't clean them up,
        // but QueryFilter.deinit should handle it if we structured it right.
        // Actually QueryFilter in query_parser.zig doesn't have a deinit that frees field names.
        // I'll use constant strings for now or manually clean up.

        for (0..subs_per_group) |j| {
            _ = try engine.subscribe("ns", "coll", filter, @as(u64, @intCast(i * 1000 + j)), 1);
        }

        // Clean up the filter we just subscribed (SubscriptionEngine clones it)
        if (filter.conditions) |conds| {
            allocator.free(conds[0].field);
        }
    }

    var row = msgpack.Payload.mapPayload(allocator);
    defer row.free(allocator);
    try row.map.putString("field_0", msgpack.Payload.intToPayload(@as(i64, 0)));
    try row.map.putString("field_1", msgpack.Payload.intToPayload(@as(i64, 1)));
    try row.map.putString("field_2", msgpack.Payload.intToPayload(@as(i64, 2)));

    const change = RowChange{
        .namespace = "ns",
        .collection = "coll",
        .operation = .insert,
        .new_row = row,
        .old_row = null,
    };

    var timer = try std.time.Timer.start();
    const iterations = 1000;
    var total_matches: usize = 0;

    for (0..iterations) |_| {
        const matches = try engine.handleRowChange(change, allocator);
        total_matches += matches.len;
        allocator.free(matches);
    }

    const elapsed = timer.read();
    const ops_per_sec = (@as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(elapsed))) * 1e9;

    std.debug.print("\nPerformance: {d:.2} handleRowChange/sec, Total matches: {d}\n", .{ ops_per_sec, total_matches });

    // Verify performance requirement: < 10ms for 10k subscriptions
    const duration_ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / @as(f64, @floatFromInt(iterations));
    const duration_10k_ms = duration_ms * (10000.0 / @as(f64, @floatFromInt(group_count * subs_per_group)));

    // Performance requirement: < 10ms for 10k subscriptions
    const builtin = @import("builtin");
    const target_ms: f64 = if (builtin.sanitize_thread) 100.0 else 10.0;
    try testing.expect(duration_10k_ms < target_ms);

    // Should be very fast since we only check 500 subscriptions (500 evaluations)
    const duration_us = duration_ms * 1000.0 * (500.0 / @as(f64, @floatFromInt(group_count * subs_per_group)));
    const target_us: f64 = if (builtin.sanitize_thread) 5000.0 else 1000.0;
    try testing.expect(duration_us < target_us); // < 1 millisecond (un-sanitized)
}
