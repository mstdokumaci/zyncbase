const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema = @import("schema.zig");
const storage_mod = @import("storage_engine.zig");
const query_parser = @import("query_parser.zig");
const doc_id_utils = @import("doc_id.zig");
const StorageEngine = storage_mod.StorageEngine;
const StorageError = storage_mod.StorageError;
const DocId = storage_mod.DocId;

/// Returns the id value if the filter is a simple `id = ?` point lookup.
fn isIdEqualsFilter(filter: query_parser.QueryFilter, id_index: usize) ?DocId {
    // Must have: exactly 1 AND condition, no OR, no order, no cursor
    const conds = filter.conditions orelse return null;
    if (conds.len != 1) return null;
    if (filter.or_conditions != null) return null;
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
    tbl_md: *const schema.Table,
    field_index: usize,
    value: msgpack.Payload,
) !schema.Field {
    if (field_index >= tbl_md.fields.len) return StorageError.UnknownField;

    // Leading system columns and trailing timestamps are immutable.
    // The last two fields are created_at and updated_at, which are also immutable by the client.
    if (field_index < schema.first_user_field_index or
        field_index >= tbl_md.fields.len - 2) return StorageError.ImmutableField;
    const field = tbl_md.fields[field_index];

    if (field.required and value == .nil) return StorageError.NullNotAllowed;

    if (value != .nil) {
        try storage_mod.validateTypedValuePayload(field.storage_type, value);

        if (field.storage_type == .array) {
            if (field.items_type) |items_type| {
                for (value.arr) |item| {
                    storage_mod.validateTypedValuePayload(items_type, item) catch {
                        return StorageError.InvalidArrayElement;
                    };
                }
            }
        }
    }

    return field;
}

