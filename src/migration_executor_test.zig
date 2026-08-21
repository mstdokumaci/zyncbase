const std = @import("std");

const sqlite = @import("sqlite");

const migration_detector = @import("migration_detector.zig");
const migration_executor = @import("migration_executor.zig");
const schema_parse = @import("schema/parse.zig");
const schema_helpers = @import("schema/test_helpers.zig");
const schema_types = @import("schema/types.zig");
const ddl_generator = @import("sql/ddl.zig");

const MigrationExecutor = migration_executor.MigrationExecutor;

const zero_doc_id = [_]u8{0} ** 16;

fn openMemDb() !sqlite.Db {
    return sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
    });
}

fn execSql(db: *sqlite.Db, allocator: std.mem.Allocator, sql: []const u8) !void {
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    try db.execDynamic(sql_z, .{}, .{});
}

fn execMultiSql(db: *sqlite.Db, allocator: std.mem.Allocator, sql: []const u8) !void {
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    try db.execMulti(sql_z, .{});
}

test "foreign key migration rebuilds constraints without triggering cascades" {
    const allocator = std.testing.allocator;
    var db = try openMemDb();
    defer db.deinit();
    var gen = ddl_generator.DDLGenerator.init(allocator);

    var target = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.1","store":{"parents":{"fields":{}},"children":{"fields":{"parent_id":{"type":"string","references":"parents","onDelete":"cascade"}}}}}
    );
    defer target.deinit();
    const parents = target.table("parents") orelse return error.TestExpectedValue;
    const parent_ddl = try gen.generateDDL(parents.*);
    defer allocator.free(parent_ddl);
    try execMultiSql(&db, allocator, parent_ddl);
    try db.exec(
        "CREATE TABLE children (id BLOB NOT NULL, namespace_id INTEGER NOT NULL, owner_id BLOB NOT NULL, parent_id BLOB, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(id))",
        .{},
        .{},
    );
    try db.exec("INSERT INTO parents VALUES (zeroblob(16), 1, zeroblob(16), 0, 0)", .{}, .{});
    try db.exec("INSERT INTO children VALUES (randomblob(16), 2, zeroblob(16), zeroblob(16), 0, 0)", .{}, .{});
    _ = try db.pragma(void, .{}, "foreign_keys", "on");

    const children = target.table("children") orelse return error.TestExpectedValue;
    const changes = [_]migration_detector.Change{.{
        .kind = .change_foreign_keys,
        .table = children,
        .field = null,
    }};
    var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{ .allow_destructive = true });
    try executor.execute(.{ .changes = @constCast(&changes), .is_destructive = true }, target.version);

    try std.testing.expectEqual(@as(?i64, 1), try db.pragma(i64, .{}, "foreign_keys", null));
    const child_count = try db.one(i64, "SELECT count(*) FROM children", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 1), child_count);
    const action = try db.oneAlloc([]const u8, allocator, "SELECT on_delete FROM pragma_foreign_key_list('children')", .{}, .{});
    defer if (action) |value| allocator.free(value);
    try std.testing.expect(action != null);
    try std.testing.expectEqualStrings("CASCADE", action.?);
}

test "foreign key index migration replaces partial indexes in place" {
    const allocator = std.testing.allocator;
    var db = try openMemDb();
    defer db.deinit();
    var gen = ddl_generator.DDLGenerator.init(allocator);

    var target = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.1","store":{"parents":{"fields":{}},"children":{"fields":{"parent_id":{"type":"string","references":"parents"}}}}}
    );
    defer target.deinit();
    for (target.tables) |table| {
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        try execMultiSql(&db, allocator, ddl);
    }
    try db.exec("DROP INDEX idx_children_parent_id", .{}, .{});
    try db.exec("CREATE INDEX idx_children_parent_id ON children(parent_id) WHERE parent_id IS NOT NULL", .{}, .{});

    const children = target.table("children") orelse return error.TestExpectedValue;
    const changes = [_]migration_detector.Change{.{
        .kind = .change_foreign_key_indexes,
        .table = children,
        .field = null,
    }};
    var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{});
    try executor.execute(.{ .changes = @constCast(&changes), .is_destructive = false }, target.version);

    const partial = try db.one(i64, "SELECT partial FROM pragma_index_list('children') WHERE name = 'idx_children_parent_id'", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 0), partial);
}

