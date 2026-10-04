const std = @import("std");

const ObjectMap = std.json.ObjectMap;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// High-level parsing helpers
// ---------------------------------------------------------------------------

pub fn parseValue(allocator: Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
}

// ---------------------------------------------------------------------------
// Object-map access helpers (type-safe getters)
// ---------------------------------------------------------------------------

pub fn getString(obj: ObjectMap, key: []const u8) !?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .string) return error.TypeMismatch;
    return v.string;
}

pub fn getInt(obj: ObjectMap, key: []const u8) !?i64 {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .integer) return error.TypeMismatch;
    return v.integer;
}

pub fn getBool(obj: ObjectMap, key: []const u8) !?bool {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .bool) return error.TypeMismatch;
    return v.bool;
}

pub fn getObject(obj: ObjectMap, key: []const u8) !?ObjectMap {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .object) return error.TypeMismatch;
    return v.object;
}

pub fn getArray(obj: ObjectMap, key: []const u8) !?std.json.Array {
    const v = obj.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .array) return error.TypeMismatch;
    return v.array;
}

pub fn setString(
    allocator: Allocator,
    field: *?[]const u8,
    obj: ObjectMap,
    key: []const u8,
) !void {
    const s = try getString(obj, key);
    const val = s orelse return;
    const new = try allocator.dupe(u8, val);
    if (field.*) |old| allocator.free(old);
    field.* = new;
}

pub fn replaceString(
    allocator: Allocator,
    field: *[]const u8,
    obj: ObjectMap,
    key: []const u8,
) !void {
    const s = try getString(obj, key);
    const val = s orelse return;
    const new = try allocator.dupe(u8, val);
    allocator.free(field.*);
    field.* = new;
}

pub fn setBool(field: *bool, obj: ObjectMap, key: []const u8) !void {
    if (try getBool(obj, key)) |v| field.* = v;
}

pub fn setInt(comptime T: type, field: *T, obj: ObjectMap, key: []const u8) !void {
    if (try getInt(obj, key)) |v| {
        field.* = std.math.cast(T, v) orelse return error.Overflow;
    }
}

// ---------------------------------------------------------------------------
// Object-map validation helpers
// ---------------------------------------------------------------------------

/// Rejects any keys in `obj` that are not in the comptime `allowed` list.
/// Returns the caller-supplied error tag on first unknown key.
pub fn rejectUnknownKeys(
    comptime err: anytype,
    comptime allowed: []const []const u8,
    obj: ObjectMap,
) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        inline for (allowed) |ak| {
            if (std.mem.eql(u8, key, ak)) break;
        } else {
            return err;
        }
    }
}
