const std = @import("std");

const authorization_store = @import("authorization/store.zig");
const authorization_types = @import("authorization/types.zig");
const request_context = @import("connection/request_context.zig");
const msgpack = @import("msgpack_utils.zig");
const query_ast = @import("query/ast.zig");
const query_hasher = @import("query/hasher.zig");
const query_parser = @import("query/parser.zig");
const schema_constraints = @import("schema/constraints.zig");
const schema_parse = @import("schema/parse.zig");
const schema_system = @import("schema/system.zig");
const schema_types = @import("schema/types.zig");
const storage_mod = @import("storage_engine.zig");
const typed_codec = @import("typed/codec.zig");
const typed_doc_id = @import("typed/doc_id.zig");

const Allocator = std.mem.Allocator;
const ReadRequest = storage_mod.ReadRequest;
const StorageEngine = storage_mod.StorageEngine;
const StorageError = storage_mod.StorageError;
const DocId = typed_doc_id.DocId;

/// Decode a sparse field array payload into a deduplicated list of column values.
/// Wire protocol: duplicate field index → last-wins (reverse scan, skip seen).
fn decodeColumnsFromPairs(
    allocator: Allocator,
    table: *const schema_types.Table,
    value: msgpack.Payload,
) !std.ArrayListUnmanaged(storage_mod.ColumnValue) {
    var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue).empty;
    errdefer {
        for (columns.items) |col| col.value.deinit(allocator);
        columns.deinit(allocator);
    }

    if (value.arr.len % 2 != 0) return error.InvalidPayload;

    var seen = std.StaticBitSet(schema_parse.max_store_fields).initEmpty();
    var i: usize = value.arr.len;
    while (i >= 2) {
        i -= 2;
        const f_idx = msgpack.extractPayloadUsize(value.arr[i]) orelse return error.InvalidPayload;
        if (f_idx < schema_parse.max_store_fields) {
            if (seen.isSet(f_idx)) continue;
            seen.set(f_idx);
        }

        const raw_value = value.arr[i + 1];
        const field = try validateFieldWrite(allocator, table, f_idx, raw_value);
        const typed_value = try typed_codec.fromPayload(allocator, field.storage_type, field.items_type, raw_value);

        columns.append(allocator, .{
            .index = f_idx,
            .value = typed_value,
        }) catch |err| {
            typed_value.deinit(allocator);
            return err;
        };
    }

    return columns;
}

/// Validates a single field write operation.
/// Checks for immutability, existence, nullability, and type constraints.
pub fn validateFieldWrite(
    allocator: Allocator,
    tbl_md: *const schema_types.Table,
    field_index: usize,
    value: msgpack.Payload,
) !schema_types.Field {
    if (field_index >= tbl_md.fields.len) return StorageError.UnknownField;

    // Leading system columns and trailing timestamps are immutable.
    // The last two fields are created_at and updated_at, which are also immutable by the client.
    if (field_index < schema_system.first_user_field_index or
        field_index >= tbl_md.fields.len - 2) return StorageError.ImmutableField;
    const field = tbl_md.fields[field_index];

    if (field.required and value == .nil) return StorageError.NullNotAllowed;

    if (value != .nil) {
        try typed_codec.validateValue(field.storage_type, value);

        if (field.storage_type == .array) {
            if (field.items_type) |items_type| {
                for (value.arr) |item| {
                    typed_codec.validateValue(items_type, item) catch {
                        return StorageError.InvalidArrayElement;
                    };
                }
            }
        }

        if (field.constraints) |constraints| {
            try schema_constraints.validate(constraints, field.declared_type, value, allocator);
        }
    }

    return field;
}

fn validateRequiredFieldsForCreate(
    table: *const schema_types.Table,
    columns: []const storage_mod.ColumnValue,
) !void {
    const user_fields = table.fields[schema_system.first_user_field_index .. table.fields.len - schema_system.trailing_system_field_count];
    for (user_fields, schema_system.first_user_field_index..) |f, f_idx| {
        if (!f.required) continue;
        const present = for (columns) |col| {
            if (col.index == f_idx) break true;
        } else false;
        if (!present) return StorageError.MissingRequiredField;
    }
}

