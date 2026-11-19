const std = @import("std");

const sqlite = @import("sqlite");

const canonical = @import("../schema/canonical.zig");
const schema_parse = @import("../schema/parse.zig");
const typed_codec = @import("../typed/codec.zig");
const catalog = @import("catalog.zig");
const startup = @import("startup.zig");
const validate = @import("validate.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const allocator = std.testing.allocator;

const Harness = struct {
    db: sqlite.Db,
    diag: Diagnostics,

    fn init() !Harness {
        var db = try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
        errdefer db.deinit();
        _ = try db.pragma(void, .{}, "foreign_keys", "on");
        return .{ .db = db, .diag = Diagnostics.init(allocator) };
    }

    fn deinit(self: *Harness) void {
        self.diag.deinit();
        self.db.deinit();
    }

    /// Runs the startup migration to `json`. Diagnostics stay available.
    fn migrate(self: *Harness, json: []const u8) !startup.Report {
        self.diag.deinit();
        self.diag = Diagnostics.init(allocator);
        var schema = try schema_parse.initFromJson(allocator, json);
        defer schema.deinit();
        const identity = try canonical.Identity.init(allocator, json);
        defer identity.deinit(allocator);
        return startup.run(std.testing.io, allocator, &self.db, .{
            .schema = &schema,
            .json = identity.json,
            .hash = identity.hash,
        }, .{}, &self.diag);
    }

    fn exec(self: *Harness, sql: []const u8) !void {
        try self.db.execDynamic(sql, .{}, .{});
    }

    fn count(self: *Harness, sql: []const u8) !i64 {
        return (try self.db.oneDynamic(i64, sql, .{}, .{})) orelse error.TestExpectedValue;
    }

    fn text(self: *Harness, sql: []const u8) ![]const u8 {
        return (try self.db.oneDynamicAlloc([]const u8, allocator, sql, .{}, .{})) orelse error.TestExpectedValue;
    }

    fn appliedHash(self: *Harness) ![]const u8 {
        return self.text("SELECT hash FROM _zync_schema");
    }

    fn diagContains(self: *const Harness, needle: []const u8) bool {
        for (self.diag.items()) |line| {
            if (std.mem.indexOf(u8, line, needle) != null) return true;
        }
        return false;
    }

    /// Fails unless the catalog matches the layout of `json` exactly.
    fn expectLayout(self: *Harness, json: []const u8) !void {
        var schema = try schema_parse.initFromJson(allocator, json);
        defer schema.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var diag = Diagnostics.init(allocator);
        defer diag.deinit();
        for (schema.tables) |*table| {
            const drift = try catalog.checkTable(arena.allocator(), &self.db, table, &diag);
            if (drift.any()) {
                for (diag.items()) |line| std.debug.print("{s}\n", .{line});
                return error.TestUnexpectedResult;
            }
        }
    }

    fn expectPragmasRestored(self: *Harness) !void {
        try std.testing.expectEqual(@as(?i64, 1), try self.db.one(i64, "PRAGMA foreign_keys", .{}, .{}));
        try std.testing.expectEqual(@as(?i64, 0), try self.db.one(i64, "PRAGMA legacy_alter_table", .{}, .{}));
    }
};

/// Inserts a row with fresh system columns plus `columns`/`values` (SQL).
fn insertRow(h: *Harness, table: []const u8, columns: []const u8, values: []const u8) !void {
    const sep = if (columns.len > 0) ", " else "";
    const sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO \"{s}\" (\"id\", \"namespace_id\", \"owner_id\", \"created_at\", \"updated_at\"{s}{s}) " ++
            "SELECT randomblob(16), 1, zeroblob(16), next, next{s}{s} FROM (SELECT coalesce(max(\"created_at\"), 0) + 1 AS next FROM \"{s}\")",
        .{ table, sep, columns, sep, values, table },
    );
    defer allocator.free(sql);
    try h.exec(sql);
}

const v1 =
    \\{"version":"1.0.0","store":{
    \\  "projects":{"fields":{"name":{"type":"string"}}},
    \\  "tasks":{"fields":{
    \\    "title":{"type":"string"},
    \\    "status":{"type":"string","enum":["open","done"]},
    \\    "project_id":{"type":"string","references":"projects"}
    \\  },"required":["title"]}
    \\}}
;

