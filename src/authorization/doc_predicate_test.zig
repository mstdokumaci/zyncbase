const std = @import("std");
const msgpack = @import("msgpack");
const testing = std.testing;
const authorization_types = @import("types.zig");
const authorization_evaluate = @import("evaluate.zig");
const authorization_doc_predicate = @import("doc_predicate.zig");
const query_ast = @import("../query/ast.zig");
const typed = @import("../typed/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const schema_system = @import("../schema/system.zig");
const auth_helpers = @import("test_helpers.zig");

const EvalContext = authorization_evaluate.EvalContext;
const ScalarValue = typed.ScalarValue;

// ─── Doc Predicate Tests ────────────────────────────────────────────────────

test "buildDocPredicate produces filter predicate for $doc comparison" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{});
    defer table.deinit(allocator);

    const test_id = typed_doc_id.generateUuidV7();
    const eval_ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };

    var predicate = (try authorization_doc_predicate.buildDocPredicate(config.store_rules[0].write, eval_ctx, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.conditions != null);
    try testing.expectEqual(@as(usize, 1), predicate.conditions.?.len);
    try testing.expect(predicate.or_conditions == null);
    const condition = predicate.conditions.?[0];
    try testing.expectEqual(query_ast.Operator.eq, condition.op);
    try testing.expect(condition.value != null);
    try testing.expect(condition.value.? == .scalar);
    try testing.expect(condition.value.?.scalar == .doc_id);
    try testing.expect(typed_doc_id.eql(condition.value.?.scalar.doc_id, test_id));
    try testing.expectEqual(schema_system.owner_id_field_index, condition.field_index);
}

test "buildDocPredicate returns null for RAM-only allow" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":true}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{});
    defer table.deinit(allocator);

    const predicate = try authorization_doc_predicate.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table);
    try testing.expect(predicate == null);
}

test "buildDocPredicate normalizes $doc notIn empty set to no guard" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"notIn":[]}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    const predicate = try authorization_doc_predicate.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table);
    try testing.expect(predicate == null);
}

test "buildDocPredicate preserves $doc in empty set as match none guard" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"in":[]}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    var predicate = (try authorization_doc_predicate.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.isAlwaysFalse());
    try testing.expect(predicate.conditions == null);
    try testing.expect(predicate.or_conditions == null);
}

test "buildDocPredicate clones borrowed literal RHS into predicate" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"eq":"public"}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    var predicate = (try authorization_doc_predicate.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    const literal_text = (config.store_rules[0].write.comparison.rhs orelse return error.TestExpectedValue).literal.scalar.text;
    const conditions = predicate.conditions orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), conditions.len);
    const predicate_value = conditions[0].value orelse return error.TestExpectedValue;
    try testing.expect(predicate_value == .scalar);
    try testing.expect(predicate_value.scalar == .text);
    const predicate_text = predicate_value.scalar.text;
    try testing.expectEqualStrings("public", predicate_text);
    try testing.expect(predicate_text.ptr != literal_text.ptr);
}

test "buildDocPredicate resolves value RHS from incoming payload" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"eq":"$value.visibility"}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    const visibility_idx = table.fieldIndex("visibility").?; // zwanzig-disable-line: optional-unwrap
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(visibility_idx);
    pair[1] = try msgpack.Payload.strToPayload("private", allocator);
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var payload = msgpack.Payload{ .arr = pairs };
    defer payload.free(allocator);

    const eval_ctx = EvalContext{
        .allocator = allocator,
        .value_payload = &payload,
        .value_table = &table,
    };

    var predicate = (try authorization_doc_predicate.buildDocPredicate(config.store_rules[0].write, eval_ctx, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    const conditions = predicate.conditions orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), conditions.len);
    const condition = conditions[0];
    const condition_value = condition.value orelse return error.TestExpectedValue;
    try testing.expect(condition_value == .scalar);
    try testing.expect(condition_value.scalar == .text);
    try testing.expectEqualStrings("private", condition_value.scalar.text);
}

test "validateDocPredicate rejects array literal items with wrong type" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "tags", .field_type = .array, .items_type = .text },
    });
    defer table.deinit(allocator);

    const items = try allocator.alloc(ScalarValue, 1);
    items[0] = .{ .integer = 42 };
    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .eq,
        .rhs = .{ .literal = .{ .array = items } },
    } };
    defer condition.deinit(allocator);

    try testing.expectError(error.InvalidValue, authorization_doc_predicate.validateDocPredicate(condition, &table));
}

test "validateDocPredicate rejects $value array item type mismatch" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "tags", .field_type = .array, .items_type = .text },
        .{ .name = "scores", .field_type = .array, .items_type = .integer },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .eq,
        .rhs = .{ .context_var = .{ .scope = .value, .field = try allocator.dupe(u8, "scores") } },
    } };
    defer condition.deinit(allocator);

    try testing.expectError(error.InvalidValue, authorization_doc_predicate.validateDocPredicate(condition, &table));
}

