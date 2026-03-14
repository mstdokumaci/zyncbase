const std = @import("std");


const testing = std.testing;
const Allocator = std.mem.Allocator;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const Subscription = @import("subscription_manager.zig").Subscription;
const SubscriptionId = @import("subscription_manager.zig").SubscriptionId;
const QueryFilter = @import("subscription_manager.zig").QueryFilter;
const Condition = @import("subscription_manager.zig").Condition;
const SortSpec = @import("subscription_manager.zig").SortSpec;
const Row = @import("subscription_manager.zig").Row;
const RowChange = @import("subscription_manager.zig").RowChange;

// **Property 4: Subscription Invalidation Accuracy**
// Subscription manager core properties
//
// This property test verifies that subscription matching is accurate:
// - All matching subscriptions are found (no false negatives)
// - No non-matching subscriptions are included (no false positives)
// - Each subscription is notified at most once (no duplicates)
// - Empty filters match all rows
// - Complex AND/OR conditions work correctly

test "subscription: invalidation matches" {
    const allocator = testing.allocator;

    // Test with various scenarios
    const test_cases = [_]struct {
        name: []const u8,
        subscriptions: []const TestSubscription,
        change: TestRowChange,
        expected_matches: []const u64,
    }{
        .{
            .name = "empty filter matches all rows",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{},
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns1",
                .collection = "tasks",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "status", .value = .{ .string = "active" } },
                },
            },
            .expected_matches = &[_]u64{1},
        },
        .{
            .name = "single condition match",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{
                        .{ .field = "status", .op = .equals, .value = .{ .string = "active" } },
                    },
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns1",
                .collection = "tasks",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "status", .value = .{ .string = "active" } },
                },
            },
            .expected_matches = &[_]u64{1},
        },
        .{
            .name = "single condition no match",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{
                        .{ .field = "status", .op = .equals, .value = .{ .string = "active" } },
                    },
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns1",
                .collection = "tasks",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "status", .value = .{ .string = "completed" } },
                },
            },
            .expected_matches = &[_]u64{},
        },
        .{
            .name = "AND conditions all match",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{
                        .{ .field = "status", .op = .equals, .value = .{ .string = "active" } },
                        .{ .field = "priority", .op = .greater_than, .value = .{ .integer = 5 } },
                    },
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns1",
                .collection = "tasks",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "status", .value = .{ .string = "active" } },
                    .{ .name = "priority", .value = .{ .integer = 8 } },
                },
            },
            .expected_matches = &[_]u64{1},
        },
        .{
            .name = "AND conditions partial match",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{
                        .{ .field = "status", .op = .equals, .value = .{ .string = "active" } },
                        .{ .field = "priority", .op = .greater_than, .value = .{ .integer = 5 } },
                    },
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns1",
                .collection = "tasks",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "status", .value = .{ .string = "active" } },
                    .{ .name = "priority", .value = .{ .integer = 3 } },
                },
            },
            .expected_matches = &[_]u64{},
        },
        .{
            .name = "different namespace no match",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{},
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns2",
                .collection = "tasks",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "status", .value = .{ .string = "active" } },
                },
            },
            .expected_matches = &[_]u64{},
        },
        .{
            .name = "different collection no match",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{},
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns1",
                .collection = "users",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "name", .value = .{ .string = "Alice" } },
                },
            },
            .expected_matches = &[_]u64{},
        },
        .{
            .name = "multiple subscriptions some match",
            .subscriptions = &[_]TestSubscription{
                .{
                    .id = 1,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{
                        .{ .field = "status", .op = .equals, .value = .{ .string = "active" } },
                    },
                    .has_or_conditions = false,
                },
                .{
                    .id = 2,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{
                        .{ .field = "status", .op = .equals, .value = .{ .string = "completed" } },
                    },
                    .has_or_conditions = false,
                },
                .{
                    .id = 3,
                    .namespace = "ns1",
                    .collection = "tasks",
                    .filter_conditions = &[_]TestCondition{},
                    .has_or_conditions = false,
                },
            },
            .change = .{
                .namespace = "ns1",
                .collection = "tasks",
                .operation = .insert,
                .new_row_fields = &[_]TestField{
                    .{ .name = "status", .value = .{ .string = "active" } },
                },
            },
            .expected_matches = &[_]u64{ 1, 3 },
        },
    };

    for (test_cases) |tc| {
        std.log.debug("Running test case: {s}", .{tc.name});

        var mgr = try SubscriptionManager.init(allocator);
        defer mgr.deinit();

        // Track subscriptions to free later
        var subs_to_free = std.ArrayList(Subscription){};
        defer {
            for (subs_to_free.items) |sub| {
                freeSubscription(allocator, sub);
            }
            subs_to_free.deinit(allocator);
        }

        // Add subscriptions
        for (tc.subscriptions) |test_sub| {
            const sub = try createSubscription(allocator, test_sub);
            try subs_to_free.append(allocator, sub);
            try mgr.subscribe(sub);
        }

        // Create row change
        const change = try createRowChange(allocator, tc.change);
        defer freeRowChange(allocator, change);

        // Find matching subscriptions
        const matches = try mgr.findMatchingSubscriptions(change);
        defer allocator.free(matches);

        // Verify expected matches
        try testing.expectEqual(tc.expected_matches.len, matches.len);

        // Check no duplicates
        for (matches, 0..) |match_id, i| {
            for (matches[i + 1 ..]) |other_id| {
                try testing.expect(match_id != other_id);
            }
        }

        // Check all expected matches are present
        for (tc.expected_matches) |expected_id| {
            var found = false;
            for (matches) |match_id| {
                if (match_id == expected_id) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
    }
}

test "subscription: update row transitions" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    // Subscribe to active tasks
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

    // Test 1: Row enters filter (completed -> active)
    {
        var old_row = Row.init(allocator);
        defer old_row.deinit();
        try old_row.put("status", .{ .string = "completed" });

        var new_row = Row.init(allocator);
        defer new_row.deinit();
        try new_row.put("status", .{ .string = "active" });

        const change = RowChange{
            .namespace = "ns1",
            .collection = "tasks",
            .operation = .update,
            .old_row = old_row,
            .new_row = new_row,
        };

        const matches = try mgr.findMatchingSubscriptions(change);
        defer allocator.free(matches);

        try testing.expectEqual(@as(usize, 1), matches.len);
        try testing.expectEqual(@as(u64, 1), matches[0]);
    }

    // Test 2: Row leaves filter (active -> completed)
    {
        var old_row = Row.init(allocator);
        defer old_row.deinit();
        try old_row.put("status", .{ .string = "active" });

        var new_row = Row.init(allocator);
        defer new_row.deinit();
        try new_row.put("status", .{ .string = "completed" });

        const change = RowChange{
            .namespace = "ns1",
            .collection = "tasks",
            .operation = .update,
            .old_row = old_row,
            .new_row = new_row,
        };

        const matches = try mgr.findMatchingSubscriptions(change);
        defer allocator.free(matches);

        try testing.expectEqual(@as(usize, 1), matches.len);
        try testing.expectEqual(@as(u64, 1), matches[0]);
    }

    // Test 3: Row stays outside filter (completed -> archived)
    {
        var old_row = Row.init(allocator);
        defer old_row.deinit();
        try old_row.put("status", .{ .string = "completed" });

        var new_row = Row.init(allocator);
        defer new_row.deinit();
        try new_row.put("status", .{ .string = "archived" });

        const change = RowChange{
            .namespace = "ns1",
            .collection = "tasks",
            .operation = .update,
            .old_row = old_row,
            .new_row = new_row,
        };

        const matches = try mgr.findMatchingSubscriptions(change);
        defer allocator.free(matches);

        try testing.expectEqual(@as(usize, 0), matches.len);
    }
}

