const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");

pub fn comptimeEncodeKey(comptime key: []const u8) []const u8 { // zwanzig-disable-line: unused-parameter
    return &(struct {
        const val = blk: {
            var buf: [key.len + 5]u8 = undefined;
            var stream = std.Io.fixedBufferStream(&buf);
            msgpack.writeMsgPackStr(stream.writer(), key) catch @panic("comptime encode failed");
            break :blk buf[0..stream.pos].*;
        };
    }.val);
}
