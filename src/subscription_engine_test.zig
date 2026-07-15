const std = @import("std");
const testing = std.testing;
const subscription_engine = @import("subscription_engine.zig");
const SubscriptionEngine = subscription_engine.SubscriptionEngine;
const typed_types = @import("typed/types.zig");
const sth = @import("storage_engine_test_helpers.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const query_ast = @import("query_ast.zig");

test "SubscriptionEngine: basic subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("items", &.{
            schema_helpers.makeField("status", .text),
        }),
    });
    defer schema.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    // Subscribe
    _ = try engine.subscribe(1, (schema.table("items") orelse return error.TestExpectedValue).index, filter, 1, 100);

    // Duplicate subscribe must return error
    try testing.expectError(error.AlreadySubscribed, engine.subscribe(1, (schema.table("items") orelse return error.TestExpectedValue).index, filter, 1, 100));

    // Create a matching record change
    var new_record = try tth.recordFromValues(allocator, &.{tth.valText("active")});
    defer new_record.deinit(allocator);

    const change = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = (schema.table("items") orelse return error.TestExpectedValue).index,
        .operation = .insert,
        .new_record = new_record,
        .old_record = null,
    };

    const matches = try engine.handleRecordChange(change, allocator);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(u64, 1), matches[0].connection_id);
    try testing.expectEqual(@as(u64, 100), matches[0].subscription_id);
}

test "SubscriptionEngine: group sharing" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .gt, .value = tth.valInt(18), .field_type = .integer, .items_type = null },
    });
    defer filter.deinit(allocator);

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("coll", &.{
            schema_helpers.makeField("age", .integer),
        }),
    });
    defer schema.deinit();

    // Two different subscribers for EXACTLY the same filter
    const first = try engine.subscribe(2, (schema.table("coll") orelse return error.TestExpectedValue).index, filter, 1, 101);
    const second = try engine.subscribe(2, (schema.table("coll") orelse return error.TestExpectedValue).index, filter, 2, 102);

    try testing.expect(first); // First one should create group
    try testing.expect(!second); // Second one should join existing group

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
}

test "SubscriptionEngine: unsubscribe clean up" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .isNotNull, .value = null, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("c", &.{}),
    });
    defer schema.deinit();

    _ = try engine.subscribe(3, (schema.table("c") orelse return error.TestExpectedValue).index, filter, 1, 1);
    try testing.expectEqual(@as(u32, 1), engine.groups.count());

    engine.unsubscribe(1, 1);
    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.groups_by_filter.count());
}

test "SubscriptionEngine: subscribe/unsubscribe state consistency across all indexes" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .isNotNull, .value = null, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("items", &.{}),
    });
    defer schema.deinit();

    const table_index = (schema.table("items") orelse return error.TestExpectedValue).index;
    const coll_key = subscription_engine.CollectionKey{ .namespace_id = 1, .table_index = table_index };

    // --- Single subscriber: full lifecycle ---
    const first = try engine.subscribe(1, table_index, filter, 10, 100);
    try testing.expect(first);

    // After successful subscribe: all 4 indexes must be consistent
    try testing.expectEqual(@as(u32, 1), engine.groups.count());
    try testing.expectEqual(@as(u32, 1), engine.groups_by_filter.count());
    try testing.expectEqual(@as(usize, 1), engine.groups_by_collection.get(coll_key).?.items.len);
    try testing.expect(engine.active_subs.get(.{ .connection_id = 10, .id = 100 }) != null);

    engine.unsubscribe(10, 100);

    // After unsubscribe: all 4 indexes must be clean
    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.groups_by_filter.count());
    try testing.expect(engine.groups_by_collection.get(coll_key) == null);
    try testing.expect(engine.active_subs.get(.{ .connection_id = 10, .id = 100 }) == null);

    // --- Multi-subscriber: partial unsubscribe preserves group ---
    var filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .isNotNull, .value = null, .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    const second = try engine.subscribe(1, table_index, filter2, 20, 200);
    try testing.expect(second); // new group
    const third = try engine.subscribe(1, table_index, filter2, 30, 300);
    try testing.expect(!third); // joins existing group

    // Group has 2 subscribers
    const grp = engine.groups.get(2) orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(u32, 2), grp.subscribers.count());

    // Unsubscribe one: group must survive
    engine.unsubscribe(20, 200);
    try testing.expectEqual(@as(u32, 1), engine.groups.count());
    try testing.expectEqual(@as(u32, 1), engine.groups_by_filter.count());
    try testing.expectEqual(@as(usize, 1), engine.groups_by_collection.get(coll_key).?.items.len);
    try testing.expect(engine.active_subs.get(.{ .connection_id = 20, .id = 200 }) == null);
    try testing.expect(engine.active_subs.get(.{ .connection_id = 30, .id = 300 }) != null);

    // Unsubscribe last: group must be torn down completely
    engine.unsubscribe(30, 300);
    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.groups_by_filter.count());
    try testing.expect(engine.groups_by_collection.get(coll_key) == null);
    try testing.expect(engine.active_subs.get(.{ .connection_id = 30, .id = 300 }) == null);
}

