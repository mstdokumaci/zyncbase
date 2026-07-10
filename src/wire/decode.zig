const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const Payload = msgpack.Payload;
const msgpack_skip = @import("msgpack_skip.zig");

pub const Envelope = struct {
    type: []const u8,
    id: u64,
};

pub const StoreSetNamespaceRequest = struct {
    namespace: []const u8,
};

pub const StoreUnsubscribeRequest = struct {
    subId: u64,
};

pub const StoreLoadMoreRequest = struct {
    subId: u64,
    nextCursor: []const u8,
};

// === Low-Level MessagePack Parser Primitives ===

fn readMapHeader(bytes: []const u8, pos: *usize) !usize {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;

    if (m >= 0x80 and m <= 0x8f) return @intCast(m & 0x0f);
    if (m == 0xde) {
        if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
        const len = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
        pos.* += 2;
        return len;
    }
    if (m == 0xdf) {
        if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
        const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
        pos.* += 4;
        return len;
    }
    return error.InvalidMessageFormat;
}

fn readStr(bytes: []const u8, pos: *usize) ![]const u8 {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;

    if (m >= 0xa0 and m <= 0xbf) {
        const len: usize = @intCast(m & 0x1f);
        if (pos.* + len > bytes.len) return error.InvalidMessageFormat;
        const s = bytes[pos.* .. pos.* + len];
        pos.* += len;
        return s;
    }
    if (m == 0xd9) {
        if (pos.* + 1 > bytes.len) return error.InvalidMessageFormat;
        const len: usize = bytes[pos.*];
        pos.* += 1;
        if (pos.* + len > bytes.len) return error.InvalidMessageFormat;
        const s = bytes[pos.* .. pos.* + len];
        pos.* += len;
        return s;
    }
    if (m == 0xda) {
        if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
        const len = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
        pos.* += 2;
        if (pos.* + len > bytes.len) return error.InvalidMessageFormat;
        const s = bytes[pos.* .. pos.* + len];
        pos.* += len;
        return s;
    }
    if (m == 0xdb) {
        if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
        const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
        pos.* += 4;
        if (pos.* + len > bytes.len) return error.InvalidMessageFormat;
        const s = bytes[pos.* .. pos.* + len];
        pos.* += len;
        return s;
    }
    return error.InvalidMessageFormat;
}

fn readU64(bytes: []const u8, pos: *usize) !u64 {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;

    if (m <= 0x7f) return m;
    if (m == 0xcc) {
        if (pos.* + 1 > bytes.len) return error.InvalidMessageFormat;
        const v = bytes[pos.*];
        pos.* += 1;
        return v;
    }
    if (m == 0xcd) {
        if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
        const v = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
        pos.* += 2;
        return v;
    }
    if (m == 0xce) {
        if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
        const v = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
        pos.* += 4;
        return v;
    }
    if (m == 0xcf) {
        if (pos.* + 8 > bytes.len) return error.InvalidMessageFormat;
        const v = std.mem.readInt(u64, bytes[pos.*..][0..8], .big);
        pos.* += 8;
        return v;
    }
    return error.InvalidMessageFormat;
}

inline fn freePayload(allocator: std.mem.Allocator, slot: anytype, found: bool) void {
    const T = @TypeOf(slot.*);
    if (@typeInfo(T) == .optional) {
        if (slot.*) |payload| payload.free(allocator);
    } else if (found) {
        slot.*.free(allocator);
    }
}

inline fn assignField(
    f: Field,
    slot: anytype,
    bytes: []const u8,
    pos: *usize,
    allocator: std.mem.Allocator,
    found: *bool,
) !void {
    switch (f.kind) {
        .str => {
            slot.* = try readStr(bytes, pos);
        },
        .u64 => {
            slot.* = try readU64(bytes, pos);
        },
        .payload => {
            const new_payload = try readSubtree(bytes, pos, allocator);
            freePayload(allocator, slot, found.*);
            slot.* = new_payload;
        },
    }
    found.* = true;
}

const FieldKind = enum { str, u64, payload };

