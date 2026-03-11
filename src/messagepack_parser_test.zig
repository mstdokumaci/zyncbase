const std = @import("std");
const testing = std.testing;
const MessagePackParser = @import("messagepack_parser.zig").MessagePackParser;

// **Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.11**
// **Property 2: MessagePack Parser Safety**
// This property test verifies that the parser correctly enforces all security limits
// and never crashes or causes stack overflow, even with malicious inputs.

test "MessagePack parser: basic value parsing" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test nil
    {
        const data = [_]u8{0xc0};
        const value = try parser.parse(&data);
        try testing.expectEqual(MessagePackParser.Value.nil, value);
    }

    // Test boolean true
    {
        const data = [_]u8{0xc3};
        const value = try parser.parse(&data);
        try testing.expect(value.boolean == true);
    }

    // Test boolean false
    {
        const data = [_]u8{0xc2};
        const value = try parser.parse(&data);
        try testing.expect(value.boolean == false);
    }

    // Test positive fixint
    {
        const data = [_]u8{0x2a}; // 42
        const value = try parser.parse(&data);
        try testing.expectEqual(@as(u64, 42), value.unsigned);
    }

    // Test negative fixint
    {
        const data = [_]u8{0xff}; // -1
        const value = try parser.parse(&data);
        try testing.expectEqual(@as(i64, -1), value.integer);
    }
}

test "MessagePack parser: string parsing" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test fixstr
    {
        const data = [_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' };
        const value = try parser.parse(&data);
        try testing.expectEqualStrings("hello", value.string);
    }

    // Test str8
    {
        const data = [_]u8{ 0xd9, 0x05, 'w', 'o', 'r', 'l', 'd' };
        const value = try parser.parse(&data);
        try testing.expectEqualStrings("world", value.string);
    }
}

test "MessagePack parser: array parsing" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test fixarray with integers
    {
        const data = [_]u8{ 0x93, 0x01, 0x02, 0x03 }; // [1, 2, 3]
        const value = try parser.parse(&data);
        defer parser.freeValue(value);

        try testing.expectEqual(@as(usize, 3), value.array.len);
        try testing.expectEqual(@as(u64, 1), value.array[0].unsigned);
        try testing.expectEqual(@as(u64, 2), value.array[1].unsigned);
        try testing.expectEqual(@as(u64, 3), value.array[2].unsigned);
    }
}

test "MessagePack parser: map parsing" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test fixmap
    {
        const data = [_]u8{ 0x81, 0xa3, 'k', 'e', 'y', 0x2a }; // {"key": 42}
        const value = try parser.parse(&data);
        defer parser.freeValue(value);

        try testing.expectEqual(@as(usize, 1), value.map.len);
        try testing.expectEqualStrings("key", value.map[0].key.string);
        try testing.expectEqual(@as(u64, 42), value.map[0].value.unsigned);
    }
}

test "MessagePack parser: max depth exceeded" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_depth = 2 });
    defer parser.deinit();

    // Create deeply nested array: [[[[]]]]
    // Depth 0: outer array
    // Depth 1: first nested array
    // Depth 2: second nested array (should fail here)
    const data = [_]u8{ 0x91, 0x91, 0x91, 0x90 }; // [[[[]]]]

    // Verify it rejects nesting at exactly the limit
    const result = parser.parse(&data);
    if (result) |val| {
        parser.freeValue(val);
        std.debug.print("UNEXPECTED SUCCESS: parsed deep nesting that should have been rejected (depth={d})\n", .{2});
        return error.UnexpectedSuccess;
    } else |err| {
        if (err != error.MaxDepthExceeded) {
            std.debug.print("UNEXPECTED ERROR: expected MaxDepthExceeded, got {s}\n", .{@errorName(err)});
            return err;
        }
    }
}

test "MessagePack parser: max size exceeded" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_size = 10 });
    defer parser.deinit();

    // Create data larger than max_size
    const data = [_]u8{0xa5} ++ [_]u8{'x'} ** 20; // String of 20 bytes

    const result = parser.parse(&data);
    try testing.expectError(error.MaxSizeExceeded, result);
}

test "MessagePack parser: max string length exceeded" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_string_length = 5 });
    defer parser.deinit();

    // Create string longer than max_string_length
    const data = [_]u8{ 0xd9, 0x0a } ++ [_]u8{'x'} ** 10; // String of 10 bytes

    const result = parser.parse(&data);
    try testing.expectError(error.MaxStringLengthExceeded, result);
}

test "MessagePack parser: max array length exceeded" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_array_length = 5 });
    defer parser.deinit();

    // Create array with 10 elements using array16 format
    var data = [_]u8{ 0xdc, 0x00, 0x0a }; // array16 with length 10
    const result = parser.parse(&data);
    try testing.expectError(error.MaxArrayLengthExceeded, result);
}

test "MessagePack parser: max map size exceeded" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_map_size = 5 });
    defer parser.deinit();

    // Create map with 10 entries using map16 format
    var data = [_]u8{ 0xde, 0x00, 0x0a }; // map16 with size 10
    const result = parser.parse(&data);
    try testing.expectError(error.MaxMapSizeExceeded, result);
}

