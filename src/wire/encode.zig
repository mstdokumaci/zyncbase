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
    pub const retry_after = comptimeEncodeKey("retryAfter");
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
    pub const write_id = comptimeEncodeKey("writeId");
    pub const details = comptimeEncodeKey("details");
    pub const phase = comptimeEncodeKey("phase");
    pub const batch_index = comptimeEncodeKey("batchIndex");
    pub const session = comptimeEncodeKey("session");
    pub const token = comptimeEncodeKey("token");
    pub const presence_user_fields = comptimeEncodeKey("presenceUserFields");
    pub const presence_shared_fields = comptimeEncodeKey("presenceSharedFields");
    pub const event = comptimeEncodeKey("event");
    pub const data = comptimeEncodeKey("data");
    pub const users = comptimeEncodeKey("users");
    pub const shared = comptimeEncodeKey("shared");
    pub const joined_at = comptimeEncodeKey("joinedAt");
};

const Values = struct {
    pub const ok = comptimeEncodeKey("ok");
    pub const @"error" = comptimeEncodeKey("error");
    pub const connected = comptimeEncodeKey("Connected");
    pub const schema_sync = comptimeEncodeKey("SchemaSync");
    pub const store_delta = comptimeEncodeKey("StoreDelta");
    pub const op_remove = comptimeEncodeKey("remove");
    pub const op_set = comptimeEncodeKey("set");
    pub const write_committed = comptimeEncodeKey("WriteCommitted");
    pub const presence_broadcast = comptimeEncodeKey("PresenceBroadcast");
    pub const shared_state_broadcast = comptimeEncodeKey("SharedStateBroadcast");
    pub const write_error = comptimeEncodeKey("WriteError");
    pub const phase_write = comptimeEncodeKey("write");
    pub const server_disconnect = comptimeEncodeKey("ServerDisconnect");
    pub const event_join = comptimeEncodeKey("join");
    pub const event_update = comptimeEncodeKey("update");
    pub const event_leave = comptimeEncodeKey("leave");
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

    try writer.writeAll(&success_header);
    try writer.writeByte(0xcf);
    try writer.writeInt(u64, msg_id, .big);

    return list.toOwnedSlice(msgpack_allocator);
}

