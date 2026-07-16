const std = @import("std");
const msgpack = @import("msgpack");
const testing = std.testing;
const authorization_types = @import("types.zig");
const authorization_evaluate = @import("evaluate.zig");
const typed = @import("../typed/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const auth_helpers = @import("test_helpers.zig");

const EvalContext = authorization_evaluate.EvalContext;
const ScalarValue = typed.ScalarValue;

// ─── RAM Evaluator Tests ────────────────────────────────────────────────────

test "evaluateCondition boolean true allows" {
    var config = try auth_helpers.implicitTestConfig(testing.allocator);
    defer config.deinit();

    const result = authorization_evaluate.evaluateCondition(.{ .boolean = true }, .{ .allocator = testing.allocator });
    try testing.expect(result == .allow);
}

test "evaluateCondition boolean false denies" {
    var config = try auth_helpers.implicitTestConfig(testing.allocator);
    defer config.deinit();

    const result = authorization_evaluate.evaluateCondition(.{ .boolean = false }, .{ .allocator = testing.allocator });
    try testing.expect(result == .deny);
}

test "evaluateCondition $doc reference returns needs_doc_predicate" {
    const allocator = testing.allocator;
    const cond = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "owner_id") },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "test") } } },
    } };
    defer cond.deinit(allocator);

    const result = authorization_evaluate.evaluateCondition(cond, .{ .allocator = allocator });
    try testing.expect(result == .needs_doc_predicate);
}

test "evaluateCondition $session.userId comparison" {
    const allocator = testing.allocator;
    const cond = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .session, .field = try allocator.dupe(u8, "userId") },
        .op = .eq,
        .rhs = .{ .context_var = .{ .scope = .session, .field = try allocator.dupe(u8, "userId") } },
    } };
    defer cond.deinit(allocator);

    const test_id = typed_doc_id.generateUuidV7();
    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };
    const result = authorization_evaluate.evaluateCondition(cond, ctx);
    try testing.expect(result == .allow);
}

test "evaluateCondition $namespace capture lookup" {
    const allocator = testing.allocator;
    const cond = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .namespace, .field = try allocator.dupe(u8, "tenant_id") },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "acme") } } },
    } };
    defer cond.deinit(allocator);

    var captures = std.StringHashMapUnmanaged([]const u8){};
    defer captures.deinit(allocator);
    try captures.put(allocator, "tenant_id", "acme");

    const ctx = EvalContext{
        .allocator = allocator,
        .namespace_captures = &captures,
    };
    const result = authorization_evaluate.evaluateCondition(cond, ctx);
    try testing.expect(result == .allow);
}

test "evaluateCondition logical_and short-circuits on deny" {
    const allocator = testing.allocator;
    const conds = try allocator.alloc(authorization_types.Condition, 2);
    conds[0] = .{ .boolean = true };
    conds[1] = .{ .boolean = false };

    const cond = authorization_types.Condition{ .logical_and = conds };
    defer cond.deinit(allocator);

    const result = authorization_evaluate.evaluateCondition(cond, .{ .allocator = allocator });
    try testing.expect(result == .deny);
}

test "evaluateCondition logical_or short-circuits on allow" {
    const allocator = testing.allocator;
    const conds = try allocator.alloc(authorization_types.Condition, 2);
    conds[0] = .{ .boolean = false };
    conds[1] = .{ .boolean = true };

    const cond = authorization_types.Condition{ .logical_or = conds };
    defer cond.deinit(allocator);

    const result = authorization_evaluate.evaluateCondition(cond, .{ .allocator = allocator });
    try testing.expect(result == .allow);
}

test "evaluateCondition in works with array" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const arr = try arena_allocator.alloc(ScalarValue, 2);
    arr[0] = .{ .text = try arena_allocator.dupe(u8, "acme") };
    arr[1] = .{ .text = try arena_allocator.dupe(u8, "globex") };

    const cond = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .namespace, .field = try arena_allocator.dupe(u8, "tenant_id") },
        .op = .in,
        .rhs = .{ .literal = .{ .array = arr } },
    } };
    // No defer deinit — all memory is arena-owned

    var captures = std.StringHashMapUnmanaged([]const u8){};
    defer captures.deinit(allocator);
    try captures.put(allocator, "tenant_id", "acme");

    const ctx = EvalContext{
        .allocator = arena_allocator,
        .namespace_captures = &captures,
    };
    const result = authorization_evaluate.evaluateCondition(cond, ctx);
    try testing.expect(result == .allow);
}

// ─── Namespace Rule Lookup Tests ────────────────────────────────────────────

test "authorizeNamespace enforces storeFilter" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"tenant:{tenant_id}","storeFilter":{"$namespace.tenant_id":{"eq":"acme"}},"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    try authorization_evaluate.authorizeNamespace(allocator, &config, "tenant:acme", user_id, "external-1", null, false);
    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizeNamespace(allocator, &config, "tenant:globex", user_id, "external-1", null, false));
    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizeNamespace(allocator, &config, "public", user_id, "external-1", null, false));
}

test "authorizeNamespace enforces presenceRead" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    try authorization_evaluate.authorizeNamespace(allocator, &config, "room:lobby", user_id, "external-1", null, true);
    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizeNamespace(allocator, &config, "unknown:xyz", user_id, "external-1", null, true));
}

test "authorizeNamespace denies when presenceRead is false" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"private:{id}","storeFilter":true,"presenceRead":false,"presenceWrite":true}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizeNamespace(allocator, &config, "private:secret", user_id, "external-1", null, true));
}

