const std = @import("std");

pub const SkipError = error{ InvalidMessageFormat, MaxDepthExceeded };

/// Fixed-length MsgPack marker bytes: marker → payload byte count (not counting
/// the marker itself). Used for ints, floats, fixext, and fixstr/fixbin-style
/// cases whose length is encoded in the marker.
const FixedLen = struct { marker: u8, len: usize };

const fixed_len_table = [_]FixedLen{
    // unsigned ints
    .{ .marker = 0xcc, .len = 1 },
    .{ .marker = 0xcd, .len = 2 },
    .{ .marker = 0xce, .len = 4 },
    .{ .marker = 0xcf, .len = 8 },
    // signed ints
    .{ .marker = 0xd0, .len = 1 },
    .{ .marker = 0xd1, .len = 2 },
    .{ .marker = 0xd2, .len = 4 },
    .{ .marker = 0xd3, .len = 8 },
    // floats
    .{ .marker = 0xca, .len = 4 },
    .{ .marker = 0xcb, .len = 8 },
    // fixext
    .{ .marker = 0xd4, .len = 2 },
    .{ .marker = 0xd5, .len = 3 },
    .{ .marker = 0xd6, .len = 5 },
    .{ .marker = 0xd7, .len = 9 },
    .{ .marker = 0xd8, .len = 17 },
};

fn fixedLenFor(marker: u8) ?usize {
    for (fixed_len_table) |e| if (e.marker == marker) return e.len;
    return null;
}

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

/// Skips a MsgPack str value (already past the marker is not supported — this
/// reads the marker). Handles fixstr (0xa0..0xbf), str8, str16, str32.
pub fn skipStr(bytes: []const u8, pos: *usize) SkipError!void {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;
    if (m >= 0xa0 and m <= 0xbf) {
        try skipPayload(bytes, pos, m & 0x1f);
        return;
    }
    const len: usize = switch (m) {
        0xd9 => try readLen(bytes, pos, 1),
        0xda => try readLen(bytes, pos, 2),
        0xdb => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    try skipPayload(bytes, pos, len);
}

/// Skips a MsgPack bin value. Handles bin8, bin16, bin32.
pub fn skipBin(bytes: []const u8, pos: *usize) SkipError!void {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;
    const len: usize = switch (m) {
        0xc4 => try readLen(bytes, pos, 1),
        0xc5 => try readLen(bytes, pos, 2),
        0xc6 => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    try skipPayload(bytes, pos, len);
}

/// Skips a MsgPack array value (header + `count` elements). Handles fixarray,
/// array16, array32.
pub fn skipArray(bytes: []const u8, pos: *usize, depth: u32) SkipError!void {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;
    const count: usize = switch (m) {
        0x90...0x9f => @intCast(m & 0x0f),
        0xdc => try readLen(bytes, pos, 2),
        0xdd => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    if (count > bytes.len - pos.*) return error.InvalidMessageFormat;
    for (0..count) |_| try skipValueDepth(bytes, pos, depth + 1);
}

/// Skips a MsgPack map value (header + `count * 2` elements). Handles fixmap,
/// map16, map32.
pub fn skipMap(bytes: []const u8, pos: *usize, depth: u32) SkipError!void {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;
    const count: usize = switch (m) {
        0x80...0x8f => @intCast(m & 0x0f),
        0xde => try readLen(bytes, pos, 2),
        0xdf => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    if (count > (bytes.len - pos.*) / 2) return error.InvalidMessageFormat;
    for (0..count * 2) |_| try skipValueDepth(bytes, pos, depth + 1);
}

/// Skips a MsgPack ext value (type byte + payload). Handles ext8, ext16, ext32
/// (fixext is handled by the fixed-length table in `skipValueDepth`).
pub fn skipExt(bytes: []const u8, pos: *usize) SkipError!void {
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;
    const len: usize = switch (m) {
        0xc7 => try readLen(bytes, pos, 1),
        0xc8 => try readLen(bytes, pos, 2),
        0xc9 => try readLen(bytes, pos, 4),
        else => return error.InvalidMessageFormat,
    };
    if (len >= bytes.len - pos.*) return error.InvalidMessageFormat;
    try skipPayload(bytes, pos, len + 1);
}

/// Skips an arbitrary MsgPack value at `bytes[*pos..]`, advancing `pos` past
/// it. Bounds-checks at every step. `depth` guards against stack overflow on
/// pathologically nested structures.
pub fn skipValueDepth(bytes: []const u8, pos: *usize, depth: u32) SkipError!void {
    if (depth > 32) return error.MaxDepthExceeded;
    if (pos.* >= bytes.len) return error.InvalidMessageFormat;
    const m = bytes[pos.*];
    pos.* += 1;

    // nil, bool, positive/negative fixint — no payload.
    if (m == 0xc0 or m == 0xc2 or m == 0xc3 or (m <= 0x7f) or (m >= 0xe0)) {
        return;
    }

    // Fixed-length int/float/fixext cases.
    if (fixedLenFor(m)) |len| {
        try skipPayload(bytes, pos, len);
        return;
    }

    // fixstr
    if (m >= 0xa0 and m <= 0xbf) {
        try skipPayload(bytes, pos, @intCast(m & 0x1f));
        return;
    }

    // str8/16/32
    if (m == 0xd9 or m == 0xda or m == 0xdb) {
        pos.* -= 1;
        try skipStr(bytes, pos);
        return;
    }

    // bin8/16/32
    if (m == 0xc4 or m == 0xc5 or m == 0xc6) {
        pos.* -= 1;
        try skipBin(bytes, pos);
        return;
    }

    // array
    if ((m >= 0x90 and m <= 0x9f) or m == 0xdc or m == 0xdd) {
        pos.* -= 1;
        try skipArray(bytes, pos, depth);
        return;
    }

    // map
    if ((m >= 0x80 and m <= 0x8f) or m == 0xde or m == 0xdf) {
        pos.* -= 1;
        try skipMap(bytes, pos, depth);
        return;
    }

    // ext8/16/32
    if (m == 0xc7 or m == 0xc8 or m == 0xc9) {
        pos.* -= 1;
        try skipExt(bytes, pos);
        return;
    }

    return error.InvalidMessageFormat;
}

/// Convenience wrapper starting at depth 0.
pub fn skipValue(bytes: []const u8, pos: *usize) SkipError!void {
    try skipValueDepth(bytes, pos, 0);
}
