const std = @import("std");

const msgpack = @import("msgpack");

const msgpack_utils = @import("msgpack_utils.zig");

const testing = std.testing;

// ============================================================
// writeMsgPackStr tests
// ============================================================

test "msgpack_utils: writeMsgPackStr fixstr (≤31 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), "type");
    // fixstr(4) = 0xa4 | "type" = 5 bytes
    try testing.expectEqual(@as(usize, 5), buf.items.len);
    try testing.expectEqual(@as(u8, 0xa4), buf.items[0]);
    try testing.expectEqualSlices(u8, "type", buf.items[1..]);
}

test "msgpack_utils: writeMsgPackStr str8 (≤255 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    const long_str = "a" ** 100;

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), long_str[0..]);
    // str8(100) = 0xd9 | 0x64 | "a"*100 = 102 bytes
    try testing.expectEqual(@as(usize, 102), buf.items.len);
    try testing.expectEqual(@as(u8, 0xd9), buf.items[0]);
    try testing.expectEqual(@as(u8, 100), buf.items[1]);
}

test "msgpack_utils: writeMsgPackStr empty string" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), "");
    // fixstr(0) = 0xa0 = 1 byte
    try testing.expectEqual(@as(usize, 1), buf.items.len);
    try testing.expectEqual(@as(u8, 0xa0), buf.items[0]);
}

test "msgpack_utils: writeMsgPackStr str16 (>255 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    const long_str = "b" ** 300;

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), long_str[0..]);
    // str16(300) = 0xda | 0x012c | "b"*300 = 303 bytes
    try testing.expectEqual(@as(usize, 303), buf.items.len);
    try testing.expectEqual(@as(u8, 0xda), buf.items[0]);
    try testing.expectEqual(@as(u16, 300), std.mem.readInt(u16, buf.items[1..3], .big));
}

test "msgpack_utils: writeMsgPackStr str32 (>65535 bytes)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    const len = 70000;
    const long_str = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(long_str);
    @memset(long_str, 'c');

    try msgpack_utils.writeMsgPackStr(buf.writer(testing.allocator), long_str);
    // str32(70000) = 0xdb | 0x00011170 | "c"*70000 = 70005 bytes
    try testing.expectEqual(@as(usize, 70005), buf.items.len);
    try testing.expectEqual(@as(u8, 0xdb), buf.items[0]);
    try testing.expectEqual(@as(u32, len), std.mem.readInt(u32, buf.items[1..5], .big));
}

// MessagePack utility properties
//
// Invariant: Oversized Payloads Rejected
//
// Payloads beyond wire_limits (depth 32, array/map 100k, string/bin/ext 1MB)
// must be rejected with the corresponding limit error.
fn writeBe32(buf: []u8, offset: usize, value: u32) void {
    var tmp: [4]u8 align(1) = undefined;
    std.mem.writeInt(u32, &tmp, value, .big);
    @memcpy(buf[offset .. offset + 4], &tmp);
}

fn expectDecodeError(allocator: std.mem.Allocator, bytes: []const u8, expected_err: anyerror) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    const result = msgpack_utils.decode(allocator, &reader);
    if (result) |payload| {
        payload.free(allocator);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(expected_err, err);
    }
}

test "msgpack: reject oversized payloads (depth, array, map, string)" {
    const allocator = testing.allocator;

    // Depth bomb: array nested 33 levels (max_depth = 32).
    {
        var depth_bomb: [34]u8 = undefined;
        for (0..33) |i| {
            depth_bomb[i] = 0x91; // fixarray of 1 element
        }
        depth_bomb[33] = 0xc0; // nil at innermost level
        try expectDecodeError(allocator, &depth_bomb, error.MaxDepthExceeded);
    }

    // String bomb: str32 claiming 2 MB (max_string_length = 1 MB).
    {
        const str_len: u32 = 2 * 1024 * 1024;
        const string_bomb = try allocator.alloc(u8, 5 + str_len);
        defer allocator.free(string_bomb);
        string_bomb[0] = 0xdb; // str32
        writeBe32(string_bomb, 1, str_len);
        @memset(string_bomb[5..], 0);
        try expectDecodeError(allocator, string_bomb, error.StringTooLong);
    }
}

