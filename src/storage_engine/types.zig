const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const lockFreeCache = @import("../lock_free_cache.zig").lockFreeCache;
const sql = @import("sql.zig");

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

/// A simple scalar value for storage elements that don't support recursion or nil.
pub const ScalarValue = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8, // Owned
    boolean: bool,

    pub fn clone(self: ScalarValue, allocator: Allocator) !ScalarValue {
        return switch (self) {
            .text => |s| .{ .text = try allocator.dupe(u8, s) },
            else => self,
        };
    }

    pub fn deinit(self: ScalarValue, allocator: Allocator) void {
        switch (self) {
            .text => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn jsonStringify(self: ScalarValue, stream: anytype) !void {
        switch (self) {
            .integer => |v| try stream.write(v),
            .real => |v| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch @panic("float formatting exceeded 64 byte buffer");
                if (std.mem.indexOfScalar(u8, s, '.') == null and std.mem.indexOfScalar(u8, s, 'e') == null and std.mem.indexOfScalar(u8, s, 'E') == null) {
                    try stream.print("{s}.0", .{s});
                } else {
                    try stream.print("{s}", .{s});
                }
            },
            .text => |s| try stream.write(s),
            .boolean => |b| try stream.write(b),
        }
    }

    /// Converts a msgpack.Payload to a ScalarValue based on the schema's FieldType.
    pub fn fromPayload(allocator: Allocator, ft: schema_manager.FieldType, value: msgpack.Payload) !ScalarValue {
        return switch (ft) {
            .text => switch (value) {
                .str => |s| ScalarValue{ .text = try allocator.dupe(u8, s.value()) },
                else => StorageError.TypeMismatch,
            },
            .integer => ScalarValue{ .integer = try payloadAsInt(value) },
            .real => ScalarValue{ .real = try payloadAsFloat(value) },
            .boolean => ScalarValue{ .boolean = try payloadAsBool(value) },
            else => StorageError.InvalidArrayElement,
        };
    }
};

/// A typed value for asynchronous storage binding.
/// Supports scalars, nil, and flat arrays of scalars.
pub const TypedValue = union(enum) {
    scalar: ScalarValue,
    array: []ScalarValue, // Owned slice of ScalarValues (no nesting, no nil)
    nil: void,

    pub fn clone(self: TypedValue, allocator: Allocator) !TypedValue {
        return switch (self) {
            .scalar => |s| .{ .scalar = try s.clone(allocator) },
            .nil => .nil,
            .array => |items| blk: {
                const cloned = try allocator.alloc(ScalarValue, items.len);
                var i: usize = 0;
                errdefer {
                    for (cloned[0..i]) |*item| item.deinit(allocator);
                    allocator.free(cloned);
                }
                while (i < items.len) : (i += 1) {
                    cloned[i] = try items[i].clone(allocator);
                }
                break :blk .{ .array = cloned };
            },
        };
    }

    pub fn deinit(self: TypedValue, allocator: Allocator) void {
        switch (self) {
            .scalar => |s| s.deinit(allocator),
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .nil => {},
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

    pub fn fromPayload(allocator: Allocator, ft: schema_manager.FieldType, items_type: ?schema_manager.FieldType, value: msgpack.Payload) !TypedValue {
        if (value == .nil) return .nil;
        return switch (ft) {
            .array => {
                const arr = value.arr;
                const items = try allocator.alloc(ScalarValue, arr.len);
                var i: usize = 0;
                errdefer {
                    for (items[0..i]) |*item| item.deinit(allocator);
                    allocator.free(items);
                }
                const it = items_type orelse return StorageError.TypeMismatch;
                while (i < arr.len) : (i += 1) {
                    if (arr[i] == .nil) return StorageError.NullNotAllowed;
                    items[i] = try ScalarValue.fromPayload(allocator, it, arr[i]);
                }
                return TypedValue{ .array = items };
            },
            else => .{ .scalar = try ScalarValue.fromPayload(allocator, ft, value) },
        };
    }

    /// Binds the typed value to a SQLite statement query parameter slot.
    pub fn bindSQLite(self: TypedValue, db: *sqlite.Db, stmt: *sqlite.c.sqlite3_stmt, index: c_int, allocator: Allocator) !void {
        const rc = switch (self) {
            .scalar => |s| switch (s) {
                .integer => |v| sqlite.c.sqlite3_bind_int64(stmt, index, v),
                .real => |v| sqlite.c.sqlite3_bind_double(stmt, index, v),
                .text => |s_val| sql.bindTextTransient(stmt, index, s_val),
                .boolean => |b| sqlite.c.sqlite3_bind_int(stmt, index, if (b) 1 else 0),
            },
            .nil => sqlite.c.sqlite3_bind_null(stmt, index),
            .array => |items| blk: {
                const json = try std.json.Stringify.valueAlloc(allocator, items, .{});
                defer allocator.free(json);
                break :blk sql.bindTextTransient(stmt, index, json);
            },
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
    stmt_cache: sql.StatementCache,
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
    upsert: struct {
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
            .upsert => |op| op.completion_signal,
            .delete => |op| op.completion_signal,
        };
    }

    pub fn deinit(self: WriteOp, allocator: Allocator) void {
        switch (self) {
            .upsert => |op| {
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
