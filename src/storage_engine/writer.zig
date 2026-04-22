const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const reader = @import("reader.zig");
const connection = @import("connection.zig");
const types = @import("types.zig");
const doc_id = @import("../doc_id.zig");
const schema_manager = @import("../schema_manager.zig");
const sql = @import("sql.zig");
const ChangeBuffer = @import("../change_buffer.zig").ChangeBuffer;
const OwnedRowChange = @import("../change_buffer.zig").OwnedRowChange;

const WriteOp = types.WriteOp;
const StorageError = types.StorageError;

fn getDocumentHelper(
    allocator: Allocator,
    conn: *sqlite.Db,
    sm: *const schema_manager.SchemaManager,
    table_index: usize,
    namespace: []const u8,
    id: types.DocId,
    sql_cache: *std.AutoHashMap(usize, []const u8),
    stmt_cache: *sql.StatementCache,
) !?types.TypedRow {
    const table_metadata = sm.getTableByIndex(table_index) orelse return null;
    const sql_str = if (sql_cache.get(table_index)) |s| s else blk: {
        const s = try reader.buildSelectDocumentSql(allocator, table_metadata);
        try sql_cache.put(table_index, s);
        break :blk s;
    };
    var mstmt = try stmt_cache.acquire(allocator, conn, sql_str);
    defer mstmt.release();
    return reader.execSelectDocumentTyped(allocator, conn, mstmt.stmt, id, namespace, table_metadata);
}

fn pushOwnedChange(
    allocator: Allocator,
    pending_changes: *std.ArrayListUnmanaged(OwnedRowChange),
    namespace: []const u8,
    table_index: usize,
    op: OwnedRowChange.Operation,
    old_row: ?types.TypedRow,
    new_row: ?types.TypedRow,
) !void {
    const ns = try allocator.dupe(u8, namespace);
    errdefer allocator.free(ns);
    try pending_changes.append(allocator, .{
        .namespace = ns,
        .table_index = table_index,
        .operation = op,
        .old_row = old_row,
        .new_row = new_row,
    });
}

