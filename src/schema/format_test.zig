const std = @import("std");

const schema_format = @import("format.zig");
const schema_parse = @import("parse.zig");
const types = @import("types.zig");

test "schema_property: format round trip preserves normalized structure" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{"version":"1.0.0","store":{"posts":{"required":["profile.name"],"fields":{"profile":{"type":"object","fields":{"name":{"type":"string"},"age":{"type":"integer"}}},"tags":{"type":"array","items":"string"}}}}}
    ;

    var parsed = try schema_parse.initFromJson(allocator, json_text);
    defer parsed.deinit();

    const formatted = try schema_format.format(allocator, &parsed);
    defer allocator.free(formatted);

    var reparsed = try schema_parse.initFromJson(allocator, formatted);
    defer reparsed.deinit();

    const posts = reparsed.table("posts") orelse return error.TestExpectedValue;
    try std.testing.expect(posts.field("profile__name") != null);
    try std.testing.expect(posts.field("profile__age") != null);
    try std.testing.expect(posts.field("tags") != null);
}

test "schema_property: format round trip preserves constraints" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{"version":"1.0.0","store":{"users":{"fields":{"age":{"maximum":120,"minimum":18,"type":"integer"},"code":{"pattern":"^[A-Z]{3}$","type":"string"},"email":{"format":"email","type":"string"},"status":{"enum":["active","idle"],"type":"string"},"username":{"maxLength":10,"minLength":3,"type":"string"}}}}}
    ;

    var parsed = try schema_parse.initFromJson(allocator, json_text);
    defer parsed.deinit();

    const formatted = try schema_format.format(allocator, &parsed);
    defer allocator.free(formatted);

    var reparsed = try schema_parse.initFromJson(allocator, formatted);
    defer reparsed.deinit();

    const users = reparsed.table("users") orelse return error.TestExpectedValue;
    const status = users.field("status") orelse return error.TestExpectedValue;
    try std.testing.expect(status.constraints != null);
    try std.testing.expectEqual(@as(usize, 2), status.constraints.?.enum_values.?.len);

    const email = users.field("email") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(types.Constraints.Format.email, email.constraints.?.format.?);

    const code = users.field("code") orelse return error.TestExpectedValue;
    try std.testing.expectEqualStrings("^[A-Z]{3}$", code.constraints.?.pattern_source.?);

    const username = users.field("username") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(?u64, 3), username.constraints.?.min_length);
    try std.testing.expectEqual(@as(?u64, 10), username.constraints.?.max_length);

    const age = users.field("age") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(?types.Constraints.Bound, .{ .integer = 18 }), age.constraints.?.minimum);
    try std.testing.expectEqual(@as(?types.Constraints.Bound, .{ .integer = 120 }), age.constraints.?.maximum);
}

test "schema_property: format round trip preserves unique constraints" {
    const allocator = std.testing.allocator;

    const json_text =
        \\{"version":"1.1.0","store":{"projects":{
        \\  "required":["slug"],
        \\  "unique":[["slug"],["provider","externalId"],["profile.handle"]],
        \\  "fields":{
        \\    "slug":{"type":"string"},
        \\    "provider":{"type":"string"},
        \\    "externalId":{"type":"string"},
        \\    "profile":{"type":"object","fields":{"handle":{"type":"string"}}}
        \\  }
        \\}}}
    ;

    var parsed = try schema_parse.initFromJson(allocator, json_text);
    defer parsed.deinit();

    const formatted = try schema_format.format(allocator, &parsed);
    defer allocator.free(formatted);

    // unique is emitted after required and before fields, as a well-formed
    // array of arrays with preserved order.
    const expected_fragment = "\"required\":[\"slug\"],\"unique\":[[\"slug\"],[\"provider\",\"externalId\"],[\"profile.handle\"]],\"fields\":";
    if (std.mem.indexOf(u8, formatted, expected_fragment) == null) {
        std.debug.print("formatted schema was:\n{s}\n", .{formatted});
    }
    try std.testing.expect(std.mem.indexOf(u8, formatted, expected_fragment) != null);

    var reparsed = try schema_parse.initFromJson(allocator, formatted);
    defer reparsed.deinit();

    // Round-trip again: second formatting must be byte-identical.
    const reformatted = try schema_format.format(allocator, &reparsed);
    defer allocator.free(reformatted);
    try std.testing.expectEqualStrings(formatted, reformatted);

    const original = (parsed.table("projects") orelse return error.TestExpectedValue).unique_constraints;
    const round_tripped = (reparsed.table("projects") orelse return error.TestExpectedValue).unique_constraints;
    try std.testing.expectEqual(original.len, round_tripped.len);
    for (original, round_tripped) |a, b| {
        try std.testing.expectEqual(a.field_indexes.len, b.field_indexes.len);
        for (a.field_indexes, b.field_indexes) |ai, bi| try std.testing.expectEqual(ai, bi);
    }

    // Empty constraints omit the property entirely.
    var plain = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string"}}}}}
    );
    defer plain.deinit();
    const plain_formatted = try schema_format.format(allocator, &plain);
    defer allocator.free(plain_formatted);
    try std.testing.expect(std.mem.indexOf(u8, plain_formatted, "\"unique\"") == null);
}
