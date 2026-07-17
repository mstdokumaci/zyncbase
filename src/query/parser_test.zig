const std = @import("std");
const query_parser = @import("parser.zig");
const query_ast = @import("ast.zig");
const msgpack = @import("../msgpack_utils.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const schema_types = @import("../schema/types.zig");
const typed = @import("../typed/types.zig");
const qth = @import("test_helpers.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const testing = std.testing;

test "basic query filter parsing" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{ "age", "status" },
        .types = &[_]schema_types.FieldType{ .integer, .text },
    }});
    defer schema.deinit();

    const tbl = schema.table("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "age", 4, 18 }, // gte
            .{ "status", 0, "active" }, // eq
        },
        .limit = 50,
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);
    const users_md = schema.table("users") orelse return error.UnknownTable;
    const age_index = users_md.fieldIndex("age") orelse return error.UnknownField;
    const status_index = users_md.fieldIndex("status") orelse return error.UnknownField;

    try testing.expectEqual(@as(usize, 2), filter.predicate.conditions.?.len);
    try testing.expectEqual(age_index, filter.predicate.conditions.?[0].field_index);
    try testing.expectEqual(@as(i64, 18), filter.predicate.conditions.?[0].value.?.scalar.integer);
    try testing.expectEqual(status_index, filter.predicate.conditions.?[1].field_index);
    try testing.expectEqualStrings("active", filter.predicate.conditions.?[1].value.?.scalar.text);
    try testing.expectEqual(@as(u32, 50), filter.limit.?);
}

test "query with orConditions" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer schema.deinit();

    const tbl = schema.table("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .or_conditions = .{
            .{ "role", 0, "admin" },
            .{ "role", 0, "editor" },
        },
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);
    const users_md = schema.table("users") orelse return error.UnknownTable;
    const role_index = users_md.fieldIndex("role") orelse return error.UnknownField;

    try testing.expect(filter.predicate.or_conditions != null);
    try testing.expectEqual(@as(usize, 2), filter.predicate.or_conditions.?.len);
    try testing.expectEqual(role_index, filter.predicate.or_conditions.?[0].field_index);
    try testing.expectEqualStrings("admin", filter.predicate.or_conditions.?[0].value.?.scalar.text);
}

test "query with orderBy and after" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"val"},
        .types = &[_]schema_types.FieldType{.text},
    }});
    defer schema.deinit();

    // cursor: Base64(MsgPack([42, doc_id(2)]))
    const cursor: typed.Cursor = .{
        .sort_value = .{ .scalar = .{ .integer = 42 } },
        .id = 2,
    };
    const after_token = try query_parser.encodeCursorToken(allocator, cursor);
    defer allocator.free(after_token);

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .orderBy = .{ "created_at", 1 }, // desc
        .cursor = after_token,
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    const items_md = schema.table("items") orelse return error.UnknownTable;
    const created_at_index = items_md.fieldIndex("created_at") orelse return error.UnknownField;
    try testing.expectEqual(created_at_index, filter.order_by.field_index);
    try testing.expectEqual(true, filter.order_by.desc);
    try testing.expectEqual(cursor.id, filter.after.?.id);
}

test "query rejects invalid Base64 after cursor token" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .cursor = "%%%INVALID_BASE64%%%",
    });
    defer root.free(allocator);

    try testing.expectError(
        error.InvalidMessageFormat,
        query_parser.parseQueryFilter(allocator, &schema, tbl.index, root),
    );
}

test "isNull condition (no value tuple)" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"deleted_at"},
    }});
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "deleted_at", 11 }, // isNull
        },
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), filter.predicate.conditions.?.len);
    try testing.expectEqual(query_ast.Operator.isNull, filter.predicate.conditions.?[0].op);
    try testing.expect(filter.predicate.conditions.?[0].value == null);
}

test "unknown field name (including flattened paths)" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"address"},
    }});
    defer schema.deinit();

    // Use raw invalid index instead of string to reach server-side UnknownField logic
    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ @as(usize, 999), 0, "NYC" },
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.UnknownField, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
}