pub fn executeBatch(
    allocator: Allocator,
    conn: *sqlite.Db,
    transaction_active: *std.atomic.Value(bool),
    ops: []const WriteOp,
    pending_changes: *std.ArrayListUnmanaged(OwnedRowChange),
    sm: *const schema_manager.SchemaManager,
    stmt_cache: *sql.StatementCache,
) !void {
    const manual_transaction_active = transaction_active.load(.acquire);

    var sql_cache = std.AutoHashMap(usize, []const u8).init(allocator);
    defer {
        var it = sql_cache.valueIterator();
        while (it.next()) |sql_str| allocator.free(sql_str.*);
        sql_cache.deinit();
    }

    if (!manual_transaction_active) {
        conn.exec("BEGIN TRANSACTION", .{}, .{}) catch |err| {
            const classified_err = types.classifyError(err);
            types.logDatabaseError("executeBatch BEGIN", classified_err, "");
            return classified_err;
        };
        transaction_active.store(true, .release);
    }

    errdefer {
        if (!manual_transaction_active) {
            conn.exec("ROLLBACK", .{}, .{}) catch |rollback_err| {
                const classified_err = types.classifyError(rollback_err);
                types.logDatabaseError("executeBatch ROLLBACK", classified_err, "");
            };
            transaction_active.store(false, .release);
        }
    }

    for (ops) |op| {
        switch (op) {
            .upsert => |iop| {
                const table_metadata = sm.getTableByIndex(iop.table_index) orelse return StorageError.UnknownTable;
                var old_row: ?types.TypedRow = null;
                const capture_res = getDocumentHelper(allocator, conn, sm, iop.table_index, iop.namespace, iop.id, &sql_cache, stmt_cache);
                if (capture_res) |orow| {
                    old_row = orow;
                } else |err| {
                    std.log.err("Failed to capture old state (pre-UPSERT) for table index {d}: {}", .{ iop.table_index, err });
                }
                const maybe_new_row = executeUpsert(allocator, conn, iop, table_metadata, stmt_cache) catch |err| {
                    if (old_row) |r| r.deinit(allocator);
                    const classified_err = types.classifyError(err);
                    types.logDatabaseError("executeBatch UPSERT", classified_err, table_metadata.table.name);
                    return classified_err;
                };

                if (maybe_new_row) |new_row| {
                    const op_type: OwnedRowChange.Operation = if (old_row == null) .insert else .update;
                    pushOwnedChange(allocator, pending_changes, iop.namespace, iop.table_index, op_type, old_row, new_row) catch |err| {
                        std.log.err("Failed to capture row change: {}", .{err});
                        if (old_row) |r| r.deinit(allocator);
                        var r = new_row;
                        r.deinit(allocator);
                    };
                } else {
                    // The upsert is guarded by namespace_id. A missing RETURNING row means
                    // the id already exists in another namespace, which we surface as a
                    // dropped write rather than silently mutating hidden data.
                    var id_hex_buf: [32]u8 = undefined;
                    std.log.debug("UPSERT for table index {d}/{s} conflicted with a different namespace", .{ iop.table_index, doc_id.hexSlice(iop.id, &id_hex_buf) });
                    if (old_row) |r| r.deinit(allocator);
                    continue;
                }
            },
            .delete => |dop| {
                const table_metadata = sm.getTableByIndex(dop.table_index) orelse return StorageError.UnknownTable;
                const maybe_old_row = executeDelete(allocator, conn, dop, table_metadata, stmt_cache) catch |err| {
                    const classified_err = types.classifyError(err);
                    types.logDatabaseError("executeBatch DELETE", classified_err, table_metadata.table.name);
                    return classified_err;
                };

                // For DELETE, the RETURNING * result IS the old row.
                if (maybe_old_row) |old_row| {
                    pushOwnedChange(allocator, pending_changes, dop.namespace, dop.table_index, .delete, old_row, null) catch |err| {
                        std.log.err("Failed to capture row change: {}", .{err});
                        var r = old_row;
                        r.deinit(allocator);
                    };
                } else {
                    // If RETURNING * is empty, the row did not exist or was already deleted.
                    // This is a valid no-op state; we skip notifications for non-existent documents.
                    var id_hex_buf: [32]u8 = undefined;
                    std.log.debug("DELETE for table index {d}/{s}: no row found (already deleted)", .{ dop.table_index, doc_id.hexSlice(dop.id, &id_hex_buf) });
                }
            },
            .begin_transaction, .commit_transaction, .rollback_transaction, .checkpoint => unreachable,
        }
    }

    if (!manual_transaction_active) {
        conn.exec("COMMIT", .{}, .{}) catch |err| {
            const classified_err = types.classifyError(err);
            types.logDatabaseError("executeBatch COMMIT", classified_err, "");
            return classified_err;
        };
        transaction_active.store(false, .release);
    }
}

