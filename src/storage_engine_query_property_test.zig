const std = @import("std");
const testing = std.testing;
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const schema_manager = @import("schema_manager.zig");
const msgpack = @import("msgpack_utils.zig");
const query_parser = @import("query_parser.zig");
const sth = @import("storage_engine_test_helpers.zig");

test "property: random query filters on StorageEngine" {
    const allocator = testing.allocator;

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
    try seedEntities(allocator, engine, 100);

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..200) |_| {
        var filter = try generateRandomFilter(allocator, random);
        defer filter.deinit(allocator);

        // Execute query
        var managed = try engine.selectQuery(allocator, "entities", "ns1", filter);
        defer managed.deinit();
        const results = managed.value orelse msgpack.Payload{ .arr = &[_]msgpack.Payload{} };

        try testing.expect(results == .arr);
    }
}

fn seedEntities(allocator: std.mem.Allocator, engine: *StorageEngine, count: usize) !void {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "id_{}", .{i});

        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "name_{}", .{random.intRangeAtMost(u8, 0, 10)});
        const name_p = try msgpack.Payload.strToPayload(name, allocator);
        defer name_p.free(allocator);

        const age = random.intRangeAtMost(i64, 0, 100);
        const score = random.float(f64) * 1000.0;

        const cols = [_]ColumnValue{
            .{ .name = "name", .value = name_p },
            .{ .name = "age", .value = msgpack.Payload.intToPayload(age) },
            .{ .name = "score", .value = msgpack.Payload.floatToPayload(score) },
        };
        try engine.insertOrReplace("entities", id, "ns1", &cols, false);
    }
    try engine.flushPendingWrites();
}

fn generateRandomFilter(allocator: std.mem.Allocator, random: std.Random) !query_parser.QueryFilter {
    var filter = query_parser.QueryFilter{};

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

    // Random OrderBy
    if (random.boolean()) {
        const fields = [_][]const u8{ "name", "age", "score", "id", "created_at" };
        filter.order_by = .{
            .field = try allocator.dupe(u8, fields[random.intRangeAtMost(usize, 0, fields.len - 1)]),
            .desc = random.boolean(),
        };
    }

    // Random Limit
    if (random.boolean()) {
        filter.limit = random.intRangeAtMost(u32, 1, 100);
    }

    return filter;
}

fn generateRandomCondition(allocator: std.mem.Allocator, random: std.Random) !query_parser.Condition {
    const fields = [_][]const u8{ "name", "age", "score" };
    const field = fields[random.intRangeAtMost(usize, 0, fields.len - 1)];

    // Choose an operator
    const op_int = random.intRangeAtMost(u8, 0, 10); // Exclude IN/NOT IN/LIKE etc for simplicity if needed, but let's try some.
    const op: query_parser.Operator = @enumFromInt(op_int);

    var value: ?msgpack.Payload = null;
    if (op != .isNull and op != .isNotNull) {
        // String operators MUST have string values
        if (op == .startsWith or op == .endsWith or op == .contains) {
            value = try msgpack.Payload.strToPayload("test_value", allocator);
        } else if (std.mem.eql(u8, field, "name")) {
            value = try msgpack.Payload.strToPayload("name_5", allocator);
        } else if (std.mem.eql(u8, field, "age")) {
            value = msgpack.Payload.intToPayload(random.intRangeAtMost(i64, 0, 100));
        } else {
            value = msgpack.Payload.floatToPayload(500.0);
        }
    }

    return .{
        .field = try allocator.dupe(u8, field),
        .op = op,
        .value = value,
    };
}
