const std = @import("std");
const msgpack_utils = @import("msgpack_utils.zig");
const msgpack_test_helpers = @import("msgpack_test_helpers.zig");
const schema_manager = @import("schema_manager.zig");

pub fn createStoreSetMessage(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table_index: usize,
    doc_id: []const u8,
    value: []const u8,
) ![]u8 {
    // Compatibility helper for single-field test tables:
    // field index 0 is `id`, field index 1 is `namespace_id`.
    // The first custom user field sits at index 2.
    return createStoreSetFieldMessage(allocator, id, namespace, table_index, doc_id, 2, value);
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
    try msgpack_utils.writeMsgPackStr(writer, "type");
    try msgpack_utils.writeMsgPackStr(writer, "StoreSet");

    try msgpack_utils.writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf); // uint64
    try writer.writeInt(u64, id, .big);

    try msgpack_utils.writeMsgPackStr(writer, "namespace");
    try msgpack_utils.writeMsgPackStr(writer, namespace);

    try msgpack_utils.writeMsgPackStr(writer, "path");
    const path_len: usize = if (field_index != null) 3 else 2;
    try buf.append(allocator, @intCast(0x90 | path_len)); // fixarray

    // 1. Table Index
    try buf.append(allocator, 0xcf); // uint64
    try writer.writeInt(u64, table_index, .big);

    // 2. Doc ID
    try msgpack_utils.writeMsgPackStr(writer, doc_id);

    // 3. Optional Field Index
    if (field_index) |fi| {
        try buf.append(allocator, 0xcf); // uint64
        try writer.writeInt(u64, fi, .big);
    }

    try msgpack_utils.writeMsgPackStr(writer, "value");
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
    return msgpack_test_helpers.createMessage(allocator, id, msg_type, namespace, table_index, path_suffix, null);
}

pub fn createInvalidStoreSetMessageMissingId(
    allocator: std.mem.Allocator,
    namespace: []const u8,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try buf.append(allocator, 0x82); // fixmap(2)
    try msgpack_utils.writeMsgPackStr(writer, "type");
    try msgpack_utils.writeMsgPackStr(writer, "StoreSet");
    try msgpack_utils.writeMsgPackStr(writer, "namespace");
    try msgpack_utils.writeMsgPackStr(writer, namespace);
    return buf.toOwnedSlice(allocator);
}

/// Creates a MsgPack Payload representing a document map based on schema.
/// Translates string field names to numeric indices using TableMetadata.
pub fn createDocumentMapPayload(allocator: std.mem.Allocator, tbl: *const schema_manager.TableMetadata, fields: anytype) !msgpack_utils.Payload {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    const fields_info = @typeInfo(@TypeOf(fields)).@"struct".fields;
    try msgpack_utils.encodeMapHeader(writer, fields_info.len);

    inline for (fields_info) |f| {
        const entry = @field(fields, f.name);
        const raw_field = entry[0];
        const val = entry[1];

        const f_idx = switch (@typeInfo(@TypeOf(raw_field))) {
            .int, .comptime_int => @as(usize, @intCast(raw_field)),
            else => tbl.getFieldIndex(raw_field) orelse return error.UnknownField,
        };

        // Encode numeric key
        try msgpack_utils.encode(msgpack_utils.Payload.uintToPayload(f_idx), writer);

        // Encode value
        try msgpack_test_helpers.encodeAnyToPayload(allocator, writer, val);
    }

    var reader: std.Io.Reader = .fixed(buf.items);
    return try msgpack_utils.decodeTrusted(allocator, &reader);
}