pub fn encodeOkWithSession(
    msgpack_allocator: Allocator,
    msg_id: u64,
    session_claims: *const std.StringHashMapUnmanaged(typed.Value),
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(msgpack_allocator);
    const writer = list.writer(msgpack_allocator);

    try msgpack.encodeMapHeader(writer, 3);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.ok);

    try writer.writeAll(Keys.id);
    try writer.writeByte(0xcf);
    try writer.writeInt(u64, msg_id, .big);

    try writer.writeAll(Keys.session);
    try msgpack.encodeMapHeader(writer, session_claims.count());
    var it = session_claims.iterator();
    while (it.next()) |entry| {
        try msgpack.writeMsgPackStr(writer, entry.key_ptr.*);
        try typed.writeMsgPack(entry.value_ptr.*, writer);
    }

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

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.connected);

    try writer.writeAll(Keys.user_id);
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

    if (wire_err.retry_after_ms) |retry_after| {
        const map_size: usize = if (msg_id != null) 5 else 4;
        try msgpack.encodeMapHeader(writer, map_size);

        try writer.writeAll(Keys.type);
        try writer.writeAll(Values.@"error");

        try writer.writeAll(Keys.code);
        try writer.writeAll(wire_err.code);

        if (msg_id) |id| {
            try writer.writeAll(Keys.id);
            try writer.writeByte(0xcf);
            try writer.writeInt(u64, id, .big);
        }

        try writer.writeAll(Keys.message);
        try writer.writeAll(wire_err.message);

        try writer.writeAll(Keys.retry_after);
        try msgpack.encode(msgpack.Payload.uintToPayload(retry_after), writer);
    } else {
        try writer.writeAll(if (msg_id != null) &error_header_with_id else &error_header_without_id);
        try writer.writeAll(wire_err.code);

        if (msg_id) |id| {
            try writer.writeAll(Keys.id);
            try writer.writeByte(0xcf);
            try writer.writeInt(u64, id, .big);
        }

        try writer.writeAll(Keys.message);
        try writer.writeAll(wire_err.message);
    }

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

    try writer.writeAll(&ok_id_header);
    try msgpack.encode(msgpack.Payload.uintToPayload(response.msg_id), writer);

    if (response.sub_id) |sid| {
        try writer.writeAll(Keys.sub_id);
        try msgpack.encode(msgpack.Payload.uintToPayload(sid), writer);
    }

    try writer.writeAll(Keys.value);
    try msgpack.encodeArrayHeader(writer, response.results.records.len);
    for (response.results.records) |record| {
        try encodeRecord(writer, record, response.table);
    }

    if (response.sub_id != null) {
        const has_more = response.next_cursor != null;
        try writer.writeAll(Keys.has_more);
        try msgpack.encode(msgpack.Payload{ .bool = has_more }, writer);
    }

    try writer.writeAll(Keys.next_cursor);
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

    try msgpack.encodeMapHeader(writer, 6);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.schema_sync);

    const tables = schema.tables;

    try writer.writeAll(Keys.tables);
    try msgpack.encodeArrayHeader(writer, tables.len);
    for (tables) |table| {
        try msgpack.writeMsgPackStr(writer, table.name);
    }

    try writer.writeAll(Keys.fields);
    try msgpack.encodeArrayHeader(writer, tables.len);
    for (tables) |table| {
        const tbl_md = schema.getTable(table.name) orelse return error.UnknownTable;
        try msgpack.encodeArrayHeader(writer, tbl_md.fields.len);
        for (tbl_md.fields) |field| {
            try msgpack.writeMsgPackStr(writer, field.name);
        }
    }

    try writer.writeAll(Keys.field_flags);
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

    try writer.writeAll(Keys.presence_user_fields);
    try msgpack.encodeArrayHeader(writer, schema.presence_user_fields_names.len);
    for (schema.presence_user_fields_names) |name| {
        try msgpack.writeMsgPackStr(writer, name);
    }

    try writer.writeAll(Keys.presence_shared_fields);
    try msgpack.encodeArrayHeader(writer, schema.presence_shared_fields_names.len);
    for (schema.presence_shared_fields_names) |name| {
        try msgpack.writeMsgPackStr(writer, name);
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

    try writer.writeAll(Keys.ops);
    try writer.writeByte(0x91); // fixarray(1)

    const op_map_size: u8 = if (maybe_value != null) 3 else 2;
    try writer.writeByte(0x80 | op_map_size);

    try writer.writeAll(Keys.op);
    try writer.writeAll(switch (op) {
        .remove => Values.op_remove,
        .set => Values.op_set,
    });

    try writer.writeAll(Keys.path);
    try writer.writeByte(0x92); // fixarray(2)
    try msgpack.encode(msgpack.Payload.uintToPayload(table_index), writer);
    try typed.writeMsgPack(id_val, writer);

    if (maybe_value) |v| {
        try writer.writeAll(Keys.value);
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

pub fn encodeWriteCommitted(allocator: Allocator, write_id: [16]u8) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.encodeMapHeader(writer, 2);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.write_committed);

    try writer.writeAll(Keys.write_id);
    const hex_buf = std.fmt.bytesToHex(write_id, .lower);
    try msgpack.writeMsgPackStr(writer, &hex_buf);

    return list.toOwnedSlice(allocator);
}

pub fn encodeWriteError(allocator: Allocator, write_id: [16]u8, wire_err: WireError, batch_index: ?usize) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    // 5 fixed fields + optional batchIndex
    const map_size: usize = if (batch_index != null) 6 else 5;
    try msgpack.encodeMapHeader(writer, map_size);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.write_error);

    try writer.writeAll(Keys.write_id);
    const hex_buf = std.fmt.bytesToHex(write_id, .lower);
    try msgpack.writeMsgPackStr(writer, &hex_buf);

    try writer.writeAll(Keys.code);
    try writer.writeAll(wire_err.code);

    try writer.writeAll(Keys.message);
    try writer.writeAll(wire_err.message);

    // phase is always "write" for async writer-thread outcomes.
    // Accept-phase failures are synchronous request errors, not WriteError messages.
    try writer.writeAll(Keys.phase);
    try writer.writeAll(Values.phase_write);

    if (batch_index) |idx| {
        try writer.writeAll(Keys.batch_index);
        try msgpack.encode(msgpack.Payload.uintToPayload(idx), writer);
    }

    return list.toOwnedSlice(allocator);
}

pub fn encodeServerDisconnect(allocator: Allocator, code: []const u8, message: []const u8) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.encodeMapHeader(writer, 3);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.server_disconnect);

    try writer.writeAll(Keys.code);
    try msgpack.writeMsgPackStr(writer, code);

    try writer.writeAll(Keys.message);
    try msgpack.writeMsgPackStr(writer, message);

    return list.toOwnedSlice(allocator);
}

// === Presence encoding ===

const PresenceManager = @import("../presence.zig").PresenceManager;
const PresenceRecord = @import("../presence.zig").PresenceRecord;

