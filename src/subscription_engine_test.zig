const std = @import("std");
const testing = std.testing;
const subscription_engine = @import("subscription_engine.zig");
const SubscriptionEngine = subscription_engine.SubscriptionEngine;
const typed = @import("typed.zig");
const sth = @import("storage_engine_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const query_ast = @import("query_ast.zig");

test "SubscriptionEngine: basic subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("items", &.{
            sth.makeField("status", .text, false),
        }),
    });
    defer sm.deinit();

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    // Subscribe
    _ = try engine.subscribe(1, (sm.getTable("items") orelse return error.TestExpectedValue).index, filter, 1, 100);

    // Create a matching record change
    var new_record = try tth.recordFromValues(allocator, &.{tth.valText("active")});
    defer new_record.deinit(allocator);

    const change = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = (sm.getTable("items") orelse return error.TestExpectedValue).index,
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

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .gt, .value = tth.valInt(18), .field_type = .integer, .items_type = null },
    });
    defer filter.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("coll", &.{
            sth.makeField("age", .integer, false),
        }),
    });
    defer sm.deinit();

    // Two different subscribers for EXACTLY the same filter
    const first = try engine.subscribe(2, (sm.getTable("coll") orelse return error.TestExpectedValue).index, filter, 1, 101);
    const second = try engine.subscribe(2, (sm.getTable("coll") orelse return error.TestExpectedValue).index, filter, 2, 102);

    try testing.expect(first); // First one should create group
    try testing.expect(!second); // Second one should join existing group

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
}

test "SubscriptionEngine: unsubscribe clean up" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .isNotNull, .value = null, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("c", &.{}),
    });
    defer sm.deinit();

    _ = try engine.subscribe(3, (sm.getTable("c") orelse return error.TestExpectedValue).index, filter, 1, 1);
    try testing.expectEqual(@as(u32, 1), engine.groups.count());

    engine.unsubscribe(1, 1);
    try testing.expectEqual(@as(u32, 0), engine.groups.count());
    try testing.expectEqual(@as(u32, 0), engine.groups_by_filter.count());
}

test "SubscriptionEngine: operator matching" {
    const allocator = testing.allocator;

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .startsWith, .value = tth.valText("Al"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var row1 = try tth.recordFromValues(allocator, &.{tth.valText("Alice")});
    defer row1.deinit(allocator);

    var row2 = try tth.recordFromValues(allocator, &.{tth.valText("Bob")});
    defer row2.deinit(allocator);

    try testing.expect(try SubscriptionEngine.evaluateFilter(filter, row1));
    try testing.expect(!try SubscriptionEngine.evaluateFilter(filter, row2));
}

test "SubscriptionEngine: canonical filter key includes values" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("inactive"), .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("items", &.{}),
    });
    defer sm.deinit();

    // Subscribe with different values
    _ = try engine.subscribe(1, (sm.getTable("items") orelse return error.TestExpectedValue).index, filter1, 1, 101);
    _ = try engine.subscribe(1, (sm.getTable("items") orelse return error.TestExpectedValue).index, filter2, 2, 102);

    // If they share the same key, they will be in the same group.
    // They SHOULD be in different groups because the values are different.
    try testing.expectEqual(@as(u32, 2), engine.groups.count());
}

test "SubscriptionEngine: canonical key distinguishes same-length array contents" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const in_val_1 = try tth.valArray(allocator, &[_]typed.ScalarValue{
        .{ .text = "a" },
    });
    defer in_val_1.deinit(allocator);
    const in_val_2 = try tth.valArray(allocator, &[_]typed.ScalarValue{
        .{ .text = "b" },
    });
    defer in_val_2.deinit(allocator);

    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .in, .value = in_val_1, .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .in, .value = in_val_2, .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("users", &.{}),
    });
    defer sm.deinit();

    _ = try engine.subscribe(1, (sm.getTable("users") orelse return error.TestExpectedValue).index, filter1, 1, 101);
    _ = try engine.subscribe(1, (sm.getTable("users") orelse return error.TestExpectedValue).index, filter2, 2, 102);

    try testing.expectEqual(@as(u32, 2), engine.groups.count());
}

