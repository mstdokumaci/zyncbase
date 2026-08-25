const std = @import("std");

const schema_parse = @import("parse.zig");
const schema_helpers = @import("test_helpers.zig");
const schema_types = @import("types.zig");

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

test "schema_parse: parses and stores constraint keywords" {
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
        \\          "maxLength":30
        \\        },
        \\        "score":{
        \\          "type":"integer",
        \\          "minimum":0,
        \\          "maximum":100
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "presence":{
        \\    "user":{
        \\      "status":{
        \\        "type":"string",
        \\        "enum":["active","idle","away"]
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer parsed.deinit();

    const posts = parsed.table("posts") orelse return error.TestExpectedValue;
    const title = posts.field("title") orelse return error.TestExpectedValue;
    try std.testing.expect(title.constraints != null);
    const tc = title.constraints.?;
    try std.testing.expect(tc.enum_values != null);
    try std.testing.expectEqual(@as(usize, 2), tc.enum_values.?.len);
    try std.testing.expectEqualStrings("a", tc.enum_values.?[0].text);
    try std.testing.expectEqualStrings("b", tc.enum_values.?[1].text);
    try std.testing.expectEqualStrings("^[a-z]+$", tc.pattern_source.?);
    try std.testing.expect(tc.compiled_regex != null);
    try std.testing.expectEqual(schema_types.Constraints.Format.email, tc.format.?);
    try std.testing.expectEqual(@as(?u64, 1), tc.min_length);
    try std.testing.expectEqual(@as(?u64, 30), tc.max_length);

    const score = posts.field("score") orelse return error.TestExpectedValue;
    try std.testing.expect(score.constraints != null);
    const sc = score.constraints.?;
    try std.testing.expectEqual(@as(?schema_types.Constraints.Bound, .{ .integer = 0 }), sc.minimum);
    try std.testing.expectEqual(@as(?schema_types.Constraints.Bound, .{ .integer = 100 }), sc.maximum);

    try std.testing.expectEqual(@as(usize, 1), parsed.presence_user_fields.len);
    const p_status = parsed.presence_user_fields[0];
    try std.testing.expect(p_status.constraints != null);
    try std.testing.expectEqual(@as(usize, 3), p_status.constraints.?.enum_values.?.len);
}

test "schema_parse: rejects invalid constraint combinations" {
    const allocator = std.testing.allocator;

    // minimum on string
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string","minimum":0}}}}}
    ));

    // pattern with embedded NUL byte
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string","pattern":"foo\u0000bar"}}}}}
    ));

    // pattern on integer
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"age":{"type":"integer","pattern":"^[0-9]+$"}}}}}
    ));

    // minLength > maxLength
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string","minLength":10,"maxLength":5}}}}}
    ));

    // minimum > maximum
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"age":{"type":"integer","minimum":100,"maximum":50}}}}}
    ));

    // unknown format
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"email":{"type":"string","format":"unknown_format"}}}}}
    ));

    // constraints on array
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array","items":"string","minLength":2}}}}}
    ));

    // constraints on boolean
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"active":{"type":"boolean","enum":[true,false]}}}}}
    ));

    // constraints on object
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"profile":{"type":"object","minLength":5,"fields":{"name":{"type":"string"}}}}}}}
    ));
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"profile":{"type":"object","pattern":"^[a-z]+$","fields":{"name":{"type":"string"}}}}}}}
    ));
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"profile":{"type":"object","minimum":0,"fields":{"name":{"type":"string"}}}}}}}
    ));

    // non-integral float constraint on integer
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"count":{"type":"integer","minimum":10.5}}}}}
    ));

    // integer minimum >= 2^63 (9223372036854775808.0) out of i64 range
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"count":{"type":"integer","minimum":9223372036854775808.0}}}}}
    ));

    // integer maximum >= 2^63 (9223372036854775808.0) out of i64 range
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"count":{"type":"integer","maximum":9223372036854775808.0}}}}}
    ));

    // number (float) allows 9223372036854775808.0
    {
        var schema = try schema_parse.initFromJson(allocator,
            \\{"version":"1.0.0","store":{"posts":{"fields":{"val":{"type":"number","minimum":9223372036854775808.0}}}}}
        );
        schema.deinit();
    }
}

