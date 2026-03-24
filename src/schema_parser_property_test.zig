const std = @import("std");
const schema_parser = @import("schema_parser.zig");
const SchemaParser = schema_parser.SchemaParser;

// Feature: schema-aware-storage, Property 3: Object field flattening
// For any schema field definition of type "object" with N properties,
// parse SHALL produce exactly N Field values named <parent>_<property>,
// none with type object.
test "schema_parser: object field flattening" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const property_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const n_props = rand.intRangeAtMost(usize, 1, 5);

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"version\":\"1.0.0\",\"store\":{\"t\":{\"fields\":{\"addr\":{\"type\":\"object\",\"properties\":{");
        for (0..n_props) |pi| {
            if (pi > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "\"{s}\":{{\"type\":\"string\"}}", .{property_names[pi]});
        }
        try buf.appendSlice(allocator, "}}}}}}");

        const schema = try parser.parse(buf.items);
        defer parser.deinit(schema);

        try std.testing.expectEqual(@as(usize, 1), schema.tables.len);
        const table = schema.tables[0];
        try std.testing.expectEqual(n_props, table.fields.len);

        for (0..n_props) |pi| {
            const expected = try std.fmt.allocPrint(allocator, "addr_{s}", .{property_names[pi]});
            defer allocator.free(expected);
            var found = false;
            for (table.fields) |f| {
                if (std.mem.eql(u8, f.name, expected)) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

// Feature: schema-aware-storage, Property 4: Unknown table-definition keys are tolerated
// For any schema JSON with extra unknown keys inside a table definition,
// parse SHALL succeed and produce the same Schema as without those keys.
test "schema_parser: unknown keys tolerated" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    var prng = std.Random.DefaultPrng.init(123);
    const rand = prng.random();

    const extra_keys = [_][]const u8{ "description", "deprecated", "meta", "x-custom", "tags" };
    const base_json =
        \\{"version":"1.0.0","store":{"items":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const n_extra = rand.intRangeAtMost(usize, 1, 3);

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"version\":\"1.0.0\",\"store\":{\"items\":{\"fields\":{\"title\":{\"type\":\"string\"}},\"required\":[\"title\"]");
        for (0..n_extra) |ei| {
            try buf.print(allocator, ",\"{s}\":\"ignored\"", .{extra_keys[ei % extra_keys.len]});
        }
        try buf.appendSlice(allocator, "}}}");

        const schema_base = try parser.parse(base_json);
        defer parser.deinit(schema_base);

        const schema_extra = try parser.parse(buf.items);
        defer parser.deinit(schema_extra);

        try std.testing.expectEqualStrings(schema_base.version, schema_extra.version);
        try std.testing.expectEqual(schema_base.tables.len, schema_extra.tables.len);
        for (schema_base.tables, schema_extra.tables) |tb, te| {
            try std.testing.expectEqualStrings(tb.name, te.name);
            try std.testing.expectEqual(tb.fields.len, te.fields.len);
            for (tb.fields, te.fields) |fb, fe| {
                try std.testing.expectEqualStrings(fb.name, fe.name);
                try std.testing.expectEqual(fb.sql_type, fe.sql_type);
                try std.testing.expectEqual(fb.required, fe.required);
            }
        }
    }
}

// Feature: schema-aware-storage, Property 5: Missing field type is rejected
// For any schema JSON with a field definition missing "type",
// parse SHALL return an error.
test "schema_parser: missing type rejected" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    var prng = std.Random.DefaultPrng.init(456);
    const rand = prng.random();

    const field_names = [_][]const u8{ "foo", "bar", "baz", "qux", "quux" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const fname = field_names[rand.intRangeAtMost(usize, 0, field_names.len - 1)];

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);

        try buf.print(
            allocator,
            "{{\"version\":\"1.0.0\",\"store\":{{\"t\":{{\"fields\":{{\"{s}\":{{\"indexed\":true}}}}}}}}}}",
            .{fname},
        );

        try std.testing.expectError(error.MissingFieldType, parser.parse(buf.items));
    }
}

// Feature: schema-aware-storage, Property 6: Schema parse/print round-trip
// For any valid schema JSON string s,
// parse(print(parse(s))) SHALL produce a Schema structurally equivalent to parse(s).
test "schema_parser: parse/print round-trip" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    var prng = std.Random.DefaultPrng.init(789);
    const rand = prng.random();

    const field_types = [_][]const u8{ "string", "integer", "number", "boolean", "array" };
    const table_names = [_][]const u8{ "users", "posts", "comments", "tags", "orders" };
    const field_names = [_][]const u8{ "id", "name", "value", "count", "active" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);

        const n_tables = rand.intRangeAtMost(usize, 1, 3);
        try buf.print(allocator, "{{\"version\":\"{d}.{d}.{d}\",\"store\":{{", .{
            rand.intRangeAtMost(u8, 0, 9),
            rand.intRangeAtMost(u8, 0, 9),
            rand.intRangeAtMost(u8, 0, 9),
        });

        for (0..n_tables) |ti| {
            if (ti > 0) try buf.append(allocator, ',');
            const n_fields = rand.intRangeAtMost(usize, 1, 3);
            try buf.print(allocator, "\"{s}\":{{\"fields\":{{", .{table_names[ti % table_names.len]});
            for (0..n_fields) |fi| {
                if (fi > 0) try buf.append(allocator, ',');
                try buf.print(allocator, "\"{s}\":{{\"type\":\"{s}\"}}", .{
                    field_names[fi % field_names.len],
                    field_types[rand.intRangeAtMost(usize, 0, field_types.len - 1)],
                });
            }
            try buf.appendSlice(allocator, "},\"required\":[]}");
        }
        try buf.appendSlice(allocator, "}}");

        const schema1 = try parser.parse(buf.items);
        defer parser.deinit(schema1);

        const printed = try parser.print(schema1);
        defer allocator.free(printed);

        const schema2 = try parser.parse(printed);
        defer parser.deinit(schema2);

        try std.testing.expectEqualStrings(schema1.version, schema2.version);
        try std.testing.expectEqual(schema1.tables.len, schema2.tables.len);
        for (schema1.tables, schema2.tables) |t1, t2| {
            try std.testing.expectEqualStrings(t1.name, t2.name);
            try std.testing.expectEqual(t1.fields.len, t2.fields.len);
            for (t1.fields, t2.fields) |f1, f2| {
                try std.testing.expectEqualStrings(f1.name, f2.name);
                try std.testing.expectEqual(f1.sql_type, f2.sql_type);
                try std.testing.expectEqual(f1.required, f2.required);
                try std.testing.expectEqual(f1.indexed, f2.indexed);
            }
        }
    }
}
