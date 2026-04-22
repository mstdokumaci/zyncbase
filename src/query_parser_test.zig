const std = @import("std");
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const schema_manager = @import("schema_manager.zig");
const storage_engine = @import("storage_engine.zig");
const doc_id = @import("doc_id.zig");
const qth = @import("query_parser_test_helpers.zig");
const testing = std.testing;

test "basic query filter parsing" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{ "age", "status" },
        .types = &[_]schema_manager.FieldType{ .integer, .text },
    }});
    defer sm.deinit();

    const tbl = sm.getTable("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "age", 4, 18 }, // gte
            .{ "status", 0, "active" }, // eq
        },
        .limit = 50,
    });
    defer root.free(allocator);

    const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
    defer filter.deinit(allocator);
    const users_md = sm.getTable("users") orelse return error.UnknownTable;
    const age_index = users_md.field_index_map.get("age") orelse return error.UnknownField;
    const status_index = users_md.field_index_map.get("status") orelse return error.UnknownField;

    try testing.expectEqual(@as(usize, 2), filter.conditions.?.len);
    try testing.expectEqual(age_index, filter.conditions.?[0].field_index);
    try testing.expectEqual(@as(i64, 18), filter.conditions.?[0].value.?.scalar.integer);
    try testing.expectEqual(status_index, filter.conditions.?[1].field_index);
    try testing.expectEqualStrings("active", filter.conditions.?[1].value.?.scalar.text);
    try testing.expectEqual(@as(u32, 50), filter.limit.?);
}

test "query with orConditions" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .or_conditions = .{
            .{ "role", 0, "admin" },
            .{ "role", 0, "editor" },
        },
    });
    defer root.free(allocator);

    const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
    defer filter.deinit(allocator);
    const users_md = sm.getTable("users") orelse return error.UnknownTable;
    const role_index = users_md.field_index_map.get("role") orelse return error.UnknownField;

    try testing.expect(filter.or_conditions != null);
    try testing.expectEqual(@as(usize, 2), filter.or_conditions.?.len);
    try testing.expectEqual(role_index, filter.or_conditions.?[0].field_index);
    try testing.expectEqualStrings("admin", filter.or_conditions.?[0].value.?.scalar.text);
}

test "query with orderBy and after" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{ "val", "created_at" },
        .types = &[_]schema_manager.FieldType{ .text, .integer },
    }});
    defer sm.deinit();

    // cursor: Base64(MsgPack([42, doc_id(2)]))
    var cursor_payload_arr = try allocator.alloc(msgpack.Payload, 2);
    const cursor_id: storage_engine.DocId = 2;
    const cursor_bytes = doc_id.toBytes(cursor_id);
    cursor_payload_arr[0] = msgpack.Payload.uintToPayload(42);
    cursor_payload_arr[1] = try msgpack.Payload.binToPayload(&cursor_bytes, allocator);
    const cursor_payload = msgpack.Payload{ .arr = cursor_payload_arr };
    defer cursor_payload.free(allocator);
    const after_token = try msgpack.encodeBase64(allocator, cursor_payload);
    defer allocator.free(after_token);

    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .orderBy = .{ "created_at", 1 }, // desc
        .cursor = after_token,
    });
    defer root.free(allocator);

    const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
    defer filter.deinit(allocator);

    const items_md = sm.getTable("items") orelse return error.UnknownTable;
    const created_at_index = items_md.field_index_map.get("created_at") orelse return error.UnknownField;
    try testing.expectEqual(created_at_index, filter.order_by.field_index);
    try testing.expectEqual(true, filter.order_by.desc);
    try testing.expectEqual(cursor_id, filter.after.?.id);
}

test "query rejects invalid Base64 after cursor token" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"created_at"},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .cursor = "%%%INVALID_BASE64%%%",
    });
    defer root.free(allocator);

    try testing.expectError(
        error.InvalidMessageFormat,
        query_parser.parseQueryFilter(allocator, &sm, tbl.index, root),
    );
}

