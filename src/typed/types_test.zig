const std = @import("std");
const testing = std.testing;
const types = @import("types.zig");

const Value = types.Value;
const ScalarValue = types.ScalarValue;
const Record = types.Record;
const Cursor = types.Cursor;

test "Value: clone preserves eql and ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Scalar roundtrip: every variant
    {
        const cases = [_]Value{
            .{ .scalar = .{ .integer = 42 } },
            .{ .scalar = .{ .real = 3.14 } },
            .{ .scalar = .{ .boolean = true } },
            .{ .scalar = .{ .boolean = false } },
            .{ .scalar = .{ .doc_id = 0x0123456789abcdef0123456789abcdef } },
            .{ .scalar = .{ .text = try allocator.dupe(u8, "hello") } },
            .{ .scalar = .{ .text = try allocator.dupe(u8, "") } },
        };
        for (cases) |v| {
            const cloned = try v.clone(allocator);
            try testing.expect(v.eql(cloned));
            v.deinit(allocator);
            cloned.deinit(allocator);
        }
    }

    // Array roundtrip
    {
        const items = try allocator.alloc(ScalarValue, 3);
        items[0] = .{ .integer = 1 };
        items[1] = .{ .text = try allocator.dupe(u8, "two") };
        items[2] = .{ .boolean = true };
        const v = Value{ .array = items };

        const cloned = try v.clone(allocator);
        try testing.expect(v.eql(cloned));
        v.deinit(allocator);
        // Deinit clone independently — no double free
        cloned.deinit(allocator);
    }

    // Nil roundtrip
    {
        const v = Value{ .nil = {} };
        const cloned = try v.clone(allocator);
        try testing.expect(v.eql(cloned));
        v.deinit(allocator);
        cloned.deinit(allocator);
    }

    // Record clone roundtrip
    {
        const values = try allocator.alloc(Value, 2);
        values[0] = .{ .scalar = .{ .integer = 10 } };
        values[1] = .{ .scalar = .{ .text = try allocator.dupe(u8, "abc") } };
        const rec = Record{ .values = values };

        const cloned = try rec.clone(allocator);
        try testing.expectEqual(@as(usize, 2), cloned.values.len);
        try testing.expect(rec.values[0].eql(cloned.values[0]));
        try testing.expect(rec.values[1].eql(cloned.values[1]));
        rec.deinit(allocator);
        cloned.deinit(allocator);
    }

    // Cursor clone roundtrip
    {
        var cur = Cursor{
            .sort_value = .{ .scalar = .{ .integer = 99 } },
            .id = 0xaaa,
        };
        var cloned = try cur.clone(allocator);
        try testing.expect(cur.sort_value.eql(cloned.sort_value));
        try testing.expectEqual(cur.id, cloned.id);
        cur.deinit(allocator);
        cloned.deinit(allocator);
    }
}

test "Value: sortedSet invariant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Sort + dedup integers
    {
        const items = try allocator.alloc(ScalarValue, 5);
        items[0] = .{ .integer = 5 };
        items[1] = .{ .integer = 1 };
        items[2] = .{ .integer = 5 };
        items[3] = .{ .integer = 2 };
        items[4] = .{ .integer = 5 };
        var v = Value{ .array = items };
        try v.sortedSet(allocator);

        try testing.expectEqual(@as(usize, 3), v.array.len);
        try testing.expectEqual(@as(i64, 1), v.array[0].integer);
        try testing.expectEqual(@as(i64, 2), v.array[1].integer);
        try testing.expectEqual(@as(i64, 5), v.array[2].integer);
    }

    // Sort + dedup strings
    {
        const items = try allocator.alloc(ScalarValue, 3);
        items[0] = .{ .text = try allocator.dupe(u8, "cherry") };
        items[1] = .{ .text = try allocator.dupe(u8, "apple") };
        items[2] = .{ .text = try allocator.dupe(u8, "apple") };
        var v = Value{ .array = items };
        try v.sortedSet(allocator);

        try testing.expectEqual(@as(usize, 2), v.array.len);
        try testing.expectEqualStrings("apple", v.array[0].text);
        try testing.expectEqualStrings("cherry", v.array[1].text);
    }

    // Verify invariant: sorted + no dups
    {
        const items = try allocator.alloc(ScalarValue, 4);
        items[0] = .{ .integer = 3 };
        items[1] = .{ .integer = 1 };
        items[2] = .{ .integer = 2 };
        items[3] = .{ .integer = 1 };
        var v = Value{ .array = items };
        try v.sortedSet(allocator);

        for (0..v.array.len - 1) |i| {
            try testing.expect(v.array[i].order(v.array[i + 1]) == .lt);
        }
    }

    // Empty and single-element: no-op
    {
        var empty = Value{ .array = try allocator.alloc(ScalarValue, 0) };
        try empty.sortedSet(allocator);
        try testing.expectEqual(@as(usize, 0), empty.array.len);

        var single = Value{ .array = try allocator.alloc(ScalarValue, 1) };
        single.array[0] = .{ .integer = 42 };
        try single.sortedSet(allocator);
        try testing.expectEqual(@as(usize, 1), single.array.len);
        try testing.expectEqual(@as(i64, 42), single.array[0].integer);
    }
}
