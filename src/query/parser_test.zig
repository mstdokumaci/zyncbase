const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const schema_system = @import("../schema/system.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const schema_types = @import("../schema/types.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const typed = @import("../typed/types.zig");
const query_ast = @import("ast.zig");
const query_hasher = @import("hasher.zig");
const query_parser = @import("parser.zig");
const qth = @import("test_helpers.zig");

const testing = std.testing;

/// Builds a canonical [clause, hidden id ASC] descriptor pair for tests.
fn twoClauseOrder(a: usize, a_desc: bool) [2]query_ast.SortDescriptor {
    return .{
        .{ .field_index = a, .desc = a_desc },
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
}

test "basic query filter parsing" {
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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

    try testing.expect(filter.predicate.or_clauses != null);
    try testing.expectEqual(@as(usize, 1), filter.predicate.or_clauses.?.len);
    try testing.expectEqual(@as(usize, 2), filter.predicate.or_clauses.?[0].len);
    try testing.expectEqual(role_index, filter.predicate.or_clauses.?[0][0].field_index);
    try testing.expectEqualStrings("admin", filter.predicate.or_clauses.?[0][0].value.?.scalar.text);
}

test "query with orderBy and after" {
    const allocator = std.testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{"val"},
        .types = &[_]schema_types.FieldType{.text},
    }});
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const created_at_index = tbl.fieldIndex("created_at") orelse return error.UnknownField;
    const descriptors = twoClauseOrder(created_at_index, true);
    const cursor_values = [_]typed.Value{
        .{ .scalar = .{ .integer = 42 } },
        .{ .scalar = .{ .doc_id = 2 } },
    };
    const after_token = try query_parser.encodeCursorToken(allocator, tbl.index, &descriptors, &cursor_values);
    defer allocator.free(after_token);

    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .orderBy = .{.{ "created_at", 1 }}, // desc
        .cursor = after_token,
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(created_at_index, filter.order_by[0].field_index);
    try testing.expectEqual(true, filter.order_by[0].desc);
    // Hidden `id ASC` tie-breaker appended.
    try testing.expectEqual(@as(usize, 2), filter.order_by.len);
    try testing.expectEqual(schema_system.id_field_index, filter.order_by[1].field_index);
    try testing.expectEqual(false, filter.order_by[1].desc);
    try testing.expectEqual(@as(i64, 42), filter.after.?.values[0].scalar.integer);
    try testing.expectEqual(@as(typed.DocId, 2), filter.after.?.values[1].scalar.doc_id);
}

test "query rejects invalid Base64 after cursor token" {
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    try testing.expect(filter.predicate.or_clauses == null);
}

test "in condition rejects non-array operand" {
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

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
    const allocator = std.testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer schema.deinit();

    // Manually construct invalid orderBy: outer array with one bad-direction tuple
    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    const tbl_items = schema.table("items") orelse return error.TestExpectedValue;
    var order_arr = try allocator.alloc(msgpack.Payload, 2);
    errdefer allocator.free(order_arr);
    order_arr[0] = msgpack.Payload.uintToPayload(tbl_items.fieldIndex("created_at") orelse return error.TestExpectedValue);
    order_arr[1] = msgpack.Payload.uintToPayload(2); // invalid direction
    const outer = try allocator.alloc(msgpack.Payload, 1);
    errdefer allocator.free(outer);
    outer[0] = .{ .arr = order_arr };
    try root.mapPut("orderBy", .{ .arr = outer });

    try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &schema, tbl_items.index, root));
}

