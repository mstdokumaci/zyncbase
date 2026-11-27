//! `zyncbase migrate ...` and `zyncbase reset` against a project in a
//! temporary directory.

const std = @import("std");

const sqlite = @import("sqlite");

const backup = @import("../backup.zig");
const cli = @import("cli.zig");
const ConfigLoader = @import("../config/loader.zig").ConfigLoader;
const Config = @import("../config/state.zig").Config;
const DataLock = @import("../data_lock.zig").DataLock;

const allocator = std.testing.allocator;

test "migrate cli: arguments are parsed per subcommand" {
    const status = try cli.parseMigrate(&.{ "status", "--db", "copy.db", "--config", "c.json" });
    try std.testing.expectEqual(cli.Subcommand.status, status.sub);
    try std.testing.expectEqualStrings("copy.db", status.db orelse return error.TestExpectedValue);
    try std.testing.expectEqualStrings("c.json", status.config_path orelse return error.TestExpectedValue);

    const new = try cli.parseMigrate(&.{ "new", "priority_to_string", "--from", "old.json" });
    try std.testing.expectEqualStrings("priority_to_string", new.name orelse return error.TestExpectedValue);
    try std.testing.expectEqualStrings("old.json", new.from orelse return error.TestExpectedValue);

    const apply = try cli.parseMigrate(&.{ "apply", "--dry-run", "--data-dir", "d" });
    try std.testing.expect(apply.dry_run);
    try std.testing.expectEqualStrings("d", apply.data_dir orelse return error.TestExpectedValue);

    const reset = try cli.parseReset(&.{ "--yes", "--no-safety-copy" });
    try std.testing.expect(reset.yes and reset.no_safety_copy);

    try std.testing.expectError(error.MissingCommand, cli.parseMigrate(&.{}));
    try std.testing.expectError(error.UnknownCommand, cli.parseMigrate(&.{"reset"}));
    try std.testing.expectError(error.MissingMigrationName, cli.parseMigrate(&.{"new"}));
    try std.testing.expectError(error.InvalidMigrationName, cli.parseMigrate(&.{ "new", "Bad-Name" }));
    try std.testing.expectError(error.AmendWithFrom, cli.parseMigrate(&.{ "new", "x", "--amend", "--from", "a.json" }));
    try std.testing.expectError(error.UnknownOption, cli.parseMigrate(&.{ "check", "--data-dir", "d" }));
    try std.testing.expectError(error.UnknownOption, cli.parseMigrate(&.{ "new", "x", "--db", "a.db" }));
    try std.testing.expectError(error.UnknownOption, cli.parseMigrate(&.{ "status", "--dry-run" }));
    try std.testing.expectError(error.UnexpectedArgument, cli.parseMigrate(&.{ "status", "extra" }));
    try std.testing.expectError(error.MissingOptionValue, cli.parseMigrate(&.{ "apply", "--db" }));
    try std.testing.expectError(error.MissingOptionValue, cli.parseMigrate(&.{ "status", "--config", "--db" }));
    const relative = try cli.parseMigrate(&.{ "status", "--db", "./--dry-run" });
    try std.testing.expectEqualStrings("./--dry-run", relative.db orelse return error.TestExpectedValue);
}

/// Writes `<root>/zyncbase-config.json` (data in `<root>/data`) and loads it.
fn loadConfig(root: []const u8, schema_path: []const u8) !Config {
    const config_path = try std.fs.path.join(allocator, &.{ root, "zyncbase-config.json" });
    defer allocator.free(config_path);
    const config_json = try std.fmt.allocPrint(allocator, "{{\"dataDir\":\"{s}/data\",\"schema\":\"{s}\"}}", .{ root, schema_path });
    defer allocator.free(config_json);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = config_json });

    var environ = try std.testing.environ.createMap(allocator);
    defer environ.deinit();
    return ConfigLoader.load(std.testing.io, &environ, allocator, config_path);
}

