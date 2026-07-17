const std = @import("std");
const testing = std.testing;
const query_ast = @import("../query/ast.zig");
const auth_helpers = @import("test_helpers.zig");

test "AuthConfig implicit defaults" {
    const allocator = testing.allocator;
    var config = try auth_helpers.implicitTestConfig(allocator);
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
    var config = try auth_helpers.initTestConfig(allocator, json);
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
    try testing.expectError(error.UnknownAuthKey, auth_helpers.initTestConfig(allocator, json));
}

test "AuthConfig rejects invalid comparison operator" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":true,"write":{"$doc.owner_id":{"invalidOp":"value"}}}]}
    ;
    try testing.expectError(error.InvalidComparisonOperator, auth_helpers.initTestConfig(allocator, json));
}

test "AuthConfig parses empty boolean and float array literals" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"*","read":{"and":[{"$session.externalId":{"in":[]}},{"$session.externalId":{"in":[true,false]}},{"$session.externalId":{"in":[2.5,1.5]}}]},"write":true}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
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

test "parse accepts isNull string shorthand for $doc field" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":"isNull"}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
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
    var config = try auth_helpers.initTestConfig(allocator, json);
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
    try testing.expectError(error.InvalidComparisonOperator, auth_helpers.initTestConfig(allocator, json));
}

test "parse accepts startsWith for $doc text field" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[],"store":[{"collection":"test","read":true,"write":{"$doc.visibility":{"startsWith":"pub"}}}]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
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
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    const write_cond = config.store_rules[0].write;
    try testing.expect(write_cond == .comparison);
    try testing.expectEqual(query_ast.Operator.endsWith, write_cond.comparison.op);
}
