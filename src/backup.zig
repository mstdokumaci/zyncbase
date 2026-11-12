const std = @import("std");

const sqlite = @import("sqlite");

const DataLock = @import("data_lock.zig").DataLock;

pub const db_file_name = "zyncbase.db";

pub const CreateInfo = struct {
    bytes: u64,
    duration_ms: i64,
};

pub const RestoreInfo = struct {
    /// Previous database kept for rollback when `--no-safety-copy` was not set.
    /// Owned by the caller.
    safety_copy: ?[]u8,

    pub fn deinit(self: *RestoreInfo, allocator: std.mem.Allocator) void {
        if (self.safety_copy) |path| allocator.free(path);
        self.safety_copy = null;
    }
};

const SafetyCopy = struct {
    db: []const u8,
    wal: []const u8,
    shm: []const u8,
};

const restore_journal_header = "zyncbase-restore-v1\n";

pub fn dbPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ data_dir, db_file_name });
}

/// Write a consistent snapshot of a live (or stopped) database.
///
/// `VACUUM INTO` runs in a read transaction, so it sees a snapshot that
/// includes committed WAL frames while writers continue. The output is a
/// compact, single-file SQLite database.
pub fn create(
    io: std.Io,
    allocator: std.mem.Allocator,
    db_path: []const u8,
    out_path: []const u8,
) !CreateInfo {
    if (!try fileExists(io, db_path)) return error.DatabaseNotFound;
    if (try fileExists(io, out_path)) return error.OutputExists;

    const data_dir = std.fs.path.dirname(db_path) orelse ".";
    var lock = try DataLock.acquireShared(io, allocator, data_dir);
    defer lock.release(io);

    if (try restoreJournalExists(io, allocator, db_path)) return error.RestoreInProgress;

    const partial_path = try std.fmt.allocPrint(
        allocator,
        "{s}.partial-{d}",
        .{ out_path, std.Io.Clock.real.now(io).toNanoseconds() },
    );
    defer allocator.free(partial_path);
    errdefer deleteQuietly(io, partial_path);

    // zwanzig-disable-next-line: sentinel-alloc
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = db_path_z },
        // Read-write so SQLite can recover a hot WAL after a crash.
        .open_flags = .{ .write = true, .create = false },
    });
    defer db.deinit();

    _ = try db.pragma(void, .{}, "busy_timeout", "5000");

    const started_at = std.Io.Clock.real.now(io).toMilliseconds();
    try db.execDynamic("VACUUM INTO ?", .{}, .{partial_path});

    try verifyFile(io, allocator, partial_path, false);
    try syncFile(io, partial_path);

    if (try fileExists(io, out_path)) return error.OutputExists;
    const cwd = std.Io.Dir.cwd();
    cwd.renamePreserve(partial_path, cwd, out_path, io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.OutputExists,
        else => return err,
    };
    try syncParentDir(io, out_path);

    const stat = try cwd.statFile(io, out_path, .{});
    return .{
        .bytes = stat.size,
        .duration_ms = std.Io.Clock.real.now(io).toMilliseconds() - started_at,
    };
}

/// Validate a snapshot. `full` runs `PRAGMA integrity_check`; otherwise
/// `PRAGMA quick_check`.
pub fn verify(
    io: std.Io,
    allocator: std.mem.Allocator,
    backup_path: []const u8,
    full: bool,
) !void {
    try verifyFile(io, allocator, backup_path, full);
}

