const std = @import("std");
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const migration_detector = @import("migration_detector.zig");
const migration_executor = @import("migration_executor.zig");
const MigrationExecutor = migration_executor.MigrationExecutor;
const MigrationConfig = migration_executor.MigrationConfig;
const sqlite = @import("sqlite");

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

fn insertSchemaMetaVersion(db: *sqlite.Db, allocator: std.mem.Allocator, version: []const u8) !void {
    try db.exec("CREATE TABLE IF NOT EXISTS schema_meta (version TEXT NOT NULL, applied_at INTEGER NOT NULL)", .{}, .{});
    try db.exec("DELETE FROM schema_meta", .{}, .{});
    const sql = try std.fmt.allocPrint(allocator, "INSERT INTO schema_meta (version, applied_at) VALUES ('{s}', 0)", .{version});
    defer allocator.free(sql);
    try execSql(db, allocator, sql);
}

// Feature: schema-aware-storage, Property 10: Additive migration preserves existing data
// For any database state and additive MigrationPlan (containing only create_table and add_column
// changes), after Migration_Executor.execute completes, every row that existed before the migration
// SHALL still exist with all its original column values intact.
test "migration_executor: property 10 - additive migration preserves existing data" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const table_names = [_][]const u8{ "users", "posts", "items", "orders", "tags" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);
        const tname = table_names[rand.intRangeAtMost(usize, 0, table_names.len - 1)];

        // Create table with initial columns
        var initial_fields = [_]schema_parser.Field{makeField("title", .text)};
        const initial_table = schema_parser.Table{ .name = tname, .fields = &initial_fields };
        const initial_ddl = try gen.generateDDL(initial_table);
        defer allocator.free(initial_ddl);
        try execMultiSql(&db, allocator, initial_ddl);

        // Insert a row
        const row_id = "row-001";
        const row_title = "hello world";
        const insert_sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO {s} (id, namespace_id, title, created_at, updated_at) VALUES ('{s}', 'ns1', '{s}', 0, 0)",
            .{ tname, row_id, row_title },
        );
        defer allocator.free(insert_sql);
        try execSql(&db, allocator, insert_sql);

        // Build additive migration plan: add a new column
        const new_field = makeField("score", .integer);
        const owned_table_name = try allocator.dupe(u8, tname);
        defer allocator.free(owned_table_name);
        const owned_field_name = try allocator.dupe(u8, new_field.name);
        defer allocator.free(owned_field_name);

        const changes = try allocator.alloc(migration_detector.Change, 1);
        defer allocator.free(changes);
        changes[0] = .{
            .kind = .add_column,
            .table_name = owned_table_name,
            .field = schema_parser.Field{
                .name = owned_field_name,
                .sql_type = .integer,
                .required = false,
                .indexed = false,
                .references = null,
                .on_delete = null,
            },
        };

        const plan = migration_detector.MigrationPlan{
            .changes = changes,
            .is_destructive = false,
        };

        // Target schema has both columns
        var target_fields = [_]schema_parser.Field{
            makeField("title", .text),
            makeField("score", .integer),
        };
        var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
        const target_schema = schema_parser.Schema{
            .version = "1.0.0",
            .tables = &target_tables,
        };

        var executor = MigrationExecutor.init(allocator, &db, &gen, .{
            .auto_migrate = .full,
            .allow_destructive = false,
        });

        try executor.execute(plan, target_schema);

        // Verify the original row still exists with original values
        const check_sql = try std.fmt.allocPrint(
            allocator,
            "SELECT id, title FROM {s} WHERE id = '{s}'",
            .{ tname, row_id },
        );
        defer allocator.free(check_sql);
        const check_sql_z = try allocator.dupeZ(u8, check_sql);
        defer allocator.free(check_sql_z);

        var stmt = try db.prepareDynamic(check_sql_z);
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
        try std.testing.expectEqualStrings(row_id, row.?.id);
        try std.testing.expectEqualStrings(row_title, row.?.title);
    }
}

