const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const lockFreeCache = @import("../lock_free_cache.zig").lockFreeCache;
const sql_utils = @import("sql_utils.zig");

pub const metadata_cache_type = lockFreeCache(msgpack.Payload);

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
    /// Attempted to modify a protected/immutable system field
    ImmutableField,
    /// NOT NULL column received null value
    NullNotAllowed,
    /// Write blocked because migration is in progress
    MigrationInProgress,
    /// Field value type does not match schema
    TypeMismatch,
    /// Array field contains non-literal elements (maps, nested arrays)
    InvalidArrayElement,
    /// The provided data path is invalid (too short, too long, or malformed)
    InvalidPath,
    /// Data directory is invalid or empty
    InvalidDataDir,
    /// Path is not a directory
    NotDir,
    /// Required condition value is missing
    MissingConditionValue,
    /// Low-level SQLite error that doesn't match specific classified types
    SQLiteError,
};

/// A column name + msgpack value pair for storage inserts/updates.
pub const ColumnValue = struct {
    name: []const u8,
    value: TypedValue,
    field_type: schema_manager.FieldType,
};

/// A managed payload that might be backed by a cache handle.
/// Caller MUST call deinit() to release any potential cache handles.
pub const ManagedPayload = struct {
    value: ?msgpack.Payload,
    next_cursor_arr: ?msgpack.Payload = null,
    handle: ?metadata_cache_type.Handle = null,
    allocator: ?Allocator = null,

    pub fn deinit(self: *ManagedPayload) void {
        if (self.handle) |*h| {
            h.release();
        }

        if (self.allocator) |alloc| {
            if (self.handle == null) {
                if (self.value) |*p| p.free(alloc);
            }
            if (self.next_cursor_arr) |*cursor| cursor.free(alloc);
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
    nil: void,

    pub fn clone(self: TypedValue, allocator: Allocator) !TypedValue {
        return switch (self) {
            .integer => |v| .{ .integer = v },
            .real => |v| .{ .real = v },
            .text => |s| .{ .text = try allocator.dupe(u8, s) },
            .boolean => |b| .{ .boolean = b },
            .nil => .nil,
        };
    }

    pub fn deinit(self: TypedValue, allocator: Allocator) void {
        switch (self) {
            .text => |s| allocator.free(s),
            else => {},
        }
    }

    /// Validates if a msgpack.Payload is compatible with a schema field type.
    pub fn validateValue(ft: schema_manager.FieldType, value: msgpack.Payload) !void {
        if (value == .nil) return;
        const match = switch (ft) {
            .text => value == .str,
            .integer => value == .int or value == .uint,
            .real => value == .float or value == .uint or value == .int,
            .boolean => value == .bool,
            .array => value == .arr,
        };
        if (!match) return StorageError.TypeMismatch;
    }

    /// Converts a msgpack.Payload to a TypedValue based on the schema's FieldType.
    /// Strings and blobs (JSON arrays) are duplicated and owned by the TypedValue.
    pub fn fromPayload(allocator: Allocator, ft: schema_manager.FieldType, items_type: ?schema_manager.FieldType, value: msgpack.Payload) !TypedValue {
        if (value == .nil) return .nil;
        return switch (ft) {
            .text => switch (value) {
                .str => |s| TypedValue{ .text = try allocator.dupe(u8, s.value()) },
                else => StorageError.TypeMismatch,
            },
            .integer => TypedValue{ .integer = try payloadAsInt(value) },
            .real => TypedValue{ .real = try payloadAsFloat(value) },
            .boolean => TypedValue{ .boolean = try payloadAsBool(value) },
            .array => TypedValue{ .text = try msgpack.payloadToJson(value, allocator, items_type orelse return StorageError.TypeMismatch) },
        };
    }

    /// Binds the typed value to a SQLite statement query parameter slot.
    pub fn bindSQLite(self: TypedValue, db: *sqlite.Db, stmt: *sqlite.c.sqlite3_stmt, index: c_int) !void {
        const rc = switch (self) {
            .integer => |v| sqlite.c.sqlite3_bind_int64(stmt, index, v),
            .real => |v| sqlite.c.sqlite3_bind_double(stmt, index, v),
            .text => |s| sql_utils.bindTextTransient(stmt, index, s),
            .boolean => |b| sqlite.c.sqlite3_bind_int(stmt, index, if (b) 1 else 0),
            .nil => sqlite.c.sqlite3_bind_null(stmt, index),
        };
        if (rc != sqlite.c.SQLITE_OK) return classifyStepError(db);
    }
};

pub fn classifyError(err: anyerror) anyerror {
    // Map SQLite errors to our specific error types
    return switch (err) {
        error.SQLiteConstraint => StorageError.ConstraintViolation,
        error.SQLiteFull => StorageError.DiskFull,
        error.SQLiteCorrupt, error.SQLiteNotADatabase => StorageError.DatabaseCorrupted,
        error.SQLiteBusy, error.SQLiteLocked => StorageError.DatabaseLocked,
        else => err,
    };
}

pub fn classifyStepError(db: *sqlite.Db) anyerror {
    const rc = sqlite.c.sqlite3_errcode(db.db);
    return switch (rc) {
        sqlite.c.SQLITE_CONSTRAINT => StorageError.ConstraintViolation,
        sqlite.c.SQLITE_FULL => StorageError.DiskFull,
        sqlite.c.SQLITE_CORRUPT, sqlite.c.SQLITE_NOTADB => StorageError.DatabaseCorrupted,
        sqlite.c.SQLITE_BUSY, sqlite.c.SQLITE_LOCKED => StorageError.DatabaseLocked,
        else => error.SQLiteError,
    };
}

pub fn logDatabaseError(operation: []const u8, err: anyerror, context: []const u8) void {
    std.log.debug("Database error during {s}: {} - Context: {s}", .{ operation, err, context });
}

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
    stmt_cache: sql_utils.StatementCache,
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
    index: c_int,
    name: []const u8,
    key: msgpack.Payload,
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

fn payloadAsInt(payload: msgpack.Payload) !i64 {
    return switch (payload) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => StorageError.TypeMismatch,
    };
}

fn payloadAsFloat(payload: msgpack.Payload) !f64 {
    return switch (payload) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .uint => |v| @floatFromInt(v),
        else => StorageError.TypeMismatch,
    };
}

fn payloadAsBool(payload: msgpack.Payload) !bool {
    return switch (payload) {
        .bool => |v| v,
        else => StorageError.TypeMismatch,
    };
}
