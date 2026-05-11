const std = @import("std");
const testing = std.testing;
const schema = @import("schema.zig");
const query_ast = @import("query_ast.zig");
const typed = @import("typed.zig");
const sth = @import("storage_engine_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

test "StorageEngine: selectQuery basic equality" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("name", .text, false),
        sth.makeField("age", .integer, false),
    };
    const table = sth.makeTable("people", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-basic", table);
    defer ctx.deinit();
    const people = try ctx.table("people");

    // Seed data
    try seedPerson(allocator, people, 1, "Alice", 30);
    try seedPerson(allocator, people, 2, "Bob", 25);
    try seedPerson(allocator, people, 3, "Charlie", 35);
    try people.flush();
    const name_index = try people.fieldIndex("name");

    // Query: name == "Bob"
    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);

    var conds = try allocator.alloc(query_ast.Condition, 1);
    conds[0] = .{
        .field_index = name_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "Bob"),
        .field_type = .text,
        .items_type = null,
    };
    filter.predicate.conditions = conds;

    var managed = try people.selectQuery(allocator, 1, &filter);
    defer managed.deinit();
    const res = managed.records;

    try testing.expectEqual(@as(usize, 1), res.len);
    _ = try sth.expectFieldString(res[0], people.metadata, "name", "Bob");
}

test "StorageEngine: selectQuery match-none predicate returns empty result" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("name", .text, false),
    };
    const table = sth.makeTable("people", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-match-none", table);
    defer ctx.deinit();
    const people = try ctx.table("people");

    try people.insertText(1, 1, "name", "Alice");
    try people.flush();

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    filter.predicate.state = .match_none;

    var managed = try people.selectQuery(allocator, 1, &filter);
    defer managed.deinit();

    try testing.expectEqual(@as(usize, 0), managed.records.len);
}

test "StorageEngine: match-none guard permits insert branch and blocks update branch" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("title", .text, false),
    };
    const table = sth.makeTable("tasks", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "guard-match-none-upsert", table);
    defer ctx.deinit();
    const tasks = try ctx.table("tasks");
    const title_index = try tasks.fieldIndex("title");
    const guard = query_ast.FilterPredicate{ .state = .match_none };

    var insert_columns = [_]sth.ColumnValue{.{
        .index = title_index,
        .value = tth.valText("first"),
    }};
    try ctx.engine.insertOrReplace(table.index, 1, 1, 1, &insert_columns, &guard);
    try tasks.flush();

    {
        var doc = try tasks.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("title", "first");
    }

    var update_columns = [_]sth.ColumnValue{.{
        .index = title_index,
        .value = tth.valText("second"),
    }};
    try ctx.engine.insertOrReplace(table.index, 1, 1, 1, &update_columns, &guard);
    try tasks.flush();

    var doc = try tasks.getOne(allocator, 1, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("title", "first");
}

test "StorageEngine: selectQuery with OR and ordering" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("name", .text, false),
        sth.makeField("age", .integer, false),
    };
    const table = sth.makeTable("people", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-complex", table);
    defer ctx.deinit();
    const people = try ctx.table("people");

    try seedPerson(allocator, people, 1, "Alice", 30);
    try seedPerson(allocator, people, 2, "Bob", 25);
    try seedPerson(allocator, people, 3, "Charlie", 35);
    try people.flush();
    const age_index = try people.fieldIndex("age");

    // Query: age < 30 OR age > 30, ORDER BY age DESC
    var filter = try qth.makeFilter(allocator, 3, true, .integer, null);
    defer filter.deinit(allocator);

    var or_conds = try allocator.alloc(query_ast.Condition, 2);
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
    filter.predicate.or_conditions = or_conds;

    var managed = try people.selectQuery(allocator, 1, &filter);
    defer managed.deinit();
    const res = managed.records;

    try testing.expectEqual(@as(usize, 2), res.len);
    _ = try sth.expectFieldString(res[0], people.metadata, "name", "Charlie"); // 35
    _ = try sth.expectFieldString(res[1], people.metadata, "name", "Bob"); // 25
}