test "msgpack: round-trip encoding/decoding preservation" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();

    // Test different types of payloads
    for (0..100) |_| {
        const payload_type = random.uintAtMost(u8, 4);
        var payload: msgpack.Payload = undefined;

        switch (payload_type) {
            0 => { // Integer
                payload = .{ .int = random.int(i64) };
            },
            1 => { // Unsigned Integer
                payload = .{ .uint = random.int(u64) };
            },
            2 => { // Boolean
                payload = .{ .bool = random.boolean() };
            },
            3 => { // String
                const len = random.uintAtMost(usize, 100);
                const str = try allocator.alloc(u8, len);
                defer allocator.free(str);
                random.bytes(str);
                // Ensure string is valid-ish (or just bytes for MsgPack purposes)
                payload = try msgpack.Payload.strToPayload(str, allocator);
            },
            4 => { // Map (simple)
                payload = msgpack.Payload.mapPayload(allocator);
                const num_entries = random.uintAtMost(usize, 5);
                for (0..num_entries) |i| {
                    const key_buf = try std.fmt.allocPrint(allocator, "key_{}", .{i});
                    defer allocator.free(key_buf);
                    const val_buf = try std.fmt.allocPrint(allocator, "val_{}", .{i});
                    defer allocator.free(val_buf);

                    try payload.mapPut(key_buf, try msgpack.Payload.strToPayload(val_buf, allocator));
                }
            },
            else => unreachable,
        }
        defer payload.free(allocator);

        // Encode using the project's standard ArrayList writer
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(allocator);
        try msgpack_utils.encode(payload, list.writer(allocator));

        // Get the encoded bytes
        const encoded = try list.toOwnedSlice(allocator);
        defer allocator.free(encoded);

        // Decode using the project's standard fixed reader
        var reader: std.Io.Reader = .fixed(encoded);
        const decoded = try msgpack_utils.decode(allocator, &reader);
        defer decoded.free(allocator);

        // Verify equality
        try verifyPayloadEquality(payload, decoded);
    }
}

