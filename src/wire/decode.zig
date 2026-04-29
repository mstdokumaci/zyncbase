const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const Payload = msgpack.Payload;
const comptimeKeyPayload = @import("comptime.zig").comptimeKeyPayload;

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

const Key = struct {
    pub const @"type" = comptimeKeyPayload("type");
    pub const id = comptimeKeyPayload("id");
    pub const namespace = comptimeKeyPayload("namespace");
    pub const sub_id = comptimeKeyPayload("subId");
    pub const next_cursor = comptimeKeyPayload("nextCursor");
    pub const path = comptimeKeyPayload("path");
    pub const value = comptimeKeyPayload("value");
    pub const table_index = comptimeKeyPayload("table_index");
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

fn skipValue(bytes: []const u8, pos: *usize) !void {
    try skipValueDepth(bytes, pos, 0);
}

fn skipValueDepth(bytes: []const u8, pos: *usize, depth: u32) !void {
    if (depth > 32) return error.MaxDepthExceeded;
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;

    switch (m) {
        0xc0, 0xc2, 0xc3 => {},
        0x00...0x7f => {},
        0xe0...0xff => {},
        0xcc => pos.* += 1,
        0xcd => pos.* += 2,
        0xce => pos.* += 4,
        0xcf => pos.* += 8,
        0xd0 => pos.* += 1,
        0xd1 => pos.* += 2,
        0xd2 => pos.* += 4,
        0xd3 => pos.* += 8,
        0xca => pos.* += 4,
        0xcb => pos.* += 8,
        0xa0...0xbf => pos.* += @intCast(m & 0x1f),
        0xd9 => {
            if (pos.* + 1 > bytes.len) return error.InvalidMessageFormat;
            const len: usize = bytes[pos.*];
            pos.* += 1;
            pos.* += len;
        },
        0xda => {
            if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
            pos.* += 2;
            pos.* += @intCast(len);
        },
        0xdb => {
            if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
            pos.* += 4;
            pos.* += len;
        },
        0xc4 => {
            if (pos.* + 1 > bytes.len) return error.InvalidMessageFormat;
            const len: usize = bytes[pos.*];
            pos.* += 1;
            pos.* += len;
        },
        0xc5 => {
            if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
            pos.* += 2;
            pos.* += @intCast(len);
        },
        0xc6 => {
            if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
            pos.* += 4;
            pos.* += len;
        },
        0x90...0x9f => {
            const len: usize = @intCast(m & 0x0f);
            for (0..len) |_| try skipValueDepth(bytes, pos, depth + 1);
        },
        0xdc => {
            if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
            pos.* += 2;
            for (0..len) |_| try skipValueDepth(bytes, pos, depth + 1);
        },
        0xdd => {
            if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
            pos.* += 4;
            for (0..len) |_| try skipValueDepth(bytes, pos, depth + 1);
        },
        0x80...0x8f => {
            const len: usize = @intCast(m & 0x0f);
            for (0..len * 2) |_| try skipValueDepth(bytes, pos, depth + 1);
        },
        0xde => {
            if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
            pos.* += 2;
            for (0..len * 2) |_| try skipValueDepth(bytes, pos, depth + 1);
        },
        0xdf => {
            if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
            pos.* += 4;
            for (0..len * 2) |_| try skipValueDepth(bytes, pos, depth + 1);
        },
        0xd4 => pos.* += 2,
        0xd5 => pos.* += 3,
        0xd6 => pos.* += 5,
        0xd7 => pos.* += 9,
        0xd8 => pos.* += 17,
        0xc7 => {
            if (pos.* + 1 > bytes.len) return error.InvalidMessageFormat;
            const len: usize = bytes[pos.*];
            pos.* += 1;
            pos.* += len + 1;
        },
        0xc8 => {
            if (pos.* + 2 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u16, bytes[pos.*..][0..2], .big);
            pos.* += 2;
            pos.* += len + 1;
        },
        0xc9 => {
            if (pos.* + 4 > bytes.len) return error.InvalidMessageFormat;
            const len = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
            pos.* += 4;
            pos.* += len + 1;
        },
        else => return error.InvalidMessageFormat,
    }

    if (pos.* > bytes.len) return error.InvalidMessageFormat;
}

// === Fast Envelope Extractor ===

pub fn extractEnvelopeFast(bytes: []const u8) !Envelope {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    // SAFETY: all fields of result are set before use via the found_type/found_id guards below
    var result: Envelope = undefined;
    var found_type: bool = false;
    var found_id: bool = false;

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        if (std.mem.eql(u8, key, Key.type)) {
            result.type = try readStr(bytes, &pos);
            found_type = true;
        } else if (std.mem.eql(u8, key, Key.id)) {
            result.id = try readU64(bytes, &pos);
            found_id = true;
        } else {
            try skipValue(bytes, &pos);
        }
    }

    if (!found_type or !found_id) return error.MissingRequiredFields;
    return result;
}