test "StorageEngine: selectQuery combines AND conditions with OR group" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("priority", .text, false),
        sth.makeField("status", .text, false),
    };
    const table = sth.makeTable("tasks", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-and-or", table);
    defer ctx.deinit();
    const tasks = try ctx.table("tasks");

    try tasks.insertNamed(1, 1, .{ sth.named("priority", tth.valText("high")), sth.named("status", tth.valText("active")) });
    try tasks.insertNamed(2, 1, .{ sth.named("priority", tth.valText("low")), sth.named("status", tth.valText("active")) });
    try tasks.insertNamed(3, 1, .{ sth.named("priority", tth.valText("high")), sth.named("status", tth.valText("pending")) });
    try tasks.insertNamed(4, 1, .{ sth.named("priority", tth.valText("high")), sth.named("status", tth.valText("closed")) });
    try tasks.flush();

    const priority_index = try tasks.fieldIndex("priority");
    const status_index = try tasks.fieldIndex("status");

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);

    const conds = try allocator.alloc(query_ast.Condition, 1);
    conds[0] = .{
        .field_index = priority_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "high"),
        .field_type = .text,
        .items_type = null,
    };
    filter.predicate.conditions = conds;

    const or_conds = try allocator.alloc(query_ast.Condition, 2);
    or_conds[0] = .{
        .field_index = status_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "active"),
        .field_type = .text,
        .items_type = null,
    };
    or_conds[1] = .{
        .field_index = status_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "pending"),
        .field_type = .text,
        .items_type = null,
    };
    filter.predicate.or_conditions = or_conds;

    var managed = try tasks.selectQuery(allocator, 1, &filter);
    defer managed.deinit();
    const res = managed.records;

    try testing.expectEqual(@as(usize, 2), res.len);
    _ = try sth.expectFieldDocId(res[0], tasks.metadata, "id", 1);
    _ = try sth.expectFieldDocId(res[1], tasks.metadata, "id", 3);
}

test "StorageEngine: selectQuery pagination (after)" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("score", .integer, false),
    };
    const table = sth.makeTable("scores", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-index", table);
    defer ctx.deinit();
    const scores = try ctx.table("scores");

    // IDs are used as secondary sort key
    try seedScore(scores, 1, 100);
    try seedScore(scores, 2, 100);
    try seedScore(scores, 3, 200);
    try seedScore(scores, 4, 300);
    try scores.flush();

    // Query 1: LIMIT 2, ORDER BY score ASC
    const score_index = try scores.fieldIndex("score");
    var filter1 = try qth.makeFilter(allocator, score_index, false, .integer, null);
    defer filter1.deinit(allocator);
    filter1.limit = 2;

    var managed1 = try scores.selectQuery(allocator, 1, &filter1);
    defer managed1.deinit();
    const res1 = managed1.records;
    try testing.expectEqual(@as(usize, 2), res1.len);
    _ = try sth.expectFieldDocId(res1[0], scores.metadata, "id", 1);
    _ = try sth.expectFieldDocId(res1[1], scores.metadata, "id", 2);

    // Query 2: Same query but AFTER [100, 2]
    var filter2 = try qth.makeFilter(allocator, score_index, false, .integer, null);
    defer filter2.deinit(allocator);
    filter2.limit = 2;
    filter2.after = typed.Cursor{
        .sort_value = tth.valInt(100),
        .id = 2,
    };

    var managed2 = try scores.selectQuery(allocator, 1, &filter2);
    defer managed2.deinit();
    const res2 = managed2.records;
    try testing.expectEqual(@as(usize, 2), res2.len);
    _ = try sth.expectFieldDocId(res2[0], scores.metadata, "id", 3); // 200
    _ = try sth.expectFieldDocId(res2[1], scores.metadata, "id", 4); // 300
}

fn seedPerson(allocator: std.mem.Allocator, people: sth.TableFixture, id: u128, name: []const u8, age: i64) !void {
    _ = allocator;
    try people.insertNamed(id, 1, .{
        sth.named("name", tth.valText(name)),
        sth.named("age", tth.valInt(age)),
    });
}

fn seedScore(scores: sth.TableFixture, id: u128, score: i64) !void {
    try scores.insertInt(id, 1, "score", score);
}

