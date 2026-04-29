const std = @import("std");
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const sth = @import("storage_engine_test_helpers.zig");
const query_parser = @import("query_parser.zig");
const testing = std.testing;

test "property: random valid query filters" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var fields = [_]schema_manager.Field{
        sth.makeField("field", .text, false),
    };
    const tables = [_]schema_manager.Table{
        .{ .name = "items", .name_quoted = "\"items\"", .fields = &fields },
    };

    var sm = try sth.createSchemaManager(allocator, &tables);
    defer sm.deinit();

    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const field_index = tbl.getFieldIndex("field") orelse return error.TestExpectedValue;

    for (0..100) |_| {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);

        // Randomly decide which fields to include
        if (random.boolean()) {
            const num_conds = random.intRangeAtMost(usize, 0, 10);
            const conds_arr = try allocator.alloc(msgpack.Payload, num_conds);
            for (conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false, field_index, .text);
            }
            try root.mapPut("conditions", .{ .arr = conds_arr });
        }

        if (random.boolean()) {
            const num_or_conds = random.intRangeAtMost(usize, 0, 5);
            const or_conds_arr = try allocator.alloc(msgpack.Payload, num_or_conds);
            for (or_conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false, field_index, .text);
            }
            try root.mapPut("orConditions", .{ .arr = or_conds_arr });
        }

        if (random.boolean()) {
            var order_arr = try allocator.alloc(msgpack.Payload, 2);
            order_arr[0] = msgpack.Payload.uintToPayload(field_index);
            order_arr[1] = msgpack.Payload.uintToPayload(if (random.boolean()) 1 else 0);
            try root.mapPut("orderBy", .{ .arr = order_arr });
        }
        const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
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

        // Add a condition with a field index not in schema
        const conds_arr = try allocator.alloc(msgpack.Payload, 1);
        conds_arr[0] = try generateRandomCondition(allocator, random, true, 0, .text);
        try root.mapPut("conditions", .{ .arr = conds_arr });

        const tables = [_]schema_manager.Table{
            .{ .name = "items", .name_quoted = "\"items\"", .fields = &[_]schema_manager.Field{} },
        };

        var sm = try sth.createSchemaManager(allocator, &tables);
        defer sm.deinit();

        const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
        const result = query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
        try testing.expectError(error.UnknownField, result);
    }
}

fn generateRandomCondition(allocator: std.mem.Allocator, random: std.Random, force_unknown_field: bool, field_index: usize, field_type: schema_manager.FieldType) !msgpack.Payload {
    const resolved_field_index: usize = if (force_unknown_field) 9999 else field_index;
    const op_code = random.intRangeAtMost(u8, 0, 12);

    // isNull (11) and isNotNull (12) are special (2 elements)
    if (op_code >= 11) {
        var cond = try allocator.alloc(msgpack.Payload, 2);
        cond[0] = msgpack.Payload.uintToPayload(resolved_field_index);
        cond[1] = msgpack.Payload.uintToPayload(op_code);
        return .{ .arr = cond };
    } else {
        var cond = try allocator.alloc(msgpack.Payload, 3);
        cond[0] = msgpack.Payload.uintToPayload(resolved_field_index);
        cond[1] = msgpack.Payload.uintToPayload(op_code);
        cond[2] = switch (op_code) {
            6, 7, 8 => try msgpack.Payload.strToPayload("v", allocator),
            9, 10 => try randomInValueForType(allocator, random, field_type),
            else => try randomValueForType(allocator, random, field_type),
        };
        return .{ .arr = cond };
    }
}

fn randomValueForType(allocator: std.mem.Allocator, random: std.Random, field_type: schema_manager.FieldType) !msgpack.Payload {
    return switch (field_type) {
        .text => msgpack.Payload.strToPayload("v", allocator),
        .doc_id => blk: {
            var bytes = [_]u8{0} ** 16;
            for (&bytes) |*byte| byte.* = random.int(u8);
            break :blk try msgpack.Payload.binToPayload(&bytes, allocator);
        },
        .integer => msgpack.Payload.uintToPayload(random.int(u64)),
        .real => .{ .float = @floatFromInt(random.int(u32)) },
        .boolean => msgpack.Payload{ .bool = random.boolean() },
        .array => blk: {
            var arr = try allocator.alloc(msgpack.Payload, 1);
            arr[0] = try msgpack.Payload.strToPayload("v", allocator);
            break :blk .{ .arr = arr };
        },
    };
}

fn randomInValueForType(allocator: std.mem.Allocator, random: std.Random, field_type: schema_manager.FieldType) !msgpack.Payload {
    const len = random.intRangeAtMost(usize, 0, 3);
    const arr = try allocator.alloc(msgpack.Payload, len);
    for (arr) |*item| {
        item.* = try randomValueForType(allocator, random, field_type);
    }
    return .{ .arr = arr };
}