test "SubscriptionEngine: evaluateFilter: startsWith operator" {
    const allocator = testing.allocator;

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .startsWith, .value = tth.valText("Al"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var row1 = try tth.recordFromValues(allocator, &.{tth.valText("Alice")});
    defer row1.deinit(allocator);

    var row2 = try tth.recordFromValues(allocator, &.{tth.valText("Bob")});
    defer row2.deinit(allocator);

    try testing.expect(try SubscriptionEngine.evaluateFilter(&filter, &row1));
    try testing.expect(!try SubscriptionEngine.evaluateFilter(&filter, &row2));
}

test "SubscriptionEngine: canonical filter key includes values" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    var filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("inactive"), .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("items", &.{}),
    });
    defer schema.deinit();

    // Subscribe with different values
    _ = try engine.subscribe(1, (schema.table("items") orelse return error.TestExpectedValue).index, filter1, 1, 101);
    _ = try engine.subscribe(1, (schema.table("items") orelse return error.TestExpectedValue).index, filter2, 2, 102);

    // If they share the same key, they will be in the same group.
    // They SHOULD be in different groups because the values are different.
    try testing.expectEqual(@as(u32, 2), engine.groups.count());
    try testing.expectEqual(@as(u32, 2), engine.active_subs.count());
}

test "SubscriptionEngine: canonical key normalizes array contents" {
    const allocator = testing.allocator;

    // Distinguishes same-length array contents
    {
        var engine = SubscriptionEngine.init(allocator);
        defer engine.deinit();

        const in_val_1 = try tth.valArray(allocator, &[_]typed_types.ScalarValue{
            .{ .text = "a" },
        });
        defer in_val_1.deinit(allocator);
        const in_val_2 = try tth.valArray(allocator, &[_]typed_types.ScalarValue{
            .{ .text = "b" },
        });
        defer in_val_2.deinit(allocator);

        var filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
            .{ .field_index = 3, .op = .in, .value = in_val_1, .field_type = .text, .items_type = null },
        });
        defer filter1.deinit(allocator);

        var filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
            .{ .field_index = 3, .op = .in, .value = in_val_2, .field_type = .text, .items_type = null },
        });
        defer filter2.deinit(allocator);

        var schema = try sth.createSchema(allocator, &.{
            schema_helpers.makeTable("users", &.{}),
        });
        defer schema.deinit();

        _ = try engine.subscribe(1, (schema.table("users") orelse return error.TestExpectedValue).index, filter1, 1, 101);
        _ = try engine.subscribe(1, (schema.table("users") orelse return error.TestExpectedValue).index, filter2, 2, 102);

        try testing.expectEqual(@as(u32, 2), engine.groups.count());
        try testing.expectEqual(@as(u32, 2), engine.active_subs.count());
    }

    // Normalizes different-order integer arrays to same group
    {
        var engine = SubscriptionEngine.init(allocator);
        defer engine.deinit();

        const in_val_1 = try tth.valArray(allocator, &[_]typed_types.ScalarValue{
            .{ .integer = 1 },
            .{ .integer = 2 },
            .{ .integer = 3 },
        });
        defer in_val_1.deinit(allocator);
        const in_val_2 = try tth.valArray(allocator, &[_]typed_types.ScalarValue{
            .{ .integer = 3 },
            .{ .integer = 1 },
            .{ .integer = 2 },
        });
        defer in_val_2.deinit(allocator);

        var filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
            .{ .field_index = 0, .op = .in, .value = in_val_1, .field_type = .integer, .items_type = null },
        });
        defer filter1.deinit(allocator);

        var filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
            .{ .field_index = 0, .op = .in, .value = in_val_2, .field_type = .integer, .items_type = null },
        });
        defer filter2.deinit(allocator);

        var schema = try sth.createSchema(allocator, &.{
            schema_helpers.makeTable("coll", &.{}),
        });
        defer schema.deinit();

        const first = try engine.subscribe(2, (schema.table("coll") orelse return error.TestExpectedValue).index, filter1, 1, 101);
        const second = try engine.subscribe(2, (schema.table("coll") orelse return error.TestExpectedValue).index, filter2, 2, 102);

        try testing.expect(first);
        try testing.expect(!second);
        try testing.expectEqual(@as(u32, 1), engine.groups.count());
        try testing.expectEqual(@as(u32, 2), engine.active_subs.count());
    }
}

