const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const schema_mod = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const typed = @import("../typed.zig");
const storage_cache = @import("cache.zig");
const filter_sql = @import("filter_sql.zig");
const read_mod = @import("reader.zig");
const connection = @import("connection.zig");
const read_buffer = @import("read_buffer.zig");
const wire = @import("../wire.zig");
const send_queue_type = @import("../send_queue.zig").send_queue;
const managedThread = @import("../threading/managed_thread.zig").managedThread;
const workerPool = @import("../threading/worker_pool.zig").workerPool;
const Notifier = @import("../threading/notifier.zig").Notifier;

const DocId = typed.DocId;
const Record = typed.Record;
const metadata_cache_type = storage_cache.metadata_cache_type;
const req_queue_type = read_buffer.read_request_queue;
const ReadRequest = read_buffer.ReadRequest;
const ReadResponse = read_buffer.ReadResponse;
const ReaderNode = connection.ReaderNode;

fn cleanupRequest(req: ReadRequest) void {
    var mutable_req = req;
    mutable_req.deinit(mutable_req.allocator);
}

fn isPointLookup(filter: *const query_ast.QueryFilter, id_index: usize) ?DocId {
    const conds = filter.predicate.conditions orelse return null;
    if (conds.len != 1) return null;
    if (filter.predicate.or_conditions != null) return null;
    if (filter.order_by.field_index != id_index or filter.order_by.desc) return null;
    if (filter.after != null) return null;
    const cond = conds[0];
    if (cond.op != .eq) return null;
    if (cond.field_index != id_index) return null;
    const val = cond.value orelse return null;
    if (val != .scalar or val.scalar != .doc_id) return null;
    return val.scalar.doc_id;
}

