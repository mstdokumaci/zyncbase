const std = @import("std");

const schema_parse = @import("parse.zig");
const schema_helpers = @import("test_helpers.zig");
const schema_types = @import("types.zig");

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

test "schema_index: users external_id is not indexed" {
    const allocator = std.testing.allocator;

    var runtime_schema = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{}}
    );
    defer runtime_schema.deinit();

    const users = runtime_schema.table("users") orelse return error.TestExpectedValue;
    try std.testing.expect(users.fieldIndex("external_id") == null);
}

test "schema_types: unique constraints stay user-relative through runtime build" {
    const allocator = std.testing.allocator;

    const declared_fields = [_]schema_types.Field{
        schema_helpers.makeField("slug", .text),
        schema_helpers.makeField("provider", .text),
        schema_helpers.makeField("externalId", .text),
    };
    // ponytail: static constraint fixture — declared tables never deinit here.
    const declared_constraints = [_]schema_types.UniqueConstraint{
        .{ .field_indexes = &.{0} },
        .{ .field_indexes = &.{ 1, 2 } },
    };
    var declared = schema_helpers.makeTable("projects", &declared_fields);
    declared.unique_constraints = &declared_constraints;

    var runtime_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &.{declared});
    defer runtime_schema.deinit();

    const projects = runtime_schema.table("projects") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 2), projects.unique_constraints.len);
    try std.testing.expect(projects.unique_constraints[0].field_indexes.ptr != declared_constraints[0].field_indexes.ptr);
    for (projects.unique_constraints, 0..) |constraint, ci| {
        for (constraint.field_indexes) |idx| {
            try std.testing.expect(idx < projects.userFields().len);
            _ = ci;
        }
    }
    try std.testing.expectEqualStrings("slug", projects.userFields()[projects.unique_constraints[0].field_indexes[0]].name);
    try std.testing.expectEqualStrings("provider", projects.userFields()[projects.unique_constraints[1].field_indexes[0]].name);
    try std.testing.expectEqualStrings("externalId", projects.userFields()[projects.unique_constraints[1].field_indexes[1]].name);
}
