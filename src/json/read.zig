const std = @import("std");
const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;

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

pub fn dupString(allocator: Allocator, obj: ObjectMap, key: []const u8) !?[]const u8 {
    const s = try getString(obj, key) orelse return null;
    return try allocator.dupe(u8, s);
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

pub fn getEnum(
    comptime Enum: type,
    obj: ObjectMap,
    key: []const u8,
    map: std.StaticStringMap(Enum),
) !?Enum {
    const s = try getString(obj, key) orelse return null;
    return map.get(s);
}

// ---------------------------------------------------------------------------
// Low-level JSON skipping (zero-allocation traversal)
// ---------------------------------------------------------------------------

pub fn skipString(json: []const u8, pos: *usize) ?void {
    if (pos.* >= json.len or json[pos.*] != '"') return null;
    pos.* += 1;
    while (pos.* < json.len and json[pos.*] != '"') {
        if (json[pos.*] == '\\') pos.* += 1;
        pos.* += 1;
    }
    if (pos.* >= json.len) return null;
    pos.* += 1;
}

pub fn skipBalanced(json: []const u8, pos: *usize, open: u8, close: u8) ?void {
    if (pos.* >= json.len or json[pos.*] != open) return null;
    var depth: usize = 1;
    pos.* += 1;
    while (pos.* < json.len and depth > 0) {
        const c = json[pos.*];
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
        } else if (c == '"') {
            skipString(json, pos) orelse return null;
            continue;
        }
        pos.* += 1;
    }
    if (depth != 0) return null;
}

pub fn skipLiteral(json: []const u8, pos: *usize, literal: []const u8) ?void {
    if (pos.* + literal.len > json.len) return null;
    if (!std.mem.eql(u8, json[pos.*..][0..literal.len], literal)) return null;
    pos.* += literal.len;
}

pub fn skipNumber(json: []const u8, pos: *usize) ?void {
    if (pos.* >= json.len) return null;
    const c = json[pos.*];
    if (c != '-' and (c < '0' or c > '9')) return null;
    const start = pos.*;
    var has_digit = false;
    while (pos.* < json.len) {
        const ch = json[pos.*];
        if (ch >= '0' and ch <= '9') {
            has_digit = true;
            pos.* += 1;
        } else if (ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E') {
            pos.* += 1;
        } else {
            break;
        }
    }
    if (!has_digit) {
        pos.* = start;
        return null;
    }
}

pub fn skipValue(json: []const u8, pos: *usize) ?void {
    if (pos.* >= json.len) return null;
    switch (json[pos.*]) {
        '"' => return skipString(json, pos),
        '{' => return skipBalanced(json, pos, '{', '}'),
        '[' => return skipBalanced(json, pos, '[', ']'),
        't' => return skipLiteral(json, pos, "true"),
        'f' => return skipLiteral(json, pos, "false"),
        'n' => return skipLiteral(json, pos, "null"),
        '-', '0'...'9' => return skipNumber(json, pos),
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Low-level JSON extraction (returns slices into the input)
// ---------------------------------------------------------------------------

pub fn skipWhitespace(json: []const u8, pos: *usize) void {
    while (pos.* < json.len) {
        switch (json[pos.*]) {
            ' ', '\t', '\n', '\r' => pos.* += 1,
            else => break,
        }
    }
}

pub fn extractJsonString(json: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= json.len or json[pos.*] != '"') return null;
    pos.* += 1;
    const start = pos.*;
    while (pos.* < json.len) {
        if (json[pos.*] == '"') {
            const result = json[start..pos.*];
            pos.* += 1;
            return result;
        }
        if (json[pos.*] == '\\') {
            pos.* += 1;
        }
        pos.* += 1;
    }
    return null;
}

pub fn extractJsonInt(json: []const u8, pos: *usize) ?i64 {
    var negative = false;
    if (pos.* < json.len and json[pos.*] == '-') {
        negative = true;
        pos.* += 1;
    }
    if (pos.* >= json.len or json[pos.*] < '0' or json[pos.*] > '9') return null;
    var value: i64 = 0;
    while (pos.* < json.len and json[pos.*] >= '0' and json[pos.*] <= '9') {
        const digit: i64 = json[pos.*] - '0';
        const mul_result = @mulWithOverflow(value, 10);
        if (mul_result[1] != 0) return null;
        value = mul_result[0];
        const add_result = @addWithOverflow(value, if (negative) -digit else digit);
        if (add_result[1] != 0) return null;
        value = add_result[0];
        pos.* += 1;
    }
    return value;
}

pub fn extractJsonKey(json: []const u8, pos: *usize) ?[]const u8 {
    return extractJsonString(json, pos);
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
