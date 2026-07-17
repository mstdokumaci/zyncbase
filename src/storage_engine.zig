const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const write_worker_mod = @import("storage_engine/write_worker.zig");
const WriteWorker = write_worker_mod.WriteWorker;
const managedThread = @import("threading/managed_thread.zig").managedThread;
const connection = @import("storage_engine/connection.zig");
const schema_types = @import("schema/types.zig");
const schema_system = @import("schema/system.zig");
const Schema = schema_types.Schema;
const query_ast = @import("query/ast.zig");
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const typed_doc_id = @import("typed/doc_id.zig");
const typed = @import("typed/types.zig");
const storage_cache = @import("storage_engine/cache.zig");
const storage_errors = @import("storage_engine/errors.zig");
const pk_set_mod = @import("storage_engine/pk_set.zig");
const write_queue = @import("storage_engine/write_queue.zig");
const sql = @import("storage_engine/sql.zig");
const sql_build = @import("sql/build.zig");
const filter_sql = @import("storage_engine/filter_sql.zig");
const ChangeQueue = @import("subscription/change_queue.zig").ChangeQueue;
const SessionResolver = @import("authorization/session_resolver.zig").SessionResolver;
const read_buffer = @import("storage_engine/read_buffer.zig");
const read_worker_pool_mod = @import("storage_engine/read_worker_pool.zig");
const send_queue_type = @import("connection/send_queue.zig").send_queue;

pub const StorageError = storage_errors.StorageError;
pub const PkSet = pk_set_mod.PkSet;
pub const ColumnValue = sql.ColumnValue;
pub const CheckpointMode = write_queue.CheckpointMode;
pub const ReaderNode = connection.ReaderNode;
const ReconnectionConfig = write_queue.ReconnectionConfig;
pub const WriteOp = write_queue.WriteOp;
pub const BatchEntry = write_queue.BatchEntry;
pub const CheckpointLatch = write_queue.CheckpointLatch;
pub const AckLatch = write_queue.AckLatch;
const CheckpointStats = write_queue.CheckpointStats;
pub const write_queue_type = write_queue.write_queue_type;
pub const ReadRequest = read_buffer.ReadRequest;
pub const ReadResponse = read_buffer.ReadResponse;
pub const ReadKind = read_buffer.ReadKind;
const DocId = typed_doc_id.DocId;
const Value = typed.Value;
const metadata_cache_type = storage_cache.metadata_cache_type;
const namespace_cache_type = storage_cache.namespace_cache_type;
const identity_cache_type = storage_cache.identity_cache_type;

var unique_id_counter = std.atomic.Value(usize).init(0);

