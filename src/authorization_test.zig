const std = @import("std");
const msgpack = @import("msgpack");
const testing = std.testing;
const authorization_types = @import("authorization/types.zig");
const authorization_evaluate = @import("authorization/evaluate.zig");
const authorization_pattern = @import("authorization/pattern.zig");
const authorization_doc_predicate = @import("authorization/doc_predicate.zig");
const authorization_parse = @import("authorization/parse.zig");
const authorization_defaults = @import("authorization/defaults.zig");
const AuthConfig = authorization_types.AuthConfig;
const EvalContext = authorization_evaluate.EvalContext;
const typed = @import("typed/types.zig");
const typed_doc_id = @import("typed/doc_id.zig");
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
    const empty = (conds[0].comparison.rhs orelse return error.TestExpectedValue).literal.array;
    try testing.expectEqual(@as(usize, 0), empty.len);

    try testing.expect(conds[1] == .comparison);
    const bools = (conds[1].comparison.rhs orelse return error.TestExpectedValue).literal.array;
    try testing.expectEqual(@as(usize, 2), bools.len);
    try testing.expect(bools[0] == .boolean);
    try testing.expect(!bools[0].boolean);
    try testing.expect(bools[1] == .boolean);
    try testing.expect(bools[1].boolean);

    try testing.expect(conds[2] == .comparison);
    const floats = (conds[2].comparison.rhs orelse return error.TestExpectedValue).literal.array;
    try testing.expectEqual(@as(usize, 2), floats.len);
    try testing.expect(floats[0] == .real);
    try testing.expectEqual(@as(f64, 1.5), floats[0].real);
    try testing.expect(floats[1] == .real);
    try testing.expectEqual(@as(f64, 2.5), floats[1].real);
}

// ─── Pattern Matcher Tests ──────────────────────────────────────────────────

test "parsePattern splits literals and captures" {
    const allocator = testing.allocator;
    const segments = try authorization_pattern.parsePattern(allocator, "tenant:{tenant_id}");
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
    const segments = try authorization_pattern.parsePattern(allocator, "tenant:{tenant_id}:user:{user_id}");
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const match_opt = try authorization_pattern.matchNamespace(allocator, segments, "tenant:acme:user:123");
    try testing.expect(match_opt != null);
    var match = match_opt.?;
    defer match.deinit(allocator);

    try testing.expect(std.mem.eql(u8, match.get("tenant_id").?, "acme"));
    try testing.expect(std.mem.eql(u8, match.get("user_id").?, "123"));
}

test "matchNamespace returns null on mismatch" {
    const allocator = testing.allocator;
    const segments = try authorization_pattern.parsePattern(allocator, "tenant:{tenant_id}");
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const match = try authorization_pattern.matchNamespace(allocator, segments, "org:acme");
    try testing.expect(match == null);
}

test "matchNamespace wildcard matches one segment" {
    const allocator = testing.allocator;
    const segments = try authorization_pattern.parsePattern(allocator, "*");
    defer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const match = try authorization_pattern.matchNamespace(allocator, segments, "default");
    try testing.expect(match != null);
    var matched = match orelse return error.TestExpectedValue;
    matched.deinit(allocator);

    const nested = try authorization_pattern.matchNamespace(allocator, segments, "tenant:acme");
    try testing.expect(nested == null);
}

// ─── RAM Evaluator Tests ────────────────────────────────────────────────────

test "evaluateCondition boolean true allows" {
    var config = try implicitTestConfig(testing.allocator);
    defer config.deinit();

    const result = authorization_evaluate.evaluateCondition(.{ .boolean = true }, .{ .allocator = testing.allocator });
    try testing.expect(result == .allow);
}

test "evaluateCondition boolean false denies" {
    var config = try implicitTestConfig(testing.allocator);
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

test "namespaceRuleFor finds matching rule with captures" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"public","storeFilter":true,"presenceRead":true,"presenceWrite":true},{"pattern":"tenant:{tenant_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    var match = try authorization_pattern.matchNamespaceRule(allocator, &config, "tenant:acme");
    try testing.expect(match != null);
    try testing.expect(std.mem.eql(u8, match.?.rule.pattern, "tenant:{tenant_id}"));
    try testing.expect(std.mem.eql(u8, match.?.captures.get("tenant_id").?, "acme"));
    match.?.deinit(allocator);
}

test "namespaceRuleFor returns null when no match" {
    const allocator = testing.allocator;
    var config = try implicitTestConfig(allocator);
    defer config.deinit();

    const match = try authorization_pattern.matchNamespaceRule(allocator, &config, "unknown:something");
    try testing.expect(match == null);
}

test "authorizeNamespace enforces storeFilter" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"tenant:{tenant_id}","storeFilter":{"$namespace.tenant_id":{"eq":"acme"}},"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizeNamespace(allocator, &config, "private:secret", user_id, "external-1", null, true));
}

