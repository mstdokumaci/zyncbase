//! Developer migrations through the full startup procedure.

const std = @import("std");

const sqlite = @import("sqlite");

const backup = @import("../backup.zig");
const canonical = @import("../schema/canonical.zig");
const schema_parse = @import("../schema/parse.zig");
const typed_codec = @import("../typed/codec.zig");
const catalog = @import("catalog.zig");
const source = @import("source.zig");
const startup = @import("startup.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const allocator = std.testing.allocator;

const Harness = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    migrations_dir: []u8,
    /// Database file path (used only by on-disk harnesses).
    db_path: [:0]u8,
    db: sqlite.Db,
    diag: Diagnostics,

    fn init() !Harness {
        return initWithDb(false);
    }

    fn initWithDb(on_disk: bool) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..] });
        errdefer allocator.free(root);
        const migrations_dir = try std.fs.path.join(allocator, &.{ root, "migrations" });
        errdefer allocator.free(migrations_dir);
        const db_path = try std.fs.path.joinZ(allocator, &.{ root, backup.db_file_name });
        errdefer allocator.free(db_path);

        var db = if (on_disk)
            try sqlite.Db.init(.{ .mode = .{ .File = db_path }, .open_flags = .{ .write = true, .create = true } })
        else
            try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
        errdefer db.deinit();
        _ = try db.pragma(void, .{}, "foreign_keys", "on");
        // Like StorageEngine.init: the namespace table exists before migrations.
        try db.exec("CREATE TABLE IF NOT EXISTS _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE) STRICT", .{}, .{});
        return .{ .tmp = tmp, .root = root, .migrations_dir = migrations_dir, .db_path = db_path, .db = db, .diag = Diagnostics.init(allocator) };
    }

    fn deinit(self: *Harness) void {
        self.diag.deinit();
        self.db.deinit();
        allocator.free(self.db_path);
        allocator.free(self.migrations_dir);
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn writeMigration(self: *Harness, id: []const u8, before: []const u8, after: []const u8, sql: []const u8) !void {
        const files = [_]struct { name: []const u8, data: []const u8 }{
            .{ .name = source.before_file, .data = before },
            .{ .name = source.after_file, .data = after },
            .{ .name = source.sql_file, .data = sql },
        };
        for (files) |file| {
            const path = try std.fs.path.join(allocator, &.{ self.migrations_dir, id, file.name });
            defer allocator.free(path);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path) orelse return error.TestExpectedValue);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = file.data });
        }
    }

    fn removeMigration(self: *Harness, id: []const u8) !void {
        const path = try std.fs.path.join(allocator, &.{ self.migrations_dir, id });
        defer allocator.free(path);
        try std.Io.Dir.cwd().deleteTree(std.testing.io, path);
    }

    const RunOptions = struct { snapshot: bool = false, dry_run: bool = false };

    fn migrate(self: *Harness, json: []const u8, options: RunOptions) !startup.Report {
        self.diag.deinit();
        self.diag = Diagnostics.init(allocator);
        var migrations = try source.load(std.testing.io, allocator, self.migrations_dir, &self.diag);
        defer migrations.deinit();
        var schema = try schema_parse.initFromJson(allocator, json);
        defer schema.deinit();
        const identity = try canonical.Identity.init(allocator, json);
        defer identity.deinit(allocator);
        return startup.run(std.testing.io, allocator, &self.db, .{
            .schema = &schema,
            .json = identity.json,
            .hash = identity.hash,
        }, .{
            .migrations = migrations.items,
            .snapshot_of = if (options.snapshot) self.db_path else null,
            .dry_run = options.dry_run,
        }, &self.diag);
    }

    /// Runs a migration expected to succeed; prints diagnostics otherwise.
    fn migrateOk(self: *Harness, json: []const u8) !startup.Report {
        return self.migrate(json, .{}) catch |err| {
            for (self.diag.items()) |line| std.debug.print("{s}\n", .{line});
            return err;
        };
    }

    fn exec(self: *Harness, sql: []const u8) !void {
        try self.db.execDynamic(sql, .{}, .{});
    }

    fn int(self: *Harness, sql: []const u8) !i64 {
        return (try self.db.oneDynamic(i64, sql, .{}, .{})) orelse error.TestExpectedValue;
    }

    fn text(self: *Harness, sql: []const u8) ![]const u8 {
        return (try self.db.oneDynamicAlloc([]const u8, allocator, sql, .{}, .{})) orelse error.TestExpectedValue;
    }

    fn expectText(self: *Harness, expected: []const u8, sql: []const u8) !void {
        const actual = try self.text(sql);
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }

    fn appliedVersion(self: *Harness) ![]const u8 {
        return self.text("SELECT version FROM _zync_schema");
    }

    fn expectApplied(self: *Harness, version: []const u8) !void {
        try self.expectText(version, "SELECT version FROM _zync_schema");
    }

    fn diagContains(self: *const Harness, needle: []const u8) bool {
        for (self.diag.items()) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) return true;
        }
        return false;
    }

    fn expectDiag(self: *const Harness, needle: []const u8) !void {
        if (self.diagContains(needle)) return;
        for (self.diag.items()) |line| std.debug.print("{s}\n", .{line});
        std.debug.print("expected a diagnostic containing: {s}\n", .{needle});
        return error.TestUnexpectedResult;
    }

    fn expectLayout(self: *Harness, json: []const u8) !void {
        var schema = try schema_parse.initFromJson(allocator, json);
        defer schema.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var diag = Diagnostics.init(allocator);
        defer diag.deinit();
        for (schema.tables) |*table| {
            if ((try catalog.checkTable(arena.allocator(), &self.db, table, &diag)).any()) {
                for (diag.items()) |line| std.debug.print("{s}\n", .{line});
                return error.TestUnexpectedResult;
            }
        }
    }

    fn expectPragmasRestored(self: *Harness) !void {
        try std.testing.expectEqual(@as(?i64, 1), try self.db.one(i64, "PRAGMA foreign_keys", .{}, .{}));
        try std.testing.expectEqual(@as(?i64, 0), try self.db.one(i64, "PRAGMA legacy_alter_table", .{}, .{}));
    }

    /// Inserts rows with valid system columns. `columns` and `values` are SQL.
    fn insert(self: *Harness, table: []const u8, columns: []const u8, values: []const u8) !void {
        const sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO \"{s}\" (\"id\", \"namespace_id\", \"owner_id\", \"created_at\", \"updated_at\", {s}) " ++
                "SELECT randomblob(16), 1, zeroblob(16), next, next, {s} FROM (SELECT coalesce(max(\"created_at\"), 0) + 1 AS next FROM \"{s}\")",
            .{ table, columns, values, table },
        );
        defer allocator.free(sql);
        try self.exec(sql);
    }
};