const Harness = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    schema_path: []u8,
    db_path: [:0]u8,
    migrations_dir: []u8,
    config: Config,
    out: std.Io.Writer.Allocating,

    /// Must not move after the first `run` (the writer points into it).
    fn init(schema_json: []const u8) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..] });
        errdefer allocator.free(root);
        const schema_path = try std.fs.path.join(allocator, &.{ root, "schema.json" });
        errdefer allocator.free(schema_path);
        const db_path = try std.fs.path.joinZ(allocator, &.{ root, "data", "zyncbase.db" });
        errdefer allocator.free(db_path);
        const migrations_dir = try std.fs.path.join(allocator, &.{ root, "migrations" });
        errdefer allocator.free(migrations_dir);

        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = schema_path, .data = schema_json });
        const config = try loadConfig(root, schema_path);
        return .{
            .tmp = tmp,
            .root = root,
            .schema_path = schema_path,
            .db_path = db_path,
            .migrations_dir = migrations_dir,
            .config = config,
            .out = .init(allocator),
        };
    }

    fn deinit(self: *Harness) void {
        self.out.deinit();
        self.config.deinit();
        allocator.free(self.migrations_dir);
        allocator.free(self.db_path);
        allocator.free(self.schema_path);
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn setSchema(self: *Harness, json: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = self.schema_path, .data = json });
    }

    /// Runs `zyncbase migrate <args>` (or `zyncbase reset <args>`).
    fn run(self: *Harness, args: []const []const u8) !void {
        self.out.clearRetainingCapacity();
        const cmd = if (std.mem.eql(u8, args[0], "reset")) try cli.parseReset(args[1..]) else try cli.parseMigrate(args);
        try cli.execute(.{ .io = std.testing.io, .allocator = allocator, .config = &self.config, .out = &self.out.writer }, cmd);
    }

    /// Runs a command expected to succeed; prints its output otherwise.
    fn runOk(self: *Harness, args: []const []const u8) !void {
        self.run(args) catch |err| {
            std.debug.print("{s}\n", .{self.out.written()});
            return err;
        };
    }

    fn expectOutput(self: *Harness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.out.written(), needle) != null) return;
        std.debug.print("--- output ---\n{s}\n--- expected to contain ---\n{s}\n", .{ self.out.written(), needle });
        return error.TestUnexpectedResult;
    }

    fn openDb(self: *Harness) !sqlite.Db {
        return sqlite.Db.init(.{ .mode = .{ .File = self.db_path }, .open_flags = .{ .write = true, .create = false } });
    }

    fn exec(self: *Harness, sql: []const u8) !void {
        var db = try self.openDb();
        defer db.deinit();
        try db.execDynamic(sql, .{}, .{});
    }

    fn int(self: *Harness, sql: []const u8) !i64 {
        var db = try self.openDb();
        defer db.deinit();
        return (try db.oneDynamic(i64, sql, .{}, .{})) orelse error.TestExpectedValue;
    }

    fn expectAppliedVersion(self: *Harness, version: []const u8) !void {
        try self.runOk(&.{"status"});
        const line = try std.fmt.allocPrint(allocator, "Applied:    {s}  ", .{version});
        defer allocator.free(line);
        try self.expectOutput(line);
    }

    /// The only migration folder, as `<migrations>/<id>`. Owned by the caller.
    fn onlyMigration(self: *Harness) ![]u8 {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, self.migrations_dir, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var found: ?[]u8 = null;
        errdefer if (found) |path| allocator.free(path);
        var iter = dir.iterate();
        while (try iter.next(std.testing.io)) |entry| {
            if (entry.name[0] == '.') continue;
            if (found != null) return error.TestUnexpectedResult;
            found = try std.fs.path.join(allocator, &.{ self.migrations_dir, entry.name });
        }
        return found orelse error.TestExpectedValue;
    }

    /// The newest migration folder by id. Owned by the caller.
    fn latestMigration(self: *Harness) ![]u8 {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, self.migrations_dir, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var found: ?[]u8 = null;
        errdefer if (found) |path| allocator.free(path);
        var iter = dir.iterate();
        while (try iter.next(std.testing.io)) |entry| {
            if (entry.name[0] == '.' or entry.kind != .directory) continue;
            if (found) |current| {
                const keep_current = std.mem.order(u8, std.fs.path.basename(current), entry.name) == .gt;
                if (keep_current) continue;
                allocator.free(current);
                found = null;
            }
            found = try std.fs.path.join(allocator, &.{ self.migrations_dir, entry.name });
        }
        return found orelse error.TestExpectedValue;
    }

    /// The newest snapshot written for `id`. Owned by the caller.
    fn latestSnapshot(self: *Harness, id: []const u8) ![]u8 {
        const dir_path = std.fs.path.dirname(self.db_path) orelse ".";
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var prefix_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}.pre-migration-{s}-", .{ std.fs.path.basename(self.db_path), id });
        var found: ?[]u8 = null;
        errdefer if (found) |path| allocator.free(path);
        var iter = dir.iterate();
        while (try iter.next(std.testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (found) |current| {
                const keep_current = std.mem.order(u8, std.fs.path.basename(current), entry.name) == .gt;
                if (keep_current) continue;
                allocator.free(current);
                found = null;
            }
            found = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        }
        return found orelse error.TestExpectedValue;
    }

    fn deleteSnapshots(self: *Harness) !void {
        const dir_path = std.fs.path.dirname(self.db_path) orelse ".";
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var prefix_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}.pre-migration-", .{std.fs.path.basename(self.db_path)});
        var iter = dir.iterate();
        while (try iter.next(std.testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            try std.Io.Dir.cwd().deleteFile(std.testing.io, try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }));
        }
    }

    fn readMigrationFile(self: *Harness, folder: []const u8, name: []const u8) ![]u8 {
        _ = self;
        const path = try std.fs.path.join(allocator, &.{ folder, name });
        defer allocator.free(path);
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
    }

    fn writeMigrationFile(self: *Harness, folder: []const u8, name: []const u8, data: []const u8) !void {
        _ = self;
        const path = try std.fs.path.join(allocator, &.{ folder, name });
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn seedTasks(self: *Harness) !void {
        try self.exec(
            "INSERT INTO tasks (id, namespace_id, owner_id, title, priority, assignee, created_at, updated_at) VALUES " ++
                "(randomblob(16), 1, zeroblob(16), 'a', 1, 'ann', 1, 1), " ++
                "(randomblob(16), 1, zeroblob(16), 'b', 2, NULL, 2, 2), " ++
                "(randomblob(16), 1, zeroblob(16), 'c', 9, 'cy', 3, 3)",
        );
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
    \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "priority", "created_at", "updated_at")
    \\SELECT "id", "namespace_id", "owner_id", "title",
    \\       CASE "priority" WHEN 1 THEN 'low' WHEN 2 THEN 'medium' ELSE 'high' END,
    \\       "created_at", "updated_at"
    \\FROM "_zync_prev_tasks";
    \\
;

test "migrate cli: status, new, check and apply take a project through a migration" {
    var h = try Harness.init(v1);
    defer h.deinit();

    try h.runOk(&.{"status"});
    try h.expectOutput("(not created yet)");
    try h.expectOutput("Applied:    none");
    try h.expectOutput("initial schema 1.0.0");
    try std.testing.expectError(error.NoMigrationBase, h.run(&.{ "new", "too_early" }));

    try h.runOk(&.{"apply"});
    try h.expectOutput("Applied 1 step(s) and 0 migration(s)");
    try h.expectAppliedVersion("1.0.0");
    try h.expectOutput("Up to date");
    try h.seedTasks();

    try h.setSchema(v2);
    try std.testing.expectError(error.MigrationRequired, h.run(&.{"status"}));
    try h.expectOutput("The next start fails (MigrationRequired)");
    try h.expectOutput("tasks.priority  type changed  (migration required)");

    try h.runOk(&.{ "new", "priority_to_string" });
    try h.expectOutput("_priority_to_string");
    try h.expectOutput("decision(s) to make");
    const folder = try h.onlyMigration();
    defer allocator.free(folder);
    const before = try h.readMigrationFile(folder, "before.json");
    defer allocator.free(before);
    try std.testing.expect(std.mem.startsWith(u8, before, "{\n\t\"version\": \"1.0.0\","));
    const after = try h.readMigrationFile(folder, "after.json");
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"version\": \"2.0.0\"") != null);

    // The pending migration already produces schema.json.
    try std.testing.expectError(error.NothingToMigrate, h.run(&.{ "new", "again" }));

    try h.runOk(&.{"status"});
    try h.expectOutput("_priority_to_string  pending");

    try std.testing.expectError(error.MigrationCheckFailed, h.run(&.{"check"}));
    try h.expectOutput("FAIL  ");
    try h.expectOutput("unresolved decision: tasks.priority: integer -> string");
    try h.expectOutput("skip  chain");

    try h.writeMigrationFile(folder, "migration.sql", v1_to_v2_sql);
    try h.runOk(&.{"check"});
    try h.expectOutput("ok    chain 1.0.0 -> 2.0.0 (schema.json)");

    try h.runOk(&.{ "apply", "--dry-run" });
    try h.expectOutput("Dry run: 1 step(s) and 1 migration(s)");
    try h.expectAppliedVersion("1.0.0");

    try h.runOk(&.{"apply"});
    try h.expectOutput("Pre-migration snapshot: ");
    try h.expectOutput("Applied 1 step(s) and 1 migration(s)");
    try h.expectAppliedVersion("2.0.0");
    try h.expectOutput("_priority_to_string  applied");
    try h.expectOutput("Up to date");
    try std.testing.expectEqual(@as(i64, 3), try h.int("SELECT count(*) FROM tasks WHERE priority IN ('low', 'medium', 'high')"));
}