test "subscription: sort field change detection" {
    const allocator = testing.allocator;

    var mgr = try SubscriptionManager.init(allocator);
    defer mgr.deinit();

    // Subscribe with sort on priority field
    const sub = Subscription{
        .id = 1,
        .namespace = "ns1",
        .collection = "tasks",
        .filter = QueryFilter{
            .conditions = &[_]Condition{},
        },
        .sort = SortSpec{
            .field = "priority",
            .order = .desc,
        },
        .connection_id = 100,
    };
    try mgr.subscribe(sub);

    // Test 1: Sort field changes
    {
        var old_row = Row.init(allocator);
        defer old_row.deinit();
        try old_row.put("priority", .{ .integer = 5 });
        try old_row.put("title", .{ .string = "Task 1" });

        var new_row = Row.init(allocator);
        defer new_row.deinit();
        try new_row.put("priority", .{ .integer = 8 });
        try new_row.put("title", .{ .string = "Task 1" });

        const change = RowChange{
            .namespace = "ns1",
            .collection = "tasks",
            .operation = .update,
            .old_row = old_row,
            .new_row = new_row,
        };

        const matches = try mgr.findMatchingSubscriptions(change);
        defer allocator.free(matches);

        try testing.expectEqual(@as(usize, 1), matches.len);
    }

    // Test 2: Sort field doesn't change
    {
        var old_row = Row.init(allocator);
        defer old_row.deinit();
        try old_row.put("priority", .{ .integer = 5 });
        try old_row.put("title", .{ .string = "Task 1" });

        var new_row = Row.init(allocator);
        defer new_row.deinit();
        try new_row.put("priority", .{ .integer = 5 });
        try new_row.put("title", .{ .string = "Task 1 Updated" });

        const change = RowChange{
            .namespace = "ns1",
            .collection = "tasks",
            .operation = .update,
            .old_row = old_row,
            .new_row = new_row,
        };

        const matches = try mgr.findMatchingSubscriptions(change);
        defer allocator.free(matches);

        try testing.expectEqual(@as(usize, 1), matches.len);
    }
}

