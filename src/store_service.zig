const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_types = @import("schema/types.zig");
const schema_parse = @import("schema/parse.zig");
const schema_system = @import("schema/system.zig");
const storage_mod = @import("storage_engine.zig");
const query_parser = @import("query/parser.zig");
const query_ast = @import("query/ast.zig");
const typed_doc_id = @import("typed/doc_id.zig");
const typed_codec = @import("typed/codec.zig");
const typed = @import("typed/types.zig");
const authorization_types = @import("authorization/types.zig");
const authorization_store = @import("authorization/store.zig");
const StorageEngine = storage_mod.StorageEngine;
const StorageError = storage_mod.StorageError;
const ReadKind = storage_mod.ReadKind;
const ReadRequest = storage_mod.ReadRequest;
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

        const field = try validateFieldWrite(table, f_idx, pair_payload.arr[1]);
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
    allocator: Allocator,
    storage_engine: *StorageEngine,
    schema: *const schema_types.Schema,
    auth_config: *const authorization_types.AuthConfig,

    pub fn init(allocator: Allocator, storage_engine: *StorageEngine, schema: *const schema_types.Schema, auth_config: *const authorization_types.AuthConfig) StoreService {
        return .{
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
        var read_req = try self.prepareQueryRead(ctx, table_index, parsed, null, .query);
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
        kind: ReadKind,
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

        const filter = try query_parser.parseQueryFilter(ctx.allocator, self.schema, table_index, parsed);

        return ReadRequest{
            .conn_id = ctx.conn_id,
            .msg_id = ctx.msg_id,
            .kind = kind,
            .table_index = table_index,
            .namespace_id = ctx.namespace_id,
            .filter = filter,
            .auth_predicate = store_read,
            .sub_id = sub_id,
            .allocator = ctx.allocator,
        };
    }

    /// Builds a ReadRequest for a load-more read over an existing subscription.
    /// Clones the subscription's filter, decodes the cursor token, and attaches
    /// it as the filter's `after` anchor.
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

        var store_read = try authorization_store.authorizeStoreRead(ctx.allocator, .{
            .config = self.auth_config,
            .table = table,
            .session_user_id = ctx.session_user_id,
            .session_external_id = ctx.session_external_id,
            .session_claims = ctx.session_claims,
            .namespace = ctx.namespace,
        });
        errdefer if (store_read) |*p| p.deinit(ctx.allocator);

        var filter_clone = try sub_filter.clone(ctx.allocator);
        errdefer filter_clone.deinit(ctx.allocator);

        const cursor = try query_parser.decodeCursorToken(
            ctx.allocator,
            next_cursor,
            filter_clone.order_by.field_type,
            filter_clone.order_by.items_type,
        );
        if (filter_clone.after) |*old| old.deinit(ctx.allocator);
        filter_clone.after = cursor;

        return ReadRequest{
            .conn_id = ctx.conn_id,
            .msg_id = ctx.msg_id,
            .kind = .load_more,
            .table_index = table_index,
            .namespace_id = namespace_id,
            .filter = filter_clone,
            .auth_predicate = store_read,
            .sub_id = sub_id,
            .allocator = ctx.allocator,
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

        var store_write = try authorization_store.authorizeStoreWrite(self.allocator, .{
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

        if (store_write) |*p| {
            if (p.isAlwaysFalse()) {
                p.deinit(self.allocator);
                store_write = null;
                return;
            }
        }

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

        var entries = try self.allocator.alloc(storage_mod.BatchEntry, ops.len);
        var initialized: usize = 0;
        var entries_owned = true;
        errdefer if (entries_owned) {
            for (entries[0..initialized]) |entry| entry.deinit(self.allocator);
            self.allocator.free(entries);
        };

        const timestamp = std.time.timestamp();

        for (ops) |op_payload| {
            if (op_payload != .arr or op_payload.arr.len < 2) return error.InvalidMessageFormat;
            const tuple = op_payload.arr;
            if (tuple[0] != .str) return error.InvalidMessageFormat;
            const kind_str = tuple[0].str.value();

            if (std.mem.eql(u8, kind_str, "s")) {
                if (tuple.len < 3) return error.MissingRequiredFields;
                entries[initialized] = try self.buildBatchSetEntry(ctx, tuple[1], tuple[2], timestamp);
            } else if (std.mem.eql(u8, kind_str, "r")) {
                entries[initialized] = try self.buildBatchRemoveEntry(ctx, tuple[1], timestamp);
            } else {
                return error.InvalidMessageFormat;
            }
            initialized += 1;
        }

        for (entries) |entry| {
            _ = self.schema.tableByIndex(entry.table_index) orelse return StorageError.UnknownTable;
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
                .timestamp = std.time.timestamp(),
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
                .timestamp = std.time.timestamp(),
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
    ) !storage_mod.BatchEntry {
        const path = try self.parseStorePath(path_payload);

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

        return storage_mod.BatchEntry{
            .kind = if (is_create) .upsert else .update,
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = ctx.namespace_id,
            .owner_doc_id = ctx.owner_doc_id,
            .columns = columns_slice,
            .guard_predicate = store_write,
            .timestamp = timestamp,
        };
    }

    fn buildBatchRemoveEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        timestamp: i64,
    ) !storage_mod.BatchEntry {
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

        return storage_mod.BatchEntry{
            .kind = .delete,
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = ctx.namespace_id,
            .owner_doc_id = ctx.owner_doc_id,
            .columns = &[_]storage_mod.ColumnValue{},
            .guard_predicate = store_write,
            .timestamp = timestamp,
        };
    }
};