test "SubscriptionEngine: canonical key keeps integer and real distinct" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter_int = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valInt(1), .field_type = .integer, .items_type = null },
    });
    defer filter_int.deinit(allocator);

    var filter_real = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valReal(1.0), .field_type = .real, .items_type = null },
    });
    defer filter_real.deinit(allocator);

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("scores", &.{}),
    });
    defer schema.deinit();

    _ = try engine.subscribe(1, (schema.table("scores") orelse return error.TestExpectedValue).index, filter_int, 1, 201);
    _ = try engine.subscribe(1, (schema.table("scores") orelse return error.TestExpectedValue).index, filter_real, 2, 202);

    try testing.expectEqual(@as(u32, 2), engine.groups.count());
}

test "SubscriptionEngine: handleRecordChange with long namespace/collection (heap key)" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();
    const long_coll = "b" ** 150;
    // combined length (150 + 1 + 150 = 301) will be > 256 stack buffer

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    const table = try schema_helpers.makeTableAlloc(allocator, long_coll, &.{});
    defer {
        allocator.free(table.name);
        allocator.free(table.name_quoted);
    }
    var schema = try sth.createSchema(allocator, &[_]sth.Table{table});
    defer schema.deinit();

    _ = try engine.subscribe(999, (schema.table(long_coll) orelse return error.TestExpectedValue).index, filter, 1, 100);

    var new_record = try tth.recordFromValues(allocator, &.{});
    defer new_record.deinit(allocator);

    const change = subscription_engine.RecordChange{
        .namespace_id = 999,
        .table_index = (schema.table(long_coll) orelse return error.TestExpectedValue).index,
        .operation = .insert,
        .new_record = new_record,
        .old_record = null,
    };

    const matches = try engine.handleRecordChange(change, allocator);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(u64, 1), matches[0].connection_id);
    try testing.expectEqual(@as(u64, 100), matches[0].subscription_id);
}

test "SubscriptionEngine: evaluateFilter: case-insensitive contains/startsWith/endsWith" {
    const allocator = testing.allocator;

    const val = tth.valText("Al");

    var filter_starts_with = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .startsWith, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_starts_with.deinit(allocator);

    var filter_ends_with = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .endsWith, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_ends_with.deinit(allocator);

    var filter_contains = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .contains, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_contains.deinit(allocator);

    // Case-insensitive startsWith
    {
        var r = try tth.recordFromValues(allocator, &.{tth.valText("aLiCe")});
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(&filter_starts_with, &r));
    }

    // Case-insensitive endsWith
    {
        var r = try tth.recordFromValues(allocator, &.{tth.valText("reAL")});
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(&filter_ends_with, &r));
    }

    // Case-insensitive contains
    {
        var r = try tth.recordFromValues(allocator, &.{tth.valText("vALid")});
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(&filter_contains, &r));
    }
}

