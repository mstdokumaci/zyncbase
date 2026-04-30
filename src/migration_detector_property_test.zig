const std = @import("std");
const schema = @import("schema.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const ddl_generator = @import("ddl_generator.zig");
const migration_detector = @import("migration_detector.zig");
const MigrationDetector = migration_detector.MigrationDetector;
const ChangeKind = migration_detector.ChangeKind;
const sqlite = @import("sqlite");

fn openMemDb() !sqlite.Db {
    return sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
}

fn execDDL(db: *sqlite.Db, allocator: std.mem.Allocator, ddl: []const u8) !void {
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try db.execMulti(ddl_z, .{});
}

fn execTableDDL(db: *sqlite.Db, allocator: std.mem.Allocator, gen: *ddl_generator.DDLGenerator, table: schema.Table) !void {
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    try execDDL(db, allocator, ddl);
}

fn execSchemaDDL(db: *sqlite.Db, allocator: std.mem.Allocator, gen: *ddl_generator.DDLGenerator, schema_value: *const schema.Schema) !void {
    for (schema_value.tables) |table| {
        try execTableDDL(db, allocator, gen, table);
    }
}

// Feature: schema-aware-storage, Property 9: Migration plan accurately describes schema diff
// For any pair of schemas (old, new), the MigrationPlan produced by
// Migration_Detector.detectChanges SHALL contain exactly one Change entry for each
// table or column that differs between old and new, with the correct ChangeKind.
test "migration_detector: migration plan accurately describes schema diff" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const table_names = [_][]const u8{ "posts", "items", "orders", "tags", "comments" };
    const field_names = [_][]const u8{ "title", "status", "count", "active", "score" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const tname = table_names[rand.intRangeAtMost(usize, 0, table_names.len - 1)];
        const scenario = rand.intRangeAtMost(u8, 0, 3);

        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);

        switch (scenario) {
            0 => {
                // Table doesn't exist in DB → expect create_table
                var target_fields = [_]schema.Field{schema_helpers.makeField("title", .text)};
                var target_tables = [_]schema.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                defer {
                    allocator.free(target_tables[0].name);
                    allocator.free(target_tables[0].name_quoted);
                }
                var target_schema = try schema.Schema.initFromTables(allocator, "1.0.0", &target_tables);
                defer target_schema.deinit();
                const users_table = target_schema.getTable("users") orelse return error.TestExpectedValue;
                try execTableDDL(&db, allocator, &gen, users_table.*);

                var detector = MigrationDetector.init(allocator, &db, &target_schema);
                const plan = try detector.detectChanges(&target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.create_table, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table.name);
                try std.testing.expect(plan.changes[0].field == null);
                try std.testing.expect(!plan.is_destructive);
            },
            1 => {
                // Table exists with one column; target adds a new column → expect add_column
                var existing_fields = [_]schema.Field{schema_helpers.makeField("title", .text)};
                const existing_tables = [_]schema.Table{try schema_helpers.makeTableAlloc(allocator, tname, &existing_fields)};
                defer {
                    allocator.free(existing_tables[0].name);
                    allocator.free(existing_tables[0].name_quoted);
                }
                const existing_ddl = try gen.generateDDL(existing_tables[0]);
                defer allocator.free(existing_ddl);
                try execDDL(&db, allocator, existing_ddl);

                var existing_schema = try schema.Schema.initFromTables(allocator, "1.0.0", &existing_tables);
                defer existing_schema.deinit();
                const users_table = existing_schema.getTable("users") orelse return error.TestExpectedValue;
                try execTableDDL(&db, allocator, &gen, users_table.*);

                const new_fname = field_names[rand.intRangeAtMost(usize, 1, field_names.len - 1)];
                const new_field = try schema_helpers.makeFieldAlloc(allocator, new_fname, .integer);
                var target_fields = [_]schema.Field{
                    schema_helpers.makeField("title", .text),
                    new_field,
                };
                var target_tables = [_]schema.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                defer {
                    allocator.free(target_tables[0].name);
                    allocator.free(target_tables[0].name_quoted);
                    allocator.free(new_field.name);
                    allocator.free(new_field.name_quoted);
                }
                var target_schema = try schema.Schema.initFromTables(allocator, "1.0.0", &target_tables);
                defer target_schema.deinit();

                var detector = MigrationDetector.init(allocator, &db, &existing_schema);
                const plan = try detector.detectChanges(&target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.add_column, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table.name);
                try std.testing.expect(plan.changes[0].field != null);
                try std.testing.expectEqualStrings(new_fname, plan.changes[0].field.?.name);
                try std.testing.expect(!plan.is_destructive);
            },
            2 => {
                // Table exists with TEXT column; target changes it to INTEGER → expect change_type
                var existing_fields = [_]schema.Field{schema_helpers.makeField("status", .text)};
                const existing_tables = [_]schema.Table{try schema_helpers.makeTableAlloc(allocator, tname, &existing_fields)};
                defer {
                    allocator.free(existing_tables[0].name);
                    allocator.free(existing_tables[0].name_quoted);
                }
                const existing_ddl = try gen.generateDDL(existing_tables[0]);
                defer allocator.free(existing_ddl);
                try execDDL(&db, allocator, existing_ddl);

                var existing_schema = try schema.Schema.initFromTables(allocator, "1.0.0", &existing_tables);
                defer existing_schema.deinit();
                const users_table = existing_schema.getTable("users") orelse return error.TestExpectedValue;
                try execTableDDL(&db, allocator, &gen, users_table.*);

                var target_fields = [_]schema.Field{schema_helpers.makeField("status", .integer)};
                var target_tables = [_]schema.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                defer {
                    allocator.free(target_tables[0].name);
                    allocator.free(target_tables[0].name_quoted);
                }
                var target_schema = try schema.Schema.initFromTables(allocator, "1.0.0", &target_tables);
                defer target_schema.deinit();

                var detector = MigrationDetector.init(allocator, &db, &existing_schema);
                const plan = try detector.detectChanges(&target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.change_type, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table.name);
                try std.testing.expect(plan.is_destructive);
            },
            else => {
                // Table exists with extra column not in target → expect remove_column
                var existing_fields = [_]schema.Field{
                    schema_helpers.makeField("title", .text),
                    schema_helpers.makeField("extra_col", .text),
                };
                const existing_tables = [_]schema.Table{try schema_helpers.makeTableAlloc(allocator, tname, &existing_fields)};
                defer {
                    allocator.free(existing_tables[0].name);
                    allocator.free(existing_tables[0].name_quoted);
                }
                const existing_ddl = try gen.generateDDL(existing_tables[0]);
                defer allocator.free(existing_ddl);
                try execDDL(&db, allocator, existing_ddl);

                var existing_schema = try schema.Schema.initFromTables(allocator, "1.0.0", &existing_tables);
                defer existing_schema.deinit();
                const users_table = existing_schema.getTable("users") orelse return error.TestExpectedValue;
                try execTableDDL(&db, allocator, &gen, users_table.*);

                var target_fields = [_]schema.Field{schema_helpers.makeField("title", .text)};
                var target_tables = [_]schema.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                defer {
                    allocator.free(target_tables[0].name);
                    allocator.free(target_tables[0].name_quoted);
                }
                var target_schema = try schema.Schema.initFromTables(allocator, "1.0.0", &target_tables);
                defer target_schema.deinit();

                var detector = MigrationDetector.init(allocator, &db, &existing_schema);
                const plan = try detector.detectChanges(&target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.remove_column, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table.name);
                try std.testing.expect(plan.is_destructive);
            },
        }
    }
}

