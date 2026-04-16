const std = @import("std");
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const schema_manager = @import("schema_manager.zig");
const testing = std.testing;

fn makeCondition(
    allocator: std.mem.Allocator,
    field: []const u8,
    op_code: u8,
    value: ?msgpack.Payload,
) !msgpack.Payload {
    const len: usize = if (value == null) 2 else 3;
    const arr = try allocator.alloc(msgpack.Payload, len);
    arr[0] = try msgpack.Payload.strToPayload(field, allocator);
    arr[1] = msgpack.Payload.uintToPayload(op_code);
    if (value) |v| arr[2] = v;
    return .{ .arr = arr };
}

fn makeSingleConditionFilter(
    allocator: std.mem.Allocator,
    condition: msgpack.Payload,
) !msgpack.Payload {
    var root = msgpack.Payload.mapPayload(allocator);
    const conds = try allocator.alloc(msgpack.Payload, 1);
    conds[0] = condition;
    try root.mapPut("conditions", .{ .arr = conds });
    return root;
}

test "basic query filter parsing" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    // conditions: [["age", 4, 18], ["status", 0, "active"]]
    var conds_inner = try allocator.alloc(msgpack.Payload, 2);

    var age_cond = try allocator.alloc(msgpack.Payload, 3);
    age_cond[0] = try msgpack.Payload.strToPayload("age", allocator);
    age_cond[1] = msgpack.Payload.uintToPayload(4); // gte
    age_cond[2] = msgpack.Payload.uintToPayload(18);
    conds_inner[0] = .{ .arr = age_cond };

    var status_cond = try allocator.alloc(msgpack.Payload, 3);
    status_cond[0] = try msgpack.Payload.strToPayload("status", allocator);
    status_cond[1] = msgpack.Payload.uintToPayload(0); // eq
    status_cond[2] = try msgpack.Payload.strToPayload("active", allocator);
    conds_inner[1] = .{ .arr = status_cond };

    try root.mapPut("conditions", .{ .arr = conds_inner });
    try root.mapPut("limit", msgpack.Payload.uintToPayload(50));

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{ "age", "status" },
        .types = &[_]schema_manager.FieldType{ .integer, .text },
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "users", root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), filter.conditions.?.len);
    try testing.expectEqualStrings("age", filter.conditions.?[0].field);
    try testing.expectEqual(query_parser.Operator.gte, filter.conditions.?[0].op);
    try testing.expectEqual(@as(i64, 18), filter.conditions.?[0].value.?.scalar.integer);
    try testing.expectEqual(schema_manager.FieldType.integer, filter.conditions.?[0].field_type);

    try testing.expectEqualStrings("status", filter.conditions.?[1].field);
    try testing.expectEqual(query_parser.Operator.eq, filter.conditions.?[1].op);
    try testing.expectEqualStrings("active", filter.conditions.?[1].value.?.scalar.text);
    try testing.expectEqual(schema_manager.FieldType.text, filter.conditions.?[1].field_type);

    try testing.expectEqual(@as(u32, 50), filter.limit.?);
}

test "query with orConditions" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    // orConditions: [["role", 0, "admin"], ["role", 0, "editor"]]
    var or_conds_inner = try allocator.alloc(msgpack.Payload, 2);

    var admin_cond = try allocator.alloc(msgpack.Payload, 3);
    admin_cond[0] = try msgpack.Payload.strToPayload("role", allocator);
    admin_cond[1] = msgpack.Payload.uintToPayload(0);
    admin_cond[2] = try msgpack.Payload.strToPayload("admin", allocator);
    or_conds_inner[0] = .{ .arr = admin_cond };

    var editor_cond = try allocator.alloc(msgpack.Payload, 3);
    editor_cond[0] = try msgpack.Payload.strToPayload("role", allocator);
    editor_cond[1] = msgpack.Payload.uintToPayload(0);
    editor_cond[2] = try msgpack.Payload.strToPayload("editor", allocator);
    or_conds_inner[1] = .{ .arr = editor_cond };

    try root.mapPut("orConditions", .{ .arr = or_conds_inner });

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "users", root);
    defer filter.deinit(allocator);

    try testing.expect(filter.or_conditions != null);
    try testing.expectEqual(@as(usize, 2), filter.or_conditions.?.len);
    try testing.expectEqualStrings("role", filter.or_conditions.?[0].field);
    try testing.expectEqualStrings("admin", filter.or_conditions.?[0].value.?.scalar.text);
}

