const std = @import("std");
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const DDLGenerator = ddl_generator.DDLGenerator;
const Field = schema_parser.Field;
const Table = schema_parser.Table;

test "ddl_generator: generate DDL for a known table" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    const fields = [_]Field{
        .{
            .name = "title",
            .sql_type = .text,
            .items_type = null,
            .required = true,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
        .{
            .name = "status",
            .sql_type = .text,
            .items_type = null,
            .required = false,
            .indexed = true,
            .references = null,
            .on_delete = null,
        },
        .{
            .name = "priority",
            .sql_type = .integer,
            .items_type = null,
            .required = false,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
    };

    const table = Table{
        .name = "tasks",
        .fields = @constCast(&fields),
    };

    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    const expected =
        \\CREATE TABLE IF NOT EXISTS tasks (
        \\  id BLOB NOT NULL CHECK(length(id) = 16),
        \\  namespace_id TEXT NOT NULL,
        \\  title TEXT NOT NULL,
        \\  status TEXT,
        \\  priority INTEGER,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  PRIMARY KEY (id, namespace_id)
        \\);
        \\CREATE INDEX IF NOT EXISTS idx_tasks_namespace_id ON tasks(namespace_id);
        \\CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
    ;

    try std.testing.expectEqualStrings(expected, ddl);
}

test "ddl_generator: generate DDL with foreign key and on delete cascade" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    const fields = [_]Field{
        .{
            .name = "user_id",
            .sql_type = .doc_id,
            .items_type = null,
            .required = true,
            .indexed = false,
            .references = "users",
            .on_delete = .cascade,
        },
    };

    const table = Table{
        .name = "posts",
        .fields = @constCast(&fields),
    };

    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    try std.testing.expect(std.mem.indexOf(u8, ddl, "FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "id BLOB NOT NULL CHECK(length(id) = 16),") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "user_id BLOB NOT NULL CHECK(length(user_id) = 16)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "PRIMARY KEY (id, namespace_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "namespace_id TEXT NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "created_at INTEGER NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "updated_at INTEGER NOT NULL") != null);
}

test "ddl_generator: array field uses BLOB column type" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    const fields = [_]Field{
        .{
            .name = "tags",
            .sql_type = .array,
            .items_type = .text,
            .required = false,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
        .{
            .name = "name",
            .sql_type = .text,
            .items_type = null,
            .required = true,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
    };

    const table = Table{
        .name = "items",
        .fields = @constCast(&fields),
    };

    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    // Array field should use BLOB
    try std.testing.expect(std.mem.indexOf(u8, ddl, "tags BLOB") != null);
    // Non-array field should use TEXT
    try std.testing.expect(std.mem.indexOf(u8, ddl, "name TEXT NOT NULL") != null);
}