test "validateDocPredicate validates context variable shape by operator" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
        .{ .name = "allowed_visibility", .field_type = .array, .items_type = .text },
        .{ .name = "tags", .field_type = .array, .items_type = .text },
    });
    defer table.deinit(allocator);

    var valid_in = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "visibility") },
        .op = .in,
        .rhs = .{ .context_var = .{ .scope = .value, .field = try allocator.dupe(u8, "allowed_visibility") } },
    } };
    defer valid_in.deinit(allocator);
    try authorization_doc_predicate.validateDocPredicate(valid_in, &table);

    var scalar_in = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "visibility") },
        .op = .in,
        .rhs = .{ .context_var = .{ .scope = .session, .field = try allocator.dupe(u8, "externalId") } },
    } };
    defer scalar_in.deinit(allocator);
    try testing.expectError(error.InvalidValue, authorization_doc_predicate.validateDocPredicate(scalar_in, &table));

    var array_contains_array = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .contains,
        .rhs = .{ .context_var = .{ .scope = .value, .field = try allocator.dupe(u8, "tags") } },
    } };
    defer array_contains_array.deinit(allocator);
    try testing.expectError(error.InvalidValue, authorization_doc_predicate.validateDocPredicate(array_contains_array, &table));
}

test "buildDocPredicate preserves logical_or predicate" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"or":[{"$doc.owner_id":{"eq":"$session.userId"}},{"$doc.visibility":{"eq":"public"}}]}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    const test_id = typed_doc_id.generateUuidV7();
    const eval_ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };

    var predicate = (try authorization_doc_predicate.buildDocPredicate(config.store_rules[0].write, eval_ctx, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.conditions == null);
    try testing.expect(predicate.or_conditions != null);
    try testing.expectEqual(@as(usize, 2), predicate.or_conditions.?.len);
    try testing.expectEqual(schema_system.owner_id_field_index, predicate.or_conditions.?[0].field_index);
    try testing.expectEqual(query_ast.Operator.eq, predicate.or_conditions.?[0].op);
    try testing.expectEqual(query_ast.Operator.eq, predicate.or_conditions.?[1].op);
    try testing.expect(predicate.or_conditions.?[1].value.?.scalar == .text);
    try testing.expectEqualStrings("public", predicate.or_conditions.?[1].value.?.scalar.text);
}

// ─── validateLiteralValue Tests ─────────────────────────────────────────────
// These tests exercise validateLiteralValue indirectly via validateDocPredicate.
// Each test constructs a doc-scoped comparison with a literal RHS and calls
// validateDocPredicate, which routes through validateDocComparison →
// validateLiteralValue.

test "validateLiteralValue in with valid array of text scalars passes" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "status", .field_type = .text },
    });
    defer table.deinit(allocator);

    const items = try allocator.alloc(ScalarValue, 2);
    items[0] = .{ .text = try allocator.dupe(u8, "active") };
    items[1] = .{ .text = try allocator.dupe(u8, "pending") };
    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "status") },
        .op = .in,
        .rhs = .{ .literal = .{ .array = items } },
    } };
    defer condition.deinit(allocator);

    try authorization_doc_predicate.validateDocPredicate(condition, &table);
}

test "validateLiteralValue in with non-array value returns error.InvalidValue" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "status", .field_type = .text },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "status") },
        .op = .in,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "active") } } },
    } };
    defer condition.deinit(allocator);

    try testing.expectError(error.InvalidValue, authorization_doc_predicate.validateDocPredicate(condition, &table));
}

test "validateLiteralValue notIn with valid array of text scalars passes" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "status", .field_type = .text },
    });
    defer table.deinit(allocator);

    const items = try allocator.alloc(ScalarValue, 1);
    items[0] = .{ .text = try allocator.dupe(u8, "banned") };
    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "status") },
        .op = .notIn,
        .rhs = .{ .literal = .{ .array = items } },
    } };
    defer condition.deinit(allocator);

    try authorization_doc_predicate.validateDocPredicate(condition, &table);
}

test "validateLiteralValue contains with array field and scalar value passes" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "tags", .field_type = .array, .items_type = .text },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .contains,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "zig") } } },
    } };
    defer condition.deinit(allocator);

    try authorization_doc_predicate.validateDocPredicate(condition, &table);
}

test "validateLiteralValue contains with text field and text scalar passes" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "description", .field_type = .text },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "description") },
        .op = .contains,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "hello") } } },
    } };
    defer condition.deinit(allocator);

    try authorization_doc_predicate.validateDocPredicate(condition, &table);
}