test "isNull condition (no value tuple)" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"deleted_at"},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "deleted_at", 11 }, // isNull
        },
    });
    defer root.free(allocator);

    const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), filter.conditions.?.len);
    try testing.expectEqual(query_parser.Operator.isNull, filter.conditions.?[0].op);
    try testing.expect(filter.conditions.?[0].value == null);
}

test "unknown field name (including flattened paths)" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"address"},
    }});
    defer sm.deinit();

    // Use raw invalid index instead of string to reach server-side UnknownField logic
    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ @as(usize, 999), 0, "NYC" },
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.UnknownField, query_parser.parseQueryFilter(allocator, &sm, tbl.index, root));
}

test "malformed after field (panic regression test)" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer sm.deinit();

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    var malformed_after = try allocator.alloc(msgpack.Payload, 2);
    malformed_after[0] = msgpack.Payload.uintToPayload(42);
    malformed_after[1] = msgpack.Payload.uintToPayload(99); // Malformed: should be a string
    try root.mapPut("after", .{ .arr = malformed_after });

    try testing.expectError(error.InvalidMessageFormat, query_parser.parseQueryFilter(allocator, &sm, sm.getTable("items").?.index, root));
}

test "in condition parses to typed array" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    const values = try allocator.alloc(msgpack.Payload, 2);
    values[0] = try msgpack.Payload.strToPayload("admin", allocator);
    values[1] = try msgpack.Payload.strToPayload("editor", allocator);
    const values_payload = msgpack.Payload{ .arr = values };
    defer values_payload.free(allocator);

    const tbl = sm.getTable("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "role", 9, values_payload },
        },
    });
    defer root.free(allocator);

    const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
    defer filter.deinit(allocator);

    const conds = filter.conditions orelse return error.TestExpectedValue;
    const value = conds[0].value orelse return error.TestExpectedValue;
    try testing.expect(value == .array);
    try testing.expectEqual(@as(usize, 2), value.array.len);
    try testing.expectEqualStrings("admin", value.array[0].text);
}

test "in condition rejects non-array operand" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "role", 9, "admin" }, // Value should be array for IN (9)
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.InvalidInOperand, query_parser.parseQueryFilter(allocator, &sm, tbl.index, root));
}

test "in condition rejects nil element" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"role"},
    }});
    defer sm.deinit();

    const values = try allocator.alloc(msgpack.Payload, 2);
    values[0] = try msgpack.Payload.strToPayload("admin", allocator);
    values[1] = .nil;
    const values_payload = msgpack.Payload{ .arr = values };
    defer values_payload.free(allocator);

    const tbl = sm.getTable("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "role", 9, values_payload },
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.NullOperandUnsupported, query_parser.parseQueryFilter(allocator, &sm, tbl.index, root));
}

test "contains on array field parses using element type" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"tags"},
        .types = &[_]schema_manager.FieldType{.array},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "tags", 6, "urgent" }, // contains
        },
    });
    defer root.free(allocator);

    const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(schema_manager.FieldType.array, filter.conditions.?[0].field_type);
    try testing.expectEqualStrings("urgent", filter.conditions.?[0].value.?.scalar.text);
}

test "contains on text rejects non-string operand" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"name"},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "name", 6, 42 }, // non-string for contains
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.InvalidOperandType, query_parser.parseQueryFilter(allocator, &sm, tbl.index, root));
}

test "startsWith on non-text field is rejected" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "users",
        .fields = &[_][]const u8{"age"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("users") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "age", 7, "1" }, // startsWith on integer
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.UnsupportedOperatorForFieldType, query_parser.parseQueryFilter(allocator, &sm, tbl.index, root));
}

