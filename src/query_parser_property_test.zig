const std = @import("std");
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const testing = std.testing;

test "property: random valid query filters" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..100) |_| {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);

        // Randomly decide which fields to include
        if (random.boolean()) {
            const num_conds = random.intRangeAtMost(usize, 0, 10);
            const conds_arr = try allocator.alloc(msgpack.Payload, num_conds);
            for (conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false, "field");
            }
            try root.mapPut("conditions", .{ .arr = conds_arr });
        }

        if (random.boolean()) {
            const num_or_conds = random.intRangeAtMost(usize, 0, 5);
            const or_conds_arr = try allocator.alloc(msgpack.Payload, num_or_conds);
            for (or_conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false, "field");
            }
            try root.mapPut("orConditions", .{ .arr = or_conds_arr });
        }

        if (random.boolean()) {
            var order_arr = try allocator.alloc(msgpack.Payload, 2);
            order_arr[0] = try msgpack.Payload.strToPayload("field", allocator);
            order_arr[1] = msgpack.Payload.uintToPayload(if (random.boolean()) 1 else 0);
            try root.mapPut("orderBy", .{ .arr = order_arr });
        }

        const fields = [_]schema_manager.Field{
            .{ .name = "field", .sql_type = .text, .required = false, .indexed = false, .references = null, .on_delete = null },
        };
        const table = schema_manager.Table{ .name = "items", .fields = @constCast(fields[0..]) };
        const tables = try allocator.alloc(schema_manager.Table, 1);
        tables[0] = try table.clone(allocator); // clone for SchemaManager ownership
        const schema = try allocator.create(schema_manager.Schema);
        schema.* = .{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };

        const sm = try SchemaManager.initWithSchema(allocator, schema.*);
        allocator.destroy(schema);
        defer sm.deinit();

        const filter = try query_parser.parseQueryFilter(allocator, sm, "items", root);
        filter.deinit(allocator);
    }
}

test "property: reject unknown field names" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();

    for (0..50) |_| {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);

        // Add a condition with a name not in schema
        const conds_arr = try allocator.alloc(msgpack.Payload, 1);
        conds_arr[0] = try generateRandomCondition(allocator, random, true, "unknown_field");
        try root.mapPut("conditions", .{ .arr = conds_arr });

        const fields = [_]schema_manager.Field{};
        const table = schema_manager.Table{ .name = "items", .fields = @constCast(fields[0..]) };
        const tables = try allocator.alloc(schema_manager.Table, 1);
        tables[0] = try table.clone(allocator);
        const schema = try allocator.create(schema_manager.Schema);
        schema.* = .{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };

        const sm = try SchemaManager.initWithSchema(allocator, schema.*);
        allocator.destroy(schema);
        defer sm.deinit();

        const result = query_parser.parseQueryFilter(allocator, sm, "items", root);
        try testing.expectError(error.UnknownField, result);
    }
}

fn generateRandomCondition(allocator: std.mem.Allocator, random: std.Random, force_unknown_field: bool, field_name: []const u8) !msgpack.Payload {
    const field = if (force_unknown_field) "another_field" else field_name;
    const op_code = random.intRangeAtMost(u8, 0, 12);

    // isNull (11) and isNotNull (12) are special (2 elements)
    if (op_code >= 11) {
        var cond = try allocator.alloc(msgpack.Payload, 2);
        cond[0] = try msgpack.Payload.strToPayload(field, allocator);
        cond[1] = msgpack.Payload.uintToPayload(op_code);
        return .{ .arr = cond };
    } else {
        var cond = try allocator.alloc(msgpack.Payload, 3);
        cond[0] = try msgpack.Payload.strToPayload(field, allocator);
        cond[1] = msgpack.Payload.uintToPayload(op_code);
        cond[2] = msgpack.Payload.uintToPayload(42); // simple value for property test
        return .{ .arr = cond };
    }
}
