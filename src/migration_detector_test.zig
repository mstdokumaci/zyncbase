const std = @import("std");

const sqlite = @import("sqlite");

const migration_detector = @import("migration_detector.zig");
const schema_parse = @import("schema/parse.zig");
const schema_helpers = @import("schema/test_helpers.zig");
const schema_types = @import("schema/types.zig");
const ddl_generator = @import("sql/ddl.zig");

const ChangeKind = migration_detector.ChangeKind;
const MigrationDetector = migration_detector.MigrationDetector;

fn openMemDb() !sqlite.Db {
    return sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
}

test "foreign key migration detector finds missing constraints and action drift" {
    const allocator = std.testing.allocator;
    var db = try openMemDb();
    defer db.deinit();
    var gen = ddl_generator.DDLGenerator.init(allocator);

    var target = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.1","store":{"parents":{"fields":{}},"children":{"fields":{"parent_id":{"type":"string","references":"parents","onDelete":"cascade"}}}}}
    );
    defer target.deinit();

    for (target.tables) |table| {
        if (!std.mem.eql(u8, table.name, "children")) try execTableDDL(&db, allocator, &gen, table);
    }
    try db.exec(
        "CREATE TABLE children (id BLOB NOT NULL, namespace_id INTEGER NOT NULL, owner_id BLOB NOT NULL, parent_id BLOB, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(id))",
        .{},
        .{},
    );

    var detector = MigrationDetector.init(allocator, &db, &target);
    const missing_plan = try detector.detectChanges(&target);
    defer detector.deinit(missing_plan);
    try std.testing.expectEqual(@as(usize, 1), missing_plan.changes.len);
    try std.testing.expectEqual(ChangeKind.change_foreign_keys, missing_plan.changes[0].kind);
    try std.testing.expect(missing_plan.is_destructive);

    const child = target.table("children") orelse return error.TestExpectedValue;
    const child_ddl = try gen.generateDDL(child.*);
    defer allocator.free(child_ddl);
    try db.exec("DROP TABLE children", .{}, .{});
    try execDDL(&db, allocator, child_ddl);

    const matching_plan = try detector.detectChanges(&target);
    defer detector.deinit(matching_plan);
    try std.testing.expectEqual(@as(usize, 0), matching_plan.changes.len);

    try db.exec("DROP INDEX idx__children__field__parent_id", .{}, .{});
    const missing_index_plan = try detector.detectChanges(&target);
    defer detector.deinit(missing_index_plan);
    try std.testing.expectEqual(@as(usize, 1), missing_index_plan.changes.len);
    try std.testing.expectEqual(ChangeKind.change_indexes, missing_index_plan.changes[0].kind);
    try std.testing.expect(!missing_index_plan.is_destructive);

    try db.exec("CREATE INDEX idx__children__field__parent_id ON children(parent_id) WHERE parent_id IS NOT NULL", .{}, .{});
    const partial_index_plan = try detector.detectChanges(&target);
    defer detector.deinit(partial_index_plan);
    try std.testing.expectEqual(@as(usize, 1), partial_index_plan.changes.len);
    try std.testing.expectEqual(ChangeKind.change_indexes, partial_index_plan.changes[0].kind);

    try db.exec("DROP INDEX idx__children__field__parent_id", .{}, .{});
    try db.exec("CREATE UNIQUE INDEX idx__children__field__parent_id ON children(parent_id)", .{}, .{});
    const unique_index_plan = try detector.detectChanges(&target);
    defer detector.deinit(unique_index_plan);
    try std.testing.expectEqual(@as(usize, 1), unique_index_plan.changes.len);
    try std.testing.expectEqual(ChangeKind.change_indexes, unique_index_plan.changes[0].kind);

    try db.exec("DROP TABLE children", .{}, .{});
    try db.exec(
        "CREATE TABLE children (id BLOB NOT NULL, namespace_id INTEGER NOT NULL, owner_id BLOB NOT NULL, parent_id BLOB, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(id), FOREIGN KEY(parent_id) REFERENCES parents(id) ON DELETE RESTRICT)",
        .{},
        .{},
    );
    const action_plan = try detector.detectChanges(&target);
    defer detector.deinit(action_plan);
    try std.testing.expectEqual(@as(usize, 1), action_plan.changes.len);
    try std.testing.expectEqual(ChangeKind.change_foreign_keys, action_plan.changes[0].kind);
    try std.testing.expect(action_plan.is_destructive);
}

