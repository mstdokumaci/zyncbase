const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const lockFreeCache = @import("../lock_free_cache.zig").lockFreeCache;
const sql = @import("sql.zig");

pub const typed_cache_type = lockFreeCache(TypedRow);

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

/// A schema field index + typed value pair for storage inserts/updates.
pub const ColumnValue = struct {
    index: usize,
    value: TypedValue,
};

/// A managed result that might be backed by a cache handle.
/// Every result is exposed as a slice of TypedRows.
/// Caller MUST call deinit() to release any potential cache handles and memory.
pub const ManagedResult = struct {
    rows: []TypedRow,
    next_cursor: ?TypedCursor = null,
    handle: ?typed_cache_type.Handle = null,
    allocator: ?Allocator = null,

    pub fn deinit(self: *ManagedResult) void {
        if (self.handle) |h| {
            // CACHE HIT: 'rows' is just a 1-length slice pointing directly at the
            // cached TypedRow memory via `handle.data()`. No wrapper array was
            // dynamically allocated. We simply release the cache handle.
            h.release();
        } else if (self.allocator) |alloc| {
            // CACHE MISS / QUERY: We dynamically allocated the rows array
            // and everything inside it. We must clean up.
            for (self.rows) |r| r.deinit(alloc);
            alloc.free(self.rows);
            if (self.next_cursor) |*nc| nc.deinit(alloc);
        }
    }
};

pub const TypedRow = struct {
    values: []TypedValue,

    pub fn deinit(self: TypedRow, allocator: Allocator) void {
        for (self.values) |value| value.deinit(allocator);
        allocator.free(self.values);
    }

    pub fn clone(self: TypedRow, allocator: Allocator) !TypedRow {
        const cloned = try allocator.alloc(TypedValue, self.values.len);
        var i: usize = 0;
        errdefer {
            for (cloned[0..i]) |value| value.deinit(allocator);
            allocator.free(cloned);
        }
        while (i < self.values.len) : (i += 1) {
            cloned[i] = try self.values[i].clone(allocator);
        }
        return .{
            .values = cloned,
        };
    }
};

