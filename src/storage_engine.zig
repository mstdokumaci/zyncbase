const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const msgpack = @import("msgpack_utils.zig");
const reader = @import("storage_engine/reader.zig");
const pipeline = @import("storage_engine/pipeline.zig");
const writer = @import("storage_engine/writer.zig");
const connection = @import("storage_engine/connection.zig");
const schema_parser = @import("schema_parser.zig");
const query_parser = @import("query_parser.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const types = @import("storage_engine/types.zig");

pub const StorageError = types.StorageError;
pub const ColumnValue = types.ColumnValue;
pub const ManagedPayload = types.ManagedPayload;
pub const TypedValue = types.TypedValue;
pub const CheckpointMode = types.CheckpointMode;
pub const ReaderNode = types.ReaderNode;
pub const CheckpointStats = types.CheckpointStats;
pub const ReconnectionConfig = types.ReconnectionConfig;
pub const WriteOp = types.WriteOp;
pub const WriteQueue = types.WriteQueue;
pub const metadata_cache_type = types.metadata_cache_type;
pub const ColumnContext = types.ColumnContext;

var unique_id_counter = std.atomic.Value(usize).init(0);

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
        try connection.configureDatabase(&writer_conn, true);

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
            try connection.configureDatabase(&node.conn, false);
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
        self.write_thread = try std.Thread.spawn(.{}, pipeline.writeThreadLoop, .{self});
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

        // 1.. Signal shutdown to the thread
        self.shutdown_requested.store(true, .release);
        self.write_cond.signal();

        // 2.. Wait for the thread to exit cleanly
        if (self.write_thread) |thread| {
            thread.join();
        }

        // 3.. Deinit cache
        self.metadata_cache.deinit();
        self.writer_conn.deinit();

        // 4.. Clean up readers
        for (self.reader_pool) |*node| {
            node.conn.deinit();
        }
        gpa.free(self.reader_pool);
        gpa.free(self.db_path);

        // 5.. Clean up the queues and objects
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
        return connection.internalExecuteCheckpoint(&self.writer_conn, self.allocator, self.db_path, self.options.in_memory, mode);
    }

    /// Get the current WAL file size in bytes
    pub fn getWalSize(self: *StorageEngine) !usize {
        return connection.getWalSize(self.allocator, self.db_path, self.options.in_memory);
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
    /// Log database error with full details
    /// Attempt to reconnect to database with exponential backoff
    fn reconnectWithBackoff(self: *StorageEngine) !void {
        return connection.reconnectWithBackoff(
            self.allocator,
            self.db_path,
            self.options.in_memory,
            &self.writer_conn,
            self.reader_pool,
            self.reconnection_config,
        );
    }

    fn attemptReconnect(self: *StorageEngine) !void {
        return connection.attemptReconnect(
            self.allocator,
            self.db_path,
            self.options.in_memory,
            &self.writer_conn,
            self.reader_pool,
        );
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

    // ─── Schema validation helpers (delegated) ────────────────────────────────

    fn findTable(self: *const StorageEngine, table_name: []const u8) ?schema_parser.TableMetadata {
        return reader.findTable(&self.schema_metadata, table_name);
    }

    fn validateTable(self: *const StorageEngine, table_name: []const u8) !void {
        return reader.validateTable(&self.schema_metadata, table_name);
    }

    fn validateField(self: *const StorageEngine, table_name: []const u8, field_name: []const u8) !void {
        return reader.validateField(&self.schema_metadata, table_name, field_name);
    }

    fn validateColumns(self: *const StorageEngine, table_name: []const u8, columns: []const ColumnValue) !void {
        return reader.validateColumns(&self.schema_metadata, table_name, columns);
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
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        const op = try writer.buildInsertOrReplaceOp(self.allocator, &self.schema_metadata, table, id, namespace, columns);
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
        const op = try writer.buildUpdateFieldOp(self.allocator, &self.schema_metadata, table, id, namespace, field, value);
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
    ) !ManagedPayload {
        try self.validateTable(table);

        const cache_key = try reader.getCacheKey(allocator, table, namespace, id);
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

        const table_metadata = self.findTable(table).?;
        const sql = try reader.buildSelectDocumentSql(allocator, table_metadata);
        defer allocator.free(sql);

        // Snapshot write_seq before the DB read.
        const seq_before = self.write_seq.load(.acquire);

        const payload = try reader.execSelectDocument(allocator, &node.conn, sql, id, namespace, table_metadata.table.*);
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

        const table_metadata = self.findTable(table).?;
        const field_ctx = table_metadata.getField(field);
        const sql = try reader.buildSelectFieldSql(allocator, table, field, field_ctx);
        defer allocator.free(sql);

        const payload = try reader.execSelectScalar(allocator, &node.conn, sql, id, namespace, field_ctx);
        return ManagedPayload{ .value = payload, .handle = null, .allocator = allocator };
    }

    /// SELECT * for all documents in a namespace.
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

        const table_metadata = self.findTable(table).?;
        const sql = try reader.buildSelectCollectionSql(allocator, table_metadata);
        defer allocator.free(sql);

        const payload = try reader.execSelectCollection(allocator, &node.conn, sql, namespace, table_metadata.table.*);
        return ManagedPayload{ .value = payload, .handle = null, .allocator = allocator };
    }

    /// SELECT for a query filter.
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
        const query_res = try reader.buildSelectQuery(allocator, table_metadata, namespace, filter);
        defer query_res.deinit(allocator);

        const payload = try reader.execQuery(allocator, &node.conn, query_res.sql, query_res.values, table_metadata.table.*);
        return ManagedPayload{ .value = payload, .handle = null, .allocator = allocator };
    }

    /// DELETE a document from a table.
    pub fn deleteDocument(
        self: *StorageEngine,
        table: []const u8,
        id: []const u8,
        namespace: []const u8,
    ) !void {
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        const op = try writer.buildDeleteDocumentOp(self.allocator, &self.schema_metadata, table, id, namespace);
        _ = self.pending_writes_count.fetchAdd(1, .release);
        try self.pushWrite(op);
    }

    fn writeThreadLoop(self: *StorageEngine) void {
        pipeline.writeThreadLoop(self);
    }
};