const v1 =
    \\{"version":"1.0.0","store":{"tasks":{"fields":{
    \\  "title":{"type":"string"},
    \\  "priority":{"type":"integer"},
    \\  "assignee":{"type":"string"}
    \\},"required":["title"]}}}
;

const v2 =
    \\{"version":"2.0.0","store":{"tasks":{"fields":{
    \\  "title":{"type":"string"},
    \\  "priority":{"type":"string","enum":["low","medium","high"]}
    \\},"required":["title"]}}}
;

const v1_to_v2_sql =
    \\-- priority becomes text, assignee is dropped
    \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "priority", "created_at", "updated_at")
    \\SELECT "id", "namespace_id", "owner_id", "title",
    \\       CASE "priority" WHEN 1 THEN 'low' WHEN 2 THEN 'medium' ELSE 'high' END,
    \\       "created_at", "updated_at"
    \\FROM "_zync_prev_tasks";
;

const m1 = "20261117T100000Z_priority_to_string";

fn seedV1(h: *Harness) !void {
    _ = try h.migrateOk(v1);
    try h.insert("tasks", "\"title\", \"priority\", \"assignee\"", "'a', 1, 'ann'");
    try h.insert("tasks", "\"title\", \"priority\", \"assignee\"", "'b', 2, 'bob'");
    try h.insert("tasks", "\"title\", \"priority\", \"assignee\"", "'c', 9, NULL");
}