pub const ReadWorker = struct {
    thread: managedThread(ReadWorker),
    node: *ReaderNode,
    request_queue: *req_queue_type,
    send_queue: *send_queue_type,
    schema: *const schema_mod.Schema,
    metadata_cache: *metadata_cache_type,
    writer_version: *std.atomic.Value(u64),
    allocator: Allocator,
    notifier: Notifier,
    memory_strategy: *MemoryStrategy,
    /// Per-request arena for record/value allocations. Bulk-freed via reset()
    /// at the start of each request, replacing hundreds of individual GPA frees.
    read_arena: *std.heap.ArenaAllocator,
    /// Reusable scratch buffer for streaming array-to-JSON serialization.
    /// Reset (length only) between uses; capacity is retained for steady-state reuse.
    json_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        node: *ReaderNode,
        request_queue: *req_queue_type,
        send_queue: *send_queue_type,
        schema: *const schema_mod.Schema,
        metadata_cache: *metadata_cache_type,
        writer_version: *std.atomic.Value(u64),
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) !ReadWorker {
        return .{
            .thread = managedThread(ReadWorker).init(),
            .node = node,
            .request_queue = request_queue,
            .send_queue = send_queue,
            .schema = schema,
            .metadata_cache = metadata_cache,
            .writer_version = writer_version,
            .allocator = allocator,
            .notifier = Notifier.init(notifier_fn, notifier_ctx),
            .memory_strategy = memory_strategy,
            .read_arena = try memory_strategy.acquireArena(),
        };
    }

    pub fn spawn(self: *ReadWorker) !void {
        try self.thread.spawn(threadLoop, self);
    }

    pub fn stop(self: *ReadWorker) void {
        self.thread.stop();
    }

    fn threadLoop(self: *ReadWorker) void {
        while (!self.thread.isRequested()) {
            // Bulk-free all record/value allocations from the previous request.
            _ = self.read_arena.reset(.retain_capacity);

            const request = self.request_queue.pop() orelse break;
            const response = self.executeRead(request);

            const handle = self.memory_strategy.acquireArenaDeferred() catch |acq_err| {
                std.log.err("ReadWorker: failed to acquire arena: {}", .{acq_err});
                continue;
            };
            defer handle.release();

            if (response.err) |err| {
                const msg_id: ?u64 = response.msg_id;
                const encoded = wire.encodeError(handle.allocator(), msg_id, .{
                    .code = "STORE_QUERY",
                    .message = @errorName(err),
                }) catch {
                    std.log.err("ReadWorker: failed to encode error", .{});
                    continue;
                };
                handle.retain();
                self.send_queue.push(.{ .conn_id = response.conn_id, .data = encoded, .arena = handle }) catch {
                    std.log.err("ReadWorker: failed to push error to send queue", .{});
                    handle.release();
                    continue;
                };
                self.notifier.notify();
            } else {
                const encoded = wire.encodeQuery(handle.allocator(), .{
                    .msg_id = response.msg_id,
                    .sub_id = response.sub_id,
                    .records = response.records,
                    .table = response.table,
                    .next_cursor = response.next_cursor_str,
                }) catch {
                    std.log.err("ReadWorker: failed to encode query", .{});
                    continue;
                };
                handle.retain();
                self.send_queue.push(.{ .conn_id = response.conn_id, .data = encoded, .arena = handle }) catch {
                    std.log.err("ReadWorker: failed to push to send queue", .{});
                    handle.release();
                    continue;
                };
                self.notifier.notify();
            }
        }

        while (self.request_queue.popTimed(0)) |request| {
            const handle = self.memory_strategy.acquireArenaDeferred() catch |acq_err| {
                std.log.err("ReadWorker: failed to acquire arena for shutdown: {}", .{acq_err});
                cleanupRequest(request);
                self.notifier.notify();
                continue;
            };
            defer handle.release();

            const shutdown_encoded = wire.encodeError(handle.allocator(), request.msg_id, .{
                .code = "STORE_QUERY",
                .message = "shutdown",
            }) catch |err| {
                std.log.err("ReadWorker: failed to encode shutdown error: {}", .{err});
                cleanupRequest(request);
                self.notifier.notify();
                continue;
            };
            handle.retain();
            self.send_queue.push(.{ .conn_id = request.conn_id, .data = shutdown_encoded, .arena = handle }) catch |err| {
                std.log.err("ReadWorker: failed to push shutdown error: {}", .{err});
                handle.release();
            };
            cleanupRequest(request);
            self.notifier.notify();
        }
    }

    fn executeRead(self: *ReadWorker, request: ReadRequest) ReadResponse {
        var req = request;

        const table_metadata = self.schema.tableByIndex(req.table_index) orelse {
            req.deinit(req.allocator);
            // SAFETY: Table metadata is undefined because the table index was not found.
            return .{
                .conn_id = req.conn_id,
                .msg_id = req.msg_id,
                .table = undefined,
                .records = &[_]Record{},
                .next_cursor_str = null,
                .err = error.UnknownTable,
            };
        };

        const effective_namespace_id = if (table_metadata.namespaced)
            req.namespace_id
        else
            schema_mod.global_namespace_id;

        const auth_pred = if (req.auth_predicate) |*p| p else null;

        if (isPointLookup(&req.filter, schema_mod.id_field_index)) |id| {
            const result = self.executeSelectDocument(
                table_metadata,
                id,
                effective_namespace_id,
                auth_pred,
            );
            const response = self.buildResponse(req, table_metadata, result);
            req.deinit(req.allocator);
            return response;
        }

        const result = self.executeSelectQuery(
            table_metadata,
            effective_namespace_id,
            &req.filter,
            auth_pred,
        );
        const response = self.buildQueryResponse(req, table_metadata, result);
        req.deinit(req.allocator);
        return response;
    }

    const SelectDocumentResult = struct { record: ?Record };

    fn executeSelectDocument(
        self: *ReadWorker,
        table_metadata: *const schema_mod.Table,
        id: DocId,
        namespace_id: i64,
        guard_predicate: ?*const query_ast.FilterPredicate,
    ) SelectDocumentResult {
        if (guard_predicate) |predicate| {
            if (predicate.isAlwaysFalse()) return .{ .record = null };
        }

        const cache_key = storage_cache.getCacheKey(table_metadata, namespace_id, id);

        switch (storage_cache.getCachedRecord(self.metadata_cache, cache_key, guard_predicate)) {
            .miss => {},
            .guard_failed => return .{ .record = null },
            .hit => |hit| {
                defer hit.handle.release();
                const cloned = hit.record.clone(self.read_arena.allocator()) catch
                    return .{ .record = null };
                return .{ .record = cloned };
            },
        }

        // Build SQL outside the node mutex — only accesses allocator + read-only metadata
        var rendered_guard = filter_sql.renderAndClause(self.allocator, table_metadata, guard_predicate) catch {
            return .{ .record = null };
        };
        defer if (rendered_guard) |*rendered| rendered.deinit(self.allocator);

        // No-guard: use the pre-built cached string directly (zero alloc).
        // Guard: concat base + guard fragment (one alloc, freed below).
        const guard_fragment: ?[]const u8 = if (rendered_guard) |*rendered| rendered.sqlSlice() else null;
        const sql_query: []const u8 = if (guard_fragment) |fragment|
            std.mem.concat(self.allocator, u8, &.{ table_metadata.select_document_sql, fragment }) catch {
                return .{ .record = null };
            }
        else
            table_metadata.select_document_sql;
        defer if (guard_fragment != null) self.allocator.free(sql_query);

        // Snapshot writer version before the DB read to detect concurrent writes
        const seq_before = self.writer_version.load(.acquire);

        // Execute DB read under the node mutex
        const result: ?Record = blk: {
            self.node.mutex.lock();
            defer self.node.mutex.unlock();

            var mstmt = self.node.stmt_cache.acquire(self.allocator, &self.node.conn, sql_query) catch {
                break :blk null;
            };
            defer mstmt.release();

            break :blk read_mod.execSelectDocument(
                self.read_arena.allocator(),
                &self.node.conn,
                mstmt.stmt,
                id,
                namespace_id,
                table_metadata,
                if (rendered_guard) |rendered| rendered.values else null,
                &self.json_buf,
            ) catch null;
        };

        // Cache update outside the node mutex — lock-free cache, version-gated
        if (result) |record| {
            if (self.writer_version.load(.acquire) == seq_before) {
                const cache_record = record.clone(self.allocator) catch {
                    return .{ .record = record };
                };
                self.metadata_cache.update(cache_key, cache_record) catch |err| {
                    cache_record.deinit(self.allocator);
                    std.log.err("ReadWorker: cache.update failed: {}", .{err});
                };
                // Double-check: if a write snuck in during the cache update, evict stale entry
                if (self.writer_version.load(.acquire) != seq_before) {
                    _ = self.metadata_cache.evict(cache_key);
                }
            }
            return .{ .record = record };
        }
        return .{ .record = null };
    }

    const SelectQueryResult = struct {
        records: []Record,
        next_cursor_str: ?[]const u8,
    };

    fn executeSelectQuery(
        self: *ReadWorker,
        table_metadata: *const schema_mod.Table,
        namespace_id: i64,
        filter: *const query_ast.QueryFilter,
        guard_predicate: ?*const query_ast.FilterPredicate,
    ) SelectQueryResult {
        if (filter.predicate.isAlwaysFalse()) {
            return .{ .records = &[_]Record{}, .next_cursor_str = null };
        }
        if (guard_predicate) |predicate| {
            if (predicate.isAlwaysFalse()) {
                return .{ .records = &[_]Record{}, .next_cursor_str = null };
            }
        }

        // Build SQL outside the node mutex — only accesses allocator + read-only metadata
        const query_res = read_mod.buildSelectQuery(self.allocator, table_metadata, namespace_id, filter, guard_predicate) catch {
            return .{ .records = &[_]Record{}, .next_cursor_str = null };
        };
        defer query_res.deinit(self.allocator);

        const sort_field_index = filter.order_by.field_index;

        // Execute DB read under the node mutex
        self.node.mutex.lock();
        defer self.node.mutex.unlock();

        var mstmt = self.node.stmt_cache.acquire(self.allocator, &self.node.conn, query_res.sql) catch {
            return .{ .records = &[_]Record{}, .next_cursor_str = null };
        };
        defer mstmt.release();
        const stmt = mstmt.stmt;

        const exec_res = read_mod.execQuery(
            self.read_arena.allocator(),
            &self.node.conn,
            stmt,
            query_res.values,
            table_metadata,
            filter.limit,
            sort_field_index,
            &self.json_buf,
        ) catch {
            return .{ .records = &[_]Record{}, .next_cursor_str = null };
        };

        return .{
            .records = exec_res.records,
            .next_cursor_str = exec_res.next_cursor_str,
        };
    }

    fn buildResponse(
        self: *ReadWorker,
        request: ReadRequest,
        table_metadata: *const schema_mod.Table,
        result: SelectDocumentResult,
    ) ReadResponse {
        if (result.record) |record| {
            const records = self.read_arena.allocator().alloc(Record, 1) catch {
                return .{
                    .conn_id = request.conn_id,
                    .msg_id = request.msg_id,
                    .table = table_metadata,
                    .records = &[_]Record{},
                    .next_cursor_str = null,
                    .err = error.OutOfMemory,
                };
            };
            records[0] = record;
            return .{
                .conn_id = request.conn_id,
                .msg_id = request.msg_id,
                .table = table_metadata,
                .records = records,
                .next_cursor_str = null,
                .sub_id = request.sub_id,
            };
        }
        return .{
            .conn_id = request.conn_id,
            .msg_id = request.msg_id,
            .table = table_metadata,
            .records = &[_]Record{},
            .next_cursor_str = null,
            .sub_id = request.sub_id,
        };
    }

    fn buildQueryResponse(
        self: *ReadWorker,
        request: ReadRequest,
        table_metadata: *const schema_mod.Table,
        result: SelectQueryResult,
    ) ReadResponse {
        _ = self;

        return .{
            .conn_id = request.conn_id,
            .msg_id = request.msg_id,
            .table = table_metadata,
            .records = result.records,
            .next_cursor_str = result.next_cursor_str,
            .sub_id = request.sub_id,
        };
    }
};