pub fn flushBatch(
    allocator: Allocator,
    conn: *sqlite.Db,
    transaction_active: *std.atomic.Value(bool),
    write_seq: *std.atomic.Value(u64),
    pending_writes_count: *std.atomic.Value(usize),
    write_mutex: *std.Thread.Mutex,
    flush_cond: *std.Thread.Condition,
    metadata_cache: anytype,
    batch: *std.ArrayListUnmanaged(WriteOp),
    last_batch_time: *i64,
    sm: *const schema_manager.SchemaManager,
    change_buffer: *ChangeBuffer,
    notifier_ptr: ?*const fn (ctx: ?*anyopaque) void,
    notifier_ctx: ?*anyopaque,
    stmt_cache: *sql.StatementCache,
) void {
    const batch_len = batch.items.len;
    std.log.debug("flushBatch: flushing {} ops", .{batch_len});

    var eviction_keys = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (eviction_keys.items) |k| allocator.free(k);
        eviction_keys.deinit(allocator);
    }
    for (batch.items) |op| {
        // SAFETY: initialized below in the switch statement
        var table_index: usize = undefined;
        // SAFETY: initialized below in the switch statement
        var id: types.DocId = undefined;
        // SAFETY: initialized below in the switch statement
        var ns: []const u8 = undefined;
        const has_affected = switch (op) {
            .upsert => |o| blk: {
                table_index = o.table_index;
                id = o.id;
                ns = o.namespace;
                break :blk true;
            },
            .delete => |o| blk: {
                table_index = o.table_index;
                id = o.id;
                ns = o.namespace;
                break :blk true;
            },
            else => false,
        };
        if (has_affected) {
            const table_metadata = sm.getTableByIndex(table_index) orelse continue;
            const key = reader.getCacheKey(allocator, table_metadata.table.name, ns, id) catch |err| {
                std.log.err("Failed to create cache key for eviction: {}", .{err});
                continue;
            };
            eviction_keys.append(allocator, key) catch |err| {
                std.log.err("Failed to append eviction key: {}", .{err});
                allocator.free(key);
                continue;
            };
        }
    }

    if (eviction_keys.items.len > 0) {
        metadata_cache.bulkEvict(eviction_keys.items);
    }

    var pending_changes = std.ArrayListUnmanaged(OwnedRowChange).empty;
    defer {
        for (pending_changes.items) |*c| c.deinit(allocator);
        pending_changes.deinit(allocator);
    }

    const result = executeBatch(allocator, conn, transaction_active, batch.items, &pending_changes, sm, stmt_cache);
    if (result) |_| {
        _ = write_seq.fetchAdd(1, .acq_rel);

        for (batch.items) |op| {
            if (op.getCompletionSignal()) |sig| sig.signal(null);
            op.deinit(allocator);
        }

        var dispatcher_woken = false;
        for (pending_changes.items) |*change| {
            change_buffer.push(change.*) catch |err| {
                std.log.err("Failed to push to change_buffer: {}", .{err});
                change.deinit(allocator);
                continue;
            };
            dispatcher_woken = true;
        }
        pending_changes.clearRetainingCapacity();

        if (dispatcher_woken) {
            if (notifier_ptr) |n| {
                n(notifier_ctx);
            }
        }
    } else |err| {
        const classified_err = types.classifyError(err);
        std.log.debug("Failed to execute batch, transaction rolled back: {}", .{classified_err});
        for (batch.items) |op| {
            if (op.getCompletionSignal()) |sig| sig.signal(classified_err);
            op.deinit(allocator);
        }
    }
    batch.clearRetainingCapacity();
    _ = pending_writes_count.fetchSub(batch_len, .release);
    write_mutex.lock();
    flush_cond.broadcast();
    write_mutex.unlock();
    last_batch_time.* = std.time.milliTimestamp();
}

pub fn writeThreadLoop(ctx: anytype) void {
    writeThreadLoopImpl(ctx) catch |err| {
        std.log.err("writeThreadLoop fatal error: {}", .{err});
    };
}

