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
    try cwd.rename(partial_path, cwd, out_path, io);

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
/// Requires exclusive access to the data directory, so the server must be
/// stopped. The current database (and its WAL/SHM) is moved aside first and
/// restored on failure.
pub fn restore(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    backup_path: []const u8,
    keep_safety_copy: bool,
) !RestoreInfo {
    var lock = try DataLock.acquire(io, allocator, data_dir);
    defer lock.release(io);

    try verifyFile(io, allocator, backup_path, true);
    try std.Io.Dir.cwd().createDirPath(io, data_dir);

    const cwd = std.Io.Dir.cwd();
    const db_path = try dbPath(allocator, data_dir);
    defer allocator.free(db_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.restore-tmp", .{db_path});
    defer allocator.free(tmp_path);
    const db_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
    defer allocator.free(db_wal);
    const db_shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{db_path});
    defer allocator.free(db_shm);

    errdefer deleteQuietly(io, tmp_path);

    try cwd.copyFile(backup_path, cwd, tmp_path, io, .{ .replace = true });
    try syncFile(io, tmp_path);

    const had_db = try fileExists(io, db_path);
    var safety_db_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety_wal_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety_shm_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var safety: ?SafetyCopy = null;
    var restore_started = false;
    errdefer if (restore_started) rollbackRestore(io, db_path, db_wal, db_shm, safety);

    if (had_db) {
        const safety_db = try std.fmt.bufPrint(
            &safety_db_buf,
            "{s}.pre-restore-{d}",
            .{ db_path, std.Io.Clock.real.now(io).toNanoseconds() },
        );
        const copy = SafetyCopy{
            .db = safety_db,
            .wal = try std.fmt.bufPrint(&safety_wal_buf, "{s}-wal", .{safety_db}),
            .shm = try std.fmt.bufPrint(&safety_shm_buf, "{s}-shm", .{safety_db}),
        };
        safety = copy;

        restore_started = true;
        try cwd.rename(db_path, cwd, copy.db, io);
        try moveIfExists(io, db_wal, copy.wal);
        try moveIfExists(io, db_shm, copy.shm);
    }

    try cwd.rename(tmp_path, cwd, db_path, io);

    if (!keep_safety_copy) {
        if (safety) |copy| {
            deleteQuietly(io, copy.db);
            deleteQuietly(io, copy.wal);
            deleteQuietly(io, copy.shm);
        }
    }

    var owned_safety: ?[]u8 = null;
    if (keep_safety_copy) {
        if (safety) |copy| owned_safety = try allocator.dupe(u8, copy.db);
    }
    return .{ .safety_copy = owned_safety };
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

fn moveIfExists(io: std.Io, from: []const u8, to: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(from, cwd, to, io) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn rollbackRestore(
    io: std.Io,
    db_path: []const u8,
    db_wal: []const u8,
    db_shm: []const u8,
    safety: ?SafetyCopy,
) void {
    const cwd = std.Io.Dir.cwd();
    if (safety) |copy| {
        cwd.rename(copy.db, cwd, db_path, io) catch |err| {
            std.log.err("restore rollback failed to restore {s}: {}", .{ db_path, err });
        };
        moveIfExists(io, copy.wal, db_wal) catch |err| {
            std.log.err("restore rollback failed to restore {s}: {}", .{ db_wal, err });
        };
        moveIfExists(io, copy.shm, db_shm) catch |err| {
            std.log.err("restore rollback failed to restore {s}: {}", .{ db_shm, err });
        };
    }
}

fn deleteQuietly(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.debug("could not remove {s}: {}", .{ path, err }),
    };
}
