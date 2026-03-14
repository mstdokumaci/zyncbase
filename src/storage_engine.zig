const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");

/// Specific error types for different database failure scenarios
pub const StorageError = error{
    /// Database connection was lost
    ConnectionLost,
    /// Failed to reconnect after multiple attempts
    ReconnectionFailed,
    /// Database constraint was violated (e.g., unique constraint)
    ConstraintViolation,
    /// Disk is full, cannot write more data
    DiskFull,
    /// Database file is corrupted
    DatabaseCorrupted,
    /// Database is locked by another process
    DatabaseLocked,
    /// Invalid database operation
    InvalidOperation,
    /// Transaction is already active
    TransactionAlreadyActive,
    /// No active transaction
    NoActiveTransaction,
};

/// SQLite checkpoint modes
pub const CheckpointMode = enum {
    /// Passive mode: checkpoint without blocking readers/writers
    passive,
    /// Full mode: wait for readers to finish, then checkpoint
    full,
    /// Restart mode: checkpoint and reset WAL
    restart,
    /// Truncate mode: checkpoint and truncate WAL to zero bytes
    truncate,
};

/// Statistics from a checkpoint operation
pub const CheckpointStats = struct {
    mode: CheckpointMode,
    duration_ms: u64,
    frames_checkpointed: usize,
    frames_in_wal: usize,
    wal_size_before: usize,
    wal_size_after: usize,
};

/// Configuration for reconnection logic
pub const ReconnectionConfig = struct {
    /// Maximum number of reconnection attempts
    max_attempts: u32 = 5,
    /// Initial backoff delay in milliseconds
    initial_backoff_ms: u64 = 100,
    /// Maximum backoff delay in milliseconds
    max_backoff_ms: u64 = 5000,
    /// Backoff multiplier for exponential backoff
    backoff_multiplier: f64 = 2.0,
};

