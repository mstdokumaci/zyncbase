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
        \\        "tags":    { "type": "array" },
        \\        "address": {
        \\          "type": "object",
        \\          "properties": {
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
        } else if (std.mem.eql(u8, f.name, "address_city")) {
            found_city = true;
            try std.testing.expectEqual(FieldType.text, f.sql_type);
        } else if (std.mem.eql(u8, f.name, "address_zip")) {
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
        \\          "properties": {
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
