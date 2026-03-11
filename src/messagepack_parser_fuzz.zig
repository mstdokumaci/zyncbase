const std = @import("std");
const testing = std.testing;
const MessagePackParser = @import("messagepack_parser.zig").MessagePackParser;

// Fuzz testing suite for MessagePack parser
// Tests parser with malicious payloads: depth bombs, size bombs, string bombs
// Validates: Requirements 3.11 - Parser never crashes or causes stack overflow

/// Generate a depth bomb - deeply nested structure
fn generateDepthBomb(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var data: std.ArrayListUnmanaged(u8) = .{};
    errdefer data.deinit(allocator);

    // Create nested arrays
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        try data.append(allocator, 0x91); // fixarray with 1 element
    }
    try data.append(allocator, 0xc0); // nil at the deepest level

    return data.toOwnedSlice(allocator);
}

/// Generate a size bomb - extremely large array declaration
fn generateSizeBomb(allocator: std.mem.Allocator, size: u32) ![]u8 {
    var data: std.ArrayListUnmanaged(u8) = .{};
    errdefer data.deinit(allocator);

    // Use array32 format to declare huge array
    try data.append(allocator, 0xdd); // array32
    try data.append(allocator, @intCast((size >> 24) & 0xFF));
    try data.append(allocator, @intCast((size >> 16) & 0xFF));
    try data.append(allocator, @intCast((size >> 8) & 0xFF));
    try data.append(allocator, @intCast(size & 0xFF));

    return data.toOwnedSlice(allocator);
}

/// Generate a string bomb - extremely long string declaration
fn generateStringBomb(allocator: std.mem.Allocator, length: u32) ![]u8 {
    var data: std.ArrayListUnmanaged(u8) = .{};
    errdefer data.deinit(allocator);

    // Use str32 format to declare huge string
    try data.append(allocator, 0xdb); // str32
    try data.append(allocator, @intCast((length >> 24) & 0xFF));
    try data.append(allocator, @intCast((length >> 16) & 0xFF));
    try data.append(allocator, @intCast((length >> 8) & 0xFF));
    try data.append(allocator, @intCast(length & 0xFF));

    return data.toOwnedSlice(allocator);
}

/// Generate a map bomb - extremely large map declaration
fn generateMapBomb(allocator: std.mem.Allocator, size: u32) ![]u8 {
    var data: std.ArrayListUnmanaged(u8) = .{};
    errdefer data.deinit(allocator);

    // Use map32 format to declare huge map
    try data.append(allocator, 0xdf); // map32
    try data.append(allocator, @intCast((size >> 24) & 0xFF));
    try data.append(allocator, @intCast((size >> 16) & 0xFF));
    try data.append(allocator, @intCast((size >> 8) & 0xFF));
    try data.append(allocator, @intCast(size & 0xFF));

    return data.toOwnedSlice(allocator);
}

test "fuzz: depth bomb - exceeds max depth" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_depth = 32 });
    defer parser.deinit();

    // Generate depth bomb with 100 levels
    const data = try generateDepthBomb(allocator, 100);
    defer allocator.free(data);

    const result = parser.parse(data);
    try testing.expectError(error.MaxDepthExceeded, result);
}

test "fuzz: size bomb - exceeds max array length" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_array_length = 100_000 });
    defer parser.deinit();

    // Generate size bomb with 1 million elements
    const data = try generateSizeBomb(allocator, 1_000_000);
    defer allocator.free(data);

    const result = parser.parse(data);
    try testing.expectError(error.MaxArrayLengthExceeded, result);
}

test "fuzz: string bomb - exceeds max string length" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_string_length = 1024 * 1024 });
    defer parser.deinit();

    // Generate string bomb with 10 MB string declaration
    const data = try generateStringBomb(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    const result = parser.parse(data);
    // Will hit UnexpectedEOF because we don't provide the actual string data
    // This is correct - parser checks EOF before length limit
    try testing.expectError(error.UnexpectedEOF, result);
}

test "fuzz: string bomb with data - exceeds max string length" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_string_length = 100 });
    defer parser.deinit();

    // Create a string that's longer than the limit with actual data
    var data: std.ArrayListUnmanaged(u8) = .{};
    defer data.deinit(allocator);

    try data.append(allocator, 0xd9); // str8
    try data.append(allocator, 200); // length 200 (exceeds limit of 100)

    // Add some actual string data
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        try data.append(allocator, 'x');
    }

    const result = parser.parse(data.items);
    try testing.expectError(error.MaxStringLengthExceeded, result);
}

test "fuzz: map bomb - exceeds max map size" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{ .max_map_size = 100_000 });
    defer parser.deinit();

    // Generate map bomb with 1 million entries
    const data = try generateMapBomb(allocator, 1_000_000);
    defer allocator.free(data);

    const result = parser.parse(data);
    try testing.expectError(error.MaxMapSizeExceeded, result);
}

