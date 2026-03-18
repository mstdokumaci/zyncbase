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

// Unit test 5.5: destructive migration with allow_destructive = true preserves common-column data
test "migration_executor: 5.5 - destructive migration preserves common-column data" {
    const allocator = std.testing.allocator;

    var db = try openMemDb();
    defer db.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);

    // Create table with [title TEXT, status TEXT]
    var initial_fields = [_]schema_parser.Field{
        makeField("title", .text),
        makeField("status", .text),
    };
    const initial_table = schema_parser.Table{ .name = "tasks", .fields = &initial_fields };
    const initial_ddl = try gen.generateDDL(initial_table);
    defer allocator.free(initial_ddl);
    try execMultiSql(&db, allocator, initial_ddl);

    // Insert a row
    try execSql(&db, allocator, "INSERT INTO tasks (id, namespace_id, title, status, created_at, updated_at) VALUES ('t1', 'ns1', 'My Task', 'open', 0, 0)");

    // Build change_type migration: status TEXT -> INTEGER
    const changes = try allocator.alloc(migration_detector.Change, 1);
    defer allocator.free(changes);
    changes[0] = .{
        .kind = .change_type,
        .table_name = "tasks",
        .field = schema_parser.Field{
            .name = "status",
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

    // Target schema: status is now INTEGER
    var target_fields = [_]schema_parser.Field{
        makeField("title", .text),
        makeField("status", .integer),
    };
    var target_tables = [_]schema_parser.Table{.{ .name = "tasks", .fields = &target_fields }};
    const target_schema = schema_parser.Schema{
        .version = "1.0.0",
        .tables = &target_tables,
    };

    var executor = MigrationExecutor.init(allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = true,
    });

    try executor.execute(plan, target_schema);

    // Verify the row still exists with title intact
    var stmt = try db.prepare("SELECT id, title FROM tasks WHERE id = 't1'");
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
    try std.testing.expectEqualStrings("t1", row.?.id);
    try std.testing.expectEqualStrings("My Task", row.?.title);
}

// Unit test 5.6: mid-migration failure leaves database unchanged
test "migration_executor: 5.6 - mid-migration failure leaves database unchanged" {
    const allocator = std.testing.allocator;

    var db = try openMemDb();
    defer db.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);

    // Create a real table first
    var fields = [_]schema_parser.Field{makeField("name", .text)};
    const table = schema_parser.Table{ .name = "real_table", .fields = &fields };
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    try execMultiSql(&db, allocator, ddl);

    // Insert a row
    try execSql(&db, allocator, "INSERT INTO real_table (id, namespace_id, name, created_at, updated_at) VALUES ('r1', 'ns1', 'test', 0, 0)");

    // Build a plan with a bad table name that will fail DDL execution
    const changes = try allocator.alloc(migration_detector.Change, 1);
    defer allocator.free(changes);
    changes[0] = .{
        .kind = .create_table,
        .table_name = "nonexistent_in_schema",
        .field = null,
    };

    const plan = migration_detector.MigrationPlan{
        .changes = changes,
        .is_destructive = false,
    };

    // Target schema does NOT contain "nonexistent_in_schema" - this will cause TableNotFoundInSchema
    var target_fields = [_]schema_parser.Field{makeField("name", .text)};
    var target_tables = [_]schema_parser.Table{.{ .name = "real_table", .fields = &target_fields }};
    const target_schema = schema_parser.Schema{
        .version = "1.0.0",
        .tables = &target_tables,
    };

    var executor = MigrationExecutor.init(allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = false,
    });

    const result = executor.execute(plan, target_schema);
    try std.testing.expectError(error.TableNotFoundInSchema, result);

    // Verify DB is unchanged: original row still exists
    var stmt = try db.prepare("SELECT id FROM real_table WHERE id = 'r1'");
    defer stmt.deinit();

    const IdRow = struct { id: []const u8 };
    var iter = try stmt.iteratorAlloc(IdRow, allocator, .{});
    const row = try iter.nextAlloc(allocator, .{});
    try std.testing.expect(row != null);
    defer allocator.free(row.?.id);
    try std.testing.expectEqualStrings("r1", row.?.id);
}

// Unit test 5.7: empty schema_meta triggers full schema creation
test "migration_executor: 5.7 - empty schema_meta triggers full schema creation" {
    const allocator = std.testing.allocator;

    var db = try openMemDb();
    defer db.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);

    // No schema_meta, no tables - start fresh
    // Build a create_table plan
    const changes = try allocator.alloc(migration_detector.Change, 1);
    defer allocator.free(changes);
    changes[0] = .{
        .kind = .create_table,
        .table_name = "users",
        .field = null,
    };

    const plan = migration_detector.MigrationPlan{
        .changes = changes,
        .is_destructive = false,
    };

    var target_fields = [_]schema_parser.Field{
        makeField("username", .text),
        makeField("email", .text),
    };
    var target_tables = [_]schema_parser.Table{.{ .name = "users", .fields = &target_fields }};
    const target_schema = schema_parser.Schema{
        .version = "1.0.0",
        .tables = &target_tables,
    };

    var executor = MigrationExecutor.init(allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = false,
    });

    try executor.execute(plan, target_schema);

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
    var fields = [_]schema_parser.Field{makeField("data", .text)};
    const table = schema_parser.Table{ .name = "docs", .fields = &fields };
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    try execMultiSql(&db, allocator, ddl);

    const changes = try allocator.alloc(migration_detector.Change, 1);
    defer allocator.free(changes);
    changes[0] = .{
        .kind = .add_column,
        .table_name = "docs",
        .field = schema_parser.Field{
            .name = "extra",
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
    var target_tables = [_]schema_parser.Table{.{ .name = "docs", .fields = &target_fields }};
    const target_schema = schema_parser.Schema{
        .version = "1.0.0",
        .tables = &target_tables,
    };

    var executor = MigrationExecutor.init(allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = false,
    });

    const result = executor.execute(plan, target_schema);
    try std.testing.expectError(error.InvalidVersion, result);
}