fn writeThreadLoopImpl(ctx: anytype) !void {
    // Signal that the write thread is up and running
    ctx.write_thread_ready.store(true, .release);
    ctx.write_mutex.lock();
    ctx.write_cond.signal();
    ctx.write_mutex.unlock();

    const batch_size = 200;
    const batch_timeout = ctx.performance_config.batch_timeout;

    var batch = std.ArrayListUnmanaged(WriteOp){};
    try batch.ensureTotalCapacity(ctx.allocator, batch_size);
    defer {
        for (batch.items) |op| {
            op.deinit(ctx.allocator);
        }
        batch.deinit(ctx.allocator);
    }

    var last_batch_time = std.time.milliTimestamp();

    while (!ctx.shutdown_requested.load(.acquire)) {
        // Collect operations for batch
        while (batch.items.len < batch_size) {
            if (ctx.write_queue.pop()) |op| {
                switch (op) {
                    .upsert, .delete => {
                        batch.append(ctx.allocator, op) catch |err| {
                            std.log.err("Failed to append to batch: {}", .{err});
                            op.deinit(ctx.allocator);
                            _ = ctx.pending_writes_count.fetchSub(1, .release);
                            ctx.write_mutex.lock();
                            ctx.flush_cond.broadcast();
                            ctx.write_mutex.unlock();
                            continue;
                        };
                    },
                    .begin_transaction => |top| {
                        if (batch.items.len > 0) {
                            flushBatch(ctx.allocator, &ctx._writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, &ctx.metadata_cache, &batch, &last_batch_time, ctx.schema_manager, &ctx.change_buffer, ctx.event_loop_notifier, ctx.notifier_ctx, &ctx.writer_stmt_cache);
                        }
                        if (ctx._writer_conn.exec("BEGIN TRANSACTION", .{}, .{})) |_| {
                            ctx.transaction_active.store(true, .release);
                            ctx.manual_transaction_active.store(true, .release);
                            if (top.completion_signal) |sig| sig.signal(null);
                        } else |err| {
                            if (top.completion_signal) |sig| sig.signal(types.classifyError(err));
                        }
                        _ = ctx.pending_writes_count.fetchSub(1, .release);
                        ctx.write_mutex.lock();
                        ctx.flush_cond.broadcast();
                        ctx.write_mutex.unlock();
                    },
                    .commit_transaction => |top| {
                        if (batch.items.len > 0) {
                            flushBatch(ctx.allocator, &ctx._writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, &ctx.metadata_cache, &batch, &last_batch_time, ctx.schema_manager, &ctx.change_buffer, ctx.event_loop_notifier, ctx.notifier_ctx, &ctx.writer_stmt_cache);
                        }
                        if (!ctx.transaction_active.load(.acquire)) {
                            if (top.completion_signal) |sig| sig.signal(StorageError.NoActiveTransaction);
                            _ = ctx.pending_writes_count.fetchSub(1, .release);
                            ctx.write_mutex.lock();
                            ctx.flush_cond.broadcast();
                            ctx.write_mutex.unlock();
                            continue;
                        }
                        if (ctx._writer_conn.exec("COMMIT", .{}, .{})) |_| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            _ = ctx.write_seq.fetchAdd(1, .acq_rel);
                            if (top.completion_signal) |sig| sig.signal(null);
                        } else |err| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            if (top.completion_signal) |sig| sig.signal(types.classifyError(err));
                        }
                        _ = ctx.pending_writes_count.fetchSub(1, .release);
                        ctx.write_mutex.lock();
                        ctx.flush_cond.broadcast();
                        ctx.write_mutex.unlock();
                    },
                    .rollback_transaction => |top| {
                        if (batch.items.len > 0) {
                            flushBatch(ctx.allocator, &ctx._writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, &ctx.metadata_cache, &batch, &last_batch_time, ctx.schema_manager, &ctx.change_buffer, ctx.event_loop_notifier, ctx.notifier_ctx, &ctx.writer_stmt_cache);
                        }
                        if (!ctx.transaction_active.load(.acquire)) {
                            if (top.completion_signal) |sig| sig.signal(StorageError.NoActiveTransaction);
                            _ = ctx.pending_writes_count.fetchSub(1, .release);
                            ctx.write_mutex.lock();
                            ctx.flush_cond.broadcast();
                            ctx.write_mutex.unlock();
                            continue;
                        }
                        if (ctx._writer_conn.exec("ROLLBACK", .{}, .{})) |_| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            if (top.completion_signal) |sig| sig.signal(null);
                        } else |err| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            if (top.completion_signal) |sig| sig.signal(types.classifyError(err));
                        }
                        _ = ctx.pending_writes_count.fetchSub(1, .release);
                        ctx.write_mutex.lock();
                        ctx.flush_cond.broadcast();
                        ctx.write_mutex.unlock();
                    },
                    .checkpoint => |cop| {
                        if (batch.items.len > 0) {
                            flushBatch(ctx.allocator, &ctx._writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, &ctx.metadata_cache, &batch, &last_batch_time, ctx.schema_manager, &ctx.change_buffer, ctx.event_loop_notifier, ctx.notifier_ctx, &ctx.writer_stmt_cache);
                        }
                        if (connection.internalExecuteCheckpoint(&ctx._writer_conn, ctx.allocator, ctx.db_path, ctx.options.in_memory, cop.mode)) |stats| {
                            cop.completion_signal.signalWithResult(stats);
                        } else |err| {
                            cop.completion_signal.signal(types.classifyError(err));
                        }
                        _ = ctx.pending_writes_count.fetchSub(1, .release);
                        ctx.write_mutex.lock();
                        ctx.flush_cond.broadcast();
                        ctx.write_mutex.unlock();
                    },
                }
            } else {
                break;
            }
        }

        const now = std.time.milliTimestamp();
        const time_since_last = now - last_batch_time;

        const should_flush = batch.items.len >= batch_size or
            (batch.items.len > 0 and time_since_last >= batch_timeout);

        if (should_flush) {
            flushBatch(ctx.allocator, &ctx._writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, &ctx.metadata_cache, &batch, &last_batch_time, ctx.schema_manager, &ctx.change_buffer, ctx.event_loop_notifier, ctx.notifier_ctx, &ctx.writer_stmt_cache);
        } else {
            ctx.write_mutex.lock();
            defer ctx.write_mutex.unlock();
            ctx.write_cond.timedWait(&ctx.write_mutex, 1 * std.time.ns_per_ms) catch |err| {
                if (err != error.Timeout) {
                    std.log.err("write_cond.timedWait failed: {}", .{err});
                }
            };
        }
    }

    // Drain
    while (ctx.write_queue.pop()) |op| {
        switch (op) {
            .upsert, .delete => {
                batch.append(ctx.allocator, op) catch {
                    op.deinit(ctx.allocator);
                    _ = ctx.pending_writes_count.fetchSub(1, .release);
                    ctx.write_mutex.lock();
                    ctx.flush_cond.broadcast();
                    ctx.write_mutex.unlock();
                };
            },
            else => {
                if (op.getCompletionSignal()) |sig| sig.signal(StorageError.InvalidOperation);
                op.deinit(ctx.allocator);
                _ = ctx.pending_writes_count.fetchSub(1, .release);
                ctx.write_mutex.lock();
                ctx.flush_cond.broadcast();
                ctx.write_mutex.unlock();
            },
        }
    }

    if (batch.items.len > 0) {
        flushBatch(ctx.allocator, &ctx._writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, &ctx.metadata_cache, &batch, &last_batch_time, ctx.schema_manager, &ctx.change_buffer, ctx.event_loop_notifier, ctx.notifier_ctx, &ctx.writer_stmt_cache);
    }
}