test "SubscriptionEngine: canonical key keeps integer and real distinct" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const filter_int = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valInt(1), .field_type = .integer, .items_type = null },
    });
    defer filter_int.deinit(allocator);

    const filter_real = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valReal(1.0), .field_type = .real, .items_type = null },
    });
    defer filter_real.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("scores", &.{}),
    });
    defer sm.deinit();

    _ = try engine.subscribe(1, (sm.getTable("scores") orelse return error.TestExpectedValue).index, filter_int, 1, 201);
    _ = try engine.subscribe(1, (sm.getTable("scores") orelse return error.TestExpectedValue).index, filter_real, 2, 202);

    try testing.expectEqual(@as(u32, 2), engine.groups.count());
}

test "SubscriptionEngine: handleRecordChange with long namespace/collection (heap key)" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();
    const long_coll = "b" ** 150;
    // combined length (150 + 1 + 150 = 301) will be > 256 stack buffer

    const filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    const table = try sth.makeTableAlloc(allocator, long_coll, &.{});
    defer {
        allocator.free(table.name);
        allocator.free(table.name_quoted);
    }
    var sm = try sth.createSchema(allocator, &[_]sth.Table{table});
    defer sm.deinit();

    _ = try engine.subscribe(999, (sm.getTable(long_coll) orelse return error.TestExpectedValue).index, filter, 1, 100);

    var new_record = try tth.recordFromValues(allocator, &.{});
    defer new_record.deinit(allocator);

    const change = subscription_engine.RecordChange{
        .namespace_id = 999,
        .table_index = (sm.getTable(long_coll) orelse return error.TestExpectedValue).index,
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

test "SubscriptionEngine: case-insensitive string matching" {
    const allocator = testing.allocator;

    const val = tth.valText("Al");

    const filter_starts_with = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .startsWith, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_starts_with.deinit(allocator);

    const filter_ends_with = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .endsWith, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_ends_with.deinit(allocator);

    const filter_contains = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .contains, .value = val, .field_type = .text, .items_type = null },
    });
    defer filter_contains.deinit(allocator);

    // Case-insensitive startsWith
    {
        var r = try tth.recordFromValues(allocator, &.{tth.valText("aLiCe")});
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_starts_with, r));
    }

    // Case-insensitive endsWith
    {
        var r = try tth.recordFromValues(allocator, &.{tth.valText("reAL")});
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_ends_with, r));
    }

    // Case-insensitive contains
    {
        var r = try tth.recordFromValues(allocator, &.{tth.valText("vALid")});
        defer r.deinit(allocator);
        try testing.expect(try SubscriptionEngine.evaluateFilter(filter_contains, r));
    }
}

test "SubscriptionEngine: group sharing with different condition order" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    // Filter 1: status=A, type=B
    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("A"), .field_type = .text, .items_type = null },
        .{ .field_index = 4, .op = .eq, .value = tth.valText("B"), .field_type = .text, .items_type = null },
    });
    defer filter1.deinit(allocator);

    // Filter 2: type=B, status=A (different order)
    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 4, .op = .eq, .value = tth.valText("B"), .field_type = .text, .items_type = null },
        .{ .field_index = 3, .op = .eq, .value = tth.valText("A"), .field_type = .text, .items_type = null },
    });
    defer filter2.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("coll", &.{
            sth.makeField("status", .text, false),
            sth.makeField("type", .text, false),
        }),
    });
    defer sm.deinit();

    const first = try engine.subscribe(2, (sm.getTable("coll") orelse return error.TestExpectedValue).index, filter1, 1, 101);
    const second = try engine.subscribe(2, (sm.getTable("coll") orelse return error.TestExpectedValue).index, filter2, 2, 102);

    try testing.expect(first);
    try testing.expect(!second); // Should share group!

    try testing.expectEqual(@as(u32, 1), engine.groups.count());
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

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("coll", &.{}),
    });
    defer sm.deinit();

    const table_index = (sm.getTable("coll") orelse return error.TestExpectedValue).index;
    const first = try engine.subscribe(2, table_index, filter_all, 1, 101);
    const second = try engine.subscribe(2, table_index, filter_none, 2, 102);

    try testing.expect(first);
    try testing.expect(second);
    try testing.expectEqual(@as(u32, 2), engine.groups.count());
}

test "SubscriptionEngine: match-none filter never matches changes" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    filter.predicate.state = .match_none;

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("users", &.{
            sth.makeField("role", .text, false),
        }),
    });
    defer sm.deinit();

    const table_index = (sm.getTable("users") orelse return error.TestExpectedValue).index;
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