pub const StorageEngine = struct {
    allocator: Allocator,
    db_path: [:0]const u8,
    writer_conn: sqlite.Db,
    reader_pool: []sqlite.Db,
    write_queue: WriteQueue,
    write_thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool),
    next_reader_idx: std.atomic.Value(usize),
    transaction_active: std.atomic.Value(bool),
    pending_writes_count: std.atomic.Value(usize),
    reconnection_config: ReconnectionConfig,
    write_mutex: std.Thread.Mutex,
    write_cond: std.Thread.Condition,

    pub fn init(allocator: Allocator, data_dir: []const u8) !*StorageEngine {
        const self = try allocator.create(StorageEngine);
        errdefer allocator.destroy(self);

        // Ensure data directory exists
        std.fs.cwd().makePath(data_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // Build database path (null-terminated for SQLite)
        const db_path_buf = try std.fmt.allocPrint(allocator, "{s}/zyncbase.db", .{data_dir});
        errdefer allocator.free(db_path_buf);
        const db_path = try allocator.dupeZ(u8, db_path_buf);
        allocator.free(db_path_buf); // Free the non-null-terminated version
        errdefer allocator.free(db_path);

        // Open writer connection
        var writer_conn = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = db_path },
            .open_flags = .{
                .write = true,
                .create = true,
            },
        });
        errdefer writer_conn.deinit();

        // Configure WAL mode and pragmas
        try configureDatabase(&writer_conn);

        // Create schema
        try createSchema(&writer_conn);

        // Create reader pool (one per CPU core)
        const num_readers = try std.Thread.getCpuCount();
        const reader_pool = try allocator.alloc(sqlite.Db, num_readers);
        errdefer allocator.free(reader_pool);

        var initialized_readers: usize = 0;
        errdefer {
            for (reader_pool[0..initialized_readers]) |*reader| {
                reader.deinit();
            }
        }

        for (reader_pool) |*reader| {
            reader.* = try sqlite.Db.init(.{
                .mode = sqlite.Db.Mode{ .File = db_path },
                .open_flags = .{
                    .write = false,
                },
            });
            initialized_readers += 1;
        }

        self.* = .{
            .allocator = allocator,
            .db_path = db_path,
            .writer_conn = writer_conn,
            .reader_pool = reader_pool,
            .write_queue = try WriteQueue.init(allocator, 1000),
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .next_reader_idx = std.atomic.Value(usize).init(0),
            .transaction_active = std.atomic.Value(bool).init(false),
            .pending_writes_count = std.atomic.Value(usize).init(0),
            .reconnection_config = .{},
            .write_mutex = .{},
            .write_cond = .{},
        };

        // Start write thread
        self.write_thread = try std.Thread.spawn(.{}, writeThreadLoop, .{self});

        // Give the write thread a moment to initialize
        std.Thread.sleep(1 * std.time.ns_per_ms);

        return self;
    }

    pub fn deinit(self: *StorageEngine) void {
        // Signal shutdown and wake the write thread immediately
        self.shutdown_requested.store(true, .release);
        self.write_cond.signal();

        // Wait for write thread
        if (self.write_thread) |thread| {
            thread.join();
        }

        // Close connections
        self.writer_conn.deinit();
        for (self.reader_pool) |*reader| {
            reader.deinit();
        }

        // Free resources
        self.allocator.free(self.reader_pool);
        self.allocator.free(self.db_path);
        self.write_queue.deinit();
        self.allocator.destroy(self);
    }

    /// Get a StorageLayer interface for the CheckpointManager
    pub fn getStorageLayer(self: *StorageEngine) !*@import("checkpoint_manager.zig").CheckpointManager.StorageLayer {
        const CheckpointManagerModule = @import("checkpoint_manager.zig");
        const storage_layer = try CheckpointManagerModule.CheckpointManager.StorageLayer.init(self.allocator, self.db_path);

        // Store a reference to self for checkpoint execution
        storage_layer.storage_engine = self;

        return storage_layer;
    }

    /// Execute a checkpoint operation with the specified mode
    /// Returns statistics about the checkpoint operation
    pub fn executeCheckpoint(self: *StorageEngine, mode: CheckpointMode) !CheckpointStats {
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .type = .checkpoint,
            .checkpoint_mode = mode,
            .completion_signal = &signal,
        };

        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);

        try signal.wait();
        return signal.result orelse error.InvalidOperation;
    }

    fn internalExecuteCheckpoint(self: *StorageEngine, mode: CheckpointMode) !CheckpointStats {
        const start_time = std.time.milliTimestamp();
        const wal_size_before = try self.getWalSize();

        var frames_checkpointed: usize = 0;
        var frames_in_wal: usize = 0;

        const CheckpointResult = struct { busy: i64, log: i64, checkpointed: i64 };
        const result = switch (mode) {
            .passive => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(PASSIVE)", .{}, .{}),
            .full => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(FULL)", .{}, .{}),
            .restart => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(RESTART)", .{}, .{}),
            .truncate => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(TRUNCATE)", .{}, .{}),
        } catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("internalExecuteCheckpoint", classified_err, @tagName(mode));
            return classified_err;
        };

        if (result) |res| {
            frames_checkpointed = @intCast(res.checkpointed);
            frames_in_wal = @intCast(res.log);
        }

        const wal_size_after = try self.getWalSize();
        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));

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

    /// Get the current WAL file size in bytes
    pub fn getWalSize(self: *StorageEngine) !usize {
        // Try to get WAL file size from filesystem
        const wal_path_buf = try std.fmt.allocPrint(self.allocator, "{s}-wal", .{self.db_path});
        defer self.allocator.free(wal_path_buf);

        const file = std.fs.cwd().openFile(wal_path_buf, .{}) catch |err| {
            // WAL file might not exist yet (no writes have occurred)
            if (err == error.FileNotFound) {
                return 0;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        return stat.size;
    }

    pub fn set(self: *StorageEngine, namespace: []const u8, path: []const u8, value: []const u8) !void {
        const op = WriteOp{
            .type = .set,
            .namespace = try self.allocator.dupe(u8, namespace),
            .path = try self.allocator.dupe(u8, path),
            .value = try self.allocator.dupe(u8, value),
        };

        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    pub fn get(self: *StorageEngine, namespace: []const u8, path: []const u8) !?[]const u8 {
        // Get reader connection (round-robin)
        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const reader = &self.reader_pool[reader_idx];

        // Execute query with inline parameters
        const row = reader.oneAlloc(
            struct { value_json: []const u8 },
            self.allocator,
            "SELECT value_json FROM kv_store WHERE namespace = $namespace{[]const u8} AND path = $path{[]const u8}",
            .{},
            .{ .namespace = namespace, .path = path },
        ) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("get", classified_err, path);

            // If connection lost, attempt reconnection
            if (classified_err == StorageError.ConnectionLost) {
                self.reconnectWithBackoff() catch |reconnect_err| {
                    logDatabaseError("reconnect", reconnect_err, "get operation");
                    return reconnect_err;
                };
                // Retry the operation after reconnection
                return self.get(namespace, path);
            }

            return classified_err;
        } orelse return null;

        // The string is already allocated by oneAlloc, so we just return it
        return row.value_json;
    }

    pub fn delete(self: *StorageEngine, namespace: []const u8, path: []const u8) !void {
        const op = WriteOp{
            .type = .delete,
            .namespace = try self.allocator.dupe(u8, namespace),
            .path = try self.allocator.dupe(u8, path),
            .value = null,
        };

        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    pub fn query(
        self: *StorageEngine,
        namespace: []const u8,
        path_prefix: []const u8,
    ) ![]QueryResult {
        // Get reader connection
        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const reader = &self.reader_pool[reader_idx];

        // Build LIKE pattern
        const pattern_buf = try std.fmt.allocPrint(self.allocator, "{s}%", .{path_prefix});
        defer self.allocator.free(pattern_buf);
        const pattern: []const u8 = pattern_buf;

        // Prepare statement
        var stmt = reader.prepare("SELECT path, value_json FROM kv_store WHERE namespace = $namespace{[]const u8} AND path LIKE $pattern{[]const u8}") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("query prepare", classified_err, path_prefix);

            // If connection lost, attempt reconnection
            if (classified_err == StorageError.ConnectionLost) {
                self.reconnectWithBackoff() catch |reconnect_err| {
                    logDatabaseError("reconnect", reconnect_err, "query operation");
                    return reconnect_err;
                };
                // Retry the operation after reconnection
                return self.query(namespace, path_prefix);
            }

            return classified_err;
        };
        defer stmt.deinit();

        // Collect results
        var results = std.ArrayList(QueryResult).initCapacity(self.allocator, 10) catch |err| {
            std.log.err("Failed to initialize results: {}", .{err});
            return err;
        };
        errdefer {
            for (results.items) |result| {
                self.allocator.free(result.path);
                self.allocator.free(result.value);
            }
            results.deinit(self.allocator);
        }

        var iter = stmt.iterator(struct {
            path: []const u8,
            value_json: []const u8,
        }, .{ .namespace = namespace, .pattern = pattern }) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("query iterator", classified_err, path_prefix);
            return classified_err;
        };

        while (iter.nextAlloc(self.allocator, .{}) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("query next", classified_err, path_prefix);
            return classified_err;
        }) |row| {
            defer self.allocator.free(row.path);
            defer self.allocator.free(row.value_json);

            try results.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, row.path),
                .value = try self.allocator.dupe(u8, row.value_json),
            });
        }

        return results.toOwnedSlice(self.allocator);
    }

    pub fn beginTransaction(self: *StorageEngine) !void {
        if (self.transaction_active.load(.acquire)) {
            return StorageError.TransactionAlreadyActive;
        }
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .type = .begin_transaction,
            .completion_signal = &signal,
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
        return signal.wait();
    }

    pub fn commitTransaction(self: *StorageEngine) !void {
        if (!self.transaction_active.load(.acquire)) {
            return StorageError.NoActiveTransaction;
        }
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .type = .commit_transaction,
            .completion_signal = &signal,
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
        return signal.wait();
    }

    pub fn rollbackTransaction(self: *StorageEngine) !void {
        if (!self.transaction_active.load(.acquire)) {
            return StorageError.NoActiveTransaction;
        }
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .type = .rollback_transaction,
            .completion_signal = &signal,
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
        return signal.wait();
    }

    pub fn isTransactionActive(self: *StorageEngine) bool {
        return self.transaction_active.load(.acquire);
    }

    /// Classify SQLite error into our specific error types
    fn classifyError(err: anyerror) anyerror {
        // Map SQLite errors to our specific error types
        return switch (err) {
            error.SQLiteConstraint => StorageError.ConstraintViolation,
            error.SQLiteFull => StorageError.DiskFull,
            error.SQLiteCorrupt, error.SQLiteNotADatabase => StorageError.DatabaseCorrupted,
            error.SQLiteBusy, error.SQLiteLocked => StorageError.DatabaseLocked,
            else => err,
        };
    }

    /// Log database error with full details
    fn logDatabaseError(operation: []const u8, err: anyerror, context: []const u8) void {
        std.log.debug("Database error during {s}: {} - Context: {s}", .{ operation, err, context });
    }

    /// Attempt to reconnect to database with exponential backoff
    fn reconnectWithBackoff(self: *StorageEngine) !void {
        var attempt: u32 = 0;
        var backoff_ms = self.reconnection_config.initial_backoff_ms;

        while (attempt < self.reconnection_config.max_attempts) : (attempt += 1) {
            std.log.warn("Attempting database reconnection (attempt {}/{})", .{
                attempt + 1,
                self.reconnection_config.max_attempts,
            });

            // Try to reconnect
            const reconnect_result = self.attemptReconnect();
            if (reconnect_result) {
                std.log.info("Database reconnection successful after {} attempts", .{attempt + 1});
                return;
            } else |err| {
                std.log.err("Reconnection attempt {} failed: {}", .{ attempt + 1, err });

                // If not the last attempt, wait with exponential backoff
                if (attempt + 1 < self.reconnection_config.max_attempts) {
                    std.log.info("Waiting {}ms before next reconnection attempt", .{backoff_ms});
                    std.Thread.sleep(backoff_ms * std.time.ns_per_ms);

                    // Calculate next backoff with exponential increase
                    const next_backoff = @as(u64, @intFromFloat(@as(f64, @floatFromInt(backoff_ms)) * self.reconnection_config.backoff_multiplier));
                    backoff_ms = @min(next_backoff, self.reconnection_config.max_backoff_ms);
                }
            }
        }

        std.log.err("Failed to reconnect after {} attempts", .{self.reconnection_config.max_attempts});
        return StorageError.ReconnectionFailed;
    }

    /// Attempt a single reconnection
    fn attemptReconnect(self: *StorageEngine) !void {
        // Close existing connections
        self.writer_conn.deinit();
        for (self.reader_pool) |*reader| {
            reader.deinit();
        }

        // Try to reopen writer connection
        self.writer_conn = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = self.db_path },
            .open_flags = .{
                .write = true,
                .create = true,
            },
        });

        // Reconfigure database
        try configureDatabase(&self.writer_conn);

        // Reopen reader connections
        for (self.reader_pool) |*reader| {
            reader.* = try sqlite.Db.init(.{
                .mode = sqlite.Db.Mode{ .File = self.db_path },
                .open_flags = .{
                    .write = false,
                },
            });
        }
    }

    /// Push a write op and wake the write thread immediately.
    fn pushWrite(self: *StorageEngine, op: WriteOp) !void {
        try self.write_queue.push(op);
        self.write_cond.signal();
    }

    pub fn flushPendingWrites(self: *StorageEngine) !void {
        // Wait for write queue and currently processing batch to drain
        while (self.pending_writes_count.load(.acquire) > 0) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    fn writeThreadLoop(self: *StorageEngine) void {
        self.writeThreadLoopImpl() catch |err| {
            std.log.err("Write thread error: {}", .{err});
        };
    }

    fn writeThreadLoopImpl(self: *StorageEngine) !void {
        const batch_size = 100;
        const batch_timeout_ms = 10;

        var batch = std.ArrayListUnmanaged(WriteOp){};
        try batch.ensureTotalCapacity(self.allocator, batch_size);
        defer {
            for (batch.items) |op| {
                op.deinit(self.allocator);
            }
            batch.deinit(self.allocator);
        }

        var last_batch_time = std.time.milliTimestamp();

        while (!self.shutdown_requested.load(.acquire)) {
            // Collect operations for batch
            while (batch.items.len < batch_size) {
                if (self.write_queue.pop()) |op| {
                    switch (op.type) {
                        .set, .delete => {
                            batch.append(self.allocator, op) catch |err| {
                                std.log.err("Failed to append to batch: {}", .{err});
                                op.deinit(self.allocator);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                continue;
                            };
                        },
                        .begin_transaction => {
                            // Flush current batch first
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            if (self.writer_conn.exec("BEGIN TRANSACTION", .{}, .{})) |_| {
                                self.transaction_active.store(true, .release);
                                op.completion_signal.?.signal(null);
                            } else |err| {
                                op.completion_signal.?.signal(classifyError(err));
                            }
                            _ = self.pending_writes_count.fetchSub(1, .release);
                        },
                        .commit_transaction => {
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            if (!self.transaction_active.load(.acquire)) {
                                op.completion_signal.?.signal(StorageError.NoActiveTransaction);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                continue;
                            }
                            if (self.writer_conn.exec("COMMIT", .{}, .{})) |_| {
                                self.transaction_active.store(false, .release);
                                op.completion_signal.?.signal(null);
                            } else |err| {
                                self.transaction_active.store(false, .release);
                                op.completion_signal.?.signal(classifyError(err));
                            }
                            _ = self.pending_writes_count.fetchSub(1, .release);
                        },
                        .rollback_transaction => {
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            if (!self.transaction_active.load(.acquire)) {
                                op.completion_signal.?.signal(StorageError.NoActiveTransaction);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                continue;
                            }
                            if (self.writer_conn.exec("ROLLBACK", .{}, .{})) |_| {
                                self.transaction_active.store(false, .release);
                                op.completion_signal.?.signal(null);
                            } else |err| {
                                self.transaction_active.store(false, .release);
                                op.completion_signal.?.signal(classifyError(err));
                            }
                            _ = self.pending_writes_count.fetchSub(1, .release);
                        },
                        .checkpoint => {
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            const stats = self.internalExecuteCheckpoint(op.checkpoint_mode.?) catch |err| {
                                op.completion_signal.?.signal(err);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                continue;
                            };
                            op.completion_signal.?.signalWithResult(stats);
                            _ = self.pending_writes_count.fetchSub(1, .release);
                        },
                    }
                } else {
                    break;
                }
            }

            // Check if we should flush batch
            const now = std.time.milliTimestamp();
            const time_since_last = now - last_batch_time;

            const should_flush = batch.items.len >= batch_size or
                (batch.items.len > 0 and time_since_last >= batch_timeout_ms);

            if (should_flush) {
                try self.flushBatch(&batch, &last_batch_time);
            } else {
                // Wait for new work or timeout (for batch flushing), instead of busy-sleeping
                self.write_mutex.lock();
                defer self.write_mutex.unlock();
                self.write_cond.timedWait(&self.write_mutex, 1 * std.time.ns_per_ms) catch {};
            }
        }

        // Drain any ops still in the queue that weren't popped before shutdown was signalled
        while (self.write_queue.pop()) |op| {
            switch (op.type) {
                .set, .delete => {
                    batch.append(self.allocator, op) catch {
                        op.deinit(self.allocator);
                        _ = self.pending_writes_count.fetchSub(1, .release);
                    };
                },
                else => {
                    // Signal waiting callers so they don't hang forever
                    if (op.completion_signal) |sig| sig.signal(StorageError.InvalidOperation);
                    op.deinit(self.allocator);
                    _ = self.pending_writes_count.fetchSub(1, .release);
                },
            }
        }

        // Flush remaining operations on shutdown
        if (batch.items.len > 0) {
            try self.flushBatch(&batch, &last_batch_time);
        }
    }

    fn flushBatch(self: *StorageEngine, batch: *std.ArrayListUnmanaged(WriteOp), last_batch_time: *i64) !void {
        const batch_len = batch.items.len;
        self.executeBatch(batch.items) catch |err| {
            std.log.debug("Failed to execute batch, transaction rolled back: {}", .{err});
        };
        for (batch.items) |op| {
            op.deinit(self.allocator);
        }
        batch.clearRetainingCapacity();
        _ = self.pending_writes_count.fetchSub(batch_len, .release);
        last_batch_time.* = std.time.milliTimestamp();
    }

    fn executeBatch(self: *StorageEngine, ops: []const WriteOp) !void {
        // Check if a manual transaction is already active
        const manual_transaction_active = self.transaction_active.load(.acquire);

        if (!manual_transaction_active) {
            self.writer_conn.exec("BEGIN TRANSACTION", .{}, .{}) catch |err| {
                const classified_err = classifyError(err);
                logDatabaseError("executeBatch BEGIN", classified_err, "");
                return classified_err;
            };
            self.transaction_active.store(true, .release);
        }

        // Ensure rollback on error (only if we started the transaction)
        errdefer {
            if (!manual_transaction_active) {
                self.writer_conn.exec("ROLLBACK", .{}, .{}) catch |rollback_err| {
                    const classified_err = classifyError(rollback_err);
                    logDatabaseError("executeBatch ROLLBACK", classified_err, "");
                };
                self.transaction_active.store(false, .release);
            }
        }

        // Execute all operations
        for (ops) |op| {
            switch (op.type) {
                .set => self.executeSet(op.namespace.?, op.path.?, op.value.?) catch |err| {
                    const classified_err = classifyError(err);
                    logDatabaseError("executeBatch SET", classified_err, op.path.?);
                    return classified_err;
                },
                .delete => self.executeDelete(op.namespace.?, op.path.?) catch |err| {
                    const classified_err = classifyError(err);
                    logDatabaseError("executeBatch DELETE", classified_err, op.path.?);
                    return classified_err;
                },
                else => unreachable, // Non-batch ops should not be here
            }
        }

        // Commit transaction and clear state (only if we started the transaction)
        if (!manual_transaction_active) {
            self.writer_conn.exec("COMMIT", .{}, .{}) catch |err| {
                const classified_err = classifyError(err);
                logDatabaseError("executeBatch COMMIT", classified_err, "");
                return classified_err;
            };
            self.transaction_active.store(false, .release);
        }
    }

    fn executeSet(self: *StorageEngine, namespace: []const u8, path: []const u8, value: []const u8) !void {
        self.writer_conn.exec(
            \\INSERT INTO kv_store (namespace, path, value_json, updated_at)
            \\VALUES ($namespace{[]const u8}, $path{[]const u8}, $value{[]const u8}, $timestamp{i64})
            \\ON CONFLICT(namespace, path) DO UPDATE SET
            \\  value_json = excluded.value_json,
            \\  updated_at = excluded.updated_at
        , .{}, .{
            .namespace = namespace,
            .path = path,
            .value = value,
            .timestamp = std.time.timestamp(),
        }) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("executeSet", classified_err, path);

            // If connection lost, attempt reconnection
            if (classified_err == StorageError.ConnectionLost) {
                self.reconnectWithBackoff() catch |reconnect_err| {
                    logDatabaseError("reconnect", reconnect_err, "executeSet operation");
                    return reconnect_err;
                };
                // Retry the operation after reconnection
                return self.executeSet(namespace, path, value);
            }

            return classified_err;
        };
    }

    fn executeDelete(self: *StorageEngine, namespace: []const u8, path: []const u8) !void {
        self.writer_conn.exec(
            \\DELETE FROM kv_store
            \\WHERE namespace = $namespace{[]const u8} AND path = $path{[]const u8}
        , .{}, .{
            .namespace = namespace,
            .path = path,
        }) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("executeDelete", classified_err, path);

            // If connection lost, attempt reconnection
            if (classified_err == StorageError.ConnectionLost) {
                self.reconnectWithBackoff() catch |reconnect_err| {
                    logDatabaseError("reconnect", reconnect_err, "executeDelete operation");
                    return reconnect_err;
                };
                // Retry the operation after reconnection
                return self.executeDelete(namespace, path);
            }

            return classified_err;
        };
    }

    fn configureDatabase(db: *sqlite.Db) !void {
        // journal_mode = WAL returns "wal", so we use void to consume the result row.
        _ = db.pragma(void, .{}, "journal_mode", "wal") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase journal_mode", classified_err, "");
            return classified_err;
        };

        // The following usually return nothing or a single row with the new value.
        // Using `void` with `pragma` ensures that the result row (if any) is consumed.
        _ = db.pragma(void, .{}, "synchronous", "normal") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase synchronous", classified_err, "");
            return classified_err;
        };
        _ = db.pragma(void, .{}, "cache_size", "-64000") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase cache_size", classified_err, "");
            return classified_err;
        };
        _ = db.pragma(void, .{}, "mmap_size", "268435456") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase mmap_size", classified_err, "");
            return classified_err;
        };
        _ = db.pragma(void, .{}, "wal_autocheckpoint", "1000") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase wal_autocheckpoint", classified_err, "");
            return classified_err;
        };
    }

    fn createSchema(db: *sqlite.Db) !void {
        // Create generic key-value table
        const create_table =
            \\CREATE TABLE IF NOT EXISTS kv_store (
            \\  namespace TEXT NOT NULL,
            \\  path TEXT NOT NULL,
            \\  value_json TEXT NOT NULL,
            \\  created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            \\  updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
            \\  PRIMARY KEY (namespace, path)
            \\)
        ;

        db.exec(create_table, .{}, .{}) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("createSchema CREATE TABLE", classified_err, "");
            return classified_err;
        };

        // Create indexes
        db.exec("CREATE INDEX IF NOT EXISTS idx_kv_namespace ON kv_store(namespace)", .{}, .{}) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("createSchema CREATE INDEX namespace", classified_err, "");
            return classified_err;
        };
        db.exec("CREATE INDEX IF NOT EXISTS idx_kv_path ON kv_store(path)", .{}, .{}) catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("createSchema CREATE INDEX path", classified_err, "");
            return classified_err;
        };
    }
};

