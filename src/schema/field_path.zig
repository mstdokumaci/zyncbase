/// field_path.zig — canonical helpers for the `__`-separated flat field path format.
///
/// Internally, nested field names are stored as flat strings joined with `__`
/// (e.g. `"address__city"`).  User-facing schema JSON uses dot-notation
/// (e.g. `"address.city"`).  Joining and conversion live here so every callsite stays in sync.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Join `prefix` and `segment` with `__`.
/// When `prefix` is empty the result is a fresh copy of `segment` (no leading separator).
pub fn join(allocator: Allocator, prefix: []const u8, segment: []const u8) ![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, segment);
    return std.mem.concat(allocator, u8, &.{ prefix, "__", segment });
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
