const std = @import("std");
const msgpack = @import("msgpack");
const FieldType = @import("schema_parser.zig").FieldType;

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

pub fn encodeArrayHeader(writer: anytype, len: usize) !void {
    if (len <= 15) {
        try writer.writeByte(0x90 | @as(u8, @intCast(len)));
    } else if (len <= 0xffff) {
        try writer.writeByte(0xdc);
        try writer.writeInt(u16, @as(u16, @intCast(len)), .big);
    } else {
        try writer.writeByte(0xdd);
        try writer.writeInt(u32, @as(u32, @intCast(len)), .big);
    }
}

pub fn encodeMapHeader(writer: anytype, len: usize) !void {
    if (len <= 15) {
        try writer.writeByte(0x80 | @as(u8, @intCast(len)));
    } else if (len <= 0xffff) {
        try writer.writeByte(0xde);
        try writer.writeInt(u16, @as(u16, @intCast(len)), .big);
    } else {
        try writer.writeByte(0xdf);
        try writer.writeInt(u32, @as(u32, @intCast(len)), .big);
    }
}

pub const Payload = msgpack.Payload;
pub const Map = msgpack.Map;

/// Serializes a Payload to MessagePack and then encodes it as a Base64 string.
/// The caller owns the returned slice.
pub fn encodeBase64(allocator: std.mem.Allocator, payload: Payload) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    try encode(payload, buf.writer(allocator));

    const encoded_len = std.base64.standard.Encoder.calcSize(buf.items.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, buf.items);
    return encoded;
}

/// Decodes a Payload from a Base64-encoded MessagePack string.
/// Uses trusted limits since this is presumed to be a token generated by the server.
/// The caller owns the returned Payload.
pub fn decodeBase64(allocator: std.mem.Allocator, token: []const u8) !Payload {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(token) catch return error.InvalidBase64Token;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, token) catch return error.InvalidBase64Token;
    const final_decoded = decoded;

    var reader: std.Io.Reader = .fixed(final_decoded);
    return decodeTrusted(allocator, &reader) catch return error.InvalidBase64Token;
}

/// Parses a JSON array string and returns a Literal_Array Payload of items_type.
/// The caller owns the returned Payload and must call payload.free(allocator).
pub fn jsonToPayload(json: []const u8, allocator: std.mem.Allocator, items_type: FieldType) !Payload {
    return switch (items_type) {
        .text => jsonArrayToPayload([]const u8, allocator, json, mapStr),
        .integer => jsonArrayToPayload(i64, allocator, json, mapInt),
        .real => jsonArrayToPayload(f64, allocator, json, mapFloat),
        .boolean => jsonArrayToPayload(bool, allocator, json, mapBool),
        .array => error.UnsupportedArrayItemsType,
    };
}

// ─── Internal JSON Helpers ───────────────────────────────────────────────────

fn mapStr(v: []const u8, alloc: std.mem.Allocator) !Payload {
    return try Payload.strToPayload(v, alloc);
}
fn mapInt(v: i64, _: std.mem.Allocator) !Payload {
    return .{ .int = v };
}
fn mapFloat(v: f64, _: std.mem.Allocator) !Payload {
    return .{ .float = v };
}
fn mapBool(v: bool, _: std.mem.Allocator) !Payload {
    return .{ .bool = v };
}

fn jsonArrayToPayload(
    comptime T: type, // zwanzig-disable-line: unused-parameter
    allocator: std.mem.Allocator,
    json: []const u8,
    mapper: anytype,
) !Payload {
    const parsed = try std.json.parseFromSlice([]const ?T, allocator, json, .{});
    defer parsed.deinit();
    const arr = try allocator.alloc(Payload, parsed.value.len);
    errdefer allocator.free(arr);
    for (parsed.value, 0..) |v, i| {
        arr[i] = if (v) |val| try mapper(val, allocator) else .nil;
    }
    return .{ .arr = arr };
}
