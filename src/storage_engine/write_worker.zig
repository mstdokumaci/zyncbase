const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const reader = @import("reader.zig");
const connection = @import("connection.zig");
const errors = @import("errors.zig");
const typed = @import("../typed.zig");
const schema = @import("../schema.zig");
const sql = @import("sql.zig");
const storage_cache = @import("cache.zig");
const write_queue = @import("write_queue.zig");
const change_queue_mod = @import("../change_queue.zig");
const OwnedRecordChange = change_queue_mod.OwnedRecordChange;
const ChangeQueue = change_queue_mod.ChangeQueue;
const SessionResolutionBuffer = @import("../connection.zig").SessionResolutionBuffer;
const SessionResolutionResult = @import("../connection.zig").SessionResolutionResult;
const wire = @import("../wire.zig");
const send_queue_type = @import("../send_queue.zig").send_queue;
const PerformanceConfig = @import("../config_loader.zig").Config.PerformanceConfig;
const managedThread = @import("../threading/managed_thread.zig").managedThread;
const Notifier = @import("../threading/notifier.zig").Notifier;
const WaitGroup = @import("../threading/wait_group.zig").WaitGroup;

const DocId = typed.DocId;
const MetadataCacheKey = storage_cache.MetadataCacheKey;
const Record = typed.Record;
const WriteOp = write_queue.WriteOp;
const write_queue_type = write_queue.write_queue_type;
const StatementCache = sql.StatementCache;
const StorageError = errors.StorageError;

