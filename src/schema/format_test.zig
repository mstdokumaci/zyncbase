const std = @import("std");
const schema_parse = @import("parse.zig");
const schema_format = @import("format.zig");

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