test "migrate: a type change runs the developer conversion and records the ledger" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2, v1_to_v2_sql);

    var report = try h.migrateOk(v2);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.migrations_applied);
    try h.expectApplied("2.0.0");
    try h.expectLayout(v2);
    try h.expectPragmasRestored();
    try h.expectText("low,medium,high", "SELECT group_concat(priority, ',') FROM (SELECT priority FROM tasks ORDER BY title)");
    try h.expectText("applied", "SELECT mode FROM _zync_migrations WHERE id = '20261117T100000Z_priority_to_string'");

    // Restarting runs nothing.
    var again = try h.migrateOk(v2);
    defer again.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), again.steps);
}

test "migrate: migration-required changes need a major version bump" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    const minor =
        \\{"version":"1.1.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]}
        \\},"required":["title"]}}}
    ;
    try h.writeMigration(m1, v1, minor, v1_to_v2_sql);
    try std.testing.expectError(error.MajorVersionBumpRequired, h.migrate(minor, .{}));
    try h.expectDiag("2.0.0");
    try h.expectApplied("1.0.0");
}

test "migrate: rows lost by the developer SQL are caught and nothing changes" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2,
        \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "priority", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "title", 'low', "created_at", "updated_at"
        \\FROM "_zync_prev_tasks" WHERE "assignee" IS NOT NULL;
    );
    try std.testing.expectError(error.RowsNotCarriedOver, h.migrate(v2, .{}));
    try h.expectDiag("left 1 row(s) of \"tasks\" behind");
    try h.expectDiag("DELETE them from \"_zync_prev_tasks\"");
    try h.expectApplied("1.0.0");
    try h.expectLayout(v1);
    try std.testing.expectEqual(@as(i64, 3), try h.int("SELECT count(*) FROM tasks"));
    try std.testing.expectEqual(@as(i64, 0), try h.int("SELECT count(*) FROM _zync_migrations"));
    try h.expectPragmasRestored();
}

test "migrate: deleting rows from the prev table drops them on purpose" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2,
        \\DELETE FROM "_zync_prev_tasks" WHERE "assignee" IS NULL;
    ++ "\n" ++ v1_to_v2_sql);
    _ = try h.migrateOk(v2);
    try std.testing.expectEqual(@as(i64, 2), try h.int("SELECT count(*) FROM tasks"));
}

test "migrate: a removed table must be emptied explicitly" {
    const with_notes =
        \\{"version":"1.0.0","store":{"notes":{"fields":{"body":{"type":"string"}}},"archive":{"fields":{"body":{"type":"string"}}}}}
    ;
    const without_notes =
        \\{"version":"2.0.0","store":{"archive":{"fields":{"body":{"type":"string"}}}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(with_notes);
    try h.insert("notes", "\"body\"", "'keep me'");
    try h.insert("notes", "\"body\"", "'old'");

    try h.writeMigration(m1, with_notes, without_notes, "-- forgot to decide\n");
    try std.testing.expectError(error.RowsNotCarriedOver, h.migrate(without_notes, .{}));
    try h.expectDiag("removed table \"notes\" undecided");

    try h.removeMigration(m1);
    try h.writeMigration(m1, with_notes, without_notes,
        \\INSERT INTO "archive" ("id", "namespace_id", "owner_id", "body", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "body", zync_now(), zync_now() FROM "_zync_prev_notes" WHERE "body" = 'keep me';
        \\DELETE FROM "_zync_prev_notes";
    );
    _ = try h.migrateOk(without_notes);
    try h.expectLayout(without_notes);
    try std.testing.expect(!try catalog.tableExists(&h.db, "notes"));
    try h.expectText("keep me", "SELECT body FROM archive");
}

test "migrate: embedded NUL bytes are rejected before anything runs" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2, "SELECT 1;\x00SELECT 2;");

    try std.testing.expectError(error.MigrationSqlRejected, h.migrate(v2, .{}));
    try h.expectDiag("NUL");
    try h.expectApplied("1.0.0");
}

test "migrate: unresolved zync_todo markers are reported with lines before anything runs" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2,
        \\-- generated
        \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "priority", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "title",
        \\       zync_todo('tasks.priority: integer -> string, it''s your call'),
        \\       "created_at", "updated_at"
        \\FROM "_zync_prev_tasks";
        \\-- zync_todo('only a comment')
    );
    try std.testing.expectError(error.MigrationSqlRejected, h.migrate(v2, .{}));
    try h.expectDiag("migration.sql line 4: unresolved decision: tasks.priority: integer -> string, it's your call");
    try std.testing.expect(!h.diagContains("only a comment"));
    try h.expectApplied("1.0.0");
    try h.expectLayout(v1);
}

