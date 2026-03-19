const std = @import("std");
const testing = std.testing;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const Subscription = @import("subscription_manager.zig").Subscription;
const QueryFilter = @import("subscription_manager.zig").QueryFilter;
const Condition = @import("subscription_manager.zig").Condition;
const Row = @import("subscription_manager.zig").Row;
const RowChange = @import("subscription_manager.zig").RowChange;

// Unit test: Filter evaluation for each operator
test "unit: filter evaluation with equals operator" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    var row = Row.init(allocator);
    defer row.deinit();
    try row.put("status", .{ .string = "active" });

    const filter = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "status", .op = .equals, .value = .{ .string = "active" } },
        },
    };

    try testing.expect(mgr.evaluateFilter(filter, row));

    const filter_no_match = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "status", .op = .equals, .value = .{ .string = "completed" } },
        },
    };

    try testing.expect(!mgr.evaluateFilter(filter_no_match, row));
}

test "unit: filter evaluation with not_equals operator" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    var row = Row.init(allocator);
    defer row.deinit();
    try row.put("status", .{ .string = "active" });

    const filter = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "status", .op = .not_equals, .value = .{ .string = "completed" } },
        },
    };

    try testing.expect(mgr.evaluateFilter(filter, row));
}

test "unit: filter evaluation with comparison operators" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    var row = Row.init(allocator);
    defer row.deinit();
    try row.put("priority", .{ .integer = 8 });

    // Greater than
    const filter_gt = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "priority", .op = .greater_than, .value = .{ .integer = 5 } },
        },
    };
    try testing.expect(mgr.evaluateFilter(filter_gt, row));

    // Less than
    const filter_lt = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "priority", .op = .less_than, .value = .{ .integer = 10 } },
        },
    };
    try testing.expect(mgr.evaluateFilter(filter_lt, row));

    // Greater or equal
    const filter_gte = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "priority", .op = .greater_or_equal, .value = .{ .integer = 8 } },
        },
    };
    try testing.expect(mgr.evaluateFilter(filter_gte, row));

    // Less or equal
    const filter_lte = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "priority", .op = .less_or_equal, .value = .{ .integer = 8 } },
        },
    };
    try testing.expect(mgr.evaluateFilter(filter_lte, row));
}

test "unit: filter evaluation with string operators" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    var row = Row.init(allocator);
    defer row.deinit();
    try row.put("title", .{ .string = "Fix urgent bug in authentication" });

    // Contains
    const filter_contains = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "title", .op = .contains, .value = .{ .string = "urgent" } },
        },
    };
    try testing.expect(mgr.evaluateFilter(filter_contains, row));

    // Starts with
    const filter_starts = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "title", .op = .starts_with, .value = .{ .string = "Fix" } },
        },
    };
    try testing.expect(mgr.evaluateFilter(filter_starts, row));

    // Ends with
    const filter_ends = QueryFilter{
        .conditions = &[_]Condition{
            .{ .field = "title", .op = .ends_with, .value = .{ .string = "authentication" } },
        },
    };
    try testing.expect(mgr.evaluateFilter(filter_ends, row));
}

// Unit test: Subscription indexing
test "unit: subscription indexing by namespace and collection" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    const sub1 = Subscription{
        .id = 1,
        .namespace = "ns1",
        .collection = "tasks",
        .filter = QueryFilter{ .conditions = &[_]Condition{} },
        .sort = null,
        .connection_id = 100,
    };

    const sub2 = Subscription{
        .id = 2,
        .namespace = "ns1",
        .collection = "users",
        .filter = QueryFilter{ .conditions = &[_]Condition{} },
        .sort = null,
        .connection_id = 100,
    };

    const sub3 = Subscription{
        .id = 3,
        .namespace = "ns2",
        .collection = "tasks",
        .filter = QueryFilter{ .conditions = &[_]Condition{} },
        .sort = null,
        .connection_id = 100,
    };

    try mgr.subscribe(sub1);
    try mgr.subscribe(sub2);
    try mgr.subscribe(sub3);

    // Test that subscriptions are indexed correctly
    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("data", .{ .string = "test" });

    const change1 = RowChange{
        .namespace = "ns1",
        .collection = "tasks",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    const matches1 = try mgr.findMatchingSubscriptions(change1);
    defer allocator.free(matches1);

    // Should only match sub1
    try testing.expectEqual(@as(usize, 1), matches1.len);
    try testing.expectEqual(@as(u64, 1), matches1[0]);
}

// Unit test: Subscribe and unsubscribe
test "unit: subscribe and unsubscribe operations" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    const sub = Subscription{
        .id = 1,
        .namespace = "ns1",
        .collection = "tasks",
        .filter = QueryFilter{ .conditions = &[_]Condition{} },
        .sort = null,
        .connection_id = 100,
    };

    // Subscribe
    try mgr.subscribe(sub);

    // Verify subscription exists
    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("data", .{ .string = "test" });

    const change = RowChange{
        .namespace = "ns1",
        .collection = "tasks",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    const matches_before = try mgr.findMatchingSubscriptions(change);
    defer allocator.free(matches_before);
    try testing.expectEqual(@as(usize, 1), matches_before.len);

    // Unsubscribe
    try mgr.unsubscribe(1);

    // Verify subscription no longer exists
    const matches_after = try mgr.findMatchingSubscriptions(change);
    defer allocator.free(matches_after);
    try testing.expectEqual(@as(usize, 0), matches_after.len);
}

// Unit test: Notification latency measurement
test "unit: measure notification latency" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    // Create a subscription
    const sub = Subscription{
        .id = 1,
        .namespace = "ns1",
        .collection = "tasks",
        .filter = QueryFilter{
            .conditions = &[_]Condition{
                .{ .field = "status", .op = .equals, .value = .{ .string = "active" } },
            },
        },
        .sort = null,
        .connection_id = 100,
    };

    try mgr.subscribe(sub);

    // Create a row change
    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("status", .{ .string = "active" });

    const change = RowChange{
        .namespace = "ns1",
        .collection = "tasks",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    // Measure latency
    const start = std.time.nanoTimestamp();
    const matches = try mgr.findMatchingSubscriptions(change);
    const end = std.time.nanoTimestamp();
    defer allocator.free(matches);

    const duration_ns = end - start;
    const duration_us = @as(f64, @floatFromInt(duration_ns)) / 1_000.0;

    std.debug.print("\nNotification latency: {d:.1} μs\n", .{duration_us});

    // Verify latency is reasonable (< 500 microseconds for single subscription)
    try testing.expect(duration_us < 500.0);
}