test "query with orderBy and after" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    // orderBy: ["created_at", 1]
    var order_inner = try allocator.alloc(msgpack.Payload, 2);
    order_inner[0] = try msgpack.Payload.strToPayload("created_at", allocator);
    order_inner[1] = msgpack.Payload.uintToPayload(1); // desc
    try root.mapPut("orderBy", .{ .arr = order_inner });

    // after: Base64(MsgPack([42, "cursor_token"]))
    var cursor_payload = try allocator.alloc(msgpack.Payload, 2);
    cursor_payload[0] = msgpack.Payload.uintToPayload(42);
    cursor_payload[1] = try msgpack.Payload.strToPayload("cursor_token", allocator);
    const after_value = msgpack.Payload{ .arr = cursor_payload };
    defer after_value.free(allocator);
    const after_token = try msgpack.encodeBase64(allocator, after_value);
    defer allocator.free(after_token);
    try root.mapPut("after", try msgpack.Payload.strToPayload(after_token, allocator));

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"val"},
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "items", root);
    defer filter.deinit(allocator);

    try testing.expectEqualStrings("created_at", filter.order_by.field);
    try testing.expectEqual(true, filter.order_by.desc);
    try testing.expectEqual(schema_manager.FieldType.integer, filter.order_by.field_type);
    try testing.expectEqualStrings("cursor_token", filter.after.?.id);
}

test "query rejects invalid Base64 after cursor token" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    // after: invalid Base64 token
    try root.mapPut("after", try msgpack.Payload.strToPayload("%%%INVALID_BASE64%%%", allocator));

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"created_at"},
    }});
    defer sm.deinit();

    try testing.expectError(
        error.InvalidMessageFormat,
        query_parser.parseQueryFilter(allocator, &sm, "items", root),
    );
}

test "isNull condition (no value tuple)" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    // conditions: [["deleted_at", 11]]
    var conds_inner = try allocator.alloc(msgpack.Payload, 1);
    var null_cond = try allocator.alloc(msgpack.Payload, 2);
    null_cond[0] = try msgpack.Payload.strToPayload("deleted_at", allocator);
    null_cond[1] = msgpack.Payload.uintToPayload(11); // isNull
    conds_inner[0] = .{ .arr = null_cond };

    try root.mapPut("conditions", .{ .arr = conds_inner });

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"deleted_at"},
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "items", root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), filter.conditions.?.len);
    try testing.expectEqual(query_parser.Operator.isNull, filter.conditions.?[0].op);
    try testing.expect(filter.conditions.?[0].value == null);
}

test "unknown field name (including flattened paths)" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    // conditions: [["address__city", 0, "NYC"]] -> Unknown because it's not in the mock schema
    var conds_inner = try allocator.alloc(msgpack.Payload, 1);
    var unknown_cond = try allocator.alloc(msgpack.Payload, 3);
    unknown_cond[0] = try msgpack.Payload.strToPayload("address__city", allocator);
    unknown_cond[1] = msgpack.Payload.uintToPayload(0);
    unknown_cond[2] = try msgpack.Payload.strToPayload("NYC", allocator);
    conds_inner[0] = .{ .arr = unknown_cond };

    try root.mapPut("conditions", .{ .arr = conds_inner });

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"address"},
    }});
    defer sm.deinit();

    const result = query_parser.parseQueryFilter(allocator, &sm, "items", root);
    try testing.expectError(error.UnknownField, result);
}

test "malformed after field (panic regression test)" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    // after: [42, 99] -> second element should be a string (cursor token)
    var after_inner = try allocator.alloc(msgpack.Payload, 2);
    after_inner[0] = msgpack.Payload.uintToPayload(42);
    after_inner[1] = msgpack.Payload.uintToPayload(99); // Malformed: should be a string
    try root.mapPut("after", .{ .arr = after_inner });

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer sm.deinit();

    const result = query_parser.parseQueryFilter(allocator, &sm, "items", root);
    // This should return an error instead of panicking
    try testing.expectError(error.InvalidMessageFormat, result);
}

test "in condition parses to typed array" {
    const allocator = testing.allocator;

    const values = try allocator.alloc(msgpack.Payload, 2);
    values[0] = try msgpack.Payload.strToPayload("admin", allocator);
    values[1] = try msgpack.Payload.strToPayload("editor", allocator);

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "role", 9, .{ .arr = values }));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "users", root);
    defer filter.deinit(allocator);

    const conds = filter.conditions orelse return error.TestExpectedValue;
    const value = conds[0].value orelse return error.TestExpectedValue;
    try testing.expect(value == .array);
    try testing.expectEqual(@as(usize, 2), value.array.len);
    try testing.expectEqualStrings("admin", value.array[0].text);
    try testing.expectEqualStrings("editor", value.array[1].text);
}

test "in condition rejects non-array operand" {
    const allocator = testing.allocator;

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "role", 9, try msgpack.Payload.strToPayload("admin", allocator)));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    try testing.expectError(error.InvalidInOperand, query_parser.parseQueryFilter(allocator, &sm, "users", root));
}

