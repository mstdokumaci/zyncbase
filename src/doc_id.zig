const std = @import("std");

pub const DocIdError = error{
    InvalidLength,
    InvalidHex,
};

pub const DocId = u128;

pub fn fromBytes(bytes: []const u8) DocIdError!DocId {
    if (bytes.len != 16) return error.InvalidLength;
    return std.mem.readInt(DocId, bytes[0..16], .big);
}

pub fn toBytes(id: DocId) [16]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u128, id));
}

pub fn fromHex(hex: []const u8) DocIdError!DocId {
    if (hex.len != 32) return error.InvalidLength;
    return std.fmt.parseInt(DocId, hex, 16) catch return error.InvalidHex;
}

pub fn eql(a: DocId, b: DocId) bool {
    return a == b;
}

pub fn order(a: DocId, b: DocId) std.math.Order {
    return std.math.order(a, b);
}

pub fn lessThan(a: DocId, b: DocId) bool {
    return order(a, b) == .lt;
}

pub fn hexSlice(id: DocId, buf: *[32]u8) []const u8 {
    const digits = "0123456789abcdef";
    const bytes = toBytes(id);
    for (bytes, 0..) |byte, i| {
        buf[i * 2] = digits[byte >> 4];
        buf[i * 2 + 1] = digits[byte & 0x0f];
    }
    return buf[0..];
}