// Feature: schema-aware-storage, Property 11: Destructive migration is refused when not allowed
// For any MigrationPlan that contains at least one change_type or remove_column change,
// when MigrationConfig.allow_destructive is false, Migration_Executor.execute SHALL return
// an error and SHALL NOT modify the database.
test "migration_executor: property 11 - destructive migration refused when not allowed" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(77);
    const rand = prng.random();

    const table_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
    const destructive_kinds = [_]migration_detector.ChangeKind{ .change_type, .remove_column };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);
        const tname = table_names[rand.intRangeAtMost(usize, 0, table_names.len - 1)];

        // Create table
        var fields = [_]schema_parser.Field{makeField("col_a", .text)};
        const table = schema_parser.Table{ .name = tname, .fields = &fields };
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        try execMultiSql(&db, allocator, ddl);

        // Insert a row to verify DB is unchanged after refused migration
        const insert_sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO {s} (id, namespace_id, col_a, created_at, updated_at) VALUES ('r1', 'ns1', 'val1', 0, 0)",
            .{tname},
        );
        defer allocator.free(insert_sql);
        try execSql(&db, allocator, insert_sql);

        // Build destructive plan
        const kind = destructive_kinds[rand.intRangeAtMost(usize, 0, destructive_kinds.len - 1)];
        const owned_tname = try allocator.dupe(u8, tname);
        defer allocator.free(owned_tname);
        const owned_fname = try allocator.dupe(u8, "col_a");
        defer allocator.free(owned_fname);

        const changes = try allocator.alloc(migration_detector.Change, 1);
        defer allocator.free(changes);
        changes[0] = .{
            .kind = kind,
            .table_name = owned_tname,
            .field = schema_parser.Field{
                .name = owned_fname,
                .sql_type = .integer,
                .required = false,
                .indexed = false,
                .references = null,
                .on_delete = null,
            },
        };

        const plan = migration_detector.MigrationPlan{
            .changes = changes,
            .is_destructive = true,
        };

        var target_fields = [_]schema_parser.Field{makeField("col_a", .integer)};
        var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
        const target_schema = schema_parser.Schema{
            .version = "1.0.0",
            .tables = &target_tables,
        };

        var executor = MigrationExecutor.init(allocator, &db, &gen, .{
            .auto_migrate = .additive_only,
            .allow_destructive = false,
        });

        const result = executor.execute(plan, target_schema);
        try std.testing.expectError(error.DestructiveMigrationNotAllowed, result);

        // Verify DB is unchanged: original row still exists
        const check_sql = try std.fmt.allocPrint(
            allocator,
            "SELECT id FROM {s} WHERE id = 'r1'",
            .{tname},
        );
        defer allocator.free(check_sql);
        const check_sql_z = try allocator.dupeZ(u8, check_sql);
        defer allocator.free(check_sql_z);

        var stmt = try db.prepareDynamic(check_sql_z);
        defer stmt.deinit();

        const IdRow = struct { id: []const u8 };
        var check_iter = try stmt.iteratorAlloc(IdRow, allocator, .{});
        const row = try check_iter.nextAlloc(allocator, .{});
        try std.testing.expect(row != null);
        defer allocator.free(row.?.id);
        try std.testing.expectEqualStrings("r1", row.?.id);
    }
}

// Feature: schema-aware-storage, Property 12: Schema version is persisted after migration
// For any successful migration, querying schema_meta immediately after
// Migration_Executor.execute returns SHALL yield a row whose version column equals
// the version string from the target Schema.
test "migration_executor: property 12 - schema version persisted after migration" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(55);
    const rand = prng.random();

    const table_names = [_][]const u8{ "things", "stuff", "items", "records", "entries" };
    const versions = [_][]const u8{ "1.0.0", "1.1.0", "1.2.3", "2.0.0", "0.1.0" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);
        const tname = table_names[rand.intRangeAtMost(usize, 0, table_names.len - 1)];
        const version = versions[rand.intRangeAtMost(usize, 0, versions.len - 1)];

        // Build a create_table plan
        const owned_tname = try allocator.dupe(u8, tname);
        defer allocator.free(owned_tname);

        const changes = try allocator.alloc(migration_detector.Change, 1);
        defer allocator.free(changes);
        changes[0] = .{
            .kind = .create_table,
            .table_name = owned_tname,
            .field = null,
        };

        const plan = migration_detector.MigrationPlan{
            .changes = changes,
            .is_destructive = false,
        };

        var target_fields = [_]schema_parser.Field{makeField("name", .text)};
        var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
        const target_schema = schema_parser.Schema{
            .version = version,
            .tables = &target_tables,
        };

        var executor = MigrationExecutor.init(allocator, &db, &gen, .{
            .auto_migrate = .full,
            .allow_destructive = false,
        });

        try executor.execute(plan, target_schema);

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

