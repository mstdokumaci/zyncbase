const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_manager = @import("schema_manager.zig");
const msgpack = @import("msgpack_utils.zig");
const query_parser = @import("query_parser.zig");
const sth = @import("storage_engine_test_helpers.zig");

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

    // Query: name == "Bob"
    var filter = query_parser.QueryFilter{};
    defer filter.deinit(allocator);

    var conds = try allocator.alloc(query_parser.Condition, 1);
    conds[0] = .{
        .field = try allocator.dupe(u8, "name"),
        .op = .eq,
        .value = try msgpack.Payload.strToPayload("Bob", allocator),
    };
    filter.conditions = conds;

    var managed = try engine.selectQuery(allocator, "users", "ns", filter);
    defer managed.deinit();
    const results = managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} };

    try testing.expectEqual(@as(usize, 1), results.arr.len);
    try testing.expectEqualStrings("Bob", try getMapStr(results.arr[0], "name"));
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

    // Query: age < 30 OR age > 30, ORDER BY age DESC
    var filter = query_parser.QueryFilter{};
    defer filter.deinit(allocator);

    var or_conds = try allocator.alloc(query_parser.Condition, 2);
    or_conds[0] = .{
        .field = try allocator.dupe(u8, "age"),
        .op = .lt,
        .value = msgpack.Payload.intToPayload(30),
    };
    or_conds[1] = .{
        .field = try allocator.dupe(u8, "age"),
        .op = .gt,
        .value = msgpack.Payload.intToPayload(30),
    };
    filter.or_conditions = or_conds;
    filter.order_by = .{
        .field = try allocator.dupe(u8, "age"),
        .desc = true,
    };

    var managed = try engine.selectQuery(allocator, "users", "ns", filter);
    defer managed.deinit();
    const results = managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} };

    try testing.expectEqual(@as(usize, 2), results.arr.len);
    try testing.expectEqualStrings("Charlie", try getMapStr(results.arr[0], "name")); // 35
    try testing.expectEqualStrings("Bob", try getMapStr(results.arr[1], "name")); // 25
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
    var filter1 = query_parser.QueryFilter{};
    defer filter1.deinit(allocator);
    filter1.limit = 2;
    filter1.order_by = .{ .field = try allocator.dupe(u8, "score"), .desc = false };

    var managed1 = try engine.selectQuery(allocator, "scores", "ns", filter1);
    defer managed1.deinit();
    const res1 = managed1.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} };
    try testing.expectEqual(@as(usize, 2), res1.arr.len);
    try testing.expectEqualStrings("id1", try getMapStr(res1.arr[0], "id"));
    try testing.expectEqualStrings("id2", try getMapStr(res1.arr[1], "id"));

    // Query 2: Same query but AFTER [100, "id2"]
    var filter2 = query_parser.QueryFilter{};
    defer filter2.deinit(allocator);
    filter2.limit = 2;
    filter2.order_by = .{ .field = try allocator.dupe(u8, "score"), .desc = false };
    filter2.after = query_parser.Cursor{
        .sort_value = msgpack.Payload.intToPayload(100),
        .id = try allocator.dupe(u8, "id2"),
    };

    var managed2 = try engine.selectQuery(allocator, "scores", "ns", filter2);
    defer managed2.deinit();
    const res2 = managed2.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} };
    try testing.expectEqual(@as(usize, 2), res2.arr.len);
    try testing.expectEqualStrings("id3", try getMapStr(res2.arr[0], "id")); // 200
    try testing.expectEqualStrings("id4", try getMapStr(res2.arr[1], "id")); // 300
}

fn seedUser(allocator: std.mem.Allocator, engine: *StorageEngine, id: []const u8, name: []const u8, age: i64) !void {
    _ = allocator;
    const cols = [_]ColumnValue{
        .{ .name = "name", .value = .{ .text = name } },
        .{ .name = "age", .value = .{ .integer = age } },
    };
    try engine.insertOrReplace("users", id, "ns", &cols);
}

