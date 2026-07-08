const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const SessionResolutionBuffer = @import("../connection.zig").SessionResolutionBuffer;
const typed = @import("../typed.zig");
const spscQueue = @import("../queues/spsc_queue.zig").spscQueue;
const latch_mod = @import("../threading/latch.zig");

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

pub const CheckpointStats = struct {
    mode: CheckpointMode,
    duration_ms: u64,
    frames_checkpointed: usize,
    frames_in_wal: usize,
    wal_size_before: usize,
    wal_size_after: usize,
};

/// Latch for checkpoint ops that return stats.
pub const CheckpointLatch = latch_mod.latch(CheckpointStats); // zwanzig-disable-line: identifier-style

/// Latch for batch ops that only need ack/err.
pub const AckLatch = latch_mod.latch(void); // zwanzig-disable-line: identifier-style

/// Configuration for reconnection logic.
pub const ReconnectionConfig = struct {
    /// Maximum number of reconnection attempts
    max_attempts: u32 = 5,
    /// Initial backoff delay in milliseconds
    initial_backoff_ms: u64 = 100,
    /// Maximum backoff delay in milliseconds
    max_backoff_ms: u64 = 5000,
    /// Multiplier for exponential backoff
    backoff_multiplier: f64 = 2.0,
};

pub const BatchEntry = struct {
    kind: enum { upsert, update, delete },
    table_index: usize,
    id: typed.DocId,
    namespace_id: i64,
    owner_doc_id: typed.DocId,
    sql: []const u8,
    values: ?[]typed.Value,
    guard_values: ?[]typed.Value = null,
    timestamp: i64,

    pub fn deinit(self: BatchEntry, allocator: Allocator) void {
        allocator.free(self.sql);
        if (self.values) |vals| typed.deinitValueSlice(allocator, vals);
        if (self.guard_values) |vals| typed.deinitValueSlice(allocator, vals);
    }
};

pub const WriteOp = union(enum) {
    checkpoint: struct { mode: CheckpointMode, latch: *CheckpointLatch },
    upsert: struct {
        table_index: usize,
        id: typed.DocId,
        namespace_id: i64,
        owner_doc_id: typed.DocId,
        sql: []const u8,
        values: []typed.Value,
        guard_values: ?[]typed.Value = null,
        timestamp: i64,
        conn_id: ?u64 = null,
        write_id: ?[16]u8 = null,
    },
    update: struct {
        table_index: usize,
        id: typed.DocId,
        namespace_id: i64,
        sql: []const u8,
        values: []typed.Value,
        guard_values: ?[]typed.Value = null,
        timestamp: i64,
        conn_id: ?u64 = null,
        write_id: ?[16]u8 = null,
    },
    delete: struct {
        table_index: usize,
        id: typed.DocId,
        namespace_id: i64,
        sql: []const u8,
        guard_values: ?[]typed.Value = null,
        conn_id: ?u64 = null,
        write_id: ?[16]u8 = null,
    },
    resolve_session: struct {
        conn_id: u64,
        msg_id: u64,
        scope_seq: u64,
        namespace: []const u8,
        external_user_id: []const u8,
        timestamp: i64,
        result_buffer: *SessionResolutionBuffer,
        is_presence: bool = false,
    },
    batch: struct {
        entries: []BatchEntry,
        latch: ?*AckLatch = null,
        conn_id: ?u64 = null,
        write_id: ?[16]u8 = null,
    },

    pub fn getWriteAckInfo(self: WriteOp) ?struct { conn_id: u64, write_id: [16]u8 } {
        return switch (self) {
            .upsert => |op| if (op.conn_id != null and op.write_id != null)
                .{ .conn_id = op.conn_id.?, .write_id = op.write_id.? }
            else
                null,
            .update => |op| if (op.conn_id != null and op.write_id != null)
                .{ .conn_id = op.conn_id.?, .write_id = op.write_id.? }
            else
                null,
            .delete => |op| if (op.conn_id != null and op.write_id != null)
                .{ .conn_id = op.conn_id.?, .write_id = op.write_id.? }
            else
                null,
            .batch => |op| if (op.conn_id != null and op.write_id != null)
                .{ .conn_id = op.conn_id.?, .write_id = op.write_id.? }
            else
                null,
            else => null,
        };
    }

    pub fn deinit(self: WriteOp, allocator: Allocator) void {
        switch (self) {
            .upsert => |op| {
                allocator.free(op.sql);
                typed.deinitValueSlice(allocator, op.values);
                if (op.guard_values) |guard_vals| typed.deinitValueSlice(allocator, guard_vals);
            },
            .update => |op| {
                allocator.free(op.sql);
                typed.deinitValueSlice(allocator, op.values);
                if (op.guard_values) |guard_vals| typed.deinitValueSlice(allocator, guard_vals);
            },
            .delete => |op| {
                allocator.free(op.sql);
                if (op.guard_values) |guard_vals| typed.deinitValueSlice(allocator, guard_vals);
            },
            .resolve_session => |op| {
                allocator.free(op.namespace);
                allocator.free(op.external_user_id);
            },
            .batch => |op| {
                for (op.entries) |entry| entry.deinit(allocator);
                allocator.free(op.entries);
            },
            else => {},
        }
    }
};

pub const write_queue_type = spscQueue(WriteOp, MemoryStrategy.IndexPool);
