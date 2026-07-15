const std = @import("std");

pub const SkipError = error{ InvalidMessageFormat, MaxDepthExceeded };

const Action = union(enum) {
    invalid,
    immediate,
    fixed: usize,
    str,
    bin,
    array,
    map,
    ext,
};

/// Comptime [256]Action lookup table mapping every MsgPack marker byte to its
/// skip strategy. Replaces the per-marker if-chain and `fixedLenFor` switch.
const marker_table = blk: {
    var t: [256]Action = [_]Action{.invalid} ** 256;
    for (0x00..0x80) |i| t[i] = .immediate; // positive fixint
    for (0x80..0x90) |i| t[i] = .map; // fixmap
    for (0x90..0xa0) |i| t[i] = .array; // fixarray
    for (0xa0..0xc0) |i| t[i] = .str; // fixstr
    t[0xc0] = .immediate; // nil
    t[0xc2] = .immediate; // false
    t[0xc3] = .immediate; // true
    t[0xc4] = .bin;
    t[0xc5] = .bin;
    t[0xc6] = .bin;
    t[0xc7] = .ext;
    t[0xc8] = .ext;
    t[0xc9] = .ext;
    t[0xca] = .{ .fixed = 4 };
    t[0xcb] = .{ .fixed = 8 };
    t[0xcc] = .{ .fixed = 1 };
    t[0xcd] = .{ .fixed = 2 };
    t[0xce] = .{ .fixed = 4 };
    t[0xcf] = .{ .fixed = 8 };
    t[0xd0] = .{ .fixed = 1 };
    t[0xd1] = .{ .fixed = 2 };
    t[0xd2] = .{ .fixed = 4 };
    t[0xd3] = .{ .fixed = 8 };
    t[0xd4] = .{ .fixed = 2 };
    t[0xd5] = .{ .fixed = 3 };
    t[0xd6] = .{ .fixed = 5 };
    t[0xd7] = .{ .fixed = 9 };
    t[0xd8] = .{ .fixed = 17 };
    t[0xd9] = .str;
    t[0xda] = .str;
    t[0xdb] = .str;
    t[0xdc] = .array;
    t[0xdd] = .array;
    t[0xde] = .map;
    t[0xdf] = .map;
    for (0xe0..0x100) |i| t[i] = .immediate; // negative fixint
    break :blk t;
};

/// Reads a big-endian length of `n_bytes` bytes from `bytes[*pos..]`, advancing
/// `pos`. Returns the decoded length. Bounds-checks the header read only; the
/// caller is responsible for bounds-checking the subsequent payload.
fn readLen(bytes: []const u8, pos: *usize, n_bytes: u3) SkipError!usize {
    if (pos.* + n_bytes > bytes.len) return error.InvalidMessageFormat;
    const len: usize = switch (n_bytes) {
        1 => bytes[pos.*],
        2 => std.mem.readInt(u16, bytes[pos.*..][0..2], .big),
        4 => std.mem.readInt(u32, bytes[pos.*..][0..4], .big),
        else => unreachable,
    };
    pos.* += n_bytes;
    return len;
}

/// Advances `pos` past `len` payload bytes, bounds-checking.
fn skipPayload(bytes: []const u8, pos: *usize, len: usize) SkipError!void {
    if (len > bytes.len - pos.*) return error.InvalidMessageFormat;
    pos.* += len;
}

// Skips a str given its already-read marker `m` (fixstr 0xa0..0xbf, str8/16/32).
inline fn skipStr(bytes: []const u8, pos: *usize, m: u8) SkipError!void {
    if (m >= 0xa0 and m <= 0xbf) return skipPayload(bytes, pos, m & 0x1f);
    const len: usize = switch (m) {
        0xd9 => try readLen(bytes, pos, 1),
        0xda => try readLen(bytes, pos, 2),
        0xdb => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    try skipPayload(bytes, pos, len);
}

// Skips a bin given its already-read marker `m` (bin8/16/32).
inline fn skipBin(bytes: []const u8, pos: *usize, m: u8) SkipError!void {
    const len: usize = switch (m) {
        0xc4 => try readLen(bytes, pos, 1),
        0xc5 => try readLen(bytes, pos, 2),
        0xc6 => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    try skipPayload(bytes, pos, len);
}

// Skips an array given its already-read marker `m` (fixarray, array16/32).
inline fn skipArray(bytes: []const u8, pos: *usize, depth: u32, m: u8) SkipError!void {
    const count: usize = switch (m) {
        0x90...0x9f => @intCast(m & 0x0f),
        0xdc => try readLen(bytes, pos, 2),
        0xdd => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    if (count > bytes.len - pos.*) return error.InvalidMessageFormat;
    for (0..count) |_| try skipValueDepth(bytes, pos, depth + 1);
}

// Skips a map given its already-read marker `m` (fixmap, map16/32).
inline fn skipMap(bytes: []const u8, pos: *usize, depth: u32, m: u8) SkipError!void {
    const count: usize = switch (m) {
        0x80...0x8f => @intCast(m & 0x0f),
        0xde => try readLen(bytes, pos, 2),
        0xdf => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    if (count > (bytes.len - pos.*) / 2) return error.InvalidMessageFormat;
    for (0..count * 2) |_| try skipValueDepth(bytes, pos, depth + 1);
}

// Skips an ext given its already-read marker `m` (ext8/16/32).
inline fn skipExt(bytes: []const u8, pos: *usize, m: u8) SkipError!void {
    const len: usize = switch (m) {
        0xc7 => try readLen(bytes, pos, 1),
        0xc8 => try readLen(bytes, pos, 2),
        0xc9 => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    if (len >= bytes.len - pos.*) return error.InvalidMessageFormat;
    try skipPayload(bytes, pos, len + 1);
}

/// Skips a MsgPack value at `bytes[*pos..]`, advancing `pos`. `depth` guards
/// against stack overflow. The marker is read once and passed to the inline
/// helpers, eliminating redundant re-reads.
pub fn skipValueDepth(bytes: []const u8, pos: *usize, depth: u32) SkipError!void {
    if (depth > 32) return error.MaxDepthExceeded;
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;

    switch (marker_table[m]) {
        .invalid => return error.InvalidMessageFormat,
        .immediate => {},
        .fixed => |len| try skipPayload(bytes, pos, len),
        .str => try skipStr(bytes, pos, m),
        .bin => try skipBin(bytes, pos, m),
        .array => try skipArray(bytes, pos, depth, m),
        .map => try skipMap(bytes, pos, depth, m),
        .ext => try skipExt(bytes, pos, m),
    }
}

/// Convenience wrapper starting at depth 0.
pub fn skipValue(bytes: []const u8, pos: *usize) SkipError!void {
    try skipValueDepth(bytes, pos, 0);
}
