const std = @import("std");
const schema_types = @import("types.zig");
const schema_system = @import("system.zig");
const schema_parse = @import("parse.zig");
const schema_helpers = @import("test_helpers.zig");

test "schema_index: direct table fixtures build lookup maps" {
    const allocator = std.testing.allocator;

    var task_fields = [_]schema_types.Field{
        schema_helpers.makeField("title", .text),
        schema_helpers.makeField("priority", .integer),
    };
    var tables = [_]schema_types.Table{
        schema_helpers.makeTable("tasks", &task_fields),
    };

    var runtime_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
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

    var fields = [_]schema_types.Field{schema_helpers.makeField("title", .text)};
    var tables = [_]schema_types.Table{schema_helpers.makeTable("posts", &fields)};

    var runtime_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer runtime_schema.deinit();

    const posts = runtime_schema.table("posts") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(schema_types.FieldKind.system, posts.fields[schema_system.id_field_index].kind);
    try std.testing.expectEqual(schema_types.FieldKind.user, posts.fields[schema_system.first_user_field_index].kind);
    try std.testing.expectEqual(schema_types.FieldKind.timestamp, posts.fields[posts.fields.len - 1].kind);
    try std.testing.expectEqual(@as(usize, 1), posts.userFields().len);
    try std.testing.expectEqual(@as(usize, posts.fields.len), posts.fields.len);
}

test "schema_index: users external_id is not indexed" {
    const allocator = std.testing.allocator;

    var runtime_schema = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{}}
    );
    defer runtime_schema.deinit();

    const users = runtime_schema.table("users") orelse return error.TestExpectedValue;
    try std.testing.expect(users.fieldIndex("external_id") == null);
}
