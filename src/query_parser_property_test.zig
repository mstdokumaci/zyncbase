const std = @import("std");
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const sth = @import("storage_engine_test_helpers.zig");
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

        var fields = [_]schema_manager.Field{
            sth.makeField("field", .text, false),
        };
        const tables = [_]schema_manager.Table{
            .{ .name = "items", .fields = &fields },
        };

        var sm = try sth.createSchemaManager(allocator, &tables);
        defer sm.deinit();

        const filter = try query_parser.parseQueryFilter(allocator, &sm, "items", root);
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

        const tables = [_]schema_manager.Table{
            .{ .name = "items", .fields = &[_]schema_manager.Field{} },
        };

        var sm = try sth.createSchemaManager(allocator, &tables);
        defer sm.deinit();

        const result = query_parser.parseQueryFilter(allocator, &sm, "items", root);
        try testing.expectError(error.UnknownField, result);
    }
}

test "property: reject type-incompatible values" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(2);
    const random = prng.random();

    for (0..50) |_| {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);

        const conds_arr = try allocator.alloc(msgpack.Payload, 1);
        var cond = try allocator.alloc(msgpack.Payload, 3);
        cond[0] = try msgpack.Payload.strToPayload("age", allocator);
        cond[1] = msgpack.Payload.uintToPayload(if (random.boolean()) 0 else 4); // eq or gte
        cond[2] = try msgpack.Payload.strToPayload("not-an-integer", allocator);
        conds_arr[0] = .{ .arr = cond };
        try root.mapPut("conditions", .{ .arr = conds_arr });

        var fields = [_]schema_manager.Field{
            sth.makeField("age", .integer, false),
        };
        const tables = [_]schema_manager.Table{
            .{ .name = "items", .fields = &fields },
        };

        var sm = try sth.createSchemaManager(allocator, &tables);
        defer sm.deinit();

        try testing.expectError(error.TypeMismatch, query_parser.parseQueryFilter(allocator, &sm, "items", root));
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
        if (op_code == @intFromEnum(query_parser.Operator.in) or op_code == @intFromEnum(query_parser.Operator.notIn)) {
            const arr = try allocator.alloc(msgpack.Payload, 2);
            arr[0] = try msgpack.Payload.strToPayload("value", allocator);
            arr[1] = try msgpack.Payload.strToPayload("value-2", allocator);
            cond[2] = .{ .arr = arr };
        } else {
            cond[2] = try msgpack.Payload.strToPayload("value", allocator); // match schema field type (.text)
        }
        return .{ .arr = cond };
    }
}