// Forward declaration of StorageEngine facade to avoid circular issues if needed,
// but we'll try to keep the interface clean.
// For now, we'll assume the functions take a context or specific fields.

pub fn executeUpsert(
    allocator: Allocator,
    conn: *sqlite.Db,
    op: anytype,
    table_metadata: *const schema_manager.TableMetadata,
    stmt_cache: *sql.StatementCache,
) !?types.TypedRow {
    const sql_str = op.sql;
    var mstmt = try stmt_cache.acquire(allocator, conn, sql_str);
    defer mstmt.release();
    const stmt = mstmt.stmt;

    var bind_idx: c_int = 1;
    const id_bytes = doc_id.toBytes(op.id);
    if (sql.bindBlobTransient(stmt, bind_idx, &id_bytes) != sqlite.c.SQLITE_OK) return types.classifyStepError(conn);
    bind_idx += 1;
    if (sql.bindTextTransient(stmt, bind_idx, op.namespace) != sqlite.c.SQLITE_OK) return types.classifyStepError(conn);
    bind_idx += 1;

    for (op.values) |val| {
        try val.bindSQLite(conn, stmt, bind_idx, allocator);
        bind_idx += 1;
    }

    if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return types.classifyStepError(conn);
    bind_idx += 1;
    if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return types.classifyStepError(conn);
    bind_idx += 1;

    const rc = sqlite.c.sqlite3_step(stmt);
    if (rc == sqlite.c.SQLITE_ROW) {
        return try reader.decodeTypedRow(allocator, stmt, table_metadata);
    }
    if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return types.classifyStepError(conn);
    return null;
}

pub fn executeDelete(
    allocator: Allocator,
    conn: *sqlite.Db,
    op: anytype,
    table_metadata: *const schema_manager.TableMetadata,
    stmt_cache: *sql.StatementCache,
) !?types.TypedRow {
    const sql_str = op.sql;
    var mstmt = try stmt_cache.acquire(allocator, conn, sql_str);
    defer mstmt.release();
    const stmt = mstmt.stmt;

    const id_bytes = doc_id.toBytes(op.id);
    if (sql.bindBlobTransient(stmt, 1, &id_bytes) != sqlite.c.SQLITE_OK) return types.classifyStepError(conn);
    if (sql.bindTextTransient(stmt, 2, op.namespace) != sqlite.c.SQLITE_OK) return types.classifyStepError(conn);

    const rc = sqlite.c.sqlite3_step(stmt);
    if (rc == sqlite.c.SQLITE_ROW) {
        return try reader.decodeTypedRow(allocator, stmt, table_metadata);
    }
    if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return types.classifyStepError(conn);
    return null;
}