pub const WriteWorker = struct {
    allocator: Allocator,
    conn: sqlite.Db,
    stmt_cache: StatementCache,
    version: std.atomic.Value(u64),
    thread: managedThread(WriteWorker),
    flush_wg: WaitGroup,
    change_queue: ?*ChangeQueue,
    session_resolution_buffer: SessionResolutionBuffer,
    send_queue: ?*send_queue_type,
    notifier: Notifier,
    metadata_cache: *storage_cache.metadata_cache_type,
    namespace_cache: *storage_cache.namespace_cache_type,
    identity_cache: *storage_cache.identity_cache_type,
    pk_sets: []@import("pk_set.zig").PkSet,
    schema: *const schema.Schema,
    is_healthy: std.atomic.Value(bool),
    queue: write_queue_type,
    performance_config: PerformanceConfig,
    db_path: [:0]const u8,
    in_memory: bool,

    pub fn beginOp(self: *WriteWorker) void {
        self.flush_wg.add(1);
    }

    pub fn endOp(self: *WriteWorker, count: usize) void {
        self.flush_wg.done(count);
    }

    pub fn enqueueOp(self: *WriteWorker, op: WriteOp) !void {
        self.thread.mutex.lock();
        defer self.thread.mutex.unlock();
        if (!self.is_healthy.load(.acquire)) {
            return StorageError.EngineUnhealthy;
        }
        self.beginOp();
        self.queue.push(op) catch |err| {
            self.endOp(1);
            return err;
        };
        self.thread.signal();
    }

    pub fn isHealthy(self: *const WriteWorker) bool {
        return self.is_healthy.load(.acquire);
    }

    pub fn pendingOpCount(self: *const WriteWorker) usize {
        return self.flush_wg.value();
    }

    pub fn bumpVersion(self: *WriteWorker) void {
        _ = self.version.fetchAdd(1, .acq_rel);
    }

    pub fn snapshotVersion(self: *const WriteWorker) u64 {
        return self.version.load(.acquire);
    }

    pub fn notifyChanges(self: *WriteWorker) void {
        self.notifier.notify();
    }

    fn pushWriteOutcome(self: *WriteWorker, conn_id: u64, write_id: [16]u8, err: ?anyerror, batch_index: ?usize) void { // zwanzig-disable-line: unused-parameter
        const sq = self.send_queue orelse {
            std.log.warn("WriteWorker: send_queue not set, dropping write outcome for conn_id={d}", .{conn_id});
            return;
        };

        const msg = if (err) |e| blk: {
            const wire_err = wire.getWireError(e);
            break :blk wire.encodeWriteError(self.allocator, write_id, wire_err, batch_index) catch |encode_err| {
                std.log.err("WriteWorker: failed to encode WriteError: {}", .{encode_err});
                return;
            };
        } else blk: {
            break :blk wire.encodeWriteCommitted(self.allocator, write_id) catch |encode_err| {
                std.log.err("WriteWorker: failed to encode WriteCommitted: {}", .{encode_err});
                return;
            };
        };

        sq.push(.{ .conn_id = conn_id, .data = msg }) catch |push_err| {
            std.log.err("WriteWorker: failed to push write outcome to SendQueue: {}", .{push_err});
            self.allocator.free(msg);
            return;
        };
    }

    pub fn wakeFlushWaiters(self: *WriteWorker) void {
        self.flush_wg.broadcast();
    }

    pub fn spawn(self: *WriteWorker) !void {
        try self.thread.spawn(writeThreadLoop, self);
    }

    pub fn stop(self: *WriteWorker) void {
        self.thread.stop();
    }

    pub fn flushPendingWrites(self: *WriteWorker) void {
        std.log.debug("flushPendingWrites: count={}", .{self.pendingOpCount()});
        self.flush_wg.wait();
    }

    pub fn setupConn(self: *WriteWorker) *sqlite.Db {
        return &self.conn;
    }

    pub fn deinit(self: *WriteWorker) void {
        self.stmt_cache.deinit(self.allocator);
        self.conn.deinit();
        self.allocator.free(self.db_path);
        while (self.queue.pop()) |op| {
            op.deinit(self.allocator);
        }
        self.queue.deinit();
        self.session_resolution_buffer.deinit();
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
        self: *WriteWorker,
        table_index: usize,
        namespace_id: i64,
        id: DocId,
        sql_cache: *std.AutoHashMap(usize, []const u8),
    ) !?Record {
        const table_metadata = self.schema.tableByIndex(table_index) orelse return null;
        const sql_str = if (sql_cache.get(table_index)) |s| s else blk: {
            const s = try sql.buildSelectDocumentSql(self.allocator, table_metadata, null);
            errdefer self.allocator.free(s);
            try sql_cache.put(table_index, s);
            break :blk s;
        };
        var mstmt = try self.stmt_cache.acquire(self.allocator, &self.conn, sql_str);
        defer mstmt.release();
        return reader.execSelectDocument(self.allocator, &self.conn, mstmt.stmt, id, namespace_id, table_metadata, null);
    }

    fn pushOwnedChange(
        allocator: Allocator,
        pending_changes: *std.ArrayListUnmanaged(OwnedRecordChange),
        namespace_id: i64,
        table_index: usize,
        doc_id: DocId,
        op: OwnedRecordChange.Operation,
        old_record: ?Record,
        new_record: ?Record,
    ) !void {
        try pending_changes.append(allocator, .{
            .namespace_id = namespace_id,
            .table_index = table_index,
            .doc_id = doc_id,
            .operation = op,
            .old_record = old_record,
            .new_record = new_record,
        });
    }

    fn flushPendingChanges(
        self: *WriteWorker,
        pending_changes: *std.ArrayListUnmanaged(OwnedRecordChange),
    ) void {
        var changes_pushed = false;
        for (pending_changes.items) |raw_change| {
            var change = raw_change;
            if (self.change_queue) |cq| {
                cq.push(change, self.allocator);
                changes_pushed = true;
            } else {
                change.deinit(self.allocator);
            }
        }
        pending_changes.clearRetainingCapacity();

        if (changes_pushed) {
            self.notifyChanges();
        }
    }

    fn executeBatch(
        self: *WriteWorker,
        ops: []const WriteOp,
        pending_changes: *std.ArrayListUnmanaged(OwnedRecordChange),
        guard_rejected: *std.ArrayListUnmanaged(usize),
    ) !void {
        execTransactionControl(&self.conn, "BEGIN TRANSACTION") catch |err| {
            const classified_err = errors.classifyError(err);
            errors.logDatabaseError("executeBatch BEGIN", classified_err, "");
            return classified_err;
        };
        errdefer {
            execTransactionControl(&self.conn, "ROLLBACK") catch |rollback_err| {
                const classified_err = errors.classifyError(rollback_err);
                errors.logDatabaseError("executeBatch ROLLBACK", classified_err, "");
            };
        }
        var sql_cache = std.AutoHashMap(usize, []const u8).init(self.allocator);
        defer {
            var it = sql_cache.valueIterator();
            while (it.next()) |sql_str| self.allocator.free(sql_str.*);
            sql_cache.deinit();
        }

        var pk_inserts = std.ArrayListUnmanaged(struct { table_index: usize, id: DocId }).empty;
        defer pk_inserts.deinit(self.allocator);
        var pk_deletes = std.ArrayListUnmanaged(struct { table_index: usize, id: DocId }).empty;
        defer pk_deletes.deinit(self.allocator);

        for (ops, 0..) |op, op_idx| {
            switch (op) {
                .upsert => |iop| {
                    const table_metadata = self.schema.tableByIndex(iop.table_index) orelse return StorageError.UnknownTable;
                    const namespace_id = if (table_metadata.namespaced) iop.namespace_id else schema.global_namespace_id;
                    const owner_doc_id = if (table_metadata.is_users_table) iop.id else iop.owner_doc_id;
                    var old_record: ?Record = null;
                    const capture_res = getDocumentHelper(self, iop.table_index, namespace_id, iop.id, &sql_cache);
                    if (capture_res) |record| {
                        old_record = record;
                    } else |err| {
                        std.log.err("Failed to capture old state (pre-UPSERT) for table index {d}: {}", .{ iop.table_index, err });
                    }
                    const maybe_new_record = executeUpsert(self, iop, namespace_id, owner_doc_id, table_metadata) catch |err| {
                        if (old_record) |r| r.deinit(self.allocator);
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatch UPSERT", classified_err, table_metadata.name);
                        return classified_err;
                    };

                    if (maybe_new_record) |new_record| {
                        const op_type: OwnedRecordChange.Operation = if (old_record == null) .insert else .update;
                        if (old_record == null) {
                            pk_inserts.append(self.allocator, .{ .table_index = iop.table_index, .id = iop.id }) catch |err| {
                                std.log.warn("Failed to track pk_insert for table {d}: {}", .{ iop.table_index, err });
                            };
                        }
                        pushOwnedChange(self.allocator, pending_changes, namespace_id, iop.table_index, iop.id, op_type, old_record, new_record) catch |err| {
                            const classified_err = errors.classifyError(err);
                            std.log.err("Failed to capture row change: {}", .{classified_err});
                            if (old_record) |r| r.deinit(self.allocator);
                            var r = new_record;
                            r.deinit(self.allocator);
                            return classified_err;
                        };
                    } else {
                        if (old_record != null and iop.guard_values != null and op.getWriteAckInfo() != null) {
                            guard_rejected.append(self.allocator, op_idx) catch |err| {
                                std.log.err("Failed to track guard rejection: {}", .{err});
                            };
                        } else {
                            var id_hex_buf: [32]u8 = undefined;
                            std.log.debug("UPSERT for table index {d}/{s} conflicted with a different namespace", .{ iop.table_index, typed.docIdHexSlice(iop.id, &id_hex_buf) });
                        }
                        if (old_record) |r| r.deinit(self.allocator);
                    }
                },
                .update => |uop| {
                    const table_metadata = self.schema.tableByIndex(uop.table_index) orelse return StorageError.UnknownTable;
                    const namespace_id = if (table_metadata.namespaced) uop.namespace_id else schema.global_namespace_id;
                    var old_record: ?Record = null;
                    const capture_res = getDocumentHelper(self, uop.table_index, namespace_id, uop.id, &sql_cache);
                    if (capture_res) |record| {
                        old_record = record;
                    } else |err| {
                        std.log.err("Failed to capture old state (pre-UPDATE) for table index {d}: {}", .{ uop.table_index, err });
                    }
                    const maybe_new_record = executeUpdate(self, uop, namespace_id, table_metadata) catch |err| {
                        if (old_record) |r| r.deinit(self.allocator);
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatch UPDATE", classified_err, table_metadata.name);
                        return classified_err;
                    };

                    if (maybe_new_record) |new_record| {
                        pushOwnedChange(self.allocator, pending_changes, namespace_id, uop.table_index, uop.id, .update, old_record, new_record) catch |err| {
                            const classified_err = errors.classifyError(err);
                            std.log.err("Failed to capture row change: {}", .{classified_err});
                            if (old_record) |r| r.deinit(self.allocator);
                            var r = new_record;
                            r.deinit(self.allocator);
                            return classified_err;
                        };
                    } else {
                        if (old_record != null and uop.guard_values != null and op.getWriteAckInfo() != null) {
                            guard_rejected.append(self.allocator, op_idx) catch |err| {
                                std.log.err("Failed to track guard rejection: {}", .{err});
                            };
                        } else {
                            var id_hex_buf: [32]u8 = undefined;
                            std.log.debug("UPDATE for table index {d}/{s} had no matching row", .{ uop.table_index, typed.docIdHexSlice(uop.id, &id_hex_buf) });
                        }
                        if (old_record) |r| r.deinit(self.allocator);
                    }
                },
                .delete => |dop| {
                    const table_metadata = self.schema.tableByIndex(dop.table_index) orelse return StorageError.UnknownTable;
                    const namespace_id = if (table_metadata.namespaced) dop.namespace_id else schema.global_namespace_id;
                    const maybe_old_record = executeDelete(self, dop, namespace_id, table_metadata) catch |err| {
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatch DELETE", classified_err, table_metadata.name);
                        return classified_err;
                    };

                    // For DELETE, the RETURNING * result IS the old record.
                    if (maybe_old_record) |old_record| {
                        pk_deletes.append(self.allocator, .{ .table_index = dop.table_index, .id = dop.id }) catch |err| {
                            std.log.warn("Failed to track pk_delete for table {d}: {}", .{ dop.table_index, err });
                        };
                        pushOwnedChange(self.allocator, pending_changes, namespace_id, dop.table_index, dop.id, .delete, old_record, null) catch |err| {
                            const classified_err = errors.classifyError(err);
                            std.log.err("Failed to capture row change: {}", .{classified_err});
                            var r = old_record;
                            r.deinit(self.allocator);
                            return classified_err;
                        };
                    } else {
                        if (dop.guard_values != null and op.getWriteAckInfo() != null) {
                            const exists = getDocumentHelper(self, dop.table_index, namespace_id, dop.id, &sql_cache) catch |err| blk: {
                                std.log.err("Delete guard post-check failed: {}", .{err});
                                break :blk null;
                            };
                            if (exists != null) {
                                exists.?.deinit(self.allocator);
                                guard_rejected.append(self.allocator, op_idx) catch |err| {
                                    std.log.err("Failed to track guard rejection: {}", .{err});
                                };
                            }
                        } else {
                            var id_hex_buf: [32]u8 = undefined;
                            std.log.debug("DELETE for table index {d}/{s}: no row found (already deleted)", .{ dop.table_index, typed.docIdHexSlice(dop.id, &id_hex_buf) });
                        }
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

        for (pk_inserts.items) |item| {
            if (item.table_index < self.pk_sets.len) {
                self.pk_sets[item.table_index].insert(self.allocator, item.id);
            }
        }
        for (pk_deletes.items) |item| {
            if (item.table_index < self.pk_sets.len) {
                self.pk_sets[item.table_index].remove(item.id);
            }
        }
    }

    pub fn flushBatch(
        self: *WriteWorker,
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
                .update => |o| blk: {
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
                const table_metadata = self.schema.tableByIndex(table_index) orelse continue;
                const key = reader.getCacheKey(table_metadata, namespace_id, id);
                eviction_keys.appendAssumeCapacity(key);
            }
        }

        var pending_changes = std.ArrayListUnmanaged(OwnedRecordChange).empty;
        defer {
            for (pending_changes.items) |*c| c.deinit(self.allocator);
            pending_changes.deinit(self.allocator);
        }

        var guard_rejected = std.ArrayListUnmanaged(usize).empty;
        defer guard_rejected.deinit(self.allocator);

        const result = executeBatch(self, batch.items, &pending_changes, &guard_rejected);
        if (result) |_| {
            self.bumpVersion();

            if (eviction_keys.items.len > 0) {
                self.metadata_cache.bulkEvict(eviction_keys.items);
            }

            var pushed_outcome = false;
            for (batch.items, 0..) |op, op_idx| {
                if (op.getWriteAckInfo()) |info| {
                    const is_guard_rejected = for (guard_rejected.items) |idx| {
                        if (idx == op_idx) break true;
                    } else false;

                    const outcome_err: ?anyerror = if (is_guard_rejected) error.PermissionDenied else null;

                    self.pushWriteOutcome(info.conn_id, info.write_id, outcome_err, null);
                    pushed_outcome = true;
                }
                if (op.getCompletionSignal()) |sig| sig.signal(null);
                op.deinit(self.allocator);
            }
            if (pushed_outcome) {
                self.notifyChanges();
            }

            flushPendingChanges(self, &pending_changes);
        } else |err| {
            const classified_err = errors.classifyError(err);
            std.log.debug("Failed to execute batch, transaction rolled back: {}", .{classified_err});
            var pushed_outcome = false;
            for (batch.items) |op| {
                if (op.getWriteAckInfo()) |info| {
                    self.pushWriteOutcome(info.conn_id, info.write_id, classified_err, null);
                    pushed_outcome = true;
                }
                if (op.getCompletionSignal()) |sig| sig.signal(classified_err);
                op.deinit(self.allocator);
            }
            if (pushed_outcome) {
                self.notifyChanges();
            }
        }
        batch.clearRetainingCapacity();
        self.endOp(batch_len);
        self.wakeFlushWaiters();
        last_batch_time.* = std.time.milliTimestamp();
    }

    fn writeThreadLoop(self: *WriteWorker) void {
        writeThreadLoopImpl(self) catch |err| {
            std.log.err("writeThreadLoop fatal error: {}", .{err});
            {
                self.thread.mutex.lock();
                self.is_healthy.store(false, .release);
                self.thread.mutex.unlock();
            }

            while (self.queue.pop()) |op| {
                if (op.getCompletionSignal()) |sig| {
                    sig.signal(StorageError.EngineUnhealthy);
                }
                if (op.getWriteAckInfo()) |info| {
                    self.pushWriteOutcome(info.conn_id, info.write_id, StorageError.EngineUnhealthy, null);
                }
                op.deinit(self.allocator);
                self.flush_wg.done(1);
            }

            self.wakeFlushWaiters();
            self.notifyChanges();
        };
    }

    fn waitForWriteSignal(self: *WriteWorker, timeout_ns: ?u64) void {
        self.thread.mutex.lock();
        defer self.thread.mutex.unlock();

        if (self.thread.isRequested() or self.queue.hasItems()) {
            return;
        }

        if (timeout_ns) |ns| {
            self.thread.cond.timedWait(&self.thread.mutex, ns) catch |err| {
                if (err != error.Timeout) {
                    std.log.err("write_cond.timedWait failed: {}", .{err});
                }
            };
        } else {
            self.thread.cond.wait(&self.thread.mutex);
        }
    }

    fn writeThreadLoopImpl(self: *WriteWorker) !void {
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

        while (!self.thread.isRequested()) {
            // Collect operations for batch
            while (batch.items.len < batch_size) {
                if (self.queue.pop()) |op| {
                    switch (op) {
                        .upsert, .update, .delete => {
                            batch.append(self.allocator, op) catch |err| {
                                std.log.err("Failed to append to batch: {}", .{err});
                                op.deinit(self.allocator);
                                self.flush_wg.done(1);
                                self.wakeFlushWaiters();
                                continue;
                            };
                        },
                        .batch, .resolve_session, .checkpoint => {
                            self.executeImmediateOp(op, &batch, &last_batch_time);
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
                .upsert, .update, .delete => {
                    batch.append(self.allocator, op) catch {
                        op.deinit(self.allocator);
                        self.flush_wg.done(1);
                        self.wakeFlushWaiters();
                    };
                },
                .batch, .resolve_session, .checkpoint => {
                    self.executeImmediateOp(op, &batch, &last_batch_time);
                },
            }
        }

        if (batch.items.len > 0) {
            flushBatch(self, &batch, &last_batch_time);
        }
    }

    pub fn executeBatchOp(
        self: *WriteWorker,
        bop: anytype,
        last_batch_time: *i64,
    ) void {
        const entries = bop.entries;
        var tx_started = false;
        var final_err: ?anyerror = null;
        var failed_batch_index: ?usize = null;
        defer {
            if (tx_started) {
                execTransactionControl(&self.conn, "ROLLBACK") catch |rollback_err| {
                    errors.logDatabaseError("executeBatchOp ROLLBACK", errors.classifyError(rollback_err), "");
                };
            }

            // Free op-owned memory before signaling so the caller cannot
            // resume while these heap allocations are still live.
            for (entries) |entry| entry.deinit(self.allocator);
            self.allocator.free(entries);

            if (bop.completion_signal) |sig| sig.signal(final_err);

            if (@hasField(@TypeOf(bop), "conn_id")) {
                if (bop.conn_id) |cid| {
                    if (bop.write_id) |wid| {
                        self.pushWriteOutcome(cid, wid, final_err, if (final_err != null) failed_batch_index else null);
                        self.notifyChanges();
                    }
                }
            }

            self.flush_wg.done(1);
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
            const table_metadata = self.schema.tableByIndex(entry.table_index) orelse continue;
            const key = reader.getCacheKey(table_metadata, entry.namespace_id, entry.id);
            eviction_keys.appendAssumeCapacity(key);
        }
        // 2. Execute all entries in a single transaction
        var pending_changes = std.ArrayListUnmanaged(OwnedRecordChange).empty;
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

        const is_confirmed = if (@hasField(@TypeOf(bop), "conn_id"))
            bop.conn_id != null and bop.write_id != null
        else
            false;

        var sql_cache = std.AutoHashMap(usize, []const u8).init(self.allocator);
        defer {
            var it = sql_cache.valueIterator();
            while (it.next()) |sql_str| self.allocator.free(sql_str.*);
            sql_cache.deinit();
        }

        var pk_inserts = std.ArrayListUnmanaged(struct { table_index: usize, id: DocId }).empty;
        defer pk_inserts.deinit(self.allocator);
        var pk_deletes = std.ArrayListUnmanaged(struct { table_index: usize, id: DocId }).empty;
        defer pk_deletes.deinit(self.allocator);

        for (entries, 0..) |entry, entry_idx| {
            const table_metadata = self.schema.tableByIndex(entry.table_index) orelse {
                final_err = StorageError.UnknownTable;
                std.log.debug("Batch entry references unknown table index {d}", .{entry.table_index});
                failed_batch_index = entry_idx;
                break;
            };
            const namespace_id = if (table_metadata.namespaced) entry.namespace_id else schema.global_namespace_id;

            switch (entry.kind) {
                .upsert => {
                    const owner_doc_id = if (table_metadata.is_users_table) entry.id else entry.owner_doc_id;
                    var old_record: ?Record = null;
                    if (getDocumentHelper(self, entry.table_index, namespace_id, entry.id, &sql_cache)) |record| {
                        old_record = record;
                    } else |err| {
                        std.log.err("Failed to capture old state (pre-UPSERT) for table index {d}: {}", .{ entry.table_index, err });
                    }

                    if (executeUpsert(self, entry, namespace_id, owner_doc_id, table_metadata)) |maybe_new_record| {
                        if (maybe_new_record) |new_record| {
                            const op_type: OwnedRecordChange.Operation = if (old_record == null) .insert else .update;
                            if (old_record == null) {
                                pk_inserts.append(self.allocator, .{ .table_index = entry.table_index, .id = entry.id }) catch |err| {
                                    std.log.warn("Failed to track pk_insert for table {d}: {}", .{ entry.table_index, err });
                                };
                            }
                            if (pushOwnedChange(self.allocator, &pending_changes, namespace_id, entry.table_index, entry.id, op_type, old_record, new_record)) |_| {
                                // success
                            } else |err| {
                                const classified_err = errors.classifyError(err);
                                std.log.err("Failed to capture row change: {}", .{classified_err});
                                if (old_record) |r| r.deinit(self.allocator);
                                var r = new_record;
                                r.deinit(self.allocator);
                                final_err = classified_err;
                                failed_batch_index = entry_idx;
                                break;
                            }
                        } else {
                            if (old_record != null and entry.guard_values != null and is_confirmed) {
                                if (old_record) |r| r.deinit(self.allocator);
                                final_err = error.PermissionDenied;
                                failed_batch_index = entry_idx;
                                break;
                            }
                            var id_hex_buf: [32]u8 = undefined;
                            std.log.debug("UPSERT for table index {d}/{s} conflicted with a different namespace", .{ entry.table_index, typed.docIdHexSlice(entry.id, &id_hex_buf) });
                            if (old_record) |r| r.deinit(self.allocator);
                        }
                    } else |err| {
                        if (old_record) |r| r.deinit(self.allocator);
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatchOp UPSERT", classified_err, table_metadata.name);
                        final_err = classified_err;
                        failed_batch_index = entry_idx;
                        break;
                    }
                },
                .update => {
                    var old_record: ?Record = null;
                    if (getDocumentHelper(self, entry.table_index, namespace_id, entry.id, &sql_cache)) |record| {
                        old_record = record;
                    } else |err| {
                        std.log.err("Failed to capture old state (pre-UPDATE) for table index {d}: {}", .{ entry.table_index, err });
                    }

                    if (executeUpdate(self, entry, namespace_id, table_metadata)) |maybe_new_record| {
                        if (maybe_new_record) |new_record| {
                            if (pushOwnedChange(self.allocator, &pending_changes, namespace_id, entry.table_index, entry.id, .update, old_record, new_record)) |_| {
                                // success
                            } else |err| {
                                const classified_err = errors.classifyError(err);
                                std.log.err("Failed to capture row change: {}", .{classified_err});
                                if (old_record) |r| r.deinit(self.allocator);
                                var r = new_record;
                                r.deinit(self.allocator);
                                final_err = classified_err;
                                failed_batch_index = entry_idx;
                                break;
                            }
                        } else {
                            if (old_record != null and entry.guard_values != null and is_confirmed) {
                                if (old_record) |r| r.deinit(self.allocator);
                                final_err = error.PermissionDenied;
                                failed_batch_index = entry_idx;
                                break;
                            }
                            var id_hex_buf: [32]u8 = undefined;
                            std.log.debug("UPDATE for table index {d}/{s} had no matching row", .{ entry.table_index, typed.docIdHexSlice(entry.id, &id_hex_buf) });
                            if (old_record) |r| r.deinit(self.allocator);
                        }
                    } else |err| {
                        if (old_record) |r| r.deinit(self.allocator);
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatchOp UPDATE", classified_err, table_metadata.name);
                        final_err = classified_err;
                        failed_batch_index = entry_idx;
                        break;
                    }
                },
                .delete => {
                    if (executeDelete(self, entry, namespace_id, table_metadata)) |maybe_old_record| {
                        if (maybe_old_record) |old_record| {
                            pk_deletes.append(self.allocator, .{ .table_index = entry.table_index, .id = entry.id }) catch |err| {
                                std.log.warn("Failed to track pk_delete for table {d}: {}", .{ entry.table_index, err });
                            };
                            if (pushOwnedChange(self.allocator, &pending_changes, namespace_id, entry.table_index, entry.id, .delete, old_record, null)) |_| {
                                // success
                            } else |err| {
                                const classified_err = errors.classifyError(err);
                                std.log.err("Failed to capture row change: {}", .{classified_err});
                                var r = old_record;
                                r.deinit(self.allocator);
                                final_err = classified_err;
                                failed_batch_index = entry_idx;
                                break;
                            }
                        } else {
                            if (entry.guard_values != null and is_confirmed) {
                                const exists = getDocumentHelper(self, entry.table_index, namespace_id, entry.id, &sql_cache) catch |err| blk: {
                                    std.log.err("Delete guard post-check failed: {}", .{err});
                                    break :blk null;
                                };
                                if (exists != null) {
                                    exists.?.deinit(self.allocator);
                                    final_err = error.PermissionDenied;
                                    failed_batch_index = entry_idx;
                                    break;
                                }
                            } else {
                                var id_hex_buf: [32]u8 = undefined;
                                std.log.debug("DELETE for table index {d}/{s}: no row found (already deleted)", .{ entry.table_index, typed.docIdHexSlice(entry.id, &id_hex_buf) });
                            }
                        }
                    } else |err| {
                        const classified_err = errors.classifyError(err);
                        errors.logDatabaseError("executeBatchOp DELETE", classified_err, table_metadata.name);
                        final_err = classified_err;
                        failed_batch_index = entry_idx;
                        break;
                    }
                },
            }
        }

        if (final_err == null) {
            if (execTransactionControl(&self.conn, "COMMIT")) |_| {
                tx_started = false;
                self.bumpVersion();

                if (eviction_keys.items.len > 0) {
                    self.metadata_cache.bulkEvict(eviction_keys.items);
                }

                for (pk_inserts.items) |item| {
                    if (item.table_index < self.pk_sets.len) {
                        self.pk_sets[item.table_index].insert(self.allocator, item.id);
                    }
                }
                for (pk_deletes.items) |item| {
                    if (item.table_index < self.pk_sets.len) {
                        self.pk_sets[item.table_index].remove(item.id);
                    }
                }

                flushPendingChanges(self, &pending_changes);
            } else |err| {
                const classified_err = errors.classifyError(err);
                errors.logDatabaseError("executeBatchOp COMMIT", classified_err, "");
                final_err = classified_err;
            }
        }
    }

    fn executeResolveSessionOp(self: *WriteWorker, sop: anytype) void {
        var result = SessionResolutionResult{
            .conn_id = sop.conn_id,
            .msg_id = sop.msg_id,
            .scope_seq = sop.scope_seq,
            .namespace_id = 0,
            .user_doc_id = typed.zeroDocId,
            .err = null,
            .is_presence = sop.is_presence,
        };

        if (sql.resolveNamespaceId(self.allocator, &self.conn, &self.stmt_cache, sop.namespace)) |namespace_id| {
            result.namespace_id = namespace_id;

            self.namespace_cache.update(
                storage_cache.namespaceCacheKey(sop.namespace),
                .{ .namespace_id = namespace_id },
            ) catch |err| {
                std.log.warn("Failed to update namespace cache during session resolution: {}", .{err});
            };

            const users_table = self.schema.table("users") orelse {
                result.err = error.UnknownTable;
                sop.result_buffer.push(result) catch |err| {
                    std.log.err("Failed to queue session resolution result: {}", .{err});
                };
                self.notifyChanges();
                return;
            };
            const identity_namespace_id = if (users_table.namespaced) namespace_id else schema.global_namespace_id;

            if (sql.resolveUserId(
                self.allocator,
                &self.conn,
                &self.stmt_cache,
                identity_namespace_id,
                sop.external_user_id,
                sop.timestamp,
            )) |user_doc_id| {
                result.user_doc_id = user_doc_id;
                self.identity_cache.update(
                    storage_cache.identityCacheKey(identity_namespace_id, sop.external_user_id),
                    .{ .user_doc_id = user_doc_id },
                ) catch |err| {
                    std.log.warn("Failed to update identity cache during session resolution: {}", .{err});
                };
            } else |err| {
                result.err = errors.classifyError(err);
            }
        } else |err| {
            result.err = errors.classifyError(err);
        }

        sop.result_buffer.push(result) catch |err| {
            std.log.err("Failed to queue session resolution result: {}", .{err});
        };
        self.notifyChanges();
    }

    fn executeImmediateOp(
        self: *WriteWorker,
        op: WriteOp,
        batch: *std.ArrayListUnmanaged(WriteOp),
        last_batch_time: *i64,
    ) void {
        if (batch.items.len > 0) {
            flushBatch(self, batch, last_batch_time);
        }

        switch (op) {
            .batch => |bop| {
                executeBatchOp(self, bop, last_batch_time);
            },
            .resolve_session => |sop| {
                self.executeResolveSessionOp(sop);
                op.deinit(self.allocator);
                self.flush_wg.done(1);
                self.wakeFlushWaiters();
            },
            .checkpoint => |cop| {
                const ckpt_result = connection.internalExecuteCheckpoint(&self.conn, self.allocator, self.db_path, self.in_memory, cop.mode);
                // No-op for checkpoint, but keeps the pattern uniform.
                op.deinit(self.allocator);
                if (ckpt_result) |stats| {
                    cop.completion_signal.signalWithResult(stats);
                } else |err| {
                    cop.completion_signal.signal(errors.classifyError(err));
                }
                self.flush_wg.done(1);
                self.wakeFlushWaiters();
            },
            .upsert, .update, .delete => unreachable,
        }
    }

    fn executeUpsert(
        self: *WriteWorker,
        op: anytype,
        namespace_id: i64,
        owner_id: DocId,
        table_metadata: *const schema.Table,
    ) !?Record {
        const sql_str = op.sql;
        var mstmt = try self.stmt_cache.acquire(self.allocator, &self.conn, sql_str);
        defer mstmt.release();
        const stmt = mstmt.stmt;

        var bind_idx: c_int = 1;
        const id_bytes = typed.docIdToBytes(op.id);
        if (sql.bindBlobTransient(stmt, bind_idx, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        const owner_id_bytes = typed.docIdToBytes(owner_id);
        if (sql.bindBlobTransient(stmt, bind_idx, &owner_id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        if (table_metadata.is_users_table) {
            var external_id_buf: [32]u8 = undefined;
            const external_id = typed.docIdHexSlice(op.id, &external_id_buf);
            if (sql.bindTextTransient(stmt, bind_idx, external_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
            bind_idx += 1;
        }

        if (@typeInfo(@TypeOf(op.values)) == .optional) {
            if (op.values) |vals| {
                for (vals) |val| {
                    try sql.bindValue(val, &self.conn, stmt, bind_idx, self.allocator);
                    bind_idx += 1;
                }
            }
        } else {
            for (op.values) |val| {
                try sql.bindValue(val, &self.conn, stmt, bind_idx, self.allocator);
                bind_idx += 1;
            }
        }

        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;

        if (op.guard_values) |guard_vals| {
            for (guard_vals) |val| {
                try sql.bindValue(val, &self.conn, stmt, bind_idx, self.allocator);
                bind_idx += 1;
            }
        }

        const rc = sqlite.c.sqlite3_step(stmt);
        if (rc == sqlite.c.SQLITE_ROW) {
            return try reader.decodeRecord(self.allocator, stmt, table_metadata);
        }
        if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(&self.conn);
        return null;
    }

    fn executeUpdate(
        self: *WriteWorker,
        op: anytype,
        namespace_id: i64,
        table_metadata: *const schema.Table,
    ) !?Record {
        const sql_str = op.sql;
        var mstmt = try self.stmt_cache.acquire(self.allocator, &self.conn, sql_str);
        defer mstmt.release();
        const stmt = mstmt.stmt;

        var bind_idx: c_int = 1;

        if (@typeInfo(@TypeOf(op.values)) == .optional) {
            if (op.values) |vals| {
                for (vals) |val| {
                    try sql.bindValue(val, &self.conn, stmt, bind_idx, self.allocator);
                    bind_idx += 1;
                }
            }
        } else {
            for (op.values) |val| {
                try sql.bindValue(val, &self.conn, stmt, bind_idx, self.allocator);
                bind_idx += 1;
            }
        }

        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;

        const id_bytes = typed.docIdToBytes(op.id);
        if (sql.bindBlobTransient(stmt, bind_idx, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;

        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;

        if (op.guard_values) |guard_vals| {
            for (guard_vals) |val| {
                try sql.bindValue(val, &self.conn, stmt, bind_idx, self.allocator);
                bind_idx += 1;
            }
        }

        const rc = sqlite.c.sqlite3_step(stmt);
        if (rc == sqlite.c.SQLITE_ROW) {
            return try reader.decodeRecord(self.allocator, stmt, table_metadata);
        }
        if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(&self.conn);
        return null;
    }

    fn executeDelete(
        self: *WriteWorker,
        op: anytype,
        namespace_id: i64,
        table_metadata: *const schema.Table,
    ) !?Record {
        const sql_str = op.sql;
        var mstmt = try self.stmt_cache.acquire(self.allocator, &self.conn, sql_str);
        defer mstmt.release();
        const stmt = mstmt.stmt;

        const id_bytes = typed.docIdToBytes(op.id);
        if (sql.bindBlobTransient(stmt, 1, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);

        if (sqlite.c.sqlite3_bind_int64(stmt, 2, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);

        var bind_idx: c_int = 3;
        if (op.guard_values) |guard_vals| {
            for (guard_vals) |val| {
                try sql.bindValue(val, &self.conn, stmt, bind_idx, self.allocator);
                bind_idx += 1;
            }
        }

        const rc = sqlite.c.sqlite3_step(stmt);
        if (rc == sqlite.c.SQLITE_ROW) {
            return try reader.decodeRecord(self.allocator, stmt, table_metadata);
        }
        if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(&self.conn);
        return null;
    }
};
