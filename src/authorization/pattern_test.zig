const std = @import("std");
const testing = std.testing;
const authorization_pattern = @import("pattern.zig");
const auth_helpers = @import("test_helpers.zig");

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

test "namespaceRuleFor finds matching rule with captures" {
    const allocator = testing.allocator;
    const json =
        \\{"namespaces":[{"pattern":"public","storeFilter":true,"presenceRead":true,"presenceWrite":true},{"pattern":"tenant:{tenant_id}","storeFilter":true,"presenceRead":true,"presenceWrite":true}],"store":[]}
    ;
    var config = try auth_helpers.initTestConfig(allocator, json);
    defer config.deinit();

    var match = try authorization_pattern.matchNamespaceRule(allocator, &config, "tenant:acme");
    try testing.expect(match != null);
    try testing.expect(std.mem.eql(u8, match.?.rule.pattern, "tenant:{tenant_id}"));
    try testing.expect(std.mem.eql(u8, match.?.captures.get("tenant_id").?, "acme"));
    match.?.deinit(allocator);
}

test "namespaceRuleFor returns null when no match" {
    const allocator = testing.allocator;
    var config = try auth_helpers.implicitTestConfig(allocator);
    defer config.deinit();

    const match = try authorization_pattern.matchNamespaceRule(allocator, &config, "unknown:something");
    try testing.expect(match == null);
}
