const std = @import("std");

pub const DocIdError = error{
    InvalidLength,
    InvalidHex,
};

pub const DocId = u128;
const uuid_family_tag: u128 = @as(u128, 1) << 127;
const uuid_payload_mask: u128 = (@as(u128, 1) << 122) - 1;

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

pub fn generateUuidV7() DocId {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    const now = std.time.milliTimestamp();
    const millis: u64 = @intCast(@max(now, 0));
    bytes[0] = @intCast((millis >> 40) & 0xff);
    bytes[1] = @intCast((millis >> 32) & 0xff);
    bytes[2] = @intCast((millis >> 24) & 0xff);
    bytes[3] = @intCast((millis >> 16) & 0xff);
    bytes[4] = @intCast((millis >> 8) & 0xff);
    bytes[5] = @intCast(millis & 0xff);

    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return packUuidV7Bytes(&bytes);
}

pub fn fromStableString(value: []const u8) DocId {
    const high = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, value);
    const low = std.hash.Wyhash.hash(0xd1b54a32d192ed03, value);
    const payload = ((@as(u128, high) << 64) | @as(u128, low)) & uuid_payload_mask;
    return uuid_family_tag | payload;
}

fn packUuidV7Bytes(bytes: *const [16]u8) DocId {
    var payload: u128 = 0;
    for (bytes[0..6]) |byte| {
        payload = (payload << 8) | @as(u128, byte);
    }
    payload = (payload << 4) | @as(u128, bytes[6] & 0x0f);
    payload = (payload << 8) | @as(u128, bytes[7]);
    payload = (payload << 6) | @as(u128, bytes[8] & 0x3f);
    for (bytes[9..16]) |byte| {
        payload = (payload << 8) | @as(u128, byte);
    }
    return uuid_family_tag | payload;
}
