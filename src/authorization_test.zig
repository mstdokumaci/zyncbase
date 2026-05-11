const std = @import("std");
const msgpack = @import("msgpack");
const testing = std.testing;
const authorization = @import("authorization.zig");
const evaluate_mod = @import("authorization/evaluate.zig");
const AuthConfig = authorization.AuthConfig;
const EvalContext = authorization.EvalContext;
const typed = @import("typed.zig");
const query_ast = @import("query_ast.zig");
const schema_mod = @import("schema.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const schema_system = @import("schema/system.zig");
const ScalarValue = typed.ScalarValue;

// ─── Parser Tests ───────────────────────────────────────────────────────────

test "AuthConfig implicit defaults" {
    const allocator = testing.allocator;
    var config = try implicitTestConfig(allocator);
    defer config.deinit();

    try testing.expect(config.namespace_rules.len >= 1);
    try testing.expect(config.store_rules.len >= 1);

    const wildcard_rule = config.storeRuleFor("nonexistent");
    try testing.expect(wildcard_rule != null);
    try testing.expect(wildcard_rule.?.is_wildcard);
}

test "AuthConfig parses custom namespace and store rules" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"tenant:{tenant_id}","storeFilter":{"$session.userId":{"eq":"$session.userId"}},"presenceRead":true,"presenceWrite":false}],"store":[{"collection":"posts","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    try testing.expect(config.namespace_rules.len == 1);
    try testing.expect(std.mem.eql(u8, config.namespace_rules[0].pattern, "tenant:{tenant_id}"));

    const posts_rule = config.storeRuleFor("posts");
    try testing.expect(posts_rule != null);
    try testing.expect(!posts_rule.?.is_wildcard);
}

test "AuthConfig rejects unknown root keys" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[],"unknownKey":true}
    ;
    try testing.expectError(error.UnknownAuthKey, initTestConfig(allocator, json));
}

test "AuthConfig rejects invalid comparison operator" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":{"$doc.owner_id":{"invalidOp":"value"}}}]}
    ;
    try testing.expectError(error.InvalidComparisonOperator, initTestConfig(allocator, json));
}

test "AuthConfig parses empty boolean and float array literals" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":{"and":[{"$session.externalId":{"in":[]}},{"$session.externalId":{"in":[true,false]}},{"$session.externalId":{"in":[2.5,1.5]}}]},"write":true}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    try testing.expect(config.store_rules[0].read == .logical_and);
    const conds = config.store_rules[0].read.logical_and;
    try testing.expectEqual(@as(usize, 3), conds.len);

    try testing.expect(conds[0] == .comparison);
    const empty = conds[0].comparison.rhs.literal.array;
    try testing.expectEqual(@as(usize, 0), empty.len);

    try testing.expect(conds[1] == .comparison);
    const bools = conds[1].comparison.rhs.literal.array;
    try testing.expectEqual(@as(usize, 2), bools.len);
    try testing.expect(bools[0] == .boolean);
    try testing.expect(!bools[0].boolean);
    try testing.expect(bools[1] == .boolean);
    try testing.expect(bools[1].boolean);

    try testing.expect(conds[2] == .comparison);
    const floats = conds[2].comparison.rhs.literal.array;
    try testing.expectEqual(@as(usize, 2), floats.len);
    try testing.expect(floats[0] == .real);
    try testing.expectEqual(@as(f64, 1.5), floats[0].real);
    try testing.expect(floats[1] == .real);
    try testing.expectEqual(@as(f64, 2.5), floats[1].real);
}

// ─── Pattern Matcher Tests ──────────────────────────────────────────────────

test "parsePattern splits literals and captures" {
    const allocator = testing.allocator;
    const segments = try authorization.parsePattern(allocator, "tenant:{tenant_id}");
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    try testing.expect(segments.len == 2);
    try testing.expect(segments[0] == .literal);
    try testing.expect(std.mem.eql(u8, segments[0].literal, "tenant"));
    try testing.expect(segments[1] == .capture);
    try testing.expect(std.mem.eql(u8, segments[1].capture, "tenant_id"));
}

