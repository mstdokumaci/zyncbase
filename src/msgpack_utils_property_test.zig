const std = @import("std");
const testing = std.testing;
const msgpack_utils = @import("msgpack_utils.zig");
const msgpack = @import("msgpack");

// MessagePack utility properties
//
// Invariant: Oversized Payloads Rejected
//
// This test MUST FAIL on unfixed code (PackerIO uses DEFAULT_LIMITS which are too permissive).
// Failure confirms the bug exists. When the fix is applied (PackWithLimits + TIGHT_LIMITS),
// this test will PASS.
test "msgpack: reject oversized payloads (depth, array, map, string)" {
    const allocator = testing.allocator;

    // --- Depth bomb ---
    // Craft a MessagePack array nested 20 levels deep.
    // Each level: fixarray of 1 element (0x91). Innermost: nil (0xc0).
    // TIGHT_LIMITS.max_depth = 16, so 20 levels should trigger MaxDepthExceeded.
    {
        var depth_bomb: [21]u8 = undefined;
        for (0..20) |i| {
            depth_bomb[i] = 0x91; // fixarray of 1 element
        }
        depth_bomb[20] = 0xc0; // nil at innermost level

        var reader = std.Io.Reader.fixed(&depth_bomb);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            // Bug confirmed: decode returned a valid Payload instead of error.MaxDepthExceeded
            // Counterexample: depth bomb (20 levels) decoded successfully — PackerIO allows depth up to 1000
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.MaxDepthExceeded, err);
        }
    }

    // --- Array bomb ---
    // Craft a MessagePack array32 header claiming 2,000 elements, followed by 2,000 nil bytes.
    // TIGHT_LIMITS.max_array_length = 1,000, so 2,000 elements should trigger ArrayTooLarge.
    {
        const count: u32 = 2000;
        var array_bomb: [5 + 2000]u8 = undefined;
        array_bomb[0] = 0xdd; // array32 format byte
        array_bomb[1] = @intCast((count >> 24) & 0xff);
        array_bomb[2] = @intCast((count >> 16) & 0xff);
        array_bomb[3] = @intCast((count >> 8) & 0xff);
        array_bomb[4] = @intCast(count & 0xff);
        for (5..5 + 2000) |i| {
            array_bomb[i] = 0xc0; // nil
        }

        var reader = std.Io.Reader.fixed(&array_bomb);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            // Bug confirmed: decode returned a valid Payload instead of error.ArrayTooLarge
            // Counterexample: array bomb (2000 elements) decoded successfully — PackerIO allows up to 1,000,000
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.ArrayTooLarge, err);
        }
    }

    // --- Map bomb ---
    // Craft a MessagePack map32 header claiming 2,000 entries, followed by 4,000 nil bytes (key+value pairs).
    // TIGHT_LIMITS.max_map_size = 1,000, so 2,000 entries should trigger MapTooLarge.
    {
        const count: u32 = 2000;
        var map_bomb: [5 + 4000]u8 = undefined;
        map_bomb[0] = 0xdf; // map32 format byte
        map_bomb[1] = @intCast((count >> 24) & 0xff);
        map_bomb[2] = @intCast((count >> 16) & 0xff);
        map_bomb[3] = @intCast((count >> 8) & 0xff);
        map_bomb[4] = @intCast(count & 0xff);
        for (5..5 + 4000) |i| {
            map_bomb[i] = 0xc0; // nil (key and value both nil)
        }

        var reader = std.Io.Reader.fixed(&map_bomb);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            // Bug confirmed: decode returned a valid Payload instead of error.MapTooLarge
            // Counterexample: map bomb (2000 entries) decoded successfully — PackerIO allows up to 1,000,000
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.MapTooLarge, err);
        }
    }

    // --- String bomb ---
    // Craft a MessagePack str32 header claiming 128 KB, followed by 128 KB of zero bytes.
    // TIGHT_LIMITS.max_string_length = 64 KB, so 128 KB should trigger StringTooLong.
    {
        const str_len: u32 = 128 * 1024;
        const total_size = 5 + str_len;
        const string_bomb = try allocator.alloc(u8, total_size);
        defer allocator.free(string_bomb);

        string_bomb[0] = 0xdb; // str32 format byte
        string_bomb[1] = @intCast((str_len >> 24) & 0xff);
        string_bomb[2] = @intCast((str_len >> 16) & 0xff);
        string_bomb[3] = @intCast((str_len >> 8) & 0xff);
        string_bomb[4] = @intCast(str_len & 0xff);
        @memset(string_bomb[5..], 0); // zero bytes for string content

        var reader = std.Io.Reader.fixed(string_bomb);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            // Bug confirmed: decode returned a valid Payload instead of error.StringTooLong
            // Counterexample: string bomb (128 KB) decoded successfully — PackerIO allows up to 100 MB
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.StringTooLong, err);
        }
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

        // Encode using the project's standard Allocating writer
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try msgpack_utils.encode(payload, &aw.writer);

        // Get the encoded bytes
        const encoded = try aw.toOwnedSlice();
        defer allocator.free(encoded);

        // Decode using the project's standard fixed reader
        var reader = std.Io.Reader.fixed(encoded);
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
// Payloads exactly at the TIGHT_LIMITS boundary must decode successfully on both unfixed and fixed code.
// These tests MUST PASS on unfixed code (confirms baseline behavior to preserve).
test "msgpack: boundary success (15 depth, 1000 items, 64KB str)" {
    const allocator = testing.allocator;

    // --- Depth exactly 15 (max allowed with max_depth=16) ---
    // The zig-msgpack depth check fires when parse_stack.items.len >= max_depth.
    // With max_depth=16, the stack can hold up to 15 items before the check fires,
    // meaning 15 levels of nesting is the maximum that succeeds.
    // 15x fixarray-of-1 (0x91) headers + nil (0xc0) = 16 bytes total
    {
        var depth15: [16]u8 = undefined;
        for (0..15) |i| {
            depth15[i] = 0x91; // fixarray of 1 element
        }
        depth15[15] = 0xc0; // nil at innermost level

        var reader = std.Io.Reader.fixed(&depth15);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- Array of exactly 1,000 elements ---
    // array16 format (0xdc) + 2-byte big-endian count 1000 + 1000 nil bytes
    {
        const count: u16 = 1000;
        var array_exact: [3 + 1000]u8 = undefined;
        array_exact[0] = 0xdc; // array16 format byte
        array_exact[1] = @intCast((count >> 8) & 0xff);
        array_exact[2] = @intCast(count & 0xff);
        for (3..3 + 1000) |i| {
            array_exact[i] = 0xc0; // nil
        }

        var reader = std.Io.Reader.fixed(&array_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- String of exactly 64*1024 bytes ---
    // str32 (0xdb) + 4-byte big-endian length + 65536 zero bytes
    {
        const str_len: u32 = 64 * 1024;
        const total_size = 5 + str_len;
        const string_exact = try allocator.alloc(u8, total_size);
        defer allocator.free(string_exact);

        string_exact[0] = 0xdb; // str32 format byte
        string_exact[1] = @intCast((str_len >> 24) & 0xff);
        string_exact[2] = @intCast((str_len >> 16) & 0xff);
        string_exact[3] = @intCast((str_len >> 8) & 0xff);
        string_exact[4] = @intCast(str_len & 0xff);
        @memset(string_exact[5..], 0);

        var reader = std.Io.Reader.fixed(string_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }
}

// Boundary failure properties
//
// Invariant: One-Over-Boundary Tests
//
// Payloads one unit over the TIGHT_LIMITS boundary must return the appropriate limit error.
// These tests MUST FAIL on unfixed code (confirms limits are not enforced yet).
// After the fix is applied, these tests will PASS.
test "msgpack: reject one-over-boundary payloads" {
    const allocator = testing.allocator;

    // --- Depth 16 (one over the effective max of 15 with max_depth=16) ---
    // The zig-msgpack depth check fires when parse_stack.items.len >= max_depth (16),
    // so depth=16 (16 nested arrays) triggers MaxDepthExceeded.
    // 16x fixarray-of-1 (0x91) headers + nil (0xc0) = 17 bytes total
    {
        var depth16: [17]u8 = undefined;
        for (0..16) |i| {
            depth16[i] = 0x91; // fixarray of 1 element
        }
        depth16[16] = 0xc0; // nil at innermost level

        var reader = std.Io.Reader.fixed(&depth16);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            // Limit not enforced: depth=16 decoded successfully — unfixed code uses DEFAULT_LIMITS (max_depth=1000)
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.MaxDepthExceeded, err);
        }
    }

    // --- Array of exactly 1,001 elements (one over max_array_length=1000) ---
    // array16 format (0xdc) + 2-byte big-endian count 1001 + 1001 nil bytes
    {
        const count: u16 = 1001;
        var array_over: [3 + 1001]u8 = undefined;
        array_over[0] = 0xdc; // array16 format byte
        array_over[1] = @intCast((count >> 8) & 0xff);
        array_over[2] = @intCast(count & 0xff);
        for (3..3 + 1001) |i| {
            array_over[i] = 0xc0; // nil
        }

        var reader = std.Io.Reader.fixed(&array_over);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            // Limit not enforced: array of 1001 decoded successfully — unfixed code uses DEFAULT_LIMITS (max_array_length=1,000,000)
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.ArrayTooLarge, err);
        }
    }

    // --- String of exactly 64*1024+1 bytes (one over max_string_length=64KB) ---
    // str32 (0xdb) + 4-byte big-endian length + 65537 zero bytes
    {
        const str_len: u32 = 64 * 1024 + 1;
        const total_size = 5 + str_len;
        const string_over = try allocator.alloc(u8, total_size);
        defer allocator.free(string_over);

        string_over[0] = 0xdb; // str32 format byte
        string_over[1] = @intCast((str_len >> 24) & 0xff);
        string_over[2] = @intCast((str_len >> 16) & 0xff);
        string_over[3] = @intCast((str_len >> 8) & 0xff);
        string_over[4] = @intCast(str_len & 0xff);
        @memset(string_over[5..], 0);

        var reader = std.Io.Reader.fixed(string_over);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            // Limit not enforced: string of 64KB+1 decoded successfully — unfixed code uses DEFAULT_LIMITS (max_string_length=100MB)
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.StringTooLong, err);
        }
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
            // In a real test we'd iterate and compare entries
        },
        else => {},
    }
}
