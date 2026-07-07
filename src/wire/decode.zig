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

const FieldKind = enum { str, u64, payload };

const Field = struct {
    key: []const u8, // wire-format name, e.g. "writeId"
    kind: FieldKind,
    field: []const u8, // result-struct field name, e.g. "write_id"
    required: bool,
};

/// Type of a named field of T (avoids depending on @FieldType availability).
fn fieldOf(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError(@typeName(T) ++ " has no field '" ++ name ++ "'");
}

fn extractMap(
    comptime T: type,
    comptime table: []const Field,
    bytes: []const u8,
    allocator: std.mem.Allocator, // only referenced when table has a .payload field
) !T {
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
                const ft = fieldOf(T, f.field);
                if (@typeInfo(ft) == .optional) {
                    if (slot.*) |p| p.free(allocator);
                } else if (found[i]) {
                    slot.free(allocator);
                }
            }
        }
    }

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        var handled = false;
        inline for (table, 0..) |f, i| {
            if (!handled and std.mem.eql(u8, key, f.key)) {
                handled = true;
                const slot = &@field(result, f.field);
                switch (f.kind) {
                    .str => {
                        slot.* = try readStr(bytes, &pos);
                        found[i] = true;
                    },
                    .u64 => {
                        slot.* = try readU64(bytes, &pos);
                        found[i] = true;
                    },
                    .payload => {
                        // Free previous value before overwriting (duplicate keys: last wins).
                        const ft = fieldOf(T, f.field);
                        if (@typeInfo(ft) == .optional) {
                            if (slot.*) |old| old.free(allocator);
                        } else if (found[i]) {
                            slot.free(allocator);
                        }
                        slot.* = try readSubtree(bytes, &pos, allocator);
                        found[i] = true;
                    },
                }
            }
        }
        if (!handled) try msgpack_skip.skipValue(bytes, &pos);
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

// === Subtree Payload Extractors (for Group B handlers that need Payload) ===

pub const StorePathPayloads = struct {
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
    return extractMap(StorePathPayloads, &store_path_table, bytes, allocator);
}

pub const StoreBatchPayloads = struct {
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
    return extractMap(StoreBatchPayloads, &store_batch_table, bytes, allocator);
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

pub const PresenceSubscribeRequest = struct {};

pub fn extractPresenceSubscribeFast(bytes: []const u8) !PresenceSubscribeRequest {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        _ = key;
        try msgpack_skip.skipValue(bytes, &pos);
    }

    return .{};
}

pub const PresenceSubscribeSharedRequest = struct {};

pub fn extractPresenceSubscribeSharedFast(bytes: []const u8) !PresenceSubscribeSharedRequest {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        _ = key;
        try msgpack_skip.skipValue(bytes, &pos);
    }

    return .{};
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
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        _ = key;
        try msgpack_skip.skipValue(bytes, &pos);
    }

    return .{};
}
