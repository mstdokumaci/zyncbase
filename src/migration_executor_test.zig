const std = @import("std");
const schema = @import("schema.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const ddl_generator = @import("ddl_generator.zig");
const migration_detector = @import("migration_detector.zig");
const migration_executor = @import("migration_executor.zig");
const MigrationExecutor = migration_executor.MigrationExecutor;
const sqlite = @import("sqlite");

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

// Unit test 5.5: destructive migration with allow_destructive = true preserves common-column data
test "migration_executor: 5.5 - destructive migration preserves common-column data" {
    const allocator = std.testing.allocator;

    var db = try openMemDb();
    defer db.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);

    // Create table with [title TEXT, status TEXT]
    var initial_fields = [_]schema.Field{
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
    var target_fields = [_]schema.Field{
        schema_helpers.makeField("title", .text),
        schema_helpers.makeField("status", .integer),
    };
    var target_tables = [_]schema.Table{schema_helpers.makeTable("tasks", &target_fields)};
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

    var executor = MigrationExecutor.init(allocator, &db, &gen, .{
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
    var target_fields = [_]schema.Field{
        schema_helpers.makeField("username", .text),
        schema_helpers.makeField("email", .text),
    };
    var target_tables = [_]schema.Table{schema_helpers.makeTable("users", &target_fields)};
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

    var executor = MigrationExecutor.init(allocator, &db, &gen, .{
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
    var fields = [_]schema.Field{schema_helpers.makeField("data", .text)};
    const table = schema_helpers.makeTable("docs", &fields);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    try execMultiSql(&db, allocator, ddl);

    var target_fields = [_]schema.Field{
        schema_helpers.makeField("data", .text),
        schema_helpers.makeField("extra", .text),
    };
    var target_tables = [_]schema.Table{schema_helpers.makeTable("docs", &target_fields)};
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

    var executor = MigrationExecutor.init(allocator, &db, &gen, .{
        .auto_migrate = .full,
        .allow_destructive = false,
    });

    const result = executor.execute(plan, target_version);
    try std.testing.expectError(error.InvalidVersion, result);
}