test "malformed after field (panic regression test)" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer schema.deinit();

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    var malformed_after = try allocator.alloc(msgpack.Payload, 2);
    malformed_after[0] = msgpack.Payload.uintToPayload(42);
    malformed_after[1] = msgpack.Payload.uintToPayload(99); // Malformed: should be a string
    try root.mapPut("after", .{ .arr = malformed_after });

    try testing.expectError(error.InvalidMessageFormat, query_parser.parseQueryFilter(allocator, &schema, schema.table("items").?.index, root));
}

test "in condition parses to typed array" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer schema.deinit();

    const values = try allocator.alloc(msgpack.Payload, 2);
    values[0] = try msgpack.Payload.strToPayload("admin", allocator);
    values[1] = try msgpack.Payload.strToPayload("editor", allocator);
    const values_payload = msgpack.Payload{ .arr = values };
    defer values_payload.free(allocator);

    const tbl = schema.table("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "role", 9, values_payload },
        },
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    const conds = filter.predicate.conditions orelse return error.TestExpectedValue;
    const value = conds[0].value orelse return error.TestExpectedValue;
    try testing.expect(value == .array);
    try testing.expectEqual(@as(usize, 2), value.array.len);
    try testing.expectEqualStrings("admin", value.array[0].text);
}

test "query normalization drops AND notIn empty set" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{ "role", "age" },
        .types = &[_]schema_types.FieldType{ .text, .integer },
    }});
    defer schema.deinit();

    const empty_values = try emptyArrayPayload(allocator);
    defer empty_values.free(allocator);

    const tbl = schema.table("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "role", 10, empty_values },
            .{ "age", 0, 18 },
        },
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(query_ast.PredicateState.conditional, filter.predicate.state);
    const conds = filter.predicate.conditions orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), conds.len);
    try testing.expectEqual(query_ast.Operator.eq, conds[0].op);
    try testing.expectEqual(tbl.fieldIndex("age").?, conds[0].field_index);
    try testing.expect(filter.predicate.or_conditions == null);
}

test "in condition rejects non-array operand" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer schema.deinit();

    const tbl = schema.table("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "role", 9, "admin" }, // Value should be array for IN (9)
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.InvalidInOperand, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
}

test "in condition rejects nil element" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer schema.deinit();

    const values = try allocator.alloc(msgpack.Payload, 2);
    values[0] = try msgpack.Payload.strToPayload("admin", allocator);
    values[1] = .nil;
    const values_payload = msgpack.Payload{ .arr = values };
    defer values_payload.free(allocator);

    const tbl = schema.table("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "role", 9, values_payload },
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.NullOperandUnsupported, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
}

test "contains on array field parses using element type" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"tags"},
        .types = &[_]schema_types.FieldType{.array},
    }});
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "tags", 6, "urgent" }, // contains
        },
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(schema_types.FieldType.array, filter.predicate.conditions.?[0].field_type);
    try testing.expectEqualStrings("urgent", filter.predicate.conditions.?[0].value.?.scalar.text);
}

test "contains on text rejects non-string operand" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"name"},
    }});
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "name", 6, 42 }, // non-string for contains
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.InvalidOperandType, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
}

test "isNull with operand is rejected" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"deleted_at"},
        .types = &[_]schema_types.FieldType{.integer},
    }});
    defer schema.deinit();

    // Manually construct null condition with extra operand to bypass helper's valid construction
    var cond_arr = try allocator.alloc(msgpack.Payload, 3);
    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    cond_arr[0] = msgpack.Payload.uintToPayload(tbl.fieldIndex("deleted_at") orelse return error.TestExpectedValue);
    cond_arr[1] = msgpack.Payload.uintToPayload(11); // isNull
    cond_arr[2] = msgpack.Payload.uintToPayload(1); // unexpected operand

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    var conds = try allocator.alloc(msgpack.Payload, 1);
    conds[0] = .{ .arr = cond_arr };
    try root.mapPut("conditions", .{ .arr = conds });

    try testing.expectError(error.UnexpectedOperand, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
}

