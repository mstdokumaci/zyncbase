const std = @import("std");
const msgpack_lib = @import("msgpack");
const message_handler = @import("message_handler.zig");
const parsePath = message_handler.parsePath;

// Feature: schema-aware-storage, Property 1: Path round-trip
// For any valid path array p of length >= 1 where every element is a string,
// routing p through parsePath and then reconstructing the canonical array from
// the resulting ParsedPath SHALL produce an array equal to p.
test "path round-trip: parsePath reconstructs original array" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const sample_strings = [_][]const u8{
        "users", "posts", "comments", "tags", "orders",
        "abc",   "xyz",   "foo",      "bar",  "baz",
    };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const length = rand.intRangeAtMost(usize, 1, 10);

        // Build a random string array
        const strings = try allocator.alloc([]const u8, length);
        defer allocator.free(strings);
        for (strings) |*s| {
            s.* = sample_strings[rand.intRangeAtMost(usize, 0, sample_strings.len - 1)];
        }

        // Build a msgpack array payload from the strings
        const arr_payload = try buildStrArrayPayload(allocator, strings);
        defer arr_payload.free(allocator);

        // Call parsePath
        const pp = try parsePath(allocator, arr_payload);
        defer if (pp == .field) allocator.free(pp.field.fields);

        // Reconstruct the canonical array from ParsedPath
        var reconstructed = try allocator.alloc([]const u8, length);
        defer allocator.free(reconstructed);

        switch (pp) {
            .collection => |c| {
                try std.testing.expectEqual(@as(usize, 1), length);
                reconstructed[0] = c.table;
            },
            .document => |d| {
                try std.testing.expectEqual(@as(usize, 2), length);
                reconstructed[0] = d.table;
                reconstructed[1] = d.id;
            },
            .field => |f| {
                try std.testing.expect(length >= 3);
                reconstructed[0] = f.table;
                reconstructed[1] = f.id;
                for (f.fields, 0..) |field, i| {
                    reconstructed[2 + i] = field;
                }
            },
        }

        // Assert reconstructed equals original
        for (strings, reconstructed) |orig, recon| {
            try std.testing.expectEqualStrings(orig, recon);
        }
    }
}

// Feature: schema-aware-storage, Property 2: Invalid path elements are rejected
// For any path array that contains at least one non-string element, or that is empty,
// parsePath SHALL return an InvalidPath error.
test "path invalid elements rejected: non-string or empty array returns error.InvalidPath" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        // Alternate between: empty array, array with integer, array with bool, mixed
        const variant = rand.intRangeAtMost(u8, 0, 3);

        const payload = switch (variant) {
            0 => blk: {
                // Empty array
                break :blk msgpack_lib.Payload{ .arr = &.{} };
            },
            1 => blk: {
                // Array with one integer element
                const elems = try allocator.alloc(msgpack_lib.Payload, 1);
                elems[0] = msgpack_lib.Payload{ .uint = 42 };
                break :blk msgpack_lib.Payload{ .arr = elems };
            },
            2 => blk: {
                // Array with a string then an integer
                const elems = try allocator.alloc(msgpack_lib.Payload, 2);
                elems[0] = try msgpack_lib.Payload.strToPayload("table", allocator);
                elems[1] = msgpack_lib.Payload{ .uint = 99 };
                break :blk msgpack_lib.Payload{ .arr = elems };
            },
            3 => blk: {
                // Array with a bool element
                const elems = try allocator.alloc(msgpack_lib.Payload, 1);
                elems[0] = msgpack_lib.Payload{ .bool = true };
                break :blk msgpack_lib.Payload{ .arr = elems };
            },
            else => unreachable,
        };

        // Free the payload after the test
        defer {
            switch (variant) {
                0 => {}, // static empty slice, nothing to free
                1 => {
                    allocator.free(payload.arr);
                },
                2 => {
                    payload.arr[0].free(allocator);
                    allocator.free(payload.arr);
                },
                3 => {
                    allocator.free(payload.arr);
                },
                else => unreachable,
            }
        }

        const result = parsePath(allocator, payload);
        try std.testing.expectError(error.InvalidPath, result);
    }

    // Also test: non-array payload (e.g. a string) returns InvalidPath
    {
        const str_payload = try msgpack_lib.Payload.strToPayload("not-an-array", allocator);
        defer str_payload.free(allocator);
        try std.testing.expectError(error.InvalidPath, parsePath(allocator, str_payload));
    }

    // Also test: integer payload returns InvalidPath
    {
        const int_payload = msgpack_lib.Payload{ .uint = 123 };
        try std.testing.expectError(error.InvalidPath, parsePath(allocator, int_payload));
    }
}

/// Build a msgpack array payload from a slice of strings.
/// Caller must call payload.free(allocator) when done.
fn buildStrArrayPayload(allocator: std.mem.Allocator, strings: []const []const u8) !msgpack_lib.Payload {
    const elems = try allocator.alloc(msgpack_lib.Payload, strings.len);
    errdefer allocator.free(elems);
    for (strings, 0..) |s, i| {
        elems[i] = try msgpack_lib.Payload.strToPayload(s, allocator);
    }
    return msgpack_lib.Payload{ .arr = elems };
}