pub const StorageEngine = struct {
    pub const Options = struct {
        in_memory: bool = false,
        reader_pool_size: usize = 0,
    };

    pub const PerformanceConfig = @import("config_loader.zig").Config.PerformanceConfig;

    pub const State = enum(u8) { setup, running, shutdown };

    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    reader_nodes: []ReaderNode,
    read_request_queue: read_buffer.read_request_queue,
    read_worker_pool: ?read_worker_pool_mod.ReadWorkerPool,

    state: std.atomic.Value(State),
    next_reader_idx: std.atomic.Value(usize),
    migration_active: std.atomic.Value(bool),
    reconnection_config: ReconnectionConfig,
    node_pool: MemoryStrategy.IndexPool(write_queue_type.Node),
    schema: *const Schema,
    metadata_cache: metadata_cache_type,
    namespace_cache: namespace_cache_type,
    identity_cache: identity_cache_type,
    options: Options,
    write_worker: WriteWorker,
    pk_sets: []PkSet,

    pub fn init(
        self: *StorageEngine,
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        data_dir: []const u8,
        schema: *const Schema,
        performance_config: PerformanceConfig,
        options: Options,
        event_loop_notifier: ?*const fn (ctx: ?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) !void {
        if (data_dir.len == 0 and !options.in_memory) return error.InvalidDataDir;

        const db_path: [:0]const u8 = try resolveDbPath(allocator, data_dir, options.in_memory);
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

        // Create reader pool
        if (options.reader_pool_size == 0) {
            return error.InvalidReaderPoolSize;
        }
        const reader_nodes = try createReaderPool(allocator, db_path, options, performance_config);
        errdefer destroyReaderPool(allocator, reader_nodes);

        self.* = .{
            .allocator = allocator,
            .memory_strategy = memory_strategy,
            .reader_nodes = reader_nodes,
            .read_request_queue = read_buffer.read_request_queue.init(allocator),
            .read_worker_pool = null,
            .options = options,
            // SAFETY: Initialized below via .node_pool.init().
            .node_pool = undefined,
            .next_reader_idx = std.atomic.Value(usize).init(0),
            .schema = schema,
            // SAFETY: Initialized below
            .metadata_cache = undefined,
            // SAFETY: Initialized below
            .namespace_cache = undefined,
            // SAFETY: Initialized below
            .identity_cache = undefined,
            .migration_active = std.atomic.Value(bool).init(false),
            .reconnection_config = .{},
            .write_worker = .{
                .allocator = allocator,
                .memory_strategy = memory_strategy,
                .conn = writer_conn,
                // SAFETY: Initialized below
                .stmt_cache = undefined,
                .version = std.atomic.Value(u64).init(0),
                .thread = managedThread(WriteWorker).init(),
                .flush_wg = .{},
                .change_queue = null,
                .session_resolver = null,
                .send_queue = null,
                .notifier = .{ .callback = event_loop_notifier, .ctx = notifier_ctx },
                // SAFETY: Set after metadata_cache init below
                .metadata_cache = undefined,
                // SAFETY: Set after cache init below
                .namespace_cache = undefined,
                // SAFETY: Set after cache init below
                .identity_cache = undefined,
                // SAFETY: Set after pk_sets init below
                .pk_sets = undefined,
                .schema = schema,
                .is_healthy = std.atomic.Value(bool).init(true),
                // SAFETY: Initialized below via .write_queue.init().
                .queue = undefined,
                .performance_config = performance_config,
                .db_path = db_path,
                .in_memory = options.in_memory,
                .json_buf = sql.JsonBuf.init(allocator),
            },
            .state = std.atomic.Value(StorageEngine.State).init(.setup),
            // SAFETY: Initialized below
            .pk_sets = undefined,
        };
        errdefer self.read_request_queue.deinit();

        self.write_worker.stmt_cache.init(allocator, self.write_worker.performance_config.statement_cache_size);
        errdefer self.write_worker.stmt_cache.deinit(allocator);

        try self.metadata_cache.init(allocator, .{});
        errdefer self.metadata_cache.deinit();
        self.write_worker.metadata_cache = &self.metadata_cache;

        try self.namespace_cache.init(allocator, .{});
        errdefer self.namespace_cache.deinit();
        self.write_worker.namespace_cache = &self.namespace_cache;

        try self.identity_cache.init(allocator, .{});
        errdefer self.identity_cache.deinit();
        self.write_worker.identity_cache = &self.identity_cache;

        try self.node_pool.init(memory_strategy.generalAllocator(), 1024, null, null);
        errdefer self.node_pool.deinit();

        self.write_worker.queue = try write_queue_type.init(&self.node_pool);
        errdefer self.write_worker.queue.deinit();

        const num_tables = schema.tables.len;
        self.pk_sets = try allocator.alloc(PkSet, num_tables);
        errdefer allocator.free(self.pk_sets);
        for (self.pk_sets) |*pk_set| {
            pk_set.* = PkSet.empty;
        }

        self.write_worker.pk_sets = self.pk_sets;
    }

    fn resolveDbPath(allocator: Allocator, data_dir: []const u8, in_memory: bool) ![:0]const u8 {
        if (in_memory) {
            // Use shared-cache in-memory database with a unique name to avoid crosstalk
            // file:zync_mem_{id}?mode=memory&cache=shared
            const id = unique_id_counter.fetchAdd(1, .seq_cst);
            const ts = std.time.nanoTimestamp();
            return try std.fmt.allocPrintSentinel(allocator, "file:zync_mem_{d}_{d}?mode=memory&cache=shared", .{ ts, id }, 0);
        }
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
        return try std.fmt.allocPrintSentinel(allocator, "{s}/zyncbase.db", .{data_dir}, 0);
    }

    fn createReaderPool(
        allocator: Allocator,
        db_path: [:0]const u8,
        options: Options,
        performance_config: PerformanceConfig,
    ) ![]ReaderNode {
        const num_readers = options.reader_pool_size;
        const reader_nodes = try allocator.alloc(ReaderNode, num_readers);
        var initialized: usize = 0;
        errdefer {
            for (reader_nodes[0..initialized]) |*node| {
                node.stmt_cache.deinit(allocator);
                node.conn.deinit();
            }
            allocator.free(reader_nodes);
        }

        for (reader_nodes) |*node| {
            node.conn = try sqlite.Db.init(.{
                .mode = sqlite.Db.Mode{ .File = db_path },
                .open_flags = .{
                    .write = false,
                },
                .shared_cache = options.in_memory,
            });
            errdefer node.conn.deinit();
            try connection.configureDatabase(&node.conn, false);
            node.stmt_cache.init(allocator, performance_config.statement_cache_size);
            node.mutex = .{};
            initialized += 1;
        }

        return reader_nodes;
    }

    fn destroyReaderPool(allocator: Allocator, reader_nodes: []ReaderNode) void {
        for (reader_nodes) |*node| {
            node.stmt_cache.deinit(allocator);
            node.conn.deinit();
        }
        allocator.free(reader_nodes);
    }

    pub fn deinit(self: *StorageEngine) void {
        const old_state = self.state.swap(.shutdown, .acq_rel);
        if (old_state == .shutdown) {
            return;
        }

        const gpa = self.allocator;

        // 1. Stop reader pool
        if (self.read_worker_pool) |*pool| {
            pool.stop();
        }

        // 2. Stop writer thread
        self.write_worker.stop();

        // 3. Deinit reader pool
        if (self.read_worker_pool) |*pool| {
            pool.deinit();
        }

        // 4. Deinit queues
        self.read_request_queue.deinit();

        // 5. Deinit cache
        self.metadata_cache.deinit();
        self.namespace_cache.deinit();
        self.identity_cache.deinit();

        // 6. Deinit pk_sets
        for (self.pk_sets) |*pk_set| {
            pk_set.deinit(gpa);
        }
        gpa.free(self.pk_sets);

        // 7. Clean up readers
        for (self.reader_nodes) |*node| {
            node.stmt_cache.deinit(self.allocator);
            node.conn.deinit();
        }
        gpa.free(self.reader_nodes);

        // 8. Clean up the writer and queue
        self.write_worker.deinit();
        self.node_pool.deinit();
    }

    /// Returns statistics about the checkpoint operation
    pub fn executeCheckpoint(self: *StorageEngine, mode: CheckpointMode) !CheckpointStats {
        try self.ensureRunning();
        var latch = CheckpointLatch{};
        const op = WriteOp{
            .checkpoint = .{
                .mode = mode,
                .latch = &latch,
            },
        };

        try self.write_worker.enqueueOp(op);

        return try latch.wait();
    }

    /// Get the current WAL file size in bytes
    pub fn getWalSize(self: *StorageEngine) !usize {
        return connection.getWalSize(self.allocator, self.write_worker.db_path, self.write_worker.in_memory);
    }

    /// Classify SQLite error into our specific error types
    /// Log database error with full details
    /// Attempt to reconnect to database with exponential backoff
    fn reconnectWithBackoff(self: *StorageEngine) !void {
        return connection.reconnectWithBackoff(
            self.write_worker.db_path,
            self.write_worker.in_memory,
            &self.write_worker.conn,
            self.reader_nodes,
            self.reconnection_config,
        );
    }

    fn attemptReconnect(self: *StorageEngine) !void {
        return connection.attemptReconnect(
            self.write_worker.db_path,
            self.write_worker.in_memory,
            &self.write_worker.conn,
            self.reader_nodes,
        );
    }

    pub fn ensureRunning(self: *StorageEngine) !void {
        if (self.state.load(.acquire) != .running) {
            return error.InvalidState;
        }
    }

    pub fn isHealthy(self: *const StorageEngine) bool {
        return self.state.load(.acquire) == .running and self.write_worker.isHealthy();
    }

    pub fn ensureHealthy(self: *const StorageEngine) !void {
        if (!self.isHealthy()) {
            return StorageError.EngineUnhealthy;
        }
    }

    pub fn ensureMutationAllowed(self: *StorageEngine) !void {
        try self.ensureRunning();
        try self.ensureHealthy();
        if (self.migration_active.load(.acquire)) return StorageError.MigrationInProgress;
    }

    pub fn documentExists(self: *StorageEngine, table_index: usize, id: DocId) bool {
        if (table_index >= self.pk_sets.len) return false;
        return self.pk_sets[table_index].contains(id);
    }

    /// Execute setup SQL (DDL/Migrations) before the engine starts.
    /// This method is only allowed when the engine is in the 'setup' state.
    pub fn execSetupSQL(self: *StorageEngine, sql_query: []const u8) !void {
        if (self.state.load(.acquire) != .setup) {
            std.log.err("execSetupSQL called outside of setup phase", .{});
            return error.InvalidState;
        }
        try self.write_worker.conn.execMulti(sql_query, .{});
        // Reset caches since DDL may have modified table structures, invalidating
        // any cached prepared statements and metadata.
        self.write_worker.stmt_cache.deinit(self.allocator);
        self.write_worker.stmt_cache.init(self.allocator, self.write_worker.performance_config.statement_cache_size);
        self.metadata_cache.deinit();
        try self.metadata_cache.init(self.allocator, .{});
        self.namespace_cache.deinit();
        try self.namespace_cache.init(self.allocator, .{});
        self.identity_cache.deinit();
        try self.identity_cache.init(self.allocator, .{});
        // Increment write_seq to notify readers that the state has changed (DDL/setup)
        self.write_worker.bumpVersion();
    }

    /// Transitions the engine from 'setup' to 'running' and spawns the write thread.
    /// Once called, the schema is locked and only data operations are permitted.
    pub fn start(
        self: *StorageEngine,
        send_queue: *send_queue_type,
        change_queue: ?*ChangeQueue,
        session_resolver: ?*SessionResolver,
    ) !void {
        if (self.state.load(.acquire) != .setup) {
            return error.InvalidState;
        }

        for (self.schema.tables, 0..) |table, table_index| {
            const sql_str = try sql_build.buildSelectAllIdsSql(self.allocator, table.name_quoted);
            defer self.allocator.free(sql_str);

            var mstmt = try self.write_worker.stmt_cache.acquire(self.allocator, &self.write_worker.conn, sql_str);
            defer mstmt.release();

            while (true) {
                const rc = sqlite.c.sqlite3_step(mstmt.stmt);
                if (rc == sqlite.c.SQLITE_DONE) break;
                if (rc != sqlite.c.SQLITE_ROW) return storage_errors.classifyStepError(&self.write_worker.conn);

                const ptr = sqlite.c.sqlite3_column_blob(mstmt.stmt, 0);
                const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(mstmt.stmt, 0));
                const bytes = if (ptr != null) @as([*]const u8, @ptrCast(ptr))[0..len] else &[_]u8{};
                const doc_id = try typed_doc_id.fromBytes(bytes);

                self.pk_sets[table_index].insert(self.allocator, doc_id);
            }
        }

        // Spawn the write thread
        try self.write_worker.spawn();

        self.write_worker.send_queue = send_queue;
        self.write_worker.change_queue = change_queue;
        self.write_worker.session_resolver = session_resolver;

        // Initialize and start the reader thread pool
        var rp = try read_worker_pool_mod.ReadWorkerPool.init(
            self.allocator,
            self.memory_strategy,
            self.reader_nodes,
            &self.read_request_queue,
            send_queue,
            self.schema,
            &self.metadata_cache,
            &self.write_worker.version,
            self.write_worker.notifier.callback,
            self.write_worker.notifier.ctx,
        );
        errdefer {
            rp.stop();
            rp.deinit();
        }
        try rp.start();
        self.read_worker_pool = rp;

        self.state.store(.running, .release);

        std.log.info("Storage engine started (Runtime Phase)", .{});
    }

    pub fn enqueueRead(self: *StorageEngine, request: ReadRequest) !void {
        try self.read_request_queue.push(request);
    }

    pub fn stopReaderPool(self: *StorageEngine) void {
        if (self.read_worker_pool) |*pool| {
            pool.stop();
        }
    }

    /// Return the raw writer connection for setup-time tools (migrations).
    /// Only allowed during the 'setup' phase.
    pub fn getSetupConn(self: *StorageEngine) !*sqlite.Db {
        if (self.state.load(.acquire) != .setup) {
            return error.InvalidState;
        }
        return self.write_worker.setupConn();
    }

    pub fn cachedNamespaceId(self: *StorageEngine, namespace: []const u8) ?i64 {
        const handle = self.namespace_cache.get(storage_cache.namespaceCacheKey(namespace)) catch return null;
        defer handle.release();
        return handle.data().namespace_id;
    }

    pub fn cachedUserId(self: *StorageEngine, identity_namespace_id: i64, external_user_id: []const u8) ?DocId {
        const key = storage_cache.identityCacheKey(identity_namespace_id, external_user_id);
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
        is_presence: bool,
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
                .is_presence = is_presence,
            },
        };

        try self.write_worker.enqueueOp(op);
    }

    pub fn flushPendingWrites(self: *StorageEngine) !void {
        self.write_worker.flushPendingWrites();
    }

    // ─── Storage methods ──────────────────────────────────────────────────

    const WriteResources = struct {
        table_metadata: *const schema_types.Table,
        effective_namespace_id: i64,
        rendered_guard: ?filter_sql.RenderedPredicate,

        fn deinit(self: *WriteResources, allocator: Allocator) void {
            if (self.rendered_guard) |*rendered| rendered.deinit(allocator);
        }

        fn guardSql(self: *const WriteResources) ?[]const u8 {
            if (self.rendered_guard) |*rendered| return rendered.sqlSlice();
            return null;
        }

        fn takeGuardValues(self: *WriteResources) ?[]Value {
            if (self.rendered_guard) |*rendered| return rendered.takeValues();
            return null;
        }
    };

    fn prepareWriteResources(
        self: *StorageEngine,
        table_index: usize,
        namespace_id: i64,
        guard_predicate: ?*const query_ast.FilterPredicate,
    ) !WriteResources {
        const table_metadata = self.schema.tableByIndex(table_index) orelse return error.UnknownTable;
        const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema_system.global_namespace_id;
        const rendered_guard = try filter_sql.renderAndClause(self.allocator, table_metadata, guard_predicate);
        return .{
            .table_metadata = table_metadata,
            .effective_namespace_id = effective_namespace_id,
            .rendered_guard = rendered_guard,
        };
    }

    /// INSERT OR REPLACE a document into a table.
    pub fn upsertDocument(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        owner_doc_id: DocId,
        columns: []const ColumnValue,
        guard_predicate: ?*const query_ast.FilterPredicate,
        conn_id: ?u64,
        write_id: ?[16]u8,
    ) !void {
        try self.ensureMutationAllowed();
        var res = try self.prepareWriteResources(table_index, namespace_id, guard_predicate);
        defer res.deinit(self.allocator);
        var queued = false;

        const sql_string = try sql.buildUpsertDocumentSql(self.allocator, res.table_metadata, columns, res.guardSql());
        errdefer if (!queued) self.allocator.free(sql_string);

        const guard_values = res.takeGuardValues();
        errdefer if (!queued) {
            if (guard_values) |values| typed.deinitValueSlice(self.allocator, values);
        };

        const values = try self.cloneColumnValues(columns);
        errdefer if (!queued) {
            for (values) |v| v.deinit(self.allocator);
            self.allocator.free(values);
        };

        const op = WriteOp{
            .upsert = .{
                .table_index = table_index,
                .id = id,
                .namespace_id = res.effective_namespace_id,
                .owner_doc_id = owner_doc_id,
                .sql = sql_string,
                .values = values,
                .guard_values = guard_values,
                .timestamp = std.time.timestamp(),
                .conn_id = conn_id,
                .write_id = write_id,
            },
        };

        try self.write_worker.enqueueOp(op);
        queued = true;
    }

    /// UPDATE an existing document in a table.
    pub fn updateDocument(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        columns: []const ColumnValue,
        guard_predicate: ?*const query_ast.FilterPredicate,
        conn_id: ?u64,
        write_id: ?[16]u8,
    ) !void {
        try self.ensureMutationAllowed();
        var res = try self.prepareWriteResources(table_index, namespace_id, guard_predicate);
        defer res.deinit(self.allocator);
        var queued = false;

        const sql_string = try sql.buildUpdateDocumentSql(self.allocator, res.table_metadata, columns, res.guardSql());
        errdefer if (!queued) self.allocator.free(sql_string);

        const guard_values = res.takeGuardValues();
        errdefer if (!queued) {
            if (guard_values) |values| typed.deinitValueSlice(self.allocator, values);
        };

        const values = try self.cloneColumnValues(columns);
        errdefer if (!queued) {
            for (values) |v| v.deinit(self.allocator);
            self.allocator.free(values);
        };

        const op = WriteOp{
            .update = .{
                .table_index = table_index,
                .id = id,
                .namespace_id = res.effective_namespace_id,
                .sql = sql_string,
                .values = values,
                .guard_values = guard_values,
                .timestamp = std.time.timestamp(),
                .conn_id = conn_id,
                .write_id = write_id,
            },
        };

        try self.write_worker.enqueueOp(op);
        queued = true;
    }

    /// Atomically execute a batch of upsert/delete operations in a single transaction.
    /// Fire-and-forget: takes ownership of entries and returns immediately after enqueue.
    pub fn batchWrite(
        self: *StorageEngine,
        entries: []BatchEntry,
        conn_id: ?u64,
        write_id: ?[16]u8,
    ) !void {
        var entries_owned = true;
        errdefer if (entries_owned) {
            for (entries) |entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
        };

        try self.ensureMutationAllowed();

        for (entries) |entry| {
            _ = self.schema.tableByIndex(entry.table_index) orelse return StorageError.UnknownTable;
        }

        const op = WriteOp{
            .batch = .{
                .entries = entries,
                .latch = null,
                .conn_id = conn_id,
                .write_id = write_id,
            },
        };
        var queued = false;
        errdefer if (!queued) op.deinit(self.allocator);
        entries_owned = false;

        try self.write_worker.enqueueOp(op);
        queued = true;
    }

    pub fn prepareBatchUpsert(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        owner_doc_id: DocId,
        columns: []const ColumnValue,
        guard_predicate: ?*const query_ast.FilterPredicate,
        timestamp: i64,
    ) !BatchEntry {
        var res = try self.prepareWriteResources(table_index, namespace_id, guard_predicate);
        defer res.deinit(self.allocator);

        const sql_string = try sql.buildUpsertDocumentSql(self.allocator, res.table_metadata, columns, res.guardSql());
        errdefer self.allocator.free(sql_string);

        const guard_values = res.takeGuardValues();
        errdefer if (guard_values) |values| typed.deinitValueSlice(self.allocator, values);

        const values = try self.cloneColumnValues(columns);
        errdefer {
            for (values) |value| value.deinit(self.allocator);
            self.allocator.free(values);
        }

        return .{
            .kind = .upsert,
            .table_index = table_index,
            .id = id,
            .namespace_id = res.effective_namespace_id,
            .owner_doc_id = owner_doc_id,
            .sql = sql_string,
            .values = values,
            .guard_values = guard_values,
            .timestamp = timestamp,
        };
    }

    pub fn prepareBatchUpdate(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        columns: []const ColumnValue,
        guard_predicate: ?*const query_ast.FilterPredicate,
        timestamp: i64,
    ) !BatchEntry {
        var res = try self.prepareWriteResources(table_index, namespace_id, guard_predicate);
        defer res.deinit(self.allocator);

        const sql_string = try sql.buildUpdateDocumentSql(self.allocator, res.table_metadata, columns, res.guardSql());
        errdefer self.allocator.free(sql_string);

        const guard_values = res.takeGuardValues();
        errdefer if (guard_values) |values| typed.deinitValueSlice(self.allocator, values);

        const values = try self.cloneColumnValues(columns);
        errdefer {
            for (values) |value| value.deinit(self.allocator);
            self.allocator.free(values);
        }

        return .{
            .kind = .update,
            .table_index = table_index,
            .id = id,
            .namespace_id = res.effective_namespace_id,
            .owner_doc_id = typed_doc_id.zero,
            .sql = sql_string,
            .values = values,
            .guard_values = guard_values,
            .timestamp = timestamp,
        };
    }

    pub fn prepareBatchDelete(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        owner_doc_id: DocId,
        guard_predicate: ?*const query_ast.FilterPredicate,
        timestamp: i64,
    ) !BatchEntry {
        var res = try self.prepareWriteResources(table_index, namespace_id, guard_predicate);
        defer res.deinit(self.allocator);

        const sql_string: []const u8 = blk: {
            const guard_sql = res.guardSql();
            break :blk if (guard_sql) |fragment|
                try std.mem.concat(self.allocator, u8, &.{
                    res.table_metadata.delete_document_sql_prefix,
                    fragment,
                    res.table_metadata.delete_document_sql_suffix,
                })
            else
                try std.mem.concat(self.allocator, u8, &.{
                    res.table_metadata.delete_document_sql_prefix,
                    res.table_metadata.delete_document_sql_suffix,
                });
        };
        errdefer self.allocator.free(sql_string);

        const guard_values = res.takeGuardValues();
        errdefer if (guard_values) |values| typed.deinitValueSlice(self.allocator, values);

        return .{
            .kind = .delete,
            .table_index = table_index,
            .id = id,
            .namespace_id = res.effective_namespace_id,
            .owner_doc_id = owner_doc_id,
            .sql = sql_string,
            .values = null,
            .guard_values = guard_values,
            .timestamp = timestamp,
        };
    }

    fn cloneColumnValues(self: *StorageEngine, columns: []const ColumnValue) ![]Value {
        const values = try self.allocator.alloc(Value, columns.len);
        var initialized_count: usize = 0;
        errdefer {
            for (values[0..initialized_count]) |value| value.deinit(self.allocator);
            self.allocator.free(values);
        }
        for (columns, 0..) |col, i| {
            values[i] = try col.value.clone(self.allocator);
            initialized_count += 1;
        }
        return values;
    }

    /// DELETE a document from a table.
    pub fn deleteDocument(
        self: *StorageEngine,
        table_index: usize,
        id: DocId,
        namespace_id: i64,
        guard_predicate: ?*const query_ast.FilterPredicate,
        conn_id: ?u64,
        write_id: ?[16]u8,
    ) !void {
        try self.ensureMutationAllowed();
        if (guard_predicate) |predicate| {
            if (predicate.isAlwaysFalse()) return;
        }
        var res = try self.prepareWriteResources(table_index, namespace_id, guard_predicate);
        defer res.deinit(self.allocator);
        var queued = false;

        const guard_sql = res.guardSql();
        const sql_string: []const u8 = if (guard_sql) |fragment|
            try std.mem.concat(self.allocator, u8, &.{
                res.table_metadata.delete_document_sql_prefix,
                fragment,
                res.table_metadata.delete_document_sql_suffix,
            })
        else
            try std.mem.concat(self.allocator, u8, &.{
                res.table_metadata.delete_document_sql_prefix,
                res.table_metadata.delete_document_sql_suffix,
            });
        errdefer if (!queued) self.allocator.free(sql_string);

        const guard_values = res.takeGuardValues();
        errdefer if (!queued) {
            if (guard_values) |values| typed.deinitValueSlice(self.allocator, values);
        };

        const op = WriteOp{
            .delete = .{
                .table_index = table_index,
                .id = id,
                .namespace_id = res.effective_namespace_id,
                .sql = sql_string,
                .guard_values = guard_values,
                .conn_id = conn_id,
                .write_id = write_id,
            },
        };

        try self.write_worker.enqueueOp(op);
        queued = true;
    }
};