// Feature: schema-aware-storage, Property 20: Major version bump is refused
// For any database whose persisted major version component is less than the major version
// component in the target Schema, Migration_Executor.execute SHALL return an error and
// SHALL NOT apply any changes.
test "migration_executor: property 20 - major version bump is refused" {
    const allocator = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(33);
    const rand = prng.random();

    const table_names = [_][]const u8{ "docs", "notes", "files", "blobs", "chunks" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        var db = try openMemDb();
        defer db.deinit();

        var gen = ddl_generator.DDLGenerator.init(allocator);
        const tname = table_names[rand.intRangeAtMost(usize, 0, table_names.len - 1)];

        // Create table and insert persisted version with lower major
        var fields = [_]schema_parser.Field{makeField("data", .text)};
        const table = schema_parser.Table{ .name = tname, .fields = &fields };
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        try execMultiSql(&db, allocator, ddl);

        // Persisted version: major = 1
        const persisted_major = rand.intRangeAtMost(u32, 1, 5);
        const target_major = persisted_major + 1 + rand.intRangeAtMost(u32, 0, 3);

        const persisted_ver = try std.fmt.allocPrint(allocator, "{d}.0.0", .{persisted_major});
        defer allocator.free(persisted_ver);
        const target_ver = try std.fmt.allocPrint(allocator, "{d}.0.0", .{target_major});
        defer allocator.free(target_ver);

        try insertSchemaMetaVersion(&db, allocator, persisted_ver);

        // Build a simple add_column plan
        const owned_tname = try allocator.dupe(u8, tname);
        defer allocator.free(owned_tname);
        const owned_fname = try allocator.dupe(u8, "extra");
        defer allocator.free(owned_fname);

        const changes = try allocator.alloc(migration_detector.Change, 1);
        defer allocator.free(changes);
        changes[0] = .{
            .kind = .add_column,
            .table_name = owned_tname,
            .field = schema_parser.Field{
                .name = owned_fname,
                .sql_type = .text,
                .required = false,
                .indexed = false,
                .references = null,
                .on_delete = null,
            },
        };

        const plan = migration_detector.MigrationPlan{
            .changes = changes,
            .is_destructive = false,
        };

        var target_fields = [_]schema_parser.Field{
            makeField("data", .text),
            makeField("extra", .text),
        };
        var target_tables = [_]schema_parser.Table{.{ .name = tname, .fields = &target_fields }};
        const target_schema = schema_parser.Schema{
            .version = target_ver,
            .tables = &target_tables,
        };

        var executor = MigrationExecutor.init(allocator, &db, &gen, .{
            .auto_migrate = .full,
            .allow_destructive = false,
        });

        const result = executor.execute(plan, target_schema);
        try std.testing.expectError(error.MajorVersionBumpNotAllowed, result);

        // Verify no changes were applied: column 'extra' should not exist
        // Check via PRAGMA table_info - 'extra' column should not be present
        const pragma_sql = try std.fmt.allocPrint(
            allocator,
            "PRAGMA table_info({s})",
            .{tname},
        );
        defer allocator.free(pragma_sql);

        var pragma_stmt = try db.prepareDynamic(pragma_sql);
        defer pragma_stmt.deinit();

        const PragmaRow = struct {
            cid: i64,
            name: []const u8,
            type: []const u8,
            notnull: i64,
            dflt_value: ?[]const u8,
            pk: i64,
        };

        var found_extra = false;
        var pragma_iter = try pragma_stmt.iteratorAlloc(PragmaRow, allocator, .{});
        while (try pragma_iter.nextAlloc(allocator, .{})) |row| {
            defer {
                allocator.free(row.name);
                allocator.free(row.type);
                if (row.dflt_value) |dv| allocator.free(dv);
            }
            if (std.mem.eql(u8, row.name, "extra")) {
                found_extra = true;
            }
        }
        try std.testing.expect(!found_extra);
    }
}