test "migrate: the authorizer rejects DDL, pragmas, transactions, and foreign writes" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.exec("CREATE TABLE manual (k INTEGER)");
    try h.writeMigration(m1, v1, v2,
        \\CREATE TABLE scratch (k INTEGER);
        \\PRAGMA foreign_keys = ON;
        \\BEGIN;
        \\UPDATE _zync_schema SET version = '9.9.9';
        \\INSERT INTO manual VALUES (1);
        \\DELETE FROM _zync_namespaces;
        \\ATTACH ':memory:' AS other;
        \\DROP TABLE "_zync_prev_tasks";
    ++ "\n" ++ v1_to_v2_sql);
    try std.testing.expectError(error.MigrationSqlRejected, h.migrate(v2, .{}));
    try h.expectDiag("line 1: CREATE TABLE is not allowed");
    try h.expectDiag("line 2: PRAGMA foreign_keys is not allowed");
    try h.expectDiag("line 3: transaction control is not allowed");
    try h.expectDiag("line 4: cannot update \"_zync_schema\"");
    try h.expectDiag("line 5: cannot insert into \"manual\"");
    try h.expectDiag("line 6: cannot delete from \"_zync_namespaces\"");
    try h.expectDiag("line 7: ATTACH and DETACH are not allowed");
    try h.expectDiag("line 8: DROP TABLE is not allowed");
    try std.testing.expect(!h.diagContains("sqlite_master"));
    try h.expectApplied("1.0.0");
    try h.expectLayout(v1);
    try std.testing.expectEqual(@as(i64, 0), try h.int("SELECT count(*) FROM manual"));
}

test "migrate: STRICT type errors point at the failing statement" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    const v2_int =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"integer"},
        \\  "owner":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    try h.writeMigration(m1, v1, v2_int,
        \\-- assignee is renamed to owner, priority keeps its type
        \\
        \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "priority", "owner", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "title", 'high', "assignee", "created_at", "updated_at" FROM "_zync_prev_tasks";
    );
    try std.testing.expectError(error.MigrationSqlFailed, h.migrate(v2_int, .{}));
    try h.expectDiag("migration.sql line 3: cannot store TEXT value in INTEGER column tasks.priority");
    try h.expectApplied("1.0.0");
}

test "migrate: rows written by migration SQL are validated against the schema" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2,
        \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "priority", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "title", 'urgent', "created_at", "updated_at" FROM "_zync_prev_tasks";
    );
    try std.testing.expectError(error.DataValidationFailed, h.migrate(v2, .{}));
    try h.expectDiag("tasks.priority: 3 row(s) violate the schema");
    try h.expectApplied("1.0.0");
}

