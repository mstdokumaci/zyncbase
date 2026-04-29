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

    // 10,000 subscriptions total: 500 groups with 20 subscribers each.
    // This provides a realistic mix of filter evaluation and result gathering.
    const group_count = 500;
    const subs_per_group = 20;

    for (0..group_count) |i| {
        // Even groups match (field_0 == 0), odd groups reject (field_0 == 999)
        const match_val: i64 = if (i % 2 == 0) 0 else 999;

        const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
            // field_index 3 corresponds to the first user-defined field in rowFromTypedValues
            .{ .field_index = 3, .op = .eq, .value = tth.valInt(match_val), .field_type = .integer, .items_type = null },
        });
        defer filter.deinit(allocator);

        for (0..subs_per_group) |j| {
            // Unique connection/subscription IDs
            _ = try engine.subscribe(1, 0, filter, @as(u64, @intCast(i + 1)), @as(u64, @intCast(j + 1)));
        }
    }

    // Test row matching user field 0 (internal index 3) == 0
    var new_row = try tth.rowFromTypedValues(allocator, &.{tth.valInt(0)});
    defer new_row.deinit(allocator);

    const change = RowChange{
        .namespace_id = 1,
        .table_index = 0,
        .operation = .insert,
        .new_row = new_row,
        .old_row = null,
    };

    // Warm up
    for (0..5) |_| {
        const m = try engine.handleRowChange(change, allocator);
        allocator.free(m);
    }

    var timer = try std.time.Timer.start();
    const iterations = 500; // Enough to get a stable average without slowing down tests

    for (0..iterations) |_| {
        const matches = try engine.handleRowChange(change, allocator);
        // Verify we got the expected 5,000 matches (50% of 10k)
        if (matches.len != (group_count / 2) * subs_per_group) {
            return error.UnexpectedMatchCount;
        }
        allocator.free(matches);
    }

    const elapsed = timer.read();
    const avg_duration_ms = @as(f64, @floatFromInt(elapsed)) / 1e6 / @as(f64, @floatFromInt(iterations));

    const builtin = @import("builtin");
    const is_debug = builtin.mode == .Debug;

    const target_ms: f64 = if (builtin.sanitize_thread) 5.0 else if (is_debug) 2.0 else 1.0;

    std.debug.print("\nPerformance: 10k subs (5k matches) processed in {d:.3}ms (Target: < {d:.1}ms)\n", .{ avg_duration_ms, target_ms });

    try testing.expect(avg_duration_ms < target_ms);
}