fn seedScore(engine: *StorageEngine, id: []const u8, score: i64) !void {
    const cols = [_]ColumnValue{
        .{ .name = "score", .value = .{ .integer = score } },
    };
    try engine.insertOrReplace("scores", id, "ns", &cols);
}

fn getMapStr(payload: msgpack.Payload, key: []const u8) ![]const u8 {
    var key_p = try msgpack.Payload.strToPayload(key, std.testing.allocator);
    defer key_p.free(std.testing.allocator);
    const val = payload.map.get(key_p) orelse return error.KeyNotFound;
    return val.str.value();
}

fn expectArrayFieldEquals(
    allocator: std.mem.Allocator,
    row: msgpack.Payload,
    field_name: []const u8,
    expected: []const []const u8,
) !void {
    var field_key = try msgpack.Payload.strToPayload(field_name, allocator);
    defer field_key.free(allocator);

    const field_val = row.map.get(field_key) orelse return error.KeyNotFound;
    try testing.expect(field_val == .arr);
    try testing.expectEqual(expected.len, field_val.arr.len);

    for (expected, field_val.arr) |exp, got| {
        try testing.expectEqualStrings(exp, got.str.value());
    }
}

fn expectMissingMapKey(
    allocator: std.mem.Allocator,
    row: msgpack.Payload,
    key_name: []const u8,
) !void {
    var key = try msgpack.Payload.strToPayload(key_name, allocator);
    defer key.free(allocator);
    try testing.expect(row.map.get(key) == null);
}

