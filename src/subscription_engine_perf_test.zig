const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RowChange = @import("subscription_engine.zig").RowChange;
const query_parser = @import("query_parser.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

test "SubscriptionEngine: handleRowChange performance" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const group_count = 100;
    const subs_per_group = 10;

    // Create filters with different conditions
    for (0..group_count) |i| {
        const field_index: usize = 2 + (i % 10);

        const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
            .{ .field_index = field_index, .op = .eq, .value = tth.valInt(@as(i64, @intCast(i % 5))), .field_type = .integer, .items_type = null },
        });
        defer filter.deinit(allocator);

        for (0..subs_per_group) |j| {
            _ = try engine.subscribe("ns", "coll", filter, @as(u64, @intCast(i * 1000 + j)), 1);
        }
    }

    var new_row = try tth.row(allocator, .{
        .field_0 = tth.valInt(0),
        .field_1 = tth.valInt(1),
        .field_2 = tth.valInt(2),
    });
    defer new_row.deinit(allocator);

    const change = RowChange{
        .namespace = "ns",
        .collection = "coll",
        .operation = .insert,
        .new_row = new_row.row,
        .old_row = null,
    };

    var timer = try std.time.Timer.start();
    const iterations = 1000;
    var total_matches: usize = 0;

    for (0..iterations) |_| {
        const matches = try engine.handleRowChange(change, new_row.metadata, allocator);
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
