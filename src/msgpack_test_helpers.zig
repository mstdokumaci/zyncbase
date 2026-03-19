const std = @import("std");
const msgpack_utils = @import("msgpack_utils.zig");

/// Wrapper for decode to maintain compatibility with zig-msgpack v0.0.16
pub const Payload = msgpack_utils.Payload;
pub const decode = msgpack_utils.decode;
pub const encode = msgpack_utils.encode;

/// Helper to create a MessagePack map for testing
/// Creates a simple map with string keys and values
pub fn createStoreSetMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    path: []const []const u8,
    value: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    // fixmap with 5 elements
    try buf.append(allocator, 0x85);

    // "type" key
    try writeString(allocator, &buf, "type");
    // "StoreSet" value
    try writeString(allocator, &buf, "StoreSet");

    // "id" key
    try writeString(allocator, &buf, "id");
    // id value (uint64)
    try buf.append(allocator, 0xcf); // uint 64
    try buf.append(allocator, @intCast((id >> 56) & 0xFF));
    try buf.append(allocator, @intCast((id >> 48) & 0xFF));
    try buf.append(allocator, @intCast((id >> 40) & 0xFF));
    try buf.append(allocator, @intCast((id >> 32) & 0xFF));
    try buf.append(allocator, @intCast((id >> 24) & 0xFF));
    try buf.append(allocator, @intCast((id >> 16) & 0xFF));
    try buf.append(allocator, @intCast((id >> 8) & 0xFF));
    try buf.append(allocator, @intCast(id & 0xFF));

    // "namespace" key
    try writeString(allocator, &buf, "namespace");
    // namespace value
    try writeString(allocator, &buf, namespace);

    // "path" key
    try writeString(allocator, &buf, "path");
    // path value (array of strings)
    try buf.append(allocator, @intCast(0x90 | path.len)); // fixarray
    for (path) |p| {
        try writeString(allocator, &buf, p);
    }

    // "value" key
    try writeString(allocator, &buf, "value");
    // value value (map with "val" field)
    try buf.append(allocator, 0x81); // fixmap with 1 element
    try writeString(allocator, &buf, "val"); // field name
    try writeString(allocator, &buf, value); // field value

    return buf.toOwnedSlice(allocator);
}

pub fn createStoreGetMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    path: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    // fixmap with 4 elements
    try buf.append(allocator, 0x84);

    // "type" key
    try writeString(allocator, &buf, "type");
    // "StoreGet" value
    try writeString(allocator, &buf, "StoreGet");

    // "id" key
    try writeString(allocator, &buf, "id");
    // id value (uint64)
    try buf.append(allocator, 0xcf); // uint 64
    try buf.append(allocator, @intCast((id >> 56) & 0xFF));
    try buf.append(allocator, @intCast((id >> 48) & 0xFF));
    try buf.append(allocator, @intCast((id >> 40) & 0xFF));
    try buf.append(allocator, @intCast((id >> 32) & 0xFF));
    try buf.append(allocator, @intCast((id >> 24) & 0xFF));
    try buf.append(allocator, @intCast((id >> 16) & 0xFF));
    try buf.append(allocator, @intCast((id >> 8) & 0xFF));
    try buf.append(allocator, @intCast(id & 0xFF));

    // "namespace" key
    try writeString(allocator, &buf, "namespace");
    // namespace value
    try writeString(allocator, &buf, namespace);

    // "path" key
    try writeString(allocator, &buf, "path");
    // path value (array of strings)
    try buf.append(allocator, @intCast(0x90 | path.len)); // fixarray
    for (path) |p| {
        try writeString(allocator, &buf, p);
    }

    return buf.toOwnedSlice(allocator);
}

pub fn writeString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    if (s.len <= 31) {
        try buf.append(allocator, @intCast(0xa0 | s.len));
    } else if (s.len <= 255) {
        try buf.append(allocator, 0xd9);
        try buf.append(allocator, @intCast(s.len));
    } else if (s.len <= 65535) {
        try buf.append(allocator, 0xda);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(s.len), .big);
        try buf.appendSlice(allocator, &b);
    } else {
        try buf.append(allocator, 0xdb);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, @intCast(s.len), .big);
        try buf.appendSlice(allocator, &b);
    }
    try buf.appendSlice(allocator, s);
}

pub fn encodeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try writeString(allocator, &buf, s);
    return buf.toOwnedSlice(allocator);
}

pub fn createStoreRemoveMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    path: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    // fixmap with 4 elements
    try buf.append(allocator, 0x84);

    // "type" key
    try writeString(allocator, &buf, "type");
    // "StoreRemove" value
    try writeString(allocator, &buf, "StoreRemove");

    // "id" key
    try writeString(allocator, &buf, "id");
    // id value (uint64)
    try buf.append(allocator, 0xcf); // uint 64
    try buf.append(allocator, @intCast((id >> 56) & 0xFF));
    try buf.append(allocator, @intCast((id >> 48) & 0xFF));
    try buf.append(allocator, @intCast((id >> 40) & 0xFF));
    try buf.append(allocator, @intCast((id >> 32) & 0xFF));
    try buf.append(allocator, @intCast((id >> 24) & 0xFF));
    try buf.append(allocator, @intCast((id >> 16) & 0xFF));
    try buf.append(allocator, @intCast((id >> 8) & 0xFF));
    try buf.append(allocator, @intCast(id & 0xFF));

    // "namespace" key
    try writeString(allocator, &buf, "namespace");
    // namespace value
    try writeString(allocator, &buf, namespace);

    // "path" key
    try writeString(allocator, &buf, "path");
    // path value (array of strings)
    try buf.append(allocator, @intCast(0x90 | path.len)); // fixarray
    for (path) |p| {
        try writeString(allocator, &buf, p);
    }

    return buf.toOwnedSlice(allocator);
}

pub fn createCustomMessage(
    allocator: std.mem.Allocator,
    id: u64,
    msg_type: []const u8,
    namespace: []const u8,
    path: []const []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    // fixmap with 4 elements
    try buf.append(allocator, 0x84);

    // "type" key
    try writeString(allocator, &buf, "type");
    // custom type value
    try writeString(allocator, &buf, msg_type);

    // "id" key
    try writeString(allocator, &buf, "id");
    // id value
    try buf.append(allocator, 0xcf);
    try buf.append(allocator, @intCast((id >> 56) & 0xFF));
    try buf.append(allocator, @intCast((id >> 48) & 0xFF));
    try buf.append(allocator, @intCast((id >> 40) & 0xFF));
    try buf.append(allocator, @intCast((id >> 32) & 0xFF));
    try buf.append(allocator, @intCast((id >> 24) & 0xFF));
    try buf.append(allocator, @intCast((id >> 16) & 0xFF));
    try buf.append(allocator, @intCast((id >> 8) & 0xFF));
    try buf.append(allocator, @intCast(id & 0xFF));

    // "namespace" key
    try writeString(allocator, &buf, "namespace");
    try writeString(allocator, &buf, namespace);

    // "path" key
    try writeString(allocator, &buf, "path");
    // path value (array of strings)
    try buf.append(allocator, @intCast(0x90 | path.len)); // fixarray
    for (path) |p| {
        try writeString(allocator, &buf, p);
    }

    return buf.toOwnedSlice(allocator);
}