test "migrate cli: new demands a major bump, and --amend folds the change into the last migration" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.seedTasks();

    try h.setSchema(v2);
    try h.runOk(&.{ "new", "priority_to_string" });
    const folder = try h.onlyMigration();
    defer allocator.free(folder);
    try h.writeMigrationFile(folder, "migration.sql", v1_to_v2_sql);
    try h.runOk(&.{"apply"});
    try h.expectAppliedVersion("2.0.0");

    // Another destructive change on the same major version.
    const v2_without_priority =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    try h.setSchema(v2_without_priority);
    try std.testing.expectError(error.MajorVersionBumpRequired, h.run(&.{ "new", "drop_priority" }));
    try h.expectOutput("set \"version\" to 3.0.0 or later");
    try h.expectOutput("--amend");

    try h.runOk(&.{ "new", "priority_to_string", "--amend" });
    try h.expectOutput("Restored ");
    try h.expectOutput("Amended ");
    try h.expectOutput("it runs as generated");
    try h.expectAppliedVersion("1.0.0");
    try h.expectOutput("_priority_to_string  pending");

    const amended = try h.onlyMigration();
    defer allocator.free(amended);
    try std.testing.expectEqualStrings(folder, amended);
    const sql = try h.readMigrationFile(amended, "migration.sql");
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "-- Previous migration.sql of ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "-- FROM \"_zync_prev_tasks\";") != null);

    try h.runOk(&.{"apply"});
    try h.expectAppliedVersion("2.0.0");
    try std.testing.expectEqual(@as(i64, 3), try h.int("SELECT count(*) FROM tasks"));
}