const Field = struct {
    key: []const u8, // wire-format name, e.g. "writeId"
    kind: FieldKind,
    field: []const u8, // result-struct field name, e.g. "write_id"
    required: bool,
};

fn validateTable(comptime T: type, comptime table: []const Field) void {
    for (@typeInfo(T).@"struct".fields) |f| {
        const is_optional = @typeInfo(f.type) == .optional;
        var found_in_table = false;
        for (table) |tf| {
            if (std.mem.eql(u8, tf.field, f.name)) {
                found_in_table = true;
                if (!is_optional and !tf.required) {
                    @compileError("Field '" ++ f.name ++ "' of " ++ @typeName(T) ++ " is non-optional but marked as not required in the table");
                }
                const field_type = f.type;
                const base_type = if (is_optional) @typeInfo(field_type).optional.child else field_type;
                switch (tf.kind) {
                    .str => {
                        if (base_type != []const u8) {
                            @compileError("Field '" ++ f.name ++ "' of " ++ @typeName(T) ++ " is expected to be []const u8 for kind .str, but got " ++ @typeName(field_type));
                        }
                    },
                    .u64 => {
                        if (base_type != u64) {
                            @compileError("Field '" ++ f.name ++ "' of " ++ @typeName(T) ++ " is expected to be u64 for kind .u64, but got " ++ @typeName(field_type));
                        }
                    },
                    .payload => {
                        if (base_type != Payload) {
                            @compileError("Field '" ++ f.name ++ "' of " ++ @typeName(T) ++ " is expected to be Payload for kind .payload, but got " ++ @typeName(field_type));
                        }
                    },
                }
                break;
            }
        }
        if (!is_optional and !found_in_table) {
            @compileError("Field '" ++ f.name ++ "' of " ++ @typeName(T) ++ " is non-optional but missing from the table");
        }
    }

    for (table) |tf| {
        var found_in_struct = false;
        for (@typeInfo(T).@"struct".fields) |f| {
            if (std.mem.eql(u8, tf.field, f.name)) {
                found_in_struct = true;
                break;
            }
        }
        if (!found_in_struct) {
            @compileError("Field '" ++ tf.field ++ "' in table is not a field of " ++ @typeName(T));
        }
    }

    for (table, 0..) |f1, i| {
        for (table[i + 1 ..]) |f2| {
            if (std.mem.eql(u8, f1.key, f2.key)) {
                @compileError("Duplicate key '" ++ f1.key ++ "' in table");
            }
        }
    }
}

fn extractMap(
    comptime T: type,
    comptime table: []const Field,
    bytes: []const u8,
    allocator: std.mem.Allocator, // only referenced when table has a .payload field
) !T {
    comptime validateTable(T, table);
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    // SAFETY: result is fully initialized by the loop over the fields of T before it is returned.
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (@typeInfo(f.type) == .optional) @field(result, f.name) = null;
    }
    var found = [_]bool{false} ** table.len;

    // If a later read errors, release any Payload slots already populated.
    errdefer {
        inline for (table, 0..) |f, i| {
            if (f.kind == .payload) {
                const slot = &@field(result, f.field);
                freePayload(allocator, slot, found[i]);
            }
        }
    }

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        inline for (table, 0..) |f, i| {
            if (std.mem.eql(u8, key, f.key)) {
                const slot = &@field(result, f.field);
                try assignField(f, slot, bytes, &pos, allocator, &found[i]);
                break;
            }
        } else {
            try msgpack_skip.skipValue(bytes, &pos);
        }
    }

    inline for (table, 0..) |f, i| {
        if (f.required and !found[i]) return error.MissingRequiredFields;
    }
    return result;
}

// === Fast Envelope Extractor ===

const envelope_table = [_]Field{
    .{ .key = "type", .kind = .str, .field = "type", .required = true },
    .{ .key = "id", .kind = .u64, .field = "id", .required = true },
};

pub fn extractEnvelopeFast(bytes: []const u8) !Envelope {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(Envelope, &envelope_table, bytes, undefined);
}

// === Type-Specific Fast Decoders ===

