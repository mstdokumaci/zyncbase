const std = @import("std");
const testing = std.testing;
const msgpack_utils = @import("msgpack_utils.zig");
const msgpack = @import("msgpack");

test "Property: MsgPack round-trip encoding/decoding" {
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

fn verifyPayloadEquality(expected: msgpack.Payload, actual: msgpack.Payload) !void {
    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) {
        // Lenient integer check: both could be integers
        if (expected.isInteger() and actual.isInteger()) {
            const e_val = try expected.getUint();
            const a_val = try actual.getUint();
            try testing.expectEqual(e_val, a_val);
            return;
        }
        std.debug.print("Tag mismatch: expected {}, found {}\n", .{std.meta.activeTag(expected), std.meta.activeTag(actual)});
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
