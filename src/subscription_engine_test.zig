const std = @import("std");
const testing = std.testing;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RowChange = @import("subscription_engine.zig").RowChange;
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");

test "SubscriptionEngine: basic subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const cond_val = try msgpack.Payload.strToPayload("active", allocator);
    defer cond_val.free(allocator);
    const filter = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "status", .op = .eq, .value = cond_val },
        },
    };

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

    const filter = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "age", .op = .gt, .value = msgpack.Payload.intToPayload(18) },
        },
    };

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

    const filter = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "x", .op = .isNotNull, .value = null },
        },
    };

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
    const filter = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "name", .op = .startsWith, .value = cond_val },
        },
    };

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
    const filter1 = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "status", .op = .eq, .value = val1 },
        },
    };

    const val2 = try msgpack.Payload.strToPayload("inactive", allocator);
    defer val2.free(allocator);
    const filter2 = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "status", .op = .eq, .value = val2 },
        },
    };

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

    const filter = query_parser.QueryFilter{ .conditions = &.{} };
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

    const filter_starts_with = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "name", .op = .startsWith, .value = val },
        },
    };

    const filter_ends_with = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "name", .op = .endsWith, .value = val },
        },
    };

    const filter_contains = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "name", .op = .contains, .value = val },
        },
    };

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
    const filter1 = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "status", .op = .eq, .value = val1 },
            .{ .field = "type", .op = .eq, .value = val2 },
        },
    };

    // Filter 2: type=B, status=A (different order)
    const filter2 = query_parser.QueryFilter{
        .conditions = &[_]query_parser.Condition{
            .{ .field = "type", .op = .eq, .value = val2 },
            .{ .field = "status", .op = .eq, .value = val1 },
        },
    };

    const first = try engine.subscribe("ns", "coll", filter1, 1, 101);
    const second = try engine.subscribe("ns", "coll", filter2, 2, 102);

    try testing.expect(first);
    try testing.expect(!second); // Should share group!

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
}
