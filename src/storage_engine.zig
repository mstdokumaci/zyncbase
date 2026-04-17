const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const reader = @import("storage_engine/reader.zig");
const writer = @import("storage_engine/writer.zig");
const connection = @import("storage_engine/connection.zig");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const query_parser = @import("query_parser.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const types = @import("storage_engine/types.zig");
const sql = @import("storage_engine/sql.zig");
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;

pub const StorageError = types.StorageError;
pub const ColumnValue = types.ColumnValue;
pub const ManagedResult = types.ManagedResult;
pub const TypedValue = types.TypedValue;
pub const TypedRow = types.TypedRow;
pub const TableMetadata = schema_manager.TableMetadata;
pub const TypedCursor = types.TypedCursor;
pub const CheckpointMode = types.CheckpointMode;
pub const ReaderNode = types.ReaderNode;
pub const CheckpointStats = types.CheckpointStats;
pub const ReconnectionConfig = types.ReconnectionConfig;
pub const WriteOp = types.WriteOp;
pub const WriteQueue = types.WriteQueue;
pub const typed_cache_type = types.typed_cache_type;
pub const ColumnContext = types.ColumnContext;

var unique_id_counter = std.atomic.Value(usize).init(0);

pub const StorageEngine = struct {
    pub const Options = struct {
        in_memory: bool = false,
        reader_pool_size: usize = 0,
    };

    pub const PerformanceConfig = @import("config_loader.zig").Config.PerformanceConfig;

    pub const State = enum(u8) { setup, running, shutdown };

    allocator: Allocator,
    db_path: [:0]const u8,
    _writer_conn: sqlite.Db,
    writer_stmt_cache: sql.StatementCache,
    reader_pool: []ReaderNode,
    write_queue: WriteQueue,
    write_thread: ?std.Thread = null,
    state: std.atomic.Value(State),
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
    schema_manager: *const SchemaManager,
    metadata_cache: typed_cache_type,
    /// Monotonically increasing counter bumped by the write thread after each
    /// successful batch commit, before cache eviction. Readers snapshot this
    /// before the DB read and only populate the cache if it hasn't advanced,
    /// preventing stale values from racing into the cache.
    write_seq: std.atomic.Value(u64),
    performance_config: PerformanceConfig,
    options: Options,
    change_buffer: ChangeBuffer,
    event_loop_notifier: ?*const fn (ctx: ?*anyopaque) void,
    notifier_ctx: ?*anyopaque,

    pub fn init(
        self: *StorageEngine,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        data_dir: []const u8,
        sm: *const SchemaManager,
        performance_config: PerformanceConfig,
        options: Options,
        event_loop_notifier: ?*const fn (ctx: ?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) !void {
        if (data_dir.len == 0 and !options.in_memory) return error.InvalidDataDir;

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
        try connection.configureDatabase(&writer_conn, true);

        // Create reader pool (one per CPU core)
        const configured_reader_pool_size = if (options.reader_pool_size == 0)
            try std.Thread.getCpuCount()
        else
            options.reader_pool_size;
        const num_readers = @max(configured_reader_pool_size, 1);
        const reader_pool = try allocator.alloc(ReaderNode, num_readers);
        errdefer allocator.free(reader_pool);

        var initialized_readers: usize = 0;
        errdefer {
            for (reader_pool[0..initialized_readers]) |*node| {
                node.stmt_cache.deinit(allocator);
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
            try connection.configureDatabase(&node.conn, false);
            node.stmt_cache.init(allocator, performance_config.statement_cache_size);
            node.mutex = .{};
            initialized_readers += 1;
        }

        const change_buffer = try ChangeBuffer.init(allocator);
        errdefer {
            var cb = change_buffer;
            cb.deinit();
        }

        self.* = .{
            .allocator = allocator,
            .db_path = db_path,
            ._writer_conn = writer_conn,
            // SAFETY: Initialized below via .writer_stmt_cache.init().
            .writer_stmt_cache = undefined,
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
            .schema_manager = sm,
            // SAFETY: Initialized below
            .metadata_cache = undefined,
            .flush_cond = .{},
            .write_mutex = .{},
            .pending_writes_count = std.atomic.Value(usize).init(0),
            .manual_transaction_active = std.atomic.Value(bool).init(false),
            .migration_active = std.atomic.Value(bool).init(false),
            .reconnection_config = .{},
            .write_cond = .{},
            .write_thread_ready = std.atomic.Value(bool).init(false),
            .change_buffer = change_buffer,
            .event_loop_notifier = event_loop_notifier,
            .notifier_ctx = notifier_ctx,
            .write_thread = null,
            .state = std.atomic.Value(StorageEngine.State).init(.setup),
        };

        self.writer_stmt_cache.init(allocator, self.performance_config.statement_cache_size);
        errdefer self.writer_stmt_cache.deinit(allocator);

        try self.metadata_cache.init(allocator, .{});
        errdefer self.metadata_cache.deinit();

        try self.node_pool.init(memory_strategy.generalAllocator(), 1024, null, null);
        errdefer self.node_pool.deinit();

        try self.write_queue.init(allocator, &self.node_pool);
        errdefer self.write_queue.deinit();
    }

    pub fn deinit(self: *StorageEngine) void {
        const old_state = self.state.swap(.shutdown, .acq_rel);
        if (old_state == .shutdown) {
            return;
        }

        const gpa = self.allocator;

        // 1. Signal shutdown to the thread only if it was running
        if (old_state == .running) {
            self.shutdown_requested.store(true, .release);
            self.write_cond.signal();

            // 2. Wait for the thread to exit cleanly
            if (self.write_thread) |thread| {
                thread.join();
                self.write_thread = null;
            }
        }

        // 3. Deinit cache
        self.metadata_cache.deinit();
        self.writer_stmt_cache.deinit(self.allocator);
        self._writer_conn.deinit();

        // 4. Clean up readers
        for (self.reader_pool) |*node| {
            node.stmt_cache.deinit(self.allocator);
            node.conn.deinit();
        }
        gpa.free(self.reader_pool);
        gpa.free(self.db_path);

        // 5. Clean up the queues and objects
        self.write_queue.deinit();
        self.node_pool.deinit();

        // 6. Clean up change buffer
        self.change_buffer.deinit();
    }

    /// Initialize a StorageLayer interface for the CheckpointManager in-place
    pub fn initStorageLayer(self: *StorageEngine, layer: *@import("checkpoint_manager.zig").CheckpointManager.StorageLayer) !void {
        const checkpoint_manager_mod = @import("checkpoint_manager.zig");
        layer.* = try checkpoint_manager_mod.CheckpointManager.StorageLayer.init(self.allocator, self.db_path);

        // Store a reference to self for checkpoint execution
        layer.storage_engine = self;
    }

    /// Returns statistics about the checkpoint operation
    pub fn executeCheckpoint(self: *StorageEngine, mode: CheckpointMode) !CheckpointStats {
        try self.ensureRunning();
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
        return connection.internalExecuteCheckpoint(&self._writer_conn, self.allocator, self.db_path, self.options.in_memory, mode);
    }

    /// Get the current WAL file size in bytes
    pub fn getWalSize(self: *StorageEngine) !usize {
        return connection.getWalSize(self.allocator, self.db_path, self.options.in_memory);
    }

    pub fn beginTransaction(self: *StorageEngine) !void {
        try self.ensureRunning();
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
        try self.ensureRunning();
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
        try self.ensureRunning();
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

    pub fn isTransactionActive(self: *StorageEngine) bool {
        return self.manual_transaction_active.load(.acquire);
    }

    /// Classify SQLite error into our specific error types
    /// Log database error with full details
    /// Attempt to reconnect to database with exponential backoff
    fn reconnectWithBackoff(self: *StorageEngine) !void {
        return connection.reconnectWithBackoff(
            self.db_path,
            self.options.in_memory,
            &self._writer_conn,
            self.reader_pool,
            self.reconnection_config,
        );
    }

    fn attemptReconnect(self: *StorageEngine) !void {
        return connection.attemptReconnect(
            self.db_path,
            self.options.in_memory,
            &self._writer_conn,
            self.reader_pool,
        );
    }

    pub fn ensureRunning(self: *StorageEngine) !void {
        if (self.state.load(.acquire) != .running) {
            return error.InvalidState;
        }
    }

    /// Execute setup SQL (DDL/Migrations) before the engine starts.
    /// This method is only allowed when the engine is in the 'setup' state.
    pub fn execSetupSQL(self: *StorageEngine, sql_query: []const u8) !void {
        if (self.state.load(.acquire) != .setup) {
            std.log.err("execSetupSQL called outside of setup phase", .{});
            return error.InvalidState;
        }
        try self._writer_conn.execMulti(sql_query, .{});
        // Reset caches since DDL may have modified table structures, invalidating
        // any cached prepared statements and metadata.
        self.writer_stmt_cache.deinit(self.allocator);
        self.writer_stmt_cache.init(self.allocator, self.performance_config.statement_cache_size);
        self.metadata_cache.deinit();
        try self.metadata_cache.init(self.allocator, .{});
        // Increment write_seq to notify readers that the state has changed (DDL/setup)
        _ = self.write_seq.fetchAdd(1, .release);
    }

    /// Transitions the engine from 'setup' to 'running' and spawns the write thread.
    /// Once called, the schema is locked and only data operations are permitted.
    pub fn start(self: *StorageEngine) !void {
        if (self.state.load(.acquire) != .setup) {
            return error.InvalidState;
        }

        // Spawn the write thread
        self.write_thread = try std.Thread.spawn(.{}, writer.writeThreadLoop, .{self});
        self.state.store(.running, .release);

        // Wait deterministically for the write thread to signal readiness
        {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            while (!self.write_thread_ready.load(.acquire)) {
                self.write_cond.wait(&self.write_mutex);
            }
        }

        std.log.info("Storage engine started (Runtime Phase)", .{});
    }

    /// Return the raw writer connection for setup-time tools (migrations).
    /// Only allowed during the 'setup' phase.
    pub fn getSetupConn(self: *StorageEngine) !*sqlite.Db {
        if (self.state.load(.acquire) != .setup) {
            return error.InvalidState;
        }
        return &self._writer_conn;
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

    fn getCacheKey(self: *const StorageEngine, table: []const u8, namespace: []const u8, id: []const u8) ![]u8 {
        return reader.getCacheKey(self.allocator, table, namespace, id);
    }

    /// Converts a msgpack.Payload to a TypedValue based on the schema's FieldType.
    /// Strings and blobs (JSON arrays) are duplicated and owned by the TypedValue.

    // ─── Storage methods ──────────────────────────────────────────────────

    /// INSERT OR REPLACE a document into a table.
    pub fn insertOrReplace(
        self: *StorageEngine,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
        columns: []const ColumnValue,
    ) !void {
        try self.ensureRunning();
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        const table_metadata = self.schema_manager.getTable(table) orelse return error.UnknownTable;

        const sql_string = try sql.buildInsertOrReplaceSql(self.allocator, table_metadata, columns);
        errdefer self.allocator.free(sql_string);

        const values = try self.allocator.alloc(TypedValue, columns.len);
        var initialized_count: usize = 0;
        errdefer {
            for (values[0..initialized_count]) |v| v.deinit(self.allocator);
            self.allocator.free(values);
        }
        for (columns, 0..) |col, i| {
            values[i] = try col.value.clone(self.allocator);
            initialized_count += 1;
        }

        const now = std.time.timestamp();
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const ns_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_owned);
        const table_owned = try self.allocator.dupe(u8, table_metadata.table.name);
        errdefer self.allocator.free(table_owned);

        const op = WriteOp{
            .upsert = .{
                .table = table_owned,
                .id = id_owned,
                .namespace = ns_owned,
                .sql = sql_string,
                .values = values,
                .timestamp = now,
                .completion_signal = null,
            },
        };

        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    /// Select a single document by ID.
    pub fn selectDocument(
        self: *StorageEngine,
        allocator: Allocator,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
    ) !ManagedResult {
        try self.ensureRunning();
        try self.schema_manager.validateTable(table);

        const cache_key = try reader.getCacheKey(allocator, table, namespace, id);
        defer allocator.free(cache_key);

        if (self.metadata_cache.get(cache_key)) |handle| {
            const typed_row_ptr = handle.data();
            const slice = @as([*]types.TypedRow, @ptrCast(typed_row_ptr))[0..1];
            return ManagedResult{
                .rows = slice,
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

        const table_metadata = self.schema_manager.getTable(table).?;
        const sql_query = try reader.buildSelectDocumentSql(allocator, table_metadata);
        defer allocator.free(sql_query);

        // Snapshot write_seq before the DB read.
        const seq_before = self.write_seq.load(.acquire);

        var mstmt = try node.stmt_cache.acquire(self.allocator, &node.conn, sql_query);
        defer mstmt.release();
        const stmt = mstmt.stmt;
        const result = try reader.execSelectDocumentTyped(allocator, &node.conn, stmt, id, namespace, table_metadata);
        if (result) |row| {
            if (self.write_seq.load(.acquire) == seq_before) {
                // Populate cache with a persistent copy (cloned into GPA)
                const cache_row = try row.clone(self.allocator);
                errdefer cache_row.deinit(self.allocator);
                try self.metadata_cache.update(cache_key, cache_row);
            }
            const items = try allocator.alloc(types.TypedRow, 1);
            items[0] = row;
            return ManagedResult{ .rows = items, .allocator = allocator };
        }
        return ManagedResult{ .rows = &[_]types.TypedRow{}, .allocator = allocator };
    }

    /// SELECT for a query filter.
    pub fn selectQuery(
        self: *StorageEngine,
        allocator: Allocator,
        table: []const u8,
        namespace: []const u8,
        filter: query_parser.QueryFilter,
    ) !ManagedResult {
        try self.ensureRunning();
        try self.schema_manager.validateTable(table);

        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const node = &self.reader_pool[reader_idx];
        node.mutex.lock();
        defer node.mutex.unlock();

        const table_metadata = self.schema_manager.getTable(table).?;
        const query_res = try reader.buildSelectQuery(allocator, table_metadata, namespace, filter);
        defer query_res.deinit(allocator);

        const sort_field_index = filter.order_by.field_index;
        var mstmt = try node.stmt_cache.acquire(self.allocator, &node.conn, query_res.sql);
        defer mstmt.release();
        const stmt = mstmt.stmt;
        const exec_res = try reader.execQueryTyped(
            allocator,
            &node.conn,
            stmt,
            query_res.values,
            table_metadata,
            filter.limit,
            sort_field_index,
        );

        return ManagedResult{
            .rows = exec_res.rows,
            .next_cursor = exec_res.next_cursor,
            .handle = null,
            .allocator = allocator,
        };
    }

    /// DELETE a document from a table.
    pub fn deleteDocument(
        self: *StorageEngine,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
    ) !void {
        try self.ensureRunning();
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        const table_metadata = self.schema_manager.getTable(table) orelse return error.UnknownTable;

        const sql_string = try sql.buildDeleteDocumentSql(self.allocator, table_metadata);
        errdefer self.allocator.free(sql_string);

        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const ns_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_owned);
        const table_owned = try self.allocator.dupe(u8, table_metadata.table.name);
        errdefer self.allocator.free(table_owned);

        const op = WriteOp{
            .delete = .{
                .table = table_owned,
                .id = id_owned,
                .namespace = ns_owned,
                .sql = sql_string,
                .completion_signal = null,
            },
        };

        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    fn writeThreadLoop(self: *StorageEngine) void {
        writer.writeThreadLoop(self);
    }
};