test "matchNamespace matches exact literals and extracts captures" {
    const allocator = testing.allocator;
    const segments = try authorization.parsePattern(allocator, "tenant:{tenant_id}:user:{user_id}");
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const match_opt = try authorization.matchNamespace(allocator, segments, "tenant:acme:user:123");
    try testing.expect(match_opt != null);
    var match = match_opt.?;
    defer match.deinit(allocator);

    try testing.expect(std.mem.eql(u8, match.get("tenant_id").?, "acme"));
    try testing.expect(std.mem.eql(u8, match.get("user_id").?, "123"));
}

test "matchNamespace returns null on mismatch" {
    const allocator = testing.allocator;
    const segments = try authorization.parsePattern(allocator, "tenant:{tenant_id}");
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const match = try authorization.matchNamespace(allocator, segments, "org:acme");
    try testing.expect(match == null);
}

test "matchNamespace wildcard matches one segment" {
    const allocator = testing.allocator;
    const segments = try authorization.parsePattern(allocator, "*");
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const match = try authorization.matchNamespace(allocator, segments, "default");
    try testing.expect(match != null);
    var matched = match orelse return error.TestExpectedValue;
    matched.deinit(allocator);

    const nested = try authorization.matchNamespace(allocator, segments, "tenant:acme");
    try testing.expect(nested == null);
}

// ─── RAM Evaluator Tests ────────────────────────────────────────────────────

test "evaluateCondition boolean true allows" {
    var config = try implicitTestConfig(testing.allocator);
    defer config.deinit();

    const result = authorization.evaluateCondition(.{ .boolean = true }, .{ .allocator = testing.allocator });
    try testing.expect(result == .allow);
}

test "evaluateCondition boolean false denies" {
    var config = try implicitTestConfig(testing.allocator);
    defer config.deinit();

    const result = authorization.evaluateCondition(.{ .boolean = false }, .{ .allocator = testing.allocator });
    try testing.expect(result == .deny);
}

test "evaluateCondition hook denies until hooks are implemented" {
    const result = authorization.evaluateCondition(.{ .hook = "myHook" }, .{ .allocator = testing.allocator });
    try testing.expect(result == .deny);
}

test "evaluateConditionStrict hook denies" {
    const result = authorization.evaluateConditionStrict(.{ .hook = "myHook" }, .{ .allocator = testing.allocator });
    try testing.expect(!result);
}

test "evaluateCondition $doc reference returns needs_doc_predicate" {
    const allocator = testing.allocator;
    const cond = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "owner_id") },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "test") } } },
    } };
    defer cond.deinit(allocator);

    const result = authorization.evaluateCondition(cond, .{ .allocator = allocator });
    try testing.expect(result == .needs_doc_predicate);
}

test "evaluateCondition $session.userId comparison" {
    const allocator = testing.allocator;
    const cond = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .session, .field = try allocator.dupe(u8, "userId") },
        .op = .eq,
        .rhs = .{ .context_var = .{ .scope = .session, .field = try allocator.dupe(u8, "userId") } },
    } };
    defer cond.deinit(allocator);

    const test_id = typed.generateUuidV7();
    const ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };
    const result = authorization.evaluateCondition(cond, ctx);
    try testing.expect(result == .allow);
}

test "evaluateCondition $namespace capture lookup" {
    const allocator = testing.allocator;
    const cond = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .namespace, .field = try allocator.dupe(u8, "tenant_id") },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "acme") } } },
    } };
    defer cond.deinit(allocator);

    var captures = std.StringHashMap([]const u8).init(allocator);
    defer captures.deinit();
    try captures.put("tenant_id", "acme");

    const ctx = EvalContext{
        .allocator = allocator,
        .namespace_captures = &captures,
    };
    const result = authorization.evaluateCondition(cond, ctx);
    try testing.expect(result == .allow);
}

