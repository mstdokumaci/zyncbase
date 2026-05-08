const std = @import("std");
const testing = std.testing;
const authorization = @import("authorization.zig");
const AuthConfig = authorization.AuthConfig;
const EvalContext = authorization.EvalContext;
const doc_id = @import("doc_id.zig");
const schema_system = @import("schema/system.zig");
const ScalarValue = @import("storage_engine.zig").ScalarValue;

// ─── Parser Tests ───────────────────────────────────────────────────────────

test "AuthConfig implicit defaults" {
    const allocator = testing.allocator;
    var config = try authorization.implicitConfig(allocator);
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
    var config = try AuthConfig.init(allocator, json);
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
    try testing.expectError(error.UnknownAuthKey, AuthConfig.init(allocator, json));
}

test "AuthConfig rejects invalid comparison operator" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":{"$doc.owner_id":{"invalidOp":"value"}}}]}
    ;
    try testing.expectError(error.InvalidComparisonOperator, AuthConfig.init(allocator, json));
}

test "AuthConfig parses empty boolean and float array literals" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":{"and":[{"$session.externalId":{"in":[]}},{"$session.externalId":{"in":[true,false]}},{"$session.externalId":{"in":[2.5,1.5]}}]},"write":true}]}
    ;
    var config = try AuthConfig.init(allocator, json);
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
    var config = try authorization.implicitConfig(testing.allocator);
    defer config.deinit();

    const result = authorization.evaluateCondition(.{ .boolean = true }, .{ .allocator = testing.allocator });
    try testing.expect(result == .allow);
}

test "evaluateCondition boolean false denies" {
    var config = try authorization.implicitConfig(testing.allocator);
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

test "evaluateCondition $doc reference returns needs_injection" {
    const allocator = testing.allocator;
    const cond = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .doc, .field = try allocator.dupe(u8, "owner_id") },
        .op = .eq,
        .rhs = .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, "test") } } },
    } };
    defer cond.deinit(allocator);

    const result = authorization.evaluateCondition(cond, .{ .allocator = allocator });
    try testing.expect(result == .needs_injection);
}

test "evaluateCondition $session.userId comparison" {
    const allocator = testing.allocator;
    const cond = authorization.Condition{ .comparison = .{
        .lhs = .{ .scope = .session, .field = try allocator.dupe(u8, "userId") },
        .op = .eq,
        .rhs = .{ .context_var = .{ .scope = .session, .field = try allocator.dupe(u8, "userId") } },
    } };
    defer cond.deinit(allocator);

    const test_id = doc_id.generateUuidV7();
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
    var config = try AuthConfig.init(allocator, json);
    defer config.deinit();

    var match = try config.namespaceRuleFor(allocator, "tenant:acme");
    try testing.expect(match != null);
    try testing.expect(std.mem.eql(u8, match.?.rule.pattern, "tenant:{tenant_id}"));
    try testing.expect(std.mem.eql(u8, match.?.captures.get("tenant_id").?, "acme"));
    match.?.deinit(allocator);
}

test "namespaceRuleFor returns null when no match" {
    const allocator = testing.allocator;
    var config = try authorization.implicitConfig(allocator);
    defer config.deinit();

    const match = try config.namespaceRuleFor(allocator, "unknown:something");
    try testing.expect(match == null);
}

test "authorizeStoreNamespace enforces storeFilter" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"tenant:{tenant_id}","storeFilter":{"$namespace.tenant_id":{"eq":"acme"}},"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try AuthConfig.init(allocator, json);
    defer config.deinit();

    const user_id = doc_id.generateUuidV7();
    try authorization.authorizeStoreNamespace(allocator, &config, "tenant:acme", user_id, "external-1");
    try testing.expectError(error.NamespaceUnauthorized, authorization.authorizeStoreNamespace(allocator, &config, "tenant:globex", user_id, "external-1"));
    try testing.expectError(error.NamespaceUnauthorized, authorization.authorizeStoreNamespace(allocator, &config, "public", user_id, "external-1"));
}

// ─── Injector Tests ─────────────────────────────────────────────────────────

test "injectDocCondition produces SQL for $doc comparison" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":{"$doc.owner_id":{"eq":"$session.userId"}}}]}
    ;
    var config = try AuthConfig.init(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "owner_id", .field_type = .doc_id },
    });
    defer table.deinit(allocator);

    const test_id = doc_id.generateUuidV7();
    const eval_ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };

    const clause = try authorization.injectDocCondition(allocator, config.store_rules[0].write, eval_ctx, &table);
    defer clause.deinit(allocator);

    try testing.expect(clause.bind_values.len == 1);
    try testing.expect(clause.bind_values[0] == .scalar);
    try testing.expect(clause.bind_values[0].scalar == .doc_id);
    try testing.expect(doc_id.eql(clause.bind_values[0].scalar.doc_id, test_id));
    try testing.expect(std.mem.indexOf(u8, clause.sql, "\"owner_id\"") != null);
}

test "injectDocCondition returns empty for RAM-only condition" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":true}]}
    ;
    var config = try AuthConfig.init(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "owner_id", .field_type = .doc_id },
    });
    defer table.deinit(allocator);

    const clause = try authorization.injectDocCondition(allocator, config.store_rules[0].write, .{ .allocator = allocator }, &table);
    defer clause.deinit(allocator);

    try testing.expect(clause.sql.len == 0);
    try testing.expect(clause.bind_values.len == 0);
}

test "injectDocCondition preserves logical_or SQL" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":{"or":[{"$doc.owner_id":{"eq":"$session.userId"}},{"$doc.visibility":{"eq":"public"}}]}}]}
    ;
    var config = try AuthConfig.init(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "owner_id", .field_type = .doc_id },
        .{ .name = "visibility", .field_type = .text },
    });
    defer table.deinit(allocator);

    const test_id = doc_id.generateUuidV7();
    const eval_ctx = EvalContext{
        .allocator = allocator,
        .session_user_id = test_id,
    };

    const clause = try authorization.injectDocCondition(allocator, config.store_rules[0].write, eval_ctx, &table);
    defer clause.deinit(allocator);

    try testing.expect(std.mem.indexOf(u8, clause.sql, " OR ") != null);
    try testing.expect(clause.bind_values.len == 2);
}

test "injectDocCondition denies hook conditions" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":{"hook":"authorizeWrite"}}]}
    ;
    var config = try AuthConfig.init(allocator, json);
    defer config.deinit();

    var table = makeTestTable(allocator, "test", &[_]TestFieldDef{
        .{ .name = "owner_id", .field_type = .doc_id },
    });
    defer table.deinit(allocator);

    try testing.expectError(error.AccessDenied, authorization.injectDocCondition(allocator, config.store_rules[0].write, .{ .allocator = allocator }, &table));
}

// ─── Test Helpers ───────────────────────────────────────────────────────────

const TestFieldDef = struct {
    name: []const u8,
    field_type: @import("schema.zig").FieldType,
};

fn makeTestTable(allocator: std.mem.Allocator, name: []const u8, fields: []const TestFieldDef) @import("schema.zig").Table {
    const schema_mod = @import("schema.zig");
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
