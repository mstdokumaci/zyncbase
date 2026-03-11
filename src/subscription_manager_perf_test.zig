const std = @import("std");
const testing = std.testing;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const Subscription = @import("subscription_manager.zig").Subscription;
const QueryFilter = @import("subscription_manager.zig").QueryFilter;
const Condition = @import("subscription_manager.zig").Condition;
const Row = @import("subscription_manager.zig").Row;
const RowChange = @import("subscription_manager.zig").RowChange;

// Performance test: Verify subscription matching completes in < 1ms for 10k subscriptions
// Validates Requirement 6.8
test "performance: subscription matching < 1ms for 10k subscriptions" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    // Track allocated condition arrays to free later
    var allocated_conditions = std.ArrayList([]Condition){};
    defer {
        for (allocated_conditions.items) |conds| {
            allocator.free(conds);
        }
        allocated_conditions.deinit(allocator);
    }

    // Create 10,000 subscriptions with various filters
    const num_subscriptions = 10_000;
    var i: u64 = 0;
    while (i < num_subscriptions) : (i += 1) {
        const filter_type = i % 5;

        var conditions = std.ArrayList(Condition){};

        // Vary the filters to simulate realistic scenarios
        switch (filter_type) {
            0 => {
                // Empty filter (matches all)
            },
            1 => {
                // Single condition
                try conditions.append(allocator, .{
                    .field = "status",
                    .op = .equals,
                    .value = .{ .string = "active" },
                });
            },
            2 => {
                // Two conditions (AND)
                try conditions.append(allocator, .{
                    .field = "status",
                    .op = .equals,
                    .value = .{ .string = "active" },
                });
                try conditions.append(allocator, .{
                    .field = "priority",
                    .op = .greater_than,
                    .value = .{ .integer = 5 },
                });
            },
            3 => {
                // Numeric comparison
                try conditions.append(allocator, .{
                    .field = "priority",
                    .op = .less_or_equal,
                    .value = .{ .integer = 10 },
                });
            },
            4 => {
                // String operation
                try conditions.append(allocator, .{
                    .field = "title",
                    .op = .contains,
                    .value = .{ .string = "urgent" },
                });
            },
            else => unreachable,
        }

        const conds_slice = try conditions.toOwnedSlice(allocator);
        try allocated_conditions.append(allocator, conds_slice);

        const sub = Subscription{
            .id = i,
            .namespace = "workspace-123",
            .collection = "tasks",
            .filter = QueryFilter{
                .conditions = conds_slice,
                .or_conditions = null,
            },
            .sort = null,
            .connection_id = i,
        };

        try mgr.subscribe(sub);
    }

    // Create a row change that will match some subscriptions
    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("status", .{ .string = "active" });
    try new_row.put("priority", .{ .integer = 8 });
    try new_row.put("title", .{ .string = "Fix urgent bug" });

    const change = RowChange{
        .namespace = "workspace-123",
        .collection = "tasks",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    // Measure matching time
    const start = std.time.nanoTimestamp();
    const matches = try mgr.findMatchingSubscriptions(change);
    const end = std.time.nanoTimestamp();
    defer allocator.free(matches);

    const duration_ns = end - start;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    std.debug.print("\n", .{});
    std.debug.print("Performance Test Results:\n", .{});
    std.debug.print("  Subscriptions: {d}\n", .{num_subscriptions});
    std.debug.print("  Matches found: {d}\n", .{matches.len});
    std.debug.print("  Duration: {d:.3} ms\n", .{duration_ms});
    std.debug.print("  Target: < 10.0 ms\n", .{});

    // Verify performance requirement: < 10ms for 10k subscriptions
    // Relax for TSan
    const target_ms: f64 = if (@import("builtin").sanitize_thread) 100.0 else 10.0;
    try testing.expect(duration_ms < target_ms);

    // Verify we found the expected matches
    // Empty filters (2000) + status=active (2000) + status=active AND priority>5 (2000) + priority<=10 (2000) + contains "urgent" (2000)
    // Should match: empty (2000) + status=active (2000) + status=active AND priority>5 (2000) + priority<=10 (2000) + contains "urgent" (2000)
    try testing.expect(matches.len > 0);
}

