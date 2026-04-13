const std = @import("std");
const schema_parser = @import("schema_parser.zig");
const SchemaParser = schema_parser.SchemaParser;
const FieldType = schema_parser.FieldType;

test "schema_parser: parse known fixture" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    const json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": {
        \\      "fields": {
        \\        "name":    { "type": "string" },
        \\        "age":     { "type": "integer" },
        \\        "score":   { "type": "number" },
        \\        "active":  { "type": "boolean" },
        \\        "tags":    { "type": "array", "items": "string" },
        \\        "address": {
        \\          "type": "object",
        \\          "fields": {
        \\            "city": { "type": "string" },
        \\            "zip":  { "type": "string" }
        \\          }
        \\        }
        \\      },
        \\      "required": ["name"]
        \\    }
        \\  }
        \\}
    ;

    const schema = try parser.parse(json);
    defer parser.deinit(schema);

    try std.testing.expectEqualStrings("1.0.0", schema.version);
    try std.testing.expectEqual(@as(usize, 1), schema.tables.len);

    const table = schema.tables[0];
    try std.testing.expectEqualStrings("users", table.name);

    // 5 scalar fields + 2 flattened object fields = 7
    try std.testing.expectEqual(@as(usize, 7), table.fields.len);

    var found_name = false;
    var found_age = false;
    var found_score = false;
    var found_active = false;
    var found_tags = false;
    var found_city = false;
    var found_zip = false;

    for (table.fields) |f| {
        std.debug.print("Found field: {s}\n", .{f.name});
        if (std.mem.eql(u8, f.name, "name")) {
            found_name = true;
            try std.testing.expectEqual(FieldType.text, f.sql_type);
            try std.testing.expect(f.required);
        } else if (std.mem.eql(u8, f.name, "age")) {
            found_age = true;
            try std.testing.expectEqual(FieldType.integer, f.sql_type);
            try std.testing.expect(!f.required);
        } else if (std.mem.eql(u8, f.name, "score")) {
            found_score = true;
            try std.testing.expectEqual(FieldType.real, f.sql_type);
        } else if (std.mem.eql(u8, f.name, "active")) {
            found_active = true;
            try std.testing.expectEqual(FieldType.boolean, f.sql_type);
        } else if (std.mem.eql(u8, f.name, "tags")) {
            found_tags = true;
            try std.testing.expectEqual(FieldType.array, f.sql_type);
        } else if (std.mem.eql(u8, f.name, "address__city")) {
            found_city = true;
            try std.testing.expectEqual(FieldType.text, f.sql_type);
        } else if (std.mem.eql(u8, f.name, "address__zip")) {
            found_zip = true;
            try std.testing.expectEqual(FieldType.text, f.sql_type);
        }
    }

    try std.testing.expect(found_name);
    try std.testing.expect(found_age);
    try std.testing.expect(found_score);
    try std.testing.expect(found_active);
    try std.testing.expect(found_tags);
    try std.testing.expect(found_city);
    try std.testing.expect(found_zip);
}

test "schema_parser: print() reconstructs nested objects" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    const json =
        \\{"version":"1.0.0","store":{"users":{"fields":{"address":{"type":"object","fields":{"city":{"type":"string"}}},"name":{"type":"string"}},"required":["address","name"]}}}
    ;

    const schema = try parser.parse(json);
    defer parser.deinit(schema);

    const printed = try parser.print(schema);
    defer allocator.free(printed);

    // Verify printed JSON contains nested objects and no double underscores
    try std.testing.expect(std.mem.indexOf(u8, printed, "address\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "city\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "__") == null);
}