/// StoreService provides a domain-level facade for storage operations.
/// It encapsulates schema validation, path resolution, and ColumnValue construction.
pub const StoreService = struct {
    allocator: Allocator,
    storage_engine: *StorageEngine,
    schema_manager: *const schema.Schema,

    pub fn init(allocator: Allocator, storage_engine: *StorageEngine, sm: *const schema.Schema) StoreService {
        return .{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .schema_manager = sm,
        };
    }

    pub fn deinit(_: *StoreService) void {}

    pub const WriteContext = struct {
        namespace_id: i64,
        owner_doc_id: DocId,
    };

    pub const ScopedSession = struct {
        namespace_id: i64,
        user_doc_id: DocId,
    };

    const PathKind = enum {
        document_or_field,
        document_only,
    };

    const StorePath = struct {
        table_index: usize,
        table: *const schema.Table,
        doc_id: DocId,
        segments_len: usize,
        field_index: ?usize,
    };

    pub fn resolveNamespace(self: *StoreService, namespace: []const u8) !i64 {
        if (namespace.len == 0) return error.InvalidMessageFormat;
        return (try self.storage_engine.lookupNamespaceId(namespace)) orelse try self.storage_engine.resolveNamespaceId(namespace);
    }

    pub fn resolveStoreScope(self: *StoreService, namespace: []const u8, external_user_id: []const u8) !ScopedSession {
        if (external_user_id.len == 0) return error.InvalidMessageFormat;

        const namespace_id = try self.resolveNamespace(namespace);
        const users_table = self.schema_manager.table("users") orelse return error.UnknownTable;
        const identity_namespace_id = if (users_table.namespaced) namespace_id else schema.global_namespace_id;
        const user_doc_id = try self.storage_engine.resolveUserId(identity_namespace_id, external_user_id);

        return .{
            .namespace_id = namespace_id,
            .user_doc_id = user_doc_id,
        };
    }

    pub fn setPath(
        self: *StoreService,
        ctx: WriteContext,
        path: msgpack.Payload,
        value: msgpack.Payload,
    ) !void {
        const parsed = try self.parseStorePath(path, .document_or_field);
        try self.applySet(parsed, ctx, value);
    }

    pub fn removePath(
        self: *StoreService,
        ctx: WriteContext,
        path: msgpack.Payload,
    ) !void {
        const parsed = try self.parseStorePath(path, .document_only);
        try self.storage_engine.deleteDocument(parsed.table_index, parsed.doc_id, ctx.namespace_id);
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

        entries_owned = false;
        try self.storage_engine.batchWrite(entries);
    }

    pub fn queryCollection(
        self: *StoreService,
        allocator: Allocator,
        namespace_id: i64,
        table_index_payload: msgpack.Payload,
        payload: msgpack.Payload,
    ) !QueryResult {
        const table_index = msgpack.extractPayloadUint(table_index_payload) orelse return error.InvalidMessageFormat;
        const table = self.schema_manager.getTableByIndex(table_index) orelse return StorageError.UnknownTable;

        const filter = try query_parser.parseQueryFilter(allocator, self.schema_manager, table_index, payload);
        errdefer filter.deinit(allocator);

        if (isIdEqualsFilter(filter, schema.id_field_index)) |id| {
            var result = try self.storage_engine.selectDocument(allocator, table_index, id, namespace_id);
            errdefer result.deinit();
            return .{
                .table_index = table_index,
                .table = table,
                .results = result,
                .filter = filter,
                .next_cursor_str = null,
            };
        }

        var results = try self.storage_engine.selectQuery(allocator, table_index, namespace_id, filter);
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
        filter: *query_parser.QueryFilter,
        next_cursor: []const u8,
    ) !CursorResult {
        const table = self.schema_manager.getTableByIndex(table_index) orelse return StorageError.UnknownTable;
        const cursor = try query_parser.decodeCursorToken(allocator, next_cursor, filter.order_by.field_type, filter.order_by.items_type);

        if (filter.after) |*old| old.deinit(allocator);
        filter.after = cursor;

        var results = try self.storage_engine.selectQuery(allocator, table_index, namespace_id, filter.*);
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
        kind: PathKind,
    ) !StorePath {
        if (payload != .arr) return error.InvalidMessageFormat;

        const path = payload.arr;
        switch (kind) {
            .document_or_field => if (path.len != 2 and path.len != 3) return StorageError.InvalidPath,
            .document_only => if (path.len != 2) return StorageError.InvalidPath,
        }

        const table_index = msgpack.extractPayloadUint(path[0]) orelse return error.InvalidMessageFormat;
        const table = self.schema_manager.getTableByIndex(table_index) orelse return StorageError.UnknownTable;

        if (path[1] != .bin) return error.InvalidMessageFormat;
        const parsed_doc_id = try doc_id_utils.fromBytes(path[1].bin.value());

        const field_index: ?usize = if (path.len == 3) blk: {
            const index = msgpack.extractPayloadUint(path[2]) orelse return error.InvalidMessageFormat;
            if (index >= table.fields.len) return StorageError.UnknownField;
            break :blk index;
        } else null;

        return .{
            .table_index = table_index,
            .table = table,
            .doc_id = parsed_doc_id,
            .segments_len = path.len,
            .field_index = field_index,
        };
    }

    fn applySet(
        self: *StoreService,
        path: StorePath,
        ctx: WriteContext,
        value: msgpack.Payload,
    ) !void {
        if (path.segments_len == 2) {
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
                const typed = try storage_mod.typedValueFromPayload(self.allocator, field.storage_type, field.items_type, entry.value_ptr.*);

                try columns.append(self.allocator, .{
                    .index = f_idx,
                    .value = typed,
                });
            }

            try self.storage_engine.insertOrReplace(path.table_index, path.doc_id, ctx.namespace_id, ctx.owner_doc_id, columns.items);
        } else if (path.segments_len == 3) {
            const f_index = path.field_index orelse return StorageError.InvalidPath;
            const field = try validateFieldWrite(path.table, f_index, value);
            const typed = try storage_mod.typedValueFromPayload(self.allocator, field.storage_type, field.items_type, value);
            defer typed.deinit(self.allocator);

            const col = [_]storage_mod.ColumnValue{.{
                .index = f_index,
                .value = typed,
            }};
            try self.storage_engine.insertOrReplace(path.table_index, path.doc_id, ctx.namespace_id, ctx.owner_doc_id, &col);
        } else {
            return StorageError.InvalidPath;
        }
    }

    fn buildBatchSetEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        value: msgpack.Payload,
        timestamp: i64,
    ) !storage_mod.BatchEntry {
        const path = try self.parseStorePath(path_payload, .document_or_field);

        var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue).empty;
        errdefer {
            for (columns.items) |col| col.value.deinit(self.allocator);
            columns.deinit(self.allocator);
        }

        if (path.segments_len == 2) {
            if (value != .map) return error.InvalidPayload;

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
                const typed = try storage_mod.typedValueFromPayload(self.allocator, field.storage_type, field.items_type, entry.value_ptr.*);

                try columns.append(self.allocator, .{
                    .index = f_idx,
                    .value = typed,
                });
            }
        } else if (path.segments_len == 3) {
            const f_index = path.field_index orelse return StorageError.InvalidPath;
            const field = try validateFieldWrite(path.table, f_index, value);
            const typed = try storage_mod.typedValueFromPayload(self.allocator, field.storage_type, field.items_type, value);

            try columns.append(self.allocator, .{
                .index = f_index,
                .value = typed,
            });
        } else {
            return StorageError.InvalidPath;
        }

        const sql_string = try @import("storage_engine/sql.zig").buildInsertOrReplaceSql(self.allocator, path.table, columns.items);
        errdefer self.allocator.free(sql_string);

        const values = try self.allocator.alloc(storage_mod.TypedValue, columns.items.len);
        for (columns.items, 0..) |col, i| {
            values[i] = col.value;
        }
        columns.deinit(self.allocator);

        const effective_namespace_id = if (path.table.namespaced) ctx.namespace_id else schema.global_namespace_id;

        return .{
            .kind = .upsert,
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = effective_namespace_id,
            .owner_doc_id = ctx.owner_doc_id,
            .sql = sql_string,
            .values = values,
            .timestamp = timestamp,
        };
    }

    fn buildBatchRemoveEntry(
        self: *StoreService,
        ctx: WriteContext,
        path_payload: msgpack.Payload,
        timestamp: i64,
    ) !storage_mod.BatchEntry {
        const path = try self.parseStorePath(path_payload, .document_only);

        const sql_string = try @import("storage_engine/sql.zig").buildDeleteDocumentSql(self.allocator, path.table);
        errdefer self.allocator.free(sql_string);

        const effective_namespace_id = if (path.table.namespaced) ctx.namespace_id else schema.global_namespace_id;

        return .{
            .kind = .delete,
            .table_index = path.table_index,
            .id = path.doc_id,
            .namespace_id = effective_namespace_id,
            .owner_doc_id = ctx.owner_doc_id,
            .sql = sql_string,
            .values = null,
            .timestamp = timestamp,
        };
    }
};

pub const QueryResult = struct {
    table_index: usize,
    table: *const schema.Table,
    results: storage_mod.ManagedResult,
    filter: query_parser.QueryFilter,
    next_cursor_str: ?[]const u8 = null,

    pub fn deinit(self: *QueryResult, allocator: Allocator) void {
        self.results.deinit();
        self.filter.deinit(allocator);
        if (self.next_cursor_str) |s| allocator.free(s);
    }
};

pub const CursorResult = struct {
    table: *const schema.Table,
    results: storage_mod.ManagedResult,
    next_cursor_str: ?[]const u8 = null,

    pub fn deinit(self: *CursorResult, allocator: Allocator) void {
        self.results.deinit();
        if (self.next_cursor_str) |s| allocator.free(s);
    }
};