test "schema_parse: preserves exact i64 precision for integer bounds" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{
        \\  "version":"1.0.0",
        \\  "store":{
        \\    "metrics":{
        \\      "fields":{
        \\        "large_int":{
        \\          "type":"integer",
        \\          "minimum":9007199254740993,
        \\          "maximum":9223372036854775806
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    );
    defer parsed.deinit();

    const metrics = parsed.table("metrics") orelse return error.TestExpectedValue;
    const field = metrics.field("large_int") orelse return error.TestExpectedValue;
    try std.testing.expect(field.constraints != null);
    try std.testing.expectEqual(@as(?schema_types.Constraints.Bound, .{ .integer = 9007199254740993 }), field.constraints.?.minimum);
    try std.testing.expectEqual(@as(?schema_types.Constraints.Bound, .{ .integer = 9223372036854775806 }), field.constraints.?.maximum);

    // Contradictory large bounds beyond 2^53
    try std.testing.expectError(error.InvalidConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"metrics":{"fields":{"val":{"type":"integer","minimum":9007199254740994,"maximum":9007199254740993}}}}}
    ));
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

// ─── Unique constraints ──────────────────────────────────────────────────────

test "schema_parse: parses single-field and compound unique constraints" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.1.0","store":{"projects":{
        \\  "required":["slug"],
        \\  "fields":{
        \\    "slug":{"type":"string"},
        \\    "provider":{"type":"string"},
        \\    "externalId":{"type":"string"}
        \\  },
        \\  "unique":[["slug"],["provider","externalId"]]
        \\}}}
    );
    defer parsed.deinit();

    const projects = parsed.table("projects") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 2), projects.unique_constraints.len);

    const single = projects.unique_constraints[0];
    try std.testing.expectEqual(@as(usize, 1), single.field_indexes.len);
    try std.testing.expectEqual(@as(usize, 0), single.field_indexes[0]);

    const compound = projects.unique_constraints[1];
    try std.testing.expectEqual(@as(usize, 2), compound.field_indexes.len);
    try std.testing.expectEqual(@as(usize, 1), compound.field_indexes[0]);
    try std.testing.expectEqual(@as(usize, 2), compound.field_indexes[1]);
}

test "schema_parse: resolves nested dotted unique paths" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"projects":{
        \\  "fields":{"profile":{"type":"object","fields":{"handle":{"type":"string"}}}},
        \\  "unique":[["profile.handle"]]
        \\}}}
    );
    defer parsed.deinit();

    const projects = parsed.table("projects") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 1), projects.unique_constraints.len);
    try std.testing.expectEqual(@as(usize, 0), projects.unique_constraints[0].field_indexes[0]);
    try std.testing.expectEqualStrings("profile__handle", projects.userFields()[projects.unique_constraints[0].field_indexes[0]].name);
}

test "schema_parse: allows optional reference and array unique fields" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"items":{
        \\  "fields":{
        \\    "owner":{"type":"string","references":"users"},
        \\    "tags":{"type":"array","items":"string"}
        \\  },
        \\  "unique":[["owner"],["tags"]]
        \\}}}
    );
    defer parsed.deinit();

    const items = parsed.table("items") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 2), items.unique_constraints.len);
}

test "schema_parse: accepts empty unique array as absent" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string"}},"unique":[]}}}
    );
    defer parsed.deinit();

    const posts = parsed.table("posts") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 0), posts.unique_constraints.len);
}

test "schema_parse: rejects malformed unique definitions" {
    const allocator = std.testing.allocator;
    const invalid = [_][]const u8{
        // Non-array unique value
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"}},"unique":"a"}}}
        ,
        // Non-array outer item
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"}},"unique":["a"]}}}
        ,
        // Empty inner array
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"}},"unique":[[]]}}}
        ,
        // Non-string component
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"}},"unique":[[1]]}}}
        ,
        // Missing field
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"}},"unique":[["missing"]]}}}
        ,
        // System field
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"}},"unique":[["id"]]}}}
        ,
        // Object (non-leaf) path
        \\{"version":"1.0.0","store":{"p":{"fields":{"obj":{"type":"object","fields":{"x":{"type":"string"}}}},"unique":[["obj"]]}}}
        ,
        // Repeated field in one constraint
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"},"b":{"type":"string"}},"unique":[["a","a"]]}}}
        ,
        // Duplicate constraint set, same order
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"},"b":{"type":"string"}},"unique":[["a","b"],["a","b"]]}}}
        ,
        // Duplicate constraint set, reversed order
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"},"b":{"type":"string"}},"unique":[["a","b"],["b","a"]]}}}
        ,
    };
    for (invalid) |json_text| {
        try std.testing.expectError(error.InvalidUniqueConstraint, schema_parse.initFromJson(allocator, json_text));
    }

    // Unknown table key still rejected.
    try std.testing.expectError(error.UnknownSchemaKey, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string"}},"uniqu":["a"]}}}
    ));
    // Field-level unique alias is unsupported.
    try std.testing.expectError(error.UnknownSchemaKey, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"p":{"fields":{"a":{"type":"string","unique":true}}}}}
    ));
}