pub const TypedCursor = struct {
    sort_value: TypedValue,
    id: []const u8, // Owned

    pub fn deinit(self: *TypedCursor, allocator: Allocator) void {
        self.sort_value.deinit(allocator);
        allocator.free(self.id);
    }

    pub fn clone(self: TypedCursor, allocator: Allocator) !TypedCursor {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);
        return .{
            .sort_value = try self.sort_value.clone(allocator),
            .id = id,
        };
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

    pub fn lessThan(self: ScalarValue, other: ScalarValue) bool {
        return self.order(other) == .lt;
    }

    pub fn order(self: ScalarValue, other: ScalarValue) std.math.Order {
        if (@as(std.meta.Tag(ScalarValue), self) != @as(std.meta.Tag(ScalarValue), other)) {
            return std.math.order(@intFromEnum(self), @intFromEnum(other));
        }
        return switch (self) {
            .integer => std.math.order(self.integer, other.integer),
            .real => std.math.order(self.real, other.real),
            .text => std.mem.order(u8, self.text, other.text),
            .boolean => std.math.order(@intFromBool(self.boolean), @intFromBool(other.boolean)),
        };
    }

    /// Writes this scalar value as MessagePack to the provided writer.
    pub fn writeMsgPack(self: ScalarValue, writer: anytype) !void {
        switch (self) {
            .integer => |iv| {
                if (iv >= 0) {
                    try msgpack.encode(msgpack.Payload{ .uint = @intCast(iv) }, writer);
                } else {
                    try msgpack.encode(msgpack.Payload{ .int = iv }, writer);
                }
            },
            .real => |rv| try msgpack.encode(msgpack.Payload{ .float = rv }, writer),
            .text => |tv| try msgpack.writeMsgPackStr(writer, tv),
            .boolean => |bv| try msgpack.encode(msgpack.Payload{ .bool = bv }, writer),
        }
    }

    pub fn jsonStringify(self: ScalarValue, stream: anytype) !void {
        switch (self) {
            .integer => |v| try stream.write(v),
            .real => |v| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return error.WriteFailed;
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

    /// Converts a JSON value to a ScalarValue based on the schema's FieldType.
    pub fn fromJson(allocator: Allocator, ft: schema_manager.FieldType, value: std.json.Value) !ScalarValue {
        return switch (ft) {
            .text => switch (value) {
                .string => |s| ScalarValue{ .text = try allocator.dupe(u8, s) },
                else => StorageError.TypeMismatch,
            },
            .integer => ScalarValue{ .integer = try jsonAsInt(value) },
            .real => ScalarValue{ .real = try jsonAsFloat(value) },
            .boolean => ScalarValue{ .boolean = try jsonAsBool(value) },
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

    pub fn sortedSet(self: *TypedValue, allocator: Allocator) !void {
        const arr = switch (self.*) {
            .array => |a| a,
            else => return,
        };
        if (arr.len <= 1) return;

        std.sort.pdq(ScalarValue, arr, {}, scalarValueLessThan);

        var write: usize = 1;
        for (1..arr.len) |read| {
            if (ScalarValue.order(arr[write - 1], arr[read]) != .eq) {
                if (write != read) {
                    arr[write] = arr[read];
                }
                write += 1;
            } else {
                arr[read].deinit(allocator);
            }
        }

        // Clear moved-from/deinitialized tail entries so a later full deinit remains safe,
        // including error paths where realloc can fail.
        for (arr[write..]) |*item| {
            item.* = .{ .integer = 0 };
        }

        if (write < arr.len) {
            self.* = .{ .array = try allocator.realloc(arr, write) };
        }
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

    /// Writes this typed value as MessagePack to the provided writer.
    pub fn writeMsgPack(self: TypedValue, writer: anytype) !void {
        switch (self) {
            .nil => try msgpack.encode(.nil, writer),
            .scalar => |s| try s.writeMsgPack(writer),
            .array => |arr| {
                try msgpack.encodeArrayHeader(writer, arr.len);
                for (arr) |item| {
                    try item.writeMsgPack(writer);
                }
            },
        }
    }

    /// Reads and converts a SQLite result column into a TypedValue.
    pub fn fromSQLiteColumn(allocator: Allocator, stmt: *sqlite.c.sqlite3_stmt, i: c_int, field: ?schema_manager.Field) !TypedValue {
        const col_type = sqlite.c.sqlite3_column_type(stmt, i);
        if (field != null and field.?.sql_type == .array and col_type == sqlite.c.SQLITE_TEXT) {
            const ptr = sqlite.c.sqlite3_column_text(stmt, i);
            const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt, i));
            const s = if (ptr != null) ptr[0..len] else "[]";
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, s, .{});
            defer parsed.deinit();
            return TypedValue.fromJson(allocator, field.?.sql_type, field.?.items_type, parsed.value);
        }
        return switch (col_type) {
            sqlite.c.SQLITE_INTEGER => {
                const val = sqlite.c.sqlite3_column_int64(stmt, i);
                if (field != null and field.?.sql_type == .boolean) {
                    return TypedValue{ .scalar = .{ .boolean = val != 0 } };
                }
                return TypedValue{ .scalar = .{ .integer = val } };
            },
            sqlite.c.SQLITE_FLOAT => TypedValue{ .scalar = .{ .real = sqlite.c.sqlite3_column_double(stmt, i) } },
            sqlite.c.SQLITE_TEXT => blk: {
                const ptr = sqlite.c.sqlite3_column_text(stmt, i);
                const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt, i));
                const s = if (ptr != null) ptr[0..len] else "";
                break :blk TypedValue{ .scalar = .{ .text = try allocator.dupe(u8, s) } };
            },
            else => .nil,
        };
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
                var result = TypedValue{ .array = items };
                try result.sortedSet(allocator);
                return result;
            },
            else => .{ .scalar = try ScalarValue.fromPayload(allocator, ft, value) },
        };
    }

    /// Converts a JSON value to a TypedValue based on the schema's FieldType.
    pub fn fromJson(allocator: Allocator, ft: schema_manager.FieldType, items_type: ?schema_manager.FieldType, value: std.json.Value) !TypedValue {
        if (value == .null) return .nil;
        return switch (ft) {
            .array => {
                if (value != .array) return StorageError.TypeMismatch;
                const arr = value.array;
                const items = try allocator.alloc(ScalarValue, arr.items.len);
                var i: usize = 0;
                errdefer {
                    for (items[0..i]) |*item| item.deinit(allocator);
                    allocator.free(items);
                }
                const it = items_type orelse return StorageError.TypeMismatch;
                while (i < arr.items.len) : (i += 1) {
                    if (arr.items[i] == .null) return StorageError.NullNotAllowed;
                    items[i] = try ScalarValue.fromJson(allocator, it, arr.items[i]);
                }
                return TypedValue{ .array = items };
            },
            else => .{ .scalar = try ScalarValue.fromJson(allocator, ft, value) },
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

fn scalarValueLessThan(_: void, a: ScalarValue, b: ScalarValue) bool {
    return a.lessThan(b);
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

fn jsonAsInt(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |v| v,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch StorageError.TypeMismatch,
        else => StorageError.TypeMismatch,
    };
}

fn jsonAsFloat(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch StorageError.TypeMismatch,
        else => StorageError.TypeMismatch,
    };
}

fn jsonAsBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => StorageError.TypeMismatch,
    };
}