test "migrate: data-only migrations backfill without schema changes" {
    const with_slug_v1 =
        \\{"version":"1.1.0","store":{"posts":{"fields":{"title":{"type":"string"},"slug":{"type":"string"}}}}}
    ;
    const base =
        \\{"version":"1.0.0","store":{"posts":{"fields":{"title":{"type":"string"}}}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(base);
    try h.insert("posts", "\"title\"", "'Hello World'");
    // Auto change (add optional field) plus a backfill in one migration.
    try h.writeMigration(m1, base, with_slug_v1,
        \\UPDATE "posts" SET "slug" = lower(replace("title", ' ', '-')) WHERE "slug" IS NULL;
    );
    _ = try h.migrateOk(with_slug_v1);
    try h.expectText("hello-world", "SELECT slug FROM posts");
    try h.expectApplied("1.1.0");
}

test "migrate: an exhausted timestamp range only fails when zync_now is called" {
    {
        var h = try Harness.init();
        defer h.deinit();
        try seedV1(&h);
        try h.exec("INSERT INTO tasks (id, namespace_id, owner_id, title, priority, assignee, created_at, updated_at) " ++
            "VALUES (randomblob(16), 1, zeroblob(16), 'max', NULL, NULL, 9223372036854775807, 9223372036854775807)");
        try h.writeMigration(m1, v1, v1, "SELECT zync_now();");
        try std.testing.expectError(error.MigrationSqlFailed, h.migrate(v1, .{}));
        try h.expectDiag("no timestamp above the stored values");
        try h.expectApplied("1.0.0");
    }
    {
        // A migration that does not use zync_now can still repair the stored value.
        var h = try Harness.init();
        defer h.deinit();
        try seedV1(&h);
        try h.exec("INSERT INTO tasks (id, namespace_id, owner_id, title, priority, assignee, created_at, updated_at) " ++
            "VALUES (randomblob(16), 1, zeroblob(16), 'max', NULL, NULL, 9223372036854775807, 9223372036854775807)");
        try h.writeMigration(m1, v1, v1, "UPDATE \"tasks\" SET \"title\" = \"title\";");
        var report = try h.migrateOk(v1);
        defer report.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), report.migrations_applied);
    }
}