test "SubscriptionEngine: group sharing with different condition order" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    // Filter 1: status=A, type=B
    var filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("A"), .field_type = .text, .items_type = null },
        .{ .field_index = 4, .op = .eq, .value = tth.valText("B"), .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    // Filter 2: type=B, status=A (different order)
    var filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 4, .op = .eq, .value = tth.valText("B"), .field_type = .text, .items_type = null },
        .{ .field_index = 3, .op = .eq, .value = tth.valText("A"), .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("coll", &.{
            schema_helpers.makeField("status", .text),
            schema_helpers.makeField("type", .text),
        }),
    });
    defer schema.deinit();

    const first = try engine.subscribe(2, (schema.table("coll") orelse return error.TestExpectedValue).index, filter1, 1, 101);
    const second = try engine.subscribe(2, (schema.table("coll") orelse return error.TestExpectedValue).index, filter2, 2, 102);

    try testing.expect(first);
    try testing.expect(!second); // Should share group!

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
    try testing.expectEqual(@as(u32, 2), engine.active_subs.count());
}

test "SubscriptionEngine: canonical key includes predicate state" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter_all = try qth.makeDefaultFilter(allocator);
    defer filter_all.deinit(allocator);
    filter_all.predicate.state = .match_all;

    var filter_none = try qth.makeDefaultFilter(allocator);
    defer filter_none.deinit(allocator);
    filter_none.predicate.state = .match_none;

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("coll", &.{}),
    });
    defer schema.deinit();

    const table_index = (schema.table("coll") orelse return error.TestExpectedValue).index;
    const first = try engine.subscribe(2, table_index, filter_all, 1, 101);
    const second = try engine.subscribe(2, table_index, filter_none, 2, 102);

    try testing.expect(first);
    try testing.expect(second);
    try testing.expectEqual(@as(u32, 2), engine.groups.count());
    try testing.expectEqual(@as(u32, 2), engine.active_subs.count());
}

test "SubscriptionEngine: match-none filter never matches changes" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    filter.predicate.state = .match_none;

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("users", &.{
            schema_helpers.makeField("role", .text),
        }),
    });
    defer schema.deinit();

    const table_index = (schema.table("users") orelse return error.TestExpectedValue).index;
    _ = try engine.subscribe(1, table_index, filter, 1, 100);

    var r = try tth.recordFromValues(allocator, &.{tth.valText("admin")});
    defer r.deinit(allocator);

    const change = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = table_index,
        .operation = .insert,
        .new_record = r,
        .old_record = null,
    };

    const matches = try engine.handleRecordChange(change, allocator);
    defer allocator.free(matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
}

test "SubscriptionEngine: in/notIn operator subscribe and match" {
    const allocator = testing.allocator;

    // in operator
    {
        var engine = SubscriptionEngine.init(allocator);
        defer engine.deinit();

        const in_val = try tth.valArray(allocator, &[_]typed_types.ScalarValue{
            .{ .text = "admin" },
            .{ .text = "editor" },
        });
        defer in_val.deinit(allocator);

        var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
            .{ .field_index = 3, .op = .in, .value = in_val, .field_type = .text, .items_type = null },
        });
        defer filter.deinit(allocator);

        var schema = try sth.createSchema(allocator, &.{
            schema_helpers.makeTable("users", &.{
                schema_helpers.makeField("role", .text),
            }),
        });
        defer schema.deinit();

        _ = try engine.subscribe(1, (schema.table("users") orelse return error.TestExpectedValue).index, filter, 1, 100);

        var r = try tth.recordFromValues(allocator, &.{tth.valText("admin")});
        defer r.deinit(allocator);

        const change = subscription_engine.RecordChange{
            .namespace_id = 1,
            .table_index = (schema.table("users") orelse return error.TestExpectedValue).index,
            .operation = .insert,
            .new_record = r,
            .old_record = null,
        };

        const matches = try engine.handleRecordChange(change, allocator);
        defer allocator.free(matches);
        try testing.expectEqual(@as(usize, 1), matches.len);
    }

    // notIn operator
    {
        var engine = SubscriptionEngine.init(allocator);
        defer engine.deinit();

        const not_in_val = try tth.valArray(allocator, &[_]typed_types.ScalarValue{
            .{ .text = "guest" },
            .{ .text = "banned" },
        });
        defer not_in_val.deinit(allocator);

        var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
            .{ .field_index = 3, .op = .notIn, .value = not_in_val, .field_type = .text, .items_type = null },
        });
        defer filter.deinit(allocator);

        var schema = try sth.createSchema(allocator, &.{
            schema_helpers.makeTable("users", &.{
                schema_helpers.makeField("role", .text),
            }),
        });
        defer schema.deinit();

        _ = try engine.subscribe(1, (schema.table("users") orelse return error.TestExpectedValue).index, filter, 1, 100);

        var r = try tth.recordFromValues(allocator, &.{tth.valText("member")});
        defer r.deinit(allocator);

        const change = subscription_engine.RecordChange{
            .namespace_id = 1,
            .table_index = (schema.table("users") orelse return error.TestExpectedValue).index,
            .operation = .insert,
            .new_record = r,
            .old_record = null,
        };

        const matches = try engine.handleRecordChange(change, allocator);
        defer allocator.free(matches);
        try testing.expectEqual(@as(usize, 1), matches.len);
    }
}

