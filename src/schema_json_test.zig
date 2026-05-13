const std = @import("std");
const schema = @import("schema.zig");

test "schema_json: rejects malformed root shape" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidSchema, schema.initSchema(allocator, "[]"));
}

test "schema_json: validates root version and store" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingVersion, schema.initSchema(allocator,
        \\{"store":{}}
    ));
    try std.testing.expectError(error.InvalidVersion, schema.initSchema(allocator,
        \\{"version":1,"store":{}}
    ));
    try std.testing.expectError(error.MissingStore, schema.initSchema(allocator,
        \\{"version":"1.0.0"}
    ));
    try std.testing.expectError(error.InvalidStore, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":[]}
    ));
}

test "schema_json: preserves allowed metadata objects" {
    const allocator = std.testing.allocator;

    var parsed = try schema.initSchema(allocator,
        \\{
        \\  "version":"1.0.0",
        \\  "metadata":{"owner":"core"},
        \\  "store":{
        \\    "posts":{
        \\      "metadata":{"displayName":"Posts"},
        \\      "fields":{
        \\        "title":{"type":"string","metadata":{"ui":{"widget":"textarea"}}}
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.metadata != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.metadata.?.json, "\"owner\":\"core\"") != null);

    const posts = parsed.table("posts") orelse return error.TestExpectedValue;
    try std.testing.expect(posts.metadata != null);
    try std.testing.expect(std.mem.indexOf(u8, posts.metadata.?.json, "\"displayName\":\"Posts\"") != null);

    const title = posts.field("title") orelse return error.TestExpectedValue;
    try std.testing.expect(title.metadata != null);
    try std.testing.expect(std.mem.indexOf(u8, title.metadata.?.json, "\"widget\":\"textarea\"") != null);
}

test "schema_json: rejects non-object metadata" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidMetadata, schema.initSchema(allocator,
        \\{"version":"1.0.0","metadata":"core","store":{}}
    ));
    try std.testing.expectError(error.InvalidMetadata, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"metadata":true,"fields":{}}}}
    ));
    try std.testing.expectError(error.InvalidMetadata, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string","metadata":[]}}}}}
    ));
}

test "schema_json: rejects unknown keys outside extension points" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.UnknownSchemaKey, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{},"owner":"core"}
    ));
    try std.testing.expectError(error.UnknownSchemaKey, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{},"description":"bad"}}}
    ));
    try std.testing.expectError(error.UnknownSchemaKey, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string","nullable":false}}}}}
    ));
}

test "schema_json: accepts planned constraint keys without enforcement" {
    const allocator = std.testing.allocator;

    var parsed = try schema.initSchema(allocator,
        \\{
        \\  "version":"1.0.0",
        \\  "store":{
        \\    "posts":{
        \\      "fields":{
        \\        "title":{
        \\          "type":"string",
        \\          "enum":["a","b"],
        \\          "pattern":"^[a-z]+$",
        \\          "format":"email",
        \\          "minLength":1,
        \\          "maxLength":30,
        \\          "minimum":0,
        \\          "maximum":100
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer parsed.deinit();

    const posts = parsed.table("posts") orelse return error.TestExpectedValue;
    try std.testing.expect(posts.field("title") != null);
}