test "startup: fresh database creates STRICT tables, indexes, and the snapshot" {
    var h = try Harness.init();
    defer h.deinit();

    const report = try h.migrate(v1);
    try std.testing.expectEqual(@as(usize, 1), report.steps);
    try h.expectLayout(v1);
    try h.expectPragmasRestored();

    const stored = try h.text("SELECT schema FROM _zync_schema");
    defer allocator.free(stored);
    const minified = try canonical.minify(allocator, v1);
    defer allocator.free(minified);
    try std.testing.expectEqualStrings(minified, stored);
    try std.testing.expectEqual(@as(i64, 0), try h.count("SELECT count(*) FROM _zync_migrations"));
}

test "startup: restarting with the same schema writes nothing" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    try h.exec("UPDATE _zync_schema SET applied_at = 42");

    const report = try h.migrate(v1);
    try std.testing.expectEqual(@as(usize, 0), report.steps);
    try std.testing.expectEqual(@as(i64, 42), try h.count("SELECT applied_at FROM _zync_schema"));
}

test "startup: whitespace-only edits do not change the applied schema" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    const pretty = try canonical.pretty(allocator, v1);
    defer allocator.free(pretty);
    const report = try h.migrate(pretty);
    try std.testing.expectEqual(@as(usize, 0), report.steps);
}

test "startup: a version-only change rewrites the snapshot and nothing else" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(
        \\{"version":"1.0.0","store":{"tasks":{"fields":{"title":{"type":"string"}}}}}
    );
    const report = try h.migrate(
        \\{"version":"1.0.1","store":{"tasks":{"fields":{"title":{"type":"string"}}}}}
    );
    try std.testing.expectEqual(@as(usize, 1), report.steps);
    const version = try h.text("SELECT version FROM _zync_schema");
    defer allocator.free(version);
    try std.testing.expectEqualStrings("1.0.1", version);
}

test "startup: auto changes reach the same layout as a fresh database and keep rows" {
    const steps = [_][]const u8{
        // add optional field and optional reference
        \\{"version":"1.1.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"}}},
        \\  "tasks":{"fields":{
        \\    "title":{"type":"string"},
        \\    "status":{"type":"string","enum":["open","done"]},
        \\    "project_id":{"type":"string","references":"projects"},
        \\    "notes":{"type":"string","indexed":true},
        \\    "parent_id":{"type":"string","references":"tasks","onDelete":"set_null"}
        \\  },"required":["title"]}
        \\}}
        ,
        // required -> optional, onDelete change, enum widened, add table
        \\{"version":"1.2.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"}}},
        \\  "labels":{"fields":{"text":{"type":"string"}}},
        \\  "tasks":{"fields":{
        \\    "title":{"type":"string"},
        \\    "status":{"type":"string","enum":["open","done","archived"]},
        \\    "project_id":{"type":"string","references":"projects","onDelete":"cascade"},
        \\    "notes":{"type":"string"},
        \\    "parent_id":{"type":"string","references":"tasks","onDelete":"set_null"}
        \\  }}
        \\}}
        ,
        // unique over clean data, index flag, field reorder
        \\{"version":"1.3.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string","indexed":true}},"unique":[["name"]]},
        \\  "labels":{"fields":{"text":{"type":"string"}}},
        \\  "tasks":{"fields":{
        \\    "status":{"type":"string","enum":["open","done","archived"]},
        \\    "title":{"type":"string"},
        \\    "project_id":{"type":"string","references":"projects","onDelete":"cascade"},
        \\    "notes":{"type":"string"},
        \\    "parent_id":{"type":"string","references":"tasks","onDelete":"set_null"}
        \\  }}
        \\}}
    };

    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    try insertRow(&h, "projects", "\"name\"", "'alpha'");
    try insertRow(&h, "projects", "\"name\"", "'beta'");
    try h.exec("INSERT INTO tasks (id, namespace_id, owner_id, title, status, project_id, created_at, updated_at) SELECT randomblob(16), 1, zeroblob(16), 'task ' || name, 'open', id, created_at, created_at FROM projects");

    for (steps) |json| {
        const report = h.migrate(json) catch |err| {
            for (h.diag.items()) |line| std.debug.print("{s}\n", .{line});
            return err;
        };
        try std.testing.expectEqual(@as(usize, 1), report.steps);
        try h.expectLayout(json);
        try h.expectPragmasRestored();
        try std.testing.expectEqual(@as(i64, 2), try h.count("SELECT count(*) FROM tasks"));
        try std.testing.expectEqual(@as(i64, 2), try h.count("SELECT count(*) FROM tasks JOIN projects ON projects.id = tasks.project_id WHERE tasks.title = 'task ' || projects.name"));
    }
}