fn execDDL(db: *sqlite.Db, allocator: std.mem.Allocator, ddl: []const u8) !void {
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try db.execMulti(ddl_z, .{});
}

fn execTableDDL(db: *sqlite.Db, allocator: std.mem.Allocator, gen: *ddl_generator.DDLGenerator, table: schema_types.Table) !void {
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    try execDDL(db, allocator, ddl);
}

fn execSchemaDDL(db: *sqlite.Db, allocator: std.mem.Allocator, gen: *ddl_generator.DDLGenerator, schema_value: *const schema_types.Schema) !void {
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

    const table_names = [_][]const u8{ "posts", "items", "orders", "tags", "comments" };

    // Exhaustive over all table names x all four diff scenarios. The implicit
    // "users" table matches in every scenario, so exactly one change is expected.
    for (table_names) |tname| {
        for (0..4) |scenario_raw| {
            const scenario: u8 = @intCast(scenario_raw);

            var db = try openMemDb();
            defer db.deinit();

            var gen = ddl_generator.DDLGenerator.init(allocator);

            switch (scenario) {
                0 => {
                    // Table doesn't exist in DB → expect create_table
                    var target_fields = [_]schema_types.Field{schema_helpers.makeField("title", .text)};
                    var target_tables = [_]schema_types.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                    defer {
                        allocator.free(target_tables[0].name);
                        allocator.free(target_tables[0].name_quoted);
                    }
                    var target_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &target_tables);
                    defer target_schema.deinit();
                    const users_table = target_schema.table("users") orelse return error.TestExpectedValue;
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
                    var existing_fields = [_]schema_types.Field{schema_helpers.makeField("title", .text)};
                    const existing_tables = [_]schema_types.Table{try schema_helpers.makeTableAlloc(allocator, tname, &existing_fields)};
                    defer {
                        allocator.free(existing_tables[0].name);
                        allocator.free(existing_tables[0].name_quoted);
                    }
                    const existing_ddl = try gen.generateDDL(existing_tables[0]);
                    defer allocator.free(existing_ddl);
                    try execDDL(&db, allocator, existing_ddl);

                    var existing_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &existing_tables);
                    defer existing_schema.deinit();
                    const users_table = existing_schema.table("users") orelse return error.TestExpectedValue;
                    try execTableDDL(&db, allocator, &gen, users_table.*);

                    const new_fname = "count";
                    const new_field = try schema_helpers.makeFieldAlloc(allocator, new_fname, .integer);
                    var target_fields = [_]schema_types.Field{
                        schema_helpers.makeField("title", .text),
                        new_field,
                    };
                    var target_tables = [_]schema_types.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                    defer {
                        allocator.free(target_tables[0].name);
                        allocator.free(target_tables[0].name_quoted);
                        allocator.free(new_field.name);
                        allocator.free(new_field.name_quoted);
                    }
                    var target_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &target_tables);
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
                    var existing_fields = [_]schema_types.Field{schema_helpers.makeField("status", .text)};
                    const existing_tables = [_]schema_types.Table{try schema_helpers.makeTableAlloc(allocator, tname, &existing_fields)};
                    defer {
                        allocator.free(existing_tables[0].name);
                        allocator.free(existing_tables[0].name_quoted);
                    }
                    const existing_ddl = try gen.generateDDL(existing_tables[0]);
                    defer allocator.free(existing_ddl);
                    try execDDL(&db, allocator, existing_ddl);

                    var existing_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &existing_tables);
                    defer existing_schema.deinit();
                    const users_table = existing_schema.table("users") orelse return error.TestExpectedValue;
                    try execTableDDL(&db, allocator, &gen, users_table.*);

                    var target_fields = [_]schema_types.Field{schema_helpers.makeField("status", .integer)};
                    var target_tables = [_]schema_types.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                    defer {
                        allocator.free(target_tables[0].name);
                        allocator.free(target_tables[0].name_quoted);
                    }
                    var target_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &target_tables);
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
                    var existing_fields = [_]schema_types.Field{
                        schema_helpers.makeField("title", .text),
                        schema_helpers.makeField("extra_col", .text),
                    };
                    const existing_tables = [_]schema_types.Table{try schema_helpers.makeTableAlloc(allocator, tname, &existing_fields)};
                    defer {
                        allocator.free(existing_tables[0].name);
                        allocator.free(existing_tables[0].name_quoted);
                    }
                    const existing_ddl = try gen.generateDDL(existing_tables[0]);
                    defer allocator.free(existing_ddl);
                    try execDDL(&db, allocator, existing_ddl);

                    var existing_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &existing_tables);
                    defer existing_schema.deinit();
                    const users_table = existing_schema.table("users") orelse return error.TestExpectedValue;
                    try execTableDDL(&db, allocator, &gen, users_table.*);

                    var target_fields = [_]schema_types.Field{schema_helpers.makeField("title", .text)};
                    var target_tables = [_]schema_types.Table{try schema_helpers.makeTableAlloc(allocator, tname, &target_fields)};
                    defer {
                        allocator.free(target_tables[0].name);
                        allocator.free(target_tables[0].name_quoted);
                    }
                    var target_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &target_tables);
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
}