// Feature: schema-aware-storage, Property 19: Matching version produces empty migration plan
// For any database whose schema matches the target Schema exactly,
// Migration_Detector.detectChanges SHALL return a MigrationPlan with zero changes.
test "migration_detector: matching schema produces empty migration plan" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();

    const table_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const field_names = [_][]const u8{ "col_a", "col_b", "col_c", "col_d" };
    const field_types = [_]schema.FieldType{ .text, .integer, .real };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);

        const n_tables = rand.intRangeAtMost(usize, 1, 3);
        const tables = try allocator.alloc(schema.Table, n_tables);
        defer {
            for (tables) |t| {
                allocator.free(t.name);
                allocator.free(t.name_quoted);
                for (t.fields) |f| {
                    allocator.free(f.name);
                    allocator.free(f.name_quoted);
                }
                allocator.free(t.fields);
            }
            allocator.free(tables);
        }

        for (0..n_tables) |ti| {
            const tname = table_names[ti % table_names.len];
            const n_fields = rand.intRangeAtMost(usize, 1, 3);
            const fields = try allocator.alloc(schema.Field, n_fields);

            for (0..n_fields) |fi| {
                const mf_name = field_names[fi % field_names.len];
                const mf_type = field_types[rand.intRangeAtMost(usize, 0, field_types.len - 1)];
                fields[fi] = try schema_helpers.makeFieldAlloc(allocator, mf_name, mf_type);
            }

            tables[ti] = try schema_helpers.makeTableAlloc(allocator, tname, fields);
        }

        var target_schema = try schema.Schema.initFromTables(allocator, "1.0.0", tables);
        defer target_schema.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target_schema);

        var detector = MigrationDetector.init(allocator, &db, &target_schema);
        const plan = try detector.detectChanges(&target_schema);
        defer detector.deinit(plan);

        if (plan.changes.len != 0) {
            std.debug.print("iter {d}: expected 0 changes, got {d}\n", .{ iter, plan.changes.len });
            for (plan.changes) |c| {
                std.debug.print("  change: kind={s} table={s}\n", .{ @tagName(c.kind), c.table.name });
            }
        }
        try std.testing.expectEqual(@as(usize, 0), plan.changes.len);
        try std.testing.expect(!plan.is_destructive);
    }
}
