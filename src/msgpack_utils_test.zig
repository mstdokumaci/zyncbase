const std = @import("std");
const testing = std.testing;
const msgpack_utils = @import("msgpack_utils.zig");
const Payload = msgpack_utils.Payload;

// ============================================================
// isLiteral tests
// ============================================================

test "isLiteral: nil returns true" {
    try testing.expect(msgpack_utils.isLiteral(.nil));
}

test "isLiteral: bool returns true" {
    try testing.expect(msgpack_utils.isLiteral(.{ .bool = false }));
}

test "isLiteral: int returns true" {
    try testing.expect(msgpack_utils.isLiteral(.{ .int = 0 }));
}

test "isLiteral: uint returns true" {
    try testing.expect(msgpack_utils.isLiteral(.{ .uint = 0 }));
}

test "isLiteral: float returns true" {
    try testing.expect(msgpack_utils.isLiteral(.{ .float = 0.0 }));
}

test "isLiteral: str returns true" {
    const allocator = testing.allocator;
    const s = try Payload.strToPayload("hi", allocator);
    defer s.free(allocator);
    try testing.expect(msgpack_utils.isLiteral(s));
}

test "isLiteral: arr returns false" {
    const allocator = testing.allocator;
    const elems = try allocator.alloc(Payload, 0);
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    try testing.expect(!msgpack_utils.isLiteral(p));
}

test "isLiteral: map returns false" {
    const allocator = testing.allocator;
    const p = Payload.mapPayload(allocator);
    defer p.free(allocator);
    try testing.expect(!msgpack_utils.isLiteral(p));
}

test "isLiteral: bin returns false" {
    const allocator = testing.allocator;
    const p = try Payload.binToPayload(&[_]u8{0x01}, allocator);
    defer p.free(allocator);
    try testing.expect(!msgpack_utils.isLiteral(p));
}

test "isLiteral: ext returns false" {
    const allocator = testing.allocator;
    const p = try Payload.extToPayload(1, &[_]u8{0x01}, allocator);
    defer p.free(allocator);
    try testing.expect(!msgpack_utils.isLiteral(p));
}

// ============================================================
// ensureLiteralArray tests
// ============================================================

test "ensureLiteralArray: empty array returns no error" {
    const allocator = testing.allocator;
    const elems = try allocator.alloc(Payload, 0);
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    try msgpack_utils.ensureLiteralArray(p);
}

test "ensureLiteralArray: single-element literal array returns no error" {
    const allocator = testing.allocator;
    const elems = try allocator.alloc(Payload, 1);
    elems[0] = .{ .int = 1 };
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    try msgpack_utils.ensureLiteralArray(p);
}

test "ensureLiteralArray: mixed array with non-literal returns NonLiteralElement" {
    const allocator = testing.allocator;
    const inner_elems = try allocator.alloc(Payload, 0);
    const elems = try allocator.alloc(Payload, 2);
    elems[0] = .{ .int = 1 };
    elems[1] = .{ .arr = inner_elems }; // non-literal
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    try testing.expectError(error.NonLiteralElement, msgpack_utils.ensureLiteralArray(p));
}

test "ensureLiteralArray: non-array payload returns NotAnArray" {
    try testing.expectError(error.NotAnArray, msgpack_utils.ensureLiteralArray(.nil));
    try testing.expectError(error.NotAnArray, msgpack_utils.ensureLiteralArray(.{ .int = 5 }));
}

// ============================================================
// payloadToJson tests
// ============================================================

test "payloadToJson: empty array produces []" {
    const allocator = testing.allocator;
    const elems = try allocator.alloc(Payload, 0);
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    const json = try msgpack_utils.payloadToJson(p, allocator);
    defer allocator.free(json);
    try testing.expectEqualStrings("[]", json);
}

test "payloadToJson: [1, \"hello\", true, null]" {
    const allocator = testing.allocator;
    const str_payload = try Payload.strToPayload("hello", allocator);
    const elems = try allocator.alloc(Payload, 4);
    elems[0] = .{ .int = 1 };
    elems[1] = str_payload;
    elems[2] = .{ .bool = true };
    elems[3] = .nil;
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    const json = try msgpack_utils.payloadToJson(p, allocator);
    defer allocator.free(json);
    try testing.expectEqualStrings("[1, \"hello\", true, null]", json);
}