/// Replace the database in `data_dir` with `backup_path`.
///
/// Requires exclusive access to the data directory, so the server and any
/// running backups must be stopped. The current database (and its WAL/SHM) is
/// moved aside first and restored on failure or interruption.
pub fn restore(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    backup_path: []const u8,
    keep_safety_copy: bool,
) !RestoreInfo {
    var lock = try DataLock.acquire(io, allocator, data_dir);
    defer lock.release(io);

    try recoverInterruptedRestore(io, allocator, data_dir);

    try verifyFile(io, allocator, backup_path, true);
    try rejectWalSidecar(io, allocator, backup_path);

    const cwd = std.Io.Dir.cwd();
    const db_path = try dbPath(allocator, data_dir);
    defer allocator.free(db_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.restore-tmp", .{db_path});
    defer allocator.free(tmp_path);
    const tmp_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{tmp_path});
    defer allocator.free(tmp_wal);
    const tmp_shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{tmp_path});
    defer allocator.free(tmp_shm);
    const db_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
    defer allocator.free(db_wal);
    const db_shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{db_path});
    defer allocator.free(db_shm);

    errdefer {
        deleteQuietly(io, tmp_path);
        deleteQuietly(io, tmp_wal);
        deleteQuietly(io, tmp_shm);
    }

    try cwd.copyFile(backup_path, cwd, tmp_path, io, .{ .replace = true });
    try syncFile(io, tmp_path);
    try verifyFile(io, allocator, tmp_path, true);
    // The staged database is standalone; verification may have created sidecars.
    deleteQuietly(io, tmp_wal);
    deleteQuietly(io, tmp_shm);

    const had_db = try fileExists(io, db_path);
    var safety_db_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety_wal_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety_shm_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety: ?SafetyCopy = null;
    var journal_started = false;
    var owned_safety: ?[]u8 = null;
    errdefer if (owned_safety) |path| allocator.free(path);
    errdefer if (journal_started) recoverInterruptedRestore(io, allocator, data_dir) catch |err| {
        std.log.err("restore rollback failed: {}", .{err});
    };

    if (had_db) {
        const timestamp = std.Io.Clock.real.now(io).toNanoseconds();
        const copy = try makeSafetyCopy(
            db_path,
            timestamp,
            &safety_db_buf,
            &safety_wal_buf,
            &safety_shm_buf,
        );
        safety = copy;
        // Allocate before the commit point: the returned path must not fail
        // after the replacement is durable.
        owned_safety = try allocator.dupe(u8, copy.db);

        try writeRestoreJournal(io, allocator, db_path, timestamp);
        journal_started = true;

        try cwd.rename(db_path, cwd, copy.db, io);
        try moveIfExists(io, db_wal, copy.wal);
        try moveIfExists(io, db_shm, copy.shm);
        try syncParentDir(io, db_path);
    }

    try cwd.rename(tmp_path, cwd, db_path, io);
    try syncParentDir(io, db_path);

    if (journal_started) {
        try deleteRestoreJournal(io, allocator, db_path);
        journal_started = false;
        // Past this point the old database cannot be recovered automatically.
        syncParentDir(io, db_path) catch |err| {
            std.log.err(
                "restore: database replaced but directory sync failed: {}; previous database kept",
                .{err},
            );
            return .{ .safety_copy = owned_safety };
        };
    }

    if (!keep_safety_copy) {
        if (safety) |copy| {
            deleteQuietly(io, copy.db);
            deleteQuietly(io, copy.wal);
            deleteQuietly(io, copy.shm);
        }
        if (owned_safety) |path| {
            allocator.free(path);
            owned_safety = null;
        }
    }

    return .{ .safety_copy = if (keep_safety_copy) owned_safety else null };
}

/// Complete or roll back a restore that was interrupted after it started
/// moving the live database. Must run while holding the exclusive data lock and
/// before `StorageEngine.init` opens the database.
pub fn recoverInterruptedRestore(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !void {
    const db_path = try dbPath(allocator, data_dir);
    defer allocator.free(db_path);
    const db_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
    defer allocator.free(db_wal);
    const db_shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{db_path});
    defer allocator.free(db_shm);

    const timestamp = readRestoreJournal(io, allocator, db_path) catch |err| switch (err) {
        error.CorruptRestoreJournal => {
            if (!try fileExists(io, db_path)) return err;
            try clearRestoreArtifacts(io, allocator, db_path);
            return;
        },
        else => return err,
    };
    if (timestamp == null) return;

    var safety_db_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety_wal_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety_shm_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const safety = try makeSafetyCopy(
        db_path,
        timestamp.?,
        &safety_db_buf,
        &safety_wal_buf,
        &safety_shm_buf,
    );

    try moveIfExists(io, safety.db, db_path);
    try moveIfExists(io, safety.wal, db_wal);
    try moveIfExists(io, safety.shm, db_shm);
    if (!try fileExists(io, db_path)) return error.RestoreRecoveryFailed;

    try clearRestoreArtifacts(io, allocator, db_path);
}

fn clearRestoreArtifacts(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.restore-tmp", .{db_path});
    defer allocator.free(tmp_path);
    const tmp_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{tmp_path});
    defer allocator.free(tmp_wal);
    const tmp_shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{tmp_path});
    defer allocator.free(tmp_shm);
    deleteQuietly(io, tmp_path);
    deleteQuietly(io, tmp_wal);
    deleteQuietly(io, tmp_shm);

    try syncParentDir(io, db_path);
    try deleteRestoreJournal(io, allocator, db_path);
    try syncParentDir(io, db_path);
}

