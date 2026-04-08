const std = @import("std");
const msgpack = @import("msgpack");

/// Security-appropriate parse limits for WebSocket message handling.
/// These align with the ZyncBase Wire Protocol Specification.
pub const wire_limits: msgpack.ParseLimits = .{
    .max_depth = 32,
    .max_array_length = 100_000,
    .max_map_size = 100_000,
    .max_string_length = 1 * 1024 * 1024, // 1 MB
    .max_bin_length = 1 * 1024 * 1024, // 1 MB
    .max_ext_length = 1 * 1024 * 1024, // 1 MB
};

fn writerCtx(comptime W: type) type {
    _ = @typeName(W);
    return struct {
        writer: W,

        fn write(self: @This(), bytes: []const u8) !usize {
            try self.writer.writeAll(bytes);
            return bytes.len;
        }
    };
}

fn readerCtx(comptime R: type) type {
    _ = @typeName(R);
    return struct {
        reader: R,

        fn read(self: @This(), buf: []u8) error{ EndOfStream, ReadFailed }!usize {
            self.reader.readSliceAll(buf) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.ReadFailed,
            };
            return buf.len;
        }
    };
}

fn tightPacker(comptime W: type, comptime R: type, comptime limits: msgpack.ParseLimits) type {
    return msgpack.PackWithLimits(
        writerCtx(W),
        readerCtx(R),
        anyerror,
        error{ EndOfStream, ReadFailed },
        writerCtx(W).write,
        readerCtx(R).read,
        limits,
    );
}

/// Standard wrapper for decoding MsgPack payloads with wire security limits.
/// Rejects payloads that exceed wire_limits (depth, array/map size, string/bin/ext length).
/// The returned Payload must be freed using `payload.free(allocator)`.
pub fn decode(allocator: std.mem.Allocator, reader: anytype) !msgpack.Payload {
    const tp = tightPacker(void, @TypeOf(reader), wire_limits);
    var packer = tp.init(
        // SAFETY: reader Context is provided, writer is not used for decoding
        undefined,
        .{ .reader = reader },
    );
    return packer.read(allocator);
}

/// Decode with standard msgpack limits (used for internal cloning and db reads)
pub fn decodeTrusted(allocator: std.mem.Allocator, reader: anytype) !msgpack.Payload {
    const tp = tightPacker(void, @TypeOf(reader), msgpack.DEFAULT_LIMITS);
    var packer = tp.init(
        // SAFETY: reader Context is provided, writer is not used for decoding
        undefined,
        .{ .reader = reader },
    );
    return packer.read(allocator);
}

/// Standard wrapper for encoding MsgPack payloads for wire transmission.
/// Enforces wire_limits to ensure clients can parse the response.
pub fn encode(payload: msgpack.Payload, writer: anytype) !void {
    const tp = tightPacker(@TypeOf(writer), void, wire_limits);
    var packer = tp.init(
        .{ .writer = writer },
        // SAFETY: writer Context is provided, reader is not used for encoding
        undefined,
    );
    return packer.write(payload);
}

/// Generic wrapper for encoding MsgPack payloads without tight wire limits.
/// Used for internal storage and cloning.
pub fn encodeTrusted(payload: msgpack.Payload, writer: anytype) !void {
    const tp = tightPacker(@TypeOf(writer), void, msgpack.DEFAULT_LIMITS);
    var packer = tp.init(
        .{ .writer = writer },
        // SAFETY: writer Context is provided, reader is not used for encoding
        undefined,
    );
    return packer.write(payload);
}

/// Writes a string to the output using MessagePack fixstr/str8/str16/str32 encoding.
pub fn writeMsgPackStr(writer: anytype, s: []const u8) !void {
    if (s.len <= 31) {
        try writer.writeByte(0xa0 | @as(u8, @intCast(s.len)));
    } else if (s.len <= 0xff) {
        try writer.writeByte(0xd9);
        try writer.writeByte(@as(u8, @intCast(s.len)));
    } else if (s.len <= 0xffff) {
        try writer.writeByte(0xda);
        try writer.writeInt(u16, @as(u16, @intCast(s.len)), .big);
    } else {
        try writer.writeByte(0xdb);
        try writer.writeInt(u32, @as(u32, @intCast(s.len)), .big);
    }
    try writer.writeAll(s);
}

pub fn encodePayload(allocator: std.mem.Allocator, payload: Payload) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(allocator);
    try encode(payload, list.writer(allocator));
    return list.toOwnedSlice(allocator);
}

pub const Payload = msgpack.Payload;
pub const Map = msgpack.Map;

/// Returns true if the payload is a literal (primitive) value: nil, bool, int, uint, float, or str.
/// Returns false for arr, map, bin, ext, and timestamp.
pub fn isLiteral(payload: Payload) bool {
    return switch (payload) {
        .nil, .bool, .int, .uint, .float, .str => true,
        .arr, .map, .bin, .ext, .timestamp => false,
    };
}

