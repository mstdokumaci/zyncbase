const std = @import("std");
const schema_parse = @import("parse.zig");
const schema_types = @import("types.zig");
const schema_helpers = @import("test_helpers.zig");

test "schema_parse: rejects malformed root shape" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidSchema, schema_parse.initFromJson(allocator, "[]"));
}

test "schema_parse: validates root version and store" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingVersion, schema_parse.initFromJson(allocator,
        \\{"store":{}}
    ));
    try std.testing.expectError(error.InvalidVersion, schema_parse.initFromJson(allocator,
        \\{"version":1,"store":{}}
    ));
    try std.testing.expectError(error.MissingStore, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0"}
    ));
    try std.testing.expectError(error.InvalidStore, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":[]}
    ));
}

test "schema_parse: preserves allowed metadata objects" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
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

test "schema_parse: rejects non-object metadata" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidMetadata, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","metadata":"core","store":{}}
    ));
    try std.testing.expectError(error.InvalidMetadata, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"metadata":true,"fields":{}}}}
    ));
    try std.testing.expectError(error.InvalidMetadata, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string","metadata":[]}}}}}
    ));
}

test "schema_parse: rejects unknown keys outside extension points" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.UnknownSchemaKey, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{},"owner":"core"}
    ));
    try std.testing.expectError(error.UnknownSchemaKey, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{},"description":"bad"}}}
    ));
    try std.testing.expectError(error.UnknownSchemaKey, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string","nullable":false}}}}}
    ));
}

test "schema_parse: accepts planned constraint keys without enforcement" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
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

test "schema_parse: implicit users is canonical first table" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{}},"comments":{"fields":{}}}}
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.tables.len);
    try std.testing.expectEqualStrings("users", parsed.tables[0].name);
    try std.testing.expectEqualStrings("posts", parsed.tables[1].name);
    try std.testing.expectEqualStrings("comments", parsed.tables[2].name);
    try std.testing.expect(!parsed.tables[0].namespaced);
    try std.testing.expect(parsed.tables[1].namespaced);
}

test "schema_parse: explicit users moves to canonical first table" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{}},"users":{"namespaced":true,"fields":{"name":{"type":"string"}}}}}
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("users", parsed.tables[0].name);
    try std.testing.expect(parsed.tables[0].namespaced);
    try std.testing.expectEqual(@as(usize, 0), parsed.tables[0].index);
    try std.testing.expectEqual(@as(usize, 1), parsed.table("posts").?.index);
}

test "schema_parse: builds canonical field order and user range" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"tasks":{"fields":{"title":{"type":"string"},"done":{"type":"boolean"}}}}}
    );
    defer parsed.deinit();

    const tasks = parsed.table("tasks") orelse return error.TestExpectedValue;
    try std.testing.expectEqualStrings("id", tasks.fields[0].name);
    try std.testing.expectEqualStrings("namespace_id", tasks.fields[1].name);
    try std.testing.expectEqualStrings("owner_id", tasks.fields[2].name);
    try std.testing.expectEqualStrings("title", tasks.fields[3].name);
    try std.testing.expectEqualStrings("done", tasks.fields[4].name);
    try std.testing.expectEqualStrings("created_at", tasks.fields[5].name);
    try std.testing.expectEqualStrings("updated_at", tasks.fields[6].name);
    try std.testing.expectEqual(@as(usize, 2), tasks.userFields().len);
    try std.testing.expect(schema_helpers.isClientWritableFieldIndex(tasks, 3));
    try std.testing.expect(!schema_helpers.isClientWritableFieldIndex(tasks, 0));
    try std.testing.expect(!schema_helpers.isClientWritableFieldIndex(tasks, 6));
}

test "schema_parse: users external_id is internal only" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.ReservedFieldName, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"users":{"fields":{"external_id":{"type":"string"}}}}}
    ));

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"users":{"fields":{"name":{"type":"string"}}}}}
    );
    defer parsed.deinit();

    const users = parsed.table("users") orelse return error.TestExpectedValue;
    try std.testing.expect(users.field("external_id") == null);
    try std.testing.expect(users.fieldIndex("external_id") == null);
}