test "migrate cli: an explicit base must be reachable from the migration chain" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.setSchema(v2);
    try h.runOk(&.{ "new", "first" });

    const v3 =
        \\{"version":"3.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]},
        \\  "notes":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    try h.setSchema(v3);

    const blocked =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    const blocked_path = try std.fs.path.join(allocator, &.{ h.root, "blocked.json" });
    defer allocator.free(blocked_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = blocked_path, .data = blocked });
    try std.testing.expectError(error.MigrationBaseMismatch, h.run(&.{ "new", "second", "--from", blocked_path }));
    try h.expectOutput("not reachable");

    const reachable =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]},
        \\  "assignee":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    const reachable_path = try std.fs.path.join(allocator, &.{ h.root, "reachable.json" });
    defer allocator.free(reachable_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = reachable_path, .data = reachable });
    try h.runOk(&.{ "new", "second", "--from", reachable_path });
    try h.expectOutput("Created ");
}

test "migrate cli: --amend is not suggested without a usable snapshot" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.seedTasks();
    try h.setSchema(v2);
    try h.runOk(&.{ "new", "priority_to_string" });
    const folder = try h.onlyMigration();
    defer allocator.free(folder);
    try h.writeMigrationFile(folder, "migration.sql", v1_to_v2_sql);
    try h.runOk(&.{"apply"});
    try h.deleteSnapshots();

    const v2_without_priority =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    try h.setSchema(v2_without_priority);
    try std.testing.expectError(error.MajorVersionBumpRequired, h.run(&.{ "new", "drop_priority" }));
    try std.testing.expect(std.mem.indexOf(u8, h.out.written(), "--amend") == null);
}

