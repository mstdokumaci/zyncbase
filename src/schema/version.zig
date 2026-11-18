const std = @import("std");

/// Strict semantic schema version `X.Y.Z`: three non-negative decimal
/// integers without signs, leading zeros, prefixes, or suffixes.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) error{InvalidVersion}!Version {
        var it = std.mem.splitScalar(u8, text, '.');
        const major = try parseComponent(it.next());
        const minor = try parseComponent(it.next());
        const patch = try parseComponent(it.next());
        if (it.next() != null) return error.InvalidVersion;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

fn parseComponent(component: ?[]const u8) error{InvalidVersion}!u32 {
    const digits = component orelse return error.InvalidVersion;
    if (digits.len == 0) return error.InvalidVersion;
    if (digits.len > 1 and digits[0] == '0') return error.InvalidVersion;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return error.InvalidVersion;
    }
    // Only overflow remains possible after the digit check; it is an invalid version.
    return std.fmt.parseInt(u32, digits, 10) catch return error.InvalidVersion;
}