/// Encode a PresenceBroadcast message with multiple user updates.
pub fn encodePresenceBroadcast(
    allocator: Allocator,
    sub_id: u64,
    updates: []const PresenceManager.PendingUserUpdate,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.encodeMapHeader(writer, 3);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.presence_broadcast);

    try writer.writeAll(Keys.sub_id);
    try msgpack.encode(msgpack.Payload.uintToPayload(sub_id), writer);

    try writer.writeAll(Keys.users);
    try msgpack.encodeArrayHeader(writer, updates.len);

    for (updates) |update| {
        // Each user entry: { userId: bin16, event: "join"|"update"|"leave", data: {...}, joinedAt: int }
        // join events have data + joinedAt, update events have data only, leave events have neither
        const is_leave = update.is_leave;
        const is_join = update.is_new_user and update.patch != null;
        const map_size: usize = if (is_leave) 2 else if (is_join) 4 else 3;
        try msgpack.encodeMapHeader(writer, map_size);

        try writer.writeAll(Keys.user_id);
        const id_bytes = typed.docIdToBytes(update.user_id);
        try msgpack.writeMsgPackBin(writer, &id_bytes);

        try writer.writeAll(Keys.event);
        if (is_leave) {
            try writer.writeAll(Values.event_leave);
        } else if (is_join) {
            try writer.writeAll(Values.event_join);
        } else {
            try writer.writeAll(Values.event_update);
        }

        if (update.patch) |patch| {
            try writer.writeAll(Keys.data);
            try msgpack.encode(patch, writer);

            if (is_join) {
                try writer.writeAll(Keys.joined_at);
                try msgpack.encode(msgpack.Payload{ .int = update.joined_at }, writer);
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Encode a SharedStateBroadcast message with shared state updates.
pub fn encodeSharedStateBroadcast(
    allocator: Allocator,
    sub_id: u64,
    updates: []const PresenceManager.PendingSharedUpdate,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.encodeMapHeader(writer, 3);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.shared_state_broadcast);

    try writer.writeAll(Keys.sub_id);
    try msgpack.encode(msgpack.Payload.uintToPayload(sub_id), writer);

    try writer.writeAll(Keys.data);
    // Merge all updates into a single patch for broadcast
    if (updates.len == 1) {
        try msgpack.encode(updates[0].patch, writer);
    } else {
        // For multiple updates, encode as array of patches
        try msgpack.encodeArrayHeader(writer, updates.len);
        for (updates) |update| {
            try msgpack.encode(update.patch, writer);
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Encode a PresenceSubscribe ok response with user snapshot.
pub fn encodePresenceUserSnapshot(
    allocator: Allocator,
    msg_id: u64,
    sub_id: u64,
    users: []const @import("../presence.zig").UserEntry,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.encodeMapHeader(writer, 4);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.ok);

    try writer.writeAll(Keys.id);
    try msgpack.encode(msgpack.Payload.uintToPayload(msg_id), writer);

    try writer.writeAll(Keys.sub_id);
    try msgpack.encode(msgpack.Payload.uintToPayload(sub_id), writer);

    try writer.writeAll(Keys.users);
    try msgpack.encodeArrayHeader(writer, users.len);

    for (users) |user| {
        // Each user: { userId: bin16, data: {...}, joinedAt: int }
        try msgpack.encodeMapHeader(writer, 3);

        try writer.writeAll(Keys.user_id);
        const id_bytes = typed.docIdToBytes(user.user_id);
        try msgpack.writeMsgPackBin(writer, &id_bytes);

        try writer.writeAll(Keys.data);
        try encodePresenceRecord(writer, user.data);

        try writer.writeAll(Keys.joined_at);
        try msgpack.encode(msgpack.Payload{ .int = user.joined_at }, writer);
    }

    return list.toOwnedSlice(allocator);
}

/// Encode a PresenceSubscribeShared ok response with shared state.
pub fn encodePresenceSharedSnapshot(
    allocator: Allocator,
    msg_id: u64,
    sub_id: u64,
    shared: ?*const PresenceRecord,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.encodeMapHeader(writer, 4);

    try writer.writeAll(Keys.type);
    try writer.writeAll(Values.ok);

    try writer.writeAll(Keys.id);
    try msgpack.encode(msgpack.Payload.uintToPayload(msg_id), writer);

    try writer.writeAll(Keys.sub_id);
    try msgpack.encode(msgpack.Payload.uintToPayload(sub_id), writer);

    try writer.writeAll(Keys.shared);
    if (shared) |record| {
        try encodePresenceRecord(writer, record.*);
    } else {
        try msgpack.encode(.nil, writer);
    }

    return list.toOwnedSlice(allocator);
}

/// Encode a PresenceRecord as an integer-keyed map.
fn encodePresenceRecord(writer: anytype, record: PresenceRecord) !void {
    // Count non-null fields
    var count: usize = 0;
    for (record.values) |slot| {
        if (slot != null) count += 1;
    }

    try msgpack.encodeMapHeader(writer, count);

    for (record.values, 0..) |slot, idx| {
        if (slot) |value| {
            try msgpack.encode(msgpack.Payload.uintToPayload(idx), writer);
            try typed.writeMsgPack(value, writer);
        }
    }
}
