const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

extern fn zync_regex_compile(pattern: [*c]const u8) ?*anyopaque;
extern fn zync_regex_match(handle: *anyopaque, str: [*c]const u8) c_int;
extern fn zync_regex_free(handle: *anyopaque) void;

pub fn compilePattern(allocator: Allocator, pattern: []const u8) !*anyopaque {
    if (std.mem.indexOfScalar(u8, pattern, 0) != null) return error.InvalidRegex;
    // zwanzig-disable-next-line: sentinel-alloc
    const pattern_z = try allocator.dupeZ(u8, pattern);
    defer allocator.free(pattern_z);

    const handle = zync_regex_compile(pattern_z.ptr) orelse return error.InvalidRegex;
    return handle;
}

pub fn freePattern(_: Allocator, handle: *anyopaque) void {
    zync_regex_free(handle);
}

pub fn matchPattern(handle: *anyopaque, allocator: Allocator, str: []const u8) !bool {
    if (std.mem.indexOfScalar(u8, str, 0) != null) return false;
    if (str.len < 256) {
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..str.len], str);
        buf[str.len] = 0;
        return zync_regex_match(handle, &buf) == 1;
    } else {
        // zwanzig-disable-next-line: sentinel-alloc
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
    return validateEmailLocal(local) and validateEmailDomain(domain);
}

fn validateEmailLocal(local: []const u8) bool {
    if (local.len == 0 or local.len > 64) return false;

    // Check local part: no spaces or control chars
    for (local) |ch| {
        if (ch <= 32 or ch >= 127) return false;
    }
    return true;
}