/// Converts a literal payload to a deterministic string for canonical keys.
/// Rejects complex types (arr, map, bin, ext, timestamp).
/// The caller owns the returned slice.
pub fn payloadToCanonicalString(payload: Payload, allocator: std.mem.Allocator) ![]const u8 {
    return switch (payload) {
        .nil => try allocator.dupe(u8, "null"),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .int => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .uint => |v| try std.fmt.allocPrint(allocator, "{d}", .{v}),
        .float => |v| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
            errdefer allocator.free(s);
            // Ensure float representation has a dot or exponent
            if (std.mem.indexOfScalar(u8, s, '.') == null and std.mem.indexOfScalar(u8, s, 'e') == null and std.mem.indexOfScalar(u8, s, 'E') == null) {
                const s2 = try std.mem.concat(allocator, u8, &.{ s, ".0" });
                allocator.free(s);
                return s2;
            }
            return s;
        },
        .str => |s| try allocator.dupe(u8, s.value()),
        else => error.UnsupportedCanonicalType,
    };
}

/// Validates that payload is an array containing only literal elements.
/// Returns error.NotAnArray if payload is not .arr.
/// Returns error.NonLiteralElement if any element fails isLiteral.
/// Returns without error for valid literal arrays, including empty arrays.
pub fn ensureLiteralArray(payload: Payload) error{ NotAnArray, NonLiteralElement }!void {
    const arr = switch (payload) {
        .arr => |a| a,
        else => return error.NotAnArray,
    };
    for (arr) |elem| {
        if (!isLiteral(elem)) return error.NonLiteralElement;
    }
}

/// Converts a Literal_Array Payload to a JSON array string.
/// Calls ensureLiteralArray first; propagates any error.
/// The caller owns the returned slice.
pub fn payloadToJson(payload: Payload, allocator: std.mem.Allocator) ![]const u8 {
    try ensureLiteralArray(payload);
    const arr = payload.arr;
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (arr, 0..) |elem, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        switch (elem) {
            .nil => try buf.appendSlice(allocator, "null"),
            .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
            .float => |v| {
                // Always emit a decimal point so JSON parsers treat this as a float,
                // not an integer. e.g. 50.0 → "50.0" not "50".
                const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(s);
                try buf.appendSlice(allocator, s);
                // If no decimal point or exponent, append ".0" to preserve float type.
                const has_dot = std.mem.indexOfScalar(u8, s, '.') != null;
                const has_exp = std.mem.indexOfScalar(u8, s, 'e') != null or std.mem.indexOfScalar(u8, s, 'E') != null;
                if (!has_dot and !has_exp) try buf.appendSlice(allocator, ".0");
            },
            .str => |s| {
                try buf.append(allocator, '"');
                for (s.value()) |c| {
                    switch (c) {
                        '"' => try buf.appendSlice(allocator, "\\\""),
                        '\\' => try buf.appendSlice(allocator, "\\\\"),
                        '\n' => try buf.appendSlice(allocator, "\\n"),
                        '\r' => try buf.appendSlice(allocator, "\\r"),
                        '\t' => try buf.appendSlice(allocator, "\\t"),
                        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try std.fmt.format(buf.writer(allocator), "\\u{x:0>4}", .{c}),
                        else => try buf.append(allocator, c),
                    }
                }
                try buf.append(allocator, '"');
            },
            .int => |v| try std.fmt.format(buf.writer(allocator), "{d}", .{v}),
            .uint => |v| try std.fmt.format(buf.writer(allocator), "{d}", .{v}),
            else => unreachable, // ensureLiteralArray already validated
        }
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

/// Helper to extract an i64 from a Payload (supports .int and .uint).
pub fn payloadAsInt(payload: Payload) !i64 {
    return switch (payload) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => error.NotAnInteger,
    };
}

/// Helper to extract an f64 from a Payload (supports .float, .int, and .uint).
pub fn payloadAsFloat(payload: Payload) !f64 {
    return switch (payload) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .uint => |v| @floatFromInt(v),
        else => error.NotAFloat,
    };
}

/// Helper to extract a bool from a Payload.
pub fn payloadAsBool(payload: Payload) !bool {
    return switch (payload) {
        .bool => |v| v,
        else => error.NotABoolean,
    };
}

/// Parses a JSON array string and returns a Literal_Array Payload.
/// Returns error.NotAnArray if the top-level JSON value is not an array.
/// Returns error.NonLiteralElement if any element is an object or nested array.
/// The caller owns the returned Payload and must call payload.free(allocator).
pub fn jsonToPayload(json: []const u8, allocator: std.mem.Allocator) !Payload {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const json_arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.NotAnArray,
    };

    const payloads = try allocator.alloc(Payload, json_arr.items.len);
    errdefer allocator.free(payloads);
    var count: usize = 0;
    errdefer for (payloads[0..count]) |p| p.free(allocator);

    for (json_arr.items) |item| {
        payloads[count] = switch (item) {
            .null => .nil,
            .bool => |b| .{ .bool = b },
            .integer => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .number_string => |s| blk: {
                // Large integers that exceed i64 range are returned as number_string.
                // Try parsing as u64 first, then i64.
                if (std.fmt.parseInt(u64, s, 10)) |v| {
                    break :blk .{ .uint = v };
                } else |_| {}
                if (std.fmt.parseInt(i64, s, 10)) |v| {
                    break :blk .{ .int = v };
                } else |_| {}
                if (std.fmt.parseFloat(f64, s)) |v| {
                    break :blk .{ .float = v };
                } else |_| {}
                return error.NonLiteralElement;
            },
            .string => |s| try Payload.strToPayload(s, allocator),
            .object, .array => return error.NonLiteralElement,
        };
        count += 1;
    }

    return Payload{ .arr = payloads };
}
