const std = @import("std");
pub const std_options = struct {
    pub const log_level = .debug;
};
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const reader = @import("storage_engine/reader.zig");
const storage_writer = @import("storage_engine/writer.zig");
const Writer = storage_writer.Writer;
const connection = @import("storage_engine/connection.zig");
const schema = @import("schema.zig");
const Schema = schema.Schema;
const query_ast = @import("query_ast.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const storage_values = @import("storage_engine/values.zig");
const value_codec = @import("storage_engine/value_codec.zig");
const storage_errors = @import("storage_engine/errors.zig");
const write_queue = @import("storage_engine/write_queue.zig");
const sql = @import("storage_engine/sql.zig");
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const SessionResolutionBuffer = @import("session_resolution_buffer.zig").SessionResolutionBuffer;
const authorization = @import("authorization.zig");

pub const StorageError = storage_errors.StorageError;
pub const ColumnValue = storage_values.ColumnValue;
pub const DocId = storage_values.DocId;
pub const ManagedResult = storage_values.ManagedResult;
pub const ScalarValue = storage_values.ScalarValue;
pub const TypedValue = storage_values.TypedValue;
pub const TypedRow = storage_values.TypedRow;
pub const TableMetadata = schema.Table;
pub const TypedCursor = storage_values.TypedCursor;
pub const CheckpointMode = write_queue.CheckpointMode;
pub const ReaderNode = connection.ReaderNode;
pub const CheckpointStats = write_queue.CheckpointStats;
pub const ReconnectionConfig = write_queue.ReconnectionConfig;
pub const WriteOp = write_queue.WriteOp;
pub const BatchEntry = write_queue.BatchEntry;
pub const WriteQueue = write_queue.WriteQueue;
const typed_cache_type = storage_values.typed_cache_type;
const namespace_cache_type = storage_values.namespace_cache_type;
const identity_cache_type = storage_values.identity_cache_type;
pub const typedValueFromPayload = value_codec.fromPayload;
pub const validateTypedValuePayload = value_codec.validateValue;
pub const writeTypedValueMsgPack = value_codec.writeMsgPack;

var unique_id_counter = std.atomic.Value(usize).init(0);

pub const StorageEngine = struct {
    pub const Options = struct {
        in_memory: bool = false,
        reader_pool_size: usize = 0,
    };

    pub const PerformanceConfig = @import("config_loader.zig").Config.PerformanceConfig;

    pub const State = enum(u8) { setup, running, shutdown };

    allocator: Allocator,
    reader_pool: []ReaderNode,
    state: std.atomic.Value(State),
    next_reader_idx: std.atomic.Value(usize),
    migration_active: std.atomic.Value(bool),
    reconnection_config: ReconnectionConfig,
    node_pool: MemoryStrategy.IndexPool(WriteQueue.Node),
    schema_manager: *const Schema,
    metadata_cache: typed_cache_type,
    namespace_cache: namespace_cache_type,
    identity_cache: identity_cache_type,
    options: Options,
    writer: Writer,

    pub fn init(
        self: *StorageEngine,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        data_dir: []const u8,
        sm: *const Schema,
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
        try sql.ensureNamespaceTable(&writer_conn);

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
        const session_resolution_buffer = try SessionResolutionBuffer.init(allocator);
        errdefer {
            var rb = session_resolution_buffer;
            rb.deinit();
        }

        self.* = .{
            .allocator = allocator,
            .reader_pool = reader_pool,
            .options = options,
            // SAFETY: Initialized below via .node_pool.init().
            .node_pool = undefined,
            .next_reader_idx = std.atomic.Value(usize).init(0),
            .schema_manager = sm,
            // SAFETY: Initialized below
            .metadata_cache = undefined,
            // SAFETY: Initialized below
            .namespace_cache = undefined,
            // SAFETY: Initialized below
            .identity_cache = undefined,
            .migration_active = std.atomic.Value(bool).init(false),
            .reconnection_config = .{},
            .writer = .{
                .allocator = allocator,
                .conn = writer_conn,
                // SAFETY: Initialized below
                .stmt_cache = undefined,
                .version = std.atomic.Value(u64).init(0),
                .work_cond = .{},
                .mutex = .{},
                .flush_cond = .{},
                .pending_count = std.atomic.Value(usize).init(0),
                .change_buffer = change_buffer,
                .session_resolution_buffer = session_resolution_buffer,
                .notifier_ptr = event_loop_notifier,
                .notifier_ctx = notifier_ctx,
                // SAFETY: Set after metadata_cache init below
                .metadata_cache = undefined,
                // SAFETY: Set after cache init below
                .namespace_cache = undefined,
                // SAFETY: Set after cache init below
                .identity_cache = undefined,
                .schema = sm,
                .shutdown_requested = std.atomic.Value(bool).init(false),
                .is_ready = std.atomic.Value(bool).init(false),
                // SAFETY: Initialized below via .write_queue.init().
                .queue = undefined,
                .performance_config = performance_config,
                .db_path = db_path,
                .in_memory = options.in_memory,
                .write_thread = null,
            },
            .state = std.atomic.Value(StorageEngine.State).init(.setup),
        };

        self.writer.stmt_cache.init(allocator, self.writer.performance_config.statement_cache_size);
        errdefer self.writer.stmt_cache.deinit(allocator);

        try self.metadata_cache.init(allocator, .{});
        errdefer self.metadata_cache.deinit();
        self.writer.metadata_cache = &self.metadata_cache;

        try self.namespace_cache.init(allocator, .{});
        errdefer self.namespace_cache.deinit();
        self.writer.namespace_cache = &self.namespace_cache;

        try self.identity_cache.init(allocator, .{});
        errdefer self.identity_cache.deinit();
        self.writer.identity_cache = &self.identity_cache;

        try self.node_pool.init(memory_strategy.generalAllocator(), 1024, null, null);
        errdefer self.node_pool.deinit();

        try self.writer.queue.init(allocator, &self.node_pool);
        errdefer self.writer.queue.deinit();
    }

    pub fn deinit(self: *StorageEngine) void {
        const old_state = self.state.swap(.shutdown, .acq_rel);
        if (old_state == .shutdown) {
            return;
        }

        const gpa = self.allocator;

        // 1. Signal shutdown to the thread only if it was running
        if (old_state == .running) {
            self.writer.stopThread();
        }

        // 3. Deinit cache
        self.metadata_cache.deinit();
        self.namespace_cache.deinit();
        self.identity_cache.deinit();

        // 4. Clean up readers
        for (self.reader_pool) |*node| {
            node.stmt_cache.deinit(self.allocator);
            node.conn.deinit();
        }
        gpa.free(self.reader_pool);

        // 5. Clean up the writer and queue
        self.writer.deinit();
        self.node_pool.deinit();
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

        try self.writer.enqueueOp(op);

        try signal.wait();
        return signal.result orelse error.InvalidOperation;
    }

    /// Get the current WAL file size in bytes
    pub fn getWalSize(self: *StorageEngine) !usize {
        return connection.getWalSize(self.allocator, self.writer.db_path, self.writer.in_memory);
    }

    /// Classify SQLite error into our specific error types
    /// Log database error with full details
    /// Attempt to reconnect to database with exponential backoff
    fn reconnectWithBackoff(self: *StorageEngine) !void {
        return connection.reconnectWithBackoff(
            self.writer.db_path,
            self.writer.in_memory,
            &self.writer.conn,
            self.reader_pool,
            self.reconnection_config,
        );
    }

    fn attemptReconnect(self: *StorageEngine) !void {
        return connection.attemptReconnect(
            self.writer.db_path,
            self.writer.in_memory,
            &self.writer.conn,
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
        try self.writer.conn.execMulti(sql_query, .{});
        // Reset caches since DDL may have modified table structures, invalidating
        // any cached prepared statements and metadata.
        self.writer.stmt_cache.deinit(self.allocator);
        self.writer.stmt_cache.init(self.allocator, self.writer.performance_config.statement_cache_size);
        self.metadata_cache.deinit();
        try self.metadata_cache.init(self.allocator, .{});
        self.namespace_cache.deinit();
        try self.namespace_cache.init(self.allocator, .{});
        self.identity_cache.deinit();
        try self.identity_cache.init(self.allocator, .{});
        // Increment write_seq to notify readers that the state has changed (DDL/setup)
        self.writer.bumpVersion();
    }

    /// Transitions the engine from 'setup' to 'running' and spawns the write thread.
    /// Once called, the schema is locked and only data operations are permitted.
    pub fn start(self: *StorageEngine) !void {
        if (self.state.load(.acquire) != .setup) {
            return error.InvalidState;
        }

        // Spawn the write thread
        try self.writer.spawnThread();
        self.state.store(.running, .release);

        // Wait deterministically for the write thread to signal readiness
        self.writer.waitUntilReady();

        std.log.info("Storage engine started (Runtime Phase)", .{});
    }

    /// Return the raw writer connection for setup-time tools (migrations).
    /// Only allowed during the 'setup' phase.
    pub fn getSetupConn(self: *StorageEngine) !*sqlite.Db {
        if (self.state.load(.acquire) != .setup) {
            return error.InvalidState;
        }
        return self.writer.setupConn();
    }

    pub fn changeBuffer(self: *StorageEngine) *ChangeBuffer {
        return &self.writer.change_buffer;
    }

    pub fn sessionResolutionBuffer(self: *StorageEngine) *SessionResolutionBuffer {
        return &self.writer.session_resolution_buffer;
    }

    pub fn cachedNamespaceId(self: *StorageEngine, namespace: []const u8) ?i64 {
        const handle = self.namespace_cache.get(storage_values.namespaceCacheKey(namespace)) catch return null;
        defer handle.release();
        return handle.data().namespace_id;
    }

    pub fn cachedUserId(self: *StorageEngine, identity_namespace_id: i64, external_user_id: []const u8) ?DocId {
        const key = storage_values.identityCacheKey(identity_namespace_id, external_user_id);
        const handle = self.identity_cache.get(key) catch return null;
        defer handle.release();
        return handle.data().user_doc_id;
    }

    pub fn enqueueSessionResolution(
        self: *StorageEngine,
        conn_id: u64,
        msg_id: u64,
        scope_seq: u64,
        namespace: []const u8,
        external_user_id: []const u8,
    ) !void {
        try self.ensureRunning();

        const namespace_owned = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(namespace_owned);
        const external_user_id_owned = try self.allocator.dupe(u8, external_user_id);
        errdefer self.allocator.free(external_user_id_owned);

        const op = WriteOp{
            .resolve_session = .{
                .conn_id = conn_id,
                .msg_id = msg_id,
                .scope_seq = scope_seq,
                .namespace = namespace_owned,
                .external_user_id = external_user_id_owned,
                .timestamp = std.time.timestamp(),
                .result_buffer = self.sessionResolutionBuffer(),
            },
        };

        try self.writer.enqueueOp(op);
    }

    pub fn flushPendingWrites(self: *StorageEngine) !void {
        self.writer.flushPendingWrites();
    }

    /// Converts a msgpack.Payload to a TypedValue based on the schema's FieldType.
    /// Strings and blobs (JSON arrays) are duplicated and owned by the TypedValue.

    // ─── Storage methods ──────────────────────────────────────────────────

    /// INSERT OR REPLACE a document into a table.
    pub fn insertOrReplace(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        owner_doc_id: DocId,
        columns: []const ColumnValue,
        auth_clause: ?@import("authorization.zig").InjectedClause,
    ) !void {
        try self.ensureRunning();
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        const table_metadata = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema.global_namespace_id;
        var queued = false;

        const sql_string = try sql.buildInsertOrReplaceSql(self.allocator, table_metadata, columns, auth_clause);
        errdefer if (!queued) self.allocator.free(sql_string);

        const values = try self.allocator.alloc(TypedValue, columns.len);
        var initialized_count: usize = 0;
        errdefer if (!queued) {
            for (values[0..initialized_count]) |v| v.deinit(self.allocator);
            self.allocator.free(values);
        };
        for (columns, 0..) |col, i| {
            values[i] = try col.value.clone(self.allocator);
            initialized_count += 1;
        }

        const auth_values = try authorization.cloneBindValues(self.allocator, auth_clause);
        errdefer if (!queued) authorization.deinitBindValues(self.allocator, auth_values);

        const op = WriteOp{
            .upsert = .{
                .table_index = table_index,
                .id = id,
                .namespace_id = effective_namespace_id,
                .owner_doc_id = owner_doc_id,
                .sql = sql_string,
                .values = values,
                .auth_values = auth_values,
                .timestamp = std.time.timestamp(),
                .completion_signal = null,
            },
        };

        try self.writer.enqueueOp(op);
        queued = true;
    }

    /// Atomically execute a batch of upsert/delete operations in a single transaction.
    /// Fire-and-forget: takes ownership of entries and returns immediately after enqueue.
    pub fn batchWrite(
        self: *StorageEngine,
        entries: []BatchEntry,
    ) !void {
        const op = WriteOp{
            .batch = .{
                .entries = entries,
                .completion_signal = null,
            },
        };
        var queued = false;
        errdefer if (!queued) op.deinit(self.allocator);

        try self.ensureRunning();
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;

        for (entries) |entry| {
            _ = self.schema_manager.getTableByIndex(entry.table_index) orelse return StorageError.UnknownTable;
        }

        try self.writer.enqueueOp(op);
        queued = true;
    }

    /// Select a single document by ID.
    pub fn selectDocument(
        self: *StorageEngine,
        allocator: Allocator,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        auth_clause: ?@import("authorization.zig").InjectedClause,
    ) !ManagedResult {
        try self.ensureRunning();
        const table_metadata = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema.global_namespace_id;

        const cache_key = reader.getCacheKey(table_metadata, namespace_id, id);

        if (self.metadata_cache.get(cache_key)) |handle| {
            const typed_row_ptr = handle.data();
            const slice = @as([*]TypedRow, @ptrCast(typed_row_ptr))[0..1];
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

        const sql_query = try sql.buildSelectDocumentSql(allocator, table_metadata, auth_clause);
        defer allocator.free(sql_query);

        // Snapshot write_seq before the DB read.
        const seq_before = self.writer.snapshotVersion();

        var mstmt = try node.stmt_cache.acquire(self.allocator, &node.conn, sql_query);
        defer mstmt.release();
        const stmt = mstmt.stmt;
        const result = try reader.execSelectDocumentTyped(allocator, &node.conn, stmt, id, effective_namespace_id, table_metadata, if (auth_clause) |c| c.bind_values else null);
        if (result) |row| {
            if (self.writer.snapshotVersion() == seq_before) {
                // Populate cache with a persistent copy (cloned into GPA)
                const cache_row = try row.clone(self.allocator);
                errdefer cache_row.deinit(self.allocator);
                try self.metadata_cache.update(cache_key, cache_row);
            }
            const items = try allocator.alloc(TypedRow, 1);
            items[0] = row;
            return ManagedResult{ .rows = items, .allocator = allocator };
        }
        return ManagedResult{ .rows = &[_]TypedRow{}, .allocator = allocator };
    }

    /// SELECT for a query filter.
    pub fn selectQuery(
        self: *StorageEngine,
        allocator: Allocator,
        table_index: usize,
        namespace_id: i64,
        filter: query_ast.QueryFilter,
        auth_clause: ?@import("authorization.zig").InjectedClause,
    ) !struct { result: ManagedResult, next_cursor_str: ?[]const u8 } {
        try self.ensureRunning();
        const table_metadata = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema.global_namespace_id;

        const reader_idx = self.next_reader_idx.fetchAdd(1, .monotonic) % self.reader_pool.len;
        const node = &self.reader_pool[reader_idx];
        node.mutex.lock();
        defer node.mutex.unlock();

        const query_res = try reader.buildSelectQuery(allocator, table_metadata, effective_namespace_id, filter, auth_clause);
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

        return .{
            .result = ManagedResult{ .rows = exec_res.rows, .allocator = allocator },
            .next_cursor_str = exec_res.next_cursor_str,
        };
    }

    /// DELETE a document from a table.
    pub fn deleteDocument(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        auth_clause: ?@import("authorization.zig").InjectedClause,
    ) !void {
        try self.ensureRunning();
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
        const table_metadata = self.schema_manager.getTableByIndex(table_index) orelse return error.UnknownTable;
        const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema.global_namespace_id;
        var queued = false;

        const sql_string = try sql.buildDeleteDocumentSql(self.allocator, table_metadata, auth_clause);
        errdefer if (!queued) self.allocator.free(sql_string);

        const auth_values = try authorization.cloneBindValues(self.allocator, auth_clause);
        errdefer if (!queued) authorization.deinitBindValues(self.allocator, auth_values);

        const op = WriteOp{
            .delete = .{
                .table_index = table_index,
                .id = id,
                .namespace_id = effective_namespace_id,
                .sql = sql_string,
                .auth_values = auth_values,
                .completion_signal = null,
            },
        };

        try self.writer.enqueueOp(op);
        queued = true;
    }
};