test "migrate: helpers produce ids, timestamps, and canonical arrays, then disappear" {
    const tags_v1 =
        \\{"version":"1.0.0","store":{"items":{"fields":{"tag":{"type":"string"}}}}}
    ;
    const tags_v2 =
        \\{"version":"2.0.0","store":{"items":{"fields":{"tags":{"type":"array","items":"string"}}}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(tags_v1);
    try h.insert("items", "\"tag\"", "'b'");
    try h.exec("UPDATE items SET created_at = 9000000000000000, updated_at = 9000000000000000");
    try h.writeMigration(m1, tags_v1, tags_v2,
        \\INSERT INTO "items" ("id", "namespace_id", "owner_id", "tags", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", jsonb(zync_array(json_array("tag", 'a', "tag"), 'string')), "created_at", "updated_at"
        \\FROM "_zync_prev_items";
        \\INSERT INTO "items" ("id", "namespace_id", "owner_id", "tags", "created_at", "updated_at")
        \\SELECT zync_new_id(), 1, zeroblob(16), jsonb(zync_array('[]', 'string')), zync_now(), zync_now();
        \\INSERT INTO "items" ("id", "namespace_id", "owner_id", "tags", "created_at", "updated_at")
        \\SELECT zync_new_id(), 1, zeroblob(16), NULL, zync_now(), zync_now();
    );
    _ = try h.migrateOk(tags_v2);

    // Same bytes the runtime writes for {"a","b"}.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[\"b\",\"a\"]", .{});
    defer parsed.deinit();
    const value = try typed_codec.fromJson(allocator, .array, .text, parsed.value);
    defer value.deinit(allocator);
    try typed_codec.writeJsonToBuf(&buf, allocator, value);
    const expected_sql = try std.fmt.allocPrint(allocator, "SELECT count(*) FROM items WHERE tags = jsonb('{s}')", .{buf.items});
    defer allocator.free(expected_sql);
    try std.testing.expectEqual(@as(i64, 1), try h.int(expected_sql));

    // New rows sort after every existing created_at, strictly increasing.
    try std.testing.expectEqual(@as(i64, 3), try h.int("SELECT count(DISTINCT created_at) FROM items"));
    try std.testing.expectEqual(@as(i64, 2), try h.int("SELECT count(*) FROM items WHERE created_at > 9000000000000000"));
    try std.testing.expectEqual(@as(i64, 3), try h.int("SELECT count(DISTINCT id) FROM items WHERE length(id) = 16"));

    // Helpers exist only during the run.
    try std.testing.expectError(error.SQLiteError, h.db.oneDynamic(i64, "SELECT zync_now()", .{}, .{}));
}

test "migrate: zync_array rejects values the runtime would reject" {
    const tags_v1 =
        \\{"version":"1.0.0","store":{"items":{"fields":{"tag":{"type":"string"}}}}}
    ;
    const tags_v2 =
        \\{"version":"2.0.0","store":{"items":{"fields":{"tags":{"type":"array","items":"integer"}}}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(tags_v1);
    try h.insert("items", "\"tag\"", "'b'");
    try h.writeMigration(m1, tags_v1, tags_v2,
        \\INSERT INTO "items" ("id", "namespace_id", "owner_id", "tags", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", jsonb(zync_array(json_array("tag"), 'integer')), "created_at", "updated_at"
        \\FROM "_zync_prev_items";
    );
    try std.testing.expectError(error.MigrationSqlFailed, h.migrate(tags_v2, .{}));
    try h.expectDiag("zync_array: an element does not match the items type");
}

test "migrate: several migrations run in one transaction with bridges between them" {
    const v1_notes =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]},
        \\  "notes":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    const v3 =
        \\{"version":"3.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "notes":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    const m2 = "20261118T100000Z_drop_priority";
    const copy_v3 =
        \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "notes", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "title", "notes", "created_at", "updated_at" FROM "_zync_prev_tasks";
    ;

    {
        var h = try Harness.init();
        defer h.deinit();
        try seedV1(&h);
        try h.writeMigration(m1, v1, v2, v1_to_v2_sql);
        // m2 starts after an auto change (notes added) that has no migration.
        try h.writeMigration(m2, v1_notes, v3, copy_v3);
        var report = try h.migrateOk(v3);
        defer report.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), report.migrations_applied);
        try std.testing.expectEqual(@as(usize, 3), report.steps);
        try h.expectApplied("3.0.0");
        try h.expectLayout(v3);
        try std.testing.expectEqual(@as(i64, 3), try h.int("SELECT count(*) FROM tasks"));
    }
    {
        // The second migration fails: the first is rolled back too.
        var h = try Harness.init();
        defer h.deinit();
        try seedV1(&h);
        try h.writeMigration(m1, v1, v2, v1_to_v2_sql);
        try h.writeMigration(m2, v1_notes, v3, "SELECT 1;");
        try std.testing.expectError(error.RowsNotCarriedOver, h.migrate(v3, .{}));
        try h.expectApplied("1.0.0");
        try h.expectLayout(v1);
        try std.testing.expectEqual(@as(i64, 0), try h.int("SELECT count(*) FROM _zync_migrations"));
        try std.testing.expectEqual(@as(i64, 1), try h.int("SELECT count(*) FROM tasks WHERE priority = 1"));
    }
}

test "migrate: a migration whose start the database cannot reach is refused" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    const other_start =
        \\{"version":"1.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    try h.writeMigration(m1, other_start, v2, v1_to_v2_sql);
    try std.testing.expectError(error.MigrationBaseMismatch, h.migrate(v2, .{}));
    try h.expectDiag("tasks.assignee");
}

test "migrate: history must be linear and applied migrations immutable" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2, v1_to_v2_sql);
    _ = try h.migrateOk(v2);

    // Editing an applied migration is refused.
    try h.removeMigration(m1);
    try h.writeMigration(m1, v1, v2, v1_to_v2_sql ++ "\n-- tweak\n");
    try std.testing.expectError(error.AppliedMigrationModified, h.migrate(v2, .{}));
    try h.expectDiag(m1);

    // Deleting an applied migration is allowed.
    try h.removeMigration(m1);
    var report = try h.migrateOk(v2);
    report.deinit(allocator);

    // A new migration that sorts before the applied one is refused.
    const v3 =
        \\{"version":"3.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    try h.writeMigration("20261101T000000Z_late", v2, v3, "SELECT 1;");
    try std.testing.expectError(error.MigrationOutOfOrder, h.migrate(v3, .{}));
}

test "migrate: fresh databases record existing migrations as baseline" {
    var h = try Harness.init();
    defer h.deinit();
    try h.writeMigration(m1, v1, v2, v1_to_v2_sql);
    var report = try h.migrateOk(v2);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.migrations_baselined);
    try std.testing.expectEqual(@as(usize, 0), report.migrations_applied);
    try h.expectText("baseline", "SELECT mode FROM _zync_migrations");
    try h.expectLayout(v2);

    // A baseline entry is matched by id only: editing the files is harmless.
    try h.removeMigration(m1);
    try h.writeMigration(m1, v1, v2, "-- rewritten after the fact\n" ++ v1_to_v2_sql);
    var again = try h.migrateOk(v2);
    defer again.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), again.steps);
}