// Feature: schema-aware-storage, Property 19: Matching version produces empty migration plan
// For any database whose schema matches the target Schema exactly,
// Migration_Detector.detectChanges SHALL return a MigrationPlan with zero changes.
test "migration_detector: matching schema produces empty migration plan" {
    const allocator = std.testing.allocator;

    const table_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const field_names = [_][]const u8{ "col_a", "col_b", "col_c", "col_d" };
    const field_types = [_]schema_types.FieldType{ .text, .integer, .real };

    // Exhaustive over table counts (1..3) and name/type offsets so every
    // combination of field count, name, and type is exercised.
    for (1..4) |n_tables| {
        for (0..4) |offset| {
            var db = try openMemDb();
            defer db.deinit();

            var gen = ddl_generator.DDLGenerator.init(allocator);

            const tables = try allocator.alloc(schema_types.Table, n_tables);
            var tables_ok = false;
            defer {
                if (tables_ok) {
                    for (tables) |t| {
                        allocator.free(t.name);
                        allocator.free(t.name_quoted);
                        for (t.fields) |f| {
                            allocator.free(f.name);
                            allocator.free(f.name_quoted);
                        }
                        allocator.free(t.fields);
                    }
                }
                allocator.free(tables);
            }

            for (0..n_tables) |ti| {
                const tname = table_names[(ti + offset) % table_names.len];
                const n_fields = 1 + ((ti + offset) % 3);
                const fields = try allocator.alloc(schema_types.Field, n_fields);
                var filled: usize = 0;
                errdefer {
                    for (fields[0..filled]) |f| {
                        allocator.free(f.name);
                        allocator.free(f.name_quoted);
                    }
                    allocator.free(fields);
                }

                for (0..n_fields) |fi| {
                    const mf_name = field_names[fi % field_names.len];
                    const mf_type = field_types[(fi + offset) % field_types.len];
                    fields[fi] = try schema_helpers.makeFieldAlloc(allocator, mf_name, mf_type);
                    filled += 1;
                }

                // makeTableAlloc takes ownership of `fields` (freed via tables_ok above).
                tables[ti] = try schema_helpers.makeTableAlloc(allocator, tname, fields);
            }
            tables_ok = true;

            var target_schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", tables);
            defer target_schema.deinit();
            try execSchemaDDL(&db, allocator, &gen, &target_schema);

            var detector = MigrationDetector.init(allocator, &db, &target_schema);
            const plan = try detector.detectChanges(&target_schema);
            defer detector.deinit(plan);

            try std.testing.expectEqual(@as(usize, 0), plan.changes.len);
            try std.testing.expect(!plan.is_destructive);
        }
    }
}

