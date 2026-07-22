const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const errors = @import("errors.zig");
const sql = @import("sql.zig");
const schema_types = @import("../schema/types.zig");
const write_queue = @import("write_queue.zig");

const StorageError = errors.StorageError;
const CheckpointMode = write_queue.CheckpointMode;
const CheckpointStats = write_queue.CheckpointStats;
const ReconnectionConfig = write_queue.ReconnectionConfig;

pub const ReaderNode = struct {
    conn: sqlite.Db,
    mutex: std.Thread.Mutex,
    stmt_cache: sql.StatementCache,
    /// Pre-prepared `SELECT <cols> FROM "<table>" WHERE "id"=? AND "namespace_id"=?`
    /// for each table, indexed by `table.index`. Prepared once in `StorageEngine.start()`
    /// after the schema is locked; finalized in `deinit`/`attemptReconnect`.
    /// Bypasses the LRU cache entirely on the hottest point-lookup path.
    select_document_stmts: []?*sqlite.c.sqlite3_stmt = &.{},
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

/// Bundles all the state `attemptReconnect` needs to finalize + re-prepare
/// static stmts and reset stmt_caches across the writer and all readers.
/// `stmt_cache_size` is the per-connection LRU capacity (from PerformanceConfig).
pub const ReconnectContext = struct {
    allocator: Allocator,
    schema: *const schema_types.Schema,
    db_path: [:0]const u8,
    in_memory: bool,
    writer_conn: *sqlite.Db,
    writer_select_stmts: *[]?*sqlite.c.sqlite3_stmt,
    writer_resolve_ns: *?*sqlite.c.sqlite3_stmt,
    writer_resolve_user: *?*sqlite.c.sqlite3_stmt,
    writer_stmt_cache: *sql.StatementCache,
    reader_pool: []ReaderNode,
    stmt_cache_size: usize,
};

/// Finalize all static stmts (writer + readers) and deinit all stmt_caches.
/// Called before connections are closed so no dangling stmt pointers remain.
/// Clears slices and nulls out optionals so callers can safely re-prepare.
fn finalizeAllStmts(ctx: ReconnectContext) void {
    // Writer static stmts
    if (ctx.writer_select_stmts.len > 0) {
        sql.finalizeStaticStmts(ctx.writer_select_stmts.*);
        ctx.allocator.free(ctx.writer_select_stmts.*);
        ctx.writer_select_stmts.* = &.{};
    }
    if (ctx.writer_resolve_ns.*) |s| _ = sqlite.c.sqlite3_finalize(s);
    ctx.writer_resolve_ns.* = null;
    if (ctx.writer_resolve_user.*) |s| _ = sqlite.c.sqlite3_finalize(s);
    ctx.writer_resolve_user.* = null;
    ctx.writer_stmt_cache.deinit(ctx.allocator);

    // Reader static stmts + caches
    for (ctx.reader_pool) |*node| {
        if (node.select_document_stmts.len > 0) {
            sql.finalizeStaticStmts(node.select_document_stmts);
            ctx.allocator.free(node.select_document_stmts);
            node.select_document_stmts = &.{};
        }
        node.stmt_cache.deinit(ctx.allocator);
    }
}

/// Re-prepare all static stmts and re-init all stmt_caches after connections
/// have been reopened. Returns on first prepare failure.
fn prepareAllStmts(ctx: ReconnectContext) !void {
    // Writer
    ctx.writer_stmt_cache.init(ctx.allocator, ctx.stmt_cache_size);
    errdefer ctx.writer_stmt_cache.deinit(ctx.allocator);

    ctx.writer_select_stmts.* = try sql.prepareSelectDocumentStmts(ctx.allocator, ctx.writer_conn, ctx.schema);
    errdefer {
        sql.finalizeStaticStmts(ctx.writer_select_stmts.*);
        ctx.allocator.free(ctx.writer_select_stmts.*);
        ctx.writer_select_stmts.* = &.{};
    }

    ctx.writer_resolve_ns.* = try sql.prepareStaticStmt(ctx.writer_conn, sql.resolve_namespace_sql);
    errdefer {
        if (ctx.writer_resolve_ns.*) |s| _ = sqlite.c.sqlite3_finalize(s);
        ctx.writer_resolve_ns.* = null;
    }

    // Only prepare the user-resolution stmt if the schema has a "users" table.
    if (ctx.schema.table("users") != null) {
        ctx.writer_resolve_user.* = try sql.prepareStaticStmt(ctx.writer_conn, sql.resolve_user_sql);
        errdefer {
            if (ctx.writer_resolve_user.*) |s| _ = sqlite.c.sqlite3_finalize(s);
            ctx.writer_resolve_user.* = null;
        }
    } else {
        ctx.writer_resolve_user.* = null;
    }

    // Readers
    for (ctx.reader_pool) |*node| {
        node.stmt_cache.init(ctx.allocator, ctx.stmt_cache_size);
        node.select_document_stmts = try sql.prepareSelectDocumentStmts(ctx.allocator, &node.conn, ctx.schema);
    }
}

pub fn reconnectWithBackoff(ctx: ReconnectContext, config: ReconnectionConfig) !void {
    var attempt: u32 = 0;
    var backoff_ms = config.initial_backoff_ms;

    while (attempt < config.max_attempts) : (attempt += 1) {
        std.log.warn("Attempting database reconnection (attempt {}/{})", .{
            attempt + 1,
            config.max_attempts,
        });

        const reconnect_result = attemptReconnect(ctx);
        if (reconnect_result) {
            std.log.info("Database reconnection successful after {} attempts", .{attempt + 1});
            return;
        } else |err| {
            std.log.err("Reconnection attempt {} failed: {}", .{ attempt + 1, err });

            if (attempt + 1 < config.max_attempts) {
                std.log.info("Waiting {}ms before next reconnection attempt", .{backoff_ms});
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);

                const float_backoff: f64 = @floatFromInt(backoff_ms);
                const next_backoff: u64 = @intFromFloat(float_backoff * config.backoff_multiplier);
                backoff_ms = @min(next_backoff, config.max_backoff_ms);
            }
        }
    }

    std.log.err("Failed to reconnect after {} attempts", .{config.max_attempts});
    return StorageError.ReconnectionFailed;
}

pub fn attemptReconnect(ctx: ReconnectContext) !void {
    // 1. Finalize all stmts + deinit caches BEFORE closing connections,
    //    so no dangling sqlite3_stmt pointers survive conn.deinit().
    finalizeAllStmts(ctx);

    // 2. Close existing connections
    ctx.writer_conn.deinit();
    for (ctx.reader_pool) |*reader_node| {
        reader_node.conn.deinit();
    }

    // 3. Reopen writer connection
    ctx.writer_conn.* = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = ctx.db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .shared_cache = ctx.in_memory,
    });
    errdefer ctx.writer_conn.deinit();

    // Reconfigure database
    try configureDatabase(ctx.writer_conn, true);

    // 4. Reopen reader connections
    var readers_reopened: usize = 0;
    errdefer {
        for (ctx.reader_pool[0..readers_reopened]) |*reader_node| {
            reader_node.conn.deinit();
        }
    }
    for (ctx.reader_pool) |*reader_node| {
        reader_node.conn = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = ctx.db_path },
            .open_flags = .{
                .write = false,
            },
            .shared_cache = ctx.in_memory,
        });
        readers_reopened += 1;
        try configureDatabase(&reader_node.conn, false);
    }

    // 5. Re-prepare all static stmts + re-init stmt_caches
    try prepareAllStmts(ctx);
}
