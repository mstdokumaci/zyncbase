//! `migration.sql` scaffolds: the text per change kind, and that generated
//! scaffolds behave as promised when they run through startup.

const std = @import("std");

const sqlite = @import("sqlite");

const canonical = @import("../schema/canonical.zig");
const schema_diff = @import("../schema/diff.zig");
const schema_parse = @import("../schema/parse.zig");
const scaffold = @import("scaffold.zig");
const source = @import("source.zig");
const startup = @import("startup.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const allocator = std.testing.allocator;

const test_id = "20261117T100000Z_test";

/// Generates the scaffold for `before` -> `after`. Owned by `arena`.
fn generate(arena: std.mem.Allocator, before_json: []const u8, after_json: []const u8) ![]const u8 {
    var before = try schema_parse.initFromJson(allocator, before_json);
    defer before.deinit();
    var after = try schema_parse.initFromJson(allocator, after_json);
    defer after.deinit();
    var d = try schema_diff.diff(allocator, &before, &after);
    defer d.deinit();
    const before_id = try canonical.Identity.init(allocator, before_json);
    defer before_id.deinit(allocator);
    const after_id = try canonical.Identity.init(allocator, after_json);
    defer after_id.deinit(allocator);
    return scaffold.generate(arena, .{
        .id = test_id,
        .before = &before,
        .before_hash = &before_id.hash,
        .after = &after,
        .after_hash = &after_id.hash,
        .diff = &d,
    });
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("--- scaffold ---\n{s}\n--- expected to contain ---\n{s}\n", .{ haystack, needle });
    return error.TestUnexpectedResult;
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return;
    std.debug.print("--- scaffold ---\n{s}\n--- expected not to contain ---\n{s}\n", .{ haystack, needle });
    return error.TestUnexpectedResult;
}

const tasks_v1 =
    \\{"version":"1.0.0","store":{"tasks":{"fields":{
    \\  "title":{"type":"string"},
    \\  "priority":{"type":"integer"},
    \\  "assignee":{"type":"string"}
    \\},"required":["title"]}}}
;

test "scaffold: a type change is a todo with a conversion suggestion" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(), tasks_v1,
        \\{"version":"2.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string"}
        \\},"required":["title"]}}}
    );
    try expectContains(text, "-- ZyncBase migration " ++ test_id ++ "\n");
    try expectContains(text, "-- Schema 1.0.0 -> 2.0.0\n");
    try expectContains(text, "--   before sha256:");
    try expectContains(text, "--   tasks.priority  type changed  (migration required)\n");
    try expectContains(text, "--   tasks.assignee  removed  (migration required)\n");
    try expectContains(text, "INSERT INTO \"tasks\" (\"id\", \"namespace_id\", \"owner_id\", \"title\", \"priority\", \"created_at\", \"updated_at\")\n");
    try expectContains(text, "  \"title\",\n");
    try expectContains(text, "  zync_todo('tasks.priority: integer -> string. Example: CAST(\"priority\" AS TEXT)'),\n");
    try expectContains(text, "  \"updated_at\"\nFROM \"_zync_prev_tasks\";\n");
    try expectContains(text, "-- Removed: \"assignee\" (its values are dropped).\n");
}

test "scaffold: an added required field next to a removed one suggests a rename" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(), tasks_v1,
        \\{"version":"2.0.0","store":{"tasks":{"fields":{
        \\  "name":{"type":"string"},
        \\  "priority":{"type":"integer"},
        \\  "assignee":{"type":"string"}
        \\},"required":["name"]}}}
    );
    try expectContains(text, "zync_todo('tasks.name is new and required. Rename of \"title\"? Then use \"title\".')");
    try expectNotContains(text, "-- Removed: \"title\"");
    try expectContains(text, "  \"priority\",\n");
}

test "scaffold: a field that became required is coalesced with a todo" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(), tasks_v1,
        \\{"version":"1.1.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"integer"},
        \\  "assignee":{"type":"string"}
        \\},"required":["title","assignee"]}}}
    );
    try expectContains(text, "--   tasks.assignee  now required  (checked)\n");
    try expectContains(text, "coalesce(\"assignee\", zync_todo('tasks.assignee is now required: value for rows where it is NULL'))");
}

test "scaffold: a namespaced change asks for namespace_id" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"settings":{"fields":{"key":{"type":"string"}}}}}
    ,
        \\{"version":"2.0.0","store":{"settings":{"namespaced":false,"fields":{"key":{"type":"string"}}}}}
    );
    try expectContains(text, "--   settings  namespaced changed  (migration required)\n");
    try expectContains(text, "  zync_todo('settings.namespaced changed: choose namespace_id for each row (0 for tables that are not namespaced)'),\n");
}

