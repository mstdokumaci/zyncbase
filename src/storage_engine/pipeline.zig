const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const reader = @import("reader.zig");
const connection = @import("connection.zig");
const types = @import("types.zig");

const WriteOp = types.WriteOp;
const StorageError = types.StorageError;

pub fn executeBatch(
    allocator: Allocator,
    conn: *sqlite.Db,
    transaction_active: *std.atomic.Value(bool),
    ops: []const WriteOp,
) !void {
    const manual_transaction_active = transaction_active.load(.acquire);

    if (!manual_transaction_active) {
        conn.exec("BEGIN TRANSACTION", .{}, .{}) catch |err| {
            const classified_err = reader.classifyError(err);
            reader.logDatabaseError("executeBatch BEGIN", classified_err, "");
            return classified_err;
        };
        transaction_active.store(true, .release);
    }

    errdefer {
        if (!manual_transaction_active) {
            conn.exec("ROLLBACK", .{}, .{}) catch |rollback_err| {
                const classified_err = reader.classifyError(rollback_err);
                reader.logDatabaseError("executeBatch ROLLBACK", classified_err, "");
            };
            transaction_active.store(false, .release);
        }
    }

    for (ops) |op| {
        switch (op) {
            .insert => |iop| executeInsert(allocator, conn, iop) catch |err| {
                const classified_err = reader.classifyError(err);
                reader.logDatabaseError("executeBatch INSERT", classified_err, iop.table);
                return classified_err;
            },
            .update => |uop| executeUpdate(allocator, conn, uop) catch |err| {
                const classified_err = reader.classifyError(err);
                reader.logDatabaseError("executeBatch UPDATE", classified_err, uop.table);
                return classified_err;
            },
            .delete => |dop| executeDelete(allocator, conn, dop) catch |err| {
                const classified_err = reader.classifyError(err);
                reader.logDatabaseError("executeBatch DELETE", classified_err, dop.table);
                return classified_err;
            },
            .ddl => |dop| {
                const sql = dop.sql;
                var it = std.mem.splitScalar(u8, sql, ';');
                while (it.next()) |stmt_raw| {
                    const stmt = std.mem.trim(u8, stmt_raw, " \r\n\t");
                    if (stmt.len == 0) continue;

                    conn.execDynamic(stmt, .{}, .{}) catch |err| {
                        std.log.err("executeBatch DDL error: {}\nSQL:\n{s}", .{ err, stmt });
                        const classified_err = reader.classifyError(err);
                        reader.logDatabaseError("executeBatch DDL", classified_err, stmt);
                        return classified_err;
                    };
                }
            },
            .begin_transaction, .commit_transaction, .rollback_transaction, .checkpoint => unreachable,
        }
    }

    if (!manual_transaction_active) {
        conn.exec("COMMIT", .{}, .{}) catch |err| {
            const classified_err = reader.classifyError(err);
            reader.logDatabaseError("executeBatch COMMIT", classified_err, "");
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
        var table: []const u8 = undefined;
        // SAFETY: initialized below in the switch statement
        var id: []const u8 = undefined;
        // SAFETY: initialized below in the switch statement
        var ns: []const u8 = undefined;
        const has_affected = switch (op) {
            .insert => |o| blk: {
                table = o.table;
                id = o.id;
                ns = o.namespace;
                break :blk true;
            },
            .update => |o| blk: {
                table = o.table;
                id = o.id;
                ns = o.namespace;
                break :blk true;
            },
            .delete => |o| blk: {
                table = o.table;
                id = o.id;
                ns = o.namespace;
                break :blk true;
            },
            else => false,
        };
        if (has_affected) {
            const key = reader.getCacheKey(allocator, table, ns, id) catch |err| {
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

    const result = executeBatch(allocator, conn, transaction_active, batch.items);
    if (result) |_| {
        _ = write_seq.fetchAdd(1, .acq_rel);

        for (batch.items) |op| {
            if (op.getCompletionSignal()) |sig| sig.signal(null);
            op.deinit(allocator);
        }
    } else |err| {
        const classified_err = reader.classifyError(err);
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
                    .insert, .update, .delete, .ddl => {
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
                            flushBatch(ctx.allocator, &ctx.writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, ctx.metadata_cache, &batch, &last_batch_time);
                        }
                        if (ctx.writer_conn.exec("BEGIN TRANSACTION", .{}, .{})) |_| {
                            ctx.transaction_active.store(true, .release);
                            ctx.manual_transaction_active.store(true, .release);
                            if (top.completion_signal) |sig| sig.signal(null);
                        } else |err| {
                            if (top.completion_signal) |sig| sig.signal(reader.classifyError(err));
                        }
                        _ = ctx.pending_writes_count.fetchSub(1, .release);
                        ctx.write_mutex.lock();
                        ctx.flush_cond.broadcast();
                        ctx.write_mutex.unlock();
                    },
                    .commit_transaction => |top| {
                        if (batch.items.len > 0) {
                            flushBatch(ctx.allocator, &ctx.writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, ctx.metadata_cache, &batch, &last_batch_time);
                        }
                        if (!ctx.transaction_active.load(.acquire)) {
                            if (top.completion_signal) |sig| sig.signal(StorageError.NoActiveTransaction);
                            _ = ctx.pending_writes_count.fetchSub(1, .release);
                            ctx.write_mutex.lock();
                            ctx.flush_cond.broadcast();
                            ctx.write_mutex.unlock();
                            continue;
                        }
                        if (ctx.writer_conn.exec("COMMIT", .{}, .{})) |_| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            _ = ctx.write_seq.fetchAdd(1, .acq_rel);
                            if (top.completion_signal) |sig| sig.signal(null);
                        } else |err| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            if (top.completion_signal) |sig| sig.signal(reader.classifyError(err));
                        }
                        _ = ctx.pending_writes_count.fetchSub(1, .release);
                        ctx.write_mutex.lock();
                        ctx.flush_cond.broadcast();
                        ctx.write_mutex.unlock();
                    },
                    .rollback_transaction => |top| {
                        if (batch.items.len > 0) {
                            flushBatch(ctx.allocator, &ctx.writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, ctx.metadata_cache, &batch, &last_batch_time);
                        }
                        if (!ctx.transaction_active.load(.acquire)) {
                            if (top.completion_signal) |sig| sig.signal(StorageError.NoActiveTransaction);
                            _ = ctx.pending_writes_count.fetchSub(1, .release);
                            ctx.write_mutex.lock();
                            ctx.flush_cond.broadcast();
                            ctx.write_mutex.unlock();
                            continue;
                        }
                        if (ctx.writer_conn.exec("ROLLBACK", .{}, .{})) |_| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            if (top.completion_signal) |sig| sig.signal(null);
                        } else |err| {
                            ctx.transaction_active.store(false, .release);
                            ctx.manual_transaction_active.store(false, .release);
                            if (top.completion_signal) |sig| sig.signal(reader.classifyError(err));
                        }
                        _ = ctx.pending_writes_count.fetchSub(1, .release);
                        ctx.write_mutex.lock();
                        ctx.flush_cond.broadcast();
                        ctx.write_mutex.unlock();
                    },
                    .checkpoint => |cop| {
                        if (batch.items.len > 0) {
                            flushBatch(ctx.allocator, &ctx.writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, ctx.metadata_cache, &batch, &last_batch_time);
                        }
                        if (connection.internalExecuteCheckpoint(&ctx.writer_conn, ctx.allocator, ctx.db_path, ctx.options.in_memory, cop.mode)) |stats| {
                            cop.completion_signal.signalWithResult(stats);
                        } else |err| {
                            cop.completion_signal.signal(reader.classifyError(err));
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
            flushBatch(ctx.allocator, &ctx.writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, ctx.metadata_cache, &batch, &last_batch_time);
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
            .insert, .update, .delete => {
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
        flushBatch(ctx.allocator, &ctx.writer_conn, &ctx.transaction_active, &ctx.write_seq, &ctx.pending_writes_count, &ctx.write_mutex, &ctx.flush_cond, ctx.metadata_cache, &batch, &last_batch_time);
    }
}

// Forward declaration of StorageEngine facade to avoid circular issues if needed,
// but we'll try to keep the interface clean.
// For now, we'll assume the functions take a context or specific fields.

pub fn executeInsert(
    allocator: Allocator,
    conn: *sqlite.Db,
    op: anytype,
) !void {
    const sql = op.sql;
    var stmt = conn.prepareDynamic(sql) catch |err| return reader.classifyError(err);
    defer stmt.deinit();

    const id_z = try allocator.dupeZ(u8, op.id);
    defer allocator.free(id_z);
    const ns_z = try allocator.dupeZ(u8, op.namespace);
    defer allocator.free(ns_z);

    var bind_idx: c_int = 1;
    if (sqlite.c.sqlite3_bind_text(stmt.stmt, bind_idx, id_z.ptr, @intCast(op.id.len), @ptrFromInt(types.sqlite_transient)) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    bind_idx += 1;
    if (sqlite.c.sqlite3_bind_text(stmt.stmt, bind_idx, ns_z.ptr, @intCast(op.namespace.len), @ptrFromInt(types.sqlite_transient)) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    bind_idx += 1;

    for (op.values) |val| {
        try reader.bindTypedValue(stmt, bind_idx, val);
        bind_idx += 1;
    }

    if (sqlite.c.sqlite3_bind_int64(stmt.stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    bind_idx += 1;
    if (sqlite.c.sqlite3_bind_int64(stmt.stmt, bind_idx, op.timestamp) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    bind_idx += 1;

    const rc = sqlite.c.sqlite3_step(stmt.stmt);
    if (rc != sqlite.c.SQLITE_DONE) return reader.classifyStepError(conn);
}

pub fn executeUpdate(
    allocator: Allocator,
    conn: *sqlite.Db,
    op: anytype,
) !void {
    const sql = op.sql;
    var stmt = conn.prepareDynamic(sql) catch |err| return reader.classifyError(err);
    defer stmt.deinit();

    const id_z = try allocator.dupeZ(u8, op.id);
    defer allocator.free(id_z);
    const ns_z = try allocator.dupeZ(u8, op.namespace);
    defer allocator.free(ns_z);

    if (sqlite.c.sqlite3_bind_text(stmt.stmt, 1, id_z.ptr, @intCast(op.id.len), @ptrFromInt(types.sqlite_transient)) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    if (sqlite.c.sqlite3_bind_text(stmt.stmt, 2, ns_z.ptr, @intCast(op.namespace.len), @ptrFromInt(types.sqlite_transient)) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    try reader.bindTypedValue(stmt, 3, op.values[0]);
    if (sqlite.c.sqlite3_bind_int64(stmt.stmt, 4, op.timestamp) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    if (sqlite.c.sqlite3_bind_int64(stmt.stmt, 5, op.timestamp) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);

    const rc = sqlite.c.sqlite3_step(stmt.stmt);
    if (rc != sqlite.c.SQLITE_DONE) return reader.classifyStepError(conn);
}

pub fn executeDelete(
    allocator: Allocator,
    conn: *sqlite.Db,
    op: anytype,
) !void {
    const sql = op.sql;
    var stmt = conn.prepareDynamic(sql) catch |err| return reader.classifyError(err);
    defer stmt.deinit();

    const id_z = try allocator.dupeZ(u8, op.id);
    defer allocator.free(id_z);
    const ns_z = try allocator.dupeZ(u8, op.namespace);
    defer allocator.free(ns_z);

    if (sqlite.c.sqlite3_bind_text(stmt.stmt, 1, id_z.ptr, @intCast(op.id.len), @ptrFromInt(types.sqlite_transient)) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);
    if (sqlite.c.sqlite3_bind_text(stmt.stmt, 2, ns_z.ptr, @intCast(op.namespace.len), @ptrFromInt(types.sqlite_transient)) != sqlite.c.SQLITE_OK) return reader.classifyStepError(conn);

    const rc = sqlite.c.sqlite3_step(stmt.stmt);
    if (rc != sqlite.c.SQLITE_DONE) return reader.classifyStepError(conn);
}
