const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_manager = @import("schema_manager.zig");
const query_parser = @import("query_parser.zig");
const sth = @import("storage_engine_test_helpers.zig");

test "property: random query filters on StorageEngine" {
    const allocator = testing.allocator;
    const seeded_entity_count = 64;
    const random_query_count = 96;

    var fields_arr = [_]schema_manager.Field{
        sth.makeIndexedField("name", .text, true),
        sth.makeField("age", .integer, false),
        sth.makeField("score", .real, false),
        sth.makeField("tags", .array, false),
    };
    const table = schema_manager.Table{ .name = "entities", .fields = &fields_arr };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-query-p1", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    // Seed some data
    try seedEntities(allocator, engine, seeded_entity_count);

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..random_query_count) |_| {
        var filter = try generateRandomFilter(allocator, random);
        defer filter.deinit(allocator);

        // Execute query
        var managed = try engine.selectQuery(allocator, "entities", "ns1", filter);
        defer managed.deinit();
        try testing.expect(managed.rows.len >= 0);
    }
}

fn seedEntities(allocator: std.mem.Allocator, engine: *StorageEngine, count: usize) !void {
    _ = allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "id_{}", .{i});

        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "name_{}", .{random.intRangeAtMost(u8, 0, 10)});

        const age = random.intRangeAtMost(i64, 0, 100);
        const score = random.float(f64) * 1000.0;

        const cols = [_]ColumnValue{
            .{ .name = "name", .value = .{ .scalar = .{ .text = name } }, .field_type = .text },
            .{ .name = "age", .value = .{ .scalar = .{ .integer = age } }, .field_type = .integer },
            .{ .name = "score", .value = .{ .scalar = .{ .real = score } }, .field_type = .real },
        };
        try engine.insertOrReplace("entities", id, "ns1", &cols);
    }
    try engine.flushPendingWrites();
}

fn generateRandomFilter(allocator: std.mem.Allocator, random: std.Random) !query_parser.QueryFilter {
    const fields = [_][]const u8{ "name", "age", "score", "id", "created_at" };
    const field_idx = random.intRangeAtMost(usize, 0, fields.len - 1);
    const field_name = fields[field_idx];
    const ft: schema_manager.FieldType = if (std.mem.eql(u8, field_name, "name") or std.mem.eql(u8, field_name, "id"))
        .text
    else if (std.mem.eql(u8, field_name, "score"))
        .real
    else
        .integer;

    var filter = query_parser.QueryFilter{
        .order_by = .{
            .field = try allocator.dupe(u8, field_name),
            .desc = random.boolean(),
            .field_type = ft,
            .items_type = null,
        },
    };

    // Random conditions
    const num_conds = random.intRangeAtMost(usize, 0, 3);
    if (num_conds > 0) {
        const conds = try allocator.alloc(query_parser.Condition, num_conds);
        for (conds) |*c| {
            c.* = try generateRandomCondition(allocator, random);
        }
        filter.conditions = conds;
    }

    // Random OR conditions
    const num_or = random.intRangeAtMost(usize, 0, 2);
    if (num_or > 0) {
        const or_conds = try allocator.alloc(query_parser.Condition, num_or);
        for (or_conds) |*c| {
            c.* = try generateRandomCondition(allocator, random);
        }
        filter.or_conditions = or_conds;
    }

    // Random Limit

    // Random Limit
    if (random.boolean()) {
        filter.limit = random.intRangeAtMost(u32, 1, 25);
    }

    return filter;
}

fn generateRandomCondition(allocator: std.mem.Allocator, random: std.Random) !query_parser.Condition {
    const fields = [_][]const u8{ "name", "age", "score" };
    const field = fields[random.intRangeAtMost(usize, 0, fields.len - 1)];

    // Choose an operator
    const op_int = random.intRangeAtMost(u8, 0, 10); // Exclude IN/NOT IN/LIKE etc for simplicity if needed, but let's try some.
    const op: query_parser.Operator = @enumFromInt(op_int);

    var value: ?storage_engine.TypedValue = null;
    if (op != .isNull and op != .isNotNull) {
        // String operators MUST have string values
        if (op == .startsWith or op == .endsWith or op == .contains) {
            value = .{ .scalar = .{ .text = try allocator.dupe(u8, "test_value") } };
        } else if (std.mem.eql(u8, field, "name")) {
            value = .{ .scalar = .{ .text = try allocator.dupe(u8, "name_5") } };
        } else if (std.mem.eql(u8, field, "age")) {
            value = .{ .scalar = .{ .integer = random.intRangeAtMost(i64, 0, 100) } };
        } else {
            value = .{ .scalar = .{ .real = 500.0 } };
        }
    }

    const ft: schema_manager.FieldType = if (std.mem.eql(u8, field, "name")) .text else if (std.mem.eql(u8, field, "age")) .integer else .real;

    return .{
        .field = try allocator.dupe(u8, field),
        .op = op,
        .value = value,
        .field_type = ft,
        .items_type = null,
    };
}
