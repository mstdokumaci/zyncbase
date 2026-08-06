const std = @import("std");

const sqlite = @import("sqlite");

const errors = @import("errors.zig");
const sql = @import("sql.zig");
const write_queue = @import("write_queue.zig");

const Allocator = std.mem.Allocator;
const CheckpointMode = write_queue.CheckpointMode;
const CheckpointStats = write_queue.CheckpointStats;

pub const ReaderNode = struct {
    conn: sqlite.Db,
    mutex: std.Thread.Mutex,
    stmt_cache: sql.StatementCache,
    /// Pre-prepared `SELECT <cols> FROM "<table>" WHERE "id"=? AND "namespace_id"=?`
    /// for each table, indexed by `table.index`. Prepared once in `StorageEngine.start()`
    /// after the schema is locked; finalized in `deinit`.
    /// Bypasses the LRU cache entirely on the hottest point-lookup path.
    select_document_stmts: []?*sqlite.c.sqlite3_stmt = &.{},

    pub fn deinit(self: *ReaderNode, allocator: Allocator) void {
        if (self.select_document_stmts.len > 0) {
            sql.finalizeStaticStmts(self.select_document_stmts);
            allocator.free(self.select_document_stmts);
            self.select_document_stmts = &.{};
        }
        self.stmt_cache.deinit(allocator);
        self.conn.deinit();
    }
};

fn pragmaChecked(db: *sqlite.Db, comptime name: []const u8, comptime value: []const u8) !void {
    _ = db.pragma(void, .{}, name, value) catch |err| {
        const classified_err = errors.classifyError(err);
        errors.logDatabaseError("configureDatabase " ++ name, classified_err, "");
        return classified_err;
    };
}

pub fn configureDatabase(db: *sqlite.Db, is_writer: bool) !void {
    if (is_writer) {
        try pragmaChecked(db, "journal_mode", "wal");
        try pragmaChecked(db, "wal_autocheckpoint", "1000");
    }

    try pragmaChecked(db, "busy_timeout", "5000");
    try pragmaChecked(db, "read_uncommitted", "true");
    try pragmaChecked(db, "synchronous", "normal");
    try pragmaChecked(db, "cache_size", "-64000");
    try pragmaChecked(db, "mmap_size", "268435456");
}

pub fn getWalSize(allocator: Allocator, db_path: []const u8, in_memory: bool) !usize {
    if (in_memory) return 0;

    const wal_path_buf = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
    defer allocator.free(wal_path_buf);

    const file = std.fs.cwd().openFile(wal_path_buf, .{}) catch |err| {
        if (err == error.FileNotFound) return 0;
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    return stat.size;
}

pub fn internalExecuteCheckpoint(conn: *sqlite.Db, allocator: Allocator, db_path: []const u8, in_memory: bool, mode: CheckpointMode) !CheckpointStats {
    const start_time = std.time.milliTimestamp();
    const wal_size_before = try getWalSize(allocator, db_path, in_memory);

    var frames_checkpointed: usize = 0;
    var frames_in_wal: usize = 0;

    const CheckpointResult = struct { busy: i64, log: i64, checkpointed: i64 };
    const result = switch (mode) {
        .passive => conn.one(CheckpointResult, "PRAGMA wal_checkpoint(PASSIVE)", .{}, .{}),
        .full => conn.one(CheckpointResult, "PRAGMA wal_checkpoint(FULL)", .{}, .{}),
        .restart => conn.one(CheckpointResult, "PRAGMA wal_checkpoint(RESTART)", .{}, .{}),
        .truncate => conn.one(CheckpointResult, "PRAGMA wal_checkpoint(TRUNCATE)", .{}, .{}),
    } catch |err| {
        const classified_err = errors.classifyError(err);
        errors.logDatabaseError("internalExecuteCheckpoint", classified_err, @tagName(mode));
        return classified_err;
    };

    if (result) |res| {
        // SQLite may return negative values in edge conditions (e.g. no WAL pages).
        // Clamp to zero to keep stats unsigned and avoid cast panics.
        frames_checkpointed = if (res.checkpointed > 0) @intCast(res.checkpointed) else 0;
        frames_in_wal = if (res.log > 0) @intCast(res.log) else 0;
    }

    const wal_size_after = try getWalSize(allocator, db_path, in_memory);
    const duration: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_time));

    std.log.info("Checkpoint completed: mode={s}, duration={}ms, frames_checkpointed={}, frames_in_wal={}, wal_before={}, wal_after={}", .{
        @tagName(mode),
        duration,
        frames_checkpointed,
        frames_in_wal,
        wal_size_before,
        wal_size_after,
    });

    return CheckpointStats{
        .mode = mode,
        .duration_ms = duration,
        .frames_checkpointed = frames_checkpointed,
        .frames_in_wal = frames_in_wal,
        .wal_size_before = wal_size_before,
        .wal_size_after = wal_size_after,
    };
}
