//! Pins the bundled SQLite behaviors that STRICT tables and the schema
//! migration design rely on (see specs/implementation/schema-migrations.md).

const std = @import("std");

const sqlite = @import("sqlite");

const c = sqlite.c;

fn openDb() !sqlite.Db {
    return sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
}

/// Runs one or more statements and returns the extended result code.
fn exec(db: *sqlite.Db, sql: [:0]const u8) c_int {
    const rc = c.sqlite3_exec(db.db, sql.ptr, null, null, null);
    if (rc == c.SQLITE_OK) return rc;
    return c.sqlite3_extended_errcode(db.db);
}

fn expectOk(db: *sqlite.Db, sql: [:0]const u8) !void {
    const rc = exec(db, sql);
    if (rc != c.SQLITE_OK) {
        std.debug.print("unexpected SQLite error {d}: {s}\n  sql: {s}\n", .{ rc, c.sqlite3_errmsg(db.db), sql });
        return error.TestUnexpectedResult;
    }
}

fn queryText(db: *sqlite.Db, allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    return (try db.oneDynamicAlloc([]const u8, allocator, sql, .{}, .{})) orelse error.TestExpectedValue;
}

test "sqlite contract: bundled version supports STRICT tables" {
    try std.testing.expect(c.SQLITE_VERSION_NUMBER >= 3037000);
}

test "sqlite contract: STRICT rejects lossy or cross-class values" {
    var db = try openDb();
    defer db.deinit();
    try expectOk(&db, "CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB CHECK(length(b) = 16)) STRICT");

    const rejected = [_][:0]const u8{
        "INSERT INTO t(i) VALUES (3.5)",
        "INSERT INTO t(i) VALUES ('open')",
        "INSERT INTO t(i) VALUES (x'01')",
        "INSERT INTO t(i) VALUES (jsonb('[1]'))",
        "INSERT INTO t(s) VALUES (x'00')",
        "INSERT INTO t(b) VALUES ('0123456789abcdef')",
        "INSERT INTO t(b) VALUES (1234567890123456)",
    };
    for (rejected) |sql| {
        try std.testing.expectEqual(@as(c_int, c.SQLITE_CONSTRAINT_DATATYPE), exec(&db, sql));
    }
    try std.testing.expectEqual(@as(c_int, c.SQLITE_CONSTRAINT_CHECK), exec(&db, "INSERT INTO t(b) VALUES (jsonb('[1,2]'))"));
    try expectOk(&db, "INSERT INTO t(b) VALUES (randomblob(16))");
}

test "sqlite contract: STRICT silently converts these values" {
    const allocator = std.testing.allocator;
    var db = try openDb();
    defer db.deinit();
    try expectOk(&db, "CREATE TABLE t (k INTEGER PRIMARY KEY, i INTEGER, r REAL, s TEXT) STRICT");
    try expectOk(&db,
        \\INSERT INTO t(k, i) VALUES (1, '123');
        \\INSERT INTO t(k, i) VALUES (2, 3.0);
        \\INSERT INTO t(k, r) VALUES (3, 5);
        \\INSERT INTO t(k, s) VALUES (4, 42);
        \\INSERT INTO t(k, r) VALUES (5, 9007199254740993);
    );

    const cases = [_]struct { sql: []const u8, expected: []const u8 }{
        .{ .sql = "SELECT typeof(i) || ':' || i FROM t WHERE k = 1", .expected = "integer:123" },
        .{ .sql = "SELECT typeof(i) || ':' || i FROM t WHERE k = 2", .expected = "integer:3" },
        .{ .sql = "SELECT typeof(r) || ':' || r FROM t WHERE k = 3", .expected = "real:5.0" },
        .{ .sql = "SELECT typeof(s) || ':' || s FROM t WHERE k = 4", .expected = "text:42" },
        // Integers above 2^53 lose precision in REAL: why integer -> number needs a migration.
        .{ .sql = "SELECT typeof(r) || ':' || printf('%.1f', r) FROM t WHERE k = 5", .expected = "real:9007199254740992.0" },
    };
    for (cases) |case| {
        const text = try queryText(&db, allocator, case.sql);
        defer allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "sqlite contract: ADD COLUMN accepts CHECK and REFERENCES but not NOT NULL without default" {
    const allocator = std.testing.allocator;
    var db = try openDb();
    defer db.deinit();
    try expectOk(&db,
        \\PRAGMA foreign_keys = ON;
        \\CREATE TABLE p (id BLOB NOT NULL, PRIMARY KEY (id)) STRICT;
        \\CREATE TABLE t (id BLOB NOT NULL, PRIMARY KEY (id)) STRICT;
        \\INSERT INTO t VALUES (randomblob(16));
        \\ALTER TABLE t ADD COLUMN "ref" BLOB CHECK(length("ref") = 16) REFERENCES "p"("id") ON DELETE SET NULL;
    );
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ERROR), exec(&db, "ALTER TABLE t ADD COLUMN \"req\" TEXT NOT NULL"));

    const fk = try queryText(&db, allocator, "SELECT \"table\" || '.' || \"to\" || ':' || on_delete FROM pragma_foreign_key_list('t')");
    defer allocator.free(fk);
    try std.testing.expectEqualStrings("p.id:SET NULL", fk);
}

