const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RowChange = @import("subscription_engine.zig").RowChange;
const query_parser = @import("query_parser.zig");
const qth = @import("query_parser_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");

test "SubscriptionEngine: basic subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const cond_val = try msgpack.Payload.strToPayload("active", allocator);
    defer cond_val.free(allocator);
    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = cond_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    // Subscribe
    _ = try engine.subscribe("default", "items", filter, 1, 100);

    // Create a matching row change
    var row = msgpack.Payload.mapPayload(allocator);
    defer row.free(allocator);

    try row.map.putString("id", try msgpack.Payload.strToPayload("1", allocator));
    try row.map.putString("status", try msgpack.Payload.strToPayload("active", allocator));

    const change = RowChange{
        .namespace = "default",
        .collection = "items",
        .operation = .insert,
        .new_row = row,
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
        .{ .field = "age", .op = .gt, .value = msgpack.Payload.intToPayload(18), .field_type = .integer, .items_type = null },
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

    const cond_val = try msgpack.Payload.strToPayload("Al", allocator);
    defer cond_val.free(allocator);
    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "name", .op = .startsWith, .value = cond_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var row1 = msgpack.Payload.mapPayload(allocator);
    defer row1.free(allocator);
    try row1.map.putString("name", try msgpack.Payload.strToPayload("Alice", allocator));

    var row2 = msgpack.Payload.mapPayload(allocator);
    defer row2.free(allocator);
    try row2.map.putString("name", try msgpack.Payload.strToPayload("Bob", allocator));

    try testing.expect(try SubscriptionEngine.evaluateFilter(filter, row1));
    try testing.expect(!try SubscriptionEngine.evaluateFilter(filter, row2));
}

test "SubscriptionEngine: canonical filter key includes values" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const val1 = try msgpack.Payload.strToPayload("active", allocator);
    defer val1.free(allocator);
    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = val1, .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    const val2 = try msgpack.Payload.strToPayload("inactive", allocator);
    defer val2.free(allocator);
    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = val2, .field_type = .text, .items_type = null },
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

    var row = msgpack.Payload.mapPayload(allocator);
    defer row.free(allocator);

    const change = RowChange{
        .namespace = long_ns,
        .collection = long_coll,
        .operation = .insert,
        .new_row = row,
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

    const val = try msgpack.Payload.strToPayload("Al", allocator);
    defer val.free(allocator);

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
        var row = msgpack.Payload.mapPayload(allocator);
        defer row.free(allocator);
        const name_val = try msgpack.Payload.strToPayload("aLiCe", allocator);
        try row.mapPut("name", name_val);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_starts_with, row));
    }

    // Case-insensitive endsWith
    {
        var row = msgpack.Payload.mapPayload(allocator);
        defer row.free(allocator);
        const name_val = try msgpack.Payload.strToPayload("reAL", allocator);
        try row.mapPut("name", name_val);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_ends_with, row));
    }

    // Case-insensitive contains
    {
        var row = msgpack.Payload.mapPayload(allocator);
        defer row.free(allocator);
        const name_val = try msgpack.Payload.strToPayload("vALid", allocator);
        try row.mapPut("name", name_val);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_contains, row));
    }
}

test "SubscriptionEngine: group sharing with different condition order" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const val1 = try msgpack.Payload.strToPayload("A", allocator);
    defer val1.free(allocator);
    const val2 = try msgpack.Payload.strToPayload("B", allocator);
    defer val2.free(allocator);

    // Filter 1: status=A, type=B
    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "status", .op = .eq, .value = val1, .field_type = .text, .items_type = null },
        .{ .field = "type", .op = .eq, .value = val2, .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    // Filter 2: type=B, status=A (different order)
    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "type", .op = .eq, .value = val2, .field_type = .text, .items_type = null },
        .{ .field = "status", .op = .eq, .value = val1, .field_type = .text, .items_type = null },
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

    var in_val: msgpack.Payload = .{ .arr = try allocator.alloc(msgpack.Payload, 2) };
    in_val.arr[0] = try msgpack.Payload.strToPayload("admin", allocator);
    in_val.arr[1] = try msgpack.Payload.strToPayload("editor", allocator);
    defer in_val.free(allocator);

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "role", .op = .in, .value = in_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try engine.subscribe("default", "users", filter, 1, 100);

    var row = msgpack.Payload.mapPayload(allocator);
    defer row.free(allocator);
    try row.map.putString("role", try msgpack.Payload.strToPayload("admin", allocator));

    const change = RowChange{
        .namespace = "default",
        .collection = "users",
        .operation = .insert,
        .new_row = row,
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

    var not_in_val: msgpack.Payload = .{ .arr = try allocator.alloc(msgpack.Payload, 2) };
    not_in_val.arr[0] = try msgpack.Payload.strToPayload("guest", allocator);
    not_in_val.arr[1] = try msgpack.Payload.strToPayload("banned", allocator);
    defer not_in_val.free(allocator);

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{ .field = "role", .op = .notIn, .value = not_in_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try engine.subscribe("default", "users", filter, 1, 100);

    var row = msgpack.Payload.mapPayload(allocator);
    defer row.free(allocator);
    try row.map.putString("role", try msgpack.Payload.strToPayload("member", allocator));

    const change = RowChange{
        .namespace = "default",
        .collection = "users",
        .operation = .insert,
        .new_row = row,
        .old_row = null,
    };

    const matches = try engine.handleRowChange(change, allocator);
    defer allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
}