// Unit test 5.5: destructive migration with allow_destructive = true preserves common-column data
test "migration_executor: 5.5 - destructive migration preserves common-column data" {
    const allocator = std.testing.allocator;

    var db = try openMemDb();
    defer db.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);

    // Create table with [title TEXT, status TEXT]
    var initial_fields = [_]schema_types.Field{
        schema_helpers.makeField("title", .text),
        schema_helpers.makeField("status", .text),
    };
    const initial_table = schema_helpers.makeTable("tasks", &initial_fields);
    const initial_ddl = try gen.generateDDL(initial_table);
    defer allocator.free(initial_ddl);
    try execMultiSql(&db, allocator, initial_ddl);

    // Insert a row
    try execSql(&db, allocator, "INSERT INTO tasks (id, namespace_id, owner_id, title, status, created_at, updated_at) VALUES (zeroblob(16), 1, zeroblob(16), 'My Task', 'open', 0, 0)");

    // Target schema: status is now INTEGER
    var target_fields = [_]schema_types.Field{
        schema_helpers.makeField("title", .text),
        schema_helpers.makeField("status", .integer),
    };
    var target_tables = [_]schema_types.Table{schema_helpers.makeTable("tasks", &target_fields)};
    const target_version = "1.0.0";

    // Build change_type migration: status TEXT -> INTEGER
    const changes = try allocator.alloc(migration_detector.Change, 1);
    defer allocator.free(changes);
    changes[0] = .{
        .kind = .change_type,
        .table = &target_tables[0],
        .field = schema_helpers.makeField("status", .integer),
    };

    const plan = migration_detector.MigrationPlan{
        .changes = changes,
        .is_destructive = true,
    };

    var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = true,
    });

    try executor.execute(plan, target_version);

    // Verify the row still exists with title intact
    var stmt = try db.prepare("SELECT id, title FROM tasks WHERE id = zeroblob(16)");
    defer stmt.deinit();

    const Row = struct {
        id: []const u8,
        title: []const u8,
    };
    var iter = try stmt.iteratorAlloc(Row, allocator, .{});
    const row = try iter.nextAlloc(allocator, .{});
    try std.testing.expect(row != null);
    defer {
        allocator.free(row.?.id);
        allocator.free(row.?.title);
    }
    try std.testing.expectEqualSlices(u8, &zero_doc_id, row.?.id);
    try std.testing.expectEqualStrings("My Task", row.?.title);
}

// Unit test 5.7: empty schema_meta triggers full schema creation
test "migration_executor: 5.7 - empty schema_meta triggers full schema creation" {
    const allocator = std.testing.allocator;

    var db = try openMemDb();
    defer db.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);

    // No schema_meta, no tables - start fresh
    // Build a create_table plan
    var target_fields = [_]schema_types.Field{
        schema_helpers.makeField("username", .text),
        schema_helpers.makeField("email", .text),
    };
    var target_tables = [_]schema_types.Table{schema_helpers.makeTable("users", &target_fields)};
    const target_version = "1.0.0";

    const changes = try allocator.alloc(migration_detector.Change, 1);
    defer allocator.free(changes);
    changes[0] = .{
        .kind = .create_table,
        .table = &target_tables[0],
        .field = null,
    };

    const plan = migration_detector.MigrationPlan{
        .changes = changes,
        .is_destructive = false,
    };

    var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = false,
    });

    try executor.execute(plan, target_version);

    // Verify the table was created
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='users'");
    defer stmt.deinit();

    const NameRow = struct { name: []const u8 };
    var iter = try stmt.iteratorAlloc(NameRow, allocator, .{});
    const row = try iter.nextAlloc(allocator, .{});
    try std.testing.expect(row != null);
    defer allocator.free(row.?.name);
    try std.testing.expectEqualStrings("users", row.?.name);

    // Verify schema_meta was created and has the version
    var meta_stmt = try db.prepare("SELECT version FROM schema_meta LIMIT 1");
    defer meta_stmt.deinit();

    const VersionRow = struct { version: []const u8 };
    var meta_iter = try meta_stmt.iteratorAlloc(VersionRow, allocator, .{});
    const ver_row = try meta_iter.nextAlloc(allocator, .{});
    try std.testing.expect(ver_row != null);
    defer allocator.free(ver_row.?.version);
    try std.testing.expectEqualStrings("1.0.0", ver_row.?.version);
}