test "in condition rejects nil element" {
    const allocator = testing.allocator;

    const values = try allocator.alloc(msgpack.Payload, 2);
    values[0] = try msgpack.Payload.strToPayload("admin", allocator);
    values[1] = .nil;

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "role", 9, .{ .arr = values }));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    try testing.expectError(error.NullOperandUnsupported, query_parser.parseQueryFilter(allocator, &sm, "users", root));
}

test "contains on array field parses using element type" {
    const allocator = testing.allocator;

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "tags", 6, try msgpack.Payload.strToPayload("urgent", allocator)));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"tags"},
        .types = &[_]schema_manager.FieldType{.array},
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "items", root);
    defer filter.deinit(allocator);

    try testing.expectEqual(schema_manager.FieldType.array, filter.conditions.?[0].field_type);
    try testing.expectEqualStrings("urgent", filter.conditions.?[0].value.?.scalar.text);
}

test "contains on text rejects non-string operand" {
    const allocator = testing.allocator;

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "name", 6, msgpack.Payload.uintToPayload(42)));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"name"},
    }});
    defer sm.deinit();

    try testing.expectError(error.InvalidOperandType, query_parser.parseQueryFilter(allocator, &sm, "items", root));
}

test "startsWith on non-text field is rejected" {
    const allocator = testing.allocator;

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "age", 7, try msgpack.Payload.strToPayload("1", allocator)));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"age"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    try testing.expectError(error.UnsupportedOperatorForFieldType, query_parser.parseQueryFilter(allocator, &sm, "users", root));
}

test "isNull with operand is rejected" {
    const allocator = testing.allocator;

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "deleted_at", 11, msgpack.Payload.uintToPayload(1)));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"deleted_at"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    try testing.expectError(error.UnexpectedOperand, query_parser.parseQueryFilter(allocator, &sm, "items", root));
}

test "eq with nil operand is rejected" {
    const allocator = testing.allocator;

    var root = try makeSingleConditionFilter(allocator, try makeCondition(allocator, "name", 0, .nil));
    defer root.free(allocator);

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"name"},
    }});
    defer sm.deinit();

    try testing.expectError(error.NullOperandUnsupported, query_parser.parseQueryFilter(allocator, &sm, "items", root));
}

test "orderBy rejects invalid direction value" {
    const allocator = testing.allocator;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);

    const order_tuple = try allocator.alloc(msgpack.Payload, 2);
    order_tuple[0] = try msgpack.Payload.strToPayload("created_at", allocator);
    order_tuple[1] = msgpack.Payload.uintToPayload(2);
    try root.mapPut("orderBy", .{ .arr = order_tuple });

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"created_at"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &sm, "items", root));
}

test "after is parsed using final orderBy regardless of map insertion order" {
    const allocator = testing.allocator;

    var cursor_payload = try allocator.alloc(msgpack.Payload, 2);
    cursor_payload[0] = msgpack.Payload.uintToPayload(42);
    cursor_payload[1] = try msgpack.Payload.strToPayload("cursor_token", allocator);
    const after_value = msgpack.Payload{ .arr = cursor_payload };
    defer after_value.free(allocator);
    const after_token = try msgpack.encodeBase64(allocator, after_value);
    defer allocator.free(after_token);

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    try root.mapPut("after", try msgpack.Payload.strToPayload(after_token, allocator));

    const order_tuple = try allocator.alloc(msgpack.Payload, 2);
    order_tuple[0] = try msgpack.Payload.strToPayload("created_at", allocator);
    order_tuple[1] = msgpack.Payload.uintToPayload(1);
    try root.mapPut("orderBy", .{ .arr = order_tuple });

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"created_at"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "items", root);
    defer filter.deinit(allocator);

    try testing.expectEqualStrings("created_at", filter.order_by.field);
    try testing.expectEqual(@as(i64, 42), filter.after.?.sort_value.scalar.integer);
}

test "cursor token rejects wrong sort type" {
    const allocator = testing.allocator;

    var cursor_payload = try allocator.alloc(msgpack.Payload, 2);
    cursor_payload[0] = try msgpack.Payload.strToPayload("not-an-int", allocator);
    cursor_payload[1] = try msgpack.Payload.strToPayload("cursor_token", allocator);
    const token_value = msgpack.Payload{ .arr = cursor_payload };
    defer token_value.free(allocator);
    const token = try msgpack.encodeBase64(allocator, token_value);
    defer allocator.free(token);

    try testing.expectError(error.InvalidCursorSortValue, query_parser.parseCursorToken(allocator, token, .integer, null));
}