test "after is parsed using final orderBy regardless of map insertion order" {
    const allocator = std.testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer schema.deinit();

    const tbl_items = schema.table("items") orelse return error.TestExpectedValue;
    const created_at_index = tbl_items.fieldIndex("created_at") orelse return error.TestExpectedValue;
    const descriptors = twoClauseOrder(created_at_index, true);
    const cursor_values = [_]typed.Value{
        .{ .scalar = .{ .integer = 42 } },
        .{ .scalar = .{ .doc_id = 2 } },
    };
    const after_token = try query_parser.encodeCursorToken(allocator, tbl_items.index, &descriptors, &cursor_values);
    defer allocator.free(after_token);

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    try root.mapPut("after", try msgpack.Payload.strToPayload(after_token, allocator));

    // Insert orderBy AFTER after to prove decoding waits for the canonical order.
    try putOrderBy(allocator, &root, &.{.{ created_at_index, 1 }});

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl_items.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(i64, 42), filter.after.?.values[0].scalar.integer);
}

test "cursor token rejects wrong sort type" {
    const allocator = std.testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{},
    }});
    defer schema.deinit();

    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const created_at_index = tbl.fieldIndex("created_at") orelse return error.UnknownField;
    const descriptors = twoClauseOrder(created_at_index, false);
    const values = [_]typed.Value{
        .{ .scalar = .{ .text = "not-an-int" } }, // created_at is integer
        .{ .scalar = .{ .doc_id = 2 } },
    };
    const token = try query_parser.encodeCursorToken(allocator, tbl.index, &descriptors, &values);
    defer allocator.free(token);

    try testing.expectError(
        error.InvalidCursorSortValue,
        query_parser.decodeCursorToken(allocator, token, tbl.index, tbl, &descriptors),
    );
}

fn emptyArrayPayload(allocator: std.mem.Allocator) !msgpack.Payload {
    return .{ .arr = try allocator.alloc(msgpack.Payload, 0) };
}

/// Builds and transfers an `orderBy` wire payload to `root`.
fn putOrderBy(allocator: std.mem.Allocator, root: *msgpack.Payload, clauses: []const [2]usize) !void {
    const outer = try allocator.alloc(msgpack.Payload, clauses.len);
    var populated: usize = 0;
    errdefer {
        for (outer[0..populated]) |c| c.free(allocator);
        allocator.free(outer);
    }
    for (clauses) |clause| {
        const tuple = try allocator.alloc(msgpack.Payload, 2);
        tuple[0] = msgpack.Payload.uintToPayload(clause[0]);
        tuple[1] = msgpack.Payload.uintToPayload(clause[1]);
        outer[populated] = .{ .arr = tuple };
        populated += 1;
    }
    try root.mapPut("orderBy", .{ .arr = outer });
}

fn itemsSchema(allocator: std.mem.Allocator, field_names: []const []const u8, field_types: []const schema_types.FieldType) !schema_types.Schema {
    return schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = field_names,
        .types = field_types,
    }});
}

test "canonical order: omitted becomes [id ASC]" {
    const allocator = std.testing.allocator;

    var schema = try itemsSchema(allocator, &.{}, &.{});
    defer schema.deinit();
    const tbl = schema.table("items") orelse return error.TestExpectedValue;

    const root = try qth.createQueryFilterPayload(allocator, tbl, .{});
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), filter.order_by.len);
    try testing.expectEqual(schema_system.id_field_index, filter.order_by[0].field_index);
    try testing.expectEqual(false, filter.order_by[0].desc);
}

test "canonical order: mixed-direction clauses preserve order and end with hidden id ASC" {
    const allocator = std.testing.allocator;

    var schema = try itemsSchema(allocator, &.{ "priority", "score" }, &.{ .integer, .integer });
    defer schema.deinit();
    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const priority_index = tbl.fieldIndex("priority") orelse return error.UnknownField;
    const created_at_index = tbl.fieldIndex("created_at") orelse return error.UnknownField;

    const root = try qth.createQueryFilterPayload(allocator, tbl, .{
        .orderBy = .{
            .{ "priority", @as(usize, 1) },
            .{ "created_at", @as(usize, 0) },
        },
    });
    defer root.free(allocator);

    var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(usize, 3), filter.order_by.len);
    try testing.expectEqual(priority_index, filter.order_by[0].field_index);
    try testing.expect(filter.order_by[0].desc);
    try testing.expectEqual(created_at_index, filter.order_by[1].field_index);
    try testing.expect(!filter.order_by[1].desc);
    try testing.expectEqual(schema_system.id_field_index, filter.order_by[2].field_index);
    try testing.expect(!filter.order_by[2].desc);
}

