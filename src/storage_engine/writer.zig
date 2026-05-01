const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const reader = @import("reader.zig");
const connection = @import("connection.zig");
const errors = @import("errors.zig");
const doc_id = @import("../doc_id.zig");
const schema = @import("../schema.zig");
const sql = @import("sql.zig");
const storage_values = @import("values.zig");
const write_queue = @import("write_queue.zig");
const change_buffer = @import("../change_buffer.zig");
const OwnedRowChange = change_buffer.OwnedRowChange;
const ChangeBuffer = change_buffer.ChangeBuffer;
const PerformanceConfig = @import("../config_loader.zig").Config.PerformanceConfig;

const DocId = storage_values.DocId;
const MetadataCacheKey = storage_values.MetadataCacheKey;
const TypedRow = storage_values.TypedRow;
const WriteOp = write_queue.WriteOp;
const WriteQueue = write_queue.WriteQueue;
const StatementCache = sql.StatementCache;
const StorageError = errors.StorageError;

pub const Writer = struct {
    allocator: Allocator,
    conn: sqlite.Db,
    stmt_cache: StatementCache,
    transaction_active: std.atomic.Value(bool),
    version: std.atomic.Value(u64),
    work_cond: std.Thread.Condition,
    mutex: std.Thread.Mutex,
    flush_cond: std.Thread.Condition,
    pending_count: std.atomic.Value(usize),
    change_buffer: ChangeBuffer,
    notifier_ptr: ?*const fn (ctx: ?*anyopaque) void,
    notifier_ctx: ?*anyopaque,
    metadata_cache: *storage_values.typed_cache_type,
    schema: *const schema.Schema,
    shutdown_requested: std.atomic.Value(bool),
    is_ready: std.atomic.Value(bool),
    queue: WriteQueue,
    performance_config: PerformanceConfig,
    db_path: [:0]const u8,
    in_memory: bool,
    write_thread: ?std.Thread = null,

    pub fn beginOp(self: *Writer) void {
        _ = self.pending_count.fetchAdd(1, .acq_rel);
    }

    pub fn endOp(self: *Writer, count: usize) void {
        _ = self.pending_count.fetchSub(count, .acq_rel);
    }

    pub fn enqueueOp(self: *Writer, op: WriteOp) !void {
        self.beginOp();
        self.queue.push(op) catch |err| {
            self.endOp(1);
            return err;
        };
        self.mutex.lock();
        self.work_cond.signal();
        self.mutex.unlock();
    }

    pub fn pendingOpCount(self: *const Writer) usize {
        return self.pending_count.load(.acquire);
    }

    pub fn bumpVersion(self: *Writer) void {
        _ = self.version.fetchAdd(1, .acq_rel);
    }

    pub fn snapshotVersion(self: *const Writer) u64 {
        return self.version.load(.acquire);
    }

    pub fn markTransactionActive(self: *Writer) void {
        self.transaction_active.store(true, .release);
    }

    pub fn markTransactionInactive(self: *Writer) void {
        self.transaction_active.store(false, .release);
    }

    pub fn isTransactionActive(self: *const Writer) bool {
        return self.transaction_active.load(.acquire);
    }

    pub fn notifyChanges(self: *Writer) void {
        if (self.notifier_ptr) |n| {
            n(self.notifier_ctx);
        }
    }

    pub fn wakeFlushWaiters(self: *Writer) void {
        self.mutex.lock();
        self.flush_cond.broadcast();
        self.mutex.unlock();
    }

    pub fn spawnThread(self: *Writer) !void {
        self.write_thread = try std.Thread.spawn(.{}, writeThreadLoop, .{self});
    }

    pub fn waitUntilReady(self: *Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.is_ready.load(.acquire)) {
            self.work_cond.wait(&self.mutex);
        }
    }

    pub fn stopThread(self: *Writer) void {
        self.shutdown_requested.store(true, .release);
        self.mutex.lock();
        self.work_cond.signal();
        self.mutex.unlock();

        if (self.write_thread) |thread| {
            thread.join();
            self.write_thread = null;
        }
    }

    pub fn flushPendingWrites(self: *Writer) void {
        std.log.debug("flushPendingWrites: count={}", .{self.pendingOpCount()});
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.pendingOpCount() > 0) {
            self.flush_cond.wait(&self.mutex);
        }
    }

    pub fn setupConn(self: *Writer) *sqlite.Db {
        return &self.conn;
    }

    pub fn deinit(self: *Writer) void {
        self.stmt_cache.deinit(self.allocator);
        self.conn.deinit();
        self.allocator.free(self.db_path);
        self.queue.deinit();
        self.change_buffer.deinit();
    }
    // Use sqlite3_exec for transaction-control statements because sqlite.Db.exec
    // logs an error from Statement.deinit when a control statement is expected to fail.
    fn execTransactionControl(conn: *sqlite.Db, statement: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = sqlite.c.sqlite3_exec(conn.db, statement.ptr, null, null, &err_msg);
        defer if (err_msg != null) sqlite.c.sqlite3_free(err_msg);
        if (rc != sqlite.c.SQLITE_OK) {
            if (err_msg != null) {
                std.log.debug("SQLite transaction control failed for {s}: {s}", .{ statement, std.mem.span(err_msg) });
            }
            return errors.classifyStepError(conn);
        }
    }

    fn getDocumentHelper(
        self: *Writer,
        table_index: usize,
        namespace_id: i64,
        id: DocId,
        sql_cache: *std.AutoHashMap(usize, []const u8),
    ) !?TypedRow {
        const table_metadata = self.schema.getTableByIndex(table_index) orelse return null;
        const sql_str = if (sql_cache.get(table_index)) |s| s else blk: {
            const s = try sql.buildSelectDocumentSql(self.allocator, table_metadata);
            errdefer self.allocator.free(s);
            try sql_cache.put(table_index, s);
            break :blk s;
        };
        var mstmt = try self.stmt_cache.acquire(self.allocator, &self.conn, sql_str);
        defer mstmt.release();
        return reader.execSelectDocumentTyped(self.allocator, &self.conn, mstmt.stmt, id, namespace_id, table_metadata);
    }

    fn pushOwnedChange(
        allocator: Allocator,
        pending_changes: *std.ArrayListUnmanaged(OwnedRowChange),
        namespace_id: i64,
        table_index: usize,
        op: OwnedRowChange.Operation,
        old_row: ?TypedRow,
        new_row: ?TypedRow,
    ) !void {
        try pending_changes.append(allocator, .{
            .namespace_id = namespace_id,
            .table_index = table_index,
            .operation = op,
            .old_row = old_row,
            .new_row = new_row,
        });
    }

    fn flushPendingChanges(
        self: *Writer,
        pending_changes: *std.ArrayListUnmanaged(OwnedRowChange),
    ) void {
        var dispatcher_woken = false;
        for (pending_changes.items) |raw_change| {
            var change = raw_change;
            self.change_buffer.push(change) catch |err| {
                std.log.err("Failed to push to change_buffer: {}", .{err});
                change.deinit(self.allocator);
                continue;
            };
            dispatcher_woken = true;
        }
        pending_changes.clearRetainingCapacity();

        if (dispatcher_woken) {
            self.notifyChanges();
        }
    }

    fn executeBatch(
        self: *Writer,
        ops: []const WriteOp,
        pending_changes: *std.ArrayListUnmanaged(OwnedRowChange),
    ) !void {
        self.conn.exec("BEGIN TRANSACTION", .{}, .{}) catch |err| {
            const classified_err = errors.classifyError(err);
            errors.logDatabaseError("executeBatch BEGIN", classified_err, "");
            return classified_err;
        };
        self.markTransactionActive();

        errdefer {
            execTransactionControl(&self.conn, "ROLLBACK") catch |rollback_err| {
                const classified_err = errors.classifyError(rollback_err);
                errors.logDatabaseError("executeBatch ROLLBACK", classified_err, "");
            };
            self.markTransactionInactive();
        }
        var sql_cache = std.AutoHashMap(usize, []const u8).init(self.allocator);
        defer {
            var it = sql_cache.valueIterator();
            while (it.next()) |sql_str| self.allocator.free(sql_str.*);
            sql_cache.deinit();
        }

        for (ops) |op| {
            switch (op) {
                .upsert => |iop| {
                    const table_metadata = self.schema.getTableByIndex(iop.table_index) orelse return StorageError.UnknownTable;
                    const namespace_id = if (table_metadata.namespaced) iop.namespace_id else schema.global_namespace_id;
                    const owner_doc_id = if (table_metadata.is_users_table) iop.id else iop.owner_doc_id;
                    var old_row: ?TypedRow = null;
                    const capture_res = getDocumentHelper(self, iop.table_index, namespace_id, iop.id, &sql_cache);
                    if (capture_res) |orow| {
                        old_row = orow;
                    } else |err| {
                        std.log.err("Failed to capture old state (pre-UPSERT) for table index {d}: {}", .{ iop.table_index, err });
                    }
                    const maybe_new_row = executeUpsert(self, iop, namespace_id, owner_doc_id, table_metadata) catch |err| {
                        if (old_row) |r| r.deinit(self.allocator);
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatch UPSERT", classified_err, table_metadata.name);
                        return classified_err;
                    };

                    if (maybe_new_row) |new_row| {
                        const op_type: OwnedRowChange.Operation = if (old_row == null) .insert else .update;
                        pushOwnedChange(self.allocator, pending_changes, namespace_id, iop.table_index, op_type, old_row, new_row) catch |err| {
                            const classified_err = errors.classifyError(err);
                            std.log.err("Failed to capture row change: {}", .{classified_err});
                            if (old_row) |r| r.deinit(self.allocator);
                            var r = new_row;
                            r.deinit(self.allocator);
                            return classified_err;
                        };
                    } else {
                        // The upsert is guarded by namespace_id. A missing RETURNING row means
                        // the id already exists in another namespace, which we surface as a
                        // dropped write rather than silently mutating hidden data.
                        var id_hex_buf: [32]u8 = undefined;
                        std.log.debug("UPSERT for table index {d}/{s} conflicted with a different namespace", .{ iop.table_index, doc_id.hexSlice(iop.id, &id_hex_buf) });
                        if (old_row) |r| r.deinit(self.allocator);
                        continue;
                    }
                },
                .delete => |dop| {
                    const table_metadata = self.schema.getTableByIndex(dop.table_index) orelse return StorageError.UnknownTable;
                    const namespace_id = if (table_metadata.namespaced) dop.namespace_id else schema.global_namespace_id;
                    const maybe_old_row = executeDelete(self, dop, namespace_id, table_metadata) catch |err| {
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatch DELETE", classified_err, table_metadata.name);
                        return classified_err;
                    };

                    // For DELETE, the RETURNING * result IS the old row.
                    if (maybe_old_row) |old_row| {
                        pushOwnedChange(self.allocator, pending_changes, namespace_id, dop.table_index, .delete, old_row, null) catch |err| {
                            const classified_err = errors.classifyError(err);
                            std.log.err("Failed to capture row change: {}", .{classified_err});
                            var r = old_row;
                            r.deinit(self.allocator);
                            return classified_err;
                        };
                    } else {
                        // If RETURNING * is empty, the row did not exist or was already deleted.
                        // This is a valid no-op state; we skip notifications for non-existent documents.
                        var id_hex_buf: [32]u8 = undefined;
                        std.log.debug("DELETE for table index {d}/{s}: no row found (already deleted)", .{ dop.table_index, doc_id.hexSlice(dop.id, &id_hex_buf) });
                    }
                },
                else => unreachable,
            }
        }

        execTransactionControl(&self.conn, "COMMIT") catch |err| {
            const classified_err = errors.classifyError(err);
            errors.logDatabaseError("executeBatch COMMIT", classified_err, "");
            return classified_err;
        };
        self.markTransactionInactive();
    }

    pub fn flushBatch(
        self: *Writer,
        batch: *std.ArrayListUnmanaged(WriteOp),
        last_batch_time: *i64,
    ) void {
        const batch_len = batch.items.len;
        std.log.debug("flushBatch: flushing {} ops", .{batch_len});

        var eviction_keys = std.ArrayListUnmanaged(MetadataCacheKey).empty;
        defer eviction_keys.deinit(self.allocator);
        eviction_keys.ensureTotalCapacity(self.allocator, batch_len) catch |err| {
            const classified_err = errors.classifyError(err);
            std.log.err("Failed to allocate eviction keys for batch: {}", .{classified_err});
            for (batch.items) |op| {
                if (op.getCompletionSignal()) |sig| sig.signal(classified_err);
                op.deinit(self.allocator);
            }
            batch.clearRetainingCapacity();
            self.endOp(batch_len);
            self.wakeFlushWaiters();
            last_batch_time.* = std.time.milliTimestamp();
            return;
        };
        for (batch.items) |op| {
            // SAFETY: initialized below in the switch statement
            var table_index: usize = undefined;
            // SAFETY: initialized below in the switch statement
            var id: DocId = undefined;
            // SAFETY: initialized below in the switch statement
            var namespace_id: i64 = undefined;
            const has_affected = switch (op) {
                .upsert => |o| blk: {
                    table_index = o.table_index;
                    id = o.id;
                    namespace_id = o.namespace_id;
                    break :blk true;
                },
                .delete => |o| blk: {
                    table_index = o.table_index;
                    id = o.id;
                    namespace_id = o.namespace_id;
                    break :blk true;
                },
                else => false,
            };
            if (has_affected) {
                const table_metadata = self.schema.getTableByIndex(table_index) orelse continue;
                const key = reader.getCacheKey(table_metadata, namespace_id, id);
                eviction_keys.appendAssumeCapacity(key);
            }
        }

        var pending_changes = std.ArrayListUnmanaged(OwnedRowChange).empty;
        defer {
            for (pending_changes.items) |*c| c.deinit(self.allocator);
            pending_changes.deinit(self.allocator);
        }

        const result = executeBatch(self, batch.items, &pending_changes);
        if (result) |_| {
            self.bumpVersion();

            if (eviction_keys.items.len > 0) {
                self.metadata_cache.bulkEvict(eviction_keys.items);
            }

            for (batch.items) |op| {
                if (op.getCompletionSignal()) |sig| sig.signal(null);
                op.deinit(self.allocator);
            }

            flushPendingChanges(self, &pending_changes);
        } else |err| {
            const classified_err = errors.classifyError(err);
            std.log.debug("Failed to execute batch, transaction rolled back: {}", .{classified_err});
            for (batch.items) |op| {
                if (op.getCompletionSignal()) |sig| sig.signal(classified_err);
                op.deinit(self.allocator);
            }
        }
        batch.clearRetainingCapacity();
        self.endOp(batch_len);
        self.wakeFlushWaiters();
        last_batch_time.* = std.time.milliTimestamp();
    }

    fn writeThreadLoop(self: *Writer) void {
        writeThreadLoopImpl(self) catch |err| {
            std.log.err("writeThreadLoop fatal error: {}", .{err});
        };
    }

    fn waitForWriteSignal(self: *Writer, timeout_ns: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutdown_requested.load(.acquire) or self.queue.hasItems()) {
            return;
        }

        if (timeout_ns) |ns| {
            self.work_cond.timedWait(&self.mutex, ns) catch |err| {
                if (err != error.Timeout) {
                    std.log.err("write_cond.timedWait failed: {}", .{err});
                }
            };
        } else {
            self.work_cond.wait(&self.mutex);
        }
    }

    fn writeThreadLoopImpl(self: *Writer) !void {
        // Signal that the write thread is up and running
        self.is_ready.store(true, .release);
        self.mutex.lock();
        self.work_cond.signal();
        self.mutex.unlock();

        const batch_size = if (self.performance_config.batch_writes)
            self.performance_config.batch_size
        else
            1;
        const batch_timeout_ms: i64 = if (self.performance_config.batch_writes)
            @intCast(self.performance_config.batch_timeout)
        else
            0;

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
                if (self.queue.pop()) |op| {
                    switch (op) {
                        .upsert, .delete => {
                            batch.append(self.allocator, op) catch |err| {
                                std.log.err("Failed to append to batch: {}", .{err});
                                op.deinit(self.allocator);
                                self.endOp(1);
                                self.wakeFlushWaiters();
                                continue;
                            };
                        },
                        .batch => |bop| {
                            if (batch.items.len > 0) {
                                flushBatch(self, &batch, &last_batch_time);
                            }
                            executeBatchOp(self, bop, &last_batch_time);
                        },
                        .upsert_namespace => |nop| {
                            if (batch.items.len > 0) {
                                flushBatch(self, &batch, &last_batch_time);
                            }
                            if (sql.resolveNamespaceId(self.allocator, &self.conn, &self.stmt_cache, nop.namespace)) |namespace_id| {
                                nop.result.* = namespace_id;
                                nop.completion_signal.signal(null);
                            } else |err| {
                                nop.completion_signal.signal(errors.classifyError(err));
                            }
                            op.deinit(self.allocator);
                            self.endOp(1);
                            self.wakeFlushWaiters();
                        },
                        .checkpoint => |cop| {
                            if (batch.items.len > 0) {
                                flushBatch(self, &batch, &last_batch_time);
                            }
                            if (connection.internalExecuteCheckpoint(&self.conn, self.allocator, self.db_path, self.in_memory, cop.mode)) |stats| {
                                cop.completion_signal.signalWithResult(stats);
                            } else |err| {
                                cop.completion_signal.signal(errors.classifyError(err));
                            }
                            op.deinit(self.allocator);
                            self.endOp(1);
                            self.wakeFlushWaiters();
                        },
                    }
                } else {
                    break;
                }
            }

            const now = std.time.milliTimestamp();
            const time_since_last = now - last_batch_time;

            const should_flush = batch.items.len >= batch_size or
                (batch.items.len > 0 and time_since_last >= batch_timeout_ms);

            if (should_flush) {
                flushBatch(self, &batch, &last_batch_time);
            } else {
                const timeout_ns: ?u64 = if (batch.items.len > 0)
                    @as(u64, @intCast(batch_timeout_ms - time_since_last)) * std.time.ns_per_ms
                else
                    null;
                waitForWriteSignal(self, timeout_ns);
            }
        }

        // Drain
        while (self.queue.pop()) |op| {
            switch (op) {
                .upsert, .delete => {
                    batch.append(self.allocator, op) catch {
                        op.deinit(self.allocator);
                        self.endOp(1);
                        self.wakeFlushWaiters();
                    };
                },
                .batch => |bop| {
                    if (batch.items.len > 0) {
                        flushBatch(self, &batch, &last_batch_time);
                    }
                    executeBatchOp(self, bop, &last_batch_time);
                },
                else => {
                    if (op.getCompletionSignal()) |sig| sig.signal(StorageError.InvalidOperation);
                    op.deinit(self.allocator);
                    self.endOp(1);
                    self.wakeFlushWaiters();
                },
            }
        }

        if (batch.items.len > 0) {
            flushBatch(self, &batch, &last_batch_time);
        }
    }

    pub fn executeBatchOp(
        self: *Writer,
        bop: anytype,
        last_batch_time: *i64,
    ) void {
        const entries = bop.entries;
        var tx_started = false;
        var final_err: ?anyerror = null;
        defer {
            if (tx_started) {
                execTransactionControl(&self.conn, "ROLLBACK") catch |rollback_err| {
                    errors.logDatabaseError("executeBatchOp ROLLBACK", errors.classifyError(rollback_err), "");
                };
                self.markTransactionInactive();
            }

            if (bop.completion_signal) |sig| sig.signal(final_err);

            for (entries) |entry| entry.deinit(self.allocator);
            self.allocator.free(entries);

            self.endOp(1);
            self.wakeFlushWaiters();
            last_batch_time.* = std.time.milliTimestamp();
        }

        // 1. Build eviction keys from all entries
        var eviction_keys = std.ArrayListUnmanaged(MetadataCacheKey).empty;
        defer eviction_keys.deinit(self.allocator);
        eviction_keys.ensureTotalCapacity(self.allocator, entries.len) catch |err| {
            const classified_err = errors.classifyError(err);
            std.log.err("Failed to allocate eviction keys for batch op: {}", .{classified_err});
            final_err = classified_err;
            return;
        };
        for (entries) |entry| {
            const table_metadata = self.schema.getTableByIndex(entry.table_index) orelse continue;
            const key = reader.getCacheKey(table_metadata, entry.namespace_id, entry.id);
            eviction_keys.appendAssumeCapacity(key);
        }
        // 2. Execute all entries in a single transaction
        var pending_changes = std.ArrayListUnmanaged(OwnedRowChange).empty;
        defer {
            for (pending_changes.items) |*c| c.deinit(self.allocator);
            pending_changes.deinit(self.allocator);
        }

        execTransactionControl(&self.conn, "BEGIN TRANSACTION") catch |err| {
            const classified_err = errors.classifyError(err);
            errors.logDatabaseError("executeBatchOp BEGIN", classified_err, "");
            final_err = classified_err;
            return;
        };
        tx_started = true;
        self.markTransactionActive();

        var sql_cache = std.AutoHashMap(usize, []const u8).init(self.allocator);
        defer {
            var it = sql_cache.valueIterator();
            while (it.next()) |sql_str| self.allocator.free(sql_str.*);
            sql_cache.deinit();
        }

        for (entries) |entry| {
            const table_metadata = self.schema.getTableByIndex(entry.table_index) orelse {
                final_err = StorageError.UnknownTable;
                std.log.debug("Batch entry references unknown table index {d}", .{entry.table_index});
                break;
            };
            const namespace_id = if (table_metadata.namespaced) entry.namespace_id else schema.global_namespace_id;

            switch (entry.kind) {
                .upsert => {
                    const owner_doc_id = if (table_metadata.is_users_table) entry.id else entry.owner_doc_id;
                    var old_row: ?TypedRow = null;
                    if (getDocumentHelper(self, entry.table_index, namespace_id, entry.id, &sql_cache)) |orow| {
                        old_row = orow;
                    } else |err| {
                        std.log.err("Failed to capture old state (pre-UPSERT) for table index {d}: {}", .{ entry.table_index, err });
                    }

                    if (executeUpsert(self, entry, namespace_id, owner_doc_id, table_metadata)) |maybe_new_row| {
                        if (maybe_new_row) |new_row| {
                            const op_type: OwnedRowChange.Operation = if (old_row == null) .insert else .update;
                            if (pushOwnedChange(self.allocator, &pending_changes, namespace_id, entry.table_index, op_type, old_row, new_row)) |_| {
                                // success
                            } else |err| {
                                const classified_err = errors.classifyError(err);
                                std.log.err("Failed to capture row change: {}", .{classified_err});
                                if (old_row) |r| r.deinit(self.allocator);
                                var r = new_row;
                                r.deinit(self.allocator);
                                final_err = classified_err;
                                break;
                            }
                        } else {
                            var id_hex_buf: [32]u8 = undefined;
                            std.log.debug("UPSERT for table index {d}/{s} conflicted with a different namespace", .{ entry.table_index, doc_id.hexSlice(entry.id, &id_hex_buf) });
                            if (old_row) |r| r.deinit(self.allocator);
                        }
                    } else |err| {
                        if (old_row) |r| r.deinit(self.allocator);
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatchOp UPSERT", classified_err, table_metadata.name);
                        final_err = classified_err;
                        break;
                    }
                },
                .delete => {
                    if (executeDelete(self, entry, namespace_id, table_metadata)) |maybe_old_row| {
                        if (maybe_old_row) |old_row| {
                            if (pushOwnedChange(self.allocator, &pending_changes, namespace_id, entry.table_index, .delete, old_row, null)) |_| {
                                // success
                            } else |err| {
                                const classified_err = errors.classifyError(err);
                                std.log.err("Failed to capture row change: {}", .{classified_err});
                                var r = old_row;
                                r.deinit(self.allocator);
                                final_err = classified_err;
                                break;
                            }
                        } else {
                            var id_hex_buf: [32]u8 = undefined;
                            std.log.debug("DELETE for table index {d}/{s}: no row found (already deleted)", .{ entry.table_index, doc_id.hexSlice(entry.id, &id_hex_buf) });
                        }
                    } else |err| {
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatchOp DELETE", classified_err, table_metadata.name);
                        final_err = classified_err;
                        break;
                    }
                },
            }
        }

        if (final_err == null) {
            if (execTransactionControl(&self.conn, "COMMIT")) |_| {
                tx_started = false;
                self.markTransactionInactive();
                self.bumpVersion();

                if (eviction_keys.items.len > 0) {
                    self.metadata_cache.bulkEvict(eviction_keys.items);
                }

                flushPendingChanges(self, &pending_changes);
            } else |err| {
                const classified_err = errors.classifyError(err);
                errors.logDatabaseError("executeBatchOp COMMIT", classified_err, "");
                final_err = classified_err;
            }
        }
    }

    fn executeUpsert(
        self: *Writer,
        op: anytype,
        namespace_id: i64,
        owner_id: DocId,
        table_metadata: *const schema.Table,
    ) !?TypedRow {
        const sql_str = op.sql;
        var mstmt = try self.stmt_cache.acquire(self.allocator, &self.conn, sql_str);
        defer mstmt.release();
        const stmt = mstmt.stmt;

        var bind_idx: c_int = 1;
        const id_bytes = doc_id.toBytes(op.id);
        if (sql.bindBlobTransient(stmt, bind_idx, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        const owner_id_bytes = doc_id.toBytes(owner_id);
        if (sql.bindBlobTransient(stmt, bind_idx, &owner_id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        if (table_metadata.is_users_table) {
            var external_id_buf: [32]u8 = undefined;
            const external_id = doc_id.hexSlice(op.id, &external_id_buf);
            if (sql.bindTextTransient(stmt, bind_idx, external_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
            bind_idx += 1;
        }

        if (@typeInfo(@TypeOf(op.values)) == .optional) {
            if (op.values) |vals| {
                for (vals) |val| {
                    try sql.bindTypedValue(val, &self.conn, stmt, bind_idx, self.allocator);
                    bind_idx += 1;
                }
            }
        } else {
            for (op.values) |val| {
                try sql.bindTypedValue(val, &self.conn, stmt, bind_idx, self.allocator);
                bind_idx += 1;
            }
        }

        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;

        const rc = sqlite.c.sqlite3_step(stmt);
        if (rc == sqlite.c.SQLITE_ROW) {
            return try reader.decodeTypedRow(self.allocator, stmt, table_metadata);
        }
        if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(&self.conn);
        return null;
    }

    fn executeDelete(
        self: *Writer,
        op: anytype,
        namespace_id: i64,
        table_metadata: *const schema.Table,
    ) !?TypedRow {
        const sql_str = op.sql;
        var mstmt = try self.stmt_cache.acquire(self.allocator, &self.conn, sql_str);
        defer mstmt.release();
        const stmt = mstmt.stmt;

        const id_bytes = doc_id.toBytes(op.id);
        if (sql.bindBlobTransient(stmt, 1, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        if (sqlite.c.sqlite3_bind_int64(stmt, 2, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);

        const rc = sqlite.c.sqlite3_step(stmt);
        if (rc == sqlite.c.SQLITE_ROW) {
            return try reader.decodeTypedRow(self.allocator, stmt, table_metadata);
        }
        if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(&self.conn);
        return null;
    }
};