// ─── Managed-index drift detection (incl. user unique constraints) ──────────

const unique_schema_json =
    \\{"version":"1.1.0","store":{"projects":{
    \\  "required":["slug","provider","externalId"],
    \\  "fields":{
    \\    "slug":{"type":"string"},
    \\    "provider":{"type":"string"},
    \\    "externalId":{"type":"string"}
    \\  },
    \\  "unique":[["slug"],["provider","externalId"]]
    \\}}}
;

fn testDetectChanges(allocator: std.mem.Allocator, db: *sqlite.Db, target: *const schema_types.Schema) !migration_detector.MigrationPlan {
    var detector = MigrationDetector.init(allocator, db, target);
    return detector.detectChanges(target);
}

test "migration_detector: exact managed indexes produce no migration" {
    const allocator = std.testing.allocator;
    var db = try openMemDb();
    defer db.deinit();
    var gen = ddl_generator.DDLGenerator.init(allocator);

    var target = try schema_parse.initFromJson(allocator, unique_schema_json);
    defer target.deinit();
    try execSchemaDDL(&db, allocator, &gen, &target);

    const plan = try testDetectChanges(allocator, &db, &target);
    defer detectorDeinit(&plan, allocator);
    try std.testing.expectEqual(@as(usize, 0), plan.changes.len);
}

fn detectorDeinit(plan: *const migration_detector.MigrationPlan, allocator: std.mem.Allocator) void {
    for (plan.changes) |c| {
        if (c.field) |f| f.deinit(allocator);
    }
    allocator.free(plan.changes);
}

fn expectSingleIndexChange(allocator: std.mem.Allocator, db: *sqlite.Db, target: *const schema_types.Schema) !void {
    const plan = try testDetectChanges(allocator, db, target);
    defer detectorDeinit(&plan, allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.changes.len);
    try std.testing.expectEqual(ChangeKind.change_indexes, plan.changes[0].kind);
    try std.testing.expect(!plan.is_destructive);
}

test "migration_detector: missing wrong and obsolete user unique indexes are detected" {
    const allocator = std.testing.allocator;
    var gen = ddl_generator.DDLGenerator.init(allocator);

    // Missing index
    {
        var db = try openMemDb();
        defer db.deinit();
        var target = try schema_parse.initFromJson(allocator, unique_schema_json);
        defer target.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target);
        try db.exec("DROP INDEX \"uidx__projects__constraint__0\"", .{}, .{});
        try expectSingleIndexChange(allocator, &db, &target);
    }

    // Wrong uniqueness flag
    {
        var db = try openMemDb();
        defer db.deinit();
        var target = try schema_parse.initFromJson(allocator, unique_schema_json);
        defer target.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target);
        try db.exec("DROP INDEX \"uidx__projects__constraint__0\"", .{}, .{});
        try db.exec("CREATE INDEX \"uidx__projects__constraint__0\" ON \"projects\"(\"namespace_id\", \"slug\")", .{}, .{});
        try expectSingleIndexChange(allocator, &db, &target);
    }

    // Partial flag
    {
        var db = try openMemDb();
        defer db.deinit();
        var target = try schema_parse.initFromJson(allocator, unique_schema_json);
        defer target.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target);
        try db.exec("DROP INDEX \"uidx__projects__constraint__0\"", .{}, .{});
        try db.exec("CREATE UNIQUE INDEX \"uidx__projects__constraint__0\" ON \"projects\"(\"namespace_id\", \"slug\") WHERE slug IS NOT NULL", .{}, .{});
        try expectSingleIndexChange(allocator, &db, &target);
    }

    // Wrong column order
    {
        var db = try openMemDb();
        defer db.deinit();
        var target = try schema_parse.initFromJson(allocator, unique_schema_json);
        defer target.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target);
        try db.exec("DROP INDEX \"uidx__projects__constraint__1\"", .{}, .{});
        try db.exec("CREATE UNIQUE INDEX \"uidx__projects__constraint__1\" ON \"projects\"(\"namespace_id\", \"externalId\", \"provider\")", .{}, .{});
        try expectSingleIndexChange(allocator, &db, &target);
    }

    // Wrong column set
    {
        var db = try openMemDb();
        defer db.deinit();
        var target = try schema_parse.initFromJson(allocator, unique_schema_json);
        defer target.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target);
        try db.exec("DROP INDEX \"uidx__projects__constraint__1\"", .{}, .{});
        try db.exec("CREATE UNIQUE INDEX \"uidx__projects__constraint__1\" ON \"projects\"(\"provider\")", .{}, .{});
        try expectSingleIndexChange(allocator, &db, &target);
    }

    // Obsolete reserved-prefix index left behind by a removed constraint
    {
        var db = try openMemDb();
        defer db.deinit();
        var target = try schema_parse.initFromJson(allocator, unique_schema_json);
        defer target.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target);
        try db.exec("CREATE UNIQUE INDEX \"uidx__projects__constraint__2\" ON \"projects\"(\"namespace_id\", \"slug\", \"provider\")", .{}, .{});
        try expectSingleIndexChange(allocator, &db, &target);
    }

    // Unrelated manual indexes are ignored
    {
        var db = try openMemDb();
        defer db.deinit();
        var target = try schema_parse.initFromJson(allocator, unique_schema_json);
        defer target.deinit();
        try execSchemaDDL(&db, allocator, &gen, &target);
        try db.exec("CREATE INDEX manual_operator_index ON projects(provider)", .{}, .{});
        const plan = try testDetectChanges(allocator, &db, &target);
        defer detectorDeinit(&plan, allocator);
        try std.testing.expectEqual(@as(usize, 0), plan.changes.len);
    }
}