test "schema_parse: users custom fields may be unique but external_id may not" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"users":{"namespaced":false,"fields":{"handle":{"type":"string"}},"unique":[["handle"]]}}}
    );
    defer parsed.deinit();

    const users = parsed.table("users") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 1), users.unique_constraints.len);
    try std.testing.expectEqualStrings("handle", users.userFields()[users.unique_constraints[0].field_indexes[0]].name);

    try std.testing.expectError(error.InvalidUniqueConstraint, schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"users":{"namespaced":false,"fields":{"name":{"type":"string"}},"unique":[["external_id"]]}}}
    ));
}

test "schema_parse: unique metadata does not change canonical field indexes" {
    const allocator = std.testing.allocator;

    var parsed = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"tasks":{"required":["title"],"fields":{"title":{"type":"string"},"status":{"type":"string"}},"unique":[["status"]]}}}
    );
    defer parsed.deinit();

    const tasks = parsed.table("tasks") orelse return error.TestExpectedValue;
    try std.testing.expectEqualStrings("id", tasks.fields[0].name);
    try std.testing.expectEqualStrings("namespace_id", tasks.fields[1].name);
    try std.testing.expectEqualStrings("owner_id", tasks.fields[2].name);
    try std.testing.expectEqualStrings("title", tasks.fields[3].name);
    try std.testing.expectEqualStrings("status", tasks.fields[4].name);
    try std.testing.expectEqual(@as(usize, 3), tasks.fieldIndex("title").?);
    try std.testing.expectEqual(@as(usize, 4), tasks.fieldIndex("status").?);
    try std.testing.expect(tasks.field("title").?.required);
}

const unique_allocation_failure_json =
    \\{"version":"1.0.0","store":{"projects":{
    \\  "required":["slug"],
    \\  "fields":{
    \\    "slug":{"type":"string"},
    \\    "provider":{"type":"string"},
    \\    "externalId":{"type":"string"},
    \\    "profile":{"type":"object","fields":{"handle":{"type":"string"}}}
    \\  },
    \\  "unique":[["slug"],["provider","externalId"],["profile.handle"]]
    \\}}}
;

test "schema_property: parse cleanup survives allocation failures with unique constraints" {
    // ponytail: explicit exhaustive scan instead of std.testing.checkAllAllocationFailures,
    // whose calibration miscounts allocations in warm processes. Same property: parse
    // either fails cleanly with OOM at every induced allocation index or succeeds
    // leak-free, and cleanup never leaks.
    const backing = std.testing.allocator;

    const total_allocations = blk: {
        var counting = std.testing.FailingAllocator.init(backing, .{});
        var parsed = try schema_parse.initFromJson(counting.allocator(), unique_allocation_failure_json);
        defer parsed.deinit();
        // Sanity: the constraint set must be complete on the success path.
        const projects = parsed.table("projects") orelse return error.TestExpectedValue;
        try std.testing.expectEqual(@as(usize, 3), projects.unique_constraints.len);
        break :blk counting.alloc_index;
    };

    var fail_i: usize = 0;
    while (fail_i < total_allocations + 8) : (fail_i += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_i });
        if (schema_parse.initFromJson(failing.allocator(), unique_allocation_failure_json)) |parsed_value| {
            var parsed = parsed_value;
            parsed.deinit();
            // Success despite an induced failure means an OOM was silently swallowed.
            if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
        } else |err| switch (err) {
            error.OutOfMemory => {
                // Every byte obtained must be released on the error path.
                if (failing.allocated_bytes != failing.freed_bytes) return error.MemoryLeakDetected;
            },
            else => return err,
        }
    }
}
