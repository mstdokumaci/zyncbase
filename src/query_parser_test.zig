const std = @import("std");
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const testing = std.testing;

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
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "users", root);
    defer filter.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), filter.conditions.?.len);
    try testing.expectEqualStrings("age", filter.conditions.?[0].field);
    try testing.expectEqual(query_parser.Operator.gte, filter.conditions.?[0].op);
    try testing.expectEqual(@as(u64, 18), filter.conditions.?[0].value.?.uint);

    try testing.expectEqualStrings("status", filter.conditions.?[1].field);
    try testing.expectEqual(query_parser.Operator.eq, filter.conditions.?[1].op);
    try testing.expectEqualStrings("active", filter.conditions.?[1].value.?.str.value());

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
    try testing.expectEqualStrings("admin", filter.or_conditions.?[0].value.?.str.value());
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

    // after: Base64(MsgPack(["val", "cursor_token"]))
    const after_token = "kqN2YWysY3Vyc29yX3Rva2Vu";
    try root.mapPut("after", try msgpack.Payload.strToPayload(after_token, allocator));

    var sm = try schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{.{
        .name = "items",
        .fields = &[_][]const u8{ "created_at", "val" },
    }});
    defer sm.deinit();

    const filter = try query_parser.parseQueryFilter(allocator, &sm, "items", root);
    defer filter.deinit(allocator);

    try testing.expect(filter.order_by != null);
    try testing.expectEqualStrings("created_at", filter.order_by.?.field);
    try testing.expectEqual(true, filter.order_by.?.desc);
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