test "StorageEngine: selectQuery array projection uses schema field names for array fields" {
    const allocator = testing.allocator;

    var fields_arr = [_]schema_manager.Field{
        sth.makeField("name", .text, false),
        sth.makeField("tags", .array, false),
        sth.makeField("labels", .array, false),
    };
    const table = schema_manager.Table{ .name = "items", .fields = &fields_arr };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "query-array-projection-aliased-multi-field", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    const tags_payload = try msgpack.jsonToPayload("[\"urgent\", \"home\"]", allocator);
    defer tags_payload.free(allocator);
    const labels_payload = try msgpack.jsonToPayload("[\"work\", \"p1\"]", allocator);
    defer labels_payload.free(allocator);
    const tags_tv = try storage_engine.TypedValue.fromPayload(allocator, .array, tags_payload);
    defer tags_tv.deinit(allocator);
    const labels_tv = try storage_engine.TypedValue.fromPayload(allocator, .array, labels_payload);
    defer labels_tv.deinit(allocator);

    const cols = [_]ColumnValue{
        .{ .name = "name", .value = .{ .text = "Task 1" } },
        .{ .name = "tags", .value = tags_tv },
        .{ .name = "labels", .value = labels_tv },
    };
    try engine.insertOrReplace("items", "id1", "ns", &cols);
    try engine.flushPendingWrites();

    var filter = query_parser.QueryFilter{};
    defer filter.deinit(allocator);

    const conds = try allocator.alloc(query_parser.Condition, 1);
    conds[0] = .{
        .field = try allocator.dupe(u8, "name"),
        .op = .eq,
        .value = try msgpack.Payload.strToPayload("Task 1", allocator),
    };
    filter.conditions = conds;

    var managed = try engine.selectQuery(allocator, "items", "ns", filter);
    defer managed.deinit();

    const results = managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} };
    try testing.expectEqual(@as(usize, 1), results.arr.len);

    const row = results.arr[0];

    // Positive contract: array fields are decoded under their schema field names.
    try expectArrayFieldEquals(allocator, row, "tags", &.{ "urgent", "home" });
    try expectArrayFieldEquals(allocator, row, "labels", &.{ "work", "p1" });

    // Negative contract: raw expression names never leak into row keys.
    try expectMissingMapKey(allocator, row, "json(tags)");
    try expectMissingMapKey(allocator, row, "json(labels)");
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

    // Seed data
    const ns = "ns";
    try seedData(allocator, engine, "1", "apple");
    try seedData(allocator, engine, "2", "app%le");
    try seedData(allocator, engine, "3", "ap_le");
    try seedData(allocator, engine, "4", "a\\le");
    try engine.flushPendingWrites();

    // 1. Contains '%' - should only match "app%le", not "apple"
    {
        var filter = query_parser.QueryFilter{};
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field = try allocator.dupe(u8, "data"),
            .op = .contains,
            .value = try msgpack.Payload.strToPayload("p%l", allocator),
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = (managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} }).arr;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("2", try getMapStr(results[0], "id"));
    }

    // 2. Contains '_' - should only match "ap_le", not "apple"
    {
        var filter = query_parser.QueryFilter{};
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field = try allocator.dupe(u8, "data"),
            .op = .contains,
            .value = try msgpack.Payload.strToPayload("p_l", allocator),
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = (managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} }).arr;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("3", try getMapStr(results[0], "id"));
    }

    // 3. StartsWith 'ap_' - should only match "ap_le"
    {
        var filter = query_parser.QueryFilter{};
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field = try allocator.dupe(u8, "data"),
            .op = .startsWith,
            .value = try msgpack.Payload.strToPayload("ap_", allocator),
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = (managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} }).arr;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("3", try getMapStr(results[0], "id"));
    }

    // 4. EndsWith '%le' - should only match "app%le"
    {
        var filter = query_parser.QueryFilter{};
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field = try allocator.dupe(u8, "data"),
            .op = .endsWith,
            .value = try msgpack.Payload.strToPayload("%le", allocator),
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = (managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} }).arr;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("2", try getMapStr(results[0], "id"));
    }

    // 5. Contains '\' - should match "a\\le"
    {
        var filter = query_parser.QueryFilter{};
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);
        conds[0] = .{
            .field = try allocator.dupe(u8, "data"),
            .op = .contains,
            .value = try msgpack.Payload.strToPayload("\\", allocator),
        };
        filter.conditions = conds;
        var managed = try engine.selectQuery(allocator, "wildcards", ns, filter);
        defer managed.deinit();
        const results = (managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} }).arr;
        try testing.expectEqual(@as(usize, 1), results.len);
        try testing.expectEqualStrings("4", try getMapStr(results[0], "id"));
    }

    // 6. SQL Injection Attempt - should be treated as a literal string by parameter binding
    {
        // Add a document in a different namespace that we'll try to reach
        try seedDataInNs(allocator, engine, "5", "secret", "other_ns");
        try engine.flushPendingWrites();

        var filter = query_parser.QueryFilter{};
        defer filter.deinit(allocator);
        var conds = try allocator.alloc(query_parser.Condition, 1);

        // Malicious payload attempting to break out of the LIKE clause and OR-in a different namespace
        const malicious = "' OR namespace_id = 'other_ns' --";

        conds[0] = .{
            .field = try allocator.dupe(u8, "data"),
            .op = .contains,
            .value = try msgpack.Payload.strToPayload(malicious, allocator),
        };
        filter.conditions = conds;

        // Querying "ns" - should return 0 results because no document in "ns" has that literal string
        var managed = try engine.selectQuery(allocator, "wildcards", "ns", filter);
        defer managed.deinit();
        const results = (managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} }).arr;
        try testing.expectEqual(@as(usize, 0), results.len);
    }
}

fn seedData(allocator: std.mem.Allocator, engine: *StorageEngine, id: []const u8, data: []const u8) !void {
    try seedDataInNs(allocator, engine, id, data, "ns");
}

fn seedDataInNs(allocator: std.mem.Allocator, engine: *StorageEngine, id: []const u8, data: []const u8, namespace: []const u8) !void {
    _ = allocator;
    const cols = [_]storage_engine.ColumnValue{
        .{ .name = "data", .value = .{ .text = data } },
    };
    try engine.insertOrReplace("wildcards", id, namespace, &cols);
}
