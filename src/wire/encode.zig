const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../msgpack_utils.zig");
const storage_mod = @import("../storage_engine.zig");
const typed = @import("../typed.zig");
const schema_mod = @import("../schema.zig");
const WireError = @import("errors.zig").WireError;
const comptimeEncodeKey = @import("comptime.zig").comptimeEncodeKey;

// === Comptime-encoded wire keys and values ===

const Keys = struct {
    pub const @"type" = comptimeEncodeKey("type");
    pub const id = comptimeEncodeKey("id");
    pub const code = comptimeEncodeKey("code");
    pub const message = comptimeEncodeKey("message");
    pub const sub_id = comptimeEncodeKey("subId");
    pub const value = comptimeEncodeKey("value");
    pub const has_more = comptimeEncodeKey("hasMore");
    pub const next_cursor = comptimeEncodeKey("nextCursor");
    pub const ops = comptimeEncodeKey("ops");
    pub const op = comptimeEncodeKey("op");
    pub const path = comptimeEncodeKey("path");
    pub const user_id = comptimeEncodeKey("userId");
    pub const tables = comptimeEncodeKey("tables");
    pub const fields = comptimeEncodeKey("fields");
    pub const field_flags = comptimeEncodeKey("fieldFlags");
};

const Values = struct {
    pub const ok = comptimeEncodeKey("ok");
    pub const @"error" = comptimeEncodeKey("error");
    pub const connected = comptimeEncodeKey("Connected");
    pub const schema_sync = comptimeEncodeKey("SchemaSync");
    pub const store_delta = comptimeEncodeKey("StoreDelta");
    pub const op_remove = comptimeEncodeKey("remove");
    pub const op_set = comptimeEncodeKey("set");
};

// === Comptime-encoded hot-path headers ===

const ok_id_header = blk: {
    var buf: [Keys.type.len + Values.ok.len + Keys.id.len]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll(Keys.type) catch @panic("comptime: failed to write type key");
    w.writeAll(Values.ok) catch @panic("comptime: failed to write ok value");
    w.writeAll(Keys.id) catch @panic("comptime: failed to write id key");
    break :blk buf[0..w.end].*;
};

const success_header = blk: {
    var buf: [1 + ok_id_header.len]u8 = undefined;
    buf[0] = 0x82; // fixmap(2)
    @memcpy(buf[1..], &ok_id_header);
    break :blk buf[0..].*;
};

const error_type_header = blk: {
    var buf: [Keys.type.len + Values.@"error".len + Keys.code.len]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeAll(Keys.type) catch @panic("comptime: failed to write type key");
    w.writeAll(Values.@"error") catch @panic("comptime: failed to write error value");
    w.writeAll(Keys.code) catch @panic("comptime: failed to write code key");
    break :blk buf[0..w.end].*;
};

const error_header_with_id = blk: {
    var buf: [1 + error_type_header.len]u8 = undefined;
    buf[0] = 0x84; // fixmap(4)
    @memcpy(buf[1..], &error_type_header);
    break :blk buf[0..].*;
};

const error_header_without_id = blk: {
    var buf: [1 + error_type_header.len]u8 = undefined;
    buf[0] = 0x83; // fixmap(3)
    @memcpy(buf[1..], &error_type_header);
    break :blk buf[0..].*;
};

pub const store_delta_header = blk: {
    var buf: [1 + Keys.type.len + Values.store_delta.len + Keys.sub_id.len]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.writeByte(0x83) catch @panic("comptime: failed to write map header");
    w.writeAll(Keys.type) catch @panic("comptime: failed to write type key");
    w.writeAll(Values.store_delta) catch @panic("comptime: failed to write StoreDelta value");
    w.writeAll(Keys.sub_id) catch @panic("comptime: failed to write subId key");
    break :blk buf[0..w.end].*;
};

// === Response builders ===

pub fn encodeSuccess(msgpack_allocator: Allocator, msg_id: u64) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(msgpack_allocator);
    const writer = list.writer(msgpack_allocator);

    try list.appendSlice(msgpack_allocator, &success_header);
    try writer.writeByte(0xcf);
    try writer.writeInt(u64, msg_id, .big);

    return list.toOwnedSlice(msgpack_allocator);
}

pub fn encodeConnected(
    msgpack_allocator: Allocator,
    user_id: ?[]const u8,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(msgpack_allocator);
    const writer = list.writer(msgpack_allocator);

    try msgpack.encodeMapHeader(writer, 2);

    try list.appendSlice(msgpack_allocator, Keys.type);
    try list.appendSlice(msgpack_allocator, Values.connected);

    try list.appendSlice(msgpack_allocator, Keys.user_id);
    if (user_id) |uid| {
        try msgpack.writeMsgPackStr(writer, uid);
    } else {
        try msgpack.encode(.nil, writer);
    }

    return list.toOwnedSlice(msgpack_allocator);
}

pub fn encodeError(
    msgpack_allocator: Allocator,
    msg_id: ?u64,
    wire_err: WireError,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(msgpack_allocator);
    const writer = list.writer(msgpack_allocator);

    try list.appendSlice(msgpack_allocator, if (msg_id != null) &error_header_with_id else &error_header_without_id);
    try list.appendSlice(msgpack_allocator, wire_err.code);

    if (msg_id) |id| {
        try list.appendSlice(msgpack_allocator, Keys.id);
        try writer.writeByte(0xcf);
        try writer.writeInt(u64, id, .big);
    }

    try list.appendSlice(msgpack_allocator, Keys.message);
    try list.appendSlice(msgpack_allocator, wire_err.message);

    return list.toOwnedSlice(msgpack_allocator);
}