test "payloadToJson: non-literal-array payload returns error" {
    const allocator = testing.allocator;
    // Non-array payload
    try testing.expectError(error.NotAnArray, msgpack_utils.payloadToJson(.nil, allocator));
    // Array with non-literal element
    const inner_elems = try allocator.alloc(Payload, 0);
    const elems = try allocator.alloc(Payload, 1);
    elems[0] = .{ .arr = inner_elems };
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    try testing.expectError(error.NonLiteralElement, msgpack_utils.payloadToJson(p, allocator));
}

// ============================================================
// payloadToCanonicalString tests
// ============================================================

test "payloadToCanonicalString: literal array produces JSON string" {
    const allocator = testing.allocator;
    const str1 = try Payload.strToPayload("admin", allocator);
    const str2 = try Payload.strToPayload("editor", allocator);
    const elems = try allocator.alloc(Payload, 2);
    elems[0] = str1;
    elems[1] = str2;
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    const result = try msgpack_utils.payloadToCanonicalString(p, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("[\"admin\", \"editor\"]", result);
}

test "payloadToCanonicalString: non-literal array returns error" {
    const allocator = testing.allocator;
    const inner_elems = try allocator.alloc(Payload, 0);
    const elems = try allocator.alloc(Payload, 1);
    elems[0] = .{ .arr = inner_elems };
    const p: Payload = .{ .arr = elems };
    defer p.free(allocator);
    try testing.expectError(error.NonLiteralElement, msgpack_utils.payloadToCanonicalString(p, allocator));
}

// ============================================================
// jsonToPayload tests
// ============================================================

test "jsonToPayload: empty array []" {
    const allocator = testing.allocator;
    const p = try msgpack_utils.jsonToPayload("[]", allocator);
    defer p.free(allocator);
    try testing.expectEqual(@as(usize, 0), p.arr.len);
}

test "jsonToPayload: [null]" {
    const allocator = testing.allocator;
    const p = try msgpack_utils.jsonToPayload("[null]", allocator);
    defer p.free(allocator);
    try testing.expectEqual(@as(usize, 1), p.arr.len);
    try testing.expectEqual(Payload.nil, p.arr[0]);
}

test "jsonToPayload: [1, \"hello\", true, null]" {
    const allocator = testing.allocator;
    const p = try msgpack_utils.jsonToPayload("[1, \"hello\", true, null]", allocator);
    defer p.free(allocator);
    try testing.expectEqual(@as(usize, 4), p.arr.len);
    try testing.expectEqual(@as(i64, 1), p.arr[0].int);
    try testing.expectEqualStrings("hello", p.arr[1].str.value());
    try testing.expectEqual(true, p.arr[2].bool);
    try testing.expectEqual(Payload.nil, p.arr[3]);
}

test "jsonToPayload: non-array JSON returns NotAnArray" {
    const allocator = testing.allocator;
    try testing.expectError(error.NotAnArray, msgpack_utils.jsonToPayload("\"hello\"", allocator));
    try testing.expectError(error.NotAnArray, msgpack_utils.jsonToPayload("42", allocator));
    try testing.expectError(error.NotAnArray, msgpack_utils.jsonToPayload("{\"a\":1}", allocator));
}

test "jsonToPayload: array with object element returns NonLiteralElement" {
    const allocator = testing.allocator;
    try testing.expectError(error.NonLiteralElement, msgpack_utils.jsonToPayload("[{\"a\":1}]", allocator));
}

test "jsonToPayload: array with nested array element returns NonLiteralElement" {
    const allocator = testing.allocator;
    try testing.expectError(error.NonLiteralElement, msgpack_utils.jsonToPayload("[[1,2]]", allocator));
}

// ============================================================
// Property-based tests (array-jsonb-storage)
// ============================================================

/// Generate a random literal Payload (nil, bool, int, uint, float, or str).
fn genLiteralPayload(rand: std.Random, allocator: std.mem.Allocator) !Payload {
    const tag = rand.intRangeAtMost(u8, 0, 5);
    return switch (tag) {
        0 => .nil,
        1 => .{ .bool = rand.boolean() },
        2 => .{ .int = rand.int(i64) },
        3 => .{ .uint = rand.int(u64) },
        4 => .{ .float = @as(f64, @floatFromInt(rand.intRangeAtMost(i32, -1000, 1000))) },
        else => try Payload.strToPayload(if (rand.boolean()) "hello" else "world", allocator),
    };
}

/// Generate a random Literal_Array Payload (arr of literal elements).
fn genLiteralArray(rand: std.Random, allocator: std.mem.Allocator) !Payload {
    const n = rand.intRangeAtMost(usize, 0, 8);
    const elems = try allocator.alloc(Payload, n);
    errdefer allocator.free(elems);
    var count: usize = 0;
    errdefer for (elems[0..count]) |p| p.free(allocator);
    for (0..n) |i| {
        elems[i] = try genLiteralPayload(rand, allocator);
        count = i + 1;
    }
    return Payload{ .arr = elems };
}

/// Check structural equivalence of two Payloads (deep comparison).
fn payloadsEqual(a: Payload, b: Payload) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) return false;
    return switch (a) {
        .nil => true,
        .bool => |v| v == b.bool,
        .int => |v| v == b.int,
        .uint => |v| v == b.uint,
        .float => |v| v == b.float,
        .str => |s| std.mem.eql(u8, s.value(), b.str.value()),
        .bin => |bn| std.mem.eql(u8, bn.value(), b.bin.value()),
        .ext => |e| e.type == b.ext.type and std.mem.eql(u8, e.data, b.ext.data),
        .arr => |arr| blk: {
            if (arr.len != b.arr.len) break :blk false;
            for (arr, b.arr) |x, y| {
                if (!payloadsEqual(x, y)) break :blk false;
            }
            break :blk true;
        },
        .map => false, // maps not used in literal arrays
        else => false, // timestamp and other types not expected in literal arrays
    };
}

