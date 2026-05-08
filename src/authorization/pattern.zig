const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const PatternSegment = types.PatternSegment;

pub const PatternMatch = struct {
    /// Extracted captures from the namespace string.
    /// Key = capture name (e.g. "tenant_id"), Value = matched segment value.
    captures: std.StringHashMap([]const u8),

    pub fn deinit(self: *PatternMatch, allocator: Allocator) void {
        var it = self.captures.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.captures.deinit();
    }

    pub fn get(self: *const PatternMatch, key: []const u8) ?[]const u8 {
        return self.captures.get(key);
    }
};

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
) !?PatternMatch {
    var parts = std.ArrayListUnmanaged([]const u8).empty;
    defer parts.deinit(allocator);

    var start: usize = 0;
    for (namespace, 0..) |c, i| {
        if (c == ':') {
            try parts.append(allocator, namespace[start..i]);
            start = i + 1;
        }
    }
    try parts.append(allocator, namespace[start..]);

    if (parts.items.len != segments.len) return null;

    var captures = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = captures.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        captures.deinit();
    }

    for (parts.items, segments) |part, seg| {
        switch (seg) {
            .literal => |lit| if (!std.mem.eql(u8, lit, "*") and !std.mem.eql(u8, lit, part)) {
                var match = PatternMatch{ .captures = captures };
                match.deinit(allocator);
                return null;
            },
            .capture => |name| {
                if (part.len == 0) {
                    var match = PatternMatch{ .captures = captures };
                    match.deinit(allocator);
                    return null;
                }
                const key = try allocator.dupe(u8, name);
                errdefer allocator.free(key);
                const value = try allocator.dupe(u8, part);
                errdefer allocator.free(value);
                try captures.put(key, value);
            },
        }
    }

    return PatternMatch{ .captures = captures };
}
