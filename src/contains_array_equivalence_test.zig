const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const schema = @import("schema.zig");
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const sth = @import("storage_engine_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const query_parser = @import("query_parser.zig");

fn collectResultSetIds(allocator: std.mem.Allocator, rows: []storage_engine.TypedRow, metadata: *const schema.Table) !std.AutoHashMap(storage_engine.DocId, void) {
    var ids = std.AutoHashMap(storage_engine.DocId, void).init(allocator);
    errdefer ids.deinit();
    for (rows) |row| {
        const id = sth.getFieldDocIdOrNull(row, metadata, "id") orelse continue;
        try ids.put(id, {});
    }
    return ids;
}

test "contains on array field: SQL and in-memory evaluator return same rows (text)" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("name", .text, false),
        sth.makeField("tags", .array, false),
    };
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "contains-array-text-equiv", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const items_md = ctx.sm.getTable("items") orelse return error.UnknownTable;

    const ns = 1;

    {
        const tags_tv = try tth.valArray(allocator, &.{ .{ .text = "urgent" }, .{ .text = "home" } });
        defer tags_tv.deinit(allocator);
        try ctx.insertNamed("items", 1, ns, .{
            sth.named("name", tth.valText("Task 1")),
            sth.named("tags", tags_tv),
        });
    }

    {
        const tags_tv = try tth.valArray(allocator, &.{ .{ .text = "work" }, .{ .text = "p1" } });
        defer tags_tv.deinit(allocator);
        try ctx.insertNamed("items", 2, ns, .{
            sth.named("name", tth.valText("Task 2")),
            sth.named("tags", tags_tv),
        });
    }

    {
        const tags_tv = try tth.valArray(allocator, &.{ .{ .text = "urgent" }, .{ .text = "work" } });
        defer tags_tv.deinit(allocator);
        try ctx.insertNamed("items", 3, ns, .{
            sth.named("name", tth.valText("Task 3")),
            sth.named("tags", tags_tv),
        });
    }

    {
        try ctx.insertField("items", 4, ns, "name", tth.valText("Task 4"));
    }

    try engine.flushPendingWrites();

    // --- SQL path: tags contains "urgent" ---
    var sql_filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{
            .field_index = items_md.fieldIndex("tags") orelse return error.UnknownField,
            .op = .contains,
            .value = tth.valText("urgent"),
            .field_type = .array,
            .items_type = .text,
        },
    });
    defer sql_filter.deinit(allocator);

    var sql_managed = try engine.selectQuery(allocator, items_md.index, ns, sql_filter);
    defer sql_managed.deinit();

    var sql_ids = try collectResultSetIds(allocator, sql_managed.rows, items_md);
    defer sql_ids.deinit();

    // --- In-memory path ---
    var mem_filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{
            .field_index = items_md.fieldIndex("tags") orelse return error.UnknownField,
            .op = .contains,
            .value = tth.valText("urgent"),
            .field_type = .array,
            .items_type = .text,
        },
    });
    defer mem_filter.deinit(allocator);

    var all_filter = try qth.makeDefaultFilter(allocator);
    defer all_filter.deinit(allocator);

    var all_managed = try engine.selectQuery(allocator, items_md.index, ns, all_filter);
    defer all_managed.deinit();

    var mem_ids = std.AutoHashMap(storage_engine.DocId, void).init(allocator);
    defer mem_ids.deinit();

    for (all_managed.rows) |row| {
        if (try SubscriptionEngine.evaluateFilter(mem_filter, row)) {
            const id = sth.getFieldDocIdOrNull(row, items_md, "id") orelse continue;
            try mem_ids.put(id, {});
        }
    }

    // --- Assert equivalence ---
    try testing.expectEqual(sql_ids.count(), mem_ids.count());
    var iter = sql_ids.iterator();
    while (iter.next()) |entry| {
        try testing.expect(mem_ids.contains(entry.key_ptr.*));
    }
}

test "contains on array field: SQL and in-memory evaluator return same rows (integer)" {
    const allocator = testing.allocator;

    var scores_field = sth.makeField("scores", .array, false);
    scores_field.items_type = .integer;
    var fields_arr = [_]schema.Field{
        sth.makeField("name", .text, false),
        scores_field,
    };
    const table = sth.makeTable("players", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "contains-array-int-equiv", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const players_md = ctx.sm.getTable("players") orelse return error.UnknownTable;

    const ns = 1;

    {
        const arr_tv = try tth.valArray(allocator, &.{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } });
        defer arr_tv.deinit(allocator);
        try ctx.insertNamed("players", 1, ns, .{
            sth.named("name", tth.valText("Alice")),
            sth.named("scores", arr_tv),
        });
    }

    {
        const arr_tv = try tth.valArray(allocator, &.{ .{ .integer = 5 }, .{ .integer = 15 } });
        defer arr_tv.deinit(allocator);
        try ctx.insertNamed("players", 2, ns, .{
            sth.named("name", tth.valText("Bob")),
            sth.named("scores", arr_tv),
        });
    }

    {
        const arr_tv = try tth.valArray(allocator, &.{ .{ .integer = 20 }, .{ .integer = 40 } });
        defer arr_tv.deinit(allocator);
        try ctx.insertNamed("players", 3, ns, .{
            sth.named("name", tth.valText("Carol")),
            sth.named("scores", arr_tv),
        });
    }

    try engine.flushPendingWrites();

    // --- SQL path: scores contains 20 ---
    var sql_filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{
            .field_index = players_md.fieldIndex("scores") orelse return error.UnknownField,
            .op = .contains,
            .value = tth.valInt(20),
            .field_type = .array,
            .items_type = .integer,
        },
    });
    defer sql_filter.deinit(allocator);

    var sql_managed = try engine.selectQuery(allocator, players_md.index, ns, sql_filter);
    defer sql_managed.deinit();

    var sql_ids = try collectResultSetIds(allocator, sql_managed.rows, players_md);
    defer sql_ids.deinit();

    // --- In-memory path ---
    var mem_filter = try qth.makeFilterWithConditions(allocator, &[_]query_parser.Condition{
        .{
            .field_index = players_md.fieldIndex("scores") orelse return error.UnknownField,
            .op = .contains,
            .value = tth.valInt(20),
            .field_type = .array,
            .items_type = .integer,
        },
    });
    defer mem_filter.deinit(allocator);

    var all_filter = try qth.makeDefaultFilter(allocator);
    defer all_filter.deinit(allocator);

    var all_managed = try engine.selectQuery(allocator, players_md.index, ns, all_filter);
    defer all_managed.deinit();

    var mem_ids = std.AutoHashMap(storage_engine.DocId, void).init(allocator);
    defer mem_ids.deinit();

    for (all_managed.rows) |row| {
        if (try SubscriptionEngine.evaluateFilter(mem_filter, row)) {
            const id = sth.getFieldDocIdOrNull(row, players_md, "id") orelse continue;
            try mem_ids.put(id, {});
        }
    }

    // --- Assert equivalence ---
    try testing.expectEqual(sql_ids.count(), mem_ids.count());
    var iter = sql_ids.iterator();
    while (iter.next()) |entry| {
        try testing.expect(mem_ids.contains(entry.key_ptr.*));
    }
}