/// StoreService provides a domain-level facade for storage operations.
/// It encapsulates schema validation, path resolution, and ColumnValue construction.
pub const StoreService = struct {
    io: std.Io,
    allocator: Allocator,
    storage_engine: *StorageEngine,
    schema: *const schema_types.Schema,
    auth_config: *const authorization_types.AuthConfig,

    pub fn init(io: std.Io, allocator: Allocator, storage_engine: *StorageEngine, schema: *const schema_types.Schema, auth_config: *const authorization_types.AuthConfig) StoreService {
        return .{
            .io = io,
            .allocator = allocator,
            .storage_engine = storage_engine,
            .schema = schema,
            .auth_config = auth_config,
        };
    }

    pub fn deinit(_: *StoreService) void {}

    pub const WriteContext = struct {
        request: request_context.RequestContext,
        write_id: ?[16]u8 = null,
    };

    pub const ReadContext = struct {
        request: request_context.RequestContext,
        msg_id: u64,
        allocator: Allocator,
    };

    const StorePath = struct {
        table_index: usize,
        table: *const schema_types.Table,
        doc_id: DocId,
    };

    const DocKey = struct {
        table_index: usize,
        doc_id: DocId,
    };

    const BatchDocState = enum { exists, deleted };
    const BatchDocStates = std.AutoHashMap(DocKey, BatchDocState);

    pub fn tryResolveScopeCached(self: *StoreService, namespace: []const u8, external_user_id: []const u8) !?request_context.Scope {
        if (namespace.len == 0) return error.InvalidMessageFormat;
        if (external_user_id.len == 0) return error.InvalidMessageFormat;

        const namespace_id = self.storage_engine.cachedNamespaceId(namespace) orelse return null;
        const users_table = self.schema.table("users") orelse return error.UnknownTable;
        const identity_namespace_id = if (users_table.namespaced) namespace_id else schema_system.global_namespace_id;
        const user_doc_id = self.storage_engine.cachedUserId(identity_namespace_id, external_user_id) orelse return null;

        return .{
            .namespace_id = namespace_id,
            .user_doc_id = user_doc_id,
        };
    }

    pub fn enqueueResolveScope(
        self: *StoreService,
        conn_id: u64,
        msg_id: u64,
        scope_seq: u64,
        namespace: []const u8,
        external_user_id: []const u8,
        is_presence: bool,
    ) !void {
        if (namespace.len == 0 or external_user_id.len == 0) return error.InvalidMessageFormat;
        try self.storage_engine.enqueueSessionResolution(conn_id, msg_id, scope_seq, namespace, external_user_id, is_presence);
    }

    pub fn enqueueRead(self: *StoreService, request: ReadRequest) !void {
        try self.storage_engine.enqueueRead(request);
    }

    /// Builds and enqueues a query read request in one step.
    pub fn query(
        self: *StoreService,
        ctx: ReadContext,
        table_index: usize,
        parsed: msgpack.Payload,
    ) !void {
        var read_req = try self.prepareQueryRead(ctx, table_index, parsed, null);
        errdefer read_req.deinit(ctx.allocator);
        try self.enqueueRead(read_req);
    }

    /// Builds and enqueues a load-more read request in one step.
    pub fn loadMore(
        self: *StoreService,
        ctx: ReadContext,
        table_index: usize,
        namespace_id: i64,
        sub_filter: query_ast.QueryFilter,
        sub_id: u64,
        next_cursor: []const u8,
    ) !void {
        var read_req = try self.prepareLoadMoreRead(ctx, table_index, namespace_id, sub_filter, sub_id, next_cursor);
        errdefer read_req.deinit(ctx.allocator);
        try self.enqueueRead(read_req);
    }

    /// Builds a ReadRequest for an initial query/subscribe read.
    /// Performs read authorization and parses the wire filter payload, then
    /// hands ownership of the resulting allocations to the returned ReadRequest.
    pub fn prepareQueryRead(
        self: *StoreService,
        ctx: ReadContext,
        table_index: usize,
        parsed: msgpack.Payload,
        sub_id: ?u64,
    ) !ReadRequest {
        const table = self.schema.tableByIndex(table_index) orelse return error.UnknownTable;

        var store_read = try authorization_store.authorizeStoreRead(ctx.allocator, .{
            .config = self.auth_config,
            .table = table,
            .session_user_id = ctx.request.user_doc_id,
            .session_external_id = ctx.request.external_user_id,
            .session_claims = ctx.request.session_claims,
            .namespace = ctx.request.store_namespace orelse return error.SessionNotReady,
        });
        errdefer if (store_read) |*p| p.deinit(ctx.allocator);

        var filter = try query_parser.parseQueryFilter(ctx.allocator, self.schema, table_index, parsed);
        errdefer filter.deinit(ctx.allocator);

        // Merge guard into filter (fixes data leak + enables correct structural hash)
        if (store_read) |*guard| {
            try query_ast.FilterPredicate.mergeInPlace(&filter.predicate, ctx.allocator, guard);
            guard.* = .{};
        }

        // Compute structural hash after merge
        filter.structural_hash = query_hasher.computeStructuralHash(table_index, &filter);

        return ReadRequest{
            .conn_id = ctx.request.conn_id,
            .msg_id = ctx.msg_id,
            .table_index = table_index,
            .namespace_id = ctx.request.store_namespace_id,
            .filter = filter,
            .sub_id = sub_id,
        };
    }

    /// Builds a ReadRequest for a load-more read over an existing subscription.
    /// Clones the subscription's filter, decodes the cursor token against the
    /// subscription's table metadata and canonical descriptors, and attaches it
    /// as the filter's `after` anchor. No re-authorization — the stored
    /// subscription filter already includes the guard from subscribe time.
    pub fn prepareLoadMoreRead(
        self: *StoreService,
        ctx: ReadContext,
        table_index: usize,
        namespace_id: i64,
        sub_filter: query_ast.QueryFilter,
        sub_id: u64,
        next_cursor: []const u8,
    ) !ReadRequest {
        const table = self.schema.tableByIndex(table_index) orelse return error.UnknownTable;

        var filter_clone = try sub_filter.clone(ctx.allocator);
        errdefer filter_clone.deinit(ctx.allocator);

        const cursor = try query_parser.decodeCursorToken(
            ctx.allocator,
            next_cursor,
            table_index,
            table,
            filter_clone.order_by,
        );
        if (filter_clone.after) |*old| old.deinit(ctx.allocator);
        filter_clone.after = cursor;

        // Recompute structural hash — after presence is part of the hash,
        // so transitioning from null to a cursor changes it.
        filter_clone.structural_hash = query_hasher.computeStructuralHash(table_index, &filter_clone);

        return ReadRequest{
            .conn_id = ctx.request.conn_id,
            .msg_id = ctx.msg_id,
            .table_index = table_index,
            .namespace_id = namespace_id,
            .filter = filter_clone,
            .sub_id = sub_id,
        };
    }

    pub fn setPath(
        self: *StoreService,
        ctx: WriteContext,
        path: msgpack.Payload,
        value: msgpack.Payload,
        if_payload: ?msgpack.Payload,
    ) !void {
        const parsed = try self.parseStorePath(path);
        try self.applySet(parsed, ctx, value, if_payload);
    }

    pub fn removePath(
        self: *StoreService,
        ctx: WriteContext,
        path: msgpack.Payload,
        if_payload: ?msgpack.Payload,
    ) !void {
        const parsed = try self.parseStorePath(path);

        const has_conditional = if_payload != null;
        try requireCommittedForConditional(has_conditional, ctx.write_id);

        var precondition = try self.decodePrecondition(parsed.table, if_payload);
        errdefer if (precondition) |*p| p.deinit(self.allocator);

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = parsed.table,
            .session_user_id = ctx.request.user_doc_id,
            .session_external_id = ctx.request.external_user_id,
            .session_claims = ctx.request.session_claims,
            .namespace = ctx.request.store_namespace orelse return error.SessionNotReady,
            .doc_id = parsed.doc_id,
            .value = null,
            .is_create = false,
        });
        errdefer if (store_write) |*p| p.deinit(self.allocator);

        if (has_conditional) try self.mergeReadGuard(ctx, parsed.table, &store_write);

        const op = storage_mod.WriteOp{
            .delete = .{
                .table_index = parsed.table_index,
                .id = parsed.doc_id,
                .namespace_id = ctx.request.store_namespace_id,
                .guard_predicate = store_write,
                .precondition_predicate = precondition,
                .conn_id = ctx.request.conn_id,
                .write_id = ctx.write_id,
            },
        };
        store_write = null;
        precondition = null;
        errdefer op.deinit(self.allocator);

        try self.storage_engine.enqueueWriteOp(op);
    }

    pub fn batchWrite(
        self: *StoreService,
        ctx: WriteContext,
        ops_payload: msgpack.Payload,
    ) !void {
        if (ops_payload != .arr) return error.InvalidMessageFormat;
        const ops = ops_payload.arr;
        if (ops.len == 0) return; // no-op, success
        if (ops.len > 500) return error.BatchTooLarge;

        var doc_states = BatchDocStates.init(self.allocator);
        defer doc_states.deinit();

        var entries = try self.allocator.alloc(storage_mod.WriteOp, ops.len);
        var initialized: usize = 0;
        var entries_owned = true;
        errdefer if (entries_owned) {
            for (entries[0..initialized]) |entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
        };

        const timestamp = std.Io.Clock.real.now(self.io).toMicroseconds();

        for (ops) |op_payload| {
            entries[initialized] = try self.buildBatchEntry(ctx, op_payload, timestamp, &doc_states);
            initialized += 1;
        }

        for (entries) |entry| {
            const target = storage_mod.getOpTarget(entry) orelse continue;
            _ = self.schema.tableByIndex(target.table_index) orelse return StorageError.UnknownTable;
        }

        entries_owned = false;
        const op = storage_mod.WriteOp{
            .batch = .{
                .entries = entries,
                .conn_id = ctx.request.conn_id,
                .write_id = ctx.write_id,
            },
        };
        errdefer op.deinit(self.allocator);

        try self.storage_engine.enqueueWriteOp(op);
    }

    inline fn buildBatchEntry(
        self: *StoreService,
        ctx: WriteContext,
        payload: msgpack.Payload,
        timestamp: i64,
        doc_states: *BatchDocStates,
    ) !storage_mod.WriteOp {
        if (payload != .arr or payload.arr.len < 2) return error.InvalidMessageFormat;
        const tuple = payload.arr;
        if (tuple[0] != .str) return error.InvalidMessageFormat;

        const kind = tuple[0].str.value();
        if (std.mem.eql(u8, kind, "s")) {
            if (tuple.len < 3) return error.MissingRequiredFields;
            if (tuple.len > 4) return error.InvalidMessageFormat;
            const if_payload = if (tuple.len == 4) tuple[3] else null;
            return self.buildBatchSetEntry(ctx, tuple[1], tuple[2], if_payload, timestamp, doc_states);
        }
        if (std.mem.eql(u8, kind, "r")) {
            if (tuple.len < 2) return error.MissingRequiredFields;
            if (tuple.len > 3) return error.InvalidMessageFormat;
            const if_payload = if (tuple.len == 3) tuple[2] else null;
            return self.buildBatchRemoveEntry(ctx, tuple[1], if_payload, timestamp, doc_states);
        }
        if (std.mem.eql(u8, kind, "i")) {
            if (tuple.len < 4) return error.MissingRequiredFields;
            if (tuple.len > 5) return error.InvalidMessageFormat;
            const if_payload = if (tuple.len == 5) tuple[4] else null;
            return self.buildBatchIncrementEntry(ctx, tuple[1], tuple[2], tuple[3], if_payload, timestamp);
        }
        return error.InvalidMessageFormat;
    }

    fn parseStorePath(
        self: *StoreService,
        payload: msgpack.Payload,
    ) !StorePath {
        if (payload != .arr) return error.InvalidMessageFormat;

        const path = payload.arr;
        if (path.len != 2) return StorageError.InvalidPath;

        const table_index = msgpack.extractPayloadUsize(path[0]) orelse return error.InvalidMessageFormat;
        const table = self.schema.tableByIndex(table_index) orelse return StorageError.UnknownTable;

        if (path[1] != .bin) return error.InvalidMessageFormat;
        const parsed_doc_id = try typed_doc_id.fromBytes(path[1].bin.value());

        return .{
            .table_index = table_index,
            .table = table,
            .doc_id = parsed_doc_id,
        };
    }

    fn applySet(
        self: *StoreService,
        path: StorePath,
        ctx: WriteContext,
        value: msgpack.Payload,
        if_payload: ?msgpack.Payload,
    ) !void {
        if (value != .arr) return error.InvalidPayload;

        var columns = try decodeColumnsFromPairs(self.allocator, path.table, value);
        errdefer {
            for (columns.items) |col| col.value.deinit(self.allocator);
            columns.deinit(self.allocator);
        }

        const has_conditional = if_payload != null;
        try requireCommittedForConditional(has_conditional, ctx.write_id);

        var precondition = try self.decodePrecondition(path.table, if_payload);
        errdefer if (precondition) |*p| p.deinit(self.allocator);

        // A conditional set is a compare-and-set on an existing row. It never
        // creates: the upsert INSERT branch has no WHERE guard.
        const is_create = if (has_conditional) false else !self.storage_engine.documentExists(path.table_index, path.doc_id);

        if (is_create) try validateRequiredFieldsForCreate(path.table, columns.items);

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = path.table,
            .session_user_id = ctx.request.user_doc_id,
            .session_external_id = ctx.request.external_user_id,
            .session_claims = ctx.request.session_claims,
            .namespace = ctx.request.store_namespace orelse return error.SessionNotReady,
            .doc_id = path.doc_id,
            .value = &value,
            .is_create = is_create,
        });
        errdefer if (store_write) |*p| p.deinit(self.allocator);

        if (has_conditional) try self.mergeReadGuard(ctx, path.table, &store_write);

        const columns_slice = try columns.toOwnedSlice(self.allocator);

        const op = if (is_create) storage_mod.WriteOp{
            .upsert = .{
                .table_index = path.table_index,
                .id = path.doc_id,
                .namespace_id = ctx.request.store_namespace_id,
                .owner_doc_id = ctx.request.user_doc_id,
                .columns = columns_slice,
                .guard_predicate = store_write,
                .timestamp = std.Io.Clock.real.now(self.io).toMicroseconds(),
                .conn_id = ctx.request.conn_id,
                .write_id = ctx.write_id,
            },
        } else storage_mod.WriteOp{
            .update = .{
                .table_index = path.table_index,
                .id = path.doc_id,
                .namespace_id = ctx.request.store_namespace_id,
                .columns = columns_slice,
                .guard_predicate = store_write,
                .precondition_predicate = precondition,
                .timestamp = std.Io.Clock.real.now(self.io).toMicroseconds(),
                .conn_id = ctx.request.conn_id,
                .write_id = ctx.write_id,
            },
        };
        store_write = null;
        precondition = null;
        errdefer op.deinit(self.allocator);

        try self.storage_engine.enqueueWriteOp(op);
    }

    fn buildBatchSetEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        value: msgpack.Payload,
        if_payload: ?msgpack.Payload,
        timestamp: i64,
        doc_states: *BatchDocStates,
    ) !storage_mod.WriteOp {
        const path = try self.parseStorePath(path_payload);

        if (value != .arr) return error.InvalidPayload;

        var columns = try decodeColumnsFromPairs(self.allocator, path.table, value);
        errdefer {
            for (columns.items) |col| col.value.deinit(self.allocator);
            columns.deinit(self.allocator);
        }

        const has_conditional = if_payload != null;
        try requireCommittedForConditional(has_conditional, ctx.write_id);

        var precondition = try self.decodePrecondition(path.table, if_payload);
        errdefer if (precondition) |*p| p.deinit(self.allocator);

        const key = DocKey{ .table_index = path.table_index, .doc_id = path.doc_id };
        const effective_state = doc_states.get(key);
        const is_create = if (has_conditional) false else if (effective_state) |state|
            state == .deleted
        else
            !self.storage_engine.documentExists(path.table_index, path.doc_id);

        if (is_create) try validateRequiredFieldsForCreate(path.table, columns.items);

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = path.table,
            .session_user_id = ctx.request.user_doc_id,
            .session_external_id = ctx.request.external_user_id,
            .session_claims = ctx.request.session_claims,
            .namespace = ctx.request.store_namespace orelse return error.SessionNotReady,
            .doc_id = path.doc_id,
            .value = &value,
            .is_create = is_create,
        });
        errdefer if (store_write) |*p| p.deinit(self.allocator);

        if (has_conditional) try self.mergeReadGuard(ctx, path.table, &store_write);

        try doc_states.put(key, .exists);

        const columns_slice = try columns.toOwnedSlice(self.allocator);

        const op = if (is_create) storage_mod.WriteOp{ .upsert = .{
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = ctx.request.store_namespace_id,
            .owner_doc_id = ctx.request.user_doc_id,
            .columns = columns_slice,
            .guard_predicate = store_write,
            .timestamp = timestamp,
        } } else storage_mod.WriteOp{ .update = .{
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = ctx.request.store_namespace_id,
            .columns = columns_slice,
            .guard_predicate = store_write,
            .precondition_predicate = precondition,
            .timestamp = timestamp,
        } };
        store_write = null;
        precondition = null;
        return op;
    }

    fn buildBatchIncrementEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        field_payload: msgpack.Payload,
        delta_payload: msgpack.Payload,
        if_payload: ?msgpack.Payload,
        timestamp: i64,
    ) !storage_mod.WriteOp {
        const path = try self.parseStorePath(path_payload);
        const field_index = msgpack.extractPayloadUsize(field_payload) orelse return error.InvalidMessageFormat;
        const delta = msgpack.payloadToInt(delta_payload) catch return StorageError.InvalidIncrement;
        try validateIncrementField(path.table, field_index, delta);
        try requireCommittedForConditional(true, ctx.write_id);

        // $value would mean the delta here, while for a set it means the
        // value being written. The resulting value is unknown pre-enqueue, so
        // refuse the ambiguity instead of silently evaluating the delta.
        const rule = self.auth_config.storeRuleFor(path.table.name) orelse return error.AccessDenied;
        if (conditionUsesValueScope(rule.write)) return StorageError.IncrementValueAuthUnsupported;

        var precondition = try self.decodePrecondition(path.table, if_payload);
        errdefer if (precondition) |*p| p.deinit(self.allocator);

        var synthetic_values = [_]msgpack.Payload{ field_payload, delta_payload };
        const synthetic = msgpack.Payload{ .arr = &synthetic_values };

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = path.table,
            .session_user_id = ctx.request.user_doc_id,
            .session_external_id = ctx.request.external_user_id,
            .session_claims = ctx.request.session_claims,
            .namespace = ctx.request.store_namespace orelse return error.SessionNotReady,
            .doc_id = path.doc_id,
            .value = &synthetic,
            .is_create = false,
        });
        errdefer if (store_write) |*p| p.deinit(self.allocator);

        try self.mergeReadGuard(ctx, path.table, &store_write);

        const columns = try self.allocator.alloc(storage_mod.ColumnValue, 0);
        errdefer self.allocator.free(columns);
        const increments = try self.allocator.alloc(storage_mod.IncrementValue, 1);
        errdefer self.allocator.free(increments);
        increments[0] = .{ .field_index = field_index, .delta = delta };

        const op = storage_mod.WriteOp{ .update = .{
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = ctx.request.store_namespace_id,
            .columns = columns,
            .increments = increments,
            .guard_predicate = store_write,
            .precondition_predicate = precondition,
            .timestamp = timestamp,
        } };
        store_write = null;
        precondition = null;
        return op;
    }

    fn buildBatchRemoveEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        if_payload: ?msgpack.Payload,
        timestamp: i64,
        doc_states: *BatchDocStates,
    ) !storage_mod.WriteOp {
        _ = timestamp;
        const path = try self.parseStorePath(path_payload);

        const has_conditional = if_payload != null;
        try requireCommittedForConditional(has_conditional, ctx.write_id);

        var precondition = try self.decodePrecondition(path.table, if_payload);
        errdefer if (precondition) |*p| p.deinit(self.allocator);

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = path.table,
            .session_user_id = ctx.request.user_doc_id,
            .session_external_id = ctx.request.external_user_id,
            .session_claims = ctx.request.session_claims,
            .namespace = ctx.request.store_namespace orelse return error.SessionNotReady,
            .doc_id = path.doc_id,
            .value = null,
            .is_create = false,
        });
        errdefer if (store_write) |*p| p.deinit(self.allocator);

        if (has_conditional) try self.mergeReadGuard(ctx, path.table, &store_write);

        const key = DocKey{ .table_index = path.table_index, .doc_id = path.doc_id };
        try doc_states.put(key, .deleted);

        const op = storage_mod.WriteOp{ .delete = .{
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = ctx.request.store_namespace_id,
            .guard_predicate = store_write,
            .precondition_predicate = precondition,
        } };
        store_write = null;
        precondition = null;
        return op;
    }

    fn decodePrecondition(
        self: *StoreService,
        table: *const schema_types.Table,
        if_payload: ?msgpack.Payload,
    ) !?query_ast.FilterPredicate {
        const payload = if_payload orelse return null;
        return try query_parser.parseWritePrecondition(self.allocator, self.schema, table.index, payload);
    }

    /// Conditional writes require read visibility so `if` cannot be used as a
    /// value oracle on rows the write rule exposes but the read rule hides.
    fn mergeReadGuard(
        self: *StoreService,
        ctx: WriteContext,
        table: *const schema_types.Table,
        write_guard: *?query_ast.FilterPredicate,
    ) !void {
        var read_guard = try authorization_store.authorizeStoreRead(self.allocator, .{
            .config = self.auth_config,
            .table = table,
            .session_user_id = ctx.request.user_doc_id,
            .session_external_id = ctx.request.external_user_id,
            .session_claims = ctx.request.session_claims,
            .namespace = ctx.request.store_namespace orelse return error.SessionNotReady,
        });
        errdefer if (read_guard) |*p| p.deinit(self.allocator);

        if (read_guard) |*rg| {
            if (write_guard.*) |*wg| {
                try query_ast.FilterPredicate.mergeInPlace(wg, self.allocator, rg);
                rg.* = .{};
            } else {
                write_guard.* = rg.*;
                rg.* = .{};
            }
        }
    }
};

