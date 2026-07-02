const std = @import("std");
const testing = std.testing;
const schema = @import("../schema.zig");
const msgpack = @import("../msgpack_utils.zig");
const mh = @import("../msgpack_test_helpers.zig");
const typed = @import("codec.zig");
const doc_id = @import("doc_id.zig");
const Value = @import("types.zig").Value;

test "Value: payload -> json array -> payload roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const roundtripJsonValue = struct {
        fn do(alloc: std.mem.Allocator, ft: schema.FieldType, items_type: ?schema.FieldType, tv: Value) !msgpack.Payload {
            const json_str = try typed.jsonAlloc(alloc, tv);
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
            defer parsed.deinit();
            const roundtripped = try typed.fromJson(alloc, ft, items_type, parsed.value);
            var out_list = std.ArrayListUnmanaged(u8).empty;
            defer out_list.deinit(alloc);
            try typed.writeMsgPack(roundtripped, out_list.writer(alloc));
            var reader: std.Io.Reader = .fixed(out_list.items);
            return try msgpack.decode(alloc, &reader);
        }
    }.do;

    // 1. Integer array — sorted/deduped by fromPayload
    {
        var arr = [_]msgpack.Payload{ .{ .int = 3 }, .{ .int = 1 }, .{ .int = 2 } };
        const tv = try typed.fromPayload(allocator, .array, .integer, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .integer, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 3), result.arr.len);
        try testing.expectEqual(@as(u64, 1), result.arr[0].uint);
        try testing.expectEqual(@as(u64, 2), result.arr[1].uint);
        try testing.expectEqual(@as(u64, 3), result.arr[2].uint);
    }

    // 2. Real array
    {
        var arr = [_]msgpack.Payload{ .{ .float = 2.5 }, .{ .float = 1.1 } };
        const tv = try typed.fromPayload(allocator, .array, .real, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .real, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 2), result.arr.len);
        try testing.expectEqual(@as(f64, 1.1), result.arr[0].float);
        try testing.expectEqual(@as(f64, 2.5), result.arr[1].float);
    }

    // 3. Text array
    {
        const s1 = try mh.anyToPayload(allocator, "banana");
        const s2 = try mh.anyToPayload(allocator, "apple");
        var arr = [_]msgpack.Payload{ s1, s2 };
        const tv = try typed.fromPayload(allocator, .array, .text, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .text, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 2), result.arr.len);
        try testing.expectEqualStrings("apple", result.arr[0].str.value());
        try testing.expectEqualStrings("banana", result.arr[1].str.value());
    }

    // 4. Boolean array
    {
        var arr = [_]msgpack.Payload{ .{ .bool = true }, .{ .bool = false } };
        const tv = try typed.fromPayload(allocator, .array, .boolean, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .boolean, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 2), result.arr.len);
        // Sorted: false < true
        try testing.expectEqual(false, result.arr[0].bool);
        try testing.expectEqual(true, result.arr[1].bool);
    }

    // 5. doc_id scalar — stringified as hex and parsed back
    {
        const original_id: u128 = 0x0123456789abcdef0123456789abcdef;
        const tv = Value{ .scalar = .{ .doc_id = original_id } };
        const result = try roundtripJsonValue(allocator, .doc_id, null, tv);

        try testing.expect(result == .bin);
        const expected_bytes = doc_id.toBytes(original_id);
        try testing.expectEqualSlices(u8, &expected_bytes, result.bin.value());
    }
}

