const std = @import("std");
const schema_parser = @import("schema_parser.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const ddl_generator = @import("ddl_generator.zig");
const DDLGenerator = ddl_generator.DDLGenerator;
const Field = schema_parser.Field;
const sqlite = @import("sqlite");

test "ddl_generator: generate DDL for a known table" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    const fields = [_]Field{
        schema_helpers.makeRequiredField("title", .text),
        schema_helpers.makeIndexedField("status", .text),
        schema_helpers.makeField("priority", .integer),
    };

    const table = schema_helpers.makeTable("tasks", &fields);

    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    const expected =
        \\CREATE TABLE IF NOT EXISTS "tasks" (
        \\  "id" BLOB NOT NULL CHECK(length("id") = 16),
        \\  "namespace_id" INTEGER NOT NULL,
        \\  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16),
        \\  "title" TEXT NOT NULL,
        \\  "status" TEXT,
        \\  "priority" INTEGER,
        \\  "created_at" INTEGER NOT NULL,
        \\  "updated_at" INTEGER NOT NULL,
        \\  PRIMARY KEY ("id")
        \\);
        \\CREATE INDEX IF NOT EXISTS "idx_tasks_namespace_id" ON "tasks"("namespace_id");
        \\CREATE INDEX IF NOT EXISTS "idx_tasks_owner_id" ON "tasks"("owner_id");
        \\CREATE INDEX IF NOT EXISTS "idx_tasks_status" ON "tasks"("status");
    ;

    try std.testing.expectEqualStrings(expected, ddl);
}

test "ddl_generator: generate DDL with foreign key and on delete cascade" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    var user_id_field = schema_helpers.makeRequiredField("user_id", .doc_id);
    user_id_field.references = "users";
    user_id_field.on_delete = .cascade;

    const fields = [_]Field{user_id_field};

    const table = schema_helpers.makeTable("posts", &fields);

    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    try std.testing.expect(std.mem.indexOf(u8, ddl, "FOREIGN KEY (\"user_id\") REFERENCES \"users\"(\"id\") ON DELETE CASCADE") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"id\" BLOB NOT NULL CHECK(length(\"id\") = 16),") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"user_id\" BLOB NOT NULL CHECK(length(\"user_id\") = 16)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "PRIMARY KEY (\"id\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"namespace_id\" INTEGER NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"owner_id\" BLOB NOT NULL CHECK(length(\"owner_id\") = 16)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"created_at\" INTEGER NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"updated_at\" INTEGER NOT NULL") != null);
}

test "ddl_generator: array field uses BLOB column type" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    const fields = [_]Field{
        schema_helpers.makeField("tags", .array),
        schema_helpers.makeRequiredField("name", .text),
    };

    const table = schema_helpers.makeTable("items", &fields);

    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    // Array field should use BLOB
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"tags\" BLOB") != null);
    // Non-array field should use TEXT
    try std.testing.expect(std.mem.indexOf(u8, ddl, "\"name\" TEXT NOT NULL") != null);
}

test "ddl_generator: quoted identifiers allow SQLite keywords" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    var from_field = schema_helpers.makeRequiredField("from", .text);
    from_field.indexed = true;

    const fields = [_]Field{from_field};

    const table = schema_helpers.makeTable("select", &fields);

    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });
    defer db.deinit();

    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try db.execMulti(ddl_z, .{});
}