test "startup: a users rebuild keeps external_id" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(
        \\{"version":"1.0.0","store":{"teams":{"fields":{}},"users":{"fields":{"team":{"type":"string","references":"teams"}}}}}
    );
    try h.exec("INSERT INTO users (id, namespace_id, owner_id, external_id, created_at, updated_at) VALUES (zeroblob(16), 0, zeroblob(16), 'auth0|alice', 1, 1)");

    const json =
        \\{"version":"1.1.0","store":{"teams":{"fields":{}},"users":{"fields":{"team":{"type":"string","references":"teams","onDelete":"set_null"}}}}}
    ;
    const report = try h.migrate(json);
    try std.testing.expect(report.rebuilt);
    try h.expectLayout(json);
    const external_id = try h.text("SELECT external_id FROM users");
    defer allocator.free(external_id);
    try std.testing.expectEqualStrings("auth0|alice", external_id);
}

test "startup: migration-required changes are refused and nothing changes" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    const before = try h.appliedHash();
    defer allocator.free(before);

    const removed_field =
        \\{"version":"2.0.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"}}},
        \\  "tasks":{"fields":{"title":{"type":"string"},"project_id":{"type":"string","references":"projects"}},"required":["title"]}
        \\}}
    ;
    try std.testing.expectError(error.MigrationRequired, h.migrate(removed_field));
    try std.testing.expect(h.diagContains("tasks.status"));
    try std.testing.expect(h.diagContains("migrate new"));

    const after = try h.appliedHash();
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try h.expectLayout(v1);
    try h.expectPragmasRestored();
}

test "startup: adding a required field passes on empty tables and fails on populated ones" {
    const with_slug =
        \\{"version":"1.1.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"},"slug":{"type":"string"}},"required":["slug"]},
        \\  "tasks":{"fields":{
        \\    "title":{"type":"string"},
        \\    "status":{"type":"string","enum":["open","done"]},
        \\    "project_id":{"type":"string","references":"projects"}
        \\  },"required":["title"]}
        \\}}
    ;
    {
        var h = try Harness.init();
        defer h.deinit();
        _ = try h.migrate(v1);
        _ = try h.migrate(with_slug);
        try h.expectLayout(with_slug);
    }
    {
        var h = try Harness.init();
        defer h.deinit();
        _ = try h.migrate(v1);
        try insertRow(&h, "projects", "\"name\"", "'alpha'");
        try std.testing.expectError(error.RequiredFieldNeedsValues, h.migrate(with_slug));
        try std.testing.expect(h.diagContains("projects.slug"));
        try h.expectLayout(v1);
        try std.testing.expectEqual(@as(i64, 1), try h.count("SELECT count(*) FROM projects"));
        try h.expectPragmasRestored();
    }
}

test "startup: making a field required fails while NULLs exist" {
    const required_status =
        \\{"version":"1.1.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"}}},
        \\  "tasks":{"fields":{
        \\    "title":{"type":"string"},
        \\    "status":{"type":"string","enum":["open","done"]},
        \\    "project_id":{"type":"string","references":"projects"}
        \\  },"required":["title","status"]}
        \\}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    try insertRow(&h, "tasks", "\"title\"", "'no status'");
    try std.testing.expectError(error.DataValidationFailed, h.migrate(required_status));
    try std.testing.expect(h.diagContains("tasks.status"));

    try h.exec("UPDATE tasks SET status = 'open'");
    _ = try h.migrate(required_status);
    try h.expectLayout(required_status);
}

test "startup: tightened constraints are validated against existing rows" {
    const narrowed =
        \\{"version":"1.1.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"}}},
        \\  "tasks":{"fields":{
        \\    "title":{"type":"string","maxLength":5},
        \\    "status":{"type":"string","enum":["open"]},
        \\    "project_id":{"type":"string","references":"projects"}
        \\  },"required":["title"]}
        \\}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    try insertRow(&h, "tasks", "\"title\", \"status\"", "'too long title', 'done'");
    const before = try h.appliedHash();
    defer allocator.free(before);

    try std.testing.expectError(error.DataValidationFailed, h.migrate(narrowed));
    try std.testing.expect(h.diagContains("tasks.status"));
    try std.testing.expect(h.diagContains("tasks.title"));
    const after = try h.appliedHash();
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    try h.exec("UPDATE tasks SET title = 'short', status = 'open'");
    _ = try h.migrate(narrowed);
}