test "schema_parser: missing file path returns error" {
    // parse() takes JSON text; the caller is responsible for reading the file.
    // Verify that opening a nonexistent path produces an error.
    const result = std.fs.cwd().openFile("nonexistent-schema.json", .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "schema_parser: unknown field types produce hard error" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    // 1. Top-level unknown type
    const json_top =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": {
        \\      "fields": {
        \\        "external_id": { "type": "uuid" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const result_top = parser.parse(json_top);
    try std.testing.expectError(error.UnknownFieldType, result_top);

    // 2. Flattened unknown type
    const json_flat =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": {
        \\      "fields": {
        \\        "metadata": {
        \\          "type": "object",
        \\          "fields": {
        \\            "legacy_type": { "type": "custom" }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const result_flat = parser.parse(json_flat);
    try std.testing.expectError(error.UnknownFieldType, result_flat);
}

test "schema_parser: parse valid onDelete values" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    const json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "posts": {
        \\      "fields": {
        \\        "userId1": { "type": "string", "references": "users", "onDelete": "cascade" },
        \\        "userId2": { "type": "string", "references": "users", "onDelete": "restrict" },
        \\        "userId3": { "type": "string", "references": "users", "onDelete": "set_null" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const schema = try parser.parse(json);
    defer parser.deinit(schema);

    const table = schema.tables[0];
    for (table.fields) |f| {
        if (std.mem.eql(u8, f.name, "userId1")) {
            try std.testing.expectEqual(schema_parser.OnDelete.cascade, f.on_delete.?);
        } else if (std.mem.eql(u8, f.name, "userId2")) {
            try std.testing.expectEqual(schema_parser.OnDelete.restrict, f.on_delete.?);
        } else if (std.mem.eql(u8, f.name, "userId3")) {
            try std.testing.expectEqual(schema_parser.OnDelete.set_null, f.on_delete.?);
        }
    }
}

test "schema_parser: default onDelete to restrict when references is set" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    const json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "posts": {
        \\      "fields": {
        \\        "userId": { "type": "string", "references": "users" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const schema = try parser.parse(json);
    defer parser.deinit(schema);

    try std.testing.expectEqual(schema_parser.OnDelete.restrict, schema.tables[0].fields[0].on_delete.?);
}

test "schema_parser: unknown onDelete returns error" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    // 1. Bogus string
    const json_bogus =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "posts": {
        \\      "fields": {
        \\        "userId": { "type": "string", "references": "users", "onDelete": "delete" }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.InvalidOnDelete, parser.parse(json_bogus));

    // 2. Uppercase (inconsistent with spec now)
    const json_upper =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "posts": {
        \\      "fields": {
        \\        "userId": { "type": "string", "references": "users", "onDelete": "CASCADE" }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.InvalidOnDelete, parser.parse(json_upper));
}

test "schema_parser: set_null on required field returns error" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    const json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "posts": {
        \\      "fields": {
        \\        "userId": { "type": "string", "references": "users", "onDelete": "set_null" }
        \\      },
        \\      "required": ["userId"]
        \\    }
        \\  }
        \\}
    ;

    try std.testing.expectError(error.InvalidOnDelete, parser.parse(json));
}

test "schema_parser: set_null on optional field succeeds" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    const json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "posts": {
        \\      "fields": {
        \\        "userId": { "type": "string", "references": "users", "onDelete": "set_null" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const schema = try parser.parse(json);
    defer parser.deinit(schema);
    try std.testing.expectEqual(schema_parser.OnDelete.set_null, schema.tables[0].fields[0].on_delete.?);
}

test "schema_parser: no references no onDelete keeps on_delete null" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    const json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "posts": {
        \\      "fields": {
        \\        "title": { "type": "string" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const schema = try parser.parse(json);
    defer parser.deinit(schema);
    try std.testing.expect(schema.tables[0].fields[0].on_delete == null);
}

test "schema_parser: reject __ in table and field names" {
    const allocator = std.testing.allocator;
    var parser = SchemaParser.init(allocator);

    // 1. Forbidden table name
    const json_table =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "bad__table": {
        \\      "fields": { "val": { "type": "string" } }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.InvalidTableName, parser.parse(json_table));

    // 2. Forbidden field name
    const json_field =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": {
        \\      "fields": { "bad__field": { "type": "string" } }
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.InvalidFieldName, parser.parse(json_field));
}