test "canonical order: explicit final id ASC is not duplicated; id DESC retained" {
    const allocator = std.testing.allocator;

    var schema = try itemsSchema(allocator, &.{}, &.{});
    defer schema.deinit();
    const tbl = schema.table("items") orelse return error.TestExpectedValue;

    // [{ id: 'asc' }] — identical canonical form to omitted order.
    {
        const root = try qth.createQueryFilterPayload(allocator, tbl, .{
            .orderBy = .{.{ "id", @as(usize, 0) }},
        });
        defer root.free(allocator);
        var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
        defer filter.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), filter.order_by.len);
        try testing.expectEqual(schema_system.id_field_index, filter.order_by[0].field_index);
        try testing.expect(!filter.order_by[0].desc);
    }

    // [{ id: 'desc' }] — direction retained, nothing appended.
    {
        const root = try qth.createQueryFilterPayload(allocator, tbl, .{
            .orderBy = .{.{ "id", @as(usize, 1) }},
        });
        defer root.free(allocator);
        var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
        defer filter.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), filter.order_by.len);
        try testing.expect(filter.order_by[0].desc);
    }
}

test "canonical order: id before another clause is rejected" {
    const allocator = std.testing.allocator;

    var schema = try itemsSchema(allocator, &.{"priority"}, &.{.integer});
    defer schema.deinit();
    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const id_index = schema_system.id_field_index;
    const priority_index = tbl.fieldIndex("priority") orelse return error.UnknownField;

    var root = msgpack.Payload.mapPayload(allocator);
    defer root.free(allocator);
    try putOrderBy(allocator, &root, &.{ .{ id_index, 0 }, .{ priority_index, 0 } });

    try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
}

test "structural hash includes table and ordered SQL shape but not cursor values" {
    const allocator = std.testing.allocator;

    var schema = try schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{
        .{ .name = "items", .fields = &.{ "priority", "score" }, .types = &.{ .integer, .integer } },
        .{ .name = "archive", .fields = &.{ "priority", "score" }, .types = &.{ .integer, .integer } },
    });
    defer schema.deinit();
    const items = schema.table("items") orelse return error.TestExpectedValue;
    const archive = schema.table("archive") orelse return error.TestExpectedValue;

    const Make = struct {
        fn filter(
            alloc: std.mem.Allocator,
            source_schema: *const schema_types.Schema,
            table: *const schema_types.Table,
            params: anytype,
        ) !query_ast.QueryFilter {
            const payload = try qth.createQueryFilterPayload(alloc, table, params);
            defer payload.free(alloc);
            return query_parser.parseQueryFilter(alloc, source_schema, table.index, payload);
        }
    };

    var default_items = try Make.filter(allocator, &schema, items, .{});
    defer default_items.deinit(allocator);
    var explicit_id = try Make.filter(allocator, &schema, items, .{ .orderBy = .{.{ "id", 0 }} });
    defer explicit_id.deinit(allocator);
    var default_archive = try Make.filter(allocator, &schema, archive, .{});
    defer default_archive.deinit(allocator);
    var priority_score = try Make.filter(allocator, &schema, items, .{
        .orderBy = .{ .{ "priority", 0 }, .{ "score", 1 } },
    });
    defer priority_score.deinit(allocator);
    var score_priority = try Make.filter(allocator, &schema, items, .{
        .orderBy = .{ .{ "score", 1 }, .{ "priority", 0 } },
    });
    defer score_priority.deinit(allocator);
    var flipped = try Make.filter(allocator, &schema, items, .{
        .orderBy = .{ .{ "priority", 1 }, .{ "score", 1 } },
    });
    defer flipped.deinit(allocator);

    const default_hash = query_hasher.computeStructuralHash(items.index, &default_items);
    try testing.expectEqual(default_hash, query_hasher.computeStructuralHash(items.index, &explicit_id));
    try testing.expect(default_hash != query_hasher.computeStructuralHash(archive.index, &default_archive));
    try testing.expect(
        query_hasher.computeStructuralHash(items.index, &priority_score) !=
            query_hasher.computeStructuralHash(items.index, &score_priority),
    );
    try testing.expect(
        query_hasher.computeStructuralHash(items.index, &priority_score) !=
            query_hasher.computeStructuralHash(items.index, &flipped),
    );

    var with_values = try priority_score.clone(allocator);
    defer with_values.deinit(allocator);
    const cursor_values = try allocator.alloc(typed.Value, with_values.order_by.len);
    cursor_values[0] = .{ .scalar = .{ .integer = 4 } };
    cursor_values[1] = .{ .scalar = .{ .integer = 9 } };
    cursor_values[2] = .{ .scalar = .{ .doc_id = 2 } };
    with_values.after = .{ .values = cursor_values };

    var with_null = try priority_score.clone(allocator);
    defer with_null.deinit(allocator);
    const null_cursor_values = try allocator.alloc(typed.Value, with_null.order_by.len);
    null_cursor_values[0] = .nil;
    null_cursor_values[1] = .{ .scalar = .{ .integer = 1 } };
    null_cursor_values[2] = .{ .scalar = .{ .doc_id = 3 } };
    with_null.after = .{ .values = null_cursor_values };

    const without_cursor_hash = query_hasher.computeStructuralHash(items.index, &priority_score);
    const with_values_hash = query_hasher.computeStructuralHash(items.index, &with_values);
    try testing.expect(without_cursor_hash != with_values_hash);
    try testing.expectEqual(with_values_hash, query_hasher.computeStructuralHash(items.index, &with_null));
}

