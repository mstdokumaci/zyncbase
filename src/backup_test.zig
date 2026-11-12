const std = @import("std");

const sqlite = @import("sqlite");

const backup = @import("backup.zig");

fn openDb(allocator: std.mem.Allocator, path: []const u8) !sqlite.Db {
    // zwanzig-disable-next-line: sentinel-alloc
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{ .write = true, .create = true },
    });
}

test "backup: snapshot while live, verify, and restore" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const data_dir = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_dir);

    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ root, "snapshot.db" });
    defer allocator.free(snapshot_path);

    var snapshot: backup.CreateInfo = undefined;
    {
        var live = try openDb(allocator, db_path);
        defer live.deinit();

        try live.exec("CREATE TABLE _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)", .{}, .{});
        try live.exec("CREATE TABLE tasks (id INTEGER PRIMARY KEY, name TEXT)", .{}, .{});
        try live.exec("INSERT INTO tasks (id, name) VALUES (1, 'before')", .{}, .{});

        snapshot = try backup.create(std.testing.io, allocator, db_path, snapshot_path);
        try std.testing.expect(snapshot.bytes > 0);

        try backup.verify(std.testing.io, allocator, snapshot_path, true);

        try live.exec("INSERT INTO tasks (id, name) VALUES (2, 'after')", .{}, .{});
    }

    var restored = try backup.restore(std.testing.io, allocator, data_dir, snapshot_path, true);
    defer restored.deinit(allocator);
    try std.testing.expect(restored.safety_copy != null);

    var db = try openDb(allocator, db_path);
    defer db.deinit();

    const before = try db.oneAlloc([]const u8, allocator, "SELECT name FROM tasks WHERE id = 1", .{}, .{});
    defer if (before) |name| allocator.free(name);
    try std.testing.expectEqualStrings("before", before.?);

    const after = try db.oneAlloc([]const u8, allocator, "SELECT name FROM tasks WHERE id = 2", .{}, .{});
    defer if (after) |name| allocator.free(name);
    try std.testing.expect(after == null);
}

test "backup: interrupted restore rolls back before storage opens" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const data_dir = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_dir);

    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    {
        var old = try openDb(allocator, db_path);
        defer old.deinit();
        try old.exec("CREATE TABLE _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)", .{}, .{});
        try old.exec("CREATE TABLE tasks (id INTEGER PRIMARY KEY, name TEXT)", .{}, .{});
        try old.exec("INSERT INTO tasks (id, name) VALUES (1, 'old')", .{}, .{});
    }

    const timestamp = std.Io.Clock.real.now(std.testing.io).toNanoseconds();
    var safety_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const safety_db = try std.fmt.bufPrint(&safety_buf, "{s}.pre-restore-{d}", .{ db_path, timestamp });
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(db_path, cwd, safety_db, std.testing.io);

    // Simulate a replacement that completed but was never committed.
    {
        var replacement = try openDb(allocator, db_path);
        defer replacement.deinit();
        try replacement.exec("CREATE TABLE _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)", .{}, .{});
        try replacement.exec("CREATE TABLE tasks (id INTEGER PRIMARY KEY, name TEXT)", .{}, .{});
        try replacement.exec("INSERT INTO tasks (id, name) VALUES (1, 'new')", .{}, .{});
    }

    const journal_path = try std.fmt.allocPrint(allocator, "{s}.restore-journal", .{db_path});
    defer allocator.free(journal_path);
    const journal = try std.fmt.allocPrint(
        allocator,
        "zyncbase-restore-v1\n{d}\n",
        .{timestamp},
    );
    defer allocator.free(journal);
    try cwd.writeFile(std.testing.io, .{ .sub_path = journal_path, .data = journal });

    try backup.recoverInterruptedRestore(std.testing.io, allocator, data_dir);

    try std.testing.expectError(
        error.FileNotFound,
        cwd.access(std.testing.io, journal_path, .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        cwd.access(std.testing.io, safety_db, .{}),
    );

    var rolled_back = try openDb(allocator, db_path);
    defer rolled_back.deinit();
    const name = try rolled_back.oneAlloc([]const u8, allocator, "SELECT name FROM tasks WHERE id = 1", .{}, .{});
    defer if (name) |value| allocator.free(value);
    try std.testing.expectEqualStrings("old", name.?);
}

test "backup: corrupt journal is cleared when the database still exists" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const data_dir = try std.fs.path.join(allocator, &.{ root, "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, data_dir);

    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    {
        var db = try openDb(allocator, db_path);
        defer db.deinit();
        try db.exec("CREATE TABLE _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)", .{}, .{});
    }

    const journal_path = try std.fmt.allocPrint(allocator, "{s}.restore-journal", .{db_path});
    defer allocator.free(journal_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = journal_path,
        .data = "zyncbase-restore-v1\nnot-a-timestamp\n",
    });

    try backup.recoverInterruptedRestore(std.testing.io, allocator, data_dir);

    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, journal_path, .{}),
    );

    var db = try openDb(allocator, db_path);
    defer db.deinit();
    const marker = try db.one(
        i64,
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='_zync_namespaces'",
        .{},
        .{},
    );
    try std.testing.expectEqual(@as(?i64, 1), marker);
}