// Unit test 5.8: unparseable version in schema_meta halts startup
test "migration_executor: 5.8 - unparseable version in schema_meta halts startup" {
    const allocator = std.testing.allocator;

    var db = try openMemDb();
    defer db.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);

    // Insert a bad version into schema_meta
    try execSql(&db, allocator, "CREATE TABLE IF NOT EXISTS schema_meta (version TEXT NOT NULL, applied_at INTEGER NOT NULL)");
    try execSql(&db, allocator, "INSERT INTO schema_meta (version, applied_at) VALUES ('not-a-version', 0)");

    // Build a simple add_column plan (non-destructive so it won't be refused for that reason)
    // We need a table to exist first
    var fields = [_]schema_types.Field{schema_helpers.makeField("data", .text)};
    const table = schema_helpers.makeTable("docs", &fields);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    try execMultiSql(&db, allocator, ddl);

    var target_fields = [_]schema_types.Field{
        schema_helpers.makeField("data", .text),
        schema_helpers.makeField("extra", .text),
    };
    var target_tables = [_]schema_types.Table{schema_helpers.makeTable("docs", &target_fields)};
    const target_version = "1.0.0";

    const changes = try allocator.alloc(migration_detector.Change, 1);
    defer allocator.free(changes);
    changes[0] = .{
        .kind = .add_column,
        .table = &target_tables[0],
        .field = schema_helpers.makeField("extra", .text),
    };

    const plan = migration_detector.MigrationPlan{
        .changes = changes,
        .is_destructive = false,
    };

    var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = false,
    });

    const result = executor.execute(plan, target_version);
    try std.testing.expectError(error.InvalidVersion, result);
}

fn insertSchemaMetaVersion(db: *sqlite.Db, allocator: std.mem.Allocator, version: []const u8) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS schema_meta (version TEXT NOT NULL, applied_at INTEGER NOT NULL)", .{}, .{});
    try db.exec("DELETE FROM schema_meta", .{}, .{});
    const sql = try std.fmt.allocPrint(allocator, "INSERT INTO schema_meta (version, applied_at) VALUES ('{s}', 0)", .{version});
    defer allocator.free(sql);
    try execSql(db, allocator, sql);
}

/// Returns the declared type of `column_name` in `table_name` via PRAGMA table_info,
/// or null if the column is absent. The returned slice is owned by the caller.
fn columnType(db: *sqlite.Db, allocator: std.mem.Allocator, table_name: []const u8, column_name: []const u8) !?[]const u8 {
    const pragma_sql = try std.fmt.allocPrint(allocator, "PRAGMA table_info({s})", .{table_name});
    defer allocator.free(pragma_sql);
    var stmt = try db.prepareDynamic(pragma_sql);
    defer stmt.deinit();

    const PragmaRow = struct {
        cid: i64,
        name: []const u8,
        type: []const u8,
        notnull: i64,
        dflt_value: ?[]const u8,
        pk: i64,
    };
    var iter = try stmt.iteratorAlloc(PragmaRow, allocator, .{});
    while (try iter.nextAlloc(allocator, .{})) |row| {
        defer {
            allocator.free(row.name);
            allocator.free(row.type);
            if (row.dflt_value) |dv| allocator.free(dv);
        }
        if (std.mem.eql(u8, row.name, column_name)) return try allocator.dupe(u8, row.type);
    }
    return null;
}

// Feature: schema-aware-storage, Property 10: Additive migration preserves existing data
// For any database state and additive MigrationPlan (containing only create_table and add_column
// changes), after Migration_Executor.execute completes, every row that existed before the migration
// SHALL still exist with all its original column values intact.
test "migration_executor: additive migration preserves existing data" {
    const allocator = std.testing.allocator;

    const table_names = [_][]const u8{ "posts", "items", "orders", "tags", "comments" };

    for (table_names) |tname| {
        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);

        // Create table with initial columns
        var initial_table = schema_helpers.makeSingleRuntimeTable(allocator, tname, &[_]schema_helpers.TestFieldDef{
            .{ .name = "title", .field_type = .text },
        });
        defer initial_table.deinit(allocator);
        const initial_ddl = try gen.generateDDL(initial_table);
        defer allocator.free(initial_ddl);
        try execMultiSql(&db, allocator, initial_ddl);

        // Insert a row
        const row_title = "hello world";
        const insert_sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO {s} (id, namespace_id, owner_id, title, created_at, updated_at) VALUES (zeroblob(16), 1, zeroblob(16), '{s}', 0, 0)",
            .{ tname, row_title },
        );
        defer allocator.free(insert_sql);
        try execSql(&db, allocator, insert_sql);

        // Target schema has both columns
        var target_table = schema_helpers.makeSingleRuntimeTable(allocator, tname, &[_]schema_helpers.TestFieldDef{
            .{ .name = "title", .field_type = .text },
            .{ .name = "score", .field_type = .integer },
        });
        defer target_table.deinit(allocator);
        const target_version = "1.0.0";

        // Build additive migration plan: add a new column
        const new_field = schema_helpers.makeField("score", .integer);

        const changes = try allocator.alloc(migration_detector.Change, 1);
        defer allocator.free(changes);
        changes[0] = .{
            .kind = .add_column,
            .table = &target_table,
            .field = new_field,
        };

        const plan = migration_detector.MigrationPlan{
            .changes = changes,
            .is_destructive = false,
        };

        var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{
            .auto_migrate = .full,
            .allow_destructive = false,
        });

        try executor.execute(plan, target_version);

        // Verify the original row still exists with original values
        const check_sql = try std.fmt.allocPrint(
            allocator,
            "SELECT id, title FROM {s} WHERE id = zeroblob(16)",
            .{tname},
        );
        defer allocator.free(check_sql);

        var stmt = try db.prepareDynamic(check_sql);
        defer stmt.deinit();

        const CheckRow = struct {
            id: []const u8,
            title: []const u8,
        };
        var check_iter = try stmt.iteratorAlloc(CheckRow, allocator, .{});
        const row = try check_iter.nextAlloc(allocator, .{});
        try std.testing.expect(row != null);
        defer {
            allocator.free(row.?.id);
            allocator.free(row.?.title);
        }
        try std.testing.expectEqualSlices(u8, &zero_doc_id, row.?.id);
        try std.testing.expectEqualStrings(row_title, row.?.title);
    }
}