test "migrate: dry runs execute everything and then roll back" {
    var h = try Harness.init();
    defer h.deinit();
    try seedV1(&h);
    try h.writeMigration(m1, v1, v2, v1_to_v2_sql);
    var report = try h.migrate(v2, .{ .dry_run = true });
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.migrations_applied);
    try h.expectApplied("1.0.0");
    try h.expectLayout(v1);
    try std.testing.expectEqual(@as(i64, 0), try h.int("SELECT count(*) FROM _zync_migrations"));
    try h.expectPragmasRestored();
}

test "migrate: a pre-migration snapshot is written only for developer migrations" {
    var h = try Harness.initWithDb(true);
    defer h.deinit();
    _ = try h.migrateOk(v1);
    try h.insert("tasks", "\"title\", \"priority\"", "'a', 1");

    // Auto change: no snapshot.
    const v1_auto =
        \\{"version":"1.1.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"integer"},
        \\  "assignee":{"type":"string"},
        \\  "extra":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    var auto_report = try h.migrate(v1_auto, .{ .snapshot = true });
    defer auto_report.deinit(allocator);
    try std.testing.expect(auto_report.snapshot_path == null);

    const v2_from_auto =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]}
        \\},"required":["title"]}}}
    ;
    try h.writeMigration(m1, v1_auto, v2_from_auto, v1_to_v2_sql);
    var report = h.migrate(v2_from_auto, .{ .snapshot = true }) catch |err| {
        for (h.diag.items()) |line| std.debug.print("{s}\n", .{line});
        return err;
    };
    defer report.deinit(allocator);
    const snapshot = report.snapshot_path orelse return error.TestExpectedValue;
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "zyncbase.db.pre-migration-" ++ m1 ++ "-") != null);
    try backup.verify(std.testing.io, allocator, snapshot, true);

    // The snapshot holds the database as it was before the migration.
    // zwanzig-disable-next-line: sentinel-alloc
    const snapshot_z = try allocator.dupeZ(u8, snapshot);
    defer allocator.free(snapshot_z);
    var before = try sqlite.Db.init(.{ .mode = .{ .File = snapshot_z }, .open_flags = .{ .write = false } });
    defer before.deinit();
    const version = try before.oneAlloc([]const u8, allocator, "SELECT version FROM _zync_schema", .{}, .{});
    defer if (version) |v| allocator.free(v);
    try std.testing.expectEqualStrings("1.1.0", version orelse return error.TestExpectedValue);
}