test "scaffold: a removed table is a todo with the delete statement" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"notes":{"fields":{"body":{"type":"string"}}},"archive":{"fields":{"body":{"type":"string"}}}}}
    ,
        \\{"version":"2.0.0","store":{"archive":{"fields":{"body":{"type":"string"}}}}}
    );
    try expectContains(text, "--   notes  removed  (migration required)\n");
    try expectContains(text, "SELECT zync_todo('notes was removed. Move rows you need, then drop the rest with: DELETE FROM \"_zync_prev_notes\";');\n");
}

test "scaffold: checked changes on tables that are not rebuilt get hints" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"projects":{"fields":{"slug":{"type":"string"},"title":{"type":"string"}}}}}
    ,
        \\{"version":"1.1.0","store":{"projects":{"fields":{"slug":{"type":"string"},"title":{"type":"string","maxLength":80},"notes":{"type":"string"}},"unique":[["slug"]]}}}
    );
    try expectContains(text, "-- projects: new columns \"notes\" start as NULL; backfill them here if needed.\n");
    try expectContains(text, "-- projects.title: the constraint is stricter;");
    try expectContains(text, "-- UPDATE \"projects\" SET \"title\" = ... WHERE ...;\n");
    try expectContains(text, "-- projects: a unique constraint was added or changed;");
    try expectContains(text, "-- SELECT \"namespace_id\", \"slug\", count(*) FROM \"projects\"\n");
    try expectContains(text, "--   WHERE \"namespace_id\" IS NOT NULL AND \"slug\" IS NOT NULL\n");
    try expectNotContains(text, "DELETE FROM");
    try expectNotContains(text, "zync_todo('");
    try expectNotContains(text, "INSERT INTO");
}

test "scaffold: identical schemas give a data-only scaffold" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(), tasks_v1, tasks_v1);
    try expectContains(text, "--   none (data-only migration)\n");
    try expectContains(text, "-- UPDATE \"<table>\" SET \"<field>\" = ... WHERE ...;\n");
}

test "scaffold: an array items change suggests a per-element conversion" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"posts":{"fields":{"tags":{"type":"array","items":"integer"}}}}}
    ,
        \\{"version":"2.0.0","store":{"posts":{"fields":{"tags":{"type":"array","items":"string"}}}}}
    );
    try expectContains(text, "zync_todo('posts.tags: array of integer -> array of string. Example: CASE WHEN \"tags\" IS NULL THEN NULL ELSE jsonb(zync_array((SELECT json_group_array(CAST(value AS TEXT)) FROM json_each(\"tags\")), ''string'')) END')");
}

test "scaffold: a string to reference change points to expand and contract" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"projects":{"fields":{}},"tasks":{"fields":{"project":{"type":"string"}}}}}
    ,
        \\{"version":"2.0.0","store":{"projects":{"fields":{}},"tasks":{"fields":{"project":{"type":"string","references":"projects"}}}}}
    );
    try expectContains(text, "tasks.project: string -> reference to projects. SQL cannot convert");
    try expectContains(text, "Expand and contract instead");
}

test "scaffold: an array of booleans maps integer items to JSON booleans" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"posts":{"fields":{"flags":{"type":"array","items":"integer"}}}}}
    ,
        \\{"version":"2.0.0","store":{"posts":{"fields":{"flags":{"type":"array","items":"boolean"}}}}}
    );
    try expectContains(text, "CASE WHEN \"flags\" IS NULL THEN NULL ELSE jsonb(zync_array((SELECT json_group_array(CASE WHEN value THEN json(''true'') ELSE json(''false'') END) FROM json_each(\"flags\")), ''boolean'')) END");
}

test "scaffold: bytes to string keeps NULL as NULL" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"files":{"fields":{"data":{"type":"bytes"}}}}}
    ,
        \\{"version":"2.0.0","store":{"files":{"fields":{"data":{"type":"string"}}}}}
    );
    try expectContains(text, "CASE WHEN \"data\" IS NULL THEN NULL ELSE hex(\"data\") END");
}

test "scaffold: a type change that also became required mentions NULL replacements" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = try generate(arena.allocator(),
        \\{"version":"1.0.0","store":{"tasks":{"fields":{"title":{"type":"string"},"count":{"type":"string"}}}}}
    ,
        \\{"version":"2.0.0","store":{"tasks":{"fields":{"title":{"type":"string"},"count":{"type":"integer"}},"required":["count"]}}}
    );
    try expectContains(text, "tasks.count: string -> integer. Example: CAST(\"count\" AS INTEGER) (non-numeric text becomes 0) Rows where it is NULL also need a replacement value.");
}

