const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

extern fn zync_regex_compile(pattern: [*c]const u8) ?*anyopaque;
extern fn zync_regex_match(handle: *anyopaque, str: [*c]const u8) c_int;
extern fn zync_regex_free(handle: *anyopaque) void;

pub fn compilePattern(allocator: Allocator, pattern: []const u8) !*anyopaque {
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    const handle = zync_regex_compile(pattern_z.ptr) orelse return error.InvalidRegex;
    return handle;
}

pub fn freePattern(_: Allocator, handle: *anyopaque) void {
    zync_regex_free(handle);
}

pub fn matchPattern(handle: *anyopaque, allocator: Allocator, str: []const u8) !bool {
    if (str.len < 256) {
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..str.len], str);
        buf[str.len] = 0;
        return zync_regex_match(handle, &buf) == 1;
    } else {
        const str_z = try allocator.dupeZ(u8, str);
        defer allocator.free(str_z);
        return zync_regex_match(handle, str_z.ptr) == 1;
    }
}

pub fn validateEmail(str: []const u8) bool {
    if (str.len < 3 or str.len > 254) return false;

    const at_idx = std.mem.indexOfScalar(u8, str, '@') orelse return false;
    // Disallow multiple '@' symbols
    if (std.mem.indexOfScalar(u8, str[at_idx + 1 ..], '@') != null) return false;

    const local = str[0..at_idx];
    const domain = str[at_idx + 1 ..];

    if (local.len == 0 or local.len > 64) return false;
    if (domain.len == 0 or domain.len > 253) return false;

    // Check local part: no spaces or control chars
    for (local) |ch| {
        if (ch <= 32 or ch >= 127) return false;
    }

    // Domain part: must have at least one dot, no leading/trailing dot, no consecutive dots
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return false;
    if (std.mem.indexOf(u8, domain, "..") != null) return false;

    var has_dot = false;
    for (domain) |ch| {
        if (ch == '.') {
            has_dot = true;
        } else if (!std.ascii.isAlphanumeric(ch) and ch != '-') {
            return false;
        }
    }

    return has_dot;
}

pub fn validateUuid(str: []const u8) bool {
    if (str.len != 36) return false;
    if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') return false;

    for (str, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

pub fn validateUri(str: []const u8) bool {
    if (str.len < 3) return false;

    // Scheme must start with a letter
    if (!std.ascii.isAlphabetic(str[0])) return false;

    const colon_idx = std.mem.indexOfScalar(u8, str, ':') orelse return false;
    const scheme = str[0..colon_idx];
    for (scheme[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }

    const rest = str[colon_idx + 1 ..];
    if (rest.len == 0) return false;

    for (str) |ch| {
        if (ch <= 32 or ch >= 127) return false;
    }

    return true;
}

pub fn validate(
    constraints: types.Constraints,
    ft: types.FieldType,
    value: msgpack.Payload,
    allocator: Allocator,
) !void {
    if (value == .nil) return;

    // 1. Enum check
    if (constraints.enum_values) |enums| {
        try validateEnum(enums, ft, value);
    }

    // 2. String constraints
    if (ft == .text and value == .str) {
        const str = value.str.value();

        if (constraints.min_length != null or constraints.max_length != null) {
            const count = std.unicode.utf8CountCodepoints(str) catch return error.LengthViolation;
            if (constraints.min_length) |min_l| {
                if (count < min_l) return error.LengthViolation;
            }
            if (constraints.max_length) |max_l| {
                if (count > max_l) return error.LengthViolation;
            }
        }

        if (constraints.compiled_regex) |regex| {
            const is_match = try matchPattern(regex, allocator, str);
            if (!is_match) return error.PatternViolation;
        }

        if (constraints.format) |fmt| {
            const ok = switch (fmt) {
                .email => validateEmail(str),
                .uuid => validateUuid(str),
                .uri => validateUri(str),
            };
            if (!ok) return error.FormatViolation;
        }
    }

    // 3. Numeric range constraints
    if (ft == .integer or ft == .real) {
        if (constraints.minimum != null or constraints.maximum != null) {
            const num_val: f64 = switch (value) {
                .int => |i| @floatFromInt(i),
                .uint => |u| @floatFromInt(u),
                .float => |f| f,
                else => return error.TypeMismatch,
            };

            if (std.math.isNan(num_val)) return error.RangeViolation;

            if (constraints.minimum) |min_val| {
                if (num_val < min_val) return error.RangeViolation;
            }
            if (constraints.maximum) |max_val| {
                if (num_val > max_val) return error.RangeViolation;
            }
        }
    }
}

fn validateEnum(enums: []const types.Constraints.EnumValue, ft: types.FieldType, value: msgpack.Payload) !void {
    switch (ft) {
        .text => {
            if (value != .str) return error.TypeMismatch;
            const str = value.str.value();
            for (enums) |e| {
                switch (e) {
                    .text => |t| if (std.mem.eql(u8, t, str)) return,
                    else => {},
                }
            }
            return error.EnumViolation;
        },
        .integer => {
            const iv = msgpack.payloadToInt(value) catch return error.TypeMismatch;
            for (enums) |e| {
                switch (e) {
                    .integer => |expected| if (expected == iv) return,
                    .real => |expected| if (@as(f64, @floatFromInt(iv)) == expected) return,
                    else => {},
                }
            }
            return error.EnumViolation;
        },
        .real => {
            const fv = msgpack.payloadToFloat(value) catch return error.TypeMismatch;
            for (enums) |e| {
                switch (e) {
                    .real => |expected| if (expected == fv) return,
                    .integer => |expected| if (@as(f64, @floatFromInt(expected)) == fv) return,
                    else => {},
                }
            }
            return error.EnumViolation;
        },
        else => return error.EnumViolation,
    }
}
