const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const msgpack = @import("msgpack_utils.zig");
const schema_parser = @import("schema_parser.zig");
const query_parser = @import("query_parser.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const lockFreeCache = @import("lock_free_cache.zig").lockFreeCache;
const metadata_cache_type = lockFreeCache(msgpack.Payload);
var unique_id_counter = std.atomic.Value(usize).init(0);

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

/// Statistics from a checkpoint operation
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

pub const StorageEngine = struct {
    pub const Options = struct {
        in_memory: bool = false,
    };

    pub const PerformanceConfig = @import("config_loader.zig").Config.PerformanceConfig;

    allocator: Allocator,
    db_path: [:0]const u8,
    writer_conn: sqlite.Db,
    reader_pool: []ReaderNode,
    write_queue: WriteQueue,
    write_thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool),
    next_reader_idx: std.atomic.Value(usize),
    transaction_active: std.atomic.Value(bool),
    manual_transaction_active: std.atomic.Value(bool),
    migration_active: std.atomic.Value(bool),
    pending_writes_count: std.atomic.Value(usize),
    reconnection_config: ReconnectionConfig,
    write_mutex: std.Thread.Mutex,
    write_cond: std.Thread.Condition,
    flush_cond: std.Thread.Condition,
    write_thread_ready: std.atomic.Value(bool),
    node_pool: MemoryStrategy.IndexPool(WriteQueue.Node),
    schema: *const schema_parser.Schema,
    schema_metadata: schema_parser.SchemaMetadata,
    metadata_cache: *metadata_cache_type,
    /// Monotonically increasing counter bumped by the write thread after each
    /// successful batch commit, before cache eviction. Readers snapshot this
    /// before the DB read and only populate the cache if it hasn't advanced,
    /// preventing stale values from racing into the cache.
    write_seq: std.atomic.Value(u64),
    performance_config: PerformanceConfig,
    options: Options,

    fn deinitPayload(allocator: Allocator, payload: *msgpack.Payload) void {
        payload.free(allocator);
    }

    pub fn init(allocator: Allocator, memory_strategy: *MemoryStrategy, data_dir: []const u8, schema: *const schema_parser.Schema, performance_config: PerformanceConfig, options: Options) !*StorageEngine {
        if (data_dir.len == 0 and !options.in_memory) return error.InvalidDataDir;
        const self = try allocator.create(StorageEngine);
        errdefer allocator.destroy(self);

        const db_path: [:0]const u8 = if (options.in_memory) uri: {
            // Use shared-cache in-memory database with a unique name to avoid crosstalk
            // file:zync_mem_{id}?mode=memory&cache=shared
            const id = unique_id_counter.fetchAdd(1, .seq_cst);
            const ts = std.time.nanoTimestamp();
            const uri_fmt = try std.fmt.allocPrint(allocator, "file:zync_mem_{d}_{d}?mode=memory&cache=shared", .{ ts, id });
            defer allocator.free(uri_fmt);
            break :uri try allocator.dupeZ(u8, uri_fmt);
        } else blk: {
            // Ensure data directory exists
            if (std.fs.cwd().openDir(data_dir, .{})) |_| {
                // Already exists and is a directory
            } else |err| switch (err) {
                error.FileNotFound => {
                    try std.fs.cwd().makePath(data_dir);
                },
                error.NotDir => return error.NotDir,
                else => return err,
            }
            const db_path_buf = try std.fmt.allocPrint(allocator, "{s}/zyncbase.db", .{data_dir});
            defer allocator.free(db_path_buf);
            break :blk try allocator.dupeZ(u8, db_path_buf);
        };
        errdefer allocator.free(db_path); // zwanzig-disable-line: deinit-lifecycle

        // Open writer connection
        var writer_conn = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = db_path },
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .shared_cache = options.in_memory,
        });
        errdefer writer_conn.deinit();

        // Configure WAL mode and pragmas
        try configureDatabase(&writer_conn, true);

        // Create reader pool (one per CPU core)
        const num_readers = try std.Thread.getCpuCount();
        const reader_pool = try allocator.alloc(ReaderNode, num_readers);
        errdefer allocator.free(reader_pool);

        const metadata_cache = try metadata_cache_type.init(allocator, .{}, deinitPayload);
        errdefer metadata_cache.deinit();

        var initialized_readers: usize = 0;
        errdefer {
            for (reader_pool[0..initialized_readers]) |*node| {
                node.conn.deinit();
            }
        }

        for (reader_pool) |*node| {
            node.conn = try sqlite.Db.init(.{
                .mode = sqlite.Db.Mode{ .File = db_path },
                .open_flags = .{
                    .write = false,
                },
                .shared_cache = options.in_memory,
            });
            try configureDatabase(&node.conn, false);
            node.mutex = .{};
            initialized_readers += 1;
        }

        const schema_metadata = try schema_parser.SchemaMetadata.init(allocator, schema);
        errdefer @constCast(&schema_metadata).deinit();

        self.* = .{
            .allocator = allocator,
            .db_path = db_path,
            .writer_conn = writer_conn,
            .reader_pool = reader_pool,
            .performance_config = performance_config,
            .options = options,
            // SAFETY: Initialized below via .node_pool.init().
            .node_pool = undefined,
            // SAFETY: Initialized below via .write_queue.init().
            .write_queue = undefined,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .next_reader_idx = std.atomic.Value(usize).init(0),
            .transaction_active = std.atomic.Value(bool).init(false),
            .write_seq = std.atomic.Value(u64).init(0),
            .schema = schema,
            .schema_metadata = schema_metadata,
            .metadata_cache = metadata_cache,
            .flush_cond = .{},
            .write_mutex = .{},
            .pending_writes_count = std.atomic.Value(usize).init(0),
            .manual_transaction_active = std.atomic.Value(bool).init(false),
            .migration_active = std.atomic.Value(bool).init(false),
            .reconnection_config = .{},
            .write_cond = .{},
            .write_thread_ready = std.atomic.Value(bool).init(false),
        };

        try self.node_pool.init(memory_strategy.generalAllocator(), 1024, null, null);
        errdefer self.node_pool.deinit();

        try self.write_queue.init(allocator, &self.node_pool);
        errdefer self.write_queue.deinit();

        // Start write thread
        self.write_thread = try std.Thread.spawn(.{}, writeThreadLoop, .{self});
        errdefer {
            self.shutdown_requested.store(true, .release);
            self.write_cond.signal();
            if (self.write_thread) |thread| thread.join();
        }

        // Wait deterministically for the write thread to signal readiness
        {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            while (!self.write_thread_ready.load(.acquire)) {
                self.write_cond.wait(&self.write_mutex);
            }
        }

        return self;
    }

    pub fn deinit(self: *StorageEngine) void {
        const gpa = self.allocator; // Assuming allocator is the general purpose allocator
        self.schema_metadata.deinit();

        // 1. Signal shutdown to the thread
        self.shutdown_requested.store(true, .release);
        self.write_cond.signal();

        // 2. Wait for the thread to exit cleanly
        if (self.write_thread) |thread| {
            thread.join();
        }

        // 3. Deinit cache
        self.metadata_cache.deinit();
        self.writer_conn.deinit();

        // 4. Clean up readers
        for (self.reader_pool) |*node| {
            node.conn.deinit();
        }
        gpa.free(self.reader_pool);
        gpa.free(self.db_path);

        // 5. Clean up the queues and objects
        self.write_queue.deinit();
        self.node_pool.deinit();

        gpa.destroy(self);
    }

    /// Get a StorageLayer interface for the CheckpointManager
    pub fn getStorageLayer(self: *StorageEngine) !*@import("checkpoint_manager.zig").CheckpointManager.StorageLayer {
        const checkpoint_manager_mod = @import("checkpoint_manager.zig");
        const storage_layer = try checkpoint_manager_mod.CheckpointManager.StorageLayer.init(self.allocator, self.db_path);

        // Store a reference to self for checkpoint execution
        storage_layer.storage_engine = self;

        return storage_layer;
    }

    /// Execute a checkpoint operation with the specified mode
    /// Returns statistics about the checkpoint operation
    pub fn executeCheckpoint(self: *StorageEngine, mode: CheckpointMode) !CheckpointStats {
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .checkpoint = .{
                .mode = mode,
                .completion_signal = &signal,
            },
        };

        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);

        try signal.wait();
        return signal.result orelse error.InvalidOperation;
    }

    fn internalExecuteCheckpoint(self: *StorageEngine, mode: CheckpointMode) !CheckpointStats {
        const start_time = std.time.milliTimestamp();
        const wal_size_before = try self.getWalSize();

        var frames_checkpointed: usize = 0;
        var frames_in_wal: usize = 0;

        const CheckpointResult = struct { busy: i64, log: i64, checkpointed: i64 };
        const result = switch (mode) {
            .passive => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(PASSIVE)", .{}, .{}),
            .full => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(FULL)", .{}, .{}),
            .restart => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(RESTART)", .{}, .{}),
            .truncate => self.writer_conn.one(CheckpointResult, "PRAGMA wal_checkpoint(TRUNCATE)", .{}, .{}),
        } catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("internalExecuteCheckpoint", classified_err, @tagName(mode));
            return classified_err;
        };

        if (result) |res| {
            frames_checkpointed = @intCast(res.checkpointed);
            frames_in_wal = @intCast(res.log);
        }

        const wal_size_after = try self.getWalSize();
        const duration: u64 = @intCast(std.time.milliTimestamp() - start_time);

        std.log.info("Checkpoint completed: mode={s}, duration={}ms, frames_checkpointed={}, frames_in_wal={}, wal_before={}, wal_after={}", .{
            @tagName(mode),
            duration,
            frames_checkpointed,
            frames_in_wal,
            wal_size_before,
            wal_size_after,
        });

        return CheckpointStats{
            .mode = mode,
            .duration_ms = duration,
            .frames_checkpointed = frames_checkpointed,
            .frames_in_wal = frames_in_wal,
            .wal_size_before = wal_size_before,
            .wal_size_after = wal_size_after,
        };
    }

    /// Get the current WAL file size in bytes
    pub fn getWalSize(self: *StorageEngine) !usize {
        // In-memory databases use URIs (e.g. file:...) and do not have a WAL file on disk.
        // We must guard this to prevent nonsensical path construction below.
        if (self.options.in_memory) {
            return 0;
        }
        // Try to get WAL file size from filesystem
        const wal_path_buf = try std.fmt.allocPrint(self.allocator, "{s}-wal", .{self.db_path});
        defer self.allocator.free(wal_path_buf);

        const file = std.fs.cwd().openFile(wal_path_buf, .{}) catch |err| {
            // WAL file might not exist yet (no writes have occurred)
            if (err == error.FileNotFound) {
                return 0;
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        return stat.size;
    }

    pub fn beginTransaction(self: *StorageEngine) !void {
        if (self.manual_transaction_active.load(.acquire)) {
            return StorageError.TransactionAlreadyActive;
        }
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .begin_transaction = .{
                .completion_signal = &signal,
            },
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
        return signal.wait();
    }

    pub fn commitTransaction(self: *StorageEngine) !void {
        if (!self.manual_transaction_active.load(.acquire)) {
            return StorageError.NoActiveTransaction;
        }
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .commit_transaction = .{
                .completion_signal = &signal,
            },
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
        return signal.wait();
    }

    pub fn rollbackTransaction(self: *StorageEngine) !void {
        if (!self.manual_transaction_active.load(.acquire)) {
            return StorageError.NoActiveTransaction;
        }
        var signal = WriteOp.CompletionSignal{};
        const op = WriteOp{
            .rollback_transaction = .{
                .completion_signal = &signal,
            },
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
        return signal.wait();
    }

    /// Execute DDL synchronously via the write thread.
    pub fn execDDL(self: *StorageEngine, sql: []const u8) !void {
        var signal = WriteOp.CompletionSignal{};
        const sql_owned = try self.allocator.dupe(u8, sql);
        // Ownership transferred to `op` immediately.

        const op = WriteOp{
            .ddl = .{
                .sql = sql_owned,
                .completion_signal = &signal,
            },
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
        return signal.wait();
    }

    pub fn isTransactionActive(self: *StorageEngine) bool {
        return self.manual_transaction_active.load(.acquire);
    }

    /// Classify SQLite error into our specific error types
    fn classifyError(err: anyerror) anyerror {
        // Map SQLite errors to our specific error types
        return switch (err) {
            error.SQLiteConstraint => StorageError.ConstraintViolation,
            error.SQLiteFull => StorageError.DiskFull,
            error.SQLiteCorrupt, error.SQLiteNotADatabase => StorageError.DatabaseCorrupted,
            error.SQLiteBusy, error.SQLiteLocked => StorageError.DatabaseLocked,
            else => err,
        };
    }

    /// Log database error with full details
    fn logDatabaseError(operation: []const u8, err: anyerror, context: []const u8) void {
        std.log.debug("Database error during {s}: {} - Context: {s}", .{ operation, err, context });
    }

    /// Attempt to reconnect to database with exponential backoff
    fn reconnectWithBackoff(self: *StorageEngine) !void {
        var attempt: u32 = 0;
        var backoff_ms = self.reconnection_config.initial_backoff_ms;

        while (attempt < self.reconnection_config.max_attempts) : (attempt += 1) {
            std.log.warn("Attempting database reconnection (attempt {}/{})", .{
                attempt + 1,
                self.reconnection_config.max_attempts,
            });

            // Try to reconnect
            const reconnect_result = self.attemptReconnect();
            if (reconnect_result) {
                std.log.info("Database reconnection successful after {} attempts", .{attempt + 1});
                return;
            } else |err| {
                std.log.err("Reconnection attempt {} failed: {}", .{ attempt + 1, err });

                // If not the last attempt, wait with exponential backoff
                if (attempt + 1 < self.reconnection_config.max_attempts) {
                    std.log.info("Waiting {}ms before next reconnection attempt", .{backoff_ms});
                    std.Thread.sleep(backoff_ms * std.time.ns_per_ms);

                    // Calculate next backoff with exponential increase
                    const float_backoff: f64 = @floatFromInt(backoff_ms);
                    const next_backoff: u64 = @intFromFloat(float_backoff * self.reconnection_config.backoff_multiplier);
                    backoff_ms = @min(next_backoff, self.reconnection_config.max_backoff_ms);
                }
            }
        }

        std.log.err("Failed to reconnect after {} attempts", .{self.reconnection_config.max_attempts});
        return StorageError.ReconnectionFailed;
    }

    /// Attempt a single reconnection
    fn attemptReconnect(self: *StorageEngine) !void {
        // Close existing connections
        self.writer_conn.deinit();
        for (self.reader_pool) |*reader| {
            reader.conn.deinit(); // Corrected: reader.deinit() -> reader.conn.deinit()
        }

        // Try to reopen writer connection
        self.writer_conn = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = self.db_path },
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .shared_cache = self.options.in_memory,
        });

        // Reconfigure database
        try configureDatabase(&self.writer_conn, true);

        // Reopen reader connections
        for (self.reader_pool) |*reader| {
            reader.conn = try sqlite.Db.init(.{ // Corrected: reader.* = try -> reader.conn = try
                .mode = sqlite.Db.Mode{ .File = self.db_path },
                .open_flags = .{
                    .write = false,
                },
                .shared_cache = self.options.in_memory,
            });
            try configureDatabase(&reader.conn, false);
        }
    }

    /// Push a write op and wake the write thread immediately.
    fn pushWrite(self: *StorageEngine, op: WriteOp) !void {
        try self.write_queue.push(op);
        self.write_cond.signal();
    }

    pub fn flushPendingWrites(self: *StorageEngine) !void {
        std.log.debug("flushPendingWrites: count={}", .{self.pending_writes_count.load(.acquire)});
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        while (self.pending_writes_count.load(.acquire) > 0) {
            self.flush_cond.wait(&self.write_mutex);
        }
    }

    // ─── Schema validation helpers ────────────────────────────────────────────

    /// Find a table in the loaded schema by name. Returns null if not found.
    fn findTable(self: *const StorageEngine, table_name: []const u8) ?schema_parser.TableMetadata {
        return self.schema_metadata.getTable(table_name);
    }

    /// Validate that a table exists
    fn validateTable(self: *const StorageEngine, table_name: []const u8) !void {
        _ = self.findTable(table_name) orelse return StorageError.UnknownTable;
    }

    /// Validate that a field exists in a table
    fn validateField(self: *const StorageEngine, table_name: []const u8, field_name: []const u8) !void {
        const table = self.findTable(table_name) orelse return StorageError.UnknownTable;
        if (table.getField(field_name) == null) return StorageError.UnknownField;
    }

    /// Validate columns for insertOrReplace: check table exists, each column exists,
    /// and required (NOT NULL) columns are not nil.
    fn validateColumns(self: *const StorageEngine, table_name: []const u8, columns: []const ColumnValue) !void {
        const table_metadata = self.findTable(table_name) orelse return StorageError.UnknownTable;
        for (columns) |col| {
            const f = table_metadata.getField(col.name) orelse return StorageError.UnknownField;
            if (f.required and col.value == .nil) return StorageError.NullNotAllowed;
            if (col.value != .nil) {
                try validateValueType(f.sql_type, col.value);
            }
        }
    }

    fn validateValueType(ft: schema_parser.FieldType, value: msgpack.Payload) !void {
        const match = switch (ft) {
            .text => value == .str,
            .integer => value == .uint or value == .int,
            .real => value == .float or value == .uint or value == .int,
            .boolean => value == .bool,
            .array => value == .arr,
        };
        if (!match) return StorageError.TypeMismatch;
    }

    fn getCacheKey(self: *const StorageEngine, table: []const u8, namespace: []const u8, id: []const u8) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}", .{ table, namespace, id });
    }

    /// Converts a msgpack.Payload to a TypedValue based on the schema's FieldType.
    /// Strings and blobs (JSON arrays) are duplicated and owned by the TypedValue.
    fn payloadToTypedValue(allocator: Allocator, ft: schema_parser.FieldType, value: msgpack.Payload) !TypedValue {
        if (value == .nil) return .nil;
        return switch (ft) {
            .text => switch (value) {
                .str => |s| TypedValue{ .text = try allocator.dupe(u8, s.value()) },
                else => StorageError.TypeMismatch,
            },
            .integer => TypedValue{ .integer = try msgpack.payloadAsInt(value) },
            .real => TypedValue{ .real = try msgpack.payloadAsFloat(value) },
            .boolean => TypedValue{ .boolean = try msgpack.payloadAsBool(value) },
            .array => TypedValue{ .blob = try msgpack.payloadToJson(value, allocator) },
        };
    }

    // ─── Storage methods ──────────────────────────────────────────────────

    /// INSERT OR REPLACE a document into a table.
    /// Schema validation happens synchronously before enqueueing.
    pub fn insertOrReplace(
        self: *StorageEngine,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
        columns: []const ColumnValue,
    ) !void {
        std.log.debug("insertOrReplace: table='{s}', id='{s}', namespace='{s}'", .{ table, id, namespace });

        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        try self.validateColumns(table, columns);

        // Look up table schema to determine which columns are array fields
        const table_metadata = self.findTable(table).?; // validateColumns already confirmed table exists

        // Build SQL: INSERT OR REPLACE INTO <table> (id, namespace_id, col1, ..., created_at, updated_at)
        // VALUES (?, ?, ..., COALESCE((SELECT created_at FROM <table> WHERE id=? AND namespace_id=?), ?), ?)
        // Array columns use jsonb(?) instead of ? as the placeholder.
        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(self.allocator);

        try sql_buf.appendSlice(self.allocator, "INSERT INTO ");
        try sql_buf.appendSlice(self.allocator, table);
        try sql_buf.appendSlice(self.allocator, " (id, namespace_id");
        for (columns) |col| {
            try sql_buf.append(self.allocator, ',');
            try sql_buf.appendSlice(self.allocator, col.name);
        }
        try sql_buf.appendSlice(self.allocator, ", created_at, updated_at) VALUES (?, ?");
        for (columns) |col| {
            // Find the field schema to check if it's an array type
            var is_array = false;
            for (table_metadata.table.fields) |f| {
                if (std.mem.eql(u8, f.name, col.name)) {
                    is_array = f.sql_type == .array;
                    break;
                }
            }
            if (is_array) {
                try sql_buf.appendSlice(self.allocator, ", jsonb(?)");
            } else {
                try sql_buf.appendSlice(self.allocator, ", ?");
            }
        }
        // created_at and updated_at placeholders
        try sql_buf.appendSlice(self.allocator, ", ?, ?) ON CONFLICT(id, namespace_id) DO UPDATE SET ");

        // Update each column provided
        for (columns, 0..) |col, i| {
            if (i > 0) try sql_buf.appendSlice(self.allocator, ", ");
            try sql_buf.appendSlice(self.allocator, col.name);
            try sql_buf.appendSlice(self.allocator, " = excluded.");
            try sql_buf.appendSlice(self.allocator, col.name);
        }
        // Always update updated_at
        try sql_buf.appendSlice(self.allocator, ", updated_at = excluded.updated_at");

        const sql = try sql_buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(sql);

        const values = try self.allocator.alloc(TypedValue, columns.len);
        var initialized_count: usize = 0;
        errdefer {
            for (values[0..initialized_count]) |v| {
                switch (v) {
                    .text => |s| self.allocator.free(s),
                    .blob => |b| self.allocator.free(b),
                    else => {},
                }
            }
            self.allocator.free(values);
        }
        for (columns, 0..) |col, i| {
            // Find the field schema to check its type
            var field_type: schema_parser.FieldType = .text;
            for (table_metadata.table.fields) |f| {
                if (std.mem.eql(u8, f.name, col.name)) {
                    field_type = f.sql_type;
                    break;
                }
            }
            values[i] = try payloadToTypedValue(self.allocator, field_type, col.value);
            initialized_count += 1;
        }

        const now = std.time.timestamp();
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const ns_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_owned);
        const table_owned = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(table_owned);

        // Build a write op using the raw SQL path
        const op = WriteOp{
            .insert = .{
                .table = table_owned,
                .id = id_owned,
                .namespace = ns_owned,
                .sql = sql,
                .values = values,
                .timestamp = now,
                .completion_signal = null,
            },
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    /// UPDATE a single field in a table.
    pub fn updateField(
        self: *StorageEngine,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: msgpack.Payload,
    ) !void {
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        try self.validateField(table, field);

        // Look up the field's sql_type to determine if it's an array field and validate type
        const table_metadata = self.findTable(table).?; // validateField already confirmed table exists
        var field_sql_type: schema_parser.FieldType = .text;
        for (table_metadata.table.fields) |f| {
            if (std.mem.eql(u8, f.name, field)) {
                field_sql_type = f.sql_type;
                if (value != .nil) {
                    try validateValueType(field_sql_type, value);
                }
                break;
            }
        }

        const values = try self.allocator.alloc(TypedValue, 1);
        values[0] = .nil;
        errdefer {
            switch (values[0]) {
                .text => |s| self.allocator.free(s),
                .blob => |b| self.allocator.free(b),
                else => {},
            }
            self.allocator.free(values);
        }
        values[0] = try payloadToTypedValue(self.allocator, field_sql_type, value);

        // Use jsonb(?) placeholder for array fields, ? for others
        const field_placeholder = if (field_sql_type == .array) "jsonb(?)" else "?";

        const sql = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s} (id, namespace_id, {s}, created_at, updated_at)
            \\VALUES (?, ?, {s}, ?, ?)
            \\ON CONFLICT(id, namespace_id) DO UPDATE SET
            \\  {s} = excluded.{s},
            \\  updated_at = excluded.updated_at
        , .{ table, field, field_placeholder, field, field });
        errdefer self.allocator.free(sql);

        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const ns_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_owned);
        const table_owned = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(table_owned);

        const now = std.time.timestamp();
        const op = WriteOp{
            .update = .{
                .table = table_owned,
                .id = id_owned,
                .namespace = ns_owned,
                .sql = sql,
                .values = values,
                .timestamp = now,
                .completion_signal = null,
            },
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    /// Select a single document by ID.
    /// Returns a ManagedPayload which may point directly to the cache (zero-copy).
    pub fn selectDocument(
        self: *StorageEngine,
        allocator: Allocator,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
    ) !ManagedPayload {
        try self.validateTable(table);

        const cache_key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ table, namespace, id });
        defer allocator.free(cache_key);

        if (self.metadata_cache.get(cache_key)) |handle| {
            return ManagedPayload{
                .value = handle.data().*,
                .handle = handle,
            };
        } else |err| switch (err) {
            error.NotFound => {},
            else => return err,
        }

        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const node = &self.reader_pool[reader_idx];
        node.mutex.lock();
        defer node.mutex.unlock();

        // Build explicit column list so array fields can be wrapped with json()
        const table_metadata = self.findTable(table).?; // validateTable already confirmed it exists
        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.appendSlice(allocator, "SELECT id, namespace_id");
        for (table_metadata.table.fields) |f| {
            if (f.sql_type == .array) {
                try sql_buf.appendSlice(allocator, ", json(");
                try sql_buf.appendSlice(allocator, f.name);
                try sql_buf.append(allocator, ')');
            } else {
                try sql_buf.append(allocator, ',');
                try sql_buf.appendSlice(allocator, f.name);
            }
        }
        try sql_buf.appendSlice(allocator, ", created_at, updated_at FROM ");
        try sql_buf.appendSlice(allocator, table);
        try sql_buf.appendSlice(allocator, " WHERE id=? AND namespace_id=?");
        const sql = try sql_buf.toOwnedSlice(allocator);
        defer allocator.free(sql);

        // Snapshot write_seq before the DB read.
        const seq_before = self.write_seq.load(.acquire);

        const payload = try execSelectDocument(allocator, &node.conn, sql, id, namespace, table_metadata);
        if (payload) |p| {
            if (self.write_seq.load(.acquire) == seq_before) {
                // Populate cache with a persistent copy (cloned into GPA)
                const cache_payload = try msgpack.clonePayload(p, self.allocator);
                errdefer cache_payload.free(self.allocator);
                try self.metadata_cache.update(cache_key, cache_payload);
            }
        }
        return ManagedPayload{ .value = payload, .handle = null, .allocator = allocator };
    }

    /// SELECT a single field for a document. Returns null if not found.
    /// Caller owns the returned Payload.
    pub fn selectField(
        self: *StorageEngine,
        allocator: Allocator,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
    ) !ManagedPayload {
        try self.validateField(table, field);

        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const node = &self.reader_pool[reader_idx];
        node.mutex.lock();
        defer node.mutex.unlock();

        // Resolve field schema to determine if it's an array field
        const table_metadata = self.findTable(table).?;
        var field_ctx: ?schema_parser.Field = null;
        for (table_metadata.table.fields) |f| {
            if (std.mem.eql(u8, f.name, field)) {
                field_ctx = f;
                break;
            }
        }

        const sql = if (field_ctx != null and field_ctx.?.sql_type == .array)
            try std.fmt.allocPrint(allocator, "SELECT json({s}) FROM {s} WHERE id=? AND namespace_id=?", .{ field, table })
        else
            try std.fmt.allocPrint(allocator, "SELECT {s} FROM {s} WHERE id=? AND namespace_id=?", .{ field, table });
        defer allocator.free(sql);

        const payload = try execSelectScalar(allocator, &node.conn, sql, id, namespace, field_ctx);
        return ManagedPayload{ .value = payload, .handle = null, .allocator = allocator };
    }

    /// SELECT * for all documents in a namespace. Returns a msgpack array of maps.
    /// Caller owns the returned Payload.
    pub fn selectCollection(
        self: *StorageEngine,
        allocator: Allocator,
        table: []const u8,
        namespace: []const u8,
    ) !ManagedPayload {
        try self.validateTable(table);

        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const node = &self.reader_pool[reader_idx];
        node.mutex.lock();
        defer node.mutex.unlock();

        // Build explicit column list so array fields can be wrapped with json()
        const table_metadata = self.findTable(table).?; // validateTable already confirmed it exists
        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        try sql_buf.appendSlice(allocator, "SELECT id, namespace_id");
        for (table_metadata.table.fields) |f| {
            if (f.sql_type == .array) {
                try sql_buf.appendSlice(allocator, ", json(");
                try sql_buf.appendSlice(allocator, f.name);
                try sql_buf.append(allocator, ')');
            } else {
                try sql_buf.append(allocator, ',');
                try sql_buf.appendSlice(allocator, f.name);
            }
        }
        try sql_buf.appendSlice(allocator, ", created_at, updated_at FROM ");
        try sql_buf.appendSlice(allocator, table);
        try sql_buf.appendSlice(allocator, " WHERE namespace_id=?");
        const sql = try sql_buf.toOwnedSlice(allocator);
        defer allocator.free(sql);

        const payload = try execSelectCollection(allocator, &node.conn, sql, namespace, table_metadata.table.*);
        return ManagedPayload{ .value = payload, .handle = null, .allocator = allocator };
    }

    /// SELECT for a query filter. Returns a msgpack array of maps.
    /// Caller owns the returned Payload.
    pub fn selectQuery(
        self: *StorageEngine,
        allocator: Allocator,
        table: []const u8,
        namespace: []const u8,
        filter: query_parser.QueryFilter,
    ) !ManagedPayload {
        try self.validateTable(table);

        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const node = &self.reader_pool[reader_idx];
        node.mutex.lock();
        defer node.mutex.unlock();

        const table_metadata = self.findTable(table).?;

        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(allocator);
        var values: std.ArrayList(TypedValue) = .empty;
        defer {
            for (values.items) |v| {
                switch (v) {
                    .text => |s| allocator.free(s),
                    .blob => |b| allocator.free(b),
                    else => {},
                }
            }
            values.deinit(allocator);
        }

        // 1. SELECT clause
        try sql_buf.appendSlice(allocator, "SELECT id, namespace_id");
        for (table_metadata.table.fields) |f| {
            try sql_buf.appendSlice(allocator, ", ");
            if (f.sql_type == .array) {
                try sql_buf.appendSlice(allocator, "json(");
                try sql_buf.appendSlice(allocator, f.name);
                try sql_buf.appendSlice(allocator, ")");
            } else {
                try sql_buf.appendSlice(allocator, f.name);
            }
        }
        try sql_buf.appendSlice(allocator, ", created_at, updated_at FROM ");
        try sql_buf.appendSlice(allocator, table);

        // 2. WHERE clause
        try sql_buf.appendSlice(allocator, " WHERE namespace_id = ?");
        try values.append(allocator, TypedValue{ .text = try allocator.dupe(u8, namespace) });

        const conds = filter.conditions orelse @as([]const query_parser.Condition, &.{});
        const or_conds = filter.or_conditions orelse @as([]const query_parser.Condition, &.{});
        const has_conditions = conds.len > 0 or or_conds.len > 0;

        if (has_conditions or filter.after != null) {
            try sql_buf.appendSlice(allocator, " AND (");

            var added_where = false;

            // AND conditions
            if (conds.len > 0) {
                try sql_buf.appendSlice(allocator, "(");
                for (conds, 0..) |cond, i| {
                    if (i > 0) try sql_buf.appendSlice(allocator, " AND ");
                    try self.appendConditionSql(allocator, &sql_buf, &values, table, cond);
                }
                try sql_buf.appendSlice(allocator, ")");
                added_where = true;
            }

            // OR conditions
            if (or_conds.len > 0) {
                if (added_where) try sql_buf.appendSlice(allocator, " OR ");
                try sql_buf.appendSlice(allocator, "(");
                for (or_conds, 0..) |cond, i| {
                    if (i > 0) try sql_buf.appendSlice(allocator, " OR ");
                    try self.appendConditionSql(allocator, &sql_buf, &values, table, cond);
                }
                try sql_buf.appendSlice(allocator, ")");
                added_where = true;
            }

            // cursor-based pagination (after)
            if (filter.after) |cursor| {
                if (added_where) try sql_buf.appendSlice(allocator, " AND ");

                const sort_field = if (filter.order_by) |o| o.field else "id";
                const is_desc = if (filter.order_by) |o| o.desc else false;
                const op = if (is_desc) "<" else ">";

                const sql_field = sort_field;

                // SQLite row-value comparison: (sort_field, id) > (?, ?)
                try sql_buf.appendSlice(allocator, "(");
                try sql_buf.appendSlice(allocator, sql_field);
                try sql_buf.appendSlice(allocator, ", id) ");
                try sql_buf.appendSlice(allocator, op);
                try sql_buf.appendSlice(allocator, " (?, ?)");

                // Find sort field type for correct binding
                var sort_ft: schema_parser.FieldType = .text;
                for (table_metadata.table.fields) |f| {
                    if (std.mem.eql(u8, f.name, sql_field)) {
                        sort_ft = f.sql_type;
                        break;
                    }
                }
                if (std.mem.eql(u8, sort_field, "id")) sort_ft = .text;
                if (std.mem.eql(u8, sort_field, "namespace_id")) sort_ft = .text;
                if (std.mem.eql(u8, sort_field, "created_at")) sort_ft = .integer;
                if (std.mem.eql(u8, sort_field, "updated_at")) sort_ft = .integer;

                try values.append(allocator, try payloadToTypedValue(allocator, sort_ft, cursor.sort_value));
                try values.append(allocator, TypedValue{ .text = try allocator.dupe(u8, cursor.id) });
            }

            try sql_buf.appendSlice(allocator, ")");
        }

        // 3. ORDER BY
        try sql_buf.appendSlice(allocator, " ORDER BY ");
        if (filter.order_by) |o| {
            const sql_field = o.field;
            try sql_buf.appendSlice(allocator, sql_field);
            try sql_buf.appendSlice(allocator, if (o.desc) " DESC" else " ASC");
            try sql_buf.appendSlice(allocator, ", id ");
            try sql_buf.appendSlice(allocator, if (o.desc) " DESC" else " ASC");
        } else {
            try sql_buf.appendSlice(allocator, "id ASC");
        }

        // 4. LIMIT
        if (filter.limit) |l| {
            try sql_buf.appendSlice(allocator, " LIMIT ");
            var l_buf: [20]u8 = undefined;
            const l_str = std.fmt.bufPrint(&l_buf, "{}", .{l}) catch "0";
            try sql_buf.appendSlice(allocator, l_str);
        }

        const payload = try execQuery(allocator, &node.conn, sql_buf.items, values.items, table_metadata.table.*);
        return ManagedPayload{ .value = payload, .handle = null, .allocator = allocator };
    }

    fn appendConditionSql(
        self: *StorageEngine,
        allocator: Allocator,
        sql_buf: *std.ArrayList(u8),
        values: *std.ArrayList(TypedValue),
        table: []const u8,
        cond: query_parser.Condition,
    ) !void {
        const sql_field = cond.field;

        // Find field type for value binding
        const table_metadata = self.findTable(table).?;
        var ft: schema_parser.FieldType = .text;
        for (table_metadata.table.fields) |f| {
            if (std.mem.eql(u8, f.name, sql_field)) {
                ft = f.sql_type;
                break;
            }
        }
        if (std.mem.eql(u8, cond.field, "id")) ft = .text;
        if (std.mem.eql(u8, cond.field, "namespace_id")) ft = .text;
        if (std.mem.eql(u8, cond.field, "created_at")) ft = .integer;
        if (std.mem.eql(u8, cond.field, "updated_at")) ft = .integer;

        try sql_buf.appendSlice(allocator, sql_field);

        switch (cond.op) {
            .eq => {
                const val = cond.value orelse return error.MissingConditionValue;
                try sql_buf.appendSlice(allocator, " = ?");
                try values.append(allocator, try payloadToTypedValue(allocator, ft, val));
            },
            .ne => {
                const val = cond.value orelse return error.MissingConditionValue;
                try sql_buf.appendSlice(allocator, " != ?");
                try values.append(allocator, try payloadToTypedValue(allocator, ft, val));
            },
            .gt => {
                const val = cond.value orelse return error.MissingConditionValue;
                try sql_buf.appendSlice(allocator, " > ?");
                try values.append(allocator, try payloadToTypedValue(allocator, ft, val));
            },
            .lt => {
                const val = cond.value orelse return error.MissingConditionValue;
                try sql_buf.appendSlice(allocator, " < ?");
                try values.append(allocator, try payloadToTypedValue(allocator, ft, val));
            },
            .gte => {
                const val = cond.value orelse return error.MissingConditionValue;
                try sql_buf.appendSlice(allocator, " >= ?");
                try values.append(allocator, try payloadToTypedValue(allocator, ft, val));
            },
            .lte => {
                const val = cond.value orelse return error.MissingConditionValue;
                try sql_buf.appendSlice(allocator, " <= ?");
                try values.append(allocator, try payloadToTypedValue(allocator, ft, val));
            },
            .contains => {
                const val = cond.value orelse return error.MissingConditionValue;
                const raw_str = switch (val) {
                    .str => |s| s.value(),
                    else => return error.TypeMismatch,
                };
                const escaped = try escapeLikePattern(allocator, raw_str);
                errdefer allocator.free(escaped);
                try sql_buf.appendSlice(allocator, " LIKE '%' || ? || '%' ESCAPE '\\'");
                try values.append(allocator, TypedValue{ .text = escaped });
            },
            .startsWith => {
                const val = cond.value orelse return error.MissingConditionValue;
                const raw_str = switch (val) {
                    .str => |s| s.value(),
                    else => return error.TypeMismatch,
                };
                const escaped = try escapeLikePattern(allocator, raw_str);
                errdefer allocator.free(escaped);
                try sql_buf.appendSlice(allocator, " LIKE ? || '%' ESCAPE '\\'");
                try values.append(allocator, TypedValue{ .text = escaped });
            },
            .endsWith => {
                const val = cond.value orelse return error.MissingConditionValue;
                const raw_str = switch (val) {
                    .str => |s| s.value(),
                    else => return error.TypeMismatch,
                };
                const escaped = try escapeLikePattern(allocator, raw_str);
                errdefer allocator.free(escaped);
                try sql_buf.appendSlice(allocator, " LIKE '%' || ? ESCAPE '\\'");
                try values.append(allocator, TypedValue{ .text = escaped });
            },
            .isNull => try sql_buf.appendSlice(allocator, " IS NULL"),
            .isNotNull => try sql_buf.appendSlice(allocator, " IS NOT NULL"),
            .in, .notIn => {
                const is_not = cond.op == .notIn;
                try sql_buf.appendSlice(allocator, if (is_not) " NOT IN (" else " IN (");
                if (cond.value) |val| {
                    if (val == .arr) {
                        for (val.arr, 0..) |v, i| {
                            if (i > 0) try sql_buf.appendSlice(allocator, ", ");
                            try sql_buf.appendSlice(allocator, "?");
                            try values.append(allocator, try payloadToTypedValue(allocator, ft, v));
                        }
                    } else {
                        // Fallback for single value even if it should be an array
                        try sql_buf.appendSlice(allocator, "?");
                        try values.append(allocator, try payloadToTypedValue(allocator, ft, val));
                    }
                }
                try sql_buf.appendSlice(allocator, ")");
            },
        }
    }

    fn execQuery(
        allocator: Allocator,
        db: *sqlite.Db,
        sql: []const u8,
        values: []const TypedValue,
        table_schema: schema_parser.Table,
    ) !msgpack.Payload {
        var stmt = db.prepareDynamic(sql) catch |err| {
            std.log.err("Failed to prepare SQL: {s}\nError: {}", .{ sql, err });
            return classifyError(err);
        };
        defer stmt.deinit();

        for (values, 0..) |v, i| {
            bindTypedValue(stmt, @intCast(i + 1), v);
        }

        var arr: std.ArrayList(msgpack.Payload) = .empty;
        errdefer {
            for (arr.items) |item| item.free(allocator);
            arr.deinit(allocator);
        }

        const col_count: c_int = sqlite.c.sqlite3_column_count(stmt.stmt);

        while (true) {
            const rc = sqlite.c.sqlite3_step(stmt.stmt);
            if (rc == sqlite.c.SQLITE_DONE) break;
            if (rc != sqlite.c.SQLITE_ROW) return error.SQLiteError;

            var map = msgpack.Payload.mapPayload(allocator);
            errdefer map.free(allocator);

            var i: c_int = 0;
            while (i < col_count) : (i += 1) {
                const ctx = resolveColumnContext(stmt, i, table_schema);
                const val = try readColumnValue(allocator, stmt, i, ctx.field);
                try map.mapPut(ctx.name, val);
            }
            try arr.append(allocator, map);
        }

        return msgpack.Payload{ .arr = try arr.toOwnedSlice(allocator) };
    }

    pub fn deleteDocument(
        self: *StorageEngine,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
    ) !void {
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        try self.validateTable(table);

        const sql = try std.fmt.allocPrint(self.allocator, "DELETE FROM {s} WHERE id=? AND namespace_id=?", .{table});
        errdefer self.allocator.free(sql);

        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const ns_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_owned);
        const table_owned = try self.allocator.dupe(u8, table);
        errdefer self.allocator.free(table_owned);

        const op = WriteOp{
            .delete = .{
                .table = table_owned,
                .id = id_owned,
                .namespace = ns_owned,
                .sql = sql,
                .completion_signal = null,
            },
        };
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    // ─── Internal read helpers ────────────────────────────────────────────────

    const ColumnContext = struct {
        name: []const u8,
        field: ?schema_parser.Field,
    };

    fn resolveColumnContext(
        stmt: sqlite.DynamicStatement,
        i: c_int,
        table_schema: schema_parser.Table,
    ) ColumnContext {
        const col_name_ptr = sqlite.c.sqlite3_column_name(stmt.stmt, i);
        // json(col) returns the column name as "json(col)" — strip the wrapper to get the real name
        const raw_name = std.mem.span(col_name_ptr);
        const col_name = if (std.mem.startsWith(u8, raw_name, "json(") and std.mem.endsWith(u8, raw_name, ")"))
            raw_name[5 .. raw_name.len - 1]
        else
            raw_name;

        // Resolve field context: null for system columns, Field for user-defined columns
        const system_cols = [_][]const u8{ "id", "namespace_id", "created_at", "updated_at" };
        var field_ctx: ?schema_parser.Field = null;
        var is_system = false;
        for (system_cols) |sc| {
            if (std.mem.eql(u8, col_name, sc)) {
                is_system = true;
                break;
            }
        }
        if (!is_system) {
            for (table_schema.fields) |f| {
                if (std.mem.eql(u8, f.name, col_name)) {
                    field_ctx = f;
                    break;
                }
            }
        }

        return .{ .name = col_name, .field = field_ctx };
    }

    /// Read a single column value from a prepared statement at column index i.
    /// Pass the resolved schema Field for user-defined columns; pass null for system columns
    /// (id, namespace_id, created_at, updated_at). Array fields stored as BLOB are returned
    /// via json(col) in the SELECT, which yields SQLITE_TEXT — dispatched to jsonToPayload.
    fn readColumnValue(allocator: Allocator, stmt: sqlite.DynamicStatement, i: c_int, field: ?schema_parser.Field) !msgpack.Payload {
        const col_type = sqlite.c.sqlite3_column_type(stmt.stmt, i);
        // Array fields: json(col) returns SQLITE_TEXT containing a JSON array string.
        if (field != null and field.?.sql_type == .array and col_type == sqlite.c.SQLITE_TEXT) {
            const ptr = sqlite.c.sqlite3_column_text(stmt.stmt, i);
            const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt.stmt, i));
            const s = if (ptr != null) ptr[0..len] else "[]";
            return msgpack.jsonToPayload(s, allocator);
        }
        return switch (col_type) {
            sqlite.c.SQLITE_INTEGER => {
                const val = sqlite.c.sqlite3_column_int64(stmt.stmt, i);
                if (field != null and field.?.sql_type == .boolean) {
                    return msgpack.Payload{ .bool = val != 0 };
                }
                return msgpack.Payload.intToPayload(val);
            },
            sqlite.c.SQLITE_FLOAT => msgpack.Payload{ .float = sqlite.c.sqlite3_column_double(stmt.stmt, i) },
            sqlite.c.SQLITE_TEXT => blk: {
                const ptr = sqlite.c.sqlite3_column_text(stmt.stmt, i);
                const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt.stmt, i));
                const s = if (ptr != null) ptr[0..len] else "";
                break :blk try msgpack.Payload.strToPayload(s, allocator);
            },
            sqlite.c.SQLITE_BLOB => blk: {
                const ptr = sqlite.c.sqlite3_column_blob(stmt.stmt, i);
                const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(stmt.stmt, i));
                const b: []const u8 = if (ptr != null) @as([*]const u8, @ptrCast(ptr))[0..len] else "";
                var any_reader: std.Io.Reader = .fixed(b);
                break :blk msgpack.decodeTrusted(allocator, &any_reader) catch
                    try msgpack.Payload.strToPayload(b, allocator);
            },
            else => .nil, // SQLITE_NULL
        };
    }

    /// Execute a SELECT with explicit column list WHERE id=? AND namespace_id=? and return a msgpack map or null.
    /// Array columns must be wrapped with json() in the SQL; table_schema is used to resolve field context.
    fn execSelectDocument(
        allocator: Allocator,
        reader: *sqlite.Db,
        sql: []const u8,
        id: []const u8,
        namespace: []const u8,
        table_metadata: schema_parser.TableMetadata,
    ) !?msgpack.Payload {
        var stmt = reader.prepareDynamic(sql) catch |err| return classifyError(err);
        defer stmt.deinit();

        // Bind parameters using the raw C API
        const id_z = try allocator.dupeZ(u8, id);
        defer allocator.free(id_z);
        const ns_z = try allocator.dupeZ(u8, namespace);
        defer allocator.free(ns_z);

        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 1, id_z.ptr, @intCast(id.len), sqlite.c.SQLITE_STATIC);
        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 2, ns_z.ptr, @intCast(namespace.len), sqlite.c.SQLITE_STATIC);

        const rc = sqlite.c.sqlite3_step(stmt.stmt);
        if (rc == sqlite.c.SQLITE_DONE) return null;
        if (rc != sqlite.c.SQLITE_ROW) return error.SQLiteError;

        const col_count: c_int = sqlite.c.sqlite3_column_count(stmt.stmt);
        var map = msgpack.Payload.mapPayload(allocator);
        errdefer map.free(allocator);

        var i: c_int = 0;
        while (i < col_count) : (i += 1) {
            const ctx = resolveColumnContext(stmt, i, table_metadata.table.*);
            const val = try readColumnValue(allocator, stmt, i, ctx.field);
            try map.mapPut(ctx.name, val);
        }
        return map;
    }

    /// Execute a SELECT <col> ... WHERE id=? AND namespace_id=? and return scalar or null.
    fn execSelectScalar(
        allocator: Allocator,
        reader: *sqlite.Db,
        sql: []const u8,
        id: []const u8,
        namespace: []const u8,
        field_ctx: ?schema_parser.Field,
    ) !?msgpack.Payload {
        var stmt = reader.prepareDynamic(sql) catch |err| return classifyError(err);
        defer stmt.deinit();

        const id_z = try allocator.dupeZ(u8, id);
        defer allocator.free(id_z);
        const ns_z = try allocator.dupeZ(u8, namespace);
        defer allocator.free(ns_z);

        std.log.debug("execSelectScalar: sql='{s}', id='{s}', namespace='{s}'", .{ sql, id, namespace });

        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 1, id_z.ptr, @intCast(id.len), sqlite.c.SQLITE_STATIC);
        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 2, ns_z.ptr, @intCast(namespace.len), sqlite.c.SQLITE_STATIC);

        const rc = sqlite.c.sqlite3_step(stmt.stmt);
        if (rc == sqlite.c.SQLITE_DONE) return null;
        if (rc != sqlite.c.SQLITE_ROW) return error.SQLiteError;

        return try readColumnValue(allocator, stmt, 0, field_ctx);
    }

    /// Execute a SELECT with explicit column list WHERE namespace_id=? and return a msgpack array of maps.
    /// Array columns must be wrapped with json() in the SQL; table_schema is used to resolve field context.
    fn execSelectCollection(
        allocator: Allocator,
        reader: *sqlite.Db,
        sql: []const u8,
        namespace: []const u8,
        table_schema: schema_parser.Table,
    ) !msgpack.Payload {
        var stmt = reader.prepareDynamic(sql) catch |err| return classifyError(err);
        defer stmt.deinit();

        const ns_z = try allocator.dupeZ(u8, namespace);
        defer allocator.free(ns_z);

        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 1, ns_z.ptr, @intCast(namespace.len), sqlite.c.SQLITE_STATIC);

        var arr: std.ArrayList(msgpack.Payload) = .empty;
        errdefer {
            for (arr.items) |item| item.free(allocator);
            arr.deinit(allocator);
        }

        const col_count: c_int = sqlite.c.sqlite3_column_count(stmt.stmt);

        while (true) {
            const rc = sqlite.c.sqlite3_step(stmt.stmt);
            if (rc == sqlite.c.SQLITE_DONE) break;
            if (rc != sqlite.c.SQLITE_ROW) return error.SQLiteError;

            var map = msgpack.Payload.mapPayload(allocator);
            errdefer map.free(allocator);

            var i: c_int = 0;
            while (i < col_count) : (i += 1) {
                const ctx = resolveColumnContext(stmt, i, table_schema);
                const val = try readColumnValue(allocator, stmt, i, ctx.field);
                try map.mapPut(ctx.name, val);
            }
            try arr.append(allocator, map);
        }

        return msgpack.Payload{ .arr = try arr.toOwnedSlice(allocator) };
    }

    // ─── Internal write helpers ───────────────────────────────────────────────

    fn escapeLikePattern(allocator: Allocator, input: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        for (input) |c| {
            if (c == '%' or c == '_' or c == '\\') {
                try out.append(allocator, '\\');
            }
            try out.append(allocator, c);
        }
        return out.toOwnedSlice(allocator);
    }

    fn bindTypedValue(stmt: sqlite.DynamicStatement, index: c_int, value: TypedValue) void {
        switch (value) {
            .integer => |v| _ = sqlite.c.sqlite3_bind_int64(stmt.stmt, index, v),
            .real => |v| _ = sqlite.c.sqlite3_bind_double(stmt.stmt, index, v),
            .text => |s| _ = sqlite.c.sqlite3_bind_text(stmt.stmt, index, s.ptr, @intCast(s.len), sqlite.c.SQLITE_STATIC),
            .boolean => |b| _ = sqlite.c.sqlite3_bind_int(stmt.stmt, index, if (b) 1 else 0),
            .blob => |b| _ = sqlite.c.sqlite3_bind_blob(stmt.stmt, index, b.ptr, @intCast(b.len), sqlite.c.SQLITE_STATIC),
            .nil => _ = sqlite.c.sqlite3_bind_null(stmt.stmt, index),
        }
    }

    fn executeInsert(self: *StorageEngine, op: anytype) !void {
        const sql = op.sql;
        std.log.debug("executeInsert: sql='{s}', id='{s}', namespace='{s}', timestamp={}", .{ sql, op.id, op.namespace, op.timestamp });
        var stmt = self.writer_conn.prepareDynamic(sql) catch |err| return classifyError(err);
        defer stmt.deinit();

        const id_z = try self.allocator.dupeZ(u8, op.id);
        defer self.allocator.free(id_z);
        const ns_z = try self.allocator.dupeZ(u8, op.namespace);
        defer self.allocator.free(ns_z);

        // Bind: id, namespace_id, col1..colN, id (COALESCE), namespace_id (COALESCE), created_at, updated_at
        var bind_idx: c_int = 1;
        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, bind_idx, id_z.ptr, @intCast(op.id.len), sqlite.c.SQLITE_STATIC);
        bind_idx += 1;
        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, bind_idx, ns_z.ptr, @intCast(op.namespace.len), sqlite.c.SQLITE_STATIC);
        bind_idx += 1;

        for (op.values) |val| {
            bindTypedValue(stmt, bind_idx, val);
            bind_idx += 1;
        }

        // created_at
        _ = sqlite.c.sqlite3_bind_int64(stmt.stmt, bind_idx, op.timestamp);
        bind_idx += 1;
        // updated_at
        _ = sqlite.c.sqlite3_bind_int64(stmt.stmt, bind_idx, op.timestamp);
        bind_idx += 1;

        const rc = sqlite.c.sqlite3_step(stmt.stmt);
        if (rc != sqlite.c.SQLITE_DONE) return error.SQLiteError;
    }

    fn executeUpdate(self: *StorageEngine, op: anytype) !void {
        const sql = op.sql;
        var stmt = self.writer_conn.prepareDynamic(sql) catch |err| return classifyError(err);
        defer stmt.deinit();

        const id_z = try self.allocator.dupeZ(u8, op.id);
        defer self.allocator.free(id_z);
        const ns_z = try self.allocator.dupeZ(u8, op.namespace);
        defer self.allocator.free(ns_z);
        // Bind: 1: id, 2: namespace_id, 3: value, 4: created_at, 5: updated_at
        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 1, id_z.ptr, @intCast(op.id.len), sqlite.c.SQLITE_STATIC);
        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 2, ns_z.ptr, @intCast(op.namespace.len), sqlite.c.SQLITE_STATIC);
        bindTypedValue(stmt, 3, op.values[0]);
        _ = sqlite.c.sqlite3_bind_int64(stmt.stmt, 4, op.timestamp);
        _ = sqlite.c.sqlite3_bind_int64(stmt.stmt, 5, op.timestamp);

        const rc = sqlite.c.sqlite3_step(stmt.stmt);
        if (rc != sqlite.c.SQLITE_DONE) return error.SQLiteError;
    }

    fn executeDelete(self: *StorageEngine, op: anytype) !void {
        const sql = op.sql;
        var stmt = self.writer_conn.prepareDynamic(sql) catch |err| return classifyError(err);
        defer stmt.deinit();

        const id_z = try self.allocator.dupeZ(u8, op.id);
        defer self.allocator.free(id_z);
        const ns_z = try self.allocator.dupeZ(u8, op.namespace);
        defer self.allocator.free(ns_z);

        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 1, id_z.ptr, @intCast(op.id.len), sqlite.c.SQLITE_STATIC);
        _ = sqlite.c.sqlite3_bind_text(stmt.stmt, 2, ns_z.ptr, @intCast(op.namespace.len), sqlite.c.SQLITE_STATIC);

        const rc = sqlite.c.sqlite3_step(stmt.stmt);
        if (rc != sqlite.c.SQLITE_DONE) return error.SQLiteError;
    }

    fn writeThreadLoop(self: *StorageEngine) void {
        self.writeThreadLoopImpl() catch |err| {
            std.log.err("Write thread error: {}", .{err});
        };
    }

    fn writeThreadLoopImpl(self: *StorageEngine) !void {
        // Signal that the write thread is up and running
        self.write_thread_ready.store(true, .release);
        self.write_mutex.lock();
        self.write_cond.signal();
        self.write_mutex.unlock();

        const batch_size = 200;
        const batch_timeout = self.performance_config.batch_timeout;

        var batch = std.ArrayListUnmanaged(WriteOp){};
        try batch.ensureTotalCapacity(self.allocator, batch_size);
        defer {
            for (batch.items) |op| {
                op.deinit(self.allocator);
            }
            batch.deinit(self.allocator);
        }

        var last_batch_time = std.time.milliTimestamp();

        while (!self.shutdown_requested.load(.acquire)) {
            // Collect operations for batch
            while (batch.items.len < batch_size) {
                if (self.write_queue.pop()) |op| {
                    switch (op) {
                        .insert, .update, .delete, .ddl => {
                            batch.append(self.allocator, op) catch |err| {
                                std.log.err("Failed to append to batch: {}", .{err});
                                op.deinit(self.allocator);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                self.write_mutex.lock();
                                self.flush_cond.broadcast();
                                self.write_mutex.unlock();
                                continue;
                            };
                        },
                        .begin_transaction => |top| {
                            // Flush current batch first
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            if (self.writer_conn.exec("BEGIN TRANSACTION", .{}, .{})) |_| {
                                self.transaction_active.store(true, .release);
                                self.manual_transaction_active.store(true, .release);
                                if (top.completion_signal) |sig| sig.signal(null);
                            } else |err| {
                                if (top.completion_signal) |sig| sig.signal(classifyError(err));
                            }
                            _ = self.pending_writes_count.fetchSub(1, .release);
                            self.write_mutex.lock();
                            self.flush_cond.broadcast();
                            self.write_mutex.unlock();
                        },
                        .commit_transaction => |top| {
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            if (!self.transaction_active.load(.acquire)) {
                                if (top.completion_signal) |sig| sig.signal(StorageError.NoActiveTransaction);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                self.write_mutex.lock();
                                self.flush_cond.broadcast();
                                self.write_mutex.unlock();
                                continue;
                            }
                            if (self.writer_conn.exec("COMMIT", .{}, .{})) |_| {
                                self.transaction_active.store(false, .release);
                                self.manual_transaction_active.store(false, .release);
                                // Bump write_seq so readers know committed data may
                                // differ from anything they read during the transaction.
                                _ = self.write_seq.fetchAdd(1, .acq_rel);
                                if (top.completion_signal) |sig| sig.signal(null);
                            } else |err| {
                                self.transaction_active.store(false, .release);
                                self.manual_transaction_active.store(false, .release);
                                if (top.completion_signal) |sig| sig.signal(classifyError(err));
                            }
                            _ = self.pending_writes_count.fetchSub(1, .release);
                            self.write_mutex.lock();
                            self.flush_cond.broadcast();
                            self.write_mutex.unlock();
                        },
                        .rollback_transaction => |top| {
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            if (!self.transaction_active.load(.acquire)) {
                                if (top.completion_signal) |sig| sig.signal(StorageError.NoActiveTransaction);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                self.write_mutex.lock();
                                self.flush_cond.broadcast();
                                self.write_mutex.unlock();
                                continue;
                            }
                            if (self.writer_conn.exec("ROLLBACK", .{}, .{})) |_| {
                                self.transaction_active.store(false, .release);
                                self.manual_transaction_active.store(false, .release);
                                if (top.completion_signal) |sig| sig.signal(null);
                            } else |err| {
                                self.transaction_active.store(false, .release);
                                self.manual_transaction_active.store(false, .release);
                                if (top.completion_signal) |sig| sig.signal(classifyError(err));
                            }
                            _ = self.pending_writes_count.fetchSub(1, .release);
                            self.write_mutex.lock();
                            self.flush_cond.broadcast();
                            self.write_mutex.unlock();
                        },
                        .checkpoint => |cop| {
                            if (batch.items.len > 0) {
                                try self.flushBatch(&batch, &last_batch_time);
                            }
                            const stats = self.internalExecuteCheckpoint(cop.mode) catch |err| {
                                cop.completion_signal.signal(err);
                                _ = self.pending_writes_count.fetchSub(1, .release);
                                self.write_mutex.lock();
                                self.flush_cond.broadcast();
                                self.write_mutex.unlock();
                                continue;
                            };
                            cop.completion_signal.signalWithResult(stats);
                            _ = self.pending_writes_count.fetchSub(1, .release);
                            self.write_mutex.lock();
                            self.flush_cond.broadcast();
                            self.write_mutex.unlock();
                        },
                    }
                } else {
                    break;
                }
            }

            // Check if we should flush batch
            const now = std.time.milliTimestamp();
            const time_since_last = now - last_batch_time;

            const should_flush = batch.items.len >= batch_size or
                (batch.items.len > 0 and time_since_last >= batch_timeout);

            if (should_flush) {
                try self.flushBatch(&batch, &last_batch_time);
            } else {
                // Wait for new work or timeout (for batch flushing), instead of busy-sleeping
                self.write_mutex.lock();
                defer self.write_mutex.unlock();
                self.write_cond.timedWait(&self.write_mutex, 1 * std.time.ns_per_ms) catch |err| {
                    if (err != error.Timeout) {
                        std.log.err("write_cond.timedWait failed: {}", .{err});
                    }
                };
            }
        }

        // Drain any ops still in the queue that weren't popped before shutdown was signalled
        while (self.write_queue.pop()) |op| {
            switch (op) {
                .insert, .update, .delete => {
                    batch.append(self.allocator, op) catch {
                        op.deinit(self.allocator);
                        _ = self.pending_writes_count.fetchSub(1, .release);
                        self.write_mutex.lock();
                        self.flush_cond.broadcast();
                        self.write_mutex.unlock();
                    };
                },
                else => {
                    // Signal waiting callers so they don't hang forever
                    if (op.getCompletionSignal()) |sig| sig.signal(StorageError.InvalidOperation);
                    op.deinit(self.allocator);
                    _ = self.pending_writes_count.fetchSub(1, .release);
                    self.write_mutex.lock();
                    self.flush_cond.broadcast();
                    self.write_mutex.unlock();
                },
            }
        }

        // Flush remaining operations on shutdown
        if (batch.items.len > 0) {
            try self.flushBatch(&batch, &last_batch_time);
        }
    }

    fn flushBatch(self: *StorageEngine, batch: *std.ArrayListUnmanaged(WriteOp), last_batch_time: *i64) !void {
        const batch_len = batch.items.len;
        std.log.debug("flushBatch: flushing {} ops", .{batch_len});

        // Collect eviction keys BEFORE committing so the cache is cleared
        // before the new data becomes visible to readers. This ensures a reader
        // that starts after the commit will always miss the cache and go to DB.
        var eviction_keys = std.ArrayList([]const u8).empty;
        defer {
            for (eviction_keys.items) |k| self.allocator.free(k);
            eviction_keys.deinit(self.allocator);
        }
        for (batch.items) |op| {
            // SAFETY: Initialized in the switch below.
            var table: []const u8 = undefined;
            // SAFETY: Initialized in the switch below.
            var id: []const u8 = undefined;
            // SAFETY: Initialized in the switch below.
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
                const key = self.getCacheKey(table, ns, id) catch |err| {
                    std.log.err("Failed to create cache key for eviction: {}", .{err});
                    continue;
                };
                eviction_keys.append(self.allocator, key) catch |err| {
                    std.log.err("Failed to append eviction key: {}", .{err});
                    self.allocator.free(key);
                    continue;
                };
            }
        }

        // Evict before commit: any reader starting after this point will miss
        // the cache and read fresh data from DB once the commit lands.
        if (eviction_keys.items.len > 0) {
            self.metadata_cache.bulkEvict(eviction_keys.items);
        }

        const result = self.executeBatch(batch.items);
        if (result) |_| {
            // Bump write_seq after commit so selectDocument's guard knows a
            // write landed and skips caching a value read before this commit.
            _ = self.write_seq.fetchAdd(1, .acq_rel);

            for (batch.items) |op| {
                if (op.getCompletionSignal()) |sig| {
                    sig.signal(null);
                }
                op.deinit(self.allocator);
            }
        } else |err| {
            const classified_err = classifyError(err);
            std.log.debug("Failed to execute batch, transaction rolled back: {}", .{classified_err});
            for (batch.items) |op| {
                if (op.getCompletionSignal()) |sig| sig.signal(classified_err);
                op.deinit(self.allocator);
            }
        }
        batch.clearRetainingCapacity();
        _ = self.pending_writes_count.fetchSub(batch_len, .release);
        self.write_mutex.lock();
        self.flush_cond.broadcast();
        self.write_mutex.unlock();
        last_batch_time.* = std.time.milliTimestamp();
    }

    fn executeBatch(self: *StorageEngine, ops: []const WriteOp) !void {
        // Check if a manual transaction is already active
        const manual_transaction_active = self.transaction_active.load(.acquire);

        if (!manual_transaction_active) {
            self.writer_conn.exec("BEGIN TRANSACTION", .{}, .{}) catch |err| {
                const classified_err = classifyError(err);
                logDatabaseError("executeBatch BEGIN", classified_err, "");
                return classified_err;
            };
            self.transaction_active.store(true, .release);
        }

        // Ensure rollback on error (only if we started the transaction)
        errdefer {
            if (!manual_transaction_active) {
                self.writer_conn.exec("ROLLBACK", .{}, .{}) catch |rollback_err| {
                    const classified_err = classifyError(rollback_err);
                    logDatabaseError("executeBatch ROLLBACK", classified_err, "");
                };
                self.transaction_active.store(false, .release);
            }
        }

        // Execute all operations
        for (ops) |op| {
            switch (op) {
                .insert => |iop| self.executeInsert(iop) catch |err| {
                    const classified_err = classifyError(err);
                    logDatabaseError("executeBatch INSERT", classified_err, iop.table);
                    return classified_err;
                },
                .update => |uop| self.executeUpdate(uop) catch |err| {
                    const classified_err = classifyError(err);
                    logDatabaseError("executeBatch UPDATE", classified_err, uop.table);
                    return classified_err;
                },
                .delete => |dop| self.executeDelete(dop) catch |err| {
                    const classified_err = classifyError(err);
                    logDatabaseError("executeBatch DELETE", classified_err, dop.table);
                    return classified_err;
                },
                .ddl => |dop| {
                    const sql = dop.sql;
                    var it = std.mem.splitScalar(u8, sql, ';');
                    while (it.next()) |stmt_raw| {
                        const stmt = std.mem.trim(u8, stmt_raw, " \r\n\t");
                        if (stmt.len == 0) continue;

                        self.writer_conn.execDynamic(stmt, .{}, .{}) catch |err| {
                            std.log.err("executeBatch DDL error: {}\nSQL:\n{s}", .{ err, stmt });
                            const classified_err = classifyError(err);
                            logDatabaseError("executeBatch DDL", classified_err, stmt);
                            return classified_err;
                        };
                    }
                },
                .begin_transaction, .commit_transaction, .rollback_transaction, .checkpoint => unreachable, // Non-batch ops filtered by loop
            }
        }

        // Commit transaction and clear state (only if we started the transaction)
        if (!manual_transaction_active) {
            self.writer_conn.exec("COMMIT", .{}, .{}) catch |err| {
                const classified_err = classifyError(err);
                logDatabaseError("executeBatch COMMIT", classified_err, "");
                return classified_err;
            };
            std.log.debug("executeBatch: COMMIT successful", .{});
            self.transaction_active.store(false, .release);
        }
    }

    fn configureDatabase(db: *sqlite.Db, is_writer: bool) !void {
        if (is_writer) {
            // journal_mode = WAL returns "wal", so we use void to consume the result row.
            _ = db.pragma(void, .{}, "journal_mode", "wal") catch |err| {
                const classified_err = classifyError(err);
                logDatabaseError("configureDatabase journal_mode", classified_err, "");
                return classified_err;
            };

            _ = db.pragma(void, .{}, "wal_autocheckpoint", "1000") catch |err| {
                const classified_err = classifyError(err);
                logDatabaseError("configureDatabase wal_autocheckpoint", classified_err, "");
                return classified_err;
            };
        }

        // busy_timeout = 5000ms: wait for locks instead of failing immediately.
        // This is crucial for shared-cache mode in-memory.
        _ = db.pragma(void, .{}, "busy_timeout", "5000") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase busy_timeout", classified_err, "");
            return classified_err;
        };

        // read_uncommitted = true: in shared-cache mode, this disables table-level locking
        // and relies on WAL's snapshot isolation. This resolves SQLITE_LOCKED issues.
        _ = db.pragma(void, .{}, "read_uncommitted", "true") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase read_uncommitted", classified_err, "");
            return classified_err;
        };

        // The following usually return nothing or a single row with the new value.
        // Using `void` with `pragma` ensures that the result row (if any) is consumed.
        _ = db.pragma(void, .{}, "synchronous", "normal") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase synchronous", classified_err, "");
            return classified_err;
        };
        _ = db.pragma(void, .{}, "cache_size", "-64000") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase cache_size", classified_err, "");
            return classified_err;
        };
        _ = db.pragma(void, .{}, "mmap_size", "268435456") catch |err| {
            const classified_err = classifyError(err);
            logDatabaseError("configureDatabase mmap_size", classified_err, "");
            return classified_err;
        };
    }
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
                for (op.values) |val| {
                    switch (val) {
                        .text => |s| allocator.free(s),
                        .blob => |b| allocator.free(b),
                        else => {},
                    }
                }
                allocator.free(op.values);
            },
            .update => |op| {
                allocator.free(op.namespace);
                allocator.free(op.table);
                allocator.free(op.id);
                allocator.free(op.sql);
                for (op.values) |val| {
                    switch (val) {
                        .text => |s| allocator.free(s),
                        .blob => |b| allocator.free(b),
                        else => {},
                    }
                }
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
    const Node = struct {
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
