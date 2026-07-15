const std = @import("std");
const schema_types = @import("../schema/types.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const ddl_generator = @import("ddl.zig");
const DDLGenerator = ddl_generator.DDLGenerator;
const Field = schema_types.Field;
const FieldType = schema_types.FieldType;
const OnDelete = schema_types.OnDelete;
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

// Feature: schema-aware-storage, Property 7: DDL contains all required columns and constraints
// For any Table value t, the DDL string produced by DDL_Generator.generateDDL(t) SHALL contain:
// id BLOB NOT NULL CHECK(length(id) = 16), namespace_id INTEGER NOT NULL,
// owner_id BLOB NOT NULL CHECK(length(owner_id) = 16),
// one correctly-typed column per field in t.fields
// (with NOT NULL for required fields, FOREIGN KEY for referenced fields),
// created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, and a CREATE INDEX on namespace_id.
test "ddl_generator: DDL contains required columns and constraints" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const field_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const ref_tables = [_][]const u8{ "users", "posts", "items", "orders", "tags" };
    const field_types = [_]FieldType{ .text, .integer, .real, .boolean, .array };
    const on_deletes = [_]?OnDelete{ null, .cascade, .restrict, .set_null };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const n_fields = rand.intRangeAtMost(usize, 1, 5);

        // Build fields array
        var fields = try allocator.alloc(Field, n_fields);
        defer allocator.free(fields);
        defer for (fields) |f| {
            allocator.free(f.name);
            allocator.free(f.name_quoted);
        };

        for (0..n_fields) |fi| {
            const has_ref = rand.boolean();
            const ref_idx = rand.intRangeAtMost(usize, 0, ref_tables.len - 1);
            const base_type = field_types[rand.intRangeAtMost(usize, 0, field_types.len - 1)];
            const st = if (has_ref) FieldType.doc_id else base_type;
            const fname = field_names[fi % field_names.len];
            var f = try schema_helpers.makeFieldAlloc(allocator, fname, st);
            f.required = rand.boolean();
            f.indexed = rand.boolean();
            f.references = if (has_ref) ref_tables[ref_idx] else null;
            f.on_delete = if (has_ref) on_deletes[rand.intRangeAtMost(usize, 0, on_deletes.len - 1)] else null;
            fields[fi] = f;
        }

        const table = schema_helpers.makeTable("test_table", fields);

        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);

        // Assert required structural elements
        try std.testing.expect(std.mem.indexOf(u8, ddl, "\"id\" BLOB NOT NULL CHECK(length(\"id\") = 16),") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "\"namespace_id\" INTEGER NOT NULL") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "\"owner_id\" BLOB NOT NULL CHECK(length(\"owner_id\") = 16)") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "\"created_at\" INTEGER NOT NULL") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "\"updated_at\" INTEGER NOT NULL") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "PRIMARY KEY (\"id\")") != null);

        // Assert CREATE INDEX on namespace_id
        const ns_idx = try std.fmt.allocPrint(allocator, "CREATE INDEX IF NOT EXISTS \"idx_{s}_namespace_id\" ON \"{s}\"(\"namespace_id\")", .{ "test_table", "test_table" });
        defer allocator.free(ns_idx);
        try std.testing.expect(std.mem.indexOf(u8, ddl, ns_idx) != null);

        // Assert each field appears with correct type and NOT NULL if required
        for (fields) |field| {
            const expected_type = field.storage_type.toSqlType();

            // Check column definition exists
            const col_def = try std.fmt.allocPrint(allocator, "  \"{s}\" {s}", .{ field.name, expected_type });
            defer allocator.free(col_def);
            try std.testing.expect(std.mem.indexOf(u8, ddl, col_def) != null);

            // Check NOT NULL for required fields
            if (field.required) {
                const not_null_def = try std.fmt.allocPrint(allocator, "  \"{s}\" {s} NOT NULL", .{ field.name, expected_type });
                defer allocator.free(not_null_def);
                try std.testing.expect(std.mem.indexOf(u8, ddl, not_null_def) != null);
            }

            if (field.storage_type == .doc_id) {
                const doc_id_check = try std.fmt.allocPrint(allocator, "  \"{s}\" {s}{s} CHECK(length(\"{s}\") = 16)", .{
                    field.name,
                    expected_type,
                    if (field.required) " NOT NULL" else "",
                    field.name,
                });
                defer allocator.free(doc_id_check);
                try std.testing.expect(std.mem.indexOf(u8, ddl, doc_id_check) != null);
            }

            // Check FOREIGN KEY for referenced fields
            if (field.references) |ref| {
                const fk_def = try std.fmt.allocPrint(allocator, "FOREIGN KEY (\"{s}\") REFERENCES \"{s}\"(\"id\")", .{ field.name, ref });
                defer allocator.free(fk_def);
                try std.testing.expect(std.mem.indexOf(u8, ddl, fk_def) != null);
            }
        }
    }
}