test "isNull with operand is rejected" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"deleted_at"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    // Manually construct null condition with extra operand to bypass helper's valid construction
    var cond_arr = try allocator.alloc(msgpack.Payload, 3);
    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    cond_arr[0] = msgpack.Payload.uintToPayload(tbl.getFieldIndex("deleted_at") orelse return error.TestExpectedValue);
    cond_arr[1] = msgpack.Payload.uintToPayload(11); // isNull
    cond_arr[2] = msgpack.Payload.uintToPayload(1); // unexpected operand

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    var conds = try allocator.alloc(msgpack.Payload, 1);
    conds[0] = .{ .arr = cond_arr };
    try root.mapPut("conditions", .{ .arr = conds });

    try testing.expectError(error.UnexpectedOperand, query_parser.parseQueryFilter(allocator, &sm, tbl.index, root));
}

test "eq with nil operand is rejected" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"name"},
    }});
    defer sm.deinit();

    const tbl = sm.getTable("items") orelse return error.TestExpectedValue;
    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .conditions = .{
            .{ "name", 0, msgpack.Payload{ .nil = {} } },
        },
    });
    defer root.free(allocator);

    try testing.expectError(error.NullOperandUnsupported, query_parser.parseQueryFilter(allocator, &sm, tbl.index, root));
}

test "orderBy rejects invalid direction value" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"created_at"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    // Manually construct invalid orderBy
    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    var order_arr = try allocator.alloc(msgpack.Payload, 2);
    const tbl_items = sm.getTable("items") orelse return error.TestExpectedValue;
    order_arr[0] = msgpack.Payload.uintToPayload(tbl_items.getFieldIndex("created_at") orelse return error.TestExpectedValue);
    order_arr[1] = msgpack.Payload.uintToPayload(2); // invalid direction
    try root.mapPut("orderBy", .{ .arr = order_arr });

    try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &sm, tbl_items.index, root));
}

test "after is parsed using final orderBy regardless of map insertion order" {
    const allocator = testing.allocator;

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"created_at"},
        .types = &[_]schema_manager.FieldType{.integer},
    }});
    defer sm.deinit();

    var cursor_payload_arr = try allocator.alloc(msgpack.Payload, 2);
    const cursor_id: storage_engine.DocId = 2;
    const cursor_bytes = doc_id.toBytes(cursor_id);
    cursor_payload_arr[0] = msgpack.Payload.uintToPayload(42);
    cursor_payload_arr[1] = try msgpack.Payload.binToPayload(&cursor_bytes, allocator);
    const cursor_payload = msgpack.Payload{ .arr = cursor_payload_arr };
    defer cursor_payload.free(allocator);
    const after_token = try msgpack.encodeBase64(allocator, cursor_payload);
    defer allocator.free(after_token);

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    try root.mapPut("after", try msgpack.Payload.strToPayload(after_token, allocator));

    var order_arr = try allocator.alloc(msgpack.Payload, 2);
    const tbl_items = sm.getTable("items") orelse return error.TestExpectedValue;
    order_arr[0] = msgpack.Payload.uintToPayload(tbl_items.getFieldIndex("created_at") orelse return error.TestExpectedValue);
    order_arr[1] = msgpack.Payload.uintToPayload(1);
    try root.mapPut("orderBy", .{ .arr = order_arr });

    const filter = try query_parser.parseQueryFilter(allocator, &sm, tbl_items.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(i64, 42), filter.after.?.sort_value.scalar.integer);
}

test "cursor token rejects wrong sort type" {
    const allocator = testing.allocator;

    var cursor_payload = try allocator.alloc(msgpack.Payload, 2);
    const cursor_id: storage_engine.DocId = 2;
    const cursor_bytes = doc_id.toBytes(cursor_id);
    cursor_payload[0] = try msgpack.Payload.strToPayload("not-an-int", allocator);
    cursor_payload[1] = try msgpack.Payload.binToPayload(&cursor_bytes, allocator);
    const token_value = msgpack.Payload{ .arr = cursor_payload };
    defer token_value.free(allocator);
    const token = try msgpack.encodeBase64(allocator, token_value);
    defer allocator.free(token);

    try testing.expectError(error.InvalidCursorSortValue, query_parser.parseCursorToken(allocator, token, .integer, null));
}