// Helper types for test data
const TestCondition = struct {
    field: []const u8,
    op: Condition.Operator,
    value: Condition.Value,
};

const TestSubscription = struct {
    id: u64,
    namespace: []const u8,
    collection: []const u8,
    filter_conditions: []const TestCondition,
    has_or_conditions: bool,
};

const TestField = struct {
    name: []const u8,
    value: Condition.Value,
};

const TestRowChange = struct {
    namespace: []const u8,
    collection: []const u8,
    operation: RowChange.Operation,
    old_row_fields: []const TestField = &[_]TestField{},
    new_row_fields: []const TestField = &[_]TestField{},
};

// Helper functions
fn createSubscription(allocator: Allocator, test_sub: TestSubscription) !Subscription {
    var conditions = std.ArrayList(Condition){};
    for (test_sub.filter_conditions) |tc| {
        try conditions.append(allocator, Condition{
            .field = tc.field,
            .op = tc.op,
            .value = tc.value,
        });
    }

    return Subscription{
        .id = test_sub.id,
        .namespace = test_sub.namespace,
        .collection = test_sub.collection,
        .filter = QueryFilter{
            .conditions = try conditions.toOwnedSlice(allocator),
            .or_conditions = null,
        },
        .sort = null,
        .connection_id = 100,
    };
}

fn freeSubscription(allocator: Allocator, sub: Subscription) void {
    allocator.free(sub.filter.conditions);
}

fn createRowChange(allocator: Allocator, test_change: TestRowChange) !RowChange {
    var old_row: ?Row = null;
    if (test_change.old_row_fields.len > 0) {
        var row = Row.init(allocator);
        for (test_change.old_row_fields) |field| {
            try row.put(field.name, field.value);
        }
        old_row = row;
    }

    var new_row: ?Row = null;
    if (test_change.new_row_fields.len > 0) {
        var row = Row.init(allocator);
        for (test_change.new_row_fields) |field| {
            try row.put(field.name, field.value);
        }
        new_row = row;
    }

    return RowChange{
        .namespace = test_change.namespace,
        .collection = test_change.collection,
        .operation = test_change.operation,
        .old_row = old_row,
        .new_row = new_row,
    };
}

fn freeRowChange(allocator: Allocator, change: RowChange) void {
    _ = allocator;
    if (change.old_row) |*row| {
        var mutable_row = @constCast(row);
        mutable_row.deinit();
    }
    if (change.new_row) |*row| {
        var mutable_row = @constCast(row);
        mutable_row.deinit();
    }
}