test "validateValue: exhaustive type matrix" {
    const allocator = testing.allocator;
    const Ft = schema.FieldType;

    const bin_payload = try msgpack.Payload.binToPayload(&([_]u8{0} ** 16), allocator);
    defer bin_payload.free(allocator);
    const str_payload = try msgpack.Payload.strToPayload("abc", allocator);
    defer str_payload.free(allocator);

    const Case = struct { field: Ft, payload: msgpack.Payload, match: bool };
    const cases = [_]Case{
        // doc_id
        .{ .field = .doc_id, .payload = bin_payload, .match = true },
        .{ .field = .doc_id, .payload = str_payload, .match = false },
        .{ .field = .doc_id, .payload = .{ .int = 1 }, .match = false },
        .{ .field = .doc_id, .payload = .{ .uint = 1 }, .match = false },
        .{ .field = .doc_id, .payload = .{ .float = 1.0 }, .match = false },
        .{ .field = .doc_id, .payload = .{ .bool = true }, .match = false },
        .{ .field = .doc_id, .payload = .{ .arr = &.{} }, .match = false },

        // text
        .{ .field = .text, .payload = str_payload, .match = true },
        .{ .field = .text, .payload = bin_payload, .match = false },
        .{ .field = .text, .payload = .{ .int = 1 }, .match = false },
        .{ .field = .text, .payload = .{ .uint = 1 }, .match = false },
        .{ .field = .text, .payload = .{ .float = 1.0 }, .match = false },
        .{ .field = .text, .payload = .{ .bool = true }, .match = false },
        .{ .field = .text, .payload = .{ .arr = &.{} }, .match = false },

        // integer
        .{ .field = .integer, .payload = .{ .int = -1 }, .match = true },
        .{ .field = .integer, .payload = .{ .uint = 1 }, .match = true },
        .{ .field = .integer, .payload = str_payload, .match = false },
        .{ .field = .integer, .payload = bin_payload, .match = false },
        .{ .field = .integer, .payload = .{ .float = 1.0 }, .match = false },
        .{ .field = .integer, .payload = .{ .bool = true }, .match = false },
        .{ .field = .integer, .payload = .{ .arr = &.{} }, .match = false },

        // real
        .{ .field = .real, .payload = .{ .float = 1.0 }, .match = true },
        .{ .field = .real, .payload = .{ .int = 1 }, .match = true },
        .{ .field = .real, .payload = .{ .uint = 1 }, .match = true },
        .{ .field = .real, .payload = str_payload, .match = false },
        .{ .field = .real, .payload = bin_payload, .match = false },
        .{ .field = .real, .payload = .{ .bool = true }, .match = false },
        .{ .field = .real, .payload = .{ .arr = &.{} }, .match = false },

        // boolean
        .{ .field = .boolean, .payload = .{ .bool = true }, .match = true },
        .{ .field = .boolean, .payload = str_payload, .match = false },
        .{ .field = .boolean, .payload = bin_payload, .match = false },
        .{ .field = .boolean, .payload = .{ .int = 1 }, .match = false },
        .{ .field = .boolean, .payload = .{ .uint = 1 }, .match = false },
        .{ .field = .boolean, .payload = .{ .float = 1.0 }, .match = false },
        .{ .field = .boolean, .payload = .{ .arr = &.{} }, .match = false },

        // array
        .{ .field = .array, .payload = .{ .arr = &.{} }, .match = true },
        .{ .field = .array, .payload = str_payload, .match = false },
        .{ .field = .array, .payload = bin_payload, .match = false },
        .{ .field = .array, .payload = .{ .int = 1 }, .match = false },
        .{ .field = .array, .payload = .{ .uint = 1 }, .match = false },
        .{ .field = .array, .payload = .{ .float = 1.0 }, .match = false },
        .{ .field = .array, .payload = .{ .bool = true }, .match = false },
    };

    for (cases) |c| {
        const result = typed.validateValue(c.field, c.payload);
        if (c.match) {
            result catch |e| switch (e) {
                error.TypeMismatch => try testing.expect(false),
            };
        } else {
            try testing.expectError(error.TypeMismatch, result);
        }
    }
}

test "Value: scalar roundtrips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const roundtripMsgpack = struct {
        fn do(alloc: std.mem.Allocator, tv: Value) !msgpack.Payload {
            var out_list = std.ArrayListUnmanaged(u8).empty;
            defer out_list.deinit(alloc);
            try typed.writeMsgPack(tv, out_list.writer(alloc));
            var reader: std.Io.Reader = .fixed(out_list.items);
            return try msgpack.decode(alloc, &reader);
        }
    }.do;

    const roundtripJson = struct {
        fn do(alloc: std.mem.Allocator, ft: schema.FieldType, tv: Value) !Value {
            const json_str = try typed.jsonAlloc(alloc, tv);
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
            defer parsed.deinit();
            return try typed.fromJson(alloc, ft, null, parsed.value);
        }
    }.do;

    // Integer: positive, negative, zero
    {
        const cases = [_]i64{ 42, -42, 0 };
        for (cases) |v| {
            const tv = Value{ .scalar = .{ .integer = v } };
            const mp = try roundtripMsgpack(allocator, tv);
            try testing.expect(mp == .int or mp == .uint);
            if (v >= 0) {
                try testing.expectEqual(@as(u64, @intCast(v)), mp.uint);
            } else {
                try testing.expectEqual(@as(i64, v), mp.int);
            }
            const j = try roundtripJson(allocator, .integer, tv);
            try testing.expectEqual(@as(i64, v), j.scalar.integer);
        }
    }

    // Real: decimal preservation and scientific notation
    {
        const json100 = try typed.jsonAlloc(allocator, .{ .scalar = .{ .real = 100.0 } });
        defer allocator.free(json100);
        try testing.expectEqualStrings("100.0", json100);

        const cases = [_]struct { input: f64, json: []const u8 }{
            .{ .input = 3.14, .json = "3.14" },
            .{ .input = -2.5, .json = "-2.5" },
            .{ .input = 1e10, .json = "10000000000.0" },
        };
        for (cases) |c| {
            const tv = Value{ .scalar = .{ .real = c.input } };
            const mp = try roundtripMsgpack(allocator, tv);
            try testing.expectEqual(@as(f64, c.input), mp.float);
            const json_str = try typed.jsonAlloc(allocator, tv);
            defer allocator.free(json_str);
            try testing.expectEqualStrings(c.json, json_str);
            const j = try roundtripJson(allocator, .real, tv);
            try testing.expectEqual(@as(f64, c.input), j.scalar.real);
        }
    }

    // Text: normal, empty
    {
        const cases = [_][]const u8{ "hello", "" };
        for (cases) |v| {
            const owned = try allocator.dupe(u8, v);
            const tv = Value{ .scalar = .{ .text = owned } };
            const mp = try roundtripMsgpack(allocator, tv);
            try testing.expectEqualStrings(v, mp.str.value());
            const j = try roundtripJson(allocator, .text, tv);
            try testing.expectEqualStrings(v, j.scalar.text);
        }
    }

    // Boolean: true, false
    {
        const cases = [_]bool{ true, false };
        for (cases) |v| {
            const tv = Value{ .scalar = .{ .boolean = v } };
            const mp = try roundtripMsgpack(allocator, tv);
            try testing.expectEqual(v, mp.bool);
            const j = try roundtripJson(allocator, .boolean, tv);
            try testing.expectEqual(v, j.scalar.boolean);
        }
    }

    // doc_id: hex roundtrip
    {
        const id: u128 = 0x0123456789abcdef0123456789abcdef;
        const tv = Value{ .scalar = .{ .doc_id = id } };
        const mp = try roundtripMsgpack(allocator, tv);
        const expected = doc_id.toBytes(id);
        try testing.expectEqualSlices(u8, &expected, mp.bin.value());
        const json_str = try typed.jsonAlloc(allocator, tv);
        defer allocator.free(json_str);
        try testing.expectEqual(@as(usize, 34), json_str.len);
        const j = try roundtripJson(allocator, .doc_id, tv);
        try testing.expectEqual(id, j.scalar.doc_id);
    }
}