const store_set_namespace_table = [_]Field{
    .{ .key = "namespace", .kind = .str, .field = "namespace", .required = true },
};

pub fn extractStoreSetNamespaceFast(bytes: []const u8) !StoreSetNamespaceRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(StoreSetNamespaceRequest, &store_set_namespace_table, bytes, undefined);
}

const store_unsubscribe_table = [_]Field{
    .{ .key = "subId", .kind = .u64, .field = "subId", .required = true },
};

pub fn extractStoreUnsubscribeFast(bytes: []const u8) !StoreUnsubscribeRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(StoreUnsubscribeRequest, &store_unsubscribe_table, bytes, undefined);
}

const store_load_more_table = [_]Field{
    .{ .key = "subId", .kind = .u64, .field = "subId", .required = true },
    .{ .key = "nextCursor", .kind = .str, .field = "nextCursor", .required = true },
};

pub fn extractStoreLoadMoreFast(bytes: []const u8) !StoreLoadMoreRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(StoreLoadMoreRequest, &store_load_more_table, bytes, undefined);
}

// === Write Acknowledgment Decoding ===

pub const WriteId = [16]u8;

pub fn decodeWriteAck(confirm_str: ?[]const u8, write_id_str: ?[]const u8) !?WriteId {
    const confirm_val = confirm_str orelse {
        // No confirm field — a writeId without confirm is a client bug.
        if (write_id_str != null) return error.InvalidWriteAck;
        return null;
    };
    if (!std.mem.eql(u8, confirm_val, "committed")) {
        // "accepted" (or any other value) with a writeId is a client bug: the
        // writeId would never be resolved, causing a silent hang on the client.
        // Reject early so the client gets an immediate error instead.
        if (write_id_str != null) return error.InvalidWriteAck;
        return null;
    }
    // confirm == "committed": writeId is required and must be valid.
    const wid_str = write_id_str orelse return error.InvalidWriteAck;
    if (wid_str.len != 32) return error.InvalidWriteAck;
    // SAFETY: hexToBytes writes all 16 bytes on success; on error we return immediately.
    var write_id: WriteId = undefined;
    _ = std.fmt.hexToBytes(&write_id, wid_str) catch return error.InvalidWriteAck;
    return write_id;
}

// === Subtree Payload Extractors (for Group B handlers that need Payload) ===

pub const StorePathPayloads = struct {
    path: Payload,
    value: ?Payload,
    write_id: ?WriteId = null,
};

const StorePathRawFields = struct {
    path: Payload,
    value: ?Payload,
    confirm: ?[]const u8 = null,
    write_id: ?[]const u8 = null,
};

const store_path_table = [_]Field{
    .{ .key = "path", .kind = .payload, .field = "path", .required = true },
    .{ .key = "value", .kind = .payload, .field = "value", .required = false },
    .{ .key = "confirm", .kind = .str, .field = "confirm", .required = false },
    .{ .key = "writeId", .kind = .str, .field = "write_id", .required = false },
};

pub fn extractStorePathPayloads(bytes: []const u8, allocator: std.mem.Allocator) !StorePathPayloads {
    const raw = try extractMap(StorePathRawFields, &store_path_table, bytes, allocator);
    errdefer {
        raw.path.free(allocator);
        if (raw.value) |v| v.free(allocator);
    }
    return .{
        .path = raw.path,
        .value = raw.value,
        .write_id = try decodeWriteAck(raw.confirm, raw.write_id),
    };
}

pub const StoreBatchPayloads = struct {
    ops: Payload,
    write_id: ?WriteId = null,
};

const StoreBatchRawFields = struct {
    ops: Payload,
    confirm: ?[]const u8 = null,
    write_id: ?[]const u8 = null,
};

const store_batch_table = [_]Field{
    .{ .key = "ops", .kind = .payload, .field = "ops", .required = true },
    .{ .key = "confirm", .kind = .str, .field = "confirm", .required = false },
    .{ .key = "writeId", .kind = .str, .field = "write_id", .required = false },
};

