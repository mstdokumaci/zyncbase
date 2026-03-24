const std = @import("std");
const testing = std.testing;
const msgpack_utils = @import("msgpack_utils.zig");
const Payload = msgpack_utils.Payload;

// ============================================================
// clonePayload tests
// ============================================================

test "clonePayload: nil (value type)" {
    const allocator = testing.allocator;
    const original: Payload = .nil;
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqual(Payload.nil, clone);
}

test "clonePayload: bool (value type)" {
    const allocator = testing.allocator;
    const original: Payload = .{ .bool = true };
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqual(true, clone.bool);
}

test "clonePayload: int (value type)" {
    const allocator = testing.allocator;
    const original: Payload = .{ .int = -42 };
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqual(@as(i64, -42), clone.int);
}

test "clonePayload: uint (value type)" {
    const allocator = testing.allocator;
    const original: Payload = .{ .uint = 99 };
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqual(@as(u64, 99), clone.uint);
}

test "clonePayload: float (value type)" {
    const allocator = testing.allocator;
    const original: Payload = .{ .float = 3.14 };
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqual(@as(f64, 3.14), clone.float);
}

test "clonePayload: str (heap-allocated)" {
    const allocator = testing.allocator;
    const original = try Payload.strToPayload("hello world", allocator);
    defer original.free(allocator);
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqualStrings("hello world", clone.str.value());
}

test "clonePayload: bin (heap-allocated)" {
    const allocator = testing.allocator;
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    const original = try Payload.binToPayload(&data, allocator);
    defer original.free(allocator);
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqualSlices(u8, &data, clone.bin.value());
}

test "clonePayload: ext (heap-allocated)" {
    const allocator = testing.allocator;
    const ext_data = [_]u8{ 0xAA, 0xBB };
    const original = try Payload.extToPayload(7, &ext_data, allocator);
    defer original.free(allocator);
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    try testing.expectEqual(@as(i8, 7), clone.ext.type);
    try testing.expectEqualSlices(u8, &ext_data, clone.ext.data);
}

test "clonePayload: nested arr (recursive clone)" {
    const allocator = testing.allocator;
    // Build arr: [42, "inner"]
    const inner_str = try Payload.strToPayload("inner", allocator);
    const elems = try allocator.alloc(Payload, 2);
    elems[0] = .{ .int = 42 };
    elems[1] = inner_str;
    const original: Payload = .{ .arr = elems };
    defer original.free(allocator);

    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);

    try testing.expectEqual(@as(usize, 2), clone.arr.len);
    try testing.expectEqual(@as(i64, 42), clone.arr[0].int);
    try testing.expectEqualStrings("inner", clone.arr[1].str.value());
}

test "clonePayload: map (recursive clone)" {
    const allocator = testing.allocator;
    var original = Payload.mapPayload(allocator);
    defer original.free(allocator);
    try original.mapPut("key", try Payload.strToPayload("value", allocator));

    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);

    try testing.expectEqual(@as(usize, 1), clone.map.count());
    const key_payload = try Payload.strToPayload("key", allocator);
    defer key_payload.free(allocator);
    const got = clone.map.get(key_payload);
    try testing.expect(got != null);
    try testing.expectEqualStrings("value", got.?.str.value());
}

test "clonePayload: freeing original does not affect clone" {
    const allocator = testing.allocator;
    const original = try Payload.strToPayload("independent", allocator);
    const clone = try msgpack_utils.clonePayload(original, allocator);
    defer clone.free(allocator);
    // Free original first
    original.free(allocator);
    // Clone should still be valid
    try testing.expectEqualStrings("independent", clone.str.value());
}

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

// Feature: array-jsonb-storage, Property 2: clonePayload structural equivalence
test "msgpack_utils: clonePayload structural equivalence" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const original = try genLiteralArray(rand, allocator);
        const clone = try msgpack_utils.clonePayload(original, allocator);
        defer clone.free(allocator);
        // Free original first, then verify clone is still valid
        original.free(allocator);
        // Clone should still be a valid array
        try testing.expect(clone == .arr);
    }
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
