const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const types = @import("types.zig");
const reader = @import("reader.zig");

const StorageError = types.StorageError;
const CheckpointMode = types.CheckpointMode;
const CheckpointStats = types.CheckpointStats;
const ReconnectionConfig = types.ReconnectionConfig;
const ReaderNode = types.ReaderNode;

pub fn configureDatabase(db: *sqlite.Db, is_writer: bool) !void {
    if (is_writer) {
        _ = db.pragma(void, .{}, "journal_mode", "wal") catch |err| {
            const classified_err = reader.classifyError(err);
            reader.logDatabaseError("configureDatabase journal_mode", classified_err, "");
            return classified_err;
        };

        _ = db.pragma(void, .{}, "wal_autocheckpoint", "1000") catch |err| {
            const classified_err = reader.classifyError(err);
            reader.logDatabaseError("configureDatabase wal_autocheckpoint", classified_err, "");
            return classified_err;
        };
    }

    _ = db.pragma(void, .{}, "busy_timeout", "5000") catch |err| {
        const classified_err = reader.classifyError(err);
        reader.logDatabaseError("configureDatabase busy_timeout", classified_err, "");
        return classified_err;
    };

    _ = db.pragma(void, .{}, "read_uncommitted", "true") catch |err| {
        const classified_err = reader.classifyError(err);
        reader.logDatabaseError("configureDatabase read_uncommitted", classified_err, "");
        return classified_err;
    };

    _ = db.pragma(void, .{}, "synchronous", "normal") catch |err| {
        const classified_err = reader.classifyError(err);
        reader.logDatabaseError("configureDatabase synchronous", classified_err, "");
        return classified_err;
    };
    _ = db.pragma(void, .{}, "cache_size", "-64000") catch |err| {
        const classified_err = reader.classifyError(err);
        reader.logDatabaseError("configureDatabase cache_size", classified_err, "");
        return classified_err;
    };
    _ = db.pragma(void, .{}, "mmap_size", "268435456") catch |err| {
        const classified_err = reader.classifyError(err);
        reader.logDatabaseError("configureDatabase mmap_size", classified_err, "");
        return classified_err;
    };
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
        const classified_err = reader.classifyError(err);
        reader.logDatabaseError("internalExecuteCheckpoint", classified_err, @tagName(mode));
        return classified_err;
    };

    if (result) |res| {
        frames_checkpointed = @intCast(res.checkpointed);
        frames_in_wal = @intCast(res.log);
    }

    const wal_size_after = try getWalSize(allocator, db_path, in_memory);
    const duration: u64 = @intCast(std.time.milliTimestamp() - start_time);

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

pub fn reconnectWithBackoff(
    db_path: [:0]const u8,
    in_memory: bool,
    writer_conn: *sqlite.Db,
    reader_pool: []ReaderNode,
    config: ReconnectionConfig,
) !void {
    var attempt: u32 = 0;
    var backoff_ms = config.initial_backoff_ms;

    while (attempt < config.max_attempts) : (attempt += 1) {
        std.log.warn("Attempting database reconnection (attempt {}/{})", .{
            attempt + 1,
            config.max_attempts,
        });

        const reconnect_result = attemptReconnect(db_path, in_memory, writer_conn, reader_pool);
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

pub fn attemptReconnect(
    db_path: [:0]const u8,
    in_memory: bool,
    writer_conn: *sqlite.Db,
    reader_pool: []ReaderNode,
) !void {
    // Close existing connections
    writer_conn.deinit();
    for (reader_pool) |*reader_node| {
        reader_node.conn.deinit();
    }

    // Try to reopen writer connection
    writer_conn.* = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .shared_cache = in_memory,
    });

    // Reconfigure database
    try configureDatabase(writer_conn, true);

    // Reopen reader connections
    for (reader_pool) |*reader_node| {
        reader_node.conn = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = db_path },
            .open_flags = .{
                .write = false,
            },
            .shared_cache = in_memory,
        });
        try configureDatabase(&reader_node.conn, false);
    }
}