// === Type-Specific Fast Decoders ===

pub fn extractStoreSetNamespaceFast(bytes: []const u8) !StoreSetNamespaceRequest {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    var namespace: ?[]const u8 = null;

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        if (std.mem.eql(u8, key, Key.namespace)) {
            namespace = try readStr(bytes, &pos);
        } else {
            try skipValue(bytes, &pos);
        }
    }

    return .{ .namespace = namespace orelse return error.MissingRequiredFields };
}

pub fn extractStoreUnsubscribeFast(bytes: []const u8) !StoreUnsubscribeRequest {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    var sub_id: ?u64 = null;

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        if (std.mem.eql(u8, key, Key.sub_id)) {
            sub_id = try readU64(bytes, &pos);
        } else {
            try skipValue(bytes, &pos);
        }
    }

    return .{ .subId = sub_id orelse return error.MissingRequiredFields };
}

pub fn extractStoreLoadMoreFast(bytes: []const u8) !StoreLoadMoreRequest {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    var sub_id: ?u64 = null;
    var next_cursor: ?[]const u8 = null;

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        if (std.mem.eql(u8, key, Key.sub_id)) {
            sub_id = try readU64(bytes, &pos);
        } else if (std.mem.eql(u8, key, Key.next_cursor)) {
            next_cursor = try readStr(bytes, &pos);
        } else {
            try skipValue(bytes, &pos);
        }
    }

    return .{
        .subId = sub_id orelse return error.MissingRequiredFields,
        .nextCursor = next_cursor orelse return error.MissingRequiredFields,
    };
}

pub fn extractStoreTableIndexFast(bytes: []const u8) !u64 {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    var table_index: ?u64 = null;

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        if (std.mem.eql(u8, key, Key.table_index)) {
            table_index = try readU64(bytes, &pos);
        } else {
            try skipValue(bytes, &pos);
        }
    }

    return table_index orelse return error.MissingRequiredFields;
}

// === Subtree Payload Extractors (for Group B handlers that need Payload) ===

pub const StorePathPayloads = struct {
    path: Payload,
    value: ?Payload,
};

pub fn extractStorePathPayloads(bytes: []const u8, allocator: std.mem.Allocator) !StorePathPayloads {
    var pos: usize = 0;
    const map_len = try readMapHeader(bytes, &pos);

    var path: ?Payload = null;
    var value: ?Payload = null;

    for (0..map_len) |_| {
        const key = try readStr(bytes, &pos);
        if (std.mem.eql(u8, key, Key.path)) {
            path = try readSubtree(bytes, &pos, allocator);
        } else if (std.mem.eql(u8, key, Key.value)) {
            value = try readSubtree(bytes, &pos, allocator);
        } else {
            try skipValue(bytes, &pos);
        }
    }

    return .{ .path = path orelse return error.MissingRequiredFields, .value = value };
}

fn readSubtree(bytes: []const u8, pos: *usize, allocator: std.mem.Allocator) !Payload {
    const start = pos.*;
    try skipValue(bytes, pos);
    const slice = bytes[start..pos.*];
    var reader: std.Io.Reader = .fixed(slice);
    return msgpack.decode(allocator, &reader);
}

pub fn getMapPayload(map: Payload, key: []const u8) ?Payload {
    if (map != .map) return null;
    var it = map.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), key)) {
            return entry.value_ptr.*;
        }
    }
    return null;
}
