const std = @import("std");
const testing = std.testing;
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
    const users = try ctx.table("users");

    // Seed data
    try seedUser(allocator, users, "1", "Alice", 30);
    try seedUser(allocator, users, "2", "Bob", 25);
    try seedUser(allocator, users, "3", "Charlie", 35);
    try users.flush();
    const name_index = try users.fieldIndex("name");

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
    _ = try sth.expectFieldString(res[0], users.metadata, "name", "Bob");
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
    const users = try ctx.table("users");

    try seedUser(allocator, users, "1", "Alice", 30);
    try seedUser(allocator, users, "2", "Bob", 25);
    try seedUser(allocator, users, "3", "Charlie", 35);
    try users.flush();
    const age_index = try users.fieldIndex("age");

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
    _ = try sth.expectFieldString(res[0], users.metadata, "name", "Charlie"); // 35
    _ = try sth.expectFieldString(res[1], users.metadata, "name", "Bob"); // 25
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
    const scores = try ctx.table("scores");

    // IDs are used as secondary sort key
    try seedScore(scores, "id1", 100);
    try seedScore(scores, "id2", 100);
    try seedScore(scores, "id3", 200);
    try seedScore(scores, "id4", 300);
    try scores.flush();

    // Query 1: LIMIT 2, ORDER BY score ASC
    var filter1 = try qth.makeFilter(allocator, 2, false, .integer, null);
    defer filter1.deinit(allocator);
    filter1.limit = 2;

    var managed1 = try engine.selectQuery(allocator, "scores", "ns", filter1);
    defer managed1.deinit();
    const res1 = managed1.rows;
    try testing.expectEqual(@as(usize, 2), res1.len);
    _ = try sth.expectFieldString(res1[0], scores.metadata, "id", "id1");
    _ = try sth.expectFieldString(res1[1], scores.metadata, "id", "id2");

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
    _ = try sth.expectFieldString(res2[0], scores.metadata, "id", "id3"); // 200
    _ = try sth.expectFieldString(res2[1], scores.metadata, "id", "id4"); // 300
}

fn seedUser(allocator: std.mem.Allocator, users: sth.TableFixture, id: []const u8, name: []const u8, age: i64) !void {
    _ = allocator;
    try users.insertNamed(id, "ns", .{
        sth.named("name", tth.valText(name)),
        sth.named("age", tth.valInt(age)),
    });
}

fn seedScore(scores: sth.TableFixture, id: []const u8, score: i64) !void {
    try scores.insertInt(id, "ns", "score", score);
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
    const items = try ctx.table("items");

    const tags_tv = try tth.valArray(allocator, &.{ .{ .text = "urgent" }, .{ .text = "home" } });
    defer tags_tv.deinit(allocator);
    const labels_tv = try tth.valArray(allocator, &.{ .{ .text = "work" }, .{ .text = "p1" } });
    defer labels_tv.deinit(allocator);

    try items.insertNamed("id1", "ns", .{
        sth.named("name", tth.valText("Task 1")),
        sth.named("tags", tags_tv),
        sth.named("labels", labels_tv),
    });
    try items.flush();
    const name_index = try items.fieldIndex("name");

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
    try sth.expectFieldTextArray(row, items.metadata, "tags", &.{ "home", "urgent" });
    try sth.expectFieldTextArray(row, items.metadata, "labels", &.{ "p1", "work" });

    // Negative contract: raw expression names never leak into row keys.
    try sth.expectMissingField(row, items.metadata, "json(tags)");
    try sth.expectMissingField(row, items.metadata, "json(labels)");
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
    const wildcards = try ctx.table("wildcards");
    const data_index = try wildcards.fieldIndex("data");

    // Seed data
    const ns = "ns";
    try seedData(allocator, wildcards, "1", "apple");
    try seedData(allocator, wildcards, "2", "app%le");
    try seedData(allocator, wildcards, "3", "ap_le");
    try seedData(allocator, wildcards, "4", "a\\le");
    try wildcards.flush();

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
        _ = try sth.expectFieldString(results[0], wildcards.metadata, "id", "2");
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
        _ = try sth.expectFieldString(results[0], wildcards.metadata, "id", "3");
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
        _ = try sth.expectFieldString(results[0], wildcards.metadata, "id", "3");
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
        _ = try sth.expectFieldString(results[0], wildcards.metadata, "id", "2");
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
        _ = try sth.expectFieldString(results[0], wildcards.metadata, "id", "4");
    }

    // 6. SQL Injection Attempt - should be treated as a literal string by parameter binding
    {
        // Add a document in a different namespace that we'll try to reach
        try seedDataInNs(allocator, wildcards, "5", "secret", "other_ns");
        try wildcards.flush();

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

fn seedData(allocator: std.mem.Allocator, wildcards: sth.TableFixture, id: []const u8, data: []const u8) !void {
    try seedDataInNs(allocator, wildcards, id, data, "ns");
}

fn seedDataInNs(allocator: std.mem.Allocator, wildcards: sth.TableFixture, id: []const u8, data: []const u8, namespace: []const u8) !void {
    _ = allocator;
    try wildcards.insertText(id, namespace, "data", data);
}
