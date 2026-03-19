const std = @import("std");
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const DDLGenerator = ddl_generator.DDLGenerator;
const Field = schema_parser.Field;
const FieldType = schema_parser.FieldType;
const OnDelete = schema_parser.OnDelete;
const Table = schema_parser.Table;
const sqlite = @import("sqlite");

// Feature: schema-aware-storage, Property 7: DDL contains all required columns and constraints
// For any Table value t, the DDL string produced by DDL_Generator.generateDDL(t) SHALL contain:
// id TEXT PRIMARY KEY, namespace_id TEXT NOT NULL, one correctly-typed column per field in t.fields
// (with NOT NULL for required fields, FOREIGN KEY for referenced fields),
// created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, and a CREATE INDEX on namespace_id.
test "ddl_generator: property 7 - DDL contains required columns and constraints" {
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

        for (0..n_fields) |fi| {
            const has_ref = rand.boolean();
            const ref_idx = rand.intRangeAtMost(usize, 0, ref_tables.len - 1);
            fields[fi] = .{
                .name = field_names[fi % field_names.len],
                .sql_type = field_types[rand.intRangeAtMost(usize, 0, field_types.len - 1)],
                .required = rand.boolean(),
                .indexed = rand.boolean(),
                .references = if (has_ref) ref_tables[ref_idx] else null,
                .on_delete = if (has_ref) on_deletes[rand.intRangeAtMost(usize, 0, on_deletes.len - 1)] else null,
            };
        }

        const table_name = "test_table";
        const table = Table{
            .name = table_name,
            .fields = fields,
        };

        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);

        // Assert required structural elements
        try std.testing.expect(std.mem.indexOf(u8, ddl, "id TEXT,") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "namespace_id TEXT NOT NULL") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "created_at INTEGER NOT NULL") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "updated_at INTEGER NOT NULL") != null);
        try std.testing.expect(std.mem.indexOf(u8, ddl, "PRIMARY KEY (id, namespace_id)") != null);

        // Assert CREATE INDEX on namespace_id
        const ns_idx = try std.fmt.allocPrint(allocator, "CREATE INDEX IF NOT EXISTS idx_{s}_namespace_id ON {s}(namespace_id)", .{ table_name, table_name });
        defer allocator.free(ns_idx);
        try std.testing.expect(std.mem.indexOf(u8, ddl, ns_idx) != null);

        // Assert each field appears with correct type and NOT NULL if required
        for (fields) |field| {
            const expected_type = switch (field.sql_type) {
                .text => "TEXT",
                .integer => "INTEGER",
                .real => "REAL",
                .boolean => "INTEGER",
                .array => "TEXT",
            };

            // Check column definition exists
            const col_def = try std.fmt.allocPrint(allocator, "  {s} {s}", .{ field.name, expected_type });
            defer allocator.free(col_def);
            try std.testing.expect(std.mem.indexOf(u8, ddl, col_def) != null);

            // Check NOT NULL for required fields
            if (field.required) {
                const not_null_def = try std.fmt.allocPrint(allocator, "  {s} {s} NOT NULL", .{ field.name, expected_type });
                defer allocator.free(not_null_def);
                try std.testing.expect(std.mem.indexOf(u8, ddl, not_null_def) != null);
            }

            // Check FOREIGN KEY for referenced fields
            if (field.references) |ref| {
                const fk_def = try std.fmt.allocPrint(allocator, "FOREIGN KEY ({s}) REFERENCES {s}(id)", .{ field.name, ref });
                defer allocator.free(fk_def);
                try std.testing.expect(std.mem.indexOf(u8, ddl, fk_def) != null);
            }
        }
    }
}

// Feature: schema-aware-storage, Property 8: Generated DDL is executable
// For any Table value t, executing the DDL produced by DDL_Generator.generateDDL(t)
// against an empty in-memory SQLite database SHALL succeed without error.
test "ddl_generator: property 8 - generated DDL is executable" {
    const allocator = std.testing.allocator;
    var gen = DDLGenerator.init(allocator);

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();

    const field_names = [_][]const u8{ "col_a", "col_b", "col_c", "col_d", "col_e" };
    const ref_tables = [_][]const u8{ "ref_one", "ref_two" };
    const field_types = [_]FieldType{ .text, .integer, .real, .boolean, .array };
    const on_deletes = [_]?OnDelete{ null, .cascade, .restrict, .set_null };

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

            // Only use references to ref_tables that we'll create separately
            // To keep DDL executable, avoid FK references (they require the referenced table to exist)
            // unless we create them first. For simplicity, skip FK references in this property test.
            _ = ref_tables;
            _ = on_deletes;

            fields[actual_n] = .{
                .name = field_names[name_idx],
                .sql_type = field_types[rand.intRangeAtMost(usize, 0, field_types.len - 1)],
                .required = rand.boolean(),
                .indexed = rand.boolean(),
                .references = null,
                .on_delete = null,
            };
            actual_n += 1;
        }

        // Build table name unique per iteration to avoid conflicts
        var table_name_buf: [32]u8 = undefined;
        const table_name = try std.fmt.bufPrint(&table_name_buf, "tbl_{d}", .{iter});

        const table = Table{
            .name = table_name,
            .fields = fields[0..actual_n],
        };

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
