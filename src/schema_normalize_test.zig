const std = @import("std");
const schema = @import("schema.zig");
const schema_helpers = @import("schema_test_helpers.zig");

test "schema_normalize: implicit users is canonical first table" {
    const allocator = std.testing.allocator;

    var parsed = try schema.initSchema(allocator,
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

test "schema_normalize: explicit users moves to canonical first table" {
    const allocator = std.testing.allocator;

    var parsed = try schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{}},"users":{"namespaced":true,"fields":{"name":{"type":"string"}}}}}
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("users", parsed.tables[0].name);
    try std.testing.expect(parsed.tables[0].namespaced);
    try std.testing.expectEqual(@as(usize, 0), parsed.tables[0].index);
    try std.testing.expectEqual(@as(usize, 1), parsed.table("posts").?.index);
}

test "schema_normalize: builds canonical field order and user range" {
    const allocator = std.testing.allocator;

    var parsed = try schema.initSchema(allocator,
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

test "schema_normalize: users external_id is internal only" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.ReservedFieldName, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"users":{"fields":{"external_id":{"type":"string"}}}}}
    ));

    var parsed = try schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"users":{"fields":{"name":{"type":"string"}}}}}
    );
    defer parsed.deinit();

    const users = parsed.table("users") orelse return error.TestExpectedValue;
    try std.testing.expect(users.field("external_id") == null);
    try std.testing.expect(users.fieldIndex("external_id") == null);
}

test "schema_normalize: rejects reserved names and internal table prefix" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidTableName, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"_zync_shadow":{"fields":{}}}}
    ));
    try std.testing.expectError(error.InvalidTableName, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"bad__name":{"fields":{}}}}
    ));
    try std.testing.expectError(error.InvalidFieldName, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"bad__name":{"type":"string"}}}}}
    ));
    try std.testing.expectError(error.ReservedFieldName, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"created_at":{"type":"integer"}}}}}
    ));
}

test "schema_normalize: flattens nested fields and resolves required leaves" {
    const allocator = std.testing.allocator;

    var parsed = try schema.initSchema(allocator,
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

test "schema_normalize: rejects object-level and missing required paths" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidRequiredField, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"profiles":{"required":["profile"],"fields":{"profile":{"type":"object","fields":{"name":{"type":"string"}}}}}}}
    ));
    try std.testing.expectError(error.InvalidRequiredField, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"profiles":{"required":["missing"],"fields":{"name":{"type":"string"}}}}}
    ));
}

test "schema_normalize: validates array items" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingArrayItems, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array"}}}}}
    ));
    try std.testing.expectError(error.UnsupportedArrayItemsType, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array","items":"array"}}}}}
    ));

    var parsed = try schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array","items":"string"}}}}}
    );
    defer parsed.deinit();

    const tags = parsed.table("posts").?.field("tags") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(schema.FieldType.array, tags.declared_type);
    try std.testing.expectEqual(schema.StorageType.array, tags.storage_type);
    try std.testing.expectEqual(schema.FieldType.text, tags.items_type.?);
}

test "schema_normalize: validates references and on delete rules" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidReference, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"author_id":{"type":"string","references":"missing"}}}}}
    ));
    try std.testing.expectError(error.InvalidFieldType, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"author_id":{"type":"integer","references":"users"}}}}}
    ));
    try std.testing.expectError(error.InvalidOnDelete, schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"required":["author_id"],"fields":{"author_id":{"type":"string","references":"users","onDelete":"set_null"}}}}}
    ));

    var parsed = try schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"author_id":{"type":"string","references":"users"}}}}}
    );
    defer parsed.deinit();

    const author_id = parsed.table("posts").?.field("author_id") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(schema.FieldType.text, author_id.declared_type);
    try std.testing.expectEqual(schema.StorageType.doc_id, author_id.storage_type);
    try std.testing.expectEqual(schema.OnDelete.restrict, author_id.on_delete.?);
}