pub const WriteOp = struct {
    type: enum { set, delete, begin_transaction, commit_transaction, rollback_transaction, checkpoint },
    namespace: ?[]const u8 = null,
    path: ?[]const u8 = null,
    value: ?[]const u8 = null,
    checkpoint_mode: ?CheckpointMode = null,
    completion_signal: ?*CompletionSignal = null,

    pub const CompletionSignal = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
        err: ?anyerror = null,
        result: ?CheckpointStats = null,

        pub fn wait(self: *CompletionSignal) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.done) {
                self.cond.wait(&self.mutex);
            }
            if (self.err) |e| return e;
        }

        pub fn signal(self: *CompletionSignal, err: ?anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.err = err;
            self.done = true;
            self.cond.signal();
        }

        pub fn signalWithResult(self: *CompletionSignal, result: CheckpointStats) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.result = result;
            self.done = true;
            self.cond.signal();
        }
    };

    pub fn deinit(self: WriteOp, allocator: Allocator) void {
        if (self.namespace) |n| allocator.free(n);
        if (self.path) |p| allocator.free(p);
        if (self.value) |v| {
            allocator.free(v);
        }
    }
};

pub const QueryResult = struct {
    path: []const u8,
    value: []const u8,
};

pub const WriteQueue = struct {
    const Node = struct {
        op: WriteOp,
        next: std.atomic.Value(?*Node),
    };

    head: *Node,
    tail: std.atomic.Value(*Node),
    allocator: Allocator,

    pub fn init(allocator: Allocator, _: usize) !WriteQueue {
        const stub = try allocator.create(Node);
        stub.* = .{ .op = undefined, .next = std.atomic.Value(?*Node).init(null) };
        return WriteQueue{
            .head = stub,
            .tail = std.atomic.Value(*Node).init(stub),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WriteQueue) void {
        while (self.pop()) |op| {
            op.deinit(self.allocator);
        }
        self.allocator.destroy(self.head);
    }

    pub fn push(self: *WriteQueue, op: WriteOp) !void {
        const node = try self.allocator.create(Node);
        node.* = .{ .op = op, .next = std.atomic.Value(?*Node).init(null) };
        // swap tail to point to our new node
        const prev = self.tail.swap(node, .acq_rel);
        // Link the previous node to our new node
        prev.next.store(node, .release);
    }

    pub fn pop(self: *WriteQueue) ?WriteOp {
        const head = self.head;
        const next = head.next.load(.acquire) orelse return null;

        self.head = next;
        const op = next.op;
        self.allocator.destroy(head);
        return op;
    }

    pub fn len(self: *WriteQueue) usize {
        _ = self;
        // Approximate length is enough for metrics, but we are removing mutex
        // For now, return 0 or implement a separate atomic counter if needed.
        // The StorageEngine already has pending_writes_count which is atomic.
        return 0;
    }
};