// Feature: array-jsonb-storage, Property 3: isLiteral returns true for all literal types
test "msgpack_utils: isLiteral returns true for all literal types" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xAAAA_BBBB);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const p = try genLiteralPayload(rand, allocator);
        defer p.free(allocator);
        try testing.expect(msgpack_utils.isLiteral(p));
    }
}

// Feature: array-jsonb-storage, Property 4: isLiteral returns false for all non-literal types
test "msgpack_utils: isLiteral returns false for all non-literal types" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xCCCC_DDDD);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        // Generate a non-literal: arr, map, bin, or ext
        const tag = rand.intRangeAtMost(u8, 0, 3);
        const p: Payload = switch (tag) {
            0 => blk: {
                const elems = try allocator.alloc(Payload, 0);
                break :blk Payload{ .arr = elems };
            },
            1 => Payload.mapPayload(allocator),
            2 => try Payload.binToPayload(&[_]u8{0x01}, allocator),
            else => try Payload.extToPayload(1, &[_]u8{0x01}, allocator),
        };
        defer p.free(allocator);
        try testing.expect(!msgpack_utils.isLiteral(p));
    }
}

// Feature: array-jsonb-storage, Property 5: ensureLiteralArray accepts literal arrays and rejects non-arrays
test "msgpack_utils: ensureLiteralArray accepts literal arrays and rejects non-arrays" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xEEEE_FFFF);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        // (a) literal arrays → no error
        {
            const p = try genLiteralArray(rand, allocator);
            defer p.free(allocator);
            try msgpack_utils.ensureLiteralArray(p);
        }

        // (b) non-array payloads → NotAnArray
        {
            const p = try genLiteralPayload(rand, allocator);
            defer p.free(allocator);
            try testing.expectError(error.NotAnArray, msgpack_utils.ensureLiteralArray(p));
        }

        // (c) array with at least one non-literal element → NonLiteralElement
        {
            const inner = try allocator.alloc(Payload, 0);
            const elems = try allocator.alloc(Payload, 2);
            elems[0] = try genLiteralPayload(rand, allocator);
            elems[1] = Payload{ .arr = inner }; // non-literal
            const p = Payload{ .arr = elems };
            defer p.free(allocator);
            try testing.expectError(error.NonLiteralElement, msgpack_utils.ensureLiteralArray(p));
        }
    }
}