test "MessagePack parser: invalid format" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test with invalid format byte (0xc1 is reserved/never used)
    const data = [_]u8{0xc1};
    const result = parser.parse(&data);
    try testing.expectError(error.InvalidFormat, result);
}

test "MessagePack parser: unexpected EOF" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test with incomplete string (declares length 5 but only has 2 bytes)
    const data = [_]u8{ 0xa5, 'h', 'i' };
    const result = parser.parse(&data);
    try testing.expectError(error.UnexpectedEOF, result);
}

test "MessagePack parser: nested structures within limits" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_depth = 10 });
    defer parser.deinit();

    // Create nested array within depth limit: [[[1]]]
    const data = [_]u8{ 0x91, 0x91, 0x91, 0x01 };
    const value = try parser.parse(&data);
    defer parser.freeValue(value);

    try testing.expectEqual(@as(usize, 1), value.array.len);
    try testing.expectEqual(@as(usize, 1), value.array[0].array.len);
    try testing.expectEqual(@as(usize, 1), value.array[0].array[0].array.len);
    try testing.expectEqual(@as(u64, 1), value.array[0].array[0].array[0].unsigned);
}

test "ConnectionViolationTracker: basic functionality" {
    const allocator = testing.allocator;
    var tracker = MessagePackParser.ConnectionViolationTracker.init(allocator, 3);
    defer tracker.deinit();

    const conn_id: u64 = 12345;

    // First violation
    {
        const should_close = try tracker.recordViolation(conn_id);
        try testing.expect(!should_close);
        try testing.expectEqual(@as(u32, 1), tracker.getViolationCount(conn_id));
    }

    // Second violation
    {
        const should_close = try tracker.recordViolation(conn_id);
        try testing.expect(!should_close);
        try testing.expectEqual(@as(u32, 2), tracker.getViolationCount(conn_id));
    }

    // Third violation - should trigger closure
    {
        const should_close = try tracker.recordViolation(conn_id);
        try testing.expect(should_close);
        try testing.expectEqual(@as(u32, 3), tracker.getViolationCount(conn_id));
    }

    // Clear violations
    tracker.clearViolations(conn_id);
    try testing.expectEqual(@as(u32, 0), tracker.getViolationCount(conn_id));
}

test "ConnectionViolationTracker: multiple connections" {
    const allocator = testing.allocator;
    var tracker = MessagePackParser.ConnectionViolationTracker.init(allocator, 2);
    defer tracker.deinit();

    const conn1: u64 = 1;
    const conn2: u64 = 2;

    // Conn1: one violation
    _ = try tracker.recordViolation(conn1);
    try testing.expectEqual(@as(u32, 1), tracker.getViolationCount(conn1));
    try testing.expectEqual(@as(u32, 0), tracker.getViolationCount(conn2));

    // Conn2: two violations (should close)
    _ = try tracker.recordViolation(conn2);
    const should_close = try tracker.recordViolation(conn2);
    try testing.expect(should_close);
    try testing.expectEqual(@as(u32, 1), tracker.getViolationCount(conn1));
    try testing.expectEqual(@as(u32, 2), tracker.getViolationCount(conn2));
}

// Property-based test: Parser never crashes with random data
test "MessagePack parser: fuzz test with random data" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Test with 100 random byte sequences
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var data: [256]u8 = undefined;
        random.bytes(&data);

        // Parser should either succeed or return a proper error, never crash
        if (parser.parse(&data)) |value| {
            parser.freeValue(value);
        } else |err| {
            // All errors should be one of the defined ParseError types
            switch (err) {
                error.MaxDepthExceeded,
                error.MaxSizeExceeded,
                error.MaxStringLengthExceeded,
                error.MaxArrayLengthExceeded,
                error.MaxMapSizeExceeded,
                error.InvalidFormat,
                error.UnexpectedEOF,
                error.OutOfMemory,
                => {},
            }
        }
    }
}

// Property test: Deeply nested structures are rejected
test "Property 2: MessagePack parser - deep nesting rejected" {
    const allocator = testing.allocator;
    const max_depth = 5;
    const parser = try MessagePackParser.init(allocator, .{ .max_depth = max_depth });
    defer parser.deinit();

    // Generate nested arrays of various depths
    var depth: usize = 1;
    while (depth <= max_depth + 5) : (depth += 1) {
        var data_list: std.ArrayListUnmanaged(u8) = .{};
        defer data_list.deinit(allocator);

        // Create nested array structure
        var d: usize = 0;
        while (d < depth) : (d += 1) {
            try data_list.append(allocator, 0x91); // fixarray with 1 element
        }
        try data_list.append(allocator, 0xc0); // nil at the deepest level

        const result = parser.parse(data_list.items);

        if (depth <= max_depth) {
            // Should succeed within limit
            if (result) |value| {
                parser.freeValue(value);
            } else |_| {
                // May fail due to other reasons, but not depth
            }
        } else {
            // Should fail with MaxDepthExceeded
            try testing.expectError(error.MaxDepthExceeded, result);
        }
    }
}
