const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_mod = @import("schema.zig");
const storage_mod = @import("storage_engine.zig");
const query_parser = @import("query_parser.zig");
const query_ast = @import("query_ast.zig");
const typed = @import("typed.zig");
const authorization = @import("authorization.zig");
const StorageEngine = storage_mod.StorageEngine;
const StorageError = storage_mod.StorageError;
const DocId = typed.DocId;

/// Returns the id value if the filter is a simple `id = ?` point lookup.
fn isIdEqualsFilter(filter: *const query_ast.QueryFilter, id_index: usize) ?DocId {
    // Must have: exactly 1 AND condition, no OR, no order, no cursor
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

/// Validates a single field write operation.
/// Checks for immutability, existence, nullability, and type constraints.
pub fn validateFieldWrite(
    tbl_md: *const schema_mod.Table,
    field_index: usize,
    value: msgpack.Payload,
) !schema_mod.Field {
    if (field_index >= tbl_md.fields.len) return StorageError.UnknownField;

    // Leading system columns and trailing timestamps are immutable.
    // The last two fields are created_at and updated_at, which are also immutable by the client.
    if (field_index < schema_mod.first_user_field_index or
        field_index >= tbl_md.fields.len - 2) return StorageError.ImmutableField;
    const field = tbl_md.fields[field_index];

    if (field.required and value == .nil) return StorageError.NullNotAllowed;

    if (value != .nil) {
        try typed.validateValue(field.storage_type, value);

        if (field.storage_type == .array) {
            if (field.items_type) |items_type| {
                for (value.arr) |item| {
                    typed.validateValue(items_type, item) catch {
                        return StorageError.InvalidArrayElement;
                    };
                }
            }
        }
    }

    return field;
}

fn validateRequiredFieldsForCreate(
    table: *const schema_mod.Table,
    columns: []const storage_mod.ColumnValue,
) !void {
    const user_fields = table.fields[schema_mod.first_user_field_index .. table.fields.len - schema_mod.trailing_system_field_count];
    for (user_fields, schema_mod.first_user_field_index..) |f, f_idx| {
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
    schema: *const schema_mod.Schema,
    auth_config: *const authorization.AuthConfig,

    pub fn init(allocator: Allocator, storage_engine: *StorageEngine, schema: *const schema_mod.Schema, auth_config: *const authorization.AuthConfig) StoreService {
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

    pub const ScopedSession = struct {
        namespace_id: i64,
        user_doc_id: DocId,
    };

    const StorePath = struct {
        table_index: usize,
        table: *const schema_mod.Table,
        doc_id: DocId,
    };

    pub fn tryResolveScopeCached(self: *StoreService, namespace: []const u8, external_user_id: []const u8) !?ScopedSession {
        if (namespace.len == 0) return error.InvalidMessageFormat;
        if (external_user_id.len == 0) return error.InvalidMessageFormat;

        const namespace_id = self.storage_engine.cachedNamespaceId(namespace) orelse return null;
        const users_table = self.schema.table("users") orelse return error.UnknownTable;
        const identity_namespace_id = if (users_table.namespaced) namespace_id else schema_mod.global_namespace_id;
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
    ) !void {
        if (namespace.len == 0 or external_user_id.len == 0) return error.InvalidMessageFormat;
        try self.storage_engine.enqueueSessionResolution(conn_id, msg_id, scope_seq, namespace, external_user_id);
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

        var auth_result = try authorization.authorizeStoreWrite(self.allocator, .{
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
        defer if (auth_result.update_predicate) |*p| p.deinit(self.allocator);
        const auth_predicate_ptr = if (auth_result.update_predicate) |*p| p else null;

        try self.storage_engine.deleteDocument(parsed.table_index, parsed.doc_id, ctx.namespace_id, auth_predicate_ptr, ctx.conn_id, ctx.write_id);
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

        for (ops, 0..) |op_payload, i| {
            _ = i;
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

        entries_owned = false;
        try self.storage_engine.batchWrite(entries, ctx.conn_id, ctx.write_id);
    }

    pub fn queryCollection(
        self: *StoreService,
        allocator: Allocator,
        namespace_id: i64,
        table_index_payload: msgpack.Payload,
        payload: msgpack.Payload,
        auth_predicate: ?*const query_ast.FilterPredicate,
    ) !QueryResult {
        const table_index = msgpack.extractPayloadUint(table_index_payload) orelse return error.InvalidMessageFormat;
        const table = self.schema.getTableByIndex(table_index) orelse return StorageError.UnknownTable;

        var filter = try query_parser.parseQueryFilter(allocator, self.schema, table_index, payload);
        errdefer filter.deinit(allocator);

        if (isIdEqualsFilter(&filter, schema_mod.id_field_index)) |id| {
            var result = try self.storage_engine.selectDocument(allocator, table_index, id, namespace_id, auth_predicate);
            errdefer result.deinit();
            return .{
                .table_index = table_index,
                .table = table,
                .results = result,
                .filter = filter,
                .next_cursor_str = null,
            };
        }

        var results = try self.storage_engine.selectQuery(allocator, table_index, namespace_id, &filter, auth_predicate);
        errdefer {
            results.result.deinit();
            if (results.next_cursor_str) |s| allocator.free(s);
        }
        return .{
            .table_index = table_index,
            .table = table,
            .results = results.result,
            .filter = filter,
            .next_cursor_str = results.next_cursor_str,
        };
    }

    pub fn queryMore(
        self: *StoreService,
        allocator: Allocator,
        table_index: usize,
        namespace_id: i64,
        filter: *query_ast.QueryFilter,
        next_cursor: []const u8,
        auth_predicate: ?*const query_ast.FilterPredicate,
    ) !CursorResult {
        const table = self.schema.getTableByIndex(table_index) orelse return StorageError.UnknownTable;
        const cursor = try query_parser.decodeCursorToken(allocator, next_cursor, filter.order_by.field_type, filter.order_by.items_type);

        if (filter.after) |*old| old.deinit(allocator);
        filter.after = cursor;

        var results = try self.storage_engine.selectQuery(allocator, table_index, namespace_id, filter, auth_predicate);
        errdefer {
            results.result.deinit();
            if (results.next_cursor_str) |s| allocator.free(s);
        }
        return .{
            .table = table,
            .results = results.result,
            .next_cursor_str = results.next_cursor_str,
        };
    }

    fn parseStorePath(
        self: *StoreService,
        payload: msgpack.Payload,
    ) !StorePath {
        if (payload != .arr) return error.InvalidMessageFormat;

        const path = payload.arr;
        if (path.len != 2) return StorageError.InvalidPath;

        const table_index = msgpack.extractPayloadUint(path[0]) orelse return error.InvalidMessageFormat;
        const table = self.schema.getTableByIndex(table_index) orelse return StorageError.UnknownTable;

        if (path[1] != .bin) return error.InvalidMessageFormat;
        const parsed_doc_id = try typed.docIdFromBytes(path[1].bin.value());

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
        if (value != .map) return error.InvalidPayload;

        var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue).empty;
        defer {
            for (columns.items) |col| col.value.deinit(self.allocator);
            columns.deinit(self.allocator);
        }

        var it = value.map.iterator();
        while (it.next()) |entry| {
            const f_idx = blk: {
                if (msgpack.extractPayloadUint(entry.key_ptr.*)) |idx| break :blk idx;
                if (entry.key_ptr.* == .str) {
                    const key_str = entry.key_ptr.*.str.value();
                    break :blk std.fmt.parseUnsigned(usize, key_str, 10) catch return StorageError.UnknownField;
                }
                return StorageError.UnknownField;
            };

            const field = try validateFieldWrite(path.table, f_idx, entry.value_ptr.*);
            const typed_value = try typed.valueFromPayload(self.allocator, field.storage_type, field.items_type, entry.value_ptr.*);

            try columns.append(self.allocator, .{
                .index = f_idx,
                .value = typed_value,
            });
        }

        const is_create = !self.storage_engine.documentExists(path.table_index, path.doc_id);

        if (is_create) try validateRequiredFieldsForCreate(path.table, columns.items);

        var auth_result = try authorization.authorizeStoreWrite(self.allocator, .{
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
        defer if (auth_result.update_predicate) |*p| p.deinit(self.allocator);
        const auth_predicate_ptr = if (auth_result.update_predicate) |*p| p else null;

        if (is_create) {
            try self.storage_engine.upsertDocument(path.table_index, path.doc_id, ctx.namespace_id, ctx.owner_doc_id, columns.items, auth_predicate_ptr, ctx.conn_id, ctx.write_id);
        } else {
            try self.storage_engine.updateDocument(path.table_index, path.doc_id, ctx.namespace_id, columns.items, auth_predicate_ptr, ctx.conn_id, ctx.write_id);
        }
    }

    fn buildBatchSetEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        value: msgpack.Payload,
        timestamp: i64,
    ) !storage_mod.BatchEntry {
        const path = try self.parseStorePath(path_payload);

        if (value != .map) return error.InvalidPayload;

        var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue).empty;
        defer {
            for (columns.items) |col| col.value.deinit(self.allocator);
            columns.deinit(self.allocator);
        }

        var it = value.map.iterator();
        while (it.next()) |entry| {
            const f_idx = blk: {
                if (msgpack.extractPayloadUint(entry.key_ptr.*)) |idx| break :blk idx;
                if (entry.key_ptr.* == .str) {
                    const key_str = entry.key_ptr.*.str.value();
                    break :blk std.fmt.parseUnsigned(usize, key_str, 10) catch return StorageError.UnknownField;
                }
                return StorageError.UnknownField;
            };

            const field = try validateFieldWrite(path.table, f_idx, entry.value_ptr.*);
            const typed_value = try typed.valueFromPayload(self.allocator, field.storage_type, field.items_type, entry.value_ptr.*);

            try columns.append(self.allocator, .{
                .index = f_idx,
                .value = typed_value,
            });
        }

        const is_create = !self.storage_engine.documentExists(path.table_index, path.doc_id);

        if (is_create) try validateRequiredFieldsForCreate(path.table, columns.items);

        var auth_result = try authorization.authorizeStoreWrite(self.allocator, .{
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
        defer if (auth_result.update_predicate) |*p| p.deinit(self.allocator);
        const auth_predicate_ptr = if (auth_result.update_predicate) |*p| p else null;

        if (is_create) {
            return try self.storage_engine.prepareBatchUpsert(
                path.table_index,
                path.doc_id,
                ctx.namespace_id,
                ctx.owner_doc_id,
                columns.items,
                auth_predicate_ptr,
                timestamp,
            );
        } else {
            return try self.storage_engine.prepareBatchUpdate(
                path.table_index,
                path.doc_id,
                ctx.namespace_id,
                columns.items,
                auth_predicate_ptr,
                timestamp,
            );
        }
    }

    fn buildBatchRemoveEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        timestamp: i64,
    ) !storage_mod.BatchEntry {
        const path = try self.parseStorePath(path_payload);

        var auth_result = try authorization.authorizeStoreWrite(self.allocator, .{
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
        defer if (auth_result.update_predicate) |*p| p.deinit(self.allocator);
        const auth_predicate_ptr = if (auth_result.update_predicate) |*p| p else null;

        return try self.storage_engine.prepareBatchDelete(
            path.table_index,
            path.doc_id,
            ctx.namespace_id,
            ctx.owner_doc_id,
            auth_predicate_ptr,
            timestamp,
        );
    }
};

pub const QueryResult = struct {
    table_index: usize,
    table: *const schema_mod.Table,
    results: storage_mod.ManagedResult,
    filter: query_ast.QueryFilter,
    next_cursor_str: ?[]const u8 = null,

    pub fn deinit(self: *QueryResult, allocator: Allocator) void {
        self.results.deinit();
        self.filter.deinit(allocator);
        if (self.next_cursor_str) |s| allocator.free(s);
    }
};

pub const CursorResult = struct {
    table: *const schema_mod.Table,
    results: storage_mod.ManagedResult,
    next_cursor_str: ?[]const u8 = null,

    pub fn deinit(self: *CursorResult, allocator: Allocator) void {
        self.results.deinit();
        if (self.next_cursor_str) |s| allocator.free(s);
    }
};
