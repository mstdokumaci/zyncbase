const std = @import("std");
const msgpack = @import("msgpack");

/// Security-appropriate parse limits for WebSocket message handling.
/// These are much tighter than zig-msgpack's DEFAULT_LIMITS to prevent
/// stack overflow and OOM attacks from crafted payloads.
pub const TIGHT_LIMITS: msgpack.ParseLimits = .{
    .max_depth = 16,
    .max_array_length = 1_000,
    .max_map_size = 1_000,
    .max_string_length = 64 * 1024,
    .max_bin_length = 64 * 1024,
    .max_ext_length = 64 * 1024,
};

/// Local writer context wrapping std.Io.Writer (mirrors zig-msgpack's internal IoWriterContext).
const WriterCtx = struct {
    writer: *std.Io.Writer,

    fn write(self: WriterCtx, bytes: []const u8) std.Io.Writer.Error!usize {
        try self.writer.writeAll(bytes);
        return bytes.len;
    }
};

/// Local reader context wrapping std.Io.Reader (mirrors zig-msgpack's internal IoReaderContext).
const ReaderCtx = struct {
    reader: *std.Io.Reader,

    fn read(self: ReaderCtx, buf: []u8) error{ EndOfStream, ReadFailed }!usize {
        self.reader.readSliceAll(buf) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return error.ReadFailed,
        };
        return buf.len;
    }
};

/// Packer type with tight security limits.
const TightPacker = msgpack.PackWithLimits(
    WriterCtx,
    ReaderCtx,
    std.Io.Writer.Error,
    error{ EndOfStream, ReadFailed },
    WriterCtx.write,
    ReaderCtx.read,
    TIGHT_LIMITS,
);

/// Standard wrapper for decoding MsgPack payloads with tight security limits.
/// Rejects payloads that exceed TIGHT_LIMITS (depth, array/map size, string/bin/ext length).
/// The returned Payload must be freed using `payload.free(allocator)`.
pub fn decode(allocator: std.mem.Allocator, reader: *std.Io.Reader) !msgpack.Payload {
    var writer: std.Io.Writer = .failing;
    const writer_ctx = WriterCtx{ .writer = &writer };
    var packer = TightPacker.init(
        writer_ctx,
        ReaderCtx{ .reader = reader },
    );
    return packer.read(allocator);
}

/// Standard wrapper for encoding MsgPack payloads using zig-msgpack's PackerIO.
pub fn encode(payload: msgpack.Payload, writer: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .failing;
    var packer = msgpack.PackerIO.init(&reader, writer);
    return packer.write(payload);
}

pub const Payload = msgpack.Payload;