// Feature: schema-aware-storage, Property 11: Destructive migration is refused when not allowed
// For any MigrationPlan that contains at least one change_type or remove_column change,
// when MigrationConfig.allow_destructive is false, Migration_Executor.execute SHALL return
// an error and SHALL NOT modify the database.
test "migration_executor: destructive migration refused when not allowed" {
    const allocator = std.testing.allocator;

    const table_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const destructive_kinds = [_]migration_detector.ChangeKind{ .change_type, .remove_column, .change_foreign_keys };

    for (table_names) |tname| {
        for (destructive_kinds) |kind| {
            var db = try openMemDb();
            defer db.deinit();

            var gen = ddl_generator.DDLGenerator.init(allocator);

            // Create table
            var table = schema_helpers.makeSingleRuntimeTable(allocator, tname, &[_]schema_helpers.TestFieldDef{
                .{ .name = "col_a", .field_type = .text },
            });
            defer table.deinit(allocator);
            const ddl = try gen.generateDDL(table);
            defer allocator.free(ddl);
            try execMultiSql(&db, allocator, ddl);

            // Insert a row to verify DB is unchanged after refused migration
            const insert_sql = try std.fmt.allocPrint(
                allocator,
                "INSERT INTO {s} (id, namespace_id, owner_id, col_a, created_at, updated_at) VALUES (zeroblob(16), 1, zeroblob(16), 'val1', 0, 0)",
                .{tname},
            );
            defer allocator.free(insert_sql);
            try execSql(&db, allocator, insert_sql);

            // Build destructive plan
            var target_table = schema_helpers.makeSingleRuntimeTable(allocator, tname, &[_]schema_helpers.TestFieldDef{
                .{ .name = "col_a", .field_type = .integer },
            });
            defer target_table.deinit(allocator);
            const target_version = "1.0.0";

            const changes = try allocator.alloc(migration_detector.Change, 1);
            defer allocator.free(changes);
            changes[0] = .{
                .kind = kind,
                .table = &target_table,
                .field = schema_helpers.makeField("col_a", .integer),
            };

            const plan = migration_detector.MigrationPlan{
                .changes = changes,
                .is_destructive = true,
            };

            var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{
                .auto_migrate = .additive_only,
                .allow_destructive = false,
            });

            const result = executor.execute(plan, target_version);
            try std.testing.expectError(error.DestructiveMigrationNotAllowed, result);

            // Verify DB is unchanged: original row still exists
            const check_sql = try std.fmt.allocPrint(
                allocator,
                "SELECT id FROM {s} WHERE id = zeroblob(16)",
                .{tname},
            );
            defer allocator.free(check_sql);

            var stmt = try db.prepareDynamic(check_sql);
            defer stmt.deinit();

            const IdRow = struct { id: []const u8 };
            var check_iter = try stmt.iteratorAlloc(IdRow, allocator, .{});
            const row = try check_iter.nextAlloc(allocator, .{});
            try std.testing.expect(row != null);
            defer allocator.free(row.?.id);
            try std.testing.expectEqualSlices(u8, &zero_doc_id, row.?.id);

            // Verify DB schema is unchanged: col_a must still be TEXT
            const col_type = try columnType(&db, allocator, tname, "col_a");
            defer if (col_type) |ct| allocator.free(ct);
            try std.testing.expect(col_type != null);
            try std.testing.expectEqualStrings("TEXT", col_type.?);
        }
    }
}