test "migrate cli: --amend replays a batch from its first snapshot" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.seedTasks();

    try h.setSchema(v2);
    try h.runOk(&.{ "new", "priority_to_string" });
    const first = try h.onlyMigration();
    defer allocator.free(first);
    try h.writeMigrationFile(first, "migration.sql", v1_to_v2_sql);

    const v3 =
        \\{"version":"3.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]},
        \\  "notes":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    try h.setSchema(v3);
    try h.runOk(&.{ "new", "zz_add_notes" });

    // Both migrations run in one transaction, so the only snapshot is pre-first.
    try h.runOk(&.{"apply"});
    try h.expectAppliedVersion("3.0.0");

    const v3_1 =
        \\{"version":"3.1.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]},
        \\  "notes":{"type":"string"},
        \\  "extra":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    try h.setSchema(v3_1);
    try h.runOk(&.{ "new", "zz_notes_again", "--amend" });
    try h.expectOutput("Restored ");
    try h.expectAppliedVersion("1.0.0");

    try h.runOk(&.{"apply"});
    try h.expectAppliedVersion("3.1.0");
    try std.testing.expectEqual(@as(i64, 3), try h.int("SELECT count(*) FROM tasks"));
}

test "migrate cli: --amend does not reuse another batch's snapshot" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.seedTasks();

    try h.setSchema(v2);
    try h.runOk(&.{ "new", "priority_to_string" });
    const first = try h.onlyMigration();
    defer allocator.free(first);
    try h.writeMigrationFile(first, "migration.sql", v1_to_v2_sql);
    try h.runOk(&.{"apply"});

    const v3 =
        \\{"version":"3.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]},
        \\  "notes":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    try h.setSchema(v3);
    try h.runOk(&.{ "new", "zz_add_notes" });
    const second = try h.latestMigration();
    defer allocator.free(second);
    try h.runOk(&.{"apply"});

    // B has its own batch. Removing its snapshot must not fall back to A's.
    const second_snapshot = try h.latestSnapshot(std.fs.path.basename(second));
    defer allocator.free(second_snapshot);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, second_snapshot);

    const v3_1 =
        \\{"version":"3.1.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string","enum":["low","medium","high"]},
        \\  "notes":{"type":"string"},
        \\  "extra":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    try h.setSchema(v3_1);
    try std.testing.expectError(error.SnapshotNotFound, h.run(&.{ "new", "zz_notes_again", "--amend" }));
    try h.expectAppliedVersion("3.0.0");
}

test "migrate cli: a database with an unknown layout is refused" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.exec("UPDATE _zync_schema SET layout = 99");

    try std.testing.expectError(error.UnsupportedLayout, h.run(&.{ "new", "blocked" }));
    try h.expectOutput("layout 99");
}

test "migrate cli: a new id must sort after the newest ledger entry" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.exec(
        "INSERT INTO _zync_migrations (id, mode, before_version, after_version, after_hash, sql_hash, applied_at) " ++
            "VALUES ('20991231T235959Z_future', 'applied', '1.0.0', '1.0.0', 'sha256:00', 'sha256:00', 0)",
    );

    try std.testing.expectError(error.MigrationOutOfOrder, h.run(&.{ "new", "too_early" }));
    try h.expectOutput("20991231T235959Z_future");
}

test "migrate cli: an explicit --db must exist and is not recreated" {
    var h = try Harness.init(v1);
    defer h.deinit();
    const missing = try std.fs.path.join(allocator, &.{ h.root, "missing.db" });
    defer allocator.free(missing);

    try std.testing.expectError(error.DatabaseNotFound, h.run(&.{ "apply", "--db", missing }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, missing, .{}));
}

