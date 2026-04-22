const std = @import("std");

pub const DocIdError = error{
    InvalidLength,
    InvalidHex,
};

pub const DocId = u128;

pub fn fromBytes(bytes: []const u8) DocIdError!DocId {
    if (bytes.len != 16) return error.InvalidLength;

    var value: u128 = 0;
    for (bytes) |b| {
        value = (value << 8) | @as(u128, b);
    }
    return value;
}

pub fn toBytes(id: DocId) [16]u8 {
    return std.mem.toBytes(std.mem.nativeToBig(u128, id));
}

pub fn fromHex(hex: []const u8) DocIdError!DocId {
    if (hex.len != 32) return error.InvalidLength;

    var value: u128 = 0;
    for (hex) |char| {
        const nibble: u8 = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => return error.InvalidHex,
        };
        value = (value << 4) | @as(u128, nibble);
    }
    return value;
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