test "startup: a new unique constraint over duplicates fails with samples" {
    const unique_names =
        \\{"version":"1.1.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"}},"unique":[["name"]]},
        \\  "tasks":{"fields":{
        \\    "title":{"type":"string"},
        \\    "status":{"type":"string","enum":["open","done"]},
        \\    "project_id":{"type":"string","references":"projects"}
        \\  },"required":["title"]}
        \\}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    try insertRow(&h, "projects", "\"name\"", "'dup'");
    try insertRow(&h, "projects", "\"name\"", "'dup'");

    try std.testing.expectError(error.UniqueConstraintViolation, h.migrate(unique_names));
    try std.testing.expect(h.diagContains("'dup'"));
    try h.expectLayout(v1);
    try h.expectPragmasRestored();
}

test "startup: retargeting a reference fails on orphaned rows" {
    const retargeted =
        \\{"version":"1.1.0","store":{
        \\  "projects":{"fields":{"name":{"type":"string"}}},
        \\  "teams":{"fields":{}},
        \\  "tasks":{"fields":{
        \\    "title":{"type":"string"},
        \\    "status":{"type":"string","enum":["open","done"]},
        \\    "project_id":{"type":"string","references":"teams"}
        \\  },"required":["title"]}
        \\}}
    ;
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    try insertRow(&h, "projects", "\"name\"", "'alpha'");
    try h.exec("INSERT INTO tasks (id, namespace_id, owner_id, title, project_id, created_at, updated_at) SELECT randomblob(16), 1, zeroblob(16), 't', id, 100, 100 FROM projects");

    try std.testing.expectError(error.ForeignKeyViolation, h.migrate(retargeted));
    try h.expectLayout(v1);
    try h.expectPragmasRestored();
}

test "startup: version downgrades are refused" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(
        \\{"version":"1.2.0","store":{"t":{"fields":{}}}}
    );
    try std.testing.expectError(error.SchemaVersionDowngrade, h.migrate(
        \\{"version":"1.1.9","store":{"t":{"fields":{"a":{"type":"string"}}}}}
    ));
}

test "startup: structural drift refuses and managed index drift is repaired" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);

    try h.exec("DROP INDEX \"idx__tasks__field__project_id\"");
    try h.exec("CREATE INDEX \"IDX__TASKS__FIELD__PROJECT_ID\" ON tasks(project_id)");
    try h.exec("CREATE INDEX \"IDX__TASKS__OBSOLETE\" ON tasks(title)");
    const report = try h.migrate(v1);
    try std.testing.expectEqual(@as(usize, 1), report.steps);
    try h.expectLayout(v1);

    try h.exec("ALTER TABLE tasks ADD COLUMN sneaky TEXT");
    try std.testing.expectError(error.SchemaDriftDetected, h.migrate(v1));
    try std.testing.expect(h.diagContains("sneaky"));
}

test "startup: a database with tables but no snapshot is unrecognized" {
    var h = try Harness.init();
    defer h.deinit();
    try h.exec("CREATE TABLE legacy (id INTEGER)");
    try std.testing.expectError(error.UnrecognizedDatabase, h.migrate(v1));
    try std.testing.expect(h.diagContains("legacy"));
}

test "startup: an unknown layout is refused" {
    var h = try Harness.init();
    defer h.deinit();
    _ = try h.migrate(v1);
    try h.exec("UPDATE _zync_schema SET layout = 99");
    try std.testing.expectError(error.UnsupportedLayout, h.migrate(v1));
}

