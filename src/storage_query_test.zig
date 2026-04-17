const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_manager = @import("schema_manager.zig");
const query_parser = @import("query_parser.zig");
const sth = @import("storage_engine_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

test "StorageEngine: selectQuery basic equality" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("name", .text, false),
        sth.makeField("age", .integer, false),
    };
    const table = schema_manager.Table{ .name = "users", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-basic", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Seed data
    try seedUser(allocator, engine, "1", "Alice", 30);
    try seedUser(allocator, engine, "2", "Bob", 25);
    try seedUser(allocator, engine, "3", "Charlie", 35);
    try engine.flushPendingWrites();
    const users_md = ctx.sm.getTable("users") orelse return error.UnknownTable;
    const name_index = users_md.field_index_map.get("name") orelse return error.UnknownField;

    // Query: name == "Bob"
    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);

    var conds = try allocator.alloc(query_parser.Condition, 1);
    conds[0] = .{
        .field_index = name_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "Bob"),
        .field_type = .text,
        .items_type = null,
    };
    filter.conditions = conds;

    var managed = try engine.selectQuery(allocator, "users", "ns", filter);
    defer managed.deinit();
    const res = managed.rows;

    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expectEqualStrings("Bob", try getRowStr(res[0], users_md, "name"));
}

test "StorageEngine: selectQuery with OR and ordering" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("name", .text, false),
        sth.makeField("age", .integer, false),
    };
    const table = schema_manager.Table{ .name = "users", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-complex", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    try seedUser(allocator, engine, "1", "Alice", 30);
    try seedUser(allocator, engine, "2", "Bob", 25);
    try seedUser(allocator, engine, "3", "Charlie", 35);
    try engine.flushPendingWrites();
    const users_md = ctx.sm.getTable("users") orelse return error.UnknownTable;
    const age_index = users_md.field_index_map.get("age") orelse return error.UnknownField;

    // Query: age < 30 OR age > 30, ORDER BY age DESC
    var filter = try qth.makeFilter(allocator, 3, true, .integer, null);
    defer filter.deinit(allocator);

    var or_conds = try allocator.alloc(query_parser.Condition, 2);
    or_conds[0] = .{
        .field_index = age_index,
        .op = .lt,
        .value = tth.valInt(30),
        .field_type = .integer,
        .items_type = null,
    };
    or_conds[1] = .{
        .field_index = age_index,
        .op = .gt,
        .value = tth.valInt(30),
        .field_type = .integer,
        .items_type = null,
    };
    filter.or_conditions = or_conds;

    var managed = try engine.selectQuery(allocator, "users", "ns", filter);
    defer managed.deinit();
    const res = managed.rows;

    try testing.expectEqual(@as(usize, 2), res.len);
    try testing.expectEqualStrings("Charlie", try getRowStr(res[0], users_md, "name")); // 35
    try testing.expectEqualStrings("Bob", try getRowStr(res[1], users_md, "name")); // 25
}

test "StorageEngine: selectQuery pagination (after)" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("score", .integer, false),
    };
    const table = schema_manager.Table{ .name = "scores", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-index", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // IDs are used as secondary sort key
    try seedScore(engine, "id1", 100);
    try seedScore(engine, "id2", 100);
    try seedScore(engine, "id3", 200);
    try seedScore(engine, "id4", 300);
    try engine.flushPendingWrites();

    // Query 1: LIMIT 2, ORDER BY score ASC
    var filter1 = try qth.makeFilter(allocator, 2, false, .integer, null);
    defer filter1.deinit(allocator);
    filter1.limit = 2;

    var managed1 = try engine.selectQuery(allocator, "scores", "ns", filter1);
    defer managed1.deinit();
    const res1 = managed1.rows;
    try testing.expectEqual(@as(usize, 2), res1.len);
    const scores_md = ctx.sm.getTable("scores") orelse return error.UnknownTable;
    try testing.expectEqualStrings("id1", try getRowStr(res1[0], scores_md, "id"));
    try testing.expectEqualStrings("id2", try getRowStr(res1[1], scores_md, "id"));

    // Query 2: Same query but AFTER [100, "id2"]
    var filter2 = try qth.makeFilter(allocator, 2, false, .integer, null);
    defer filter2.deinit(allocator);
    filter2.limit = 2;
    filter2.after = query_parser.Cursor{
        .sort_value = tth.valInt(100),
        .id = try allocator.dupe(u8, "id2"),
    };

    var managed2 = try engine.selectQuery(allocator, "scores", "ns", filter2);
    defer managed2.deinit();
    const res2 = managed2.rows;
    try testing.expectEqual(@as(usize, 2), res2.len);
    try testing.expectEqualStrings("id3", try getRowStr(res2[0], scores_md, "id")); // 200
    try testing.expectEqualStrings("id4", try getRowStr(res2[1], scores_md, "id")); // 300
}

