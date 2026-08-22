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
    try std.testing.expectEqual(@as(?f64, 18.0), age.constraints.?.minimum);
    try std.testing.expectEqual(@as(?f64, 120.0), age.constraints.?.maximum);
}