test "SubscriptionEngine: unsubscribeMany" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("items", &.{
            schema_helpers.makeField("status", .text),
        }),
    });
    defer schema.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    const table_index = (schema.table("items") orelse return error.TestExpectedValue).index;
    const coll_key = subscription_engine.CollectionKey{ .namespace_id = 1, .table_index = table_index };

    // Subscribe 4 subscribers to the same group (same conn_id, different sub_ids)
    _ = try engine.subscribe(1, table_index, filter, 1, 100);
    _ = try engine.subscribe(1, table_index, filter, 1, 200);
    _ = try engine.subscribe(1, table_index, filter, 1, 300);
    _ = try engine.subscribe(1, table_index, filter, 1, 400);

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
    try testing.expectEqual(@as(u32, 4), engine.active_subs.count());

    // Unsubscribe 2 of 4: group must survive
    engine.unsubscribeMany(1, &[_]u64{ 100, 200 });
    try testing.expectEqual(@as(u32, 1), engine.groups.count());
    try testing.expectEqual(@as(u32, 2), engine.active_subs.count());
    try testing.expectEqual(@as(usize, 1), engine.groups_by_collection.get(coll_key).?.items.len);

    // Unsubscribe remaining 2: group must be torn down completely
    engine.unsubscribeMany(1, &[_]u64{ 300, 400 });
    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.groups_by_filter.count());
    try testing.expect(engine.groups_by_collection.get(coll_key) == null);
    try testing.expectEqual(@as(u32, 0), engine.active_subs.count());

    // Empty slice is a no-op
    engine.unsubscribeMany(1, &[_]u64{});

    // Non-existent IDs are no-ops
    engine.unsubscribeMany(999, &[_]u64{ 9999, 8888 });
}

test "SubscriptionEngine: getSubscriptionQuery" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("items", &.{
            schema_helpers.makeField("status", .text),
        }),
    });
    defer schema.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    const table_index = (schema.table("items") orelse return error.TestExpectedValue).index;

    _ = try engine.subscribe(1, table_index, filter, 1, 100);
    _ = try engine.subscribe(1, table_index, filter, 2, 200);

    // Existing subscriber returns valid query
    const query_opt = try engine.getSubscriptionQuery(allocator, .{ .connection_id = 1, .id = 100 });
    try testing.expect(query_opt != null);
    var query = query_opt.?;
    defer query.deinit(allocator);

    try testing.expectEqual(@as(i64, 1), query.namespace_id);
    try testing.expectEqual(table_index, query.table_index);
    try testing.expect(query.filter.predicate.conditions != null);
    try testing.expect(query.filter.predicate.conditions.?.len > 0);

    // Second subscriber also returns valid query
    const query2_opt = try engine.getSubscriptionQuery(allocator, .{ .connection_id = 2, .id = 200 });
    try testing.expect(query2_opt != null);
    var query2 = query2_opt.?;
    defer query2.deinit(allocator);

    try testing.expectEqual(@as(i64, 1), query2.namespace_id);

    // Non-existent subscriber returns null
    const missing = try engine.getSubscriptionQuery(allocator, .{ .connection_id = 99, .id = 999 });
    try testing.expect(missing == null);

    // Returned query is independent: deinit does not affect engine
    query.deinit(allocator);
    var still_valid = try engine.getSubscriptionQuery(allocator, .{ .connection_id = 1, .id = 100 });
    if (still_valid) |*q| {
        q.deinit(allocator);
    }
    try testing.expect(still_valid != null);

    // After unsubscribe, query is no longer available
    engine.unsubscribe(1, 100);
    const after_unsub = try engine.getSubscriptionQuery(allocator, .{ .connection_id = 1, .id = 100 });
    try testing.expect(after_unsub == null);

    // Remaining subscriber still works
    var still_there = try engine.getSubscriptionQuery(allocator, .{ .connection_id = 2, .id = 200 });
    if (still_there) |*q| {
        q.deinit(allocator);
    }
    try testing.expect(still_there != null);
}