fn seedUser(allocator: std.mem.Allocator, engine: *StorageEngine, id: []const u8, name: []const u8, age: i64) !void {
    _ = allocator;
    const cols = [_]ColumnValue{
        .{ .name = "name", .value = tth.valText(name), .field_type = .text },
        .{ .name = "age", .value = tth.valInt(age), .field_type = .integer },
    };
    try engine.insertOrReplace("users", id, "ns", &cols);
}

fn seedScore(engine: *StorageEngine, id: []const u8, score: i64) !void {
    const cols = [_]ColumnValue{
        .{ .name = "score", .value = tth.valInt(score), .field_type = .integer },
    };
    try engine.insertOrReplace("scores", id, "ns", &cols);
}

fn getRowStr(row: storage_engine.TypedRow, metadata: *const schema_manager.TableMetadata, key: []const u8) ![]const u8 {
    const val = row.getField(metadata, key) orelse return error.KeyNotFound;
    return val.scalar.text;
}

fn expectArrayFieldEquals(
    row: storage_engine.TypedRow,
    metadata: *const schema_manager.TableMetadata,
    field_name: []const u8,
    expected: []const []const u8,
) !void {
    const field_val = row.getField(metadata, field_name) orelse return error.KeyNotFound;
    try testing.expect(field_val == .array);
    try testing.expectEqual(expected.len, field_val.array.len);

    for (expected, field_val.array) |exp, got| {
        try testing.expectEqualStrings(exp, got.text);
    }
}

fn expectMissingRowKey(
    row: storage_engine.TypedRow,
    metadata: *const schema_manager.TableMetadata,
    key_name: []const u8,
) !void {
    try testing.expect(row.getField(metadata, key_name) == null);
}

test "StorageEngine: selectQuery array projection uses schema field names for array fields" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("name", .text, false),
        schema_manager.Field{ .name = "tags", .sql_type = .array, .items_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null },
        schema_manager.Field{ .name = "labels", .sql_type = .array, .items_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null },
    };
    const table = schema_manager.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-array-projection-aliased-multi-field", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    const tags_tv = try tth.valArray(allocator, &.{ .{ .text = "urgent" }, .{ .text = "home" } });
    defer tags_tv.deinit(allocator);
    const labels_tv = try tth.valArray(allocator, &.{ .{ .text = "work" }, .{ .text = "p1" } });
    defer labels_tv.deinit(allocator);

    const cols = [_]ColumnValue{
        .{ .name = "name", .value = tth.valText("Task 1"), .field_type = .text },
        .{ .name = "tags", .value = tags_tv, .field_type = .array },
        .{ .name = "labels", .value = labels_tv, .field_type = .array },
    };
    try engine.insertOrReplace("items", "id1", "ns", &cols);
    try engine.flushPendingWrites();
    const items_md = ctx.sm.getTable("items") orelse return error.UnknownTable;
    const name_index = items_md.field_index_map.get("name") orelse return error.UnknownField;

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);

    const conds = try allocator.alloc(query_parser.Condition, 1);
    conds[0] = .{
        .field_index = name_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "Task 1"),
        .field_type = .text,
        .items_type = null,
    };
    filter.conditions = conds;

    var managed = try engine.selectQuery(allocator, "items", "ns", filter);
    defer managed.deinit();

    const res = managed.rows;
    try testing.expectEqual(@as(usize, 1), res.len);

    const row = res[0];

    // Positive contract: array fields are decoded under their schema field names.
    try expectArrayFieldEquals(row, items_md, "tags", &.{ "home", "urgent" });
    try expectArrayFieldEquals(row, items_md, "labels", &.{ "p1", "work" });

    // Negative contract: raw expression names never leak into row keys.
    try expectMissingRowKey(row, items_md, "json(tags)");
    try expectMissingRowKey(row, items_md, "json(labels)");
}

