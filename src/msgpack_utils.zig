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
            const reader_type = switch (comptime @typeInfo(R)) {
                .pointer => |ptr| ptr.child,
                else => R,
            };
            const has_read_slice_all = comptime @hasDecl(reader_type, "readSliceAll");
            if (comptime has_read_slice_all) {
                _ = self.reader.readSliceAll(buf) catch |err| switch (err) {
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.ReadFailed,
                };
            } else {
                _ = self.reader.readAll(buf) catch |err| switch (err) {
                    error.EndOfStream => return error.EndOfStream,
                    else => return error.ReadFailed,
                };
            }
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
        undefined,
        .{ .reader = reader },
    );
    return packer.read(allocator);
}

/// Decode with standard msgpack limits (used for internal cloning and db reads)
pub fn decodeTrusted(allocator: std.mem.Allocator, reader: anytype) !msgpack.Payload {
    const tp = tightPacker(void, @TypeOf(reader), msgpack.DEFAULT_LIMITS);
    var packer = tp.init(
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
        undefined,
    );
    return packer.write(payload);
}

pub const Payload = msgpack.Payload;