test "evaluateCondition logical_and short-circuits on deny" {
    const allocator = testing.allocator;
    const conds = try allocator.alloc(authorization.Condition, 2);
    conds[0] = .{ .boolean = true };
    conds[1] = .{ .boolean = false };

    const cond = authorization.Condition{ .logical_and = conds };
    defer cond.deinit(allocator);

    const result = authorization.evaluateCondition(cond, .{ .allocator = allocator });
    try testing.expect(result == .deny);
}

test "evaluateCondition logical_or short-circuits on allow" {
    const allocator = testing.allocator;
    const conds = try allocator.alloc(authorization.Condition, 2);
    conds[0] = .{ .boolean = false };
    conds[1] = .{ .boolean = true };

    const cond = authorization.Condition{ .logical_or = conds };
    defer cond.deinit(allocator);

    const result = authorization.evaluateCondition(cond, .{ .allocator = allocator });
    try testing.expect(result == .allow);
}

test "evaluateCondition in_set works with array" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const arr = try arena_allocator.alloc(ScalarValue, 2);
    arr[0] = .{ .text = try arena_allocator.dupe(u8, "acme") };
    arr[1] = .{ .text = try arena_allocator.dupe(u8, "globex") };

    const cond = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .namespace, .field = try arena_allocator.dupe(u8, "tenant_id") },
        .op = .in_set,
        .rhs = .{ .literal = .{ .array = arr } },
    } };
    // No defer deinit — all memory is arena-owned

    var captures = std.StringHashMap([]const u8).init(allocator);
    defer captures.deinit();
    try captures.put("tenant_id", "acme");

    const ctx = EvalContext{
        .allocator = arena_allocator,
        .namespace_captures = &captures,
    };
    const result = authorization.evaluateCondition(cond, ctx);
    try testing.expect(result == .allow);
}

// ─── Namespace Rule Lookup Tests ────────────────────────────────────────────

test "namespaceRuleFor finds matching rule with captures" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"public","storeFilter":true,"presenceRead":true,"presenceWrite":true},{"pattern":"tenant:{tenant_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var match = try config.namespaceRuleFor(allocator, "tenant:acme");
    try testing.expect(match != null);
    try testing.expect(std.mem.eql(u8, match.?.rule.pattern, "tenant:{tenant_id}"));
    try testing.expect(std.mem.eql(u8, match.?.captures.get("tenant_id").?, "acme"));
    match.?.deinit(allocator);
}

test "namespaceRuleFor returns null when no match" {
    const allocator = testing.allocator;
    var config = try implicitTestConfig(allocator);
    defer config.deinit();

    const match = try config.namespaceRuleFor(allocator, "unknown:something");
    try testing.expect(match == null);
}

test "authorizeStoreNamespace enforces storeFilter" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"tenant:{tenant_id}","storeFilter":{"$namespace.tenant_id":{"eq":"acme"}},"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed.generateUuidV7();
    try authorization.authorizeStoreNamespace(allocator, &config, "tenant:acme", user_id, "external-1");
    try testing.expectError(error.NamespaceUnauthorized, authorization.authorizeStoreNamespace(allocator, &config, "tenant:globex", user_id, "external-1"));
    try testing.expectError(error.NamespaceUnauthorized, authorization.authorizeStoreNamespace(allocator, &config, "public", user_id, "external-1"));
}

// ─── Doc Predicate Tests ────────────────────────────────────────────────────

test "buildDocPredicate produces filter predicate for $doc comparison" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "owner_id", .field_type = .doc_id },
    });
    defer table.deinit(allocator);

    const test_id = typed.generateUuidV7();
    const eval_ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };

    var predicate = (try authorization.buildDocPredicate(config.store_rules[0].write, eval_ctx, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.conditions != null);
    try testing.expectEqual(@as(usize, 1), predicate.conditions.?.len);
    try testing.expect(predicate.or_conditions == null);
    const condition = predicate.conditions.?[0];
    try testing.expectEqual(query_ast.Operator.eq, condition.op);
    try testing.expect(condition.value != null);
    try testing.expect(condition.value.? == .scalar);
    try testing.expect(condition.value.?.scalar == .doc_id);
    try testing.expect(typed.docIdEql(condition.value.?.scalar.doc_id, test_id));
    try testing.expectEqual(schema_system.owner_id_field_index, condition.field_index);
}