// Feature: schema-aware-storage, Property 8: Generated DDL is executable
// For any Table value t, executing the DDL produced by DDL_Generator.generateDDL(t)
// against an empty in-memory SQLite database SHALL succeed without error.
test "ddl_generator: generated DDL is executable" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();

    const field_names = [_][]const u8{ "col_a", "col_b", "col_c", "col_d", "col_e" };
    const field_types = [_]FieldType{ .text, .integer, .real, .boolean, .array };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const n_fields = rand.intRangeAtMost(usize, 1, 5);

        var fields = try allocator.alloc(Field, n_fields);
        defer allocator.free(fields);

        // Track which field names are used to avoid duplicates
        var used_names = [_]bool{false} ** field_names.len;
        var actual_n: usize = 0;

        for (0..n_fields) |fi| {
            // Find an unused name
            var name_idx: usize = fi % field_names.len;
            var attempts: usize = 0;
            while (used_names[name_idx] and attempts < field_names.len) {
                name_idx = (name_idx + 1) % field_names.len;
                attempts += 1;
            }
            if (used_names[name_idx]) break; // all names used
            used_names[name_idx] = true;

            const st = field_types[rand.intRangeAtMost(usize, 0, field_types.len - 1)];
            const fname2 = field_names[name_idx];
            var f = try schema_helpers.makeFieldAlloc(allocator, fname2, st);
            f.required = rand.boolean();
            f.indexed = rand.boolean();
            fields[actual_n] = f;
            actual_n += 1;
        }
        defer for (fields[0..actual_n]) |f| {
            allocator.free(f.name);
            allocator.free(f.name_quoted);
        };

        // Build table name unique per iteration to avoid conflicts
        var table_name_buf: [32]u8 = undefined;
        const table_name = try std.fmt.bufPrint(&table_name_buf, "tbl_{d}", .{iter});

        const table = try schema_helpers.makeTableAlloc(allocator, table_name, fields[0..actual_n]);
        defer {
            allocator.free(table.name);
            allocator.free(table.name_quoted);
        }

        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);

        // Open an in-memory SQLite database and execute the DDL
        var db = try sqlite.Db.init(.{
            .mode = .Memory,
            .open_flags = .{
                .write = true,
                .create = true,
            },
        });
        defer db.deinit();

        // execMulti requires null-terminated string
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);

        // Execute all statements using execMulti (handles multiple statements)
        db.execMulti(ddl_z, .{}) catch |err| {
            std.debug.print("DDL execution failed for iter {d}: {}\nFull DDL:\n{s}\n", .{ iter, err, ddl });
            return err;
        };
    }
}

// Feature: array-jsonb-storage, Property 1: DDL emits BLOB for array fields
// For any Table with a mix of field types including at least one .array field,
// generateDDL shall emit BLOB for array columns and the correct type for all others.
test "ddl_generator: DDL emits BLOB for array fields" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    var prng = std.Random.DefaultPrng.init(0xABCD_1234);
    const rand = prng.random();

    const field_names = [_][]const u8{ "f0", "f1", "f2", "f3", "f4" };
    const non_array_types = [_]FieldType{ .text, .integer, .real, .boolean };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const n_fields = rand.intRangeAtMost(usize, 2, 5);
        const array_idx = rand.intRangeAtMost(usize, 0, n_fields - 1);

        var fields = try allocator.alloc(Field, n_fields);
        defer allocator.free(fields);
        defer for (fields) |f| {
            allocator.free(f.name);
            allocator.free(f.name_quoted);
        };

        for (0..n_fields) |fi| {
            const st = if (fi == array_idx) .array else non_array_types[rand.intRangeAtMost(usize, 0, non_array_types.len - 1)];
            const fname3 = field_names[fi % field_names.len];
            var f = try schema_helpers.makeFieldAlloc(allocator, fname3, st);
            f.required = rand.boolean();
            fields[fi] = f;
        }

        const table = schema_helpers.makeTable("prop1_tbl", fields);
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);

        for (fields) |f| {
            const expected_type = f.storage_type.toSqlType();
            const col_def = try std.fmt.allocPrint(allocator, "  \"{s}\" {s}", .{ f.name, expected_type });
            defer allocator.free(col_def);
            try std.testing.expect(std.mem.indexOf(u8, ddl, col_def) != null);
        }

        // Specifically assert the array column uses BLOB, not TEXT
        const array_field = fields[array_idx];
        const blob_def = try std.fmt.allocPrint(allocator, "  \"{s}\" BLOB", .{array_field.name});
        defer allocator.free(blob_def);
        try std.testing.expect(std.mem.indexOf(u8, ddl, blob_def) != null);
        const text_def = try std.fmt.allocPrint(allocator, "  \"{s}\" TEXT", .{array_field.name});
        defer allocator.free(text_def);
        try std.testing.expect(std.mem.indexOf(u8, ddl, text_def) == null);
    }
}
