const std = @import("std");

const authorization_store = @import("authorization/store.zig");
const authorization_types = @import("authorization/types.zig");
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
const typed = @import("typed/types.zig");

const Allocator = std.mem.Allocator;
const ReadRequest = storage_mod.ReadRequest;
const StorageEngine = storage_mod.StorageEngine;
const StorageError = storage_mod.StorageError;
const DocId = typed_doc_id.DocId;

/// Decode a pair-array payload into a deduplicated list of column values.
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

    var seen = std.StaticBitSet(schema_parse.max_store_fields).initEmpty();
    var pair_i: usize = value.arr.len;
    while (pair_i > 0) {
        pair_i -= 1;
        const pair_payload = value.arr[pair_i];
        if (pair_payload != .arr or pair_payload.arr.len != 2) return error.InvalidPayload;
        const f_idx = msgpack.extractPayloadUsize(pair_payload.arr[0]) orelse return error.InvalidPayload;
        if (f_idx < schema_parse.max_store_fields) {
            if (seen.isSet(f_idx)) continue;
            seen.set(f_idx);
        }

        const field = try validateFieldWrite(allocator, table, f_idx, pair_payload.arr[1]);
        const typed_value = try typed_codec.fromPayload(allocator, field.storage_type, field.items_type, pair_payload.arr[1]);

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
        namespace_id: i64,
        namespace: []const u8,
        owner_doc_id: DocId,
        session_user_id: DocId,
        session_external_id: ?[]const u8 = null,
        session_claims: ?*const std.StringHashMapUnmanaged(typed.Value) = null,
        conn_id: ?u64 = null,
        write_id: ?[16]u8 = null,
    };

    pub const ReadContext = struct {
        conn_id: u64,
        msg_id: u64,
        session_user_id: DocId,
        session_external_id: ?[]const u8,
        session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
        namespace: []const u8,
        namespace_id: i64,
        allocator: Allocator,
    };

    pub const ScopedSession = struct {
        namespace_id: i64,
        user_doc_id: DocId,
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

    pub fn tryResolveScopeCached(self: *StoreService, namespace: []const u8, external_user_id: []const u8) !?ScopedSession {
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
            .session_user_id = ctx.session_user_id,
            .session_external_id = ctx.session_external_id,
            .session_claims = ctx.session_claims,
            .namespace = ctx.namespace,
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
            .conn_id = ctx.conn_id,
            .msg_id = ctx.msg_id,
            .table_index = table_index,
            .namespace_id = ctx.namespace_id,
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
            .conn_id = ctx.conn_id,
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
    ) !void {
        const parsed = try self.parseStorePath(path);
        try self.applySet(parsed, ctx, value);
    }

    pub fn removePath(
        self: *StoreService,
        ctx: WriteContext,
        path: msgpack.Payload,
    ) !void {
        const parsed = try self.parseStorePath(path);

        const store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = parsed.table,
            .session_user_id = ctx.session_user_id,
            .session_external_id = ctx.session_external_id,
            .session_claims = ctx.session_claims,
            .namespace = ctx.namespace,
            .doc_id = parsed.doc_id,
            .value = null,
            .is_create = false,
        });

        const op = storage_mod.WriteOp{
            .delete = .{
                .table_index = parsed.table_index,
                .id = parsed.doc_id,
                .namespace_id = ctx.namespace_id,
                .guard_predicate = store_write,
                .conn_id = ctx.conn_id,
                .write_id = ctx.write_id,
            },
        };
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

        const timestamp = std.Io.Clock.real.now(self.io).toSeconds();

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
                .conn_id = ctx.conn_id,
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
            return self.buildBatchSetEntry(ctx, tuple[1], tuple[2], timestamp, doc_states);
        }
        if (std.mem.eql(u8, kind, "r")) {
            return self.buildBatchRemoveEntry(ctx, tuple[1], timestamp, doc_states);
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
    ) !void {
        if (value != .arr) return error.InvalidPayload;

        var columns = try decodeColumnsFromPairs(self.allocator, path.table, value);
        errdefer {
            for (columns.items) |col| col.value.deinit(self.allocator);
            columns.deinit(self.allocator);
        }

        const is_create = !self.storage_engine.documentExists(path.table_index, path.doc_id);

        if (is_create) try validateRequiredFieldsForCreate(path.table, columns.items);

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = path.table,
            .session_user_id = ctx.session_user_id,
            .session_external_id = ctx.session_external_id,
            .session_claims = ctx.session_claims,
            .namespace = ctx.namespace,
            .doc_id = path.doc_id,
            .value = &value,
            .is_create = is_create,
        });

        const columns_slice = columns.toOwnedSlice(self.allocator) catch |err| {
            if (store_write) |*p| p.deinit(self.allocator);
            return err;
        };

        const op = if (is_create) storage_mod.WriteOp{
            .upsert = .{
                .table_index = path.table_index,
                .id = path.doc_id,
                .namespace_id = ctx.namespace_id,
                .owner_doc_id = ctx.owner_doc_id,
                .columns = columns_slice,
                .guard_predicate = store_write,
                .timestamp = std.Io.Clock.real.now(self.io).toSeconds(),
                .conn_id = ctx.conn_id,
                .write_id = ctx.write_id,
            },
        } else storage_mod.WriteOp{
            .update = .{
                .table_index = path.table_index,
                .id = path.doc_id,
                .namespace_id = ctx.namespace_id,
                .columns = columns_slice,
                .guard_predicate = store_write,
                .timestamp = std.Io.Clock.real.now(self.io).toSeconds(),
                .conn_id = ctx.conn_id,
                .write_id = ctx.write_id,
            },
        };
        errdefer op.deinit(self.allocator);

        try self.storage_engine.enqueueWriteOp(op);
    }

    fn buildBatchSetEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        value: msgpack.Payload,
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

        const key = DocKey{ .table_index = path.table_index, .doc_id = path.doc_id };
        const effective_state = doc_states.get(key);
        const is_create = if (effective_state) |state|
            state == .deleted
        else
            !self.storage_engine.documentExists(path.table_index, path.doc_id);

        if (is_create) try validateRequiredFieldsForCreate(path.table, columns.items);

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = path.table,
            .session_user_id = ctx.session_user_id,
            .session_external_id = ctx.session_external_id,
            .session_claims = ctx.session_claims,
            .namespace = ctx.namespace,
            .doc_id = path.doc_id,
            .value = &value,
            .is_create = is_create,
        });
        errdefer if (store_write) |*p| p.deinit(self.allocator);

        try doc_states.put(key, .exists);

        const columns_slice = try columns.toOwnedSlice(self.allocator);

        if (is_create) {
            return storage_mod.WriteOp{ .upsert = .{
                .table_index = path.table_index,
                .id = path.doc_id,
                .namespace_id = ctx.namespace_id,
                .owner_doc_id = ctx.owner_doc_id,
                .columns = columns_slice,
                .guard_predicate = store_write,
                .timestamp = timestamp,
            } };
        } else {
            return storage_mod.WriteOp{ .update = .{
                .table_index = path.table_index,
                .id = path.doc_id,
                .namespace_id = ctx.namespace_id,
                .columns = columns_slice,
                .guard_predicate = store_write,
                .timestamp = timestamp,
            } };
        }
    }

    fn buildBatchRemoveEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        timestamp: i64,
        doc_states: *BatchDocStates,
    ) !storage_mod.WriteOp {
        _ = timestamp;
        const path = try self.parseStorePath(path_payload);

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
            .config = self.auth_config,
            .table = path.table,
            .session_user_id = ctx.session_user_id,
            .session_external_id = ctx.session_external_id,
            .session_claims = ctx.session_claims,
            .namespace = ctx.namespace,
            .doc_id = path.doc_id,
            .value = null,
            .is_create = false,
        });
        errdefer if (store_write) |*p| p.deinit(self.allocator);

        const key = DocKey{ .table_index = path.table_index, .doc_id = path.doc_id };
        try doc_states.put(key, .deleted);

        return storage_mod.WriteOp{ .delete = .{
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = ctx.namespace_id,
            .guard_predicate = store_write,
        } };
    }
};
