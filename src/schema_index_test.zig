const std = @import("std");
const schema = @import("schema.zig");

fn field(comptime name: []const u8, declared_type: schema.FieldType) schema.Field {
    return .{
        .name = name,
        .name_quoted = "\"" ++ name ++ "\"",
        .declared_type = declared_type,
        .storage_type = declared_type,
    };
}

fn table(comptime name: []const u8, fields: []const schema.Field) schema.Table {
    return .{
        .name = name,
        .name_quoted = "\"" ++ name ++ "\"",
        .fields = fields,
    };
}

test "schema_index: direct table fixtures build lookup maps" {
    const allocator = std.testing.allocator;

    var task_fields = [_]schema.Field{
        field("title", .text),
        field("priority", .integer),
    };
    var tables = [_]schema.Table{
        table("tasks", &task_fields),
    };

    var runtime_schema = try schema.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer runtime_schema.deinit();

    const users = runtime_schema.tableByIndex(0) orelse return error.TestExpectedValue;
    const tasks = runtime_schema.table("tasks") orelse return error.TestExpectedValue;
    try std.testing.expectEqualStrings("users", users.name);
    try std.testing.expectEqual(@as(usize, 1), tasks.index);
    try std.testing.expectEqual(@as(usize, 3), tasks.fieldIndex("title").?);
    try std.testing.expectEqual(@as(usize, 4), tasks.fieldIndex("priority").?);
    try std.testing.expect(tasks.field("missing") == null);
}

test "schema_index: exposes field kinds and writable ranges" {
    const allocator = std.testing.allocator;

    var fields = [_]schema.Field{field("title", .text)};
    var tables = [_]schema.Table{table("posts", &fields)};

    var runtime_schema = try schema.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer runtime_schema.deinit();

    const posts = runtime_schema.table("posts") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(schema.FieldKind.system, posts.fields[schema.id_field_index].kind);
    try std.testing.expectEqual(schema.FieldKind.user, posts.fields[schema.first_user_field_index].kind);
    try std.testing.expectEqual(schema.FieldKind.timestamp, posts.fields[posts.fields.len - 1].kind);
    try std.testing.expectEqual(@as(usize, 1), posts.userFields().len);
    try std.testing.expectEqual(@as(usize, posts.fields.len), posts.fields.len);
}

test "schema_index: users external_id is not indexed" {
    const allocator = std.testing.allocator;

    var runtime_schema = try schema.initSchema(allocator,
        \\{"version":"1.0.0","store":{}}
    );
    defer runtime_schema.deinit();

    const users = runtime_schema.table("users") orelse return error.TestExpectedValue;
    try std.testing.expect(users.fieldIndex("external_id") == null);
}