pub fn extractStoreBatchPayloads(
    bytes: []const u8,
    allocator: std.mem.Allocator,
) !StoreBatchPayloads {
    const raw = try extractMap(StoreBatchRawFields, &store_batch_table, bytes, allocator);
    errdefer raw.ops.free(allocator);
    return .{
        .ops = raw.ops,
        .write_id = try decodeWriteAck(raw.confirm, raw.write_id),
    };
}

const AuthRefreshResult = struct { token: []const u8 };
const auth_refresh_table = [_]Field{
    .{ .key = "token", .kind = .str, .field = "token", .required = true },
};

pub fn extractAuthRefreshFast(bytes: []const u8) ![]const u8 {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return (try extractMap(AuthRefreshResult, &auth_refresh_table, bytes, undefined)).token;
}

fn readSubtree(bytes: []const u8, pos: *usize, allocator: std.mem.Allocator) !Payload {
    const start = pos.*;
    try msgpack_skip.skipValue(bytes, pos);
    const slice = bytes[start..pos.*];
    var reader: std.Io.Reader = .fixed(slice);
    return msgpack.decode(allocator, &reader);
}

pub const PresenceSetNamespaceRequest = struct {
    namespace: []const u8,
};

const presence_set_namespace_table = [_]Field{
    .{ .key = "namespace", .kind = .str, .field = "namespace", .required = true },
};

pub fn extractPresenceSetNamespaceFast(bytes: []const u8) !PresenceSetNamespaceRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(PresenceSetNamespaceRequest, &presence_set_namespace_table, bytes, undefined);
}

pub const PresenceSetRequest = struct {
    data: Payload,
};

const presence_set_table = [_]Field{
    .{ .key = "data", .kind = .payload, .field = "data", .required = true },
};

pub fn extractPresenceSetFast(bytes: []const u8, allocator: std.mem.Allocator) !PresenceSetRequest {
    return extractMap(PresenceSetRequest, &presence_set_table, bytes, allocator);
}

pub const PresenceUnsubscribeRequest = struct {
    subId: u64,
};

const presence_unsubscribe_table = [_]Field{
    .{ .key = "subId", .kind = .u64, .field = "subId", .required = true },
};

pub fn extractPresenceUnsubscribeFast(bytes: []const u8) !PresenceUnsubscribeRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(PresenceUnsubscribeRequest, &presence_unsubscribe_table, bytes, undefined);
}

pub const PresenceSetSharedRequest = struct {
    data: Payload,
};

const presence_set_shared_table = [_]Field{
    .{ .key = "data", .kind = .payload, .field = "data", .required = true },
};

pub fn extractPresenceSetSharedFast(bytes: []const u8, allocator: std.mem.Allocator) !PresenceSetSharedRequest {
    return extractMap(PresenceSetSharedRequest, &presence_set_shared_table, bytes, allocator);
}

const empty_table = [_]Field{};

pub const PresenceSubscribeRequest = struct {};

pub fn extractPresenceSubscribeFast(bytes: []const u8) !PresenceSubscribeRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(PresenceSubscribeRequest, &empty_table, bytes, undefined);
}

pub const PresenceSubscribeSharedRequest = struct {};

pub fn extractPresenceSubscribeSharedFast(bytes: []const u8) !PresenceSubscribeSharedRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(PresenceSubscribeSharedRequest, &empty_table, bytes, undefined);
}

pub const PresenceUnsubscribeSharedRequest = struct {
    subId: u64,
};

const presence_unsubscribe_shared_table = [_]Field{
    .{ .key = "subId", .kind = .u64, .field = "subId", .required = true },
};

pub fn extractPresenceUnsubscribeSharedFast(bytes: []const u8) !PresenceUnsubscribeSharedRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(PresenceUnsubscribeSharedRequest, &presence_unsubscribe_shared_table, bytes, undefined);
}

pub const PresenceRemoveRequest = struct {};

pub fn extractPresenceRemoveFast(bytes: []const u8) !PresenceRemoveRequest {
    // SAFETY: allocator unused — table has no .payload fields; parameter is comptime-dead.
    return extractMap(PresenceRemoveRequest, &empty_table, bytes, undefined);
}
