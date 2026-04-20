const std = @import("std");
const msgpack_utils = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const TableMetadata = schema_manager.TableMetadata;

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
    table_index: ?usize,
    path_suffix: []const []const u8,
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
    try buf.append(allocator, 0xcf); // uint 64
    try writer.writeInt(u64, id, .big);

    // "namespace" key
    try writeMsgPackStr(writer, "namespace");
    try writeMsgPackStr(writer, namespace);

    // "path" key
    try writeMsgPackStr(writer, "path");
    const path_len: u8 = @intCast(path_suffix.len + (if (table_index != null) @as(usize, 1) else 0));
    try buf.append(allocator, 0x90 | path_len); // fixarray
    if (table_index) |idx| {
        try buf.append(allocator, 0xcf); // uint 64
        try writer.writeInt(u64, idx, .big);
    }
    for (path_suffix) |p| {
        try writeMsgPackStr(writer, p);
    }

    if (value) |val| {
        // "value" key
        try writeMsgPackStr(writer, "value");
        if (path_suffix.len == 1 and table_index != null) {
            // Document-level update: wrap in a map with a default field "val"
            try buf.append(allocator, 0x81); // fixmap with 1 element
            try writeMsgPackStr(writer, "val"); // field name
            try writeMsgPackStr(writer, val); // field value
        } else {
            try writeMsgPackStr(writer, val);
        }
    }

    return buf.toOwnedSlice(allocator);
}

pub fn getMapValue(payload: Payload, key: []const u8) !?Payload {
    if (payload != .map) return null;
    return try payload.mapGet(key);
}

pub fn getMapValueByUint(payload: Payload, index: usize) !?Payload {
    if (payload != .map) return null;
    var it = payload.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (k == .uint and k.uint == index) return val;
    }
    return null;
}

pub fn getMapValueByName(payload: Payload, tbl: *const TableMetadata, name: []const u8) !?Payload {
    const index = tbl.getFieldIndex(name) orelse return null;
    return try getMapValueByUint(payload, index);
}

pub fn anyToPayload(allocator: std.mem.Allocator, val: anytype) !Payload {
    const T = @TypeOf(val);
    if (T == Payload) return try val.deepClone(allocator);

    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.child == u8 or (@typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8)) {
                return try Payload.strToPayload(val, allocator);
            }
        },
        .int, .comptime_int => {
            return Payload.intToPayload(@intCast(val));
        },
        .bool => {
            return Payload{ .bool = val };
        },
        else => {},
    }
    return error.UnsupportedType;
}

pub fn encodeAnyToPayload(allocator: std.mem.Allocator, writer: anytype, val: anytype) !void {
    const ValType = @TypeOf(val);
    if (ValType == Payload) {
        try msgpack_utils.encode(val, writer);
    } else {
        switch (@typeInfo(ValType)) {
            .pointer => |ptr| {
                if (ptr.child == u8 or (@typeInfo(ptr.child) == .array and @typeInfo(ptr.child).array.child == u8)) {
                    try msgpack_utils.writeMsgPackStr(writer, val);
                } else {
                    @compileError("Unsupported pointer type: " ++ @typeName(ValType));
                }
            },
            .int, .comptime_int => {
                try msgpack_utils.encode(msgpack_utils.Payload.uintToPayload(@intCast(val)), writer);
            },
            .bool => {
                try msgpack_utils.encode(.{ .bool = val }, writer);
            },
            else => @compileError("Unsupported value type: " ++ @typeName(ValType)),
        }
    }
    _ = allocator;
}

pub fn createStoreSetMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table_index: usize,
    doc_id: []const u8,
    value: []const u8,
) ![]u8 {
    // Compatibility helper for single-field test tables:
    // field index 0 is reserved for immutable system id.
    return createStoreSetFieldMessage(allocator, id, namespace, table_index, doc_id, 1, value);
}

pub fn createStoreSetFieldMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table_index: usize,
    doc_id: []const u8,
    field_index: usize,
    value: []const u8,
) ![]u8 {
    const val_payload = try msgpack_utils.Payload.strToPayload(value, allocator);
    defer val_payload.free(allocator);
    return createStoreSetMessageWithPayload(allocator, id, namespace, table_index, doc_id, field_index, val_payload);
}

pub fn createStoreSetMessageWithPayload(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table_index: usize,
    doc_id: []const u8,
    field_index: ?usize,
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
    try writer.writeInt(u64, id, .big);

    try writeMsgPackStr(writer, "namespace");
    try writeMsgPackStr(writer, namespace);

    try writeMsgPackStr(writer, "path");
    const path_len: usize = if (field_index != null) 3 else 2;
    try buf.append(allocator, @intCast(0x90 | path_len)); // fixarray

    // 1. Table Index
    try buf.append(allocator, 0xcf); // uint64
    try writer.writeInt(u64, table_index, .big);

    // 2. Doc ID
    try writeMsgPackStr(writer, doc_id);

    // 3. Optional Field Index
    if (field_index) |fi| {
        try buf.append(allocator, 0xcf); // uint64
        try writer.writeInt(u64, fi, .big);
    }

    try writeMsgPackStr(writer, "value");
    try msgpack_utils.encode(value, buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}

pub fn createStoreQueryMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table_index: usize,
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
        try p.mapPut("table_index", msgpack_utils.Payload.uintToPayload(table_index));
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
    table_index: usize,
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
        try p.mapPut("table_index", msgpack_utils.Payload.uintToPayload(table_index));
    }
    {
        const k_val = try filter.deepClone(allocator);
        errdefer k_val.free(allocator);
        try p.mapPut("filter", k_val);
    }

    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    try msgpack_utils.encode(p, list.writer(allocator));
    return try list.toOwnedSlice(allocator);
}

pub fn createStoreQueryMessageWithEmptyFilter(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table_index: usize,
) ![]u8 {
    var filter = msgpack_utils.Payload.mapPayload(allocator);
    defer filter.free(allocator);
    return createStoreQueryMessageWithFilterKey(allocator, id, namespace, table_index, filter);
}

pub fn createStoreSubscribeMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table_index: usize,
    filter: msgpack_utils.Payload,
    _subscription_id: u64,
) ![]u8 {
    var p = msgpack_utils.Payload.mapPayload(allocator);
    defer p.free(allocator);

    _ = _subscription_id;
    {
        const k_val = try msgpack_utils.Payload.strToPayload("StoreSubscribe", allocator);
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
        try p.mapPut("table_index", msgpack_utils.Payload.uintToPayload(table_index));
    }

    // Flat filter fields
    if (filter == .map) {
        var it = filter.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str) {
                const k_val = try entry.value_ptr.*.deepClone(allocator);
                errdefer k_val.free(allocator);
                try p.mapPut(entry.key_ptr.*.str.value(), k_val);
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
    table_index: ?usize,
    path_suffix: []const []const u8,
) ![]u8 {
    return createMessage(allocator, id, msg_type, namespace, table_index, path_suffix, null);
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