test "migrate: renaming a table moves rows and empties the prev table" {
    const old =
        \\{"version":"1.0.0","store":{"todos":{"fields":{"title":{"type":"string"}}}}}
    ;
    const renamed =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}}}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(old);
    try h.insert("todos", "\"title\"", "'x'");
    try h.writeMigration(m1, old, renamed,
        \\INSERT INTO "tasks" SELECT * FROM "_zync_prev_todos";
        \\DELETE FROM "_zync_prev_todos";
    );
    _ = try h.migrateOk(renamed);
    try h.expectLayout(renamed);
    try h.expectText("x", "SELECT title FROM tasks");
    try std.testing.expect(!try catalog.tableExists(&h.db, "todos"));
}

test "migrate: a case-only table rename moves the old table aside first" {
    const before =
        \\{"version":"1.0.0","store":{"Tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    const after =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(before);
    try h.insert("Tasks", "\"title\"", "'a'");
    try h.writeMigration(m1, before, after,
        \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "title", "created_at", "updated_at" FROM "_zync_prev_Tasks";
        \\DELETE FROM "_zync_prev_Tasks";
    );
    var report = try h.migrateOk(after);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.migrations_applied);
    try h.expectApplied("2.0.0");
    try h.expectLayout(after);
    try std.testing.expectEqual(@as(i64, 1), try h.int("SELECT count(*) FROM tasks"));
}

test "migrate: the scaffold array conversion keeps NULL, empty, and values" {
    const before =
        \\{"version":"1.0.0","store":{"items":{"fields":{"name":{"type":"string"},"nums":{"type":"array","items":"integer"}}}}}
    ;
    const after =
        \\{"version":"2.0.0","store":{"items":{"fields":{"name":{"type":"string"},"nums":{"type":"array","items":"string"}}}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(before);
    try h.exec("INSERT INTO items (id, namespace_id, owner_id, name, nums, created_at, updated_at) VALUES " ++
        "(randomblob(16), 1, zeroblob(16), 'null', NULL, 1, 1), " ++
        "(randomblob(16), 1, zeroblob(16), 'empty', jsonb('[]'), 2, 2), " ++
        "(randomblob(16), 1, zeroblob(16), 'nums', jsonb('[1,2]'), 3, 3)");
    try h.writeMigration(m1, before, after,
        \\INSERT INTO "items" ("id", "namespace_id", "owner_id", "name", "nums", "created_at", "updated_at")
        \\SELECT "id", "namespace_id", "owner_id", "name",
        \\  CASE WHEN "nums" IS NULL THEN NULL ELSE jsonb(zync_array((SELECT json_group_array(CAST(value AS TEXT)) FROM json_each("nums")), 'string')) END,
        \\  "created_at", "updated_at"
        \\FROM "_zync_prev_items";
    );
    _ = try h.migrateOk(after);
    try std.testing.expectEqual(@as(i64, 1), try h.int("SELECT count(*) FROM items WHERE nums IS NULL"));
    try h.expectText("[]", "SELECT json(nums) FROM items WHERE name = 'empty'");
    try h.expectText("[\"1\",\"2\"]", "SELECT json(nums) FROM items WHERE name = 'nums'");
}

test "migrate: namespaced changes reassign namespace_id in SQL" {
    const scoped =
        \\{"version":"1.0.0","store":{"settings":{"fields":{"key":{"type":"string"}},"unique":[["key"]]}}}
    ;
    const global =
        \\{"version":"2.0.0","store":{"settings":{"namespaced":false,"fields":{"key":{"type":"string"}},"unique":[["key"]]}}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrateOk(scoped);
    try h.insert("settings", "\"key\"", "'theme'");
    try h.exec("UPDATE settings SET namespace_id = 7");
    try h.writeMigration(m1, scoped, global,
        \\INSERT INTO "settings" ("id", "namespace_id", "owner_id", "key", "created_at", "updated_at")
        \\SELECT "id", 0, "owner_id", "key", "created_at", "updated_at" FROM "_zync_prev_settings";
    );
    _ = try h.migrateOk(global);
    try std.testing.expectEqual(@as(i64, 0), try h.int("SELECT namespace_id FROM settings"));
}