test "validateLiteralValue contains with non-scalar value returns error.InvalidValue" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "tags", .field_type = .array, .items_type = .text },
    });
    defer table.deinit(allocator);

    // Passing an array where a scalar is required
    const items = try allocator.alloc(ScalarValue, 1);
    items[0] = .{ .text = try allocator.dupe(u8, "zig") };
    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .contains,
        .rhs = .{ .literal = .{ .array = items } },
    } };
    defer condition.deinit(allocator);

    try testing.expectError(error.InvalidValue, authorization_doc_predicate.validateDocPredicate(condition, &table));
}

test "validateLiteralValue generic eq operator with scalar value passes" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "score", .field_type = .integer },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "score") },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .integer = 42 } } },
    } };
    defer condition.deinit(allocator);

    try authorization_doc_predicate.validateDocPredicate(condition, &table);
}

// ─── Create Auth Tests (authorizeWriteCondition) ───────────────────────────

test "authorizeWriteCondition denies create when $doc rule fails" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "status", .field_type = .text },
    });
    defer table.deinit(allocator);

    const status_field = try allocator.dupe(u8, "status");
    const condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = status_field },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "draft") } } },
    } };
    defer condition.deinit(allocator);

    const status_idx = table.fieldIndex("status").?; // zwanzig-disable-line: optional-unwrap
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(status_idx);
    pair[1] = try msgpack.Payload.strToPayload("published", allocator);
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var payload = msgpack.Payload{ .arr = pairs };
    defer payload.free(allocator);

    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = typed_doc_id.generateUuidV7(),
        .doc_id = typed_doc_id.generateUuidV7(),
        .owner_doc_id = typed_doc_id.generateUuidV7(),
        .value_payload = &payload,
        .value_table = &table,
    };

    const result = authorization_doc_predicate.authorizeWriteCondition(condition, ctx, &table, true);
    try testing.expectError(error.AccessDenied, result);
}

test "authorizeWriteCondition allows create and returns predicate when $doc rule passes" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{});
    defer table.deinit(allocator);

    const test_id = typed_doc_id.generateUuidV7();
    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
        .doc_id = typed_doc_id.generateUuidV7(),
        .owner_doc_id = test_id,
        .value_table = &table,
    };

    var predicate = try authorization_doc_predicate.authorizeWriteCondition(config.store_rules[0].write, ctx, &table, true);
    if (predicate) |*p| {
        defer p.deinit(allocator);
    }

    try testing.expect(predicate != null);
}

// ─── New operator tests (lower to query_ast) ────────────────────────────────

test "buildDocPredicate lowers isNull to query_ast.Condition with null value" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "deletedAt", .field_type = .text },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "deletedAt") },
        .op = .isNull,
        .rhs = null,
    } };
    defer condition.deinit(allocator);

    var predicate = (try authorization_doc_predicate.buildDocPredicate(condition, .{ .allocator = allocator }, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.conditions != null);
    try testing.expectEqual(@as(usize, 1), predicate.conditions.?.len);
    const cond = predicate.conditions.?[0];
    try testing.expectEqual(query_ast.Operator.isNull, cond.op);
    try testing.expect(cond.value == null);
}

test "buildDocPredicate lowers isNotNull to query_ast.Condition with null value" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "deletedAt", .field_type = .text },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "deletedAt") },
        .op = .isNotNull,
        .rhs = null,
    } };
    defer condition.deinit(allocator);

    var predicate = (try authorization_doc_predicate.buildDocPredicate(condition, .{ .allocator = allocator }, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.conditions != null);
    const cond = predicate.conditions.?[0];
    try testing.expectEqual(query_ast.Operator.isNotNull, cond.op);
    try testing.expect(cond.value == null);
}

test "buildDocPredicate lowers startsWith to query_ast.Condition with text value" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "visibility") },
        .op = .startsWith,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "pub") } } },
    } };
    defer condition.deinit(allocator);

    var predicate = (try authorization_doc_predicate.buildDocPredicate(condition, .{ .allocator = allocator }, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.conditions != null);
    const cond = predicate.conditions.?[0];
    try testing.expectEqual(query_ast.Operator.startsWith, cond.op);
    try testing.expect(cond.value != null);
    try testing.expect(cond.value.? == .scalar);
    try testing.expect(cond.value.?.scalar == .text);
    try testing.expectEqualStrings("pub", cond.value.?.scalar.text);
}

test "validateDocPredicate rejects startsWith on non-text field" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "score", .field_type = .integer },
    });
    defer table.deinit(allocator);

    var condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "score") },
        .op = .startsWith,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "prefix") } } },
    } };
    defer condition.deinit(allocator);

    try testing.expectError(error.UnsupportedOperatorForFieldType, authorization_doc_predicate.validateDocPredicate(condition, &table));
}