fn validateEmailDomain(domain: []const u8) bool {
    if (domain.len == 0 or domain.len > 253) return false;

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

    for (str) |ch| {
        if (ch <= 32 or ch >= 127) return false;
    }

    // Scheme must start with a letter
    if (!std.ascii.isAlphabetic(str[0])) return false;

    const colon_idx = std.mem.indexOfScalar(u8, str, ':') orelse return false;
    const scheme = str[0..colon_idx];
    for (scheme[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }

    const rest = str[colon_idx + 1 ..];
    return rest.len > 0;
}

/// A constrainable scalar, independent of its wire or storage encoding.
pub const Scalar = union(enum) {
    text: []const u8,
    integer: i64,
    real: f64,
    bytes: []const u8,
};

/// Validates a wire value. The write path, actions, and presence share this
/// entry point; stored values use `validateScalar` with the same rules.
pub fn validate(
    constraints: types.Constraints,
    ft: types.FieldType,
    value: msgpack.Payload,
    allocator: Allocator,
) !void {
    if (value == .nil) return;

    const has_numeric_checks = constraints.enum_values != null or
        constraints.minimum != null or constraints.maximum != null;
    const scalar: Scalar = switch (ft) {
        .text => if (value == .str) .{ .text = value.str.value() } else return error.TypeMismatch,
        // Numeric conversion only happens when a check needs the value.
        .integer => if (has_numeric_checks)
            .{ .integer = msgpack.payloadToInt(value) catch return error.TypeMismatch }
        else
            return,
        // Always decode reals so non-finite values are rejected below.
        .real => .{ .real = msgpack.payloadToFloat(value) catch return error.TypeMismatch },
        .bytes => if (value == .bin) .{ .bytes = value.bin.value() } else return error.TypeMismatch,
        else => {
            if (constraints.enum_values != null) return error.EnumViolation;
            return;
        },
    };
    return validateScalar(constraints, ft, scalar, allocator);
}

/// Validates a decoded scalar against field constraints.
pub fn validateScalar(
    constraints: types.Constraints,
    ft: types.FieldType,
    value: Scalar,
    allocator: Allocator,
) !void {
    if (ft == .real) {
        if (value != .real) return error.TypeMismatch;
        if (!std.math.isFinite(value.real)) return error.RangeViolation;
    }
    if (constraints.enum_values) |enums| {
        try validateEnum(enums, ft, value);
    }

    switch (ft) {
        .text => try validateTextConstraints(constraints, value, allocator),
        .integer => try validateIntegerRange(constraints, value),
        .real => try validateRealRange(constraints, value),
        .bytes => try validateBinaryConstraints(constraints, value),
        else => {},
    }
}

inline fn validateBinaryConstraints(constraints: types.Constraints, value: Scalar) !void {
    if (value != .bytes) return error.TypeMismatch;
    const bytes = value.bytes;
    if (constraints.min_length) |min_l| {
        if (bytes.len < min_l) return error.LengthViolation;
    }
    if (constraints.max_length) |max_l| {
        if (bytes.len > max_l) return error.LengthViolation;
    }
}

inline fn validateTextConstraints(constraints: types.Constraints, value: Scalar, allocator: Allocator) !void {
    if (value != .text) return error.TypeMismatch;
    const str = value.text;

    try validateTextLength(constraints, str);

    if (constraints.compiled_regex) |regex| {
        const is_match = try matchPattern(regex, allocator, str);
        if (!is_match) return error.PatternViolation;
    }

    if (constraints.format) |fmt| {
        try validateTextFormat(fmt, str);
    }
}

inline fn validateTextLength(constraints: types.Constraints, str: []const u8) !void {
    if (constraints.min_length == null and constraints.max_length == null) return;
    const count = std.unicode.utf8CountCodepoints(str) catch return error.LengthViolation;
    if (constraints.min_length) |min_l| {
        if (count < min_l) return error.LengthViolation;
    }
    if (constraints.max_length) |max_l| {
        if (count > max_l) return error.LengthViolation;
    }
}

inline fn validateTextFormat(format: types.Constraints.Format, str: []const u8) !void {
    const valid = switch (format) {
        .email => validateEmail(str),
        .uuid => validateUuid(str),
        .uri => validateUri(str),
    };
    if (!valid) return error.FormatViolation;
}

inline fn validateIntegerRange(constraints: types.Constraints, value: Scalar) !void {
    if (constraints.minimum == null and constraints.maximum == null) return;
    if (value != .integer) return error.TypeMismatch;
    const int_val = value.integer;

    if (constraints.minimum) |min_val| {
        switch (min_val) {
            .integer => |min_i| if (int_val < min_i) return error.RangeViolation,
            .real => |min_r| if (@as(f64, @floatFromInt(int_val)) < min_r) return error.RangeViolation,
        }
    }
    if (constraints.maximum) |max_val| {
        switch (max_val) {
            .integer => |max_i| if (int_val > max_i) return error.RangeViolation,
            .real => |max_r| if (@as(f64, @floatFromInt(int_val)) > max_r) return error.RangeViolation,
        }
    }
}

inline fn validateRealRange(constraints: types.Constraints, value: Scalar) !void {
    if (constraints.minimum == null and constraints.maximum == null) return;
    if (value != .real) return error.TypeMismatch;
    const float_val = value.real;
    if (std.math.isNan(float_val)) return error.RangeViolation;

    if (constraints.minimum) |min_val| {
        const min_r = switch (min_val) {
            .real => |r| r,
            .integer => |i| @as(f64, @floatFromInt(i)),
        };
        if (float_val < min_r) return error.RangeViolation;
    }
    if (constraints.maximum) |max_val| {
        const max_r = switch (max_val) {
            .real => |r| r,
            .integer => |i| @as(f64, @floatFromInt(i)),
        };
        if (float_val > max_r) return error.RangeViolation;
    }
}

fn validateEnum(enums: []const types.Constraints.EnumValue, ft: types.FieldType, value: Scalar) !void {
    switch (ft) {
        .text => {
            if (value != .text) return error.TypeMismatch;
            if (!matchTextEnum(enums, value.text)) return error.EnumViolation;
        },
        .integer => {
            if (value != .integer) return error.TypeMismatch;
            if (!matchIntEnum(enums, value.integer)) return error.EnumViolation;
        },
        .real => {
            if (value != .real) return error.TypeMismatch;
            if (!matchRealEnum(enums, value.real)) return error.EnumViolation;
        },
        else => return error.EnumViolation,
    }
}

fn matchTextEnum(enums: []const types.Constraints.EnumValue, str: []const u8) bool {
    for (enums) |e| {
        switch (e) {
            .text => |t| if (std.mem.eql(u8, t, str)) return true,
            else => {},
        }
    }
    return false;
}

fn matchIntEnum(enums: []const types.Constraints.EnumValue, iv: i64) bool {
    for (enums) |e| {
        switch (e) {
            .integer => |expected| if (expected == iv) return true,
            // integer compared exactly first; f64 only as cross-type fallback
            .real => |expected| if (@as(f64, @floatFromInt(iv)) == expected) return true,
            else => {},
        }
    }
    return false;
}

fn matchRealEnum(enums: []const types.Constraints.EnumValue, fv: f64) bool {
    for (enums) |e| {
        switch (e) {
            .real => |expected| if (expected == fv) return true,
            .integer => |expected| if (@as(f64, @floatFromInt(expected)) == fv) return true,
            else => {},
        }
    }
    return false;
}