test "buildDocPredicate returns null for RAM-only allow" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":true}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "owner_id", .field_type = .doc_id },
    });
    defer table.deinit(allocator);

    const predicate = try authorization.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table);
    try testing.expect(predicate == null);
}

test "buildDocPredicate normalizes $doc notIn empty set to no guard" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"notIn":[]}}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    const predicate = try authorization.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table);
    try testing.expect(predicate == null);
}

test "buildDocPredicate preserves $doc in empty set as match none guard" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"in":[]}}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    var predicate = (try authorization.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    try testing.expect(predicate.isAlwaysFalse());
    try testing.expect(predicate.conditions == null);
    try testing.expect(predicate.or_conditions == null);
}

test "ResolvedAuthValue intoOwned moves owned value and makes deinit no-op" {
    const allocator = testing.allocator;

    const text = try allocator.dupe(u8, "private");
    const original_ptr = text.ptr;
    var resolved = evaluate_mod.ResolvedAuthValue.fromOwned(.{ .scalar = .{ .text = text } });

    var owned_value = try resolved.intoOwned(allocator);
    defer owned_value.deinit(allocator);

    try testing.expect(owned_value == .scalar);
    try testing.expect(owned_value.scalar == .text);
    try testing.expect(owned_value.scalar.text.ptr == original_ptr);
    try testing.expectEqual(std.meta.activeTag(evaluate_mod.ResolvedAuthValue{ .borrowed = .nil }), std.meta.activeTag(resolved));

    resolved.deinit(allocator);
}

test "buildDocPredicate clones borrowed literal RHS into predicate" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"eq":"public"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    var predicate = (try authorization.buildDocPredicate(config.store_rules[0].write, .{ .allocator = allocator }, &table)) orelse return error.TestExpectedValue;
    defer predicate.deinit(allocator);

    const literal_text = config.store_rules[0].write.comparison.rhs.literal.scalar.text;
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
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);
    try payload.mapPut("visibility", try msgpack.Payload.strToPayload("private", allocator));

    const eval_ctx = EvalContext{
        .allocator = allocator,
        .value_payload = &payload,
        .value_table = &table,
    };

    var predicate = (try authorization.buildDocPredicate(config.store_rules[0].write, eval_ctx, &table)) orelse return error.TestExpectedValue;
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

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "tags", .field_type = .array, .items_type = .text },
    });
    defer table.deinit(allocator);

    const items = try allocator.alloc(ScalarValue, 1);
    items[0] = .{ .integer = 42 };
    var condition = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .eq,
        .rhs = .{ .literal = .{ .array = items } },
    } };
    defer condition.deinit(allocator);

    try testing.expectError(error.InvalidValue, authorization.validateDocPredicate(condition, &table));
}

test "validateDocPredicate rejects $value array item type mismatch" {
    const allocator = testing.allocator;

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "tags", .field_type = .array, .items_type = .text },
        .{ .name = "scores", .field_type = .array, .items_type = .integer },
    });
    defer table.deinit(allocator);

    var condition = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .eq,
        .rhs = .{ .context_var = .{ .scope = .value, .field = try allocator.dupe(u8, "scores") } },
    } };
    defer condition.deinit(allocator);

    try testing.expectError(error.InvalidValue, authorization.validateDocPredicate(condition, &table));
}

test "validateDocPredicate validates context variable shape by operator" {
    const allocator = testing.allocator;

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "visibility", .field_type = .text },
        .{ .name = "allowed_visibility", .field_type = .array, .items_type = .text },
        .{ .name = "tags", .field_type = .array, .items_type = .text },
    });
    defer table.deinit(allocator);

    var valid_in_set = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "visibility") },
        .op = .in_set,
        .rhs = .{ .context_var = .{ .scope = .value, .field = try allocator.dupe(u8, "allowed_visibility") } },
    } };
    defer valid_in_set.deinit(allocator);
    try authorization.validateDocPredicate(valid_in_set, &table);

    var scalar_in_set = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "visibility") },
        .op = .in_set,
        .rhs = .{ .context_var = .{ .scope = .session, .field = try allocator.dupe(u8, "externalId") } },
    } };
    defer scalar_in_set.deinit(allocator);
    try testing.expectError(error.InvalidValue, authorization.validateDocPredicate(scalar_in_set, &table));

    var array_contains_array = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "tags") },
        .op = .contains,
        .rhs = .{ .context_var = .{ .scope = .value, .field = try allocator.dupe(u8, "tags") } },
    } };
    defer array_contains_array.deinit(allocator);
    try testing.expectError(error.InvalidValue, authorization.validateDocPredicate(array_contains_array, &table));
}

