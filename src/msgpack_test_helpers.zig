const std = @import("std");
const msgpack_utils = @import("msgpack_utils.zig");

/// Wrapper for decode to maintain compatibility with zig-msgpack v0.0.16
pub const Payload = msgpack_utils.Payload;
pub const decode = msgpack_utils.decode;
pub const encode = msgpack_utils.encode;
pub const writeMsgPackStr = msgpack_utils.writeMsgPackStr;

/// Helper to create a MessagePack map for testing
/// Creates a simple map with string keys and values
pub fn createMessage(
    allocator: std.mem.Allocator,
    id: u64,
    msg_type: []const u8,
    namespace: []const u8,
    path: []const []const u8,
    value: ?[]const u8,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    const num_elements: u8 = if (value != null) 5 else 4;
    try buf.append(allocator, 0x80 | num_elements); // fixmap with N elements

    // "type" key
    try writeMsgPackStr(writer, "type");
    try writeMsgPackStr(writer, msg_type);

    // "id" key
    try writeMsgPackStr(writer, "id");
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
    try writeMsgPackStr(writer, "namespace");
    try writeMsgPackStr(writer, namespace);

    // "path" key
    try writeMsgPackStr(writer, "path");
    // path value (array of strings)
    try buf.append(allocator, @intCast(0x90 | path.len)); // fixarray
    for (path) |p| {
        try writeMsgPackStr(writer, p);
    }

    if (value) |val| {
        // "value" key
        try writeMsgPackStr(writer, "value");
        if (path.len == 2) {
            // Document-level update: wrap in a map with a default field "val"
            // to maintain compatibility with existing tests.
            try buf.append(allocator, 0x81); // fixmap with 1 element
            try writeMsgPackStr(writer, "val"); // field name
            try writeMsgPackStr(writer, val); // field value
        } else {
            // Field-level or other update: send value directly as a string
            try writeMsgPackStr(writer, val);
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Helper to get a value from a MsgPack map by string key
pub fn getMapValue(payload: Payload, key: []const u8) ?Payload {
    if (payload != .map) return null;
    var it = payload.map.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k == .str and std.mem.eql(u8, k.str.value(), key)) {
            return entry.value_ptr.*;
        }
    }
    return null;
}

pub fn createStoreSetMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    path: []const []const u8,
    value: []const u8,
) ![]u8 {
    return createMessage(allocator, id, "StoreSet", namespace, path, value);
}

pub fn createStoreSetMessageWithPayload(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    path: []const []const u8,
    value: msgpack_utils.Payload,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try buf.append(allocator, 0x85); // fixmap(5)
    try writeMsgPackStr(writer, "type");
    try writeMsgPackStr(writer, "StoreSet");

    try writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf); // uint64
    for (0..8) |i| try buf.append(allocator, @intCast((id >> @intCast((7 - i) * 8)) & 0xFF));

    try writeMsgPackStr(writer, "namespace");
    try writeMsgPackStr(writer, namespace);

    try writeMsgPackStr(writer, "path");
    if (path.len < 16) {
        try buf.append(allocator, @intCast(0x90 | path.len)); // fixarray
    } else {
        try buf.append(allocator, 0xdc); // array16
        try buf.append(allocator, @intCast((path.len >> 8) & 0xFF));
        try buf.append(allocator, @intCast(path.len & 0xFF));
    }
    for (path) |seg| try writeMsgPackStr(writer, seg);

    try writeMsgPackStr(writer, "value");
    try msgpack_utils.encode(value, buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}

pub fn createStoreQueryMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    collection: []const u8,
    filter: msgpack_utils.Payload,
) ![]u8 {
    var p = msgpack_utils.Payload.mapPayload(allocator);
    defer p.free(allocator);

    {
        const k_val = try msgpack_utils.Payload.strToPayload("StoreQuery", allocator);
        errdefer k_val.free(allocator);
        try p.mapPut("type", k_val);
    }
    try p.mapPut("id", msgpack_utils.Payload.uintToPayload(id));
    {
        const k_val = try msgpack_utils.Payload.strToPayload(namespace, allocator);
        errdefer k_val.free(allocator);
        try p.mapPut("namespace", k_val);
    }
    {
        const k_val = try msgpack_utils.Payload.strToPayload(collection, allocator);
        errdefer k_val.free(allocator);
        try p.mapPut("collection", k_val);
    }

    // Flat filter fields
    if (filter == .map) {
        var it = filter.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str) {
                const cloned = try entry.value_ptr.*.deepClone(allocator);
                errdefer cloned.free(allocator);
                try p.mapPut(entry.key_ptr.*.str.value(), cloned);
            }
        }
    }

    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    try msgpack_utils.encode(p, list.writer(allocator));
    return try list.toOwnedSlice(allocator);
}

pub fn createStoreQueryMessageWithFilterKey(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    collection: []const u8,
    filter: msgpack_utils.Payload,
) ![]u8 {
    var p = msgpack_utils.Payload.mapPayload(allocator);
    defer p.free(allocator);

    try p.mapPut("type", try msgpack_utils.Payload.strToPayload("StoreQuery", allocator));
    try p.mapPut("id", msgpack_utils.Payload.uintToPayload(id));
    try p.mapPut("namespace", try msgpack_utils.Payload.strToPayload(namespace, allocator));
    try p.mapPut("collection", try msgpack_utils.Payload.strToPayload(collection, allocator));
    try p.mapPut("filter", try filter.deepClone(allocator));

    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    try msgpack_utils.encode(p, list.writer(allocator));
    return try list.toOwnedSlice(allocator);
}

pub fn createStoreQueryMessageWithEmptyFilter(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    collection: []const u8,
) ![]u8 {
    var filter = msgpack_utils.Payload.mapPayload(allocator);
    defer filter.free(allocator);
    return createStoreQueryMessageWithFilterKey(allocator, id, namespace, collection, filter);
}

pub fn createStoreSubscribeMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    collection: []const u8,
    filter: msgpack_utils.Payload,
    _subscription_id: u64,
) ![]u8 {
    var p = msgpack_utils.Payload.mapPayload(allocator);
    defer p.free(allocator);

    _ = _subscription_id;
    try p.mapPut("type", try msgpack_utils.Payload.strToPayload("StoreSubscribe", allocator));
    try p.mapPut("id", msgpack_utils.Payload.uintToPayload(id));
    try p.mapPut("namespace", try msgpack_utils.Payload.strToPayload(namespace, allocator));
    try p.mapPut("collection", try msgpack_utils.Payload.strToPayload(collection, allocator));

    // Flat filter fields
    if (filter == .map) {
        var it = filter.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str) {
                try p.mapPut(entry.key_ptr.*.str.value(), try entry.value_ptr.*.deepClone(allocator));
            }
        }
    }

    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);
    try msgpack_utils.encode(p, list.writer(allocator));
    return try list.toOwnedSlice(allocator);
}

pub fn createCustomMessage(
    allocator: std.mem.Allocator,
    id: u64,
    msg_type: []const u8,
    namespace: []const u8,
    path: []const []const u8,
) ![]u8 {
    return createMessage(allocator, id, msg_type, namespace, path, null);
}

pub fn createInvalidStoreSetMessageMissingId(
    allocator: std.mem.Allocator,
    namespace: []const u8,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try buf.append(allocator, 0x82); // fixmap(2)
    try writeMsgPackStr(writer, "type");
    try writeMsgPackStr(writer, "StoreSet");
    try writeMsgPackStr(writer, "namespace");
    try writeMsgPackStr(writer, namespace);
    return buf.toOwnedSlice(allocator);
}