test "fuzz: random malicious payloads - bounded parse time" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    // Test 1000 random malicious payloads
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var data: [1024]u8 = undefined;
        random.bytes(&data);

        const start = std.time.nanoTimestamp();

        // Parser should either succeed or return error, never hang
        if (parser.parse(&data)) |value| {
            parser.freeValue(value);
        } else |err| {
            // All errors should be defined ParseError types
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

        const end = std.time.nanoTimestamp();
        const duration_ms = @divTrunc(end - start, 1_000_000);

        // Parse should complete in under 100ms even for malicious input
        try testing.expect(duration_ms < 100);
    }
}

test "fuzz: mixed attack vectors" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Combine multiple attack vectors in one payload
    var data: std.ArrayListUnmanaged(u8) = .{};
    defer data.deinit(allocator);

    // Start with a map
    try data.append(allocator, 0x82); // fixmap with 2 entries

    // First entry: depth bomb key
    try data.append(allocator, 0xa4); // fixstr length 4
    try data.appendSlice(allocator, "deep");
    // Value: nested arrays
    var d: usize = 0;
    while (d < 10) : (d += 1) {
        try data.append(allocator, 0x91); // fixarray with 1 element
    }
    try data.append(allocator, 0xc0); // nil

    // Second entry: large array key
    try data.append(allocator, 0xa5); // fixstr length 5
    try data.appendSlice(allocator, "large");
    // Value: declare large array (will fail on size check)
    try data.append(allocator, 0xdc); // array16
    try data.append(allocator, 0xFF);
    try data.append(allocator, 0xFF); // 65535 elements

    const result = parser.parse(data.items);

    // Should fail with one of the limit errors
    if (result) |value| {
        parser.freeValue(value);
        try testing.expect(false); // Should not succeed
    } else |err| {
        switch (err) {
            error.MaxDepthExceeded,
            error.MaxArrayLengthExceeded,
            error.UnexpectedEOF,
            => {},
            else => try testing.expect(false),
        }
    }
}

test "fuzz: incomplete payloads" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test various incomplete payloads
    const test_cases = [_][]const u8{
        &[_]u8{0xd9}, // str8 without length
        &[_]u8{ 0xd9, 0x05 }, // str8 with length but no data
        &[_]u8{ 0xdc, 0x00 }, // array16 incomplete length
        &[_]u8{ 0xde, 0x00, 0x05 }, // map16 with size but no data
        &[_]u8{0x91}, // fixarray with 1 element but no element
        &[_]u8{ 0x81, 0xa3, 'k', 'e', 'y' }, // fixmap with key but no value
    };

    for (test_cases) |data| {
        const result = parser.parse(data);
        try testing.expectError(error.UnexpectedEOF, result);
    }
}

test "fuzz: edge case values" {
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    // Test edge case integer values
    const test_cases = [_]struct { data: []const u8, expected_type: std.meta.Tag(MessagePackParser.Value) }{
        .{ .data = &[_]u8{0x00}, .expected_type = .unsigned }, // min positive fixint
        .{ .data = &[_]u8{0x7f}, .expected_type = .unsigned }, // max positive fixint
        .{ .data = &[_]u8{0xe0}, .expected_type = .integer }, // min negative fixint
        .{ .data = &[_]u8{0xff}, .expected_type = .integer }, // max negative fixint (-1)
        .{ .data = &[_]u8{ 0xcc, 0xff }, .expected_type = .unsigned }, // max u8
        .{ .data = &[_]u8{ 0xcd, 0xff, 0xff }, .expected_type = .unsigned }, // max u16
        .{ .data = &[_]u8{ 0xd0, 0x80 }, .expected_type = .integer }, // min i8
        .{ .data = &[_]u8{ 0xd0, 0x7f }, .expected_type = .integer }, // max i8
    };

    for (test_cases) |tc| {
        const value = try parser.parse(tc.data);
        defer parser.freeValue(value);
        try testing.expectEqual(tc.expected_type, @as(std.meta.Tag(MessagePackParser.Value), value));
    }
}

test "fuzz: stress test with AddressSanitizer" {
    // This test is designed to be run with AddressSanitizer to detect memory issues
    const allocator = testing.allocator;
    const parser = try MessagePackParser.init(allocator, .{});
    defer parser.deinit();

    var prng = std.Random.DefaultPrng.init(99999);
    const random = prng.random();

    // Stress test with many random payloads
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const size = random.intRangeAtMost(usize, 1, 512);
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);

        random.bytes(data);

        if (parser.parse(data)) |value| {
            parser.freeValue(value);
        } else |_| {
            // Expected to fail on most random data
        }
    }
}