test "SubscriptionEngine: in operator subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const in_val = try tth.valArray(allocator, &[_]typed.ScalarValue{
        .{ .text = "admin" },
        .{ .text = "editor" },
    });
    defer in_val.deinit(allocator);

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .in, .value = in_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("users", &.{
            sth.makeField("role", .text, false),
        }),
    });
    defer sm.deinit();

    _ = try engine.subscribe(1, (sm.getTable("users") orelse return error.TestExpectedValue).index, filter, 1, 100);

    var r = try tth.recordFromValues(allocator, &.{tth.valText("admin")});
    defer r.deinit(allocator);

    const change = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = (sm.getTable("users") orelse return error.TestExpectedValue).index,
        .operation = .insert,
        .new_record = r,
        .old_record = null,
    };

    const matches = try engine.handleRecordChange(change, allocator);
    defer allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
}

test "SubscriptionEngine: canonical key normalizes array element order" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const in_val_1 = try tth.valArray(allocator, &[_]typed.ScalarValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    });
    defer in_val_1.deinit(allocator);
    const in_val_2 = try tth.valArray(allocator, &[_]typed.ScalarValue{
        .{ .integer = 3 },
        .{ .integer = 1 },
        .{ .integer = 2 },
    });
    defer in_val_2.deinit(allocator);

    const filter1 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 0, .op = .in, .value = in_val_1, .field_type = .integer, .items_type = null },
    });
    defer filter1.deinit(allocator);

    const filter2 = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 0, .op = .in, .value = in_val_2, .field_type = .integer, .items_type = null },
    });
    defer filter2.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("coll", &.{}),
    });
    defer sm.deinit();

    const first = try engine.subscribe(2, (sm.getTable("coll") orelse return error.TestExpectedValue).index, filter1, 1, 101);
    const second = try engine.subscribe(2, (sm.getTable("coll") orelse return error.TestExpectedValue).index, filter2, 2, 102);

    try testing.expect(first);
    try testing.expect(!second);
    try testing.expectEqual(@as(u32, 1), engine.groups.count());
}

test "SubscriptionEngine: notIn operator subscribe and match" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    const not_in_val = try tth.valArray(allocator, &[_]typed.ScalarValue{
        .{ .text = "guest" },
        .{ .text = "banned" },
    });
    defer not_in_val.deinit(allocator);

    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .notIn, .value = not_in_val, .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("users", &.{
            sth.makeField("role", .text, false),
        }),
    });
    defer sm.deinit();

    _ = try engine.subscribe(1, (sm.getTable("users") orelse return error.TestExpectedValue).index, filter, 1, 100);

    var r = try tth.recordFromValues(allocator, &.{tth.valText("member")});
    defer r.deinit(allocator);

    const change = subscription_engine.RecordChange{
        .namespace_id = 1,
        .table_index = (sm.getTable("users") orelse return error.TestExpectedValue).index,
        .operation = .insert,
        .new_record = r,
        .old_record = null,
    };

    const matches = try engine.handleRecordChange(change, allocator);
    defer allocator.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
}

test "SubscriptionEngine: filter removal notification when record leaves filter" {
    const allocator = testing.allocator;
    var engine = SubscriptionEngine.init(allocator);
    defer engine.deinit();

    var sm = try sth.createSchema(allocator, &.{
        sth.makeTable("items", &.{
            sth.makeField("priority", .integer, false),
        }),
    });
    defer sm.deinit();

    // Filter: priority >= 5 (user fields start at index 3)
    const filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .gte, .value = tth.valInt(5), .field_type = .integer, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try engine.subscribe(2, (sm.getTable("items") orelse return error.TestExpectedValue).index, filter, 1, 100);

    // Case 1: Record leaves filter (priority 8 -> 2)
    var old_record = try tth.recordFromValues(allocator, &.{tth.valInt(8)});
    defer old_record.deinit(allocator);
    var new_record = try tth.recordFromValues(allocator, &.{tth.valInt(2)});
    defer new_record.deinit(allocator);

    const change_leave = subscription_engine.RecordChange{
        .namespace_id = 2,
        .table_index = (sm.getTable("items") orelse return error.TestExpectedValue).index,
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
        .table_index = (sm.getTable("items") orelse return error.TestExpectedValue).index,
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
        .table_index = (sm.getTable("items") orelse return error.TestExpectedValue).index,
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
        .table_index = (sm.getTable("items") orelse return error.TestExpectedValue).index,
        .operation = .update,
        .new_record = new_record4,
        .old_record = old_record4,
    };

    const matches_outside = try engine.handleRecordChange(change_outside, allocator);
    defer allocator.free(matches_outside);
    try testing.expectEqual(@as(usize, 0), matches_outside.len);
}
