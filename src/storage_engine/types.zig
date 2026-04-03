const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const lockFreeCache = @import("../lock_free_cache.zig").lockFreeCache;

pub const metadata_cache_type = lockFreeCache(msgpack.Payload);

/// Safe bind helpers to avoid alignment errors with TSAN on ARM.
/// We delegate transient binding to C to bypass Zig's strict runtime alignment
/// checks for the special -1 pointer sentinel.
pub extern fn zyncbase_sqlite3_bind_text_transient(stmt: ?*sqlite.c.sqlite3_stmt, i: c_int, zData: ?*const anyopaque, nData: c_int) c_int;
pub extern fn zyncbase_sqlite3_bind_blob_transient(stmt: ?*sqlite.c.sqlite3_stmt, i: c_int, zData: ?*const anyopaque, nData: c_int) c_int;

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
    /// Table not found in schema
    UnknownTable,
    /// Field not found in table schema
    UnknownField,
    /// NOT NULL column received null value
    NullNotAllowed,
    /// Write blocked because migration is in progress
    MigrationInProgress,
    /// Field value type does not match schema
    TypeMismatch,
    /// Data directory is invalid or empty
    InvalidDataDir,
    /// Path is not a directory
    NotDir,
    /// Required condition value is missing
    MissingConditionValue,
};

/// A column name + msgpack value pair for storage inserts/updates.
pub const ColumnValue = struct {
    name: []const u8,
    value: msgpack.Payload,
};

/// A managed payload that might be backed by a cache handle.
/// Caller MUST call deinit() to release any potential cache handles.
pub const ManagedPayload = struct {
    value: ?msgpack.Payload,
    handle: ?metadata_cache_type.Handle = null,
    allocator: ?Allocator = null,

    pub fn deinit(self: *ManagedPayload) void {
        if (self.handle) |*h| {
            h.release();
        } else if (self.allocator) |alloc| {
            if (self.value) |*p| p.free(alloc);
        }
    }
};

/// A typed value for asynchronous storage binding.
/// This structure holds the native SQLite-compatible representation of a field.
/// Strings and blobs (for JSON arrays) are duplicated and owned by the WriteOp.
pub const TypedValue = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8, // Owned
    boolean: bool,
    blob: []const u8, // Owned (for arrays/complex)
    nil: void,

    pub fn deinit(self: TypedValue, allocator: Allocator) void {
        switch (self) {
            .text => |s| allocator.free(s),
            .blob => |b| allocator.free(b),
            else => {},
        }
    }
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

pub const ReaderNode = struct {
    conn: sqlite.Db,
    mutex: std.Thread.Mutex,
};

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

pub const ColumnContext = struct {
    name: []const u8,
    field: ?schema_manager.Field,
};

pub const WriteOp = union(enum) {
    begin_transaction: struct { completion_signal: ?*CompletionSignal },
    commit_transaction: struct { completion_signal: ?*CompletionSignal },
    rollback_transaction: struct { completion_signal: ?*CompletionSignal },
    checkpoint: struct { mode: CheckpointMode, completion_signal: *CompletionSignal },
    insert: struct {
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
        sql: []const u8,
        values: []TypedValue,
        timestamp: i64,
        completion_signal: ?*CompletionSignal = null,
    },
    update: struct {
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
        sql: []const u8,
        values: []TypedValue,
        timestamp: i64,
        completion_signal: ?*CompletionSignal = null,
    },
    delete: struct {
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
        sql: []const u8,
        completion_signal: ?*CompletionSignal = null,
    },
    ddl: struct {
        sql: []const u8,
        completion_signal: ?*CompletionSignal,
    },

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

    pub fn getCompletionSignal(self: WriteOp) ?*CompletionSignal {
        return switch (self) {
            .begin_transaction => |op| op.completion_signal,
            .commit_transaction => |op| op.completion_signal,
            .rollback_transaction => |op| op.completion_signal,
            .checkpoint => |op| op.completion_signal,
            .insert => |op| op.completion_signal,
            .update => |op| op.completion_signal,
            .delete => |op| op.completion_signal,
            .ddl => |op| op.completion_signal,
        };
    }

    pub fn deinit(self: WriteOp, allocator: Allocator) void {
        switch (self) {
            .insert => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.id);
                allocator.free(op.sql);
                for (op.values) |val| val.deinit(allocator);
                allocator.free(op.values);
            },
            .update => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.id);
                allocator.free(op.sql);
                for (op.values) |val| val.deinit(allocator);
                allocator.free(op.values);
            },
            .delete => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.id);
                allocator.free(op.sql);
            },
            .ddl => |op| {
                allocator.free(op.sql);
            },
            else => {},
        }
    }
};

pub const WriteQueue = struct {
    pub const Node = struct {
        op: WriteOp,
        next: std.atomic.Value(?*Node),
    };

    head: *Node,
    tail: std.atomic.Value(*Node),
    allocator: Allocator,
    pool: *MemoryStrategy.IndexPool(Node),

    pub fn init(self: *WriteQueue, allocator: std.mem.Allocator, node_pool: *MemoryStrategy.IndexPool(Node)) !void {
        const stub = try node_pool.acquire();
        stub.next = std.atomic.Value(?*Node).init(null);
        self.* = WriteQueue{
            .head = stub,
            .tail = std.atomic.Value(*Node).init(stub),
            .allocator = allocator,
            .pool = node_pool,
        };
    }

    pub fn deinit(self: *WriteQueue) void {
        while (self.pop()) |op| {
            op.deinit(self.allocator);
        }
        self.pool.release(self.head);
    }

    pub fn push(self: *WriteQueue, op: WriteOp) !void {
        const node = try self.pool.acquire();
        node.op = op;
        node.next = std.atomic.Value(?*Node).init(null);
        const prev = self.tail.swap(node, .acq_rel);
        prev.next.store(node, .release);
    }

    pub fn pop(self: *WriteQueue) ?WriteOp {
        const head = self.head;
        const next = head.next.load(.acquire) orelse return null;

        self.head = next;
        const op = next.op;
        self.pool.release(head);
        return op;
    }
};
