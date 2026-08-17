const std = @import("std");

const msgpack_test_helpers = @import("msgpack_test_helpers.zig");
const msgpack_utils = @import("msgpack_utils.zig");
const schema_types = @import("schema/types.zig");
const typed_doc_id = @import("typed/doc_id.zig");

pub fn createStoreSetMessageWithPayload(
    allocator: std.mem.Allocator,
    id: u64,
    _namespace_id: i64,
    table_index: usize,
    doc_id_value: typed_doc_id.DocId,
    value: msgpack_utils.Payload,
) ![]u8 {
    _ = _namespace_id;
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;

    try writer.writeByte(0x84); // fixmap(4) - removed namespace
    try msgpack_utils.writeMsgPackStr(writer, "type");
    try msgpack_utils.writeMsgPackStr(writer, "StoreSet");

    try msgpack_utils.writeMsgPackStr(writer, "id");
    try writer.writeByte(0xcf); // uint64
    try writer.writeInt(u64, id, .big);

    try msgpack_utils.writeMsgPackStr(writer, "path");
    try writer.writeByte(0x90 | 2); // fixarray(2)

    // 1. Table Index
    try writer.writeByte(0xcf); // uint64
    try writer.writeInt(u64, table_index, .big);

    // 2. Doc ID
    const doc_id_bytes = typed_doc_id.toBytes(doc_id_value);
    try msgpack_utils.writeMsgPackBin(writer, &doc_id_bytes);

    try msgpack_utils.writeMsgPackStr(writer, "value");
    try msgpack_utils.encode(value, writer);
    return buf.toOwnedSlice();
}

pub fn createStoreQueryMessageWithFilterKey(
    allocator: std.mem.Allocator,
    id: u64,
    _namespace_id: i64,
    table_index: usize,
    filter: msgpack_utils.Payload,
) ![]u8 {
    _ = _namespace_id;
    var p = msgpack_utils.Payload.mapPayload(allocator);
    defer p.free(allocator);

    {
        const k_val = try msgpack_utils.Payload.strToPayload("StoreQuery", allocator);
        errdefer k_val.free(allocator);
        try p.mapPut("type", k_val);
    }
    try p.mapPut("id", msgpack_utils.Payload.uintToPayload(id));
    {
        try p.mapPut("table_index", msgpack_utils.Payload.uintToPayload(table_index));
    }
    {
        const k_val = try filter.deepClone(allocator);
        errdefer k_val.free(allocator);
        try p.mapPut("filter", k_val);
    }

    var list = std.Io.Writer.Allocating.init(allocator);
    errdefer list.deinit();
    try msgpack_utils.encode(p, &list.writer);
    return try list.toOwnedSlice();
}

pub fn createStoreQueryMessageWithEmptyFilter(
    allocator: std.mem.Allocator,
    id: u64,
    namespace_id: i64,
    table_index: usize,
) ![]u8 {
    var filter = msgpack_utils.Payload.mapPayload(allocator);
    defer filter.free(allocator);
    return createStoreQueryMessageWithFilterKey(allocator, id, namespace_id, table_index, filter);
}

pub fn createStoreSubscribeMessage(
    allocator: std.mem.Allocator,
    id: u64,
    _namespace_id: i64,
    table_index: usize,
    filter: msgpack_utils.Payload,
    _subscription_id: u64,
) ![]u8 {
    _ = _namespace_id;
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

    var list = std.Io.Writer.Allocating.init(allocator);
    errdefer list.deinit();
    try msgpack_utils.encode(p, &list.writer);
    return try list.toOwnedSlice();
}

pub fn createCustomMessage(
    allocator: std.mem.Allocator,
    id: u64,
    msg_type: []const u8,
    namespace_id: i64,
    table_index: ?usize,
    path_suffix: []const []const u8,
) ![]u8 {
    _ = namespace_id;
    return msgpack_test_helpers.createMessage(allocator, id, msg_type, null, table_index, path_suffix, null);
}

pub fn createInvalidStoreSetMessageMissingId(
    allocator: std.mem.Allocator,
    _namespace_id: i64,
) ![]u8 {
    _ = _namespace_id;
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    const writer = &buf.writer;
    try writer.writeByte(0x81); // fixmap(1) - removed namespace
    try msgpack_utils.writeMsgPackStr(writer, "type");
    try msgpack_utils.writeMsgPackStr(writer, "StoreSet");
    return buf.toOwnedSlice();
}

/// Creates a MsgPack Payload representing a document as a pair-array based on schema.
/// Translates string field names to numeric indices using table metadata.
/// Returns a pair-array: [[field_index, value], ...]
pub fn createDocumentMapPayload(allocator: std.mem.Allocator, tbl: *const schema_types.Table, fields: anytype) !msgpack_utils.Payload {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    const fields_info = @typeInfo(@TypeOf(fields)).@"struct".fields;
    try msgpack_utils.encodeArrayHeader(writer, fields_info.len);

    inline for (fields_info) |f| {
        const entry = @field(fields, f.name);
        const raw_field = entry[0];
        const val = entry[1];

        const f_idx = switch (@typeInfo(@TypeOf(raw_field))) {
            .int, .comptime_int => @as(usize, @intCast(raw_field)),
            else => tbl.fieldIndex(raw_field) orelse return error.UnknownField,
        };

        // Encode pair: [field_index, value]
        try msgpack_utils.encodeArrayHeader(writer, 2);
        try msgpack_utils.encode(msgpack_utils.Payload.uintToPayload(f_idx), writer);
        try msgpack_test_helpers.encodeAnyToPayload(allocator, writer, val);
    }

    var reader: std.Io.Reader = .fixed(buf.written());
    return try msgpack_utils.decodeTrusted(allocator, &reader);
}