test "migration_detector: missing system field reference and identity indexes are repaired" {
    const allocator = std.testing.allocator;
    var gen = ddl_generator.DDLGenerator.init(allocator);
    var db = try openMemDb();
    defer db.deinit();

    var target = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"parents":{"fields":{}},"children":{"fields":{"parent_id":{"type":"string","references":"users"}}}}}
    );
    defer target.deinit();
    try execSchemaDDL(&db, allocator, &gen, &target);

    // Drop one of each managed index class; all must be reported for repair.
    try db.exec("DROP INDEX \"idx__children__namespace\"", .{}, .{});
    try db.exec("DROP INDEX \"idx__children__owner\"", .{}, .{});
    try db.exec("DROP INDEX \"idx__children__field__parent_id\"", .{}, .{});
    try db.exec("DROP INDEX \"uidx__users__identity\"", .{}, .{});

    const plan = try testDetectChanges(allocator, &db, &target);
    defer detectorDeinit(&plan, allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.changes.len); // children + users, at most one entry per table
    for (plan.changes) |change| {
        try std.testing.expectEqual(ChangeKind.change_indexes, change.kind);
    }
}

test "migration_detector: rebuild-classified changes suppress redundant index reconciliation" {
    const allocator = std.testing.allocator;

    var target = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"tasks":{"fields":{"status":{"type":"string","indexed":true},"title":{"type":"string"}},"unique":[["title"]]}}}
    );
    defer target.deinit();

    // Existing table lacks the status column and every managed index, and its
    // title column has drifted from TEXT to BLOB → destructive rebuild path.
    var db = try openMemDb();
    defer db.deinit();
    try db.exec(
        "CREATE TABLE tasks (id BLOB NOT NULL, namespace_id INTEGER NOT NULL, owner_id BLOB NOT NULL, title BLOB, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(id))",
        .{},
        .{},
    );

    const plan = try testDetectChanges(allocator, &db, &target);
    defer detectorDeinit(&plan, allocator);
    try std.testing.expect(plan.is_destructive);
    for (plan.changes) |change| {
        try std.testing.expect(change.kind != .change_indexes);
    }

    // The rebuild itself is still scheduled alongside the additive column.
    var saw_change_type = false;
    var saw_add_column = false;
    for (plan.changes) |change| {
        if (change.kind == .change_type) saw_change_type = true;
        if (change.kind == .add_column) saw_add_column = true;
    }
    try std.testing.expect(saw_change_type and saw_add_column);
}