test "authorizePresenceWrite enforces presenceWrite condition" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_mod.PresenceField{
        .{ .name = "cursor_x", .declared_type = .real },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = .{ .float = 42.0 };
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try authorization_evaluate.authorizePresenceWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch);
    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizePresenceWrite(allocator, &config, "unknown:xyz", user_id, "external-1", null, &presence_fields, &patch));
}

test "authorizePresenceWrite denies when presenceWrite is false" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"readonly:{id}","storeFilter":true,"presenceRead":true,"presenceWrite":false}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_mod.PresenceField{
        .{ .name = "status", .declared_type = .text },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = try msgpack.Payload.strToPayload("online", allocator);
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizePresenceWrite(allocator, &config, "readonly:ns", user_id, "external-1", null, &presence_fields, &patch));
}

test "authorizePresenceSharedWrite enforces presenceSharedWrite condition" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true,"presenceSharedWrite":true}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_mod.PresenceField{
        .{ .name = "slide", .declared_type = .integer },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = .{ .uint = 5 };
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try authorization_evaluate.authorizePresenceSharedWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch);
    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizePresenceSharedWrite(allocator, &config, "unknown:xyz", user_id, "external-1", null, &presence_fields, &patch));
}

test "authorizePresenceSharedWrite falls back to presenceWrite when not specified" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"room:{room_id}","storeFilter":true,"presenceRead":true,"presenceWrite":false}],"store":[]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const user_id = typed_doc_id.generateUuidV7();
    const presence_fields = [_]schema_mod.PresenceField{
        .{ .name = "slide", .declared_type = .integer },
    };
    var pair = try allocator.alloc(msgpack.Payload, 2);
    pair[0] = msgpack.Payload.uintToPayload(0);
    pair[1] = .{ .uint = 5 };
    var pairs = try allocator.alloc(msgpack.Payload, 1);
    pairs[0] = .{ .arr = pair };
    var patch = msgpack.Payload{ .arr = pairs };
    defer patch.free(allocator);

    try testing.expectError(error.NamespaceUnauthorized, authorization_evaluate.authorizePresenceSharedWrite(allocator, &config, "room:lobby", user_id, "external-1", null, &presence_fields, &patch));
}

// ─── Doc Predicate Tests ────────────────────────────────────────────────────

test "buildDocPredicate produces filter predicate for $doc comparison" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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

test "buildDocPredicate clones borrowed literal RHS into predicate" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"eq":"public"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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

// ─── Create Auth Tests ──────────────────────────────────────────────────────

test "evaluateConditionWithDoc allows $doc.owner_id == $session.userId when owner matches" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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
    var config = try initTestConfig(allocator, json);
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

// ─── New operator tests ───────────────────────────────────────────────────────

test "parse accepts isNull string shorthand for $doc field" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":"isNull"}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const write_cond = config.store_rules[0].write;
    try testing.expect(write_cond == .comparison);
    try testing.expectEqual(query_ast.Operator.isNull, write_cond.comparison.op);
    try testing.expect(write_cond.comparison.rhs == null);
}

test "parse accepts isNotNull string shorthand for $doc field" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":"isNotNull"}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const write_cond = config.store_rules[0].write;
    try testing.expect(write_cond == .comparison);
    try testing.expectEqual(query_ast.Operator.isNotNull, write_cond.comparison.op);
    try testing.expect(write_cond.comparison.rhs == null);
}

test "parse rejects unknown string shorthand" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":{"$doc.f":"notAnOp"}}]}
    ;
    try testing.expectError(error.InvalidComparisonOperator, initTestConfig(allocator, json));
}

test "parse accepts startsWith for $doc text field" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"startsWith":"pub"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const write_cond = config.store_rules[0].write;
    try testing.expect(write_cond == .comparison);
    try testing.expectEqual(query_ast.Operator.startsWith, write_cond.comparison.op);
    try testing.expect(write_cond.comparison.rhs != null);
    try testing.expect(write_cond.comparison.rhs.? == .literal);
}

test "parse accepts endsWith for $doc text field" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"endsWith":"_suffix"}}}]}
    ;
    var config = try initTestConfig(allocator, json);
    defer config.deinit();

    const write_cond = config.store_rules[0].write;
    try testing.expect(write_cond == .comparison);
    try testing.expectEqual(query_ast.Operator.endsWith, write_cond.comparison.op);
}

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

// ─── Test Helpers ───────────────────────────────────────────────────────────

fn initTestConfig(allocator: std.mem.Allocator, json: []const u8) !AuthConfig {
    var schema = try makeAuthTestSchema(allocator);
    defer schema.deinit();
    return authorization_parse.initFromJson(allocator, json, &schema);
}

fn implicitTestConfig(allocator: std.mem.Allocator) !AuthConfig {
    var schema = try makeAuthTestSchema(allocator);
    defer schema.deinit();
    return authorization_defaults.implicitConfig(allocator, &schema);
}

fn makeAuthTestSchema(allocator: std.mem.Allocator) !schema_mod.Schema {
    const text_types = [_]schema_mod.FieldType{.text};
    return schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{
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