test "StorageEngine: LIKE wildcard escaping" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("data", .text, false),
    };
    const table = schema_manager.Table{ .name = "wildcards", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-wildcard-escape", table);
    defer ctx.deinit();
    const engine = &ctx.engine;
    const wildcards_md = ctx.sm.getTable("wildcards") orelse return error.UnknownTable;
    const data_index = wildcards_md.field_index_map.get("data") orelse return error.UnknownField;

    // Seed data
    const ns = "ns";
    try seedData(allocator, engine, "1", "apple");
    try seedData(allocator, engine, "2", "app%le");
    try seedData(allocator, engine, "3", "ap_le");
    try seedData(allocator, engine, "4", "a\\le");
    try engine.flushPendingWrites();

    // 1. Contains '%' - should only match "app%le", not "apple"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, "p%l"),
            .field_type = .text,
            .items_type = null,
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = managed.rows;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("2", try getRowStr(results[0], wildcards_md, "id"));
    }

    // 2. Contains '_' - should only match "ap_le", not "apple"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, "p_l"),
            .field_type = .text,
            .items_type = null,
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = managed.rows;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("3", try getRowStr(results[0], wildcards_md, "id"));
    }

    // 3. StartsWith 'ap_' - should only match "ap_le"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .startsWith,
            .value = try tth.valTextOwned(allocator, "ap_"),
            .field_type = .text,
            .items_type = null,
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = managed.rows;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("3", try getRowStr(results[0], wildcards_md, "id"));
    }

    // 4. EndsWith '%le' - should only match "app%le"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .endsWith,
            .value = try tth.valTextOwned(allocator, "%le"),
            .field_type = .text,
            .items_type = null,
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = managed.rows;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("2", try getRowStr(results[0], wildcards_md, "id"));
    }

    // 5. Contains '\' - should match "a\\le"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, "\\"),
            .field_type = .text,
            .items_type = null,
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = managed.rows;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("4", try getRowStr(results[0], wildcards_md, "id"));
    }

    // 6. SQL Injection Attempt - should be treated as a literal string by parameter binding
    {
        // Add a document in a different namespace that we'll try to reach
        try seedDataInNs(allocator, engine, "5", "secret", "other_ns");
        try engine.flushPendingWrites();

        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);

        // Malicious payload attempting to break out of the LIKE clause and OR-in a different namespace
        const malicious = "' OR namespace_id = 'other_ns' --";

        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, malicious),
            .field_type = .text,
            .items_type = null,
        };
        filter.conditions = conds;

        // Querying "ns" - should return 0 results because no document in "ns" has that literal string
        var managed = try engine.selectQuery(allocator, "wildcards", "ns", filter);
        defer managed.deinit();
        const results = managed.rows;
        try testing.expectEqual(@as(usize, 0), results.len);
    }
}

fn seedData(allocator: std.mem.Allocator, engine: *StorageEngine, id: []const u8, data: []const u8) !void {
    try seedDataInNs(allocator, engine, id, data, "ns");
}

fn seedDataInNs(allocator: std.mem.Allocator, engine: *StorageEngine, id: []const u8, data: []const u8, namespace: []const u8) !void {
    _ = allocator;
    const cols = [_]storage_engine.ColumnValue{
        .{ .name = "data", .value = tth.valText(data), .field_type = .text },
    };
    try engine.insertOrReplace("wildcards", id, namespace, &cols);
}
