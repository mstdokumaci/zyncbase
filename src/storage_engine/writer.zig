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
const OwnedRowChange = @import("../change_buffer.zig").OwnedRowChange;
const WriteContext = @import("write_context.zig").WriteContext;

const DocId = storage_values.DocId;
const MetadataCacheKey = storage_values.MetadataCacheKey;
const TypedRow = storage_values.TypedRow;
const WriteOp = write_queue.WriteOp;
const StorageError = errors.StorageError;

fn execTransactionControl(conn: *sqlite.Db, statement: [:0]const u8) !void {
    var err_msg: [*c]u8 = null;
    const rc = sqlite.c.sqlite3_exec(conn.db, statement.ptr, null, null, &err_msg);
    if (err_msg != null) sqlite.c.sqlite3_free(err_msg);
    if (rc != sqlite.c.SQLITE_OK) return errors.classifyStepError(conn);
}

fn getDocumentHelper(
    wc: *WriteContext,
    table_index: usize,
    namespace_id: i64,
    id: DocId,
    sql_cache: *std.AutoHashMap(usize, []const u8),
) !?TypedRow {
    const table_metadata = wc.schema.getTableByIndex(table_index) orelse return null;
    const sql_str = if (sql_cache.get(table_index)) |s| s else blk: {
        const s = try sql.buildSelectDocumentSql(wc.allocator, table_metadata);
        try sql_cache.put(table_index, s);
        break :blk s;
    };
    var mstmt = try wc.stmt_cache.acquire(wc.allocator, &wc.conn, sql_str);
    defer mstmt.release();
    return reader.execSelectDocumentTyped(wc.allocator, &wc.conn, mstmt.stmt, id, namespace_id, table_metadata);
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

fn executeBatch(
    wc: *WriteContext,
    ops: []const WriteOp,
    pending_changes: *std.ArrayListUnmanaged(OwnedRowChange),
) !void {
    wc.conn.exec("BEGIN TRANSACTION", .{}, .{}) catch |err| {
        const classified_err = errors.classifyError(err);
        errors.logDatabaseError("executeBatch BEGIN", classified_err, "");
        return classified_err;
    };
    wc.markTransactionActive();

    errdefer {
        wc.conn.exec("ROLLBACK", .{}, .{}) catch |rollback_err| {
            const classified_err = errors.classifyError(rollback_err);
            errors.logDatabaseError("executeBatch ROLLBACK", classified_err, "");
        };
        wc.markTransactionInactive();
    }
    var sql_cache = std.AutoHashMap(usize, []const u8).init(wc.allocator);
    defer {
        var it = sql_cache.valueIterator();
        while (it.next()) |sql_str| wc.allocator.free(sql_str.*);
        sql_cache.deinit();
    }

    for (ops) |op| {
        switch (op) {
            .upsert => |iop| {
                const table_metadata = wc.schema.getTableByIndex(iop.table_index) orelse return StorageError.UnknownTable;
                const namespace_id = if (table_metadata.namespaced) iop.namespace_id else schema.global_namespace_id;
                const owner_doc_id = if (table_metadata.is_users_table) iop.id else iop.owner_doc_id;
                var old_row: ?TypedRow = null;
                const capture_res = getDocumentHelper(wc, iop.table_index, namespace_id, iop.id, &sql_cache);
                if (capture_res) |orow| {
                    old_row = orow;
                } else |err| {
                    std.log.err("Failed to capture old state (pre-UPSERT) for table index {d}: {}", .{ iop.table_index, err });
                }
                const maybe_new_row = executeUpsert(wc, iop, namespace_id, owner_doc_id, table_metadata) catch |err| {
                    if (old_row) |r| r.deinit(wc.allocator);
                    const classified_err = errors.classifyError(err);
                    errors.logDatabaseError("executeBatch UPSERT", classified_err, table_metadata.name);
                    return classified_err;
                };

                if (maybe_new_row) |new_row| {
                    const op_type: OwnedRowChange.Operation = if (old_row == null) .insert else .update;
                    pushOwnedChange(wc.allocator, pending_changes, namespace_id, iop.table_index, op_type, old_row, new_row) catch |err| {
                        std.log.err("Failed to capture row change: {}", .{err});
                        if (old_row) |r| r.deinit(wc.allocator);
                        var r = new_row;
                        r.deinit(wc.allocator);
                    };
                } else {
                    // The upsert is guarded by namespace_id. A missing RETURNING row means
                    // the id already exists in another namespace, which we surface as a
                    // dropped write rather than silently mutating hidden data.
                    var id_hex_buf: [32]u8 = undefined;
                    std.log.debug("UPSERT for table index {d}/{s} conflicted with a different namespace", .{ iop.table_index, doc_id.hexSlice(iop.id, &id_hex_buf) });
                    if (old_row) |r| r.deinit(wc.allocator);
                    continue;
                }
            },
            .delete => |dop| {
                const table_metadata = wc.schema.getTableByIndex(dop.table_index) orelse return StorageError.UnknownTable;
                const namespace_id = if (table_metadata.namespaced) dop.namespace_id else schema.global_namespace_id;
                const maybe_old_row = executeDelete(wc, dop, namespace_id, table_metadata) catch |err| {
                    const classified_err = errors.classifyError(err);
                    errors.logDatabaseError("executeBatch DELETE", classified_err, table_metadata.name);
                    return classified_err;
                };

                // For DELETE, the RETURNING * result IS the old row.
                if (maybe_old_row) |old_row| {
                    pushOwnedChange(wc.allocator, pending_changes, namespace_id, dop.table_index, .delete, old_row, null) catch |err| {
                        std.log.err("Failed to capture row change: {}", .{err});
                        var r = old_row;
                        r.deinit(wc.allocator);
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

    wc.conn.exec("COMMIT", .{}, .{}) catch |err| {
        const classified_err = errors.classifyError(err);
        errors.logDatabaseError("executeBatch COMMIT", classified_err, "");
        return classified_err;
    };
    wc.markTransactionInactive();
}

pub fn flushBatch(
    wc: *WriteContext,
    batch: *std.ArrayListUnmanaged(WriteOp),
    last_batch_time: *i64,
) void {
    const batch_len = batch.items.len;
    std.log.debug("flushBatch: flushing {} ops", .{batch_len});

    var eviction_keys = std.ArrayListUnmanaged(MetadataCacheKey).empty;
    defer eviction_keys.deinit(wc.allocator);
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
            const table_metadata = wc.schema.getTableByIndex(table_index) orelse continue;
            const key = reader.getCacheKey(table_metadata, namespace_id, id);
            eviction_keys.append(wc.allocator, key) catch |err| {
                std.log.err("Failed to append eviction key: {}", .{err});
                continue;
            };
        }
    }

    var pending_changes = std.ArrayListUnmanaged(OwnedRowChange).empty;
    defer {
        for (pending_changes.items) |*c| c.deinit(wc.allocator);
        pending_changes.deinit(wc.allocator);
    }

    const result = executeBatch(wc, batch.items, &pending_changes);
    if (result) |_| {
        wc.bumpVersion();

        if (eviction_keys.items.len > 0) {
            wc.metadata_cache.bulkEvict(eviction_keys.items);
        }

        for (batch.items) |op| {
            if (op.getCompletionSignal()) |sig| sig.signal(null);
            op.deinit(wc.allocator);
        }

        var dispatcher_woken = false;
        for (pending_changes.items) |*change| {
            wc.change_buffer.push(change.*) catch |err| {
                std.log.err("Failed to push to change_buffer: {}", .{err});
                change.deinit(wc.allocator);
                continue;
            };
            dispatcher_woken = true;
        }
        pending_changes.clearRetainingCapacity();

        if (dispatcher_woken) {
            wc.notifyChanges();
        }
    } else |err| {
        const classified_err = errors.classifyError(err);
        std.log.debug("Failed to execute batch, transaction rolled back: {}", .{classified_err});
        for (batch.items) |op| {
            if (op.getCompletionSignal()) |sig| sig.signal(classified_err);
            op.deinit(wc.allocator);
        }
    }
    batch.clearRetainingCapacity();
    wc.endOp(batch_len);
    wc.wakeFlushWaiters();
    last_batch_time.* = std.time.milliTimestamp();
}

pub fn writeThreadLoop(wc: *WriteContext) void {
    writeThreadLoopImpl(wc) catch |err| {
        std.log.err("writeThreadLoop fatal error: {}", .{err});
    };
}

fn waitForWriteSignal(wc: *WriteContext, timeout_ns: ?u64) void {
    wc.mutex.lock();
    defer wc.mutex.unlock();

    if (wc.shutdown_requested.load(.acquire) or wc.queue.hasItems()) {
        return;
    }

    if (timeout_ns) |ns| {
        wc.work_cond.timedWait(&wc.mutex, ns) catch |err| {
            if (err != error.Timeout) {
                std.log.err("write_cond.timedWait failed: {}", .{err});
            }
        };
    } else {
        wc.work_cond.wait(&wc.mutex);
    }
}

fn writeThreadLoopImpl(wc: *WriteContext) !void {
    // Signal that the write thread is up and running
    wc.is_ready.store(true, .release);
    wc.mutex.lock();
    wc.work_cond.signal();
    wc.mutex.unlock();

    const batch_size = if (wc.performance_config.batch_writes)
        wc.performance_config.batch_size
    else
        1;
    const batch_timeout_ms: i64 = if (wc.performance_config.batch_writes)
        @intCast(wc.performance_config.batch_timeout)
    else
        0;

    var batch = std.ArrayListUnmanaged(WriteOp){};
    try batch.ensureTotalCapacity(wc.allocator, batch_size);
    defer {
        for (batch.items) |op| {
            op.deinit(wc.allocator);
        }
        batch.deinit(wc.allocator);
    }

    var last_batch_time = std.time.milliTimestamp();

    while (!wc.shutdown_requested.load(.acquire)) {
        // Collect operations for batch
        while (batch.items.len < batch_size) {
            if (wc.queue.pop()) |op| {
                switch (op) {
                    .upsert, .delete => {
                        batch.append(wc.allocator, op) catch |err| {
                            std.log.err("Failed to append to batch: {}", .{err});
                            op.deinit(wc.allocator);
                            wc.endOp(1);
                            wc.wakeFlushWaiters();
                            continue;
                        };
                    },
                    .batch => |bop| {
                        if (batch.items.len > 0) {
                            flushBatch(wc, &batch, &last_batch_time);
                        }
                        executeBatchOp(wc, bop, &last_batch_time);
                    },
                    .upsert_namespace => |nop| {
                        if (batch.items.len > 0) {
                            flushBatch(wc, &batch, &last_batch_time);
                        }
                        if (sql.resolveNamespaceId(wc.allocator, &wc.conn, &wc.stmt_cache, nop.namespace)) |namespace_id| {
                            nop.result.* = namespace_id;
                            nop.completion_signal.signal(null);
                        } else |err| {
                            nop.completion_signal.signal(errors.classifyError(err));
                        }
                        op.deinit(wc.allocator);
                        wc.endOp(1);
                        wc.wakeFlushWaiters();
                    },
                    .checkpoint => |cop| {
                        if (batch.items.len > 0) {
                            flushBatch(wc, &batch, &last_batch_time);
                        }
                        if (connection.internalExecuteCheckpoint(&wc.conn, wc.allocator, wc.db_path, wc.in_memory, cop.mode)) |stats| {
                            cop.completion_signal.signalWithResult(stats);
                        } else |err| {
                            cop.completion_signal.signal(errors.classifyError(err));
                        }
                        wc.endOp(1);
                        wc.wakeFlushWaiters();
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
            flushBatch(wc, &batch, &last_batch_time);
        } else {
            const timeout_ns: ?u64 = if (batch.items.len > 0)
                @as(u64, @intCast(batch_timeout_ms - time_since_last)) * std.time.ns_per_ms
            else
                null;
            waitForWriteSignal(wc, timeout_ns);
        }
    }

    // Drain
    while (wc.queue.pop()) |op| {
        switch (op) {
            .upsert, .delete => {
                batch.append(wc.allocator, op) catch {
                    op.deinit(wc.allocator);
                    wc.endOp(1);
                    wc.wakeFlushWaiters();
                };
            },
            .batch => |bop| {
                if (batch.items.len > 0) {
                    flushBatch(wc, &batch, &last_batch_time);
                }
                executeBatchOp(wc, bop, &last_batch_time);
            },
            else => {
                if (op.getCompletionSignal()) |sig| sig.signal(StorageError.InvalidOperation);
                op.deinit(wc.allocator);
                wc.endOp(1);
                wc.wakeFlushWaiters();
            },
        }
    }

    if (batch.items.len > 0) {
        flushBatch(wc, &batch, &last_batch_time);
    }
}

// Forward declaration of StorageEngine facade to avoid circular issues if needed,
// but we'll try to keep the interface clean.
// For now, we'll assume the functions take a context or specific fields.

pub fn executeBatchOp(
    wc: *WriteContext,
    bop: anytype,
    last_batch_time: *i64,
) void {
    const entries = bop.entries;
    var tx_started = false;
    var final_err: ?anyerror = null;
    defer {
        if (tx_started) {
            execTransactionControl(&wc.conn, "ROLLBACK") catch |rollback_err| {
                errors.logDatabaseError("executeBatchOp ROLLBACK", errors.classifyError(rollback_err), "");
            };
            wc.markTransactionInactive();
        }

        if (bop.completion_signal) |sig| sig.signal(final_err);

        for (entries) |entry| {
            wc.allocator.free(entry.sql);
            if (entry.values) |vals| {
                for (vals) |v| v.deinit(wc.allocator);
                wc.allocator.free(vals);
            }
        }
        wc.allocator.free(entries);

        wc.endOp(1);
        wc.wakeFlushWaiters();
        last_batch_time.* = std.time.milliTimestamp();
    }

    // 1. Build eviction keys from all entries
    var eviction_keys = std.ArrayListUnmanaged(MetadataCacheKey).empty;
    defer eviction_keys.deinit(wc.allocator);
    for (entries) |entry| {
        const table_metadata = wc.schema.getTableByIndex(entry.table_index) orelse continue;
        const key = reader.getCacheKey(table_metadata, entry.namespace_id, entry.id);
        eviction_keys.append(wc.allocator, key) catch |err| {
            std.log.err("Failed to allocate eviction key in batch: {}", .{err});
            continue;
        };
    }
    // 2. Execute all entries in a single transaction
    var pending_changes = std.ArrayListUnmanaged(OwnedRowChange).empty;
    defer {
        for (pending_changes.items) |*c| c.deinit(wc.allocator);
        pending_changes.deinit(wc.allocator);
    }

    execTransactionControl(&wc.conn, "BEGIN TRANSACTION") catch |err| {
        const classified_err = errors.classifyError(err);
        errors.logDatabaseError("executeBatchOp BEGIN", classified_err, "");
        final_err = classified_err;
        return;
    };
    tx_started = true;
    wc.markTransactionActive();

    var sql_cache = std.AutoHashMap(usize, []const u8).init(wc.allocator);
    defer {
        var it = sql_cache.valueIterator();
        while (it.next()) |sql_str| wc.allocator.free(sql_str.*);
        sql_cache.deinit();
    }

    for (entries) |entry| {
        const table_metadata = wc.schema.getTableByIndex(entry.table_index) orelse {
            final_err = StorageError.UnknownTable;
            std.log.debug("Batch entry references unknown table index {d}", .{entry.table_index});
            break;
        };
        const namespace_id = if (table_metadata.namespaced) entry.namespace_id else schema.global_namespace_id;

        switch (entry.kind) {
            .upsert => {
                const owner_doc_id = if (table_metadata.is_users_table) entry.id else entry.owner_doc_id;
                var old_row: ?TypedRow = null;
                if (getDocumentHelper(wc, entry.table_index, namespace_id, entry.id, &sql_cache)) |orow| {
                    old_row = orow;
                } else |err| {
                    std.log.err("Failed to capture old state (pre-UPSERT) for table index {d}: {}", .{ entry.table_index, err });
                }

                if (executeUpsert(wc, entry, namespace_id, owner_doc_id, table_metadata)) |maybe_new_row| {
                    if (maybe_new_row) |new_row| {
                        const op_type: OwnedRowChange.Operation = if (old_row == null) .insert else .update;
                        if (pushOwnedChange(wc.allocator, &pending_changes, namespace_id, entry.table_index, op_type, old_row, new_row)) |_| {
                            // success
                        } else |err| {
                            std.log.err("Failed to capture row change: {}", .{err});
                            if (old_row) |r| r.deinit(wc.allocator);
                            var r = new_row;
                            r.deinit(wc.allocator);
                        }
                    } else {
                        var id_hex_buf: [32]u8 = undefined;
                        std.log.debug("UPSERT for table index {d}/{s} conflicted with a different namespace", .{ entry.table_index, doc_id.hexSlice(entry.id, &id_hex_buf) });
                        if (old_row) |r| r.deinit(wc.allocator);
                    }
                } else |err| {
                    if (old_row) |r| r.deinit(wc.allocator);
                    const classified_err = errors.classifyError(err);
                    errors.logDatabaseError("executeBatchOp UPSERT", classified_err, table_metadata.name);
                    final_err = classified_err;
                    break;
                }
            },
            .delete => {
                if (executeDelete(wc, entry, namespace_id, table_metadata)) |maybe_old_row| {
                    if (maybe_old_row) |old_row| {
                        if (pushOwnedChange(wc.allocator, &pending_changes, namespace_id, entry.table_index, .delete, old_row, null)) |_| {
                            // success
                        } else |err| {
                            std.log.err("Failed to capture row change: {}", .{err});
                            var r = old_row;
                            r.deinit(wc.allocator);
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
        if (execTransactionControl(&wc.conn, "COMMIT")) |_| {
            tx_started = false;
            wc.markTransactionInactive();
            wc.bumpVersion();

            if (eviction_keys.items.len > 0) {
                wc.metadata_cache.bulkEvict(eviction_keys.items);
            }

            var dispatcher_woken = false;
            for (pending_changes.items) |*change| {
                wc.change_buffer.push(change.*) catch |err| {
                    std.log.err("Failed to push to change_buffer: {}", .{err});
                    change.deinit(wc.allocator);
                    continue;
                };
                dispatcher_woken = true;
            }
            pending_changes.clearRetainingCapacity();

            if (dispatcher_woken) {
                wc.notifyChanges();
            }
        } else |err| {
            const classified_err = errors.classifyError(err);
            errors.logDatabaseError("executeBatchOp COMMIT", classified_err, "");
            final_err = classified_err;
        }
    }
}

fn executeUpsert(
    wc: *WriteContext,
    op: anytype,
    namespace_id: i64,
    owner_id: DocId,
    table_metadata: *const schema.Table,
) !?TypedRow {
    const sql_str = op.sql;
    var mstmt = try wc.stmt_cache.acquire(wc.allocator, &wc.conn, sql_str);
    defer mstmt.release();
    const stmt = mstmt.stmt;

    var bind_idx: c_int = 1;
    const id_bytes = doc_id.toBytes(op.id);
    if (sql.bindBlobTransient(stmt, bind_idx, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);
    bind_idx += 1;
    if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);
    bind_idx += 1;
    const owner_id_bytes = doc_id.toBytes(owner_id);
    if (sql.bindBlobTransient(stmt, bind_idx, &owner_id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);
    bind_idx += 1;
    if (table_metadata.is_users_table) {
        var external_id_buf: [32]u8 = undefined;
        const external_id = doc_id.hexSlice(op.id, &external_id_buf);
        if (sql.bindTextTransient(stmt, bind_idx, external_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);
        bind_idx += 1;
    }

    if (@typeInfo(@TypeOf(op.values)) == .optional) {
        if (op.values) |vals| {
            for (vals) |val| {
                try sql.bindTypedValue(val, &wc.conn, stmt, bind_idx, wc.allocator);
                bind_idx += 1;
            }
        }
    } else {
        for (op.values) |val| {
            try sql.bindTypedValue(val, &wc.conn, stmt, bind_idx, wc.allocator);
            bind_idx += 1;
        }
    }

    if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);
    bind_idx += 1;
    if (sqlite.c.sqlite3_bind_int64(stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);
    bind_idx += 1;

    const rc = sqlite.c.sqlite3_step(stmt);
    if (rc == sqlite.c.SQLITE_ROW) {
        return try reader.decodeTypedRow(wc.allocator, stmt, table_metadata);
    }
    if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(&wc.conn);
    return null;
}

fn executeDelete(
    wc: *WriteContext,
    op: anytype,
    namespace_id: i64,
    table_metadata: *const schema.Table,
) !?TypedRow {
    const sql_str = op.sql;
    var mstmt = try wc.stmt_cache.acquire(wc.allocator, &wc.conn, sql_str);
    defer mstmt.release();
    const stmt = mstmt.stmt;

    const id_bytes = doc_id.toBytes(op.id);
    if (sql.bindBlobTransient(stmt, 1, &id_bytes) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);
    if (sqlite.c.sqlite3_bind_int64(stmt, 2, namespace_id) != sqlite.c.SQLITE_OK) return errors.classifyStepError(&wc.conn);

    const rc = sqlite.c.sqlite3_step(stmt);
    if (rc == sqlite.c.SQLITE_ROW) {
        return try reader.decodeTypedRow(wc.allocator, stmt, table_metadata);
    }
    if (rc != sqlite.c.SQLITE_DONE and rc != sqlite.c.SQLITE_ROW) return errors.classifyStepError(&wc.conn);
    return null;
}