test "migrate cli: apply rejects an unrelated explicit database without writing" {
    var h = try Harness.init(v1);
    defer h.deinit();
    const other_path = try std.fs.path.join(allocator, &.{ h.root, "other.db" });
    defer allocator.free(other_path);
    // zwanzig-disable-next-line: sentinel-alloc
    const other_path_z = try allocator.dupeZ(u8, other_path);
    defer allocator.free(other_path_z);

    {
        var other = try sqlite.Db.init(.{ .mode = .{ .File = other_path_z }, .open_flags = .{ .write = true, .create = true } });
        defer other.deinit();
        try other.exec("CREATE TABLE other (id INTEGER PRIMARY KEY)", .{}, .{});
    }

    try std.testing.expectError(error.UnrecognizedDatabase, h.run(&.{ "apply", "--db", other_path }));

    var other = try sqlite.Db.init(.{ .mode = .{ .File = other_path_z }, .open_flags = .{ .write = false } });
    defer other.deinit();
    const tables = try other.one(i64, "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 1), tables);
    const namespace_tables = try other.one(i64, "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name = '_zync_namespaces'", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 0), namespace_tables);
}

test "migrate cli: apply recovers a configured explicit database" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});

    var stamp_buf: [backup.utc_timestamp_len]u8 = undefined;
    const stamp = backup.utcTimestamp(std.testing.io, &stamp_buf);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.reset-journal", .{h.db_path});
    defer allocator.free(journal_path);
    const journal = try std.fmt.allocPrint(allocator, "zyncbase-reset-v1\n{s}\n1\n", .{stamp});
    defer allocator.free(journal);
    const aside = try std.fmt.allocPrint(allocator, "{s}.pre-reset-{s}", .{ h.db_path, stamp });
    defer allocator.free(aside);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(std.testing.io, .{ .sub_path = journal_path, .data = journal });
    try cwd.rename(h.db_path, cwd, aside, std.testing.io);

    try h.runOk(&.{ "apply", "--db", h.db_path });
    try h.expectAppliedVersion("1.0.0");
    try cwd.access(std.testing.io, aside, .{});
}

test "migrate cli: apply rejects pending recovery for another explicit database" {
    var h = try Harness.init(v1);
    defer h.deinit();
    const other_path = try std.fs.path.join(allocator, &.{ h.root, "other.db" });
    defer allocator.free(other_path);
    // zwanzig-disable-next-line: sentinel-alloc
    const other_path_z = try allocator.dupeZ(u8, other_path);
    defer allocator.free(other_path_z);
    {
        var other = try sqlite.Db.init(.{ .mode = .{ .File = other_path_z }, .open_flags = .{ .write = true, .create = true } });
        defer other.deinit();
        try other.exec("CREATE TABLE other (id INTEGER PRIMARY KEY)", .{}, .{});
    }
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.reset-journal", .{other_path});
    defer allocator.free(journal_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = journal_path, .data = "pending" });

    try std.testing.expectError(error.RecoveryPending, h.run(&.{ "apply", "--db", other_path }));
}

test "migrate cli: status refuses a pending restore journal" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});

    const journal_path = try std.fmt.allocPrint(allocator, "{s}.restore-journal", .{h.db_path});
    defer allocator.free(journal_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = journal_path, .data = "pending" });

    try std.testing.expectError(error.RestoreInProgress, h.run(&.{"status"}));
    try h.expectOutput("restore is pending");
}

test "migrate cli: status refuses a restore journal before the database exists" {
    var h = try Harness.init(v1);
    defer h.deinit();
    const data_dir = std.fs.path.dirname(h.db_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_dir);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.restore-journal", .{h.db_path});
    defer allocator.free(journal_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = journal_path, .data = "pending" });

    try std.testing.expectError(error.RestoreInProgress, h.run(&.{"status"}));
    try h.expectOutput("restore is pending");
}

test "migrate cli: status reports an active restore" {
    var h = try Harness.init(v1);
    defer h.deinit();
    const data_dir = std.fs.path.dirname(h.db_path) orelse ".";
    var lock = try DataLock.acquire(std.testing.io, allocator, data_dir);
    defer lock.release(std.testing.io);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.restore-journal", .{h.db_path});
    defer allocator.free(journal_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = journal_path, .data = "pending" });

    try std.testing.expectError(error.RestoreInProgress, h.run(&.{"status"}));
    try h.expectOutput("restore is pending");
}