test "fromDynamicJson: all scalar paths and error cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1. String -> text scalar
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "\"hello\"", .{});
        defer parsed.deinit();
        const result = try typed.fromDynamicJson(allocator, parsed.value);
        try testing.expect(result == .scalar);
        try testing.expectEqualStrings("hello", result.scalar.text);
    }

    // 2. Integer -> integer scalar
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "42", .{});
        defer parsed.deinit();
        const result = try typed.fromDynamicJson(allocator, parsed.value);
        try testing.expect(result == .scalar);
        try testing.expectEqual(@as(i64, 42), result.scalar.integer);
    }

    // 3. Float -> real scalar
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "3.14", .{});
        defer parsed.deinit();
        const result = try typed.fromDynamicJson(allocator, parsed.value);
        try testing.expect(result == .scalar);
        try testing.expectEqual(@as(f64, 3.14), result.scalar.real);
    }

    // 4. Bool -> boolean scalar
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "true", .{});
        defer parsed.deinit();
        const result = try typed.fromDynamicJson(allocator, parsed.value);
        try testing.expect(result == .scalar);
        try testing.expectEqual(true, result.scalar.boolean);
    }

    // 5. Array of mixed scalars
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[1, \"two\", 3.0, true]", .{});
        defer parsed.deinit();
        const result = try typed.fromDynamicJson(allocator, parsed.value);
        try testing.expect(result == .array);
        try testing.expectEqual(@as(usize, 4), result.array.len);
        try testing.expectEqual(@as(i64, 1), result.array[0].integer);
        try testing.expectEqualStrings("two", result.array[1].text);
        try testing.expectEqual(@as(f64, 3.0), result.array[2].real);
        try testing.expectEqual(true, result.array[3].boolean);
    }

    // 6. Error: null -> UnsupportedClaimType
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "null", .{});
        defer parsed.deinit();
        try testing.expectError(error.UnsupportedClaimType, typed.fromDynamicJson(allocator, parsed.value));
    }

    // 7. Error: object -> UnsupportedClaimType
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":1}", .{});
        defer parsed.deinit();
        try testing.expectError(error.UnsupportedClaimType, typed.fromDynamicJson(allocator, parsed.value));
    }

    // 8. Error: array with nested object -> InvalidClaimArrayElement
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[1, {\"a\":1}]", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidClaimArrayElement, typed.fromDynamicJson(allocator, parsed.value));
    }

    // 9. Error: array with null element -> InvalidClaimArrayElement
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[1, null]", .{});
        defer parsed.deinit();
        try testing.expectError(error.InvalidClaimArrayElement, typed.fromDynamicJson(allocator, parsed.value));
    }

    // 10. Error: array with > 1000 elements -> ClaimArrayTooLarge
    {
        var buf: [12000]u8 = undefined;
        buf[0] = '[';
        var pos: usize = 1;
        var i: usize = 0;
        while (i < 1001) : (i += 1) {
            if (i > 0) {
                buf[pos] = ',';
                pos += 1;
            }
            buf[pos] = '1';
            pos += 1;
        }
        buf[pos] = ']';
        pos += 1;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf[0..pos], .{});
        defer parsed.deinit();
        try testing.expectError(error.ClaimArrayTooLarge, typed.fromDynamicJson(allocator, parsed.value));
    }
}

test "Value: array dedup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var arr = [_]msgpack.Payload{ .{ .int = 5 }, .{ .int = 5 }, .{ .int = 5 } };
    const tv = try typed.fromPayload(allocator, .array, .integer, .{ .arr = arr[0..] });
    try testing.expect(tv == .array);
    try testing.expectEqual(@as(usize, 1), tv.array.len);
    try testing.expectEqual(@as(i64, 5), tv.array[0].integer);
}