pub const QueryResponse = struct {
    msg_id: u64,
    sub_id: ?u64 = null,
    results: *const storage_mod.ManagedResult,
    table: *const storage_mod.TableMetadata,
    next_cursor: ?[]const u8 = null,
};

pub fn encodeQuery(
    arena_allocator: std.mem.Allocator,
    response: QueryResponse,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(arena_allocator);
    const writer = list.writer(arena_allocator);

    const map_size: usize = if (response.sub_id != null) 6 else 4;
    try msgpack.encodeMapHeader(writer, map_size);

    try list.appendSlice(arena_allocator, &ok_id_header);
    try msgpack.encode(msgpack.Payload.uintToPayload(response.msg_id), writer);

    if (response.sub_id) |sid| {
        try list.appendSlice(arena_allocator, Keys.sub_id);
        try msgpack.encode(msgpack.Payload.uintToPayload(sid), writer);
    }

    try list.appendSlice(arena_allocator, Keys.value);
    try msgpack.encodeArrayHeader(writer, response.results.records.len);
    for (response.results.records) |record| {
        try encodeRecord(writer, record, response.table);
    }

    if (response.sub_id != null) {
        const has_more = response.next_cursor != null;
        try list.appendSlice(arena_allocator, Keys.has_more);
        try msgpack.encode(msgpack.Payload{ .bool = has_more }, writer);
    }

    try list.appendSlice(arena_allocator, Keys.next_cursor);
    if (response.next_cursor) |cursor_str| {
        try msgpack.writeMsgPackStr(writer, cursor_str);
    } else {
        try msgpack.encode(.nil, writer);
    }

    return list.toOwnedSlice(arena_allocator);
}

pub fn encodeSchemaSync(allocator: Allocator, schema: *const schema_mod.Schema) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.encodeMapHeader(writer, 4);

    try list.appendSlice(allocator, Keys.type);
    try list.appendSlice(allocator, Values.schema_sync);

    const tables = schema.tables;

    try list.appendSlice(allocator, Keys.tables);
    try msgpack.encodeArrayHeader(writer, tables.len);
    for (tables) |table| {
        try msgpack.writeMsgPackStr(writer, table.name);
    }

    try list.appendSlice(allocator, Keys.fields);
    try msgpack.encodeArrayHeader(writer, tables.len);
    for (tables) |table| {
        const tbl_md = schema.getTable(table.name) orelse return error.UnknownTable;
        try msgpack.encodeArrayHeader(writer, tbl_md.fields.len);
        for (tbl_md.fields) |field| {
            try msgpack.writeMsgPackStr(writer, field.name);
        }
    }

    try list.appendSlice(allocator, Keys.field_flags);
    try msgpack.encodeArrayHeader(writer, tables.len);
    for (tables) |table| {
        const tbl_md = schema.getTable(table.name) orelse return error.UnknownTable;
        try msgpack.encodeArrayHeader(writer, tbl_md.fields.len);
        for (tbl_md.fields) |field| {
            var flags: u8 = 0;
            if (field.isSystem()) flags |= 0b01;
            if (field.storage_type == .doc_id) flags |= 0b10;
            try msgpack.encode(msgpack.Payload.uintToPayload(flags), writer);
        }
    }

    return list.toOwnedSlice(allocator);
}

// === Delta encoding ===

fn encodeDeltaOp(
    allocator: Allocator,
    comptime op: DeltaOp,
    table_index: usize,
    id_val: typed.Value,
    maybe_value: ?struct { record: typed.Record, meta: *const storage_mod.TableMetadata },
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try list.appendSlice(allocator, Keys.ops);
    try writer.writeByte(0x91); // fixarray(1)

    const op_map_size: u8 = if (maybe_value != null) 3 else 2;
    try writer.writeByte(0x80 | op_map_size);

    try list.appendSlice(allocator, Keys.op);
    try list.appendSlice(allocator, switch (op) {
        .remove => Values.op_remove,
        .set => Values.op_set,
    });

    try list.appendSlice(allocator, Keys.path);
    try writer.writeByte(0x92); // fixarray(2)
    try msgpack.encode(msgpack.Payload.uintToPayload(table_index), writer);
    try typed.writeMsgPack(id_val, writer);

    if (maybe_value) |v| {
        try list.appendSlice(allocator, Keys.value);
        try encodeRecord(writer, v.record, v.meta);
    }

    return list.toOwnedSlice(allocator);
}

pub const DeltaOp = enum { remove, set };

pub fn encodeDeleteDeltaSuffix(
    allocator: Allocator,
    table_index: usize,
    id_val: typed.Value,
) ![]const u8 {
    return encodeDeltaOp(allocator, .remove, table_index, id_val, null);
}

pub fn encodeSetDeltaSuffix(
    allocator: Allocator,
    table_index: usize,
    id_val: typed.Value,
    new_record: typed.Record,
    table_metadata: *const storage_mod.TableMetadata,
) ![]const u8 {
    return encodeDeltaOp(allocator, .set, table_index, id_val, .{
        .record = new_record,
        .meta = table_metadata,
    });
}

pub inline fn encodeRecord(writer: anytype, record: typed.Record, table_metadata: *const storage_mod.TableMetadata) !void {
    if (record.values.len != table_metadata.fields.len) return error.InternalError;
    try msgpack.encodeMapHeader(writer, record.values.len);
    for (record.values, 0..) |typed_value, idx| {
        try msgpack.encode(msgpack.Payload.uintToPayload(idx), writer);
        try typed.writeMsgPack(typed_value, writer);
    }
}