test "sort rejects: empty array, duplicates, ninth clause, unknown field, array field" {
    const allocator = std.testing.allocator;

    var schema = try itemsSchema(
        allocator,
        &.{ "a", "b", "tags" },
        &.{ .integer, .integer, .array },
    );
    defer schema.deinit();
    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const a_index = tbl.fieldIndex("a") orelse return error.UnknownField;
    const b_index = tbl.fieldIndex("b") orelse return error.UnknownField;
    const tags_index = tbl.fieldIndex("tags") orelse return error.UnknownField;

    // Empty outer array
    {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);
        try root.mapPut("orderBy", try emptyArrayPayload(allocator));
        try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
    }

    // Duplicate field
    {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);
        try putOrderBy(allocator, &root, &.{ .{ a_index, 0 }, .{ b_index, 1 }, .{ a_index, 0 } });
        try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
    }

    // Ninth client clause
    {
        var clauses: [9][2]usize = undefined;
        // Alternate two distinct fields is invalid (dup), so use distinct valid indexes:
        // only a/b exist as user fields; use system fields too — they are distinct fields.
        clauses[0] = .{ a_index, 0 };
        clauses[1] = .{ b_index, 0 };
        clauses[2] = .{ schema_system.namespace_id_field_index, 0 };
        clauses[3] = .{ schema_system.owner_id_field_index, 0 };
        clauses[4] = .{ tbl.fieldIndex("created_at") orelse return error.UnknownField, 0 };
        clauses[5] = .{ tbl.fieldIndex("updated_at") orelse return error.UnknownField, 0 };
        clauses[6] = .{ a_index + 100, 0 };
        clauses[7] = .{ b_index, 1 };
        clauses[8] = .{ a_index, 1 };
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);
        try putOrderBy(allocator, &root, &clauses);
        try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
    }

    // Unknown field index
    {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);
        try putOrderBy(allocator, &root, &.{.{ a_index + 100, 0 }});
        try testing.expectError(error.UnknownField, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
    }

    // Array field sort → UnsupportedSortFieldType
    {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);
        try putOrderBy(allocator, &root, &.{.{ tags_index, 0 }});
        try testing.expectError(error.UnsupportedSortFieldType, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
    }

    // Non-array orderBy value
    {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);
        try root.mapPut("orderBy", msgpack.Payload.uintToPayload(a_index));
        try testing.expectError(error.InvalidSortFormat, query_parser.parseQueryFilter(allocator, &schema, tbl.index, root));
    }
}

