const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const PatternSegment = types.PatternSegment;

/// Parse a pattern string into PatternSegments.
/// "tenant:{tenant_id}" -> [literal("tenant"), capture("tenant_id")]
pub fn parsePattern(allocator: Allocator, pattern: []const u8) ![]PatternSegment {
    var segments = std.ArrayListUnmanaged(PatternSegment).empty;
    errdefer {
        for (segments.items) |seg| seg.deinit(allocator);
        segments.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, pattern, ':');
    while (iter.next()) |segment| {
        if (segment.len == 0) return error.InvalidPattern;
        if (segment[0] == '{' and segment[segment.len - 1] == '}') {
            const name = try allocator.dupe(u8, segment[1 .. segment.len - 1]);
            errdefer allocator.free(name);
            try segments.append(allocator, .{ .capture = name });
        } else {
            const literal = try allocator.dupe(u8, segment);
            errdefer allocator.free(literal);
            try segments.append(allocator, .{ .literal = literal });
        }
    }

    return segments.toOwnedSlice(allocator);
}

/// Match a concrete namespace string against parsed segments.
/// Returns null if no match, PatternMatch with captures on success.
/// "tenant:acme" vs [literal("tenant"), capture("tenant_id")] -> captures{"tenant_id": "acme"}
pub fn matchNamespace(
    allocator: Allocator,
    segments: []const PatternSegment,
    namespace: []const u8,
) !?types.PatternMatch {
    var iter = std.mem.splitScalar(u8, namespace, ':');
    var captures = std.StringHashMapUnmanaged([]const u8){};
    errdefer captures.deinit(allocator);

    for (segments) |seg| {
        const part = iter.next() orelse {
            captures.deinit(allocator);
            return null;
        };

        switch (seg) {
            .literal => |lit| if (!std.mem.eql(u8, lit, "*") and !std.mem.eql(u8, lit, part)) {
                captures.deinit(allocator);
                return null;
            },
            .capture => |name| {
                if (part.len == 0) {
                    captures.deinit(allocator);
                    return null;
                }
                try captures.put(allocator, name, part);
            },
        }
    }

    if (iter.next() != null) {
        captures.deinit(allocator);
        return null;
    }

    return types.PatternMatch{ .captures = captures };
}

/// Find the first NamespaceRule whose pattern matches the given namespace string.
/// Caller must call deinit() on the returned match to free captures.
pub fn matchNamespaceRule(
    allocator: Allocator,
    config: *const types.AuthConfig,
    namespace: []const u8,
) !?types.AuthConfig.NamespaceRuleMatch {
    for (config.namespace_rules) |*rule| {
        if (try matchNamespace(allocator, rule.segments, namespace)) |match| {
            return .{ .rule = rule, .captures = match };
        }
    }
    return null;
}