test "validate: arrays must use the runtime encoding and booleans must be 0 or 1" {
    var h = try Harness.init();
    defer h.deinit();
    const json =
        \\{"version":"1.0.0","store":{"items":{"fields":{"tags":{"type":"array","items":"string"},"nums":{"type":"array","items":"number"},"ok":{"type":"boolean"}}}}}
    ;
    _ = try h.migrate(json);

    // The runtime write path: jsonb(<codec JSON>).
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[\"b\",\"a\",\"b\"]", .{});
    defer parsed.deinit();
    const value = try typed_codec.fromJson(allocator, .array, .text, parsed.value);
    defer value.deinit(allocator);
    try typed_codec.writeJsonToBuf(&buf, allocator, value);
    var nums_buf = std.ArrayListUnmanaged(u8).empty;
    defer nums_buf.deinit(allocator);
    var nums_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[2.5,1]", .{});
    defer nums_parsed.deinit();
    const nums = try typed_codec.fromJson(allocator, .array, .real, nums_parsed.value);
    defer nums.deinit(allocator);
    try typed_codec.writeJsonToBuf(&nums_buf, allocator, nums);

    const good = try std.fmt.allocPrint(allocator, "jsonb('{s}'), jsonb('{s}'), 1", .{ buf.items, nums_buf.items });
    defer allocator.free(good);
    try insertRow(&h, "items", "\"tags\", \"nums\", \"ok\"", good);

    var schema = try schema_parse.initFromJson(allocator, json);
    defer schema.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const items = schema.table("items") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(u64, 0), try validate.validateTable(arena.allocator(), &h.db, items, null, &diag));

    try insertRow(&h, "items", "\"tags\", \"nums\", \"ok\"", "jsonb('[\"b\",\"a\"]'), jsonb('[1]'), 2");
    try std.testing.expectEqual(@as(u64, 3), try validate.validateTable(arena.allocator(), &h.db, items, null, &diag));
    var saw_canonical = false;
    var saw_boolean = false;
    for (diag.items()) |line| {
        if (std.mem.indexOf(u8, line, "canonical") != null) saw_canonical = true;
        if (std.mem.indexOf(u8, line, "0 or 1") != null) saw_boolean = true;
    }
    try std.testing.expect(saw_canonical and saw_boolean);
}

test "validate: malformed array JSON is a row violation, not a statement error" {
    var h = try Harness.init();
    defer h.deinit();
    const json =
        \\{"version":"1.0.0","store":{"items":{"fields":{"tags":{"type":"array","items":"string"}}}}}
    ;
    _ = try h.migrate(json);
    try insertRow(&h, "items", "\"tags\"", "CAST('not json' AS BLOB)");
    try insertRow(&h, "items", "\"tags\"", "jsonb('5')");

    var schema = try schema_parse.initFromJson(allocator, json);
    defer schema.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const items = schema.table("items") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(u64, 2), try validate.validateTable(arena.allocator(), &h.db, items, null, &diag));

    var saw_invalid = false;
    var saw_not_array = false;
    for (diag.items()) |line| {
        if (std.mem.indexOf(u8, line, "not valid JSON") != null) saw_invalid = true;
        if (std.mem.indexOf(u8, line, "not a JSON array") != null) saw_not_array = true;
    }
    try std.testing.expect(saw_invalid and saw_not_array);
}

test "validate: unconstrained reals are scanned for non-finite values" {
    var h = try Harness.init();
    defer h.deinit();
    const json =
        \\{"version":"1.0.0","store":{"items":{"fields":{"ratio":{"type":"number"}}}}}
    ;
    _ = try h.migrate(json);
    try insertRow(&h, "items", "\"ratio\"", "1e999");

    var schema = try schema_parse.initFromJson(allocator, json);
    defer schema.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    const items = schema.table("items") orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(u64, 1), try validate.validateTable(arena.allocator(), &h.db, items, null, &diag));
}

test "validate: constraint violations are counted per field" {
    var h = try Harness.init();
    defer h.deinit();
    const json =
        \\{"version":"1.0.0","store":{"items":{"fields":{"code":{"type":"string","pattern":"^[A-Z]+$"},"qty":{"type":"integer","minimum":1},"ratio":{"type":"number","maximum":1}}}}}
    ;
    _ = try h.migrate(json);
    try insertRow(&h, "items", "\"code\", \"qty\", \"ratio\"", "'OK', 3, 0.5");
    try insertRow(&h, "items", "\"code\", \"qty\", \"ratio\"", "'bad', 0, 1.5");

    var schema = try schema_parse.initFromJson(allocator, json);
    defer schema.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    try std.testing.expectEqual(@as(u64, 3), try validate.validateTable(arena.allocator(), &h.db, schema.table("items").?, null, &diag));
    try std.testing.expectEqual(@as(u64, 1), try validate.validateTable(arena.allocator(), &h.db, schema.table("items").?, &.{"qty"}, &diag));
}