test "buildDocPredicate preserves logical_or predicate" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"or":[{"$doc.owner_id":{"eq":"$session.userId"}},{"$doc.visibility":{"eq":"public"}}]}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "owner_id", .field_type = .doc_id },
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    const test_id = typed.generateUuidV7();
    const eval_ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };

    var predicate = (try authorization.buildDocPredicate(config.store_rules[0].write, eval_ctx, &table)) orelse return error.TestExpectedValue;
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

test "AuthConfig rejects unsupported store hook predicates at boot" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"hook":"authorizeWrite"}}]}
    ;
    try testing.expectError(error.UnsupportedAuthorizationPredicate, initTestConfig(allocator, json));
}

// ─── Test Helpers ───────────────────────────────────────────────────────────

fn initTestConfig(allocator: std.mem.Allocator, json: []const u8) !AuthConfig {
    var sm = try makeAuthTestSchema(allocator);
    defer sm.deinit();
    return AuthConfig.init(allocator, json, &sm);
}

fn implicitTestConfig(allocator: std.mem.Allocator) !AuthConfig {
    var sm = try makeAuthTestSchema(allocator);
    defer sm.deinit();
    return authorization.implicitConfig(allocator, &sm);
}

fn makeAuthTestSchema(allocator: std.mem.Allocator) !schema_mod.Schema {
    const text_types = [_]schema_mod.FieldType{.text};
    return schema_helpers.createTestSchemaManager(allocator, &[_]schema_helpers.TableDef{
        .{
            .name = "posts",
            .fields = &[_][]const u8{"visibility"},
            .types = &text_types,
        },
        .{
            .name = "test",
            .fields = &[_][]const u8{"visibility"},
            .types = &text_types,
        },
    });
}

const TestFieldDef = struct {
    name: []const u8,
    field_type: schema_mod.FieldType,
    items_type: ?schema_mod.FieldType = null,
};

fn makeTestTable(allocator: std.mem.Allocator, name: []const u8, fields: []const TestFieldDef) schema_mod.Table {
    const name_owned = allocator.dupe(u8, name) catch @panic("oom");
    const name_quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{name}) catch @panic("oom");

    const total_fields = schema_mod.leading_system_field_count + fields.len + schema_mod.trailing_system_field_count;
    const table_fields = allocator.alloc(schema_mod.Field, total_fields) catch @panic("oom");

    var idx: usize = 0;
    for (schema_system.leading_system_fields) |f| {
        table_fields[idx] = f;
        idx += 1;
    }
    for (fields) |field_def| {
        const field_name = allocator.dupe(u8, field_def.name) catch @panic("oom");
        const field_name_quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{field_def.name}) catch @panic("oom");
        table_fields[idx] = .{
            .name = field_name,
            .name_quoted = field_name_quoted,
            .declared_type = field_def.field_type,
            .storage_type = field_def.field_type,
            .items_type = if (field_def.field_type == .array) field_def.items_type orelse .text else null,
            .kind = .user,
        };
        idx += 1;
    }
    for (schema_system.trailing_system_fields) |f| {
        table_fields[idx] = f;
        idx += 1;
    }

    return .{
        .name = name_owned,
        .name_quoted = name_quoted,
        .fields = table_fields,
        .canonical_fields = true,
        .user_field_start = schema_mod.leading_system_field_count,
        .user_field_end = schema_mod.leading_system_field_count + fields.len,
    };
}