pub const ReadWorkerPool = struct {
    pool: workerPool(ReadWorker),
    request_queue: *req_queue_type,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        memory_strategy: *MemoryStrategy,
        reader_nodes: []ReaderNode,
        request_queue: *req_queue_type,
        send_queue: *send_queue_type,
        schema: *const schema_mod.Schema,
        metadata_cache: *metadata_cache_type,
        writer_version: *std.atomic.Value(u64),
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) !ReadWorkerPool {
        var pool = try workerPool(ReadWorker).init(allocator, reader_nodes.len);
        var initialized: usize = 0;
        errdefer {
            for (pool.workers[0..initialized]) |*w| {
                w.memory_strategy.releaseArena(w.read_arena);
            }
            pool.deinit();
        }

        for (reader_nodes, 0..) |*node, i| {
            pool.workers[i] = try ReadWorker.init(
                allocator,
                memory_strategy,
                node,
                request_queue,
                send_queue,
                schema,
                metadata_cache,
                writer_version,
                notifier_fn,
                notifier_ctx,
            );
            initialized += 1;
        }

        return .{
            .pool = pool,
            .request_queue = request_queue,
            .allocator = allocator,
        };
    }

    pub fn start(self: *ReadWorkerPool) !void {
        try self.pool.start();
    }

    /// SHUTDOWN ORDER: The request_queue MUST be shut down (via `request_queue.shutdown()`)
    /// BEFORE calling this method. ReadWorkers block inside the SPMC queue's own condvar
    /// (not managedThread's) for new work. Calling shutdown() on the queue unblocks all
    /// waiting workers, allowing isRequested() to be seen and the thread loop to exit cleanly.
    ///
    /// The managedThread inside each ReadWorker is used only for spawn/stop/isRequested —
    /// it does not participate in the per-request wait cycle.
    pub fn stop(self: *ReadWorkerPool) void {
        self.request_queue.shutdown();
        self.pool.stop();
    }

    pub fn deinit(self: *ReadWorkerPool) void {
        for (self.pool.workers) |*w| {
            w.json_buf.deinit(w.allocator);
            w.memory_strategy.releaseArena(w.read_arena);
        }
        self.pool.deinit();
    }
};
