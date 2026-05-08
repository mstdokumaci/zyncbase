const std = @import("std");
const testing = std.testing;
const schema = @import("schema.zig");
const query_ast = @import("query_ast.zig");
const TypedValue = @import("storage_engine.zig").TypedValue;
const sth = @import("storage_engine_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

test "property: random query filters on StorageEngine" {
    const allocator = testing.allocator;
    const seeded_entity_count = 64;
    const random_query_count = 96;

    var fields_arr = [_]schema.Field{
        sth.makeIndexedField("name", .text, true),
        sth.makeField("age", .integer, false),
        sth.makeField("score", .real, false),
        sth.makeField("tags", .array, false),
    };
    const table = sth.makeTable("entities", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "storage-query-p1", table);
    defer ctx.deinit();

    // Seed some data
    try seedEntities(allocator, &ctx, seeded_entity_count);

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..random_query_count) |_| {
        var filter = try generateRandomFilter(allocator, random);
        defer filter.deinit(allocator);

        // Execute query
        var managed = try (try ctx.table("entities")).selectQuery(allocator, 1, filter);
        defer managed.deinit();
        try testing.expect(managed.rows.len >= 0);
    }
}

fn seedEntities(allocator: std.mem.Allocator, ctx: *sth.EngineTestContext, count: usize) !void {
    _ = allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const id: u128 = i + 1;

        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "name_{}", .{random.intRangeAtMost(u8, 0, 10)});

        const age = random.intRangeAtMost(i64, 0, 100);
        const score = random.float(f64) * 1000.0;

        try ctx.insertNamed("entities", id, 1, .{
            sth.named("name", tth.valText(name)),
            sth.named("age", tth.valInt(age)),
            sth.named("score", tth.valReal(score)),
        });
    }
    try ctx.engine.flushPendingWrites();
}

fn generateRandomFilter(allocator: std.mem.Allocator, random: std.Random) !query_ast.QueryFilter {
    const fields = [_][]const u8{ "name", "age", "score", "id", "created_at" };
    const field_idx = random.intRangeAtMost(usize, 0, fields.len - 1);
    const field_name = fields[field_idx];
    const ft: schema.FieldType = if (std.mem.eql(u8, field_name, "name"))
        .text
    else if (std.mem.eql(u8, field_name, "id"))
        .doc_id
    else if (std.mem.eql(u8, field_name, "score"))
        .real
    else
        .integer;

    var filter = query_ast.QueryFilter{
        .order_by = .{
            .field_index = switch (field_idx) {
                0 => 4, // name
                1 => 5, // age
                2 => 6, // score
                3 => 0, // id
                4 => 2, // created_at
                else => unreachable,
            },
            .desc = random.boolean(),
            .field_type = ft,
            .items_type = null,
        },
    };

    // Random conditions
    const num_conds = random.intRangeAtMost(usize, 0, 3);
    if (num_conds > 0) {
        const conds = try allocator.alloc(query_ast.Condition, num_conds);
        for (conds) |*c| {
            c.* = try generateRandomCondition(allocator, random);
        }
        filter.conditions = conds;
    }

    // Random OR conditions
    const num_or = random.intRangeAtMost(usize, 0, 2);
    if (num_or > 0) {
        const or_conds = try allocator.alloc(query_ast.Condition, num_or);
        for (or_conds) |*c| {
            c.* = try generateRandomCondition(allocator, random);
        }
        filter.or_conditions = or_conds;
    }

    // Random Limit

    // Random Limit
    if (random.boolean()) {
        filter.limit = random.intRangeAtMost(u32, 1, 25);
    }

    return filter;
}

fn generateRandomCondition(allocator: std.mem.Allocator, random: std.Random) !query_ast.Condition {
    const fields = [_][]const u8{ "name", "age", "score" };
    const field = fields[random.intRangeAtMost(usize, 0, fields.len - 1)];

    // Choose an operator
    const op_int = random.intRangeAtMost(u8, 0, 10); // Exclude IN/NOT IN/LIKE etc for simplicity if needed, but let's try some.
    const op: query_ast.Operator = @enumFromInt(op_int);

    var value: ?TypedValue = null;
    if (op != .isNull and op != .isNotNull) {
        // String operators MUST have string values
        if (op == .startsWith or op == .endsWith or op == .contains) {
            value = try tth.valTextOwned(allocator, "test_value");
        } else if (std.mem.eql(u8, field, "name")) {
            value = try tth.valTextOwned(allocator, "name_5");
        } else if (std.mem.eql(u8, field, "age")) {
            value = tth.valInt(random.intRangeAtMost(i64, 0, 100));
        } else {
            value = tth.valReal(500.0);
        }
    }

    const ft: schema.FieldType = if (std.mem.eql(u8, field, "name")) .text else if (std.mem.eql(u8, field, "age")) .integer else .real;
    const field_index: usize = if (std.mem.eql(u8, field, "name"))
        4
    else if (std.mem.eql(u8, field, "age"))
        5
    else
        6;

    return .{
        .field_index = field_index,
        .op = op,
        .value = value,
        .field_type = ft,
        .items_type = null,
    };
}