test "SubscriptionEngine: multiple collections isolation" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("items", &.{
            schema_helpers.makeField("status", .text),
        }),
        schema_helpers.makeTable("orders", &.{
            schema_helpers.makeField("total", .integer),
        }),
    });
    defer schema.deinit();

    // Filter for collection A (items.status = "active")
    var filter_a = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter_a.deinit(allocator);

    // Filter for collection B (orders.total > 100)
    var filter_b = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .gt, .value = tth.valInt(100), .field_type = .integer, .items_type = null },
    });
    defer filter_b.deinit(allocator);

    const table_a = (schema.table("items") orelse return error.TestExpectedValue).index;
    const table_b = (schema.table("orders") orelse return error.TestExpectedValue).index;

    _ = try engine.subscribe(1, table_a, filter_a, 1, 100);
    _ = try engine.subscribe(1, table_a, filter_a, 2, 200);
    _ = try engine.subscribe(1, table_b, filter_b, 3, 300);

    try testing.expectEqual(@as(u32, 2), engine.groups.count());
    try testing.expectEqual(@as(u32, 3), engine.active_subs.count());

    // Change on collection A: only A's subscribers match
    var record_active = try tth.recordFromValues(allocator, &.{tth.valText("active")});
    defer record_active.deinit(allocator);

    const change_a = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = table_a,
        .operation = .insert,
        .new_record = record_active,
        .old_record = null,
    };

    const matches_a = try engine.handleRecordChange(change_a, allocator);
    defer allocator.free(matches_a);
    try testing.expectEqual(@as(usize, 2), matches_a.len);
    // Verify both collection A subscribers matched
    var found_100 = false;
    var found_200 = false;
    for (matches_a) |m| {
        if (m.connection_id == 1 and m.subscription_id == 100) found_100 = true;
        if (m.connection_id == 2 and m.subscription_id == 200) found_200 = true;
    }
    try testing.expect(found_100);
    try testing.expect(found_200);

    // Change on collection B: only B's subscribers match
    var record_high = try tth.recordFromValues(allocator, &.{tth.valInt(200)});
    defer record_high.deinit(allocator);

    const change_b = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = table_b,
        .operation = .insert,
        .new_record = record_high,
        .old_record = null,
    };

    const matches_b = try engine.handleRecordChange(change_b, allocator);
    defer allocator.free(matches_b);
    try testing.expectEqual(@as(usize, 1), matches_b.len);
    try testing.expectEqual(@as(u64, 3), matches_b[0].connection_id);
    try testing.expectEqual(@as(u64, 300), matches_b[0].subscription_id);

    // Change on collection B with non-matching record: no matches
    var record_low = try tth.recordFromValues(allocator, &.{tth.valInt(50)});
    defer record_low.deinit(allocator);

    const change_b_nomatch = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = table_b,
        .operation = .insert,
        .new_record = record_low,
        .old_record = null,
    };

    const matches_b_nomatch = try engine.handleRecordChange(change_b_nomatch, allocator);
    defer allocator.free(matches_b_nomatch);
    try testing.expectEqual(@as(usize, 0), matches_b_nomatch.len);

    // Unsubscribe collection A's last subscriber: collection A indexes cleaned, B untouched
    engine.unsubscribe(1, 100);
    engine.unsubscribe(2, 200);
    try testing.expectEqual(@as(u32, 1), engine.groups.count());
    try testing.expectEqual(@as(u32, 1), engine.active_subs.count());
}