test "schema_parse: rejects reserved names and internal table prefix" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidTableName, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"_zync_shadow":{"fields":{}}}}
    ));
    try std.testing.expectError(error.InvalidTableName, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"bad__name":{"fields":{}}}}
    ));
    try std.testing.expectError(error.InvalidFieldName, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"bad__name":{"type":"string"}}}}}
    ));
    try std.testing.expectError(error.ReservedFieldName, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"created_at":{"type":"integer"}}}}}
    ));
}

test "schema_parse: flattens nested fields and resolves required leaves" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{
        \\  "version":"1.0.0",
        \\  "store":{
        \\    "profiles":{
        \\      "required":["profile.name"],
        \\      "fields":{
        \\        "profile":{"type":"object","fields":{"name":{"type":"string"},"age":{"type":"integer"}}}
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer parsed.deinit();

    const profiles = parsed.table("profiles") orelse return error.TestExpectedValue;
    const name = profiles.field("profile__name") orelse return error.TestExpectedValue;
    const age = profiles.field("profile__age") orelse return error.TestExpectedValue;
    try std.testing.expect(name.required);
    try std.testing.expect(!age.required);
}

test "schema_parse: rejects object-level and missing required paths" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidRequiredField, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"profiles":{"required":["profile"],"fields":{"profile":{"type":"object","fields":{"name":{"type":"string"}}}}}}}
    ));
    try std.testing.expectError(error.InvalidRequiredField, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"profiles":{"required":["missing"],"fields":{"name":{"type":"string"}}}}}
    ));
}

test "schema_parse: validates array items" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingArrayItems, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array"}}}}}
    ));
    try std.testing.expectError(error.UnsupportedArrayItemsType, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array","items":"array"}}}}}
    ));

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array","items":"string"}}}}}
    );
    defer parsed.deinit();

    const tags = parsed.table("posts").?.field("tags") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(schema_types.FieldType.array, tags.declared_type);
    try std.testing.expectEqual(schema_types.StorageType.array, tags.storage_type);
    try std.testing.expectEqual(schema_types.FieldType.text, tags.items_type.?);
}

test "schema_parse: validates references and on delete rules" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidReference, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"author_id":{"type":"string","references":"missing"}}}}}
    ));
    try std.testing.expectError(error.InvalidFieldType, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"author_id":{"type":"integer","references":"users"}}}}}
    ));
    try std.testing.expectError(error.InvalidOnDelete, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"required":["author_id"],"fields":{"author_id":{"type":"string","references":"users","onDelete":"set_null"}}}}}
    ));

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"author_id":{"type":"string","references":"users"}}}}}
    );
    defer parsed.deinit();

    const author_id = parsed.table("posts").?.field("author_id") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(schema_types.FieldType.text, author_id.declared_type);
    try std.testing.expectEqual(schema_types.StorageType.doc_id, author_id.storage_type);
    try std.testing.expectEqual(schema_types.OnDelete.restrict, author_id.on_delete.?);
}

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

        var parsed = try schema_parse.initFromJson(allocator, json_text);
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
        try std.testing.expectError(error.InvalidTableName, schema_parse.initFromJson(allocator, table_json));

        if (name.len == 0) continue;
        const field_json = try std.fmt.allocPrint(
            allocator,
            "{{\"version\":\"1.0.0\",\"store\":{{\"posts\":{{\"fields\":{{\"{s}\":{{\"type\":\"string\"}}}}}}}}}}",
            .{name},
        );
        defer allocator.free(field_json);
        try std.testing.expectError(error.InvalidFieldName, schema_parse.initFromJson(allocator, field_json));
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
        var parsed = try schema_parse.initFromJson(allocator, json_text);
        defer parsed.deinit();

        const table = parsed.table("t") orelse return error.TestExpectedValue;
        for (table.userFields()) |f| {
            try std.testing.expect(std.mem.indexOf(u8, f.name, ".") == null);
            try std.testing.expect(std.mem.indexOf(u8, f.name, "__") != null or std.mem.eql(u8, f.name, "z"));
        }
    }
}