// Feature: schema-aware-storage, Property 12: Schema version is persisted after migration
// For any successful migration, querying schema_meta immediately after
// Migration_Executor.execute returns SHALL yield a row whose version column equals
// the version string from the target Schema.
test "migration_executor: schema version persisted after migration" {
    const allocator = std.testing.allocator;

    const table_names = [_][]const u8{ "things", "stuff", "items", "records", "entries" };
    const versions = [_][]const u8{ "1.0.0", "1.1.0", "1.2.3", "2.0.0", "0.1.0" };

    for (table_names) |tname| {
        for (versions) |version| {
            var db = try openMemDb();
            defer db.deinit();

            var gen = ddl_generator.DDLGenerator.init(allocator);

            // Build a create_table plan
            var target_table = schema_helpers.makeSingleRuntimeTable(allocator, tname, &[_]schema_helpers.TestFieldDef{
                .{ .name = "name", .field_type = .text },
            });
            defer target_table.deinit(allocator);
            const target_version = version;

            const changes = try allocator.alloc(migration_detector.Change, 1);
            defer allocator.free(changes);
            changes[0] = .{
                .kind = .create_table,
                .table = &target_table,
                .field = null,
            };

            const plan = migration_detector.MigrationPlan{
                .changes = changes,
                .is_destructive = false,
            };

            var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{
                .auto_migrate = .full,
                .allow_destructive = false,
            });

            try executor.execute(plan, target_version);

            // Verify schema_meta has the correct version
            var stmt = try db.prepare("SELECT version FROM schema_meta LIMIT 1");
            defer stmt.deinit();

            const VersionRow = struct { version: []const u8 };
            var ver_iter = try stmt.iteratorAlloc(VersionRow, allocator, .{});
            const ver_row = try ver_iter.nextAlloc(allocator, .{});
            try std.testing.expect(ver_row != null);
            defer allocator.free(ver_row.?.version);
            try std.testing.expectEqualStrings(version, ver_row.?.version);
        }
    }
}

// Feature: schema-aware-storage, Property 20: Major version bump is refused
// For any database whose persisted major version component is less than the major version
// component in the target Schema, Migration_Executor.execute SHALL return an error and
// SHALL NOT apply any changes.
test "migration_executor: major version bump is refused" {
    const allocator = std.testing.allocator;

    const table_names = [_][]const u8{ "docs", "notes", "files", "blobs", "chunks" };

    for (table_names) |tname| {
        for (1..4) |persisted_major| {
            var db = try openMemDb();
            defer db.deinit();

            var gen = ddl_generator.DDLGenerator.init(allocator);

            // Create table and insert persisted version with lower major
            var table = schema_helpers.makeSingleRuntimeTable(allocator, tname, &[_]schema_helpers.TestFieldDef{
                .{ .name = "data", .field_type = .text },
            });
            defer table.deinit(allocator);
            const ddl = try gen.generateDDL(table);
            defer allocator.free(ddl);
            try execMultiSql(&db, allocator, ddl);

            // Target major is always one greater than the persisted major.
            const target_major = persisted_major + 1;

            const persisted_ver = try std.fmt.allocPrint(allocator, "{d}.0.0", .{persisted_major});
            defer allocator.free(persisted_ver);
            const target_ver = try std.fmt.allocPrint(allocator, "{d}.0.0", .{target_major});
            defer allocator.free(target_ver);

            try insertSchemaMetaVersion(&db, allocator, persisted_ver);

            // Build a simple add_column plan
            var target_table = schema_helpers.makeSingleRuntimeTable(allocator, tname, &[_]schema_helpers.TestFieldDef{
                .{ .name = "data", .field_type = .text },
                .{ .name = "extra", .field_type = .text },
            });
            defer target_table.deinit(allocator);
            const target_version = target_ver;

            const changes = try allocator.alloc(migration_detector.Change, 1);
            defer allocator.free(changes);
            changes[0] = .{
                .kind = .add_column,
                .table = &target_table,
                .field = schema_helpers.makeField("extra", .text),
            };

            const plan = migration_detector.MigrationPlan{
                .changes = changes,
                .is_destructive = false,
            };

            var executor = MigrationExecutor.init(std.testing.io, allocator, &db, &gen, .{
                .auto_migrate = .full,
                .allow_destructive = false,
            });

            const result = executor.execute(plan, target_version);
            try std.testing.expectError(error.MajorVersionBumpNotAllowed, result);

            // Verify no changes were applied: column 'extra' should not exist
            const extra_type = try columnType(&db, allocator, tname, "extra");
            defer if (extra_type) |et| allocator.free(et);
            try std.testing.expect(extra_type == null);
        }
    }
}