fn requireCommittedForConditional(is_conditional: bool, write_id: ?[16]u8) !void {
    if (is_conditional and write_id == null) return error.InvalidWriteAck;
}

fn conditionUsesValueScope(condition: authorization_types.Condition) bool {
    switch (condition) {
        .boolean => return false,
        .logical_and => |conditions| {
            for (conditions) |c| {
                if (conditionUsesValueScope(c)) return true;
            }
            return false;
        },
        .logical_or => |conditions| {
            for (conditions) |c| {
                if (conditionUsesValueScope(c)) return true;
            }
            return false;
        },
        .comparison => |comp| {
            if (comp.lhs.scope == .value) return true;
            if (comp.rhs) |rhs| {
                return switch (rhs) {
                    .context_var => |cv| cv.scope == .value,
                    .literal => false,
                };
            }
            return false;
        },
    }
}

fn validateIncrementField(table: *const schema_types.Table, field_index: usize, delta: i64) !void {
    if (field_index < schema_system.first_user_field_index or
        field_index >= table.fields.len - schema_system.trailing_system_field_count) return StorageError.ImmutableField;

    const field = table.fields[field_index];
    if (field.storage_type != .integer) return StorageError.TypeMismatch;
    if (field.constraints) |constraints| {
        if (constraints.enum_values != null) return StorageError.IncrementNotSupported;
    }

    // Unique constraint indexes are relative to userFields().
    const relative_index = field_index - schema_system.first_user_field_index;
    for (table.unique_constraints) |constraint| {
        for (constraint.field_indexes) |index| {
            if (index == relative_index) return StorageError.IncrementNotSupported;
        }
    }

    if (delta == 0) return StorageError.InvalidIncrement;
}