test "eq with nil operand is rejected" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"name"},
    }});
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "name", 0, msgpack.Payload{ .nil = {} } },
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.NullOperandUnsupported, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
}

test "orderBy rejects invalid direction value" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer schema.deinit();

    // Manually construct invalid orderBy
    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    var order_arr = try allocator.alloc(msgpack.Payload, 2);
    const tbl_items = schema.table("items") orelse return error.TestExpectedValue;
    order_arr[0] = msgpack.Payload.uintToPayload(tbl_items.fieldIndex("created_at") orelse return error.TestExpectedValue);
    order_arr[1] = msgpack.Payload.uintToPayload(2); // invalid direction
    try root.mapPut("orderBy", .{ .arr = order_arr });

    try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &schema, tbl_items.index, root));
}

test "after is parsed using final orderBy regardless of map insertion order" {
    const allocator = testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer schema.deinit();

    const cursor: typed.Cursor = .{
        .sort_value = .{ .scalar = .{ .integer = 42 } },
        .id = 2,
    };
    const after_token = try query_parser.encodeCursorToken(allocator, cursor);
    defer allocator.free(after_token);

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    try root.mapPut("after", try msgpack.Payload.strToPayload(after_token, allocator));

    var order_arr = try allocator.alloc(msgpack.Payload, 2);
    const tbl_items = schema.table("items") orelse return error.TestExpectedValue;
    order_arr[0] = msgpack.Payload.uintToPayload(tbl_items.fieldIndex("created_at") orelse return error.TestExpectedValue);
    order_arr[1] = msgpack.Payload.uintToPayload(1);
    try root.mapPut("orderBy", .{ .arr = order_arr });

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl_items.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(i64, 42), filter.after.?.sort_value.scalar.integer);
}

test "cursor token rejects wrong sort type" {
    const allocator = testing.allocator;

    const cursor: typed.Cursor = .{
        .sort_value = .{ .scalar = .{ .text = "not-an-int" } },
        .id = 2,
    };
    const token = try query_parser.encodeCursorToken(allocator, cursor);
    defer allocator.free(token);

    try testing.expectError(error.InvalidCursorSortValue, query_parser.decodeCursorToken(allocator, token, .integer, null));
}

fn emptyArrayPayload(allocator: std.mem.Allocator) !msgpack.Payload {
    return .{ .arr = try allocator.alloc(msgpack.Payload, 0) };
}

test "property: random valid query filters" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var fields = [_]schema_types.Field{
        schema_helpers.makeField("field", .text),
    };
    const tables = [_]schema_types.Table{
        schema_helpers.makeTable("items", &fields),
    };

    var schema = try sth.createSchema(allocator, &tables);
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const field_index = tbl.fieldIndex("field") orelse return error.TestExpectedValue;

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
        var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
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

        const tables = [_]schema_types.Table{
            schema_helpers.makeTable("items", &[_]schema_types.Field{}),
        };

        var schema = try sth.createSchema(allocator, &tables);
        defer schema.deinit();

        const tbl = schema.table("items") orelse return error.TestExpectedValue;
        const result = query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
        try testing.expectError(error.UnknownField, result);
    }
}

fn generateRandomCondition(allocator: std.mem.Allocator, random: std.Random, force_unknown_field: bool, field_index: usize, field_type: schema_types.FieldType) !msgpack.Payload {
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

fn randomValueForType(allocator: std.mem.Allocator, random: std.Random, field_type: schema_types.FieldType) !msgpack.Payload {
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

fn randomInValueForType(allocator: std.mem.Allocator, random: std.Random, field_type: schema_types.FieldType) !msgpack.Payload {
    const len = random.intRangeAtMost(usize, 0, 3);
    const arr = try allocator.alloc(msgpack.Payload, len);
    for (arr) |*item| {
        item.* = try randomValueForType(allocator, random, field_type);
    }
    return .{ .arr = arr };
}
