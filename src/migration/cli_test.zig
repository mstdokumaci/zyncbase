//! `zyncbase migrate ...` and `zyncbase reset` against a project in a
//! temporary directory.

const std = @import("std");

const sqlite = @import("sqlite");

const cli = @import("cli.zig");
const ConfigLoader = @import("../config/loader.zig").ConfigLoader;
const Config = @import("../config/state.zig").Config;

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
