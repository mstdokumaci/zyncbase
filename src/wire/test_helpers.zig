const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const typed_types = @import("../typed/types.zig");
const tth = @import("../typed/test_helpers.zig");

pub fn makeDeltaTestRecord(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !typed_types.Record {
    const values = try allocator.alloc(typed_types.Value, 6);
    errdefer allocator.free(values);

    values[0] = try tth.valTextOwned(allocator, id);
    errdefer values[0].deinit(allocator);
    values[1] = tth.valInt(1);
    values[2] = try tth.valTextOwned(allocator, "test-owner");
    errdefer values[2].deinit(allocator);
    values[3] = try tth.valTextOwned(allocator, name);
    errdefer values[3].deinit(allocator);
    values[4] = tth.valInt(0);
    values[5] = tth.valInt(0);

    return .{ .values = values };
}

pub fn encodePayload(allocator: std.mem.Allocator, payload: msgpack.Payload) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(allocator);
    try msgpack.encode(payload, list.writer(allocator));
    return list.toOwnedSlice(allocator);
}

pub fn writeFixStr(writer: anytype, s: []const u8) !void {
    // Write a fixstr header + payload bytes
    try writer.writeByte(@as(u8, @intCast(0xa0 | s.len)));
    try writer.writeAll(s);
}

pub fn writeFixMapHeader(writer: anytype, n: usize) !void {
    try writer.writeByte(@as(u8, @intCast(0x80 | n)));
}
