const std = @import("std");
const schema_parser = @import("schema_parser.zig");
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

fn makeField(name: []const u8, sql_type: schema_parser.FieldType) schema_parser.Field {
    return .{
        .name = name,
        .sql_type = sql_type,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

// Feature: schema-aware-storage, Property 9: Migration plan accurately describes schema diff
// For any pair of schemas (old, new), the MigrationPlan produced by
// Migration_Detector.detectChanges SHALL contain exactly one Change entry for each
// table or column that differs between old and new, with the correct ChangeKind.
test "migration_detector: property 9 - migration plan accurately describes schema diff" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const table_names = [_][]const u8{ "users", "posts", "items", "orders", "tags" };
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
                var target_fields = [_]schema_parser.Field{makeField("title", .text)};
                var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
                const target_schema = schema_parser.Schema{
                    .version = "1.0.0",
                    .tables = &target_tables,
                };

                var detector = MigrationDetector.init(allocator, &db);
                const plan = try detector.detectChanges(target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.create_table, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table_name);
                try std.testing.expect(plan.changes[0].field == null);
                try std.testing.expect(!plan.is_destructive);
            },
            1 => {
                // Table exists with one column; target adds a new column → expect add_column
                var existing_fields = [_]schema_parser.Field{makeField("title", .text)};
                const existing_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &existing_fields }};
                const existing_ddl = try gen.generateDDL(existing_tables[0]);
                defer allocator.free(existing_ddl);
                try execDDL(&db, allocator, existing_ddl);

                const new_fname = field_names[rand.intRangeAtMost(usize, 1, field_names.len - 1)];
                var target_fields = [_]schema_parser.Field{
                    makeField("title", .text),
                    makeField(new_fname, .integer),
                };
                var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
                const target_schema = schema_parser.Schema{
                    .version = "1.0.0",
                    .tables = &target_tables,
                };

                var detector = MigrationDetector.init(allocator, &db);
                const plan = try detector.detectChanges(target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.add_column, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table_name);
                try std.testing.expect(plan.changes[0].field != null);
                try std.testing.expectEqualStrings(new_fname, plan.changes[0].field.?.name);
                try std.testing.expect(!plan.is_destructive);
            },
            2 => {
                // Table exists with TEXT column; target changes it to INTEGER → expect change_type
                var existing_fields = [_]schema_parser.Field{makeField("status", .text)};
                const existing_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &existing_fields }};
                const existing_ddl = try gen.generateDDL(existing_tables[0]);
                defer allocator.free(existing_ddl);
                try execDDL(&db, allocator, existing_ddl);

                var target_fields = [_]schema_parser.Field{makeField("status", .integer)};
                var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
                const target_schema = schema_parser.Schema{
                    .version = "1.0.0",
                    .tables = &target_tables,
                };

                var detector = MigrationDetector.init(allocator, &db);
                const plan = try detector.detectChanges(target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.change_type, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table_name);
                try std.testing.expect(plan.is_destructive);
            },
            else => {
                // Table exists with extra column not in target → expect remove_column
                var existing_fields = [_]schema_parser.Field{
                    makeField("title", .text),
                    makeField("extra_col", .text),
                };
                const existing_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &existing_fields }};
                const existing_ddl = try gen.generateDDL(existing_tables[0]);
                defer allocator.free(existing_ddl);
                try execDDL(&db, allocator, existing_ddl);

                var target_fields = [_]schema_parser.Field{makeField("title", .text)};
                var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
                const target_schema = schema_parser.Schema{
                    .version = "1.0.0",
                    .tables = &target_tables,
                };

                var detector = MigrationDetector.init(allocator, &db);
                const plan = try detector.detectChanges(target_schema);
                defer detector.deinit(plan);

                try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
                try std.testing.expectEqual(ChangeKind.remove_column, plan.changes[0].kind);
                try std.testing.expectEqualStrings(tname, plan.changes[0].table_name);
                try std.testing.expect(plan.is_destructive);
            },
        }
    }
}

// Feature: schema-aware-storage, Property 19: Matching version produces empty migration plan
// For any database whose schema matches the target Schema exactly,
// Migration_Detector.detectChanges SHALL return a MigrationPlan with zero changes.
test "migration_detector: property 19 - matching schema produces empty migration plan" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();

    const table_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const field_names = [_][]const u8{ "col_a", "col_b", "col_c", "col_d" };
    const field_types = [_]schema_parser.FieldType{ .text, .integer, .real };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);

        const n_tables = rand.intRangeAtMost(usize, 1, 3);
        const tables = try allocator.alloc(schema_parser.Table, n_tables);
        defer {
            for (tables) |t| allocator.free(t.fields);
            allocator.free(tables);
        }

        for (0..n_tables) |ti| {
            const tname = table_names[ti % table_names.len];
            const n_fields = rand.intRangeAtMost(usize, 1, 3);
            const fields = try allocator.alloc(schema_parser.Field, n_fields);

            for (0..n_fields) |fi| {
                fields[fi] = makeField(
                    field_names[fi % field_names.len],
                    field_types[rand.intRangeAtMost(usize, 0, field_types.len - 1)],
                );
            }

            tables[ti] = .{ .name = tname, .fields = fields };

            const ddl = try gen.generateDDL(tables[ti]);
            defer allocator.free(ddl);
            try execDDL(&db, allocator, ddl);
        }

        const target_schema = schema_parser.Schema{
            .version = "1.0.0",
            .tables = tables,
        };

        var detector = MigrationDetector.init(allocator, &db);
        const plan = try detector.detectChanges(target_schema);
        defer detector.deinit(plan);

        if (plan.changes.len != 0) {
            std.debug.print("iter {d}: expected 0 changes, got {d}\n", .{ iter, plan.changes.len });
            for (plan.changes) |c| {
                std.debug.print("  change: kind={s} table={s}\n", .{ @tagName(c.kind), c.table_name });
            }
        }
        try std.testing.expectEqual(@as(usize, 0), plan.changes.len);
        try std.testing.expect(!plan.is_destructive);
    }
}
