const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RowChange = @import("subscription_engine.zig").RowChange;
const query_parser = @import("query_parser.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const types = @import("storage_engine/types.zig");

test "SubscriptionEngine: basic subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    // Subscribe
    _ = try engine.subscribe("default", "items", filter, 1, 100);

    // Create a matching row change
    const new_row = try tth.row(allocator, .{
        .id = tth.valText("1"),
        .status = tth.valText("active"),
    });
    defer new_row.deinit(allocator);

    const change = RowChange{
        .namespace = "default",
        .collection = "items",
        .operation = .insert,
        .new_row = new_row,
        .old_row = null,
    };

    const matches = try engine.handleRowChange(change, allocator);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(u64, 1), matches[0].connection_id);
    try testing.expectEqual(@as(u64, 100), matches[0].subscription_id);
}

test "SubscriptionEngine: group sharing" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "age", .op = .gt, .value = tth.valInt(18), .field_type = .integer, .items_type = null },
    });
    defer filter.deinit(allocator);

    // Two different subscribers for EXACTLY the same filter
    const first = try engine.subscribe("ns", "coll", filter, 1, 101);
    const second = try engine.subscribe("ns", "coll", filter, 2, 102);

    try testing.expect(first); // First one should create group
    try testing.expect(!second); // Second one should join existing group

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
}

test "SubscriptionEngine: unsubscribe clean up" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "x", .op = .isNotNull, .value = null, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try engine.subscribe("n", "c", filter, 1, 1);
    try testing.expectEqual(@as(u32, 1), engine.groups.count());

    try engine.unsubscribe(1, 1);
    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.groups_by_filter.count());
}

test "SubscriptionEngine: operator matching" {
    const allocator = testing.allocator;

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "name", .op = .startsWith, .value = tth.valText("Al"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    const row1 = try tth.row(allocator, .{ .name = tth.valText("Alice") });
    defer row1.deinit(allocator);

    const row2 = try tth.row(allocator, .{ .name = tth.valText("Bob") });
    defer row2.deinit(allocator);

    try testing.expect(try SubscriptionEngine.evaluateFilter(filter, row1));
    try testing.expect(!try SubscriptionEngine.evaluateFilter(filter, row2));
}

test "SubscriptionEngine: canonical filter key includes values" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = tth.valText("inactive"), .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    // Subscribe with different values
    _ = try engine.subscribe("default", "items", filter1, 1, 101);
    _ = try engine.subscribe("default", "items", filter2, 2, 102);

    // If they share the same key, they will be in the same group.
    // They SHOULD be in different groups because the values are different.
    try testing.expectEqual(@as(u32, 2), engine.groups.count());
}

test "SubscriptionEngine: handleRowChange with long namespace/collection (heap key)" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const long_ns = "a" ** 150;
    const long_coll = "b" ** 150;
    // combined length (150 + 1 + 150 = 301) will be > 256 stack buffer

    const filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    _ = try engine.subscribe(long_ns, long_coll, filter, 1, 100);

    const new_row = try tth.row(allocator, .{});
    defer new_row.deinit(allocator);

    const change = RowChange{
        .namespace = long_ns,
        .collection = long_coll,
        .operation = .insert,
        .new_row = new_row,
        .old_row = null,
    };

    const matches = try engine.handleRowChange(change, allocator);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(u64, 1), matches[0].connection_id);
    try testing.expectEqual(@as(u64, 100), matches[0].subscription_id);
}

test "SubscriptionEngine: case-insensitive string matching" {
    const allocator = testing.allocator;

    const val = tth.valText("Al");

    const filter_starts_with = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "name", .op = .startsWith, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_starts_with.deinit(allocator);

    const filter_ends_with = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "name", .op = .endsWith, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_ends_with.deinit(allocator);

    const filter_contains = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "name", .op = .contains, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_contains.deinit(allocator);

    // Case-insensitive startsWith
    {
        const r = try tth.row(allocator, .{ .name = tth.valText("aLiCe") });
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_starts_with, r));
    }

    // Case-insensitive endsWith
    {
        const r = try tth.row(allocator, .{ .name = tth.valText("reAL") });
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_ends_with, r));
    }

    // Case-insensitive contains
    {
        const r = try tth.row(allocator, .{ .name = tth.valText("vALid") });
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_contains, r));
    }
}

test "SubscriptionEngine: group sharing with different condition order" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    // Filter 1: status=A, type=B
    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = tth.valText("A"), .field_type = .text, .items_type = null },
        .{ .field = "type", .op = .eq, .value = tth.valText("B"), .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    // Filter 2: type=B, status=A (different order)
    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "type", .op = .eq, .value = tth.valText("B"), .field_type = .text, .items_type = null },
        .{ .field = "status", .op = .eq, .value = tth.valText("A"), .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    const first = try engine.subscribe("ns", "coll", filter1, 1, 101);
    const second = try engine.subscribe("ns", "coll", filter2, 2, 102);

    try testing.expect(first);
    try testing.expect(!second); // Should share group!

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
}

test "SubscriptionEngine: in operator subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const in_val = try tth.valArray(allocator, &[_]types.ScalarValue{
        .{ .text = "admin" },
        .{ .text = "editor" },
    });
    defer in_val.deinit(allocator);

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "role", .op = .in, .value = in_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try engine.subscribe("default", "users", filter, 1, 100);

    const r = try tth.row(allocator, .{ .role = tth.valText("admin") });
    defer r.deinit(allocator);

    const change = RowChange{
        .namespace = "default",
        .collection = "users",
        .operation = .insert,
        .new_row = r,
        .old_row = null,
    };

    const matches = try engine.handleRowChange(change, allocator);
    defer allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
}

test "SubscriptionEngine: notIn operator subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const not_in_val = try tth.valArray(allocator, &[_]types.ScalarValue{
        .{ .text = "guest" },
        .{ .text = "banned" },
    });
    defer not_in_val.deinit(allocator);

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "role", .op = .notIn, .value = not_in_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try engine.subscribe("default", "users", filter, 1, 100);

    const r = try tth.row(allocator, .{ .role = tth.valText("member") });
    defer r.deinit(allocator);

    const change = RowChange{
        .namespace = "default",
        .collection = "users",
        .operation = .insert,
        .new_row = r,
        .old_row = null,
    };

    const matches = try engine.handleRowChange(change, allocator);
    defer allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
}
