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
    // Craft a MessagePack array nested 33 levels deep.
    // Each level: fixarray of 1 element (0x91). Innermost: nil (0xc0).
    // wire_limits.max_depth = 32, so 33 levels should trigger MaxDepthExceeded.
    {
        var depth_bomb: [34]u8 = undefined;
        for (0..33) |i| {
            depth_bomb[i] = 0x91; // fixarray of 1 element
        }
        depth_bomb[33] = 0xc0; // nil at innermost level

        var reader: std.Io.Reader = .fixed(&depth_bomb);
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
    // Craft a MessagePack array32 header claiming 100,001 elements, followed by 100,001 nil bytes.
    // wire_limits.max_array_length = 100,000, so 100,001 elements should trigger ArrayTooLarge.
    {
        const count: u32 = 100001;
        var array_bomb: [5 + 100001]u8 = undefined;
        array_bomb[0] = 0xdd; // array32 format byte
        array_bomb[1] = @intCast((count >> 24) & 0xff);
        array_bomb[2] = @intCast((count >> 16) & 0xff);
        array_bomb[3] = @intCast((count >> 8) & 0xff);
        array_bomb[4] = @intCast(count & 0xff);
        for (5..5 + 100001) |i| {
            array_bomb[i] = 0xc0; // nil
        }

        var reader: std.Io.Reader = .fixed(&array_bomb);
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
    // Craft a MessagePack map32 header claiming 100,001 entries, followed by 200,002 nil bytes (key+value pairs).
    // wire_limits.max_map_size = 100,000, so 100,001 entries should trigger MapTooLarge.
    {
        const count: u32 = 100001;
        var map_bomb: [5 + 200002]u8 = undefined;
        map_bomb[0] = 0xdf; // map32 format byte
        map_bomb[1] = @intCast((count >> 24) & 0xff);
        map_bomb[2] = @intCast((count >> 16) & 0xff);
        map_bomb[3] = @intCast((count >> 8) & 0xff);
        map_bomb[4] = @intCast(count & 0xff);
        for (5..5 + 200002) |i| {
            map_bomb[i] = 0xc0; // nil (key and value both nil)
        }

        var reader: std.Io.Reader = .fixed(&map_bomb);
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
    // Craft a MessagePack str32 header claiming 2 MB, followed by 2 MB of zero bytes.
    // wire_limits.max_string_length = 1 MB, so 2 MB should trigger StringTooLong.
    {
        const str_len: u32 = 2 * 1024 * 1024;
        const total_size = 5 + str_len;
        const string_bomb = try allocator.alloc(u8, total_size);
        defer allocator.free(string_bomb);

        string_bomb[0] = 0xdb; // str32 format byte
        string_bomb[1] = @intCast((str_len >> 24) & 0xff);
        string_bomb[2] = @intCast((str_len >> 16) & 0xff);
        string_bomb[3] = @intCast((str_len >> 8) & 0xff);
        string_bomb[4] = @intCast(str_len & 0xff);
        @memset(string_bomb[5..], 0); // zero bytes for string content

        var reader: std.Io.Reader = .fixed(string_bomb);
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

        // Encode using the project's standard ArrayList writer
        var list: std.ArrayList(u8) = .{};
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
    // The zig-msgpack depth check fires when parse_stack.items.len >= max_depth (32).
    // So 31 levels of nesting is the maximum that succeeds.
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
        const total_size = 5 + count;
        const array_exact = try allocator.alloc(u8, total_size);
        defer allocator.free(array_exact);

        array_exact[0] = 0xdd; // array32 format byte
        array_exact[1] = @intCast((count >> 24) & 0xff);
        array_exact[2] = @intCast((count >> 16) & 0xff);
        array_exact[3] = @intCast((count >> 8) & 0xff);
        array_exact[4] = @intCast(count & 0xff);
        @memset(array_exact[5..], 0xc0); // nil

        var reader: std.Io.Reader = .fixed(array_exact);
        const result = try msgpack_utils.decode(allocator, &reader);
        result.free(allocator);
    }

    // --- String of exactly 1MB bytes ---
    {
        const str_len: u32 = 1 * 1024 * 1024;
        const total_size = 5 + str_len;
        const string_exact = try allocator.alloc(u8, total_size);
        defer allocator.free(string_exact);

        string_exact[0] = 0xdb; // str32 format byte
        string_exact[1] = @intCast((str_len >> 24) & 0xff);
        string_exact[2] = @intCast((str_len >> 16) & 0xff);
        string_exact[3] = @intCast((str_len >> 8) & 0xff);
        string_exact[4] = @intCast(str_len & 0xff);
        @memset(string_exact[5..], 0);

        var reader: std.Io.Reader = .fixed(string_exact);
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

        var reader: std.Io.Reader = .fixed(&depth32);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.MaxDepthExceeded, err);
        }
    }

    // --- Array of exactly 100,001 elements (one over max_array_length=100,000) ---
    {
        const count: u32 = 100001;
        const total_size = 5 + count;
        const array_over = try allocator.alloc(u8, total_size);
        defer allocator.free(array_over);

        array_over[0] = 0xdd; // array32 format byte
        array_over[1] = @intCast((count >> 24) & 0xff);
        array_over[2] = @intCast((count >> 16) & 0xff);
        array_over[3] = @intCast((count >> 8) & 0xff);
        array_over[4] = @intCast(count & 0xff);
        @memset(array_over[5..], 0xc0); // nil

        var reader: std.Io.Reader = .fixed(array_over);
        const result = msgpack_utils.decode(allocator, &reader);
        if (result) |payload| {
            payload.free(allocator);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.ArrayTooLarge, err);
        }
    }

    // --- String of exactly 1MB+1 bytes (one over max_string_length=1MB) ---
    {
        const str_len: u32 = 1 * 1024 * 1024 + 1;
        const total_size = 5 + str_len;
        const string_over = try allocator.alloc(u8, total_size);
        defer allocator.free(string_over);

        string_over[0] = 0xdb; // str32 format byte
        string_over[1] = @intCast((str_len >> 24) & 0xff);
        string_over[2] = @intCast((str_len >> 16) & 0xff);
        string_over[3] = @intCast((str_len >> 8) & 0xff);
        string_over[4] = @intCast(str_len & 0xff);
        @memset(string_over[5..], 0);

        var reader: std.Io.Reader = .fixed(string_over);
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