test "migrate cli: status reports a data directory held by another process" {
    var h = try Harness.init(v1);
    defer h.deinit();
    const data_dir = std.fs.path.dirname(h.db_path) orelse ".";
    var lock = try DataLock.acquire(std.testing.io, allocator, data_dir);
    defer lock.release(std.testing.io);
    try std.testing.expectError(error.DataDirLocked, h.run(&.{"status"}));
    try h.expectOutput("in use by another zyncbase process");
}
test "migrate cli: a max major version reports that it cannot be raised" {
    const vmax =
        \\{"version":"4294967295.0.0","store":{"tasks":{"fields":{"title":{"type":"string"},"priority":{"type":"integer"}},"required":["title"]}}}
    ;
    const vmax_removed =
        \\{"version":"4294967295.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    var h = try Harness.init(vmax);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.setSchema(vmax_removed);

    try std.testing.expectError(error.MajorVersionBumpRequired, h.run(&.{ "new", "drop_priority" }));
    try h.expectOutput("cannot be raised further");
}

test "migrate cli: per-migration checks skip the deployment foreign-key check" {
    const schema =
        \\{"version":"1.0.0","store":{"projects":{"fields":{"name":{"type":"string"}}},"tasks":{"fields":{"title":{"type":"string"},"project_id":{"type":"string","references":"projects"}},"required":["title"]}}}
    ;
    var h = try Harness.init(schema);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.runOk(&.{ "new", "orphan" });
    const folder = try h.onlyMigration();
    defer allocator.free(folder);
    try h.writeMigrationFile(folder, "migration.sql",
        \\INSERT INTO "tasks" ("id", "namespace_id", "owner_id", "title", "project_id", "created_at", "updated_at")
        \\VALUES (randomblob(16), 1, zeroblob(16), 'orphan', randomblob(16), 1, 1);
    );

    // The per-migration run has no FK check; the chain run catches the orphan.
    try std.testing.expectError(error.MigrationCheckFailed, h.run(&.{"check"}));
    try h.expectOutput("ok    ");
    try h.expectOutput("FAIL  chain");
}

test "migrate cli: an interrupted amend is refused before the database is restored" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});
    try h.seedTasks();
    try h.setSchema(v2);
    try h.runOk(&.{ "new", "priority_to_string" });
    const folder = try h.onlyMigration();
    defer allocator.free(folder);
    try h.writeMigrationFile(folder, "migration.sql", v1_to_v2_sql);
    try h.runOk(&.{"apply"});

    // A crash after the restore but before the folder swap leaves the database
    // at 1.0.0 and the old folder in `.replaced`.
    const snapshot = try h.latestSnapshot(std.fs.path.basename(folder));
    defer allocator.free(snapshot);
    const data_dir = std.fs.path.dirname(h.db_path) orelse ".";
    var restored = try backup.restore(std.testing.io, allocator, data_dir, snapshot, true);
    defer restored.deinit(allocator);

    const replaced = try std.fmt.allocPrint(allocator, "{s}/.{s}.replaced", .{ h.migrations_dir, std.fs.path.basename(folder) });
    defer allocator.free(replaced);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(folder, cwd, replaced, std.testing.io);

    const v2_without_priority =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}},"required":["title"]}}}
    ;
    try h.setSchema(v2_without_priority);
    try std.testing.expectError(error.InterruptedAmend, h.run(&.{ "new", "priority_to_string", "--amend" }));
    try h.expectOutput(".replaced");

    // The failure happens before the snapshot restore and even when no folder remains.
    try h.setSchema(v1);
    try h.expectAppliedVersion("1.0.0");
    try std.Io.Dir.cwd().access(std.testing.io, replaced, .{});

    // Recover by restoring the folder, then finish the migration normally.
    try cwd.rename(replaced, cwd, folder, std.testing.io);
    try h.setSchema(v2);
    try h.runOk(&.{"apply"});
    try h.expectAppliedVersion("2.0.0");
    try h.expectOutput("_priority_to_string  applied");
}

test "migrate cli: reset needs --yes and moves the database aside" {
    var h = try Harness.init(v1);
    defer h.deinit();
    try h.runOk(&.{"apply"});

    try std.testing.expectError(error.ConfirmationRequired, h.run(&.{"reset"}));
    try h.expectOutput("--yes");
    try h.runOk(&.{ "reset", "--yes" });
    try h.expectOutput(".pre-reset-");
    try h.runOk(&.{"status"});
    try h.expectOutput("(not created yet)");
    try h.runOk(&.{ "reset", "--yes" });
    try h.expectOutput("nothing to reset");
}