// ─── Scaffolds through startup ───────────────────────────────────────────────

const Harness = struct {
    tmp: std.testing.TmpDir,
    migrations_dir: []u8,
    db: sqlite.Db,
    diag: Diagnostics,

    fn init() !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const migrations_dir = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "migrations" });
        errdefer allocator.free(migrations_dir);
        var db = try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
        errdefer db.deinit();
        _ = try db.pragma(void, .{}, "foreign_keys", "on");
        try db.exec("CREATE TABLE IF NOT EXISTS _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE) STRICT", .{}, .{});
        return .{ .tmp = tmp, .migrations_dir = migrations_dir, .db = db, .diag = Diagnostics.init(allocator) };
    }

    fn deinit(self: *Harness) void {
        self.diag.deinit();
        self.db.deinit();
        allocator.free(self.migrations_dir);
        self.tmp.cleanup();
    }

    /// Writes a migration folder whose `migration.sql` is the generated scaffold.
    fn writeScaffolded(self: *Harness, before: []const u8, after: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sql = try generate(arena.allocator(), before, after);
        const files = [_]struct { name: []const u8, data: []const u8 }{
            .{ .name = source.before_file, .data = before },
            .{ .name = source.after_file, .data = after },
            .{ .name = source.sql_file, .data = sql },
        };
        for (files) |file| {
            const path = try std.fs.path.join(allocator, &.{ self.migrations_dir, test_id, file.name });
            defer allocator.free(path);
            try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path) orelse return error.TestExpectedValue);
            try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = file.data });
        }
    }

    fn migrate(self: *Harness, json: []const u8) !startup.Report {
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
        }, .{ .migrations = migrations.items }, &self.diag);
    }

    fn migrateOk(self: *Harness, json: []const u8) !startup.Report {
        return self.migrate(json) catch |err| {
            for (self.diag.items()) |line| std.debug.print("{s}\n", .{line});
            return err;
        };
    }

    fn expectDiag(self: *const Harness, needle: []const u8) !void {
        for (self.diag.items()) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) return;
        }
        for (self.diag.items()) |line| std.debug.print("{s}\n", .{line});
        std.debug.print("expected a diagnostic containing: {s}\n", .{needle});
        return error.TestUnexpectedResult;
    }

    fn seedTasks(self: *Harness) !void {
        _ = try self.migrateOk(tasks_v1);
        try self.db.exec(
            "INSERT INTO tasks (id, namespace_id, owner_id, title, priority, assignee, created_at, updated_at) VALUES " ++
                "(randomblob(16), 1, zeroblob(16), 'a', 1, 'ann', 1, 1), (randomblob(16), 1, zeroblob(16), 'b', 2, NULL, 2, 2)",
            .{},
            .{},
        );
    }
};

test "scaffold: a generated rebuild without decisions runs unchanged" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seedTasks();
    // title becomes optional: a rebuild with nothing to decide.
    const after =
        \\{"version":"1.1.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"integer"},
        \\  "assignee":{"type":"string"}
        \\}}}}
    ;
    try h.writeScaffolded(tasks_v1, after);
    var report = try h.migrateOk(after);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), report.migrations_applied);
    try std.testing.expectEqual(@as(?i64, 2), try h.db.one(i64, "SELECT count(*) FROM tasks", .{}, .{}));
    try std.testing.expectEqual(@as(?i64, 1), try h.db.one(i64, "SELECT count(*) FROM tasks WHERE title = 'a' AND priority = 1 AND assignee = 'ann'", .{}, .{}));
}

test "scaffold: a generated scaffold with decisions is rejected until they are made" {
    var h = try Harness.init();
    defer h.deinit();
    try h.seedTasks();
    const after =
        \\{"version":"2.0.0","store":{"tasks":{"fields":{
        \\  "title":{"type":"string"},
        \\  "priority":{"type":"string"}
        \\},"required":["title"]}}}
    ;
    try h.writeScaffolded(tasks_v1, after);
    try std.testing.expectError(error.MigrationSqlRejected, h.migrate(after));
    try h.expectDiag("unresolved decision: tasks.priority: integer -> string. Example: CAST(\"priority\" AS TEXT)");
    try std.testing.expectEqual(@as(?i64, 2), try h.db.one(i64, "SELECT count(*) FROM tasks WHERE priority IN (1, 2)", .{}, .{}));
}
