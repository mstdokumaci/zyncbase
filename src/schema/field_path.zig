/// field_path.zig — canonical helpers for the `__`-separated flat field path format.
///
/// Internally, nested field names are stored as flat strings joined with `__`
/// (e.g. `"address__city"`).  User-facing schema JSON uses dot-notation
/// (e.g. `"address.city"`).  All joining, splitting, and normalization lives
/// here so every callsite stays in sync.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Join `prefix` and `segment` with `__`.
/// When `prefix` is empty the result is a fresh copy of `segment` (no leading separator).
pub fn join(allocator: Allocator, prefix: []const u8, segment: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, segment);
    return std.fmt.allocPrint(allocator, "{s}__{s}", .{ prefix, segment });
}

/// Split `path` at the first `__` occurrence.
/// Returns `.{ .segment = first_part, .rest = remaining }`.
/// When there is no `__` in `path`, `.rest` is `null`.
pub const Split = struct {
    segment: []const u8,
    rest: ?[]const u8,
};

pub fn splitFirst(path: []const u8) Split {
    const sep = std.mem.indexOf(u8, path, "__") orelse return .{
        .segment = path,
        .rest = null,
    };
    return .{
        .segment = path[0..sep],
        .rest = path[sep + 2 ..],
    };
}

/// Return the portion of `path` that follows `prefix__`.
/// Returns `null` when `path` does not start with `prefix__` or equals `prefix`.
/// When `prefix` is empty the whole `path` is the remainder.
pub fn remainder(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return path;
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    if (path.len <= prefix.len + 2) return null;
    if (!std.mem.eql(u8, path[prefix.len .. prefix.len + 2], "__")) return null;
    return path[prefix.len + 2 ..];
}

/// Convert user-facing dot-notation (`"a.b.c"`) to internal `__` form (`"a__b__c"`).
/// Allocates; caller owns the result.
pub fn normalizeDots(allocator: Allocator, dotted: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, allocator, dotted, ".", "__");
}

/// Convert internal `__` form (`"a__b__c"`) back to dot-notation (`"a.b.c"`).
/// Allocates; caller owns the result.
pub fn toDotted(allocator: Allocator, flat: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, allocator, flat, "__", ".");
}