test "ResolvedAuthValue intoOwned moves owned value and makes deinit no-op" {
    const allocator = testing.allocator;

    const text = try allocator.dupe(u8, "private");
    const original_ptr = text.ptr;
    var resolved = authorization_evaluate.ResolvedAuthValue.fromOwned(.{ .scalar = .{ .text = text } });

    var owned_value = try resolved.intoOwned(allocator);
    defer owned_value.deinit(allocator);

    try testing.expect(owned_value == .scalar);
    try testing.expect(owned_value.scalar == .text);
    try testing.expect(owned_value.scalar.text.ptr == original_ptr);
    try testing.expectEqual(std.meta.activeTag(authorization_evaluate.ResolvedAuthValue{ .borrowed = .nil }), std.meta.activeTag(resolved));

    resolved.deinit(allocator);
}

// ─── Create Auth Tests (evaluateConditionWithDoc) ───────────────────────────

test "evaluateConditionWithDoc allows $doc.owner_id == $session.userId when owner matches" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const test_id = typed_doc_id.generateUuidV7();
    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
        .owner_doc_id = test_id,
    };

    const result = authorization_evaluate.evaluateConditionWithDoc(config.store_rules[0].write, ctx);
    try testing.expect(result);
}

test "evaluateConditionWithDoc denies $doc.owner_id == $session.userId when owner differs" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const session_id = typed_doc_id.generateUuidV7();
    const other_id = typed_doc_id.generateUuidV7();
    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = session_id,
        .owner_doc_id = other_id,
    };

    const result = authorization_evaluate.evaluateConditionWithDoc(config.store_rules[0].write, ctx);
    try testing.expect(!result);
}

test "evaluateConditionWithDoc denies when $doc field is absent from candidate" {
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

    var payload = msgpack.Payload{ .arr = try allocator.alloc(msgpack.Payload, 0) };
    defer payload.free(allocator);

    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = typed_doc_id.generateUuidV7(),
        .doc_id = typed_doc_id.generateUuidV7(),
        .owner_doc_id = typed_doc_id.generateUuidV7(),
        .value_payload = &payload,
        .value_table = &table,
    };

    const result = authorization_evaluate.evaluateConditionWithDoc(condition, ctx);
    try testing.expect(!result);
}

test "evaluateConditionWithDoc allows $doc.status == draft when status is draft" {
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
    pair[1] = try msgpack.Payload.strToPayload("draft", allocator);
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

    const result = authorization_evaluate.evaluateConditionWithDoc(condition, ctx);
    try testing.expect(result);
}

test "evaluateConditionWithDoc denies $doc.status == draft when status is published" {
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

    const result = authorization_evaluate.evaluateConditionWithDoc(condition, ctx);
    try testing.expect(!result);
}

test "duplicate field index in value pair-array resolves to last-wins" {
    const allocator = testing.allocator;

    var table = schema_helpers.makeSingleRuntimeTable(allocator, "test", &[_]schema_helpers.TestFieldDef{
        .{ .name = "status", .field_type = .text },
    });
    defer table.deinit(allocator);

    const status_idx = table.fieldIndex("status").?; // zwanzig-disable-line: optional-unwrap

    // Build pair-array with duplicate field index: [[idx, "first"], [idx, "second"]]
    var pair1 = try allocator.alloc(msgpack.Payload, 2);
    pair1[0] = msgpack.Payload.uintToPayload(status_idx);
    pair1[1] = try msgpack.Payload.strToPayload("first", allocator);
    var pair2 = try allocator.alloc(msgpack.Payload, 2);
    pair2[0] = msgpack.Payload.uintToPayload(status_idx);
    pair2[1] = try msgpack.Payload.strToPayload("second", allocator);
    var pairs = try allocator.alloc(msgpack.Payload, 2);
    pairs[0] = .{ .arr = pair1 };
    pairs[1] = .{ .arr = pair2 };
    var payload = msgpack.Payload{ .arr = pairs };
    defer payload.free(allocator);

    // Condition: $value.status == "second" (should pass with last-wins)
    const status_field = try allocator.dupe(u8, "status");
    const condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .value, .field = status_field },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "second") } } },
    } };
    defer condition.deinit(allocator);

    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = typed_doc_id.generateUuidV7(),
        .doc_id = typed_doc_id.generateUuidV7(),
        .owner_doc_id = typed_doc_id.generateUuidV7(),
        .value_payload = &payload,
        .value_table = &table,
    };

    const result = authorization_evaluate.evaluateConditionWithDoc(condition, ctx);
    try testing.expect(result);
}

// ─── New operator tests ───────────────────────────────────────────────────────

test "evaluateCondition: isNull allows when session field is absent" {
    const allocator = testing.allocator;

    const condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .session, .field = "userId" },
        .op = .isNull,
        .rhs = null,
    } };

    const ctx = EvalContext{ .allocator = allocator, .session_user_id = null };
    try testing.expectEqual(.allow, authorization_evaluate.evaluateCondition(condition, ctx));
}

test "evaluateCondition: isNull denies when session field is present" {
    const allocator = testing.allocator;

    const test_id = typed_doc_id.generateUuidV7();
    const condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .session, .field = "userId" },
        .op = .isNull,
        .rhs = null,
    } };

    const ctx = EvalContext{ .allocator = allocator, .session_user_id = test_id };
    try testing.expectEqual(.deny, authorization_evaluate.evaluateCondition(condition, ctx));
}

test "evaluateCondition: isNotNull allows when session field is present" {
    const allocator = testing.allocator;

    const test_id = typed_doc_id.generateUuidV7();
    const condition = authorization_types.Condition{ .comparison = .{
        .lhs = .{ .scope = .session, .field = "userId" },
        .op = .isNotNull,
        .rhs = null,
    } };

    const ctx = EvalContext{ .allocator = allocator, .session_user_id = test_id };
    try testing.expectEqual(.allow, authorization_evaluate.evaluateCondition(condition, ctx));
}