// Boundary success properties
//
// Invariant: Boundary Success Tests
//
// Payloads exactly at the wire_limits boundary must decode successfully.
test "msgpack: boundary success (31 depth, 100000 items, 1MB str)" {
    const allocator = testing.allocator;

    // --- Depth exactly 31 (max allowed with max_depth=32) ---
    {
        var depth31: [32]u8 = undefined;
        for (0..31) |i| {
            depth31[i] = 0x91; // fixarray of 1 element
        }
        depth31[31] = 0xc0; // nil at innermost level

        var reader: std.Io.Reader = .fixed(&depth31);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- Array of exactly 100,000 elements ---
    {
        const count: u32 = 100000;
        const array_exact = try allocator.alloc(u8, 5 + count);
        defer allocator.free(array_exact);

        array_exact[0] = 0xdd; // array32
        writeBe32(array_exact, 1, count);
        @memset(array_exact[5..], 0xc0); // nil

        var reader: std.Io.Reader = .fixed(array_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- Map of exactly 100,000 entries ---
    {
        const count: u32 = 100000;
        const map_exact = try allocator.alloc(u8, 5 + 2 * count);
        defer allocator.free(map_exact);

        map_exact[0] = 0xdf; // map32
        writeBe32(map_exact, 1, count);
        @memset(map_exact[5..], 0xc0); // nil key+value pairs

        var reader: std.Io.Reader = .fixed(map_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- String of exactly 1MB bytes ---
    {
        const str_len: u32 = 1 * 1024 * 1024;
        const string_exact = try allocator.alloc(u8, 5 + str_len);
        defer allocator.free(string_exact);

        string_exact[0] = 0xdb; // str32
        writeBe32(string_exact, 1, str_len);
        @memset(string_exact[5..], 0);

        var reader: std.Io.Reader = .fixed(string_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- Bin of exactly 1MB bytes ---
    {
        const bin_len: u32 = 1 * 1024 * 1024;
        const bin_exact = try allocator.alloc(u8, 5 + bin_len);
        defer allocator.free(bin_exact);

        bin_exact[0] = 0xc6; // bin32
        writeBe32(bin_exact, 1, bin_len);
        @memset(bin_exact[5..], 0);

        var reader: std.Io.Reader = .fixed(bin_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- Ext of exactly 1MB bytes ---
    {
        const ext_len: u32 = 1 * 1024 * 1024;
        const ext_exact = try allocator.alloc(u8, 5 + 1 + ext_len);
        defer allocator.free(ext_exact);

        ext_exact[0] = 0xc9; // ext32
        writeBe32(ext_exact, 1, ext_len);
        ext_exact[5] = 0x00; // ext type byte
        @memset(ext_exact[6..], 0);

        var reader: std.Io.Reader = .fixed(ext_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }
}

// Boundary failure properties
//
// Invariant: One-Over-Boundary Tests
//
// Payloads one unit over the wire_limits boundary must return the appropriate limit error.
test "msgpack: reject one-over-boundary payloads" {
    const allocator = testing.allocator;

    // --- Depth 32 (one over the effective max of 31 with max_depth=32) ---
    {
        var depth32: [33]u8 = undefined;
        for (0..32) |i| {
            depth32[i] = 0x91; // fixarray of 1 element
        }
        depth32[32] = 0xc0; // nil at innermost level
        try expectDecodeError(allocator, &depth32, error.MaxDepthExceeded);
    }

    // --- Array of exactly 100,001 elements (one over max_array_length=100,000) ---
    {
        const count: u32 = 100001;
        const array_over = try allocator.alloc(u8, 5 + count);
        defer allocator.free(array_over);

        array_over[0] = 0xdd; // array32
        writeBe32(array_over, 1, count);
        @memset(array_over[5..], 0xc0); // nil
        try expectDecodeError(allocator, array_over, error.ArrayTooLarge);
    }

    // --- Map of exactly 100,001 entries (one over max_map_size=100,000) ---
    {
        const count: u32 = 100001;
        const map_over = try allocator.alloc(u8, 5 + 2 * count);
        defer allocator.free(map_over);

        map_over[0] = 0xdf; // map32
        writeBe32(map_over, 1, count);
        @memset(map_over[5..], 0xc0); // nil key+value pairs
        try expectDecodeError(allocator, map_over, error.MapTooLarge);
    }

    // --- String of exactly 1MB+1 bytes (one over max_string_length=1MB) ---
    {
        const str_len: u32 = 1 * 1024 * 1024 + 1;
        const string_over = try allocator.alloc(u8, 5 + str_len);
        defer allocator.free(string_over);

        string_over[0] = 0xdb; // str32
        writeBe32(string_over, 1, str_len);
        @memset(string_over[5..], 0);
        try expectDecodeError(allocator, string_over, error.StringTooLong);
    }

    // --- Bin of exactly 1MB+1 bytes (one over max_bin_length=1MB) ---
    {
        const bin_len: u32 = 1 * 1024 * 1024 + 1;
        const bin_over = try allocator.alloc(u8, 5 + bin_len);
        defer allocator.free(bin_over);

        bin_over[0] = 0xc6; // bin32
        writeBe32(bin_over, 1, bin_len);
        @memset(bin_over[5..], 0);
        try expectDecodeError(allocator, bin_over, error.BinDataLengthTooLong);
    }

    // --- Ext of exactly 1MB+1 bytes (one over max_ext_length=1MB) ---
    {
        const ext_len: u32 = 1 * 1024 * 1024 + 1;
        const ext_over = try allocator.alloc(u8, 5 + 1 + ext_len);
        defer allocator.free(ext_over);

        ext_over[0] = 0xc9; // ext32
        writeBe32(ext_over, 1, ext_len);
        ext_over[5] = 0x00; // ext type byte
        @memset(ext_over[6..], 0);
        try expectDecodeError(allocator, ext_over, error.ExtDataTooLarge);
    }
}

fn verifyPayloadEquality(expected: msgpack.Payload, actual: msgpack.Payload) !void {
    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) {
        // Lenient integer check: both could be integers
        if (expected.isInteger() and actual.isInteger()) {
            const e_val = try expected.getUint();
            const a_val = try actual.getUint();
            try testing.expectEqual(e_val, a_val);
            return;
        }
        std.debug.print("Tag mismatch: expected {}, found {}\n", .{ std.meta.activeTag(expected), std.meta.activeTag(actual) });
        try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    }

    switch (expected) {
        .int => |v| try testing.expectEqual(v, actual.int),
        .uint => |v| try testing.expectEqual(v, actual.uint),
        .bool => |v| try testing.expectEqual(v, actual.bool),
        .str => |v| try testing.expectEqualStrings(v.value(), actual.str.value()),
        .map => {
            try testing.expectEqual(expected.map.count(), actual.map.count());
            var it = expected.map.iterator();
            while (it.next()) |entry| {
                const actual_val = (try actual.mapGetGeneric(entry.key_ptr.*)) orelse return error.TestExpectedValue;
                try verifyPayloadEquality(entry.value_ptr.*, actual_val);
            }
        },
        else => return error.UnsupportedRoundTripPayload,
    }
}
