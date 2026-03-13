const std = @import("std");
const msgpack = @import("msgpack");

/// Standard wrapper for decoding MsgPack payloads using zig-msgpack's PackerIO.
/// The returned Payload must be freed using `payload.free(allocator)`.
pub fn decodePayload(allocator: std.mem.Allocator, reader: *std.Io.Reader) !msgpack.Payload {
    var writer: std.Io.Writer = .failing;
    var packer = msgpack.PackerIO.init(reader, &writer);
    return packer.read(allocator);
}

/// Standard wrapper for encoding MsgPack payloads using zig-msgpack's PackerIO.
pub fn encodePayload(payload: msgpack.Payload, writer: *std.Io.Writer) !void {
    var reader: std.Io.Reader = .failing;
    var packer = msgpack.PackerIO.init(&reader, writer);
    return packer.write(payload);
}
