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
const BatchEntry = write_queue.BatchEntry;
const WriteOp = write_queue.WriteOp;
const write_queue_type = write_queue.write_queue_type;
const StatementCache = sql.StatementCache;
const StorageError = errors.StorageError;

/// Classify a database error, log it, and optionally deinit an old record.
/// Used as the catch handler in executeBatch* / handle*Entry functions.
fn mapAndLogError(
    label: []const u8,
    err: anyerror,
    table_name: []const u8,
    allocator: Allocator,
    old_record: ?Record,
) anyerror {
    if (old_record) |r| r.deinit(allocator);
    const classified_err = errors.classifyError(err);
    errors.logDatabaseError(label, classified_err, table_name);
    return classified_err;
}

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
        self.thread.lockWork();
        defer self.thread.unlockWork();
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

    fn pushBatchOutcomes(
        self: *WriteWorker,
        batch: []const WriteOp,
        guard_rejected: ?[]const usize,
        batch_err: ?anyerror,
    ) void {
        var pushed = false;
        for (batch, 0..) |op, op_idx| {
            if (op.getWriteAckInfo()) |info| {
                const err: ?anyerror = if (batch_err) |e| e else blk: {
                    if (guard_rejected) |rejected| {
                        for (rejected) |idx| {
                            if (idx == op_idx) break :blk error.PermissionDenied;
                        }
                    }
                    break :blk null;
                };
                self.pushWriteOutcome(info.conn_id, info.write_id, err, null);
                pushed = true;
            }
            op.deinit(self.allocator);
        }
        if (pushed) {
            self.notifyChanges();
        }
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

    fn execTransactionControlChecked(conn: *sqlite.Db, statement: [:0]const u8, comptime label: []const u8) !void {
        execTransactionControl(conn, statement) catch |err| {
            const classified_err = errors.classifyError(err);
            errors.logDatabaseError(label, classified_err, "");
            return classified_err;
        };
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

    /// Prefetch the current record for change tracking. Returns the old record
    /// when the change queue is active (for insert-vs-update classification) or
    /// when a guard is present (to distinguish non-existent rows from guard
    /// conflicts in applyWriteResult). Returns null otherwise.
    fn prefetchOldRecord(
        self: *WriteWorker,
        comptime op_label: []const u8,
        entry: anytype,
        namespace_id: i64,
        sql_cache: *std.AutoHashMap(usize, []const u8),
    ) ?Record {
        if (self.change_queue != null or entry.guard_values != null) {
            if (getDocumentHelper(self, entry.table_index, namespace_id, entry.id, sql_cache)) |record| {
                return record;
            } else |err| {
                std.log.err("Failed to capture old state ({s}) for table index {d}: {}", .{ op_label, entry.table_index, err });
            }
        }
        return null;
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
        try execTransactionControlChecked(&self.conn, "BEGIN TRANSACTION", "executeBatch BEGIN");
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

        var pk_inserts = std.ArrayListUnmanaged(PkTracking).empty;
        defer pk_inserts.deinit(self.allocator);
        var pk_deletes = std.ArrayListUnmanaged(PkTracking).empty;
        defer pk_deletes.deinit(self.allocator);

        var ctx = BatchCtx{
            .self = self,
            .sql_cache = &sql_cache,
            .pending_changes = pending_changes,
            .pk_inserts = &pk_inserts,
            .pk_deletes = &pk_deletes,
            .is_confirmed = false, // unused for WriteOp path; guard check uses op.getWriteAckInfo()
        };

        for (ops, 0..) |op, op_idx| {
            switch (op) {
                .upsert => |iop| {
                    if (try executeBatchUpsert(&ctx, iop, op.getWriteAckInfo() != null)) continue;
                    try guard_rejected.append(self.allocator, op_idx);
                },
                .update => |uop| {
                    if (try executeBatchUpdate(&ctx, uop, op.getWriteAckInfo() != null)) continue;
                    try guard_rejected.append(self.allocator, op_idx);
                },
                .delete => |dop| {
                    if (try executeBatchDelete(&ctx, dop, op.getWriteAckInfo() != null)) continue;
                    try guard_rejected.append(self.allocator, op_idx);
                },
                else => unreachable,
            }
        }

        try execTransactionControlChecked(&self.conn, "COMMIT", "executeBatch COMMIT");

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

    /// Handles post-execute bookkeeping shared by all three write paths:
    /// PK tracking, change log push, and guard-conflict detection.
    /// `old_record` / `new_record` ownership is consumed here — caller must
    /// not deinit them afterwards regardless of the return value.
    /// Returns true on success (row was affected or no guard conflict),
    /// false when a guard conflict was detected (caller tracks as rejected).
    fn applyWriteResult(
        self: *WriteWorker,
        ctx: *BatchCtx,
        table_index: usize,
        namespace_id: i64,
        doc_id: typed.DocId,
        has_guard: bool,
        has_write_ack: bool,
        pk_insert: bool,
        pk_delete: bool,
        old_record: ?Record,
        new_record: ?Record,
    ) !bool {
        if (new_record != null or (pk_delete and old_record != null)) {
            // Row was affected — track PK and push change.
            errdefer {
                if (old_record) |r| r.deinit(self.allocator);
                if (new_record) |r| r.deinit(self.allocator);
            }
            if (pk_insert and old_record == null) {
                try ctx.pk_inserts.append(self.allocator, .{ .table_index = table_index, .id = doc_id });
            }
            if (pk_delete) {
                try ctx.pk_deletes.append(self.allocator, .{ .table_index = table_index, .id = doc_id });
            }
            const op_type: OwnedRecordChange.Operation = if (pk_delete)
                .delete
            else if (old_record == null)
                .insert
            else
                .update;
            if (self.change_queue != null) {
                pushOwnedChange(self.allocator, ctx.pending_changes, namespace_id, table_index, doc_id, op_type, old_record, new_record) catch |err| {
                    const classified_err = errors.classifyError(err);
                    std.log.err("Failed to capture row change: {}", .{classified_err});
                    return classified_err;
                };
            } else {
                if (old_record) |r| r.deinit(self.allocator);
                if (new_record) |r| r.deinit(self.allocator);
            }
            return true;
        } else {
            // Row was not affected — check for guard conflict.
            const guard_conflict = old_record != null and has_guard and has_write_ack;
            if (old_record) |r| r.deinit(self.allocator);
            if (new_record) |r| r.deinit(self.allocator);
            return !guard_conflict;
        }
    }

    /// Returns true if the upsert succeeded (or was a no-op without guard conflict).
    /// Returns false if the guard rejected the operation (caller should track in guard_rejected).
    fn executeBatchUpsert(
        ctx: *BatchCtx,
        iop: anytype,
        has_write_ack: bool,
    ) !bool {
        const self = ctx.self;
        const table_metadata = self.schema.tableByIndex(iop.table_index) orelse return StorageError.UnknownTable;
        const namespace_id = if (table_metadata.namespaced) iop.namespace_id else schema.global_namespace_id;
        const owner_doc_id = if (table_metadata.is_users_table) iop.id else iop.owner_doc_id;

        const old_record = self.prefetchOldRecord("pre-UPSERT", iop, namespace_id, ctx.sql_cache);

        const maybe_new_record = executeUpsert(self, iop, namespace_id, owner_doc_id, table_metadata) catch |err| {
            return mapAndLogError("executeBatch UPSERT", err, table_metadata.name, self.allocator, old_record);
        };

        return applyWriteResult(self, ctx, iop.table_index, namespace_id, iop.id, iop.guard_values != null, has_write_ack, true, false, old_record, maybe_new_record);
    }

    fn executeBatchUpdate(
        ctx: *BatchCtx,
        uop: anytype,
        has_write_ack: bool,
    ) !bool {
        const self = ctx.self;
        const table_metadata = self.schema.tableByIndex(uop.table_index) orelse return StorageError.UnknownTable;
        const namespace_id = if (table_metadata.namespaced) uop.namespace_id else schema.global_namespace_id;

        const old_record = self.prefetchOldRecord("pre-UPDATE", uop, namespace_id, ctx.sql_cache);

        const maybe_new_record = executeUpdate(self, uop, namespace_id, table_metadata) catch |err| {
            return mapAndLogError("executeBatch UPDATE", err, table_metadata.name, self.allocator, old_record);
        };

        return applyWriteResult(self, ctx, uop.table_index, namespace_id, uop.id, uop.guard_values != null, has_write_ack, false, false, old_record, maybe_new_record);
    }

    fn executeBatchDelete(
        ctx: *BatchCtx,
        dop: anytype,
        has_write_ack: bool,
    ) !bool {
        const self = ctx.self;
        const table_metadata = self.schema.tableByIndex(dop.table_index) orelse return StorageError.UnknownTable;
        const namespace_id = if (table_metadata.namespaced) dop.namespace_id else schema.global_namespace_id;

        // executeDelete returns the old row (for the change log) when it deleted
        // something, or null when no row matched.  We do NOT need a pre-fetch here
        // because the deleted row is returned by the SQL statement itself (RETURNING).
        const maybe_old_record = executeDelete(self, dop, namespace_id, table_metadata) catch |err| {
            return mapAndLogError("executeBatch DELETE", err, table_metadata.name, self.allocator, null);
        };

        // Guard semantics for delete: if the row was not affected and a guard is
        // present, we must distinguish between "row doesn't exist" (idempotent
        // success) and "row exists but guard condition didn't match" (conflict).
        if (maybe_old_record == null and dop.guard_values != null and has_write_ack) {
            const exists = getDocumentHelper(self, dop.table_index, namespace_id, dop.id, ctx.sql_cache) catch |err| {
                const classified_err = errors.classifyError(err);
                std.log.err("Delete guard post-check failed: {}", .{classified_err});
                return classified_err;
            };
            if (exists) |r| {
                r.deinit(self.allocator);
                return false; // row exists but guard didn't match — conflict
            }
            return true; // row genuinely doesn't exist — idempotent success
        }

        return applyWriteResult(self, ctx, dop.table_index, namespace_id, dop.id, dop.guard_values != null, has_write_ack, false, true, maybe_old_record, null);
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
                op.deinit(self.allocator);
            }
            batch.clearRetainingCapacity();
            self.endOp(batch_len);
            last_batch_time.* = std.time.milliTimestamp();
            return;
        };
        for (batch.items) |op| {
            if (getOpTarget(op)) |target| {
                const table_metadata = self.schema.tableByIndex(target.table_index) orelse continue;
                const key = reader.getCacheKey(table_metadata, target.namespace_id, target.id);
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

            self.pushBatchOutcomes(batch.items, guard_rejected.items, null);
            flushPendingChanges(self, &pending_changes);
        } else |err| {
            const classified_err = errors.classifyError(err);
            std.log.debug("Failed to execute batch, transaction rolled back: {}", .{classified_err});
            self.pushBatchOutcomes(batch.items, null, classified_err);
        }
        batch.clearRetainingCapacity();
        self.endOp(batch_len);
        last_batch_time.* = std.time.milliTimestamp();
    }

    fn writeThreadLoop(self: *WriteWorker) void {
        writeThreadLoopImpl(self) catch |err| {
            std.log.err("writeThreadLoop fatal error: {}", .{err});
            {
                self.thread.lockWork();
                self.is_healthy.store(false, .release);
                self.thread.unlockWork();
            }

            while (self.queue.pop()) |op| {
                switch (op) {
                    .checkpoint => |cop| cop.latch.reject(StorageError.EngineUnhealthy),
                    .batch => |bop| if (bop.latch) |l| l.reject(StorageError.EngineUnhealthy),
                    else => {},
                }
                if (op.getWriteAckInfo()) |info| {
                    self.pushWriteOutcome(info.conn_id, info.write_id, StorageError.EngineUnhealthy, null);
                }
                op.deinit(self.allocator);
                self.flush_wg.done(1);
            }

            self.notifyChanges();
        };
    }

    fn waitForWriteSignal(self: *WriteWorker, timeout_ns: ?u64) void {
        self.thread.lockWork();
        defer self.thread.unlockWork();

        if (self.thread.isRequested() or self.queue.hasItems()) {
            return;
        }

        _ = if (timeout_ns) |ns|
            self.thread.waitForWorkTimed(ns)
        else blk: {
            self.thread.waitForWork();
            break :blk @TypeOf(self.thread).WaitResult.signaled;
        };
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
                    if (tryEnqueueOp(self, op, &batch, &last_batch_time) == .skipped) continue;
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
            _ = tryEnqueueOp(self, op, &batch, &last_batch_time);
        }

        if (batch.items.len > 0) {
            flushBatch(self, &batch, &last_batch_time);
        }
    }

    const EnqueueResult = enum { appended, immediate, skipped };

    fn tryEnqueueOp(
        self: *WriteWorker,
        op: WriteOp,
        batch: *std.ArrayListUnmanaged(WriteOp),
        last_batch_time: *i64,
    ) EnqueueResult {
        return switch (op) {
            .upsert, .update, .delete => blk: {
                batch.append(self.allocator, op) catch |err| {
                    std.log.err("Failed to append to batch: {}", .{err});
                    if (op.getWriteAckInfo()) |info| {
                        self.pushWriteOutcome(info.conn_id, info.write_id, errors.classifyError(err), null);
                        self.notifyChanges();
                    }
                    op.deinit(self.allocator);
                    self.flush_wg.done(1);
                    break :blk .skipped;
                };
                break :blk .appended;
            },
            .batch, .resolve_session, .checkpoint => blk: {
                self.executeImmediateOp(op, batch, last_batch_time);
                break :blk .immediate;
            },
        };
    }

    const PkTracking = struct { table_index: usize, id: DocId };

    const BatchCtx = struct {
        self: *WriteWorker,
        sql_cache: *std.AutoHashMap(usize, []const u8),
        pending_changes: *std.ArrayListUnmanaged(OwnedRecordChange),
        pk_inserts: *std.ArrayListUnmanaged(PkTracking),
        pk_deletes: *std.ArrayListUnmanaged(PkTracking),
        is_confirmed: bool,
    };

    const OpTarget = struct {
        table_index: usize,
        id: DocId,
        namespace_id: i64,
    };

    fn getOpTarget(op: WriteOp) ?OpTarget {
        return switch (op) {
            .upsert => |o| .{ .table_index = o.table_index, .id = o.id, .namespace_id = o.namespace_id },
            .update => |o| .{ .table_index = o.table_index, .id = o.id, .namespace_id = o.namespace_id },
            .delete => |o| .{ .table_index = o.table_index, .id = o.id, .namespace_id = o.namespace_id },
            else => null,
        };
    }

    fn bindValueSlice(
        self: *WriteWorker,
        stmt: *sqlite.c.sqlite3_stmt,
        bind_idx: *c_int,
        values: []const typed.Value,
    ) !void {
        for (values) |val| {
            try sql.bindValue(val, &self.conn, stmt, bind_idx.*, self.allocator);
            bind_idx.* += 1;
        }
    }

    fn buildEvictionKeys(
        self: *WriteWorker,
        entries: []const BatchEntry,
        eviction_keys: *std.ArrayListUnmanaged(MetadataCacheKey),
    ) !void {
        eviction_keys.ensureTotalCapacity(self.allocator, entries.len) catch |err| {
            const classified_err = errors.classifyError(err);
            std.log.err("Failed to allocate eviction keys for batch op: {}", .{classified_err});
            return classified_err;
        };
        for (entries) |entry| {
            const table_metadata = self.schema.tableByIndex(entry.table_index) orelse continue;
            const key = reader.getCacheKey(table_metadata, entry.namespace_id, entry.id);
            eviction_keys.appendAssumeCapacity(key);
        }
    }

    fn runBatchTransaction(
        self: *WriteWorker,
        bop: anytype,
        entries: []const BatchEntry,
        tx_started: *bool,
        failed_batch_index: *?usize,
        eviction_keys: *std.ArrayListUnmanaged(MetadataCacheKey),
    ) !void {
        var pending_changes = std.ArrayListUnmanaged(OwnedRecordChange).empty;
        defer {
            for (pending_changes.items) |*c| c.deinit(self.allocator);
            pending_changes.deinit(self.allocator);
        }

        try execTransactionControlChecked(&self.conn, "BEGIN TRANSACTION", "executeBatchOp BEGIN");
        tx_started.* = true;

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

        var pk_inserts = std.ArrayListUnmanaged(PkTracking).empty;
        defer pk_inserts.deinit(self.allocator);
        var pk_deletes = std.ArrayListUnmanaged(PkTracking).empty;
        defer pk_deletes.deinit(self.allocator);

        var ctx = BatchCtx{
            .self = self,
            .sql_cache = &sql_cache,
            .pending_changes = &pending_changes,
            .pk_inserts = &pk_inserts,
            .pk_deletes = &pk_deletes,
            .is_confirmed = is_confirmed,
        };

        for (entries, 0..) |entry, entry_idx| {
            const table_metadata = self.schema.tableByIndex(entry.table_index) orelse {
                std.log.debug("Batch entry references unknown table index {d}", .{entry.table_index});
                failed_batch_index.* = entry_idx;
                return StorageError.UnknownTable;
            };
            const namespace_id = if (table_metadata.namespaced) entry.namespace_id else schema.global_namespace_id;

            const handle_result = switch (entry.kind) {
                .upsert => handleUpsertEntry(&ctx, entry, namespace_id, table_metadata),
                .update => handleUpdateEntry(&ctx, entry, namespace_id, table_metadata),
                .delete => handleDeleteEntry(&ctx, entry, namespace_id, table_metadata),
            };
            handle_result catch |err| {
                failed_batch_index.* = entry_idx;
                return err;
            };
        }

        try commitBatchAndApply(self, tx_started, eviction_keys, &pk_inserts, &pk_deletes, &pending_changes);
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

            if (bop.latch) |l| {
                if (final_err) |e| l.reject(e) else l.resolve({});
            }

            if (@hasField(@TypeOf(bop), "conn_id")) {
                if (bop.conn_id) |cid| {
                    if (bop.write_id) |wid| {
                        self.pushWriteOutcome(cid, wid, final_err, if (final_err != null) failed_batch_index else null);
                        self.notifyChanges();
                    }
                }
            }

            self.flush_wg.done(1);
            last_batch_time.* = std.time.milliTimestamp();
        }

        // 1. Build eviction keys from all entries
        var eviction_keys = std.ArrayListUnmanaged(MetadataCacheKey).empty;
        defer eviction_keys.deinit(self.allocator);
        self.buildEvictionKeys(entries, &eviction_keys) catch |err| {
            final_err = err;
            return;
        };

        // 2. Execute all entries in a single transaction
        self.runBatchTransaction(bop, entries, &tx_started, &failed_batch_index, &eviction_keys) catch |err| {
            final_err = err;
        };
    }

    fn commitBatchAndApply(
        self: *WriteWorker,
        tx_started: *bool,
        eviction_keys: *std.ArrayListUnmanaged(MetadataCacheKey),
        pk_inserts: *std.ArrayListUnmanaged(PkTracking),
        pk_deletes: *std.ArrayListUnmanaged(PkTracking),
        pending_changes: *std.ArrayListUnmanaged(OwnedRecordChange),
    ) !void {
        try execTransactionControlChecked(&self.conn, "COMMIT", "executeBatchOp COMMIT");
        tx_started.* = false;
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

        flushPendingChanges(self, pending_changes);
    }

    fn handleUpsertEntry(
        ctx: *BatchCtx,
        entry: anytype,
        namespace_id: i64,
        table_metadata: *const schema.Table,
    ) !void {
        const self = ctx.self;
        const owner_doc_id = if (table_metadata.is_users_table) entry.id else entry.owner_doc_id;

        const old_record = self.prefetchOldRecord("pre-UPSERT", entry, namespace_id, ctx.sql_cache);

        const maybe_new_record = executeUpsert(self, entry, namespace_id, owner_doc_id, table_metadata) catch |err| {
            return mapAndLogError("executeBatchOp UPSERT", err, table_metadata.name, self.allocator, old_record);
        };

        const succeeded = try applyWriteResult(self, ctx, entry.table_index, namespace_id, entry.id, entry.guard_values != null, ctx.is_confirmed, true, false, old_record, maybe_new_record);
        if (!succeeded) return error.PermissionDenied;
    }

    fn handleUpdateEntry(
        ctx: *BatchCtx,
        entry: anytype,
        namespace_id: i64,
        table_metadata: *const schema.Table,
    ) !void {
        const self = ctx.self;

        const old_record = self.prefetchOldRecord("pre-UPDATE", entry, namespace_id, ctx.sql_cache);

        const maybe_new_record = executeUpdate(self, entry, namespace_id, table_metadata) catch |err| {
            return mapAndLogError("executeBatchOp UPDATE", err, table_metadata.name, self.allocator, old_record);
        };

        const succeeded = try applyWriteResult(self, ctx, entry.table_index, namespace_id, entry.id, entry.guard_values != null, ctx.is_confirmed, false, false, old_record, maybe_new_record);
        if (!succeeded) return error.PermissionDenied;
    }

    fn handleDeleteEntry(
        ctx: *BatchCtx,
        entry: anytype,
        namespace_id: i64,
        table_metadata: *const schema.Table,
    ) !void {
        const self = ctx.self;

        // executeDelete returns the old row via RETURNING — no pre-fetch needed.
        const maybe_old_record = executeDelete(self, entry, namespace_id, table_metadata) catch |err| {
            return mapAndLogError("executeBatchOp DELETE", err, table_metadata.name, self.allocator, null);
        };

        // Guard semantics for delete: distinguish "row doesn't exist" (idempotent
        // success) from "row exists but guard didn't match" (conflict).
        if (maybe_old_record == null and entry.guard_values != null and ctx.is_confirmed) {
            const exists = getDocumentHelper(self, entry.table_index, namespace_id, entry.id, ctx.sql_cache) catch |err| {
                const classified_err = errors.classifyError(err);
                std.log.err("Delete guard post-check failed: {}", .{classified_err});
                return classified_err;
            };
            if (exists) |r| {
                r.deinit(self.allocator);
                return error.PermissionDenied;
            }
            return; // row doesn't exist — idempotent success
        }

        const succeeded = try applyWriteResult(self, ctx, entry.table_index, namespace_id, entry.id, entry.guard_values != null, ctx.is_confirmed, false, true, maybe_old_record, null);
        if (!succeeded) return error.PermissionDenied;
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
            },
            .checkpoint => |cop| {
                const ckpt_result = connection.internalExecuteCheckpoint(&self.conn, self.allocator, self.db_path, self.in_memory, cop.mode);
                op.deinit(self.allocator);
                if (ckpt_result) |stats| {
                    cop.latch.resolve(stats);
                } else |err| {
                    cop.latch.reject(errors.classifyError(err));
                }
                self.flush_wg.done(1);
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
        try sql.bindDocIdNamespace(stmt, &self.conn, bind_idx, op.id, namespace_id);
        bind_idx += 2;
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
                try self.bindValueSlice(stmt, &bind_idx, vals);
            }
        } else {
            try self.bindValueSlice(stmt, &bind_idx, op.values);
        }

        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;
        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;

        if (op.guard_values) |guard_vals| {
            try self.bindValueSlice(stmt, &bind_idx, guard_vals);
        }

        return try reader.stepReturning(self.allocator, &self.conn, stmt, table_metadata);
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
                try self.bindValueSlice(stmt, &bind_idx, vals);
            }
        } else {
            try self.bindValueSlice(stmt, &bind_idx, op.values);
        }

        if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&self.conn);
        bind_idx += 1;

        try sql.bindDocIdNamespace(stmt, &self.conn, bind_idx, op.id, namespace_id);
        bind_idx += 2;

        if (op.guard_values) |guard_vals| {
            try self.bindValueSlice(stmt, &bind_idx, guard_vals);
        }

        return try reader.stepReturning(self.allocator, &self.conn, stmt, table_metadata);
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

        try sql.bindDocIdNamespace(stmt, &self.conn, 1, op.id, namespace_id);

        var bind_idx: c_int = 3;
        if (op.guard_values) |guard_vals| {
            try self.bindValueSlice(stmt, &bind_idx, guard_vals);
        }

        return try reader.stepReturning(self.allocator, &self.conn, stmt, table_metadata);
    }
};
