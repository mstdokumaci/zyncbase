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
    namespace: ?[]const u8,
    table_index: ?usize,
    path_suffix: []const []const u8,
    value: ?[]const u8,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    var num_elements: u8 = if (value != null) 5 else 4;
    if (namespace == null) num_elements -= 1;
    try buf.append(allocator, 0x80 | num_elements); // fixmap with N elements

    // "type" key
    try writeMsgPackStr(writer, "type");
    try writeMsgPackStr(writer, msg_type);

    // "id" key
    try writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf); // uint 64
    try writer.writeInt(u64, id, .big);

    // "namespace" key
    if (namespace) |ns| {
        try writeMsgPackStr(writer, "namespace");
        try writeMsgPackStr(writer, ns);
    }

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