fn verifyFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    full: bool,
) !void {
    if (!try fileExists(io, path)) return error.BackupNotFound;

    // zwanzig-disable-next-line: sentinel-alloc
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{ .write = false, .create = false },
    });
    defer db.deinit();

    _ = try db.pragma(void, .{}, "busy_timeout", "5000");

    const result = if (full)
        try db.oneAlloc([]const u8, allocator, "PRAGMA integrity_check", .{}, .{})
    else
        try db.oneAlloc([]const u8, allocator, "PRAGMA quick_check", .{}, .{});
    defer if (result) |text| allocator.free(text);
    if (result == null or !std.mem.eql(u8, result.?, "ok")) return error.BackupCorrupt;

    const marker = try db.one(
        i64,
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='_zync_namespaces')",
        .{},
        .{},
    );
    if (marker == null or marker.? != 1) return error.NotZyncBaseDatabase;
}

fn rejectWalSidecar(io: std.Io, allocator: std.mem.Allocator, backup_path: []const u8) !void {
    const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{backup_path});
    defer allocator.free(wal_path);
    const stat = std.Io.Dir.cwd().statFile(io, wal_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.size > 0) return error.BackupHasWal;
}

fn makeSafetyCopy(
    db_path: []const u8,
    timestamp: i96,
    db_buf: []u8,
    wal_buf: []u8,
    shm_buf: []u8,
) !SafetyCopy {
    const safety_db = try std.fmt.bufPrint(db_buf, "{s}.pre-restore-{d}", .{ db_path, timestamp });
    return .{
        .db = safety_db,
        .wal = try std.fmt.bufPrint(wal_buf, "{s}-wal", .{safety_db}),
        .shm = try std.fmt.bufPrint(shm_buf, "{s}-shm", .{safety_db}),
    };
}

fn writeRestoreJournal(
    io: std.Io,
    allocator: std.mem.Allocator,
    db_path: []const u8,
    timestamp: i96,
) !void {
    const journal_path = try restoreJournalPath(allocator, db_path);
    defer allocator.free(journal_path);
    errdefer deleteQuietly(io, journal_path);

    const contents = try std.fmt.allocPrint(
        allocator,
        "{s}{d}\n",
        .{ restore_journal_header, timestamp },
    );
    defer allocator.free(contents);

    const file = try std.Io.Dir.cwd().createFile(io, journal_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
    try file.sync(io);
    try syncParentDir(io, db_path);
}

fn readRestoreJournal(
    io: std.Io,
    allocator: std.mem.Allocator,
    db_path: []const u8,
) !?i96 {
    const journal_path = try restoreJournalPath(allocator, db_path);
    defer allocator.free(journal_path);

    const contents = std.Io.Dir.cwd().readFileAlloc(io, journal_path, allocator, .limited(128)) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.StreamTooLong => return error.CorruptRestoreJournal,
        else => return err,
    };
    defer allocator.free(contents);

    if (!std.mem.startsWith(u8, contents, restore_journal_header)) return error.CorruptRestoreJournal;
    const value = std.mem.trim(u8, contents[restore_journal_header.len..], "\r\n \t");
    if (value.len == 0) return error.CorruptRestoreJournal;
    return std.fmt.parseInt(i96, value, 10) catch return error.CorruptRestoreJournal;
}

fn deleteRestoreJournal(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) !void {
    const journal_path = try restoreJournalPath(allocator, db_path);
    defer allocator.free(journal_path);
    std.Io.Dir.cwd().deleteFile(io, journal_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn restoreJournalPath(allocator: std.mem.Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.restore-journal", .{db_path});
}

fn restoreJournalExists(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) !bool {
    const journal_path = try restoreJournalPath(allocator, db_path);
    defer allocator.free(journal_path);
    return fileExists(io, journal_path);
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn syncFile(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.sync(io);
}

fn syncParentDir(io: std.Io, path: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const dir = try std.Io.Dir.cwd().openFile(io, dir_path, .{
        .mode = .read_only,
        .allow_directory = true,
    });
    defer dir.close(io);
    try dir.sync(io);
}

fn moveIfExists(io: std.Io, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(from, cwd, to, io) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn deleteQuietly(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.debug("could not remove {s}: {}", .{ path, err }),
    };
}