test "StorageEngine: selectQuery array projection uses schema field names for array fields" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema.Field{
        sth.makeField("name", .text, false),
        sth.makeField("tags", .array, false),
        sth.makeField("labels", .array, false),
    };
    const table = sth.makeTable("items", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-array-projection-aliased-multi-field", table);
    defer ctx.deinit();
    const items = try ctx.table("items");

    const tags_tv = try tth.valArray(allocator, &.{ .{ .text = "urgent" }, .{ .text = "home" } });
    defer tags_tv.deinit(allocator);
    const labels_tv = try tth.valArray(allocator, &.{ .{ .text = "work" }, .{ .text = "p1" } });
    defer labels_tv.deinit(allocator);

    try items.insertNamed(1, 1, .{
        sth.named("name", tth.valText("Task 1")),
        sth.named("tags", tags_tv),
        sth.named("labels", labels_tv),
    });
    try items.flush();
    const name_index = try items.fieldIndex("name");

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);

    const conds = try allocator.alloc(query_ast.Condition, 1);
    conds[0] = .{
        .field_index = name_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "Task 1"),
        .field_type = .text,
        .items_type = null,
    };
    filter.predicate.conditions = conds;

    var managed = try items.selectQuery(allocator, 1, &filter);
    defer managed.deinit();

    const res = managed.records;
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

    var fields_arr = [_]schema.Field{
        sth.makeField("data", .text, false),
    };
    const table = sth.makeTable("wildcards", &fields_arr);
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "engine-wildcard-escape", table);
    defer ctx.deinit();
    const wildcards = try ctx.table("wildcards");
    const data_index = try wildcards.fieldIndex("data");

    // Seed data
    const ns = 1;
    try seedData(allocator, wildcards, 1, "apple");
    try seedData(allocator, wildcards, 2, "app%le");
    try seedData(allocator, wildcards, 3, "ap_le");
    try seedData(allocator, wildcards, 4, "a\\le");
    try wildcards.flush();

    // 1. Contains '%' - should only match "app%le", not "apple"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_ast.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, "p%l"),
            .field_type = .text,
            .items_type = null,
        };
        filter.predicate.conditions = conds;
        var managed = try wildcards.selectQuery(allocator, ns, &filter);
        defer managed.deinit();
        const results = managed.records;
        try testing.expectEqual(@as(usize, 1), results.len);
        _ = try sth.expectFieldDocId(results[0], wildcards.metadata, "id", 2);
    }

    // 2. Contains '_' - should only match "ap_le", not "apple"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_ast.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, "p_l"),
            .field_type = .text,
            .items_type = null,
        };
        filter.predicate.conditions = conds;
        var managed = try wildcards.selectQuery(allocator, ns, &filter);
        defer managed.deinit();
        const results = managed.records;
        try testing.expectEqual(@as(usize, 1), results.len);
        _ = try sth.expectFieldDocId(results[0], wildcards.metadata, "id", 3);
    }

    // 3. StartsWith 'ap_' - should only match "ap_le"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_ast.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .startsWith,
            .value = try tth.valTextOwned(allocator, "ap_"),
            .field_type = .text,
            .items_type = null,
        };
        filter.predicate.conditions = conds;
        var managed = try wildcards.selectQuery(allocator, ns, &filter);
        defer managed.deinit();
        const results = managed.records;
        try testing.expectEqual(@as(usize, 1), results.len);
        _ = try sth.expectFieldDocId(results[0], wildcards.metadata, "id", 3);
    }

    // 4. EndsWith '%le' - should only match "app%le"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_ast.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .endsWith,
            .value = try tth.valTextOwned(allocator, "%le"),
            .field_type = .text,
            .items_type = null,
        };
        filter.predicate.conditions = conds;
        var managed = try wildcards.selectQuery(allocator, ns, &filter);
        defer managed.deinit();
        const results = managed.records;
        try testing.expectEqual(@as(usize, 1), results.len);
        _ = try sth.expectFieldDocId(results[0], wildcards.metadata, "id", 2);
    }

    // 5. Contains '\' - should match "a\\le"
    {
        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_ast.Condition, 1);
        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, "\\"),
            .field_type = .text,
            .items_type = null,
        };
        filter.predicate.conditions = conds;
        var managed = try wildcards.selectQuery(allocator, ns, &filter);
        defer managed.deinit();
        const results = managed.records;
        try testing.expectEqual(@as(usize, 1), results.len);
        _ = try sth.expectFieldDocId(results[0], wildcards.metadata, "id", 4);
    }

    // 6. SQL Injection Attempt - should be treated as a literal string by parameter binding
    {
        // Add a document in a different namespace that we'll try to reach
        try seedDataInNs(allocator, wildcards, 5, "secret", 2);
        try wildcards.flush();

        var filter = try qth.makeDefaultFilter(allocator);
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_ast.Condition, 1);

        // Malicious payload attempting to break out of the LIKE clause and OR-in a different namespace
        const malicious = "' OR namespace_id = 'other_ns' --";

        conds[0] = .{
            .field_index = data_index,
            .op = .contains,
            .value = try tth.valTextOwned(allocator, malicious),
            .field_type = .text,
            .items_type = null,
        };
        filter.predicate.conditions = conds;

        // Querying "ns" - should return 0 results because no document in "ns" has that literal string
        var managed = try wildcards.selectQuery(allocator, 1, &filter);
        defer managed.deinit();
        const results = managed.records;
        try testing.expectEqual(@as(usize, 0), results.len);
    }
}

fn seedData(allocator: std.mem.Allocator, wildcards: sth.TableFixture, id: u128, data: []const u8) !void {
    try seedDataInNs(allocator, wildcards, id, data, 1);
}

fn seedDataInNs(allocator: std.mem.Allocator, wildcards: sth.TableFixture, id: u128, data: []const u8, namespace_id: i64) !void {
    _ = allocator;
    try wildcards.insertText(id, namespace_id, "data", data);
}