test "SubscriptionEngine: filter removal notification when record leaves filter" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("items", &.{
            schema_helpers.makeField("priority", .integer),
        }),
    });
    defer schema.deinit();

    // Filter: priority >= 5 (user fields start at index 3)
    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .gte, .value = tth.valInt(5), .field_type = .integer, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try engine.subscribe(2, (schema.table("items") orelse return error.TestExpectedValue).index, filter, 1, 100);

    // Case 1: Record leaves filter (priority 8 -> 2)
    var old_record = try tth.recordFromValues(allocator, &.{tth.valInt(8)});
    defer old_record.deinit(allocator);
    var new_record = try tth.recordFromValues(allocator, &.{tth.valInt(2)});
    defer new_record.deinit(allocator);

    const change_leave = subscription_engine.RecordChange{
        .namespace_id = 2,
        .table_index = (schema.table("items") orelse return error.TestExpectedValue).index,
        .operation = .update,
        .new_record = new_record,
        .old_record = old_record,
    };

    const matches_leave = try engine.handleRecordChange(change_leave, allocator);
    defer allocator.free(matches_leave);
    try testing.expectEqual(@as(usize, 1), matches_leave.len);
    try testing.expectEqual(SubscriptionEngine.MatchOp.remove, matches_leave[0].op);

    // Case 2: Record enters filter (priority 2 -> 8)
    var old_record2 = try tth.recordFromValues(allocator, &.{tth.valInt(2)});
    defer old_record2.deinit(allocator);
    var new_record2 = try tth.recordFromValues(allocator, &.{tth.valInt(8)});
    defer new_record2.deinit(allocator);

    const change_enter = subscription_engine.RecordChange{
        .namespace_id = 2,
        .table_index = (schema.table("items") orelse return error.TestExpectedValue).index,
        .operation = .update,
        .new_record = new_record2,
        .old_record = old_record2,
    };

    const matches_enter = try engine.handleRecordChange(change_enter, allocator);
    defer allocator.free(matches_enter);
    try testing.expectEqual(@as(usize, 1), matches_enter.len);
    try testing.expectEqual(SubscriptionEngine.MatchOp.set_op, matches_enter[0].op);

    // Case 3: Record changes within filter (priority 6 -> 9)
    var old_record3 = try tth.recordFromValues(allocator, &.{tth.valInt(6)});
    defer old_record3.deinit(allocator);
    var new_record3 = try tth.recordFromValues(allocator, &.{tth.valInt(9)});
    defer new_record3.deinit(allocator);

    const change_within = subscription_engine.RecordChange{
        .namespace_id = 2,
        .table_index = (schema.table("items") orelse return error.TestExpectedValue).index,
        .operation = .update,
        .new_record = new_record3,
        .old_record = old_record3,
    };

    const matches_within = try engine.handleRecordChange(change_within, allocator);
    defer allocator.free(matches_within);
    try testing.expectEqual(@as(usize, 1), matches_within.len);
    try testing.expectEqual(SubscriptionEngine.MatchOp.set_op, matches_within[0].op);

    // Case 4: Record stays outside filter (priority 1 -> 3)
    var old_record4 = try tth.recordFromValues(allocator, &.{tth.valInt(1)});
    defer old_record4.deinit(allocator);
    var new_record4 = try tth.recordFromValues(allocator, &.{tth.valInt(3)});
    defer new_record4.deinit(allocator);

    const change_outside = subscription_engine.RecordChange{
        .namespace_id = 2,
        .table_index = (schema.table("items") orelse return error.TestExpectedValue).index,
        .operation = .update,
        .new_record = new_record4,
        .old_record = old_record4,
    };

    const matches_outside = try engine.handleRecordChange(change_outside, allocator);
    defer allocator.free(matches_outside);
    try testing.expectEqual(@as(usize, 0), matches_outside.len);
}
