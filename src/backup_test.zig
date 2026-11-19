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

test "backup: UTC timestamps are fixed-width YYYYMMDDTHHMMSSZ" {
    var buf: [backup.utc_timestamp_len]u8 = undefined;
    try std.testing.expectEqualStrings("19700101T000000Z", backup.formatUtcTimestamp(0, &buf));
    // 2026-11-17T14:05:09Z
    try std.testing.expectEqualStrings("20261117T140509Z", backup.formatUtcTimestamp(1794924309, &buf));
    // Leap day.
    try std.testing.expectEqualStrings("20240229T235959Z", backup.formatUtcTimestamp(1709251199, &buf));
}

fn tmpDataDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const data_dir = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "data" });
    std.Io.Dir.cwd().createDirPath(std.testing.io, data_dir) catch |err| {
        allocator.free(data_dir);
        return err;
    };
    return data_dir;
}

fn writeResetJournalForTest(allocator: std.mem.Allocator, db_path: []const u8, stamp: []const u8, keep_safety_copy: bool) !void {
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.reset-journal", .{db_path});
    defer allocator.free(journal_path);
    const contents = try std.fmt.allocPrint(
        allocator,
        "zyncbase-reset-v1\n{s}\n{d}\n",
        .{ stamp, @intFromBool(keep_safety_copy) },
    );
    defer allocator.free(contents);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = journal_path, .data = contents });
}

test "backup: reset completes an interrupted keep move" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);
    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    {
        var db = try openDb(allocator, db_path);
        defer db.deinit();
        try db.exec("CREATE TABLE t (k INTEGER)", .{}, .{});
    }
    const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
    defer allocator.free(wal_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = wal_path, .data = "pending" });

    var stamp_buf: [backup.utc_timestamp_len]u8 = undefined;
    const stamp = backup.utcTimestamp(std.testing.io, &stamp_buf);
    const aside = try std.fmt.allocPrint(allocator, "{s}.pre-reset-{s}", .{ db_path, stamp });
    defer allocator.free(aside);
    const aside_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{aside});
    defer allocator.free(aside_wal);
    try writeResetJournalForTest(allocator, db_path, stamp, true);

    // Crash after moving the database but before its WAL.
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(db_path, cwd, aside, std.testing.io);

    var info = try backup.reset(std.testing.io, allocator, data_dir, true);
    defer info.deinit(allocator);
    try std.testing.expectEqual(backup.ResetOutcome.moved, info.outcome);
    const moved = info.moved_to orelse return error.TestExpectedValue;
    try std.testing.expectEqualStrings(aside, moved);
    try cwd.access(std.testing.io, aside, .{});
    try cwd.access(std.testing.io, aside_wal, .{});
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, wal_path, .{}));
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.reset-journal", .{db_path});
    defer allocator.free(journal_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, journal_path, .{}));

    // The completed reset is not repeated.
    var again = try backup.reset(std.testing.io, allocator, data_dir, true);
    defer again.deinit(allocator);
    try std.testing.expectEqual(backup.ResetOutcome.absent, again.outcome);
}

test "backup: reset rolls back an interrupted partial move" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);
    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    {
        var db = try openDb(allocator, db_path);
        defer db.deinit();
        try db.exec("CREATE TABLE t (k INTEGER)", .{}, .{});
    }
    const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
    defer allocator.free(wal_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = wal_path, .data = "pending" });

    var stamp_buf: [backup.utc_timestamp_len]u8 = undefined;
    const stamp = backup.utcTimestamp(std.testing.io, &stamp_buf);
    const aside = try std.fmt.allocPrint(allocator, "{s}.pre-reset-{s}", .{ db_path, stamp });
    defer allocator.free(aside);
    const aside_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{aside});
    defer allocator.free(aside_wal);
    try writeResetJournalForTest(allocator, db_path, stamp, true);

    // Crash after moving a sidecar but before the database.
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(wal_path, cwd, aside_wal, std.testing.io);

    var info = try backup.reset(std.testing.io, allocator, data_dir, true);
    defer info.deinit(allocator);
    try std.testing.expectEqual(backup.ResetOutcome.moved, info.outcome);
    const moved = info.moved_to orelse return error.TestExpectedValue;
    const moved_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{moved});
    defer allocator.free(moved_wal);
    try cwd.access(std.testing.io, moved, .{});
    try cwd.access(std.testing.io, moved_wal, .{});
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.reset-journal", .{db_path});
    defer allocator.free(journal_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, journal_path, .{}));
}