// Feature: array-jsonb-storage, Property 6: payloadToJson rejects non-literal-array payloads
test "msgpack_utils: payloadToJson rejects non-literal-array payloads" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1111_2222);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        // Non-array literal payload → NotAnArray
        const p = try genLiteralPayload(rand, allocator);
        defer p.free(allocator);
        try testing.expectError(error.NotAnArray, msgpack_utils.payloadToJson(p, allocator));
    }

    // Array with non-literal element → NonLiteralElement
    iter = 0;
    while (iter < 100) : (iter += 1) {
        const inner = try allocator.alloc(Payload, 0);
        const elems = try allocator.alloc(Payload, 1);
        elems[0] = Payload{ .arr = inner };
        const p = Payload{ .arr = elems };
        defer p.free(allocator);
        try testing.expectError(error.NonLiteralElement, msgpack_utils.payloadToJson(p, allocator));
    }
}

/// Compare two Payloads for round-trip equivalence through JSON.
/// JSON has no unsigned integer type, so .uint and .int are considered
/// equivalent when their numeric values match.
fn payloadsEqualRoundTrip(a: Payload, b: Payload) bool {
    // Normalize: treat uint/int as the same numeric kind for comparison
    const a_as_i64: ?i64 = switch (a) {
        .int => |v| v,
        .uint => |v| if (v <= std.math.maxInt(i64)) @intCast(v) else null,
        else => null,
    };
    const b_as_i64: ?i64 = switch (b) {
        .int => |v| v,
        .uint => |v| if (v <= std.math.maxInt(i64)) @intCast(v) else null,
        else => null,
    };
    if (a_as_i64 != null and b_as_i64 != null) {
        return a_as_i64.? == b_as_i64.?;
    }
    return payloadsEqual(a, b);
}

// Feature: array-jsonb-storage, Property 7: JSON round-trip for Literal_Arrays
test "msgpack_utils: JSON round-trip for Literal_Arrays" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x3333_4444);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const original = try genLiteralArray(rand, allocator);
        defer original.free(allocator);

        const json = try msgpack_utils.payloadToJson(original, allocator);
        defer allocator.free(json);

        const roundtripped = try msgpack_utils.jsonToPayload(json, allocator);
        defer roundtripped.free(allocator);

        // Structural equivalence: same length and same element values.
        // JSON has no unsigned integer type, so uint values come back as int —
        // use payloadsEqualRoundTrip which treats int/uint as equivalent.
        try testing.expectEqual(original.arr.len, roundtripped.arr.len);
        for (original.arr, roundtripped.arr) |orig_elem, rt_elem| {
            try testing.expect(payloadsEqualRoundTrip(orig_elem, rt_elem));
        }
    }
}

// Feature: array-jsonb-storage, Property 8: jsonToPayload rejects invalid JSON inputs
test "msgpack_utils: jsonToPayload rejects invalid JSON inputs" {
    const allocator = testing.allocator;

    // (a) Non-array JSON strings → error
    const non_array_jsons = [_][]const u8{
        "\"hello\"",
        "42",
        "true",
        "null",
        "{\"a\":1}",
        "3.14",
    };
    for (non_array_jsons) |json| {
        try testing.expectError(error.NotAnArray, msgpack_utils.jsonToPayload(json, allocator));
    }

    // (b) JSON arrays with object or nested array elements → NonLiteralElement
    const invalid_array_jsons = [_][]const u8{
        "[{\"a\":1}]",
        "[[1,2]]",
        "[1, {\"x\":2}]",
        "[[], 3]",
    };
    for (invalid_array_jsons) |json| {
        try testing.expectError(error.NonLiteralElement, msgpack_utils.jsonToPayload(json, allocator));
    }
}

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