test "cursor round-trip with mixed text, integer, null, reference values" {
    const allocator = std.testing.allocator;

    var schema = try itemsSchema(
        allocator,
        &.{ "title", "score", "note", "ref" },
        &.{ .text, .integer, .text, .doc_id },
    );
    defer schema.deinit();
    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const title_index = tbl.fieldIndex("title") orelse return error.UnknownField;
    const score_index = tbl.fieldIndex("score") orelse return error.UnknownField;
    const note_index = tbl.fieldIndex("note") orelse return error.UnknownField;
    const ref_index = tbl.fieldIndex("ref") orelse return error.UnknownField;

    // note is optional in this fixture; ref is doc_id.
    const descriptors = [_]query_ast.SortDescriptor{
        .{ .field_index = title_index, .desc = true },
        .{ .field_index = score_index, .desc = false },
        .{ .field_index = note_index, .desc = false },
        .{ .field_index = ref_index, .desc = false },
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
    const values = [_]typed.Value{
        .{ .scalar = .{ .text = "t" } },
        .{ .scalar = .{ .integer = 42 } },
        .nil,
        .{ .scalar = .{ .doc_id = 42 } },
        .{ .scalar = .{ .doc_id = 7 } },
    };

    const token = try query_parser.encodeCursorToken(allocator, tbl.index, &descriptors, &values);
    defer allocator.free(token);

    var cursor = try query_parser.decodeCursorToken(allocator, token, tbl.index, tbl, &descriptors);
    defer cursor.deinit(allocator);

    try testing.expectEqual(descriptors.len, cursor.values.len);
    for (cursor.values, values) |actual, expected| try testing.expect(actual.eql(expected));
}

test "cursor rejects wrong table, reordered descriptors, null required value, trailing bytes" {
    const allocator = std.testing.allocator;

    var schema = try itemsSchema(allocator, &.{"score"}, &.{.integer});
    defer schema.deinit();
    const tbl = schema.table("items") orelse return error.TestExpectedValue;
    const score_index = tbl.fieldIndex("score") orelse return error.UnknownField;

    const descriptors = [_]query_ast.SortDescriptor{
        .{ .field_index = score_index, .desc = false },
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
    const values = [_]typed.Value{
        .{ .scalar = .{ .integer = 5 } },
        .{ .scalar = .{ .doc_id = 7 } },
    };
    const token = try query_parser.encodeCursorToken(allocator, tbl.index, &descriptors, &values);
    defer allocator.free(token);

    // Wrong table index
    try testing.expectError(
        error.InvalidCursorSortValue,
        query_parser.decodeCursorToken(allocator, token, tbl.index + 1, tbl, &descriptors),
    );

    // Reordered descriptor list
    const reordered = [_]query_ast.SortDescriptor{
        .{ .field_index = schema_system.id_field_index, .desc = false },
        .{ .field_index = score_index, .desc = false },
    };
    try testing.expectError(
        error.InvalidCursorSortValue,
        query_parser.decodeCursorToken(allocator, token, tbl.index, tbl, &reordered),
    );

    // Wrong direction on the first clause
    const flipped = [_]query_ast.SortDescriptor{
        .{ .field_index = score_index, .desc = true },
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
    try testing.expectError(
        error.InvalidCursorSortValue,
        query_parser.decodeCursorToken(allocator, token, tbl.index, tbl, &flipped),
    );

    // Null for the required id field
    const null_values = [_]typed.Value{
        .{ .scalar = .{ .integer = 5 } },
        .nil,
    };
    const null_token = try query_parser.encodeCursorToken(allocator, tbl.index, &descriptors, &null_values);
    defer allocator.free(null_token);
    try testing.expectError(
        error.InvalidCursorSortValue,
        query_parser.decodeCursorToken(allocator, null_token, tbl.index, tbl, &descriptors),
    );

    // Trailing bytes after the MessagePack payload must be rejected.
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(token);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, token);
    const with_trailing = try allocator.alloc(u8, decoded_len + 1);
    defer allocator.free(with_trailing);
    @memcpy(with_trailing[0..decoded_len], decoded);
    with_trailing[decoded_len] = 0xc0; // stray nil byte
    const Encoder = std.base64.standard.Encoder;
    const trailing_token = try allocator.alloc(u8, Encoder.calcSize(with_trailing.len));
    defer allocator.free(trailing_token);
    _ = Encoder.encode(trailing_token, with_trailing);
    try testing.expectError(
        error.InvalidMessageFormat,
        query_parser.decodeCursorToken(allocator, trailing_token, tbl.index, tbl, &descriptors),
    );
}

test "property: random valid query filters" {
    const allocator = std.testing.allocator;
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
            var populated: usize = 0;
            errdefer {
                for (conds_arr[0..populated]) |c| c.free(allocator);
                allocator.free(conds_arr);
            }
            for (conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false, field_index, .text);
                populated += 1;
            }
            try root.mapPut("conditions", .{ .arr = conds_arr });
        }

        if (random.boolean()) {
            const num_or_conds = random.intRangeAtMost(usize, 0, 5);
            const or_conds_arr = try allocator.alloc(msgpack.Payload, num_or_conds);
            var populated: usize = 0;
            errdefer {
                for (or_conds_arr[0..populated]) |c| c.free(allocator);
                allocator.free(or_conds_arr);
            }
            for (or_conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false, field_index, .text);
                populated += 1;
            }
            try root.mapPut("orConditions", .{ .arr = or_conds_arr });
        }

        if (random.boolean()) {
            const outer = try allocator.alloc(msgpack.Payload, 1);
            errdefer allocator.free(outer);
            var order_arr = try allocator.alloc(msgpack.Payload, 2);
            errdefer allocator.free(order_arr);
            order_arr[0] = msgpack.Payload.uintToPayload(field_index);
            order_arr[1] = msgpack.Payload.uintToPayload(if (random.boolean()) 1 else 0);
            outer[0] = .{ .arr = order_arr };
            try root.mapPut("orderBy", .{ .arr = outer });
        }
        var filter = try query_parser.parseQueryFilter(allocator, &schema, tbl.index, root);
        filter.deinit(allocator);
    }
}

test "property: reject unknown field names" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();

    for (0..50) |_| {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);

        // Add a condition with a field index not in schema
        const conds_arr = try allocator.alloc(msgpack.Payload, 1);
        var populated: usize = 0;
        errdefer {
            for (conds_arr[0..populated]) |c| c.free(allocator);
            allocator.free(conds_arr);
        }
        conds_arr[0] = try generateRandomCondition(allocator, random, true, 0, .text);
        populated += 1;
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
        errdefer allocator.free(cond);
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
            errdefer allocator.free(arr);
            arr[0] = try msgpack.Payload.strToPayload("v", allocator);
            break :blk .{ .arr = arr };
        },
    };
}

fn randomInValueForType(allocator: std.mem.Allocator, random: std.Random, field_type: schema_types.FieldType) !msgpack.Payload {
    const len = random.intRangeAtMost(usize, 0, 3);
    const arr = try allocator.alloc(msgpack.Payload, len);
    var populated: usize = 0;
    errdefer {
        for (arr[0..populated]) |item| item.free(allocator);
        allocator.free(arr);
    }
    for (arr) |*item| {
        item.* = try randomValueForType(allocator, random, field_type);
        populated += 1;
    }
    return .{ .arr = arr };
}
