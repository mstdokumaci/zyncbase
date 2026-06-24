const std = @import("std");
const Allocator = std.mem.Allocator;
const schema_mod = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const typed = @import("../typed.zig");
const storage_cache = @import("cache.zig");
const sql = @import("sql.zig");
const filter_sql = @import("filter_sql.zig");
const filter_eval = @import("../filter_eval.zig");
const read_mod = @import("reader.zig");
const connection = @import("connection.zig");
const read_buffer = @import("read_buffer.zig");
const wire = @import("../wire.zig");
const send_queue_type = @import("../send_queue.zig").send_queue;

const DocId = typed.DocId;
const Record = typed.Record;
const metadata_cache_type = storage_cache.metadata_cache_type;
const req_queue_type = read_buffer.read_request_queue;
const ReadRequest = read_buffer.ReadRequest;
const ReadResponse = read_buffer.ReadResponse;
const ReaderNode = connection.ReaderNode;

fn cleanupRequest(req: ReadRequest) void {
    var mutable_req = req;
    mutable_req.deinit();
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

pub const ReaderThread = struct {
    thread: ?std.Thread,
    node: *ReaderNode,
    request_queue: *req_queue_type,
    send_queue: *send_queue_type,
    schema: *const schema_mod.Schema,
    metadata_cache: *metadata_cache_type,
    writer_version: *std.atomic.Value(u64),
    allocator: Allocator,
    notifier_fn: ?*const fn (?*anyopaque) void,
    notifier_ctx: ?*anyopaque,
    shutdown_requested: std.atomic.Value(bool),
    is_ready: std.atomic.Value(bool),
    ready_mutex: std.Thread.Mutex,
    ready_cond: std.Thread.Condition,

    pub fn init(
        allocator: Allocator,
        node: *ReaderNode,
        request_queue: *req_queue_type,
        send_queue: *send_queue_type,
        schema: *const schema_mod.Schema,
        metadata_cache: *metadata_cache_type,
        writer_version: *std.atomic.Value(u64),
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) ReaderThread {
        return .{
            .thread = null,
            .node = node,
            .request_queue = request_queue,
            .send_queue = send_queue,
            .schema = schema,
            .metadata_cache = metadata_cache,
            .writer_version = writer_version,
            .allocator = allocator,
            .notifier_fn = notifier_fn,
            .notifier_ctx = notifier_ctx,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .is_ready = std.atomic.Value(bool).init(false),
            .ready_mutex = .{},
            .ready_cond = .{},
        };
    }

    pub fn spawn(self: *ReaderThread) !void {
        self.thread = try std.Thread.spawn(.{}, threadLoop, .{self});
    }

    pub fn waitUntilReady(self: *ReaderThread) void {
        self.ready_mutex.lock();
        defer self.ready_mutex.unlock();
        while (!self.is_ready.load(.acquire)) {
            self.ready_cond.wait(&self.ready_mutex);
        }
    }

    pub fn stop(self: *ReaderThread) void {
        self.shutdown_requested.store(true, .release);
        self.request_queue.shutdown();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn threadLoop(self: *ReaderThread) void {
        self.is_ready.store(true, .release);
        self.ready_mutex.lock();
        self.ready_cond.broadcast();
        self.ready_mutex.unlock();

        while (!self.shutdown_requested.load(.acquire)) {
            const request = self.request_queue.pop() orelse break;
            var response = self.executeRead(request);
            if (self.notifier_fn) |n| n(self.notifier_ctx);

            if (response.err) |err| {
                const msg_id: ?u64 = response.msg_id;
                const encoded = wire.encodeError(self.allocator, msg_id, .{
                    .code = "STORE_QUERY",
                    .message = @errorName(err),
                }) catch {
                    std.log.err("ReaderThread: failed to encode error", .{});
                    response.deinit(self.allocator);
                    continue;
                };
                self.send_queue.push(.{ .conn_id = response.conn_id, .data = encoded }) catch {
                    std.log.err("ReaderThread: failed to push error to send queue", .{});
                    self.allocator.free(encoded);
                    response.deinit(self.allocator);
                    continue;
                };
            } else {
                const encoded = wire.encodeQuery(self.allocator, .{
                    .msg_id = response.msg_id,
                    .sub_id = response.sub_id,
                    .records = response.records,
                    .table = response.table,
                    .next_cursor = response.next_cursor_str,
                }) catch {
                    std.log.err("ReaderThread: failed to encode query", .{});
                    response.deinit(self.allocator);
                    continue;
                };
                self.send_queue.push(.{ .conn_id = response.conn_id, .data = encoded }) catch {
                    std.log.err("ReaderThread: failed to push to send queue", .{});
                    self.allocator.free(encoded);
                    response.deinit(self.allocator);
                    continue;
                };
            }
            response.deinit(self.allocator);
        }

        while (self.request_queue.popTimed(0)) |request| {
            const shutdown_encoded = wire.encodeError(self.allocator, request.msg_id, .{
                .code = "STORE_QUERY",
                .message = "shutdown",
            }) catch |err| {
                std.log.err("ReaderThread: failed to encode shutdown error: {}", .{err});
                cleanupRequest(request);
                if (self.notifier_fn) |n| n(self.notifier_ctx);
                continue;
            };
            self.send_queue.push(.{ .conn_id = request.conn_id, .data = shutdown_encoded }) catch |err| {
                std.log.err("ReaderThread: failed to push shutdown error: {}", .{err});
                self.allocator.free(shutdown_encoded);
            };
            cleanupRequest(request);
            if (self.notifier_fn) |n| n(self.notifier_ctx);
        }
    }

    fn executeRead(self: *ReaderThread, request: ReadRequest) ReadResponse {
        var req = request;

        const table_metadata = self.schema.tableByIndex(req.table_index) orelse {
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
            req.deinit();
            return response;
        }

        const result = self.executeSelectQuery(
            table_metadata,
            effective_namespace_id,
            &req.filter,
            auth_pred,
        );
        const response = self.buildQueryResponse(req, table_metadata, result);
        req.deinit();
        return response;
    }

    const SelectDocumentResult = struct { record: ?Record };

    fn executeSelectDocument(
        self: *ReaderThread,
        table_metadata: *const schema_mod.Table,
        id: DocId,
        namespace_id: i64,
        guard_predicate: ?*const query_ast.FilterPredicate,
    ) SelectDocumentResult {
        if (guard_predicate) |predicate| {
            if (predicate.isAlwaysFalse()) return .{ .record = null };
        }

        const cache_key = read_mod.getCacheKey(table_metadata, namespace_id, id);

        if (self.metadata_cache.get(cache_key)) |handle| {
            const typed_record_ptr = handle.data();
            const slice: []Record = typed_record_ptr[0..1];
            if (guard_predicate) |predicate| {
                if (filter_eval.evaluatePredicate(predicate, &slice[0]) catch false) {
                    // cache hit with passing guard
                } else {
                    handle.release();
                    return .{ .record = null };
                }
            }
            defer handle.release();
            const cloned = slice[0].clone(self.allocator) catch {
                return .{ .record = null };
            };
            return .{ .record = cloned };
        } else |err| switch (err) {
            error.NotFound => {},
            else => return .{ .record = null },
        }

        self.node.mutex.lock();
        defer self.node.mutex.unlock();

        var rendered_guard = filter_sql.renderAndClause(self.allocator, table_metadata, guard_predicate) catch {
            return .{ .record = null };
        };
        defer if (rendered_guard) |*rendered| rendered.deinit(self.allocator);

        const sql_query = sql.buildSelectDocumentSql(self.allocator, table_metadata, if (rendered_guard) |*rendered| rendered.sqlSlice() else null) catch {
            return .{ .record = null };
        };
        defer self.allocator.free(sql_query);

        const seq_before = self.writer_version.load(.acquire);

        var mstmt = self.node.stmt_cache.acquire(self.allocator, &self.node.conn, sql_query) catch {
            return .{ .record = null };
        };
        defer mstmt.release();
        const stmt = mstmt.stmt;

        const result = read_mod.execSelectDocument(self.allocator, &self.node.conn, stmt, id, namespace_id, table_metadata, if (rendered_guard) |rendered| rendered.values else null) catch {
            return .{ .record = null };
        };

        if (result) |record| {
            if (self.writer_version.load(.acquire) == seq_before) {
                const cache_record = record.clone(self.allocator) catch {
                    return .{ .record = record };
                };
                self.metadata_cache.update(cache_key, cache_record) catch |err| {
                    std.log.err("ReaderThread: cache.update failed: {}", .{err});
                };
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
        self: *ReaderThread,
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

        self.node.mutex.lock();
        defer self.node.mutex.unlock();

        const query_res = read_mod.buildSelectQuery(self.allocator, table_metadata, namespace_id, filter, guard_predicate) catch {
            return .{ .records = &[_]Record{}, .next_cursor_str = null };
        };
        defer query_res.deinit(self.allocator);

        const sort_field_index = filter.order_by.field_index;
        var mstmt = self.node.stmt_cache.acquire(self.allocator, &self.node.conn, query_res.sql) catch {
            return .{ .records = &[_]Record{}, .next_cursor_str = null };
        };
        defer mstmt.release();
        const stmt = mstmt.stmt;

        const exec_res = read_mod.execQuery(
            self.allocator,
            &self.node.conn,
            stmt,
            query_res.values,
            table_metadata,
            filter.limit,
            sort_field_index,
        ) catch {
            return .{ .records = &[_]Record{}, .next_cursor_str = null };
        };

        return .{
            .records = exec_res.records,
            .next_cursor_str = exec_res.next_cursor_str,
        };
    }

    fn buildResponse(
        self: *ReaderThread,
        request: ReadRequest,
        table_metadata: *const schema_mod.Table,
        result: SelectDocumentResult,
    ) ReadResponse {
        if (result.record) |record| {
            const records = self.allocator.alloc(Record, 1) catch {
                record.deinit(self.allocator);
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
        self: *ReaderThread,
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

pub const ReaderPool = struct {
    threads: []ReaderThread,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        reader_nodes: []ReaderNode,
        request_queue: *req_queue_type,
        send_queue: *send_queue_type,
        schema: *const schema_mod.Schema,
        metadata_cache: *metadata_cache_type,
        writer_version: *std.atomic.Value(u64),
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) !ReaderPool {
        const threads = try allocator.alloc(ReaderThread, reader_nodes.len);
        var init_count: usize = 0;
        errdefer allocator.free(threads[0..init_count]);

        for (reader_nodes, 0..) |*node, i| {
            threads[i] = ReaderThread.init(
                allocator,
                node,
                request_queue,
                send_queue,
                schema,
                metadata_cache,
                writer_version,
                notifier_fn,
                notifier_ctx,
            );
            init_count += 1;
        }

        return .{ .threads = threads, .allocator = allocator };
    }

    pub fn start(self: *ReaderPool) !void {
        for (self.threads) |*rt| {
            try rt.spawn();
        }
        for (self.threads) |*rt| {
            rt.waitUntilReady();
        }
    }

    pub fn stop(self: *ReaderPool) void {
        for (self.threads) |*rt| {
            rt.stop();
        }
    }

    pub fn deinit(self: *ReaderPool) void {
        self.allocator.free(self.threads);
    }
};