test "backup: reset recovery finishes a no-safety deletion" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);
    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    {
        var db = try openDb(allocator, db_path);
        defer db.deinit();
        try db.exec("CREATE TABLE t (k INTEGER)", .{}, .{});
    }

    var stamp_buf: [backup.utc_timestamp_len]u8 = undefined;
    const stamp = backup.utcTimestamp(std.testing.io, &stamp_buf);
    const aside = try std.fmt.allocPrint(allocator, "{s}.pre-reset-{s}", .{ db_path, stamp });
    defer allocator.free(aside);
    try writeResetJournalForTest(allocator, db_path, stamp, false);

    // Crash after the move, before deleting the safety copy.
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(db_path, cwd, aside, std.testing.io);

    const recovered = (try backup.recoverInterruptedReset(std.testing.io, allocator, data_dir)) orelse return error.TestExpectedValue;
    var info = recovered;
    defer info.deinit(allocator);
    try std.testing.expectEqual(backup.ResetOutcome.deleted, info.outcome);
    try std.testing.expect(info.moved_to == null);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, aside, .{}));
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.reset-journal", .{db_path});
    defer allocator.free(journal_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, journal_path, .{}));
}

test "backup: reset recovery finishes a partial no-safety deletion" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);
    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);

    {
        var db = try openDb(allocator, db_path);
        defer db.deinit();
        try db.exec("CREATE TABLE t (k INTEGER)", .{}, .{});
    }

    var stamp_buf: [backup.utc_timestamp_len]u8 = undefined;
    const stamp = backup.utcTimestamp(std.testing.io, &stamp_buf);
    const aside = try std.fmt.allocPrint(allocator, "{s}.pre-reset-{s}", .{ db_path, stamp });
    defer allocator.free(aside);
    const aside_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{aside});
    defer allocator.free(aside_wal);
    try writeResetJournalForTest(allocator, db_path, stamp, false);

    // Crash after deleting the database copy but before its WAL.
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(db_path, cwd, aside, std.testing.io);
    try cwd.writeFile(std.testing.io, .{ .sub_path = aside_wal, .data = "pending" });
    try cwd.deleteFile(std.testing.io, aside);

    _ = try backup.recoverInterruptedReset(std.testing.io, allocator, data_dir);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, aside_wal, .{}));
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.reset-journal", .{db_path});
    defer allocator.free(journal_path);
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, journal_path, .{}));
}

test "backup: reset moves the database aside and the next open is fresh" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);
    {
        var db = try openDb(allocator, db_path);
        defer db.deinit();
        try db.exec("CREATE TABLE t (k INTEGER)", .{}, .{});
    }

    var info = try backup.reset(std.testing.io, allocator, data_dir, true);
    defer info.deinit(allocator);
    try std.testing.expectEqual(backup.ResetOutcome.moved, info.outcome);
    const moved = info.moved_to orelse return error.TestExpectedValue;
    try std.testing.expect(std.mem.indexOf(u8, moved, ".pre-reset-") != null);
    try std.Io.Dir.cwd().access(std.testing.io, moved, .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, db_path, .{}));
    // Free the name so the same-second deleted reset can reuse the timestamp.
    try std.Io.Dir.cwd().deleteTree(std.testing.io, moved);

    // Nothing to reset the second time.
    var again = try backup.reset(std.testing.io, allocator, data_dir, true);
    defer again.deinit(allocator);
    try std.testing.expectEqual(backup.ResetOutcome.absent, again.outcome);
    try std.testing.expect(again.moved_to == null);

    // A fresh database deleted without a safety copy reports `deleted`.
    {
        var db = try openDb(allocator, db_path);
        defer db.deinit();
        try db.exec("CREATE TABLE t (k INTEGER)", .{}, .{});
    }
    var deleted = try backup.reset(std.testing.io, allocator, data_dir, false);
    defer deleted.deinit(allocator);
    try std.testing.expectEqual(backup.ResetOutcome.deleted, deleted.outcome);
    try std.testing.expect(deleted.moved_to == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, db_path, .{}));
}

test "backup: snapshotHeld writes a verified pre-migration snapshot" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    const db_path = try backup.dbPath(allocator, data_dir);
    defer allocator.free(db_path);
    var db = try openDb(allocator, db_path);
    defer db.deinit();
    try db.exec("CREATE TABLE _zync_namespaces (id INTEGER PRIMARY KEY, name TEXT UNIQUE)", .{}, .{});
    try db.exec("INSERT INTO _zync_namespaces VALUES (0, '$global')", .{}, .{});

    const path = try backup.snapshotHeld(std.testing.io, allocator, &db, db_path, "20261117T140500Z_demo");
    defer allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "zyncbase.db.pre-migration-20261117T140500Z_demo-") != null);
    try backup.verify(std.testing.io, allocator, path, true);

    // A second snapshot in the same second gets a suffix instead of failing.
    const again = try backup.snapshotHeld(std.testing.io, allocator, &db, db_path, "20261117T140500Z_demo");
    defer allocator.free(again);
    try std.testing.expect(!std.mem.eql(u8, path, again));
    try backup.verify(std.testing.io, allocator, again, true);
}
