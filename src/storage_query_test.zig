const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const ddl_generator = @import("ddl_generator.zig");
const msgpack = @import("msgpack_utils.zig");
const query_parser = @import("query_parser.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const schema_helpers = @import("schema_test_helpers.zig");

fn makeField(name: []const u8, sql_type: schema_manager.FieldType, required: bool) schema_manager.Field {
    return .{
        .name = name,
        .sql_type = sql_type,
        .required = required,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

fn initTestTable(allocator: std.mem.Allocator, name: []const u8, fields: []schema_manager.Field) !schema_manager.Table {
    _ = allocator;
    return schema_manager.Table{ .name = name, .fields = fields };
}

const EngineTestContext = struct {
    engine: *StorageEngine,
    sm: *SchemaManager,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const EngineTestContext) void {
        self.engine.deinit();
        self.sm.deinit();
    }
};

fn setupEngine(allocator: std.mem.Allocator, memory_strategy: *MemoryStrategy, test_dir: []const u8, table: schema_manager.Table) !EngineTestContext {
    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = try table.clone(allocator);
    const schema = try allocator.create(schema_manager.Schema);
    schema.* = .{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };
    const sm = try SchemaManager.initWithSchema(allocator, schema.*);
    allocator.destroy(schema);

    const engine = try StorageEngine.init(allocator, memory_strategy, test_dir, sm, .{}, .{ .in_memory = true });

    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.writer_conn.execMulti(ddl_z, .{});

    return .{ .engine = engine, .sm = sm, .allocator = allocator };
}

test "StorageEngine: selectQuery basic equality" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-query-basic");
    defer context.deinit();

    var fields_arr = [_]schema_manager.Field{
        makeField("name", .text, false),
        makeField("age", .integer, false),
    };
    const table = try initTestTable(allocator, "users", &fields_arr);
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, context.test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

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
    var context = try schema_helpers.TestContext.init(allocator, "engine-query-or");
    defer context.deinit();

    var fields_arr = [_]schema_manager.Field{
        makeField("name", .text, false),
        makeField("age", .integer, false),
    };
    const table = schema_manager.Table{ .name = "users", .fields = &fields_arr };
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, context.test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

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
    var context = try schema_helpers.TestContext.init(allocator, "engine-query-page");
    defer context.deinit();

    var fields_arr = [_]schema_manager.Field{
        makeField("score", .integer, false),
    };
    const table = try initTestTable(allocator, "scores", &fields_arr);
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, context.test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

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
    const name_p = try msgpack.Payload.strToPayload(name, allocator);
    defer name_p.free(allocator);
    const cols = [_]ColumnValue{
        .{ .name = "name", .value = name_p },
        .{ .name = "age", .value = msgpack.Payload.intToPayload(age) },
    };
    try engine.insertOrReplace("users", id, "ns", &cols);
}

fn seedScore(engine: *StorageEngine, id: []const u8, score: i64) !void {
    const cols = [_]ColumnValue{
        .{ .name = "score", .value = msgpack.Payload.intToPayload(score) },
    };
    try engine.insertOrReplace("scores", id, "ns", &cols);
}

fn getMapStr(payload: msgpack.Payload, key: []const u8) ![]const u8 {
    var key_p = try msgpack.Payload.strToPayload(key, std.testing.allocator);
    defer key_p.free(std.testing.allocator);
    const val = payload.map.get(key_p) orelse return error.KeyNotFound;
    return val.str.value();
}

test "StorageEngine: LIKE wildcard escaping" {
    const allocator = testing.allocator;
    var context = try schema_helpers.TestContext.init(allocator, "engine-wildcard-escape");
    defer context.deinit();

    var fields_arr = [_]schema_manager.Field{
        makeField("data", .text, false),
    };
    const table = try initTestTable(allocator, "wildcards", &fields_arr);
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();
    const ctx = try setupEngine(allocator, &memory_strategy, context.test_dir, table);
    defer ctx.deinit();
    const engine = ctx.engine;

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
    const data_p = try msgpack.Payload.strToPayload(data, allocator);
    defer data_p.free(allocator);
    const cols = [_]storage_engine.ColumnValue{
        .{ .name = "data", .value = data_p },
    };
    try engine.insertOrReplace("wildcards", id, namespace, &cols);
}