test "sqlite contract: rename with legacy_alter_table keeps child foreign keys and moves the PK autoindex" {
    const allocator = std.testing.allocator;
    var db = try openDb();
    defer db.deinit();
    try expectOk(&db,
        \\CREATE TABLE p (id BLOB NOT NULL, v TEXT, PRIMARY KEY (id)) STRICT;
        \\CREATE INDEX "idx__p__field__v" ON p(v);
        \\CREATE TABLE ch (id BLOB NOT NULL, pid BLOB, PRIMARY KEY (id), FOREIGN KEY (pid) REFERENCES "p"("id")) STRICT;
        \\PRAGMA foreign_keys = OFF;
        \\PRAGMA legacy_alter_table = ON;
        \\BEGIN;
        \\ALTER TABLE p RENAME TO _zync_prev_p;
    );

    const child_sql = try queryText(&db, allocator, "SELECT sql FROM sqlite_schema WHERE name = 'ch'");
    defer allocator.free(child_sql);
    try std.testing.expect(std.mem.indexOf(u8, child_sql, "REFERENCES \"p\"(\"id\")") != null);

    const autoindex_owner = try queryText(&db, allocator, "SELECT tbl_name FROM sqlite_schema WHERE name = 'sqlite_autoindex__zync_prev_p_1'");
    defer allocator.free(autoindex_owner);
    try std.testing.expectEqualStrings("_zync_prev_p", autoindex_owner);

    // Managed indexes keep their names and must be dropped before recreation.
    const managed_owner = try queryText(&db, allocator, "SELECT tbl_name FROM sqlite_schema WHERE name = 'idx__p__field__v'");
    defer allocator.free(managed_owner);
    try std.testing.expectEqualStrings("_zync_prev_p", managed_owner);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ERROR), exec(&db, "CREATE INDEX \"idx__p__field__v\" ON _zync_prev_p(v)"));

    try expectOk(&db,
        \\DROP INDEX "idx__p__field__v";
        \\CREATE TABLE p (id BLOB NOT NULL, v TEXT, PRIMARY KEY (id)) STRICT;
        \\CREATE INDEX "idx__p__field__v" ON p(v);
        \\DROP TABLE _zync_prev_p;
        \\COMMIT;
        \\PRAGMA legacy_alter_table = OFF;
    );
}

test "sqlite contract: rename without legacy_alter_table rewrites child foreign keys" {
    const allocator = std.testing.allocator;
    var db = try openDb();
    defer db.deinit();
    try expectOk(&db,
        \\CREATE TABLE p (id BLOB NOT NULL, PRIMARY KEY (id)) STRICT;
        \\CREATE TABLE ch (id BLOB NOT NULL, pid BLOB, PRIMARY KEY (id), FOREIGN KEY (pid) REFERENCES "p"("id")) STRICT;
        \\PRAGMA foreign_keys = OFF;
        \\ALTER TABLE p RENAME TO _zync_prev_p;
    );
    const child_sql = try queryText(&db, allocator, "SELECT sql FROM sqlite_schema WHERE name = 'ch'");
    defer allocator.free(child_sql);
    try std.testing.expect(std.mem.indexOf(u8, child_sql, "_zync_prev_p") != null);
}

test "sqlite contract: table_list reports STRICT and pragmas hold outside transactions" {
    const allocator = std.testing.allocator;
    var db = try openDb();
    defer db.deinit();
    try expectOk(&db, "CREATE TABLE s (k INTEGER) STRICT; CREATE TABLE n (k INTEGER)");

    const strict = try queryText(&db, allocator, "SELECT group_concat(name || '=' || strict, ',') FROM (SELECT name, strict FROM pragma_table_list WHERE name IN ('n', 's') ORDER BY name)");
    defer allocator.free(strict);
    try std.testing.expectEqualStrings("n=0,s=1", strict);

    // foreign_keys is a no-op inside a transaction, so runs set it before BEGIN.
    try expectOk(&db, "PRAGMA foreign_keys = ON; BEGIN; PRAGMA foreign_keys = OFF;");
    try std.testing.expectEqual(@as(?i64, 1), try db.one(i64, "PRAGMA foreign_keys", .{}, .{}));
    try expectOk(&db, "COMMIT");
}

test "sqlite contract: coalesce does not evaluate later arguments" {
    var db = try openDb();
    defer db.deinit();
    // abs(min int64) raises an integer overflow when evaluated.
    try expectOk(&db, "SELECT coalesce(1, abs(-9223372036854775808))");
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ERROR), exec(&db, "SELECT coalesce(NULL, abs(-9223372036854775808))"));
}

test "sqlite contract: json_valid accepts JSON text and strict JSONB with flag 9" {
    var db = try openDb();
    defer db.deinit();

    // 9 = JSON text (1) + strictly well-formed JSONB (8). Flag 4 is superficial.
    const cases = [_]struct { sql: []const u8, expected: i64 }{
        .{ .sql = "SELECT json_valid('[1]', 9)", .expected = 1 },
        .{ .sql = "SELECT json_valid(CAST('[1]' AS BLOB), 9)", .expected = 1 },
        .{ .sql = "SELECT json_valid(jsonb('[1]'), 9)", .expected = 1 },
        .{ .sql = "SELECT json_valid('not json', 9)", .expected = 0 },
        // CASE evaluates only the chosen branch, so invalid JSON becomes NULL.
        .{ .sql = "SELECT CASE WHEN json_valid(CAST('not json' AS BLOB), 9) THEN json(CAST('not json' AS BLOB)) END IS NULL", .expected = 1 },
    };
    for (cases) |case| {
        const value = (try db.oneDynamic(i64, case.sql, .{}, .{})) orelse return error.TestExpectedValue;
        try std.testing.expectEqual(case.expected, value);
    }
}
