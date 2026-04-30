const std = @import("std");
const schema = @import("schema.zig");

test "schema_property: generated valid identifiers survive normalization" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const names = [_][]const u8{ "alpha", "beta_1", "Gamma2", "delta_value", "epsilon" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const table_name = names[random.intRangeAtMost(usize, 0, names.len - 1)];
        const field_name = names[random.intRangeAtMost(usize, 0, names.len - 1)];

        const json_text = try std.fmt.allocPrint(
            allocator,
            "{{\"version\":\"1.0.0\",\"store\":{{\"{s}\":{{\"fields\":{{\"{s}\":{{\"type\":\"string\"}}}}}}}}}}",
            .{ table_name, field_name },
        );
        defer allocator.free(json_text);

        var parsed = try schema.Schema.init(allocator, json_text);
        defer parsed.deinit();

        const table = parsed.table(table_name) orelse return error.TestExpectedValue;
        try std.testing.expect(table.field(field_name) != null);
    }
}

test "schema_property: generated invalid identifiers fail" {
    const allocator = std.testing.allocator;

    const invalid_names = [_][]const u8{ "", "1bad", "bad-name", "bad.name", "bad__name" };

    for (invalid_names) |name| {
        const table_json = try std.fmt.allocPrint(
            allocator,
            "{{\"version\":\"1.0.0\",\"store\":{{\"{s}\":{{\"fields\":{{}}}}}}}}",
            .{name},
        );
        defer allocator.free(table_json);
        try std.testing.expectError(error.InvalidTableName, schema.Schema.init(allocator, table_json));

        if (name.len == 0) continue;
        const field_json = try std.fmt.allocPrint(
            allocator,
            "{{\"version\":\"1.0.0\",\"store\":{{\"posts\":{{\"fields\":{{\"{s}\":{{\"type\":\"string\"}}}}}}}}}}",
            .{name},
        );
        defer allocator.free(field_json);
        try std.testing.expectError(error.InvalidFieldName, schema.Schema.init(allocator, field_json));
    }
}

test "schema_property: nested flattening uses only internal separator" {
    const allocator = std.testing.allocator;

    const cases = [_][]const u8{
        \\{"version":"1.0.0","store":{"t":{"fields":{"addr":{"type":"object","fields":{"city":{"type":"string"}}}}}}}
        ,
        \\{"version":"1.0.0","store":{"t":{"fields":{"a":{"type":"object","fields":{"b":{"type":"object","fields":{"c":{"type":"integer"}}}}}}}}}
        ,
        \\{"version":"1.0.0","store":{"t":{"fields":{"x":{"type":"object","fields":{"y":{"type":"string"}}},"z":{"type":"boolean"}}}}}
        ,
    };

    for (cases) |json_text| {
        var parsed = try schema.Schema.init(allocator, json_text);
        defer parsed.deinit();

        const table = parsed.table("t") orelse return error.TestExpectedValue;
        for (table.userFields()) |f| {
            try std.testing.expect(std.mem.indexOf(u8, f.name, ".") == null);
            try std.testing.expect(std.mem.indexOf(u8, f.name, "__") != null or std.mem.eql(u8, f.name, "z"));
        }
    }
}

test "schema_property: format round trip preserves normalized structure" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{"version":"1.0.0","store":{"posts":{"required":["profile.name"],"fields":{"profile":{"type":"object","fields":{"name":{"type":"string"},"age":{"type":"integer"}}},"tags":{"type":"array","items":"string"}}}}}
    ;

    var parsed = try schema.Schema.init(allocator, json_text);
    defer parsed.deinit();

    const formatted = try parsed.format(allocator);
    defer allocator.free(formatted);

    var reparsed = try schema.Schema.init(allocator, formatted);
    defer reparsed.deinit();

    const posts = reparsed.table("posts") orelse return error.TestExpectedValue;
    try std.testing.expect(posts.field("profile__name") != null);
    try std.testing.expect(posts.field("profile__age") != null);
    try std.testing.expect(posts.field("tags") != null);
}