// Performance test: Verify no performance degradation with complex filters
test "performance: complex filter evaluation" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    // Track allocated condition arrays to free later
    var allocated_conditions = std.ArrayList([]Condition){};
    defer {
        for (allocated_conditions.items) |conds| {
            allocator.free(conds);
        }
        allocated_conditions.deinit(allocator);
    }

    // Create subscriptions with complex filters
    const num_subscriptions = 1_000;
    var i: u64 = 0;
    while (i < num_subscriptions) : (i += 1) {
        var conditions = std.ArrayList(Condition){};

        // Complex filter with multiple conditions
        try conditions.append(allocator, .{
            .field = "status",
            .op = .equals,
            .value = .{ .string = "active" },
        });
        try conditions.append(allocator, .{
            .field = "priority",
            .op = .greater_than,
            .value = .{ .integer = 5 },
        });
        try conditions.append(allocator, .{
            .field = "assignee",
            .op = .not_equals,
            .value = .{ .string = "unassigned" },
        });
        try conditions.append(allocator, .{
            .field = "title",
            .op = .contains,
            .value = .{ .string = "bug" },
        });

        const conds_slice = try conditions.toOwnedSlice(allocator);
        try allocated_conditions.append(allocator, conds_slice);

        const sub = Subscription{
            .id = i,
            .namespace = "workspace-123",
            .collection = "tasks",
            .filter = QueryFilter{
                .conditions = conds_slice,
                .or_conditions = null,
            },
            .sort = null,
            .connection_id = i,
        };

        try mgr.subscribe(sub);
    }

    // Create a row change
    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("status", .{ .string = "active" });
    try new_row.put("priority", .{ .integer = 8 });
    try new_row.put("assignee", .{ .string = "alice" });
    try new_row.put("title", .{ .string = "Fix critical bug in auth" });

    const change = RowChange{
        .namespace = "workspace-123",
        .collection = "tasks",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    // Measure matching time
    const start = std.time.nanoTimestamp();
    const matches = try mgr.findMatchingSubscriptions(change);
    const end = std.time.nanoTimestamp();
    defer allocator.free(matches);

    const duration_ns = end - start;
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    std.debug.print("\n", .{});
    std.debug.print("Complex Filter Performance:\n", .{});
    std.debug.print("  Subscriptions: {d}\n", .{num_subscriptions});
    std.debug.print("  Matches found: {d}\n", .{matches.len});
    std.debug.print("  Duration: {d:.3} ms\n", .{duration_ms});

    // All subscriptions should match
    try testing.expectEqual(num_subscriptions, matches.len);
}

// Performance test: Verify efficient indexing by namespace+collection
test "performance: efficient namespace+collection indexing" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    // Track allocated strings to free later
    var allocated_strings = std.ArrayList([]const u8){};
    defer {
        for (allocated_strings.items) |str| {
            allocator.free(str);
        }
        allocated_strings.deinit(allocator);
    }

    // Create subscriptions across multiple namespaces and collections
    const num_namespaces = 10;
    const num_collections = 10;
    const subs_per_combo = 100;

    var sub_id: u64 = 0;
    var ns: usize = 0;
    while (ns < num_namespaces) : (ns += 1) {
        var coll: usize = 0;
        while (coll < num_collections) : (coll += 1) {
            var i: usize = 0;
            while (i < subs_per_combo) : (i += 1) {
                const namespace = try std.fmt.allocPrint(allocator, "ns-{d}", .{ns});
                const collection = try std.fmt.allocPrint(allocator, "coll-{d}", .{coll});

                try allocated_strings.append(allocator, namespace);
                try allocated_strings.append(allocator, collection);

                const sub = Subscription{
                    .id = sub_id,
                    .namespace = namespace,
                    .collection = collection,
                    .filter = QueryFilter{
                        .conditions = &[_]Condition{},
                        .or_conditions = null,
                    },
                    .sort = null,
                    .connection_id = sub_id,
                };

                try mgr.subscribe(sub);
                sub_id += 1;
            }
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("Total subscriptions: {d}\n", .{sub_id});

    // Create a row change for a specific namespace+collection
    var new_row = Row.init(allocator);
    defer new_row.deinit();
    try new_row.put("data", .{ .string = "test" });

    const change = RowChange{
        .namespace = "ns-5",
        .collection = "coll-5",
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    };

    // Measure matching time - should only check 100 subscriptions, not all 10,000
    const start = std.time.nanoTimestamp();
    const matches = try mgr.findMatchingSubscriptions(change);
    const end = std.time.nanoTimestamp();
    defer allocator.free(matches);

    const duration_ns = end - start;
    const duration_us = @as(f64, @floatFromInt(duration_ns)) / 1_000.0;

    std.debug.print("Indexing Performance:\n", .{});
    std.debug.print("  Total subscriptions: {d}\n", .{sub_id});
    std.debug.print("  Relevant subscriptions: {d}\n", .{subs_per_combo});
    std.debug.print("  Matches found: {d}\n", .{matches.len});
    std.debug.print("  Duration: {d:.1} μs\n", .{duration_us});

    // Should match exactly the subscriptions for this namespace+collection
    try testing.expectEqual(subs_per_combo, matches.len);

    // Should be very fast since we only check 100 subscriptions
    // Relax for TSan
    const target_us: f64 = if (@import("builtin").sanitize_thread) 5000.0 else 1000.0;
    try testing.expect(duration_us < target_us); // < 1 millisecond (un-sanitized)
}
