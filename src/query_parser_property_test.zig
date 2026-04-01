const std = @import("std");
const query_parser = @import("query_parser.zig");
const msgpack = @import("msgpack_utils.zig");
const testing = std.testing;

test "property: random valid query filters" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..100) |_| {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);

        // Randomly decide which fields to include
        if (random.boolean()) {
            const num_conds = random.intRangeAtMost(usize, 0, 10);
            const conds_arr = try allocator.alloc(msgpack.Payload, num_conds);
            for (conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false);
            }
            try root.mapPut("conditions", .{ .arr = conds_arr });
        }

        if (random.boolean()) {
            const num_or_conds = random.intRangeAtMost(usize, 0, 5);
            const or_conds_arr = try allocator.alloc(msgpack.Payload, num_or_conds);
            for (or_conds_arr) |*c| {
                c.* = try generateRandomCondition(allocator, random, false);
            }
            try root.mapPut("orConditions", .{ .arr = or_conds_arr });
        }

        if (random.boolean()) {
            var order_arr = try allocator.alloc(msgpack.Payload, 2);
            order_arr[0] = try msgpack.Payload.strToPayload("field", allocator);
            order_arr[1] = msgpack.Payload.uintToPayload(if (random.boolean()) 1 else 0);
            try root.mapPut("orderBy", .{ .arr = order_arr });
        }

        if (random.boolean()) {
            try root.mapPut("limit", msgpack.Payload.uintToPayload(random.uintAtMost(u32, 1000)));
        }

        const filter = try query_parser.parseQueryFilter(allocator, root);
        filter.deinit(allocator);
    }
}

test "property: reject forbidden field names" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();

    for (0..50) |_| {
        var root = msgpack.Payload.mapPayload(allocator);
        defer root.free(allocator);

        var conds_arr = try allocator.alloc(msgpack.Payload, 1);
        conds_arr[0] = try generateRandomCondition(allocator, random, true);
        try root.mapPut("conditions", .{ .arr = conds_arr });

        const result = query_parser.parseQueryFilter(allocator, root);
        try testing.expectError(error.InvalidFieldName, result);
    }
}

fn generateRandomCondition(allocator: std.mem.Allocator, random: std.Random, force_bad_field: bool) !msgpack.Payload {
    const field = if (force_bad_field) "bad__field" else "good_field";
    const op_code = random.intRangeAtMost(u8, 0, 12);

    // isNull (11) and isNotNull (12) are special (2 elements)
    if (op_code >= 11) {
        var cond = try allocator.alloc(msgpack.Payload, 2);
        cond[0] = try msgpack.Payload.strToPayload(field, allocator);
        cond[1] = msgpack.Payload.uintToPayload(op_code);
        return .{ .arr = cond };
    } else {
        var cond = try allocator.alloc(msgpack.Payload, 3);
        cond[0] = try msgpack.Payload.strToPayload(field, allocator);
        cond[1] = msgpack.Payload.uintToPayload(op_code);
        cond[2] = msgpack.Payload.uintToPayload(42); // simple value for property test
        return .{ .arr = cond };
    }
}
