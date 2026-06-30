const std = @import("std");
const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;

/// Returns the string for `key` if it is a string, else null.
pub fn getString(obj: ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Returns the integer for `key` if it is an integer, else null.
pub fn getInt(obj: ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

/// Returns the bool for `key` if it is a bool, else null.
pub fn getBool(obj: ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    if (v != .bool) return null;
    return v.bool;
}

/// Returns the `ObjectMap` for `key` if it is an object, else null.
pub fn getObject(obj: ObjectMap, key: []const u8) ?ObjectMap {
    const v = obj.get(key) orelse return null;
    if (v != .object) return null;
    return v.object;
}

/// Returns the `std.json.Array` for `key` if it is an array, else null.
pub fn getArray(obj: ObjectMap, key: []const u8) ?std.json.Array {
    const v = obj.get(key) orelse return null;
    if (v != .array) return null;
    return v.array;
}

/// Duplicates the string for `key` if it is a string.
/// Caller owns the returned slice. Returns null if absent or not a string.
pub fn dupString(allocator: Allocator, obj: ObjectMap, key: []const u8) !?[]const u8 {
    const s = getString(obj, key) orelse return null;
    return try allocator.dupe(u8, s);
}

/// Sets an optional `?[]const u8` field from the string for `key`.
/// Only acts when `key` is present and a string. Caller owns the duped slice.
pub fn setString(
    allocator: Allocator,
    field: *?[]const u8,
    obj: ObjectMap,
    key: []const u8,
) !void {
    const s = getString(obj, key) orelse return;
    const new = try allocator.dupe(u8, s);
    if (field.*) |old| allocator.free(old);
    field.* = new;
}

/// Replaces a non-optional `[]const u8` field with a freshly duped copy of the
/// string for `key`. Frees the previous value. Only acts when `key` is present
/// and a string. `field` must point to a caller-owned slice.
pub fn replaceString(
    allocator: Allocator,
    field: *[]const u8,
    obj: ObjectMap,
    key: []const u8,
) !void {
    const s = getString(obj, key) orelse return;
    const new = try allocator.dupe(u8, s);
    allocator.free(field.*);
    field.* = new;
}

/// Resolves `key` to an enum tag via a comptime `std.StaticStringMap(Enum)`.
pub fn getEnum(
    comptime Enum: type,
    obj: ObjectMap,
    key: []const u8,
    map: std.StaticStringMap(Enum),
) ?Enum {
    const s = getString(obj, key) orelse return null;
    return map.get(s);
}
