const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const storage_mod = @import("storage_engine.zig");
const query_parser = @import("query_parser.zig");
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
    tbl_md: *const schema_manager.TableMetadata,
    field_index: usize,
    value: msgpack.Payload,
) !schema_manager.Field {
    if (field_index >= tbl_md.fields.len) return StorageError.UnknownField;

    // Leading system columns and trailing timestamps are immutable.
    // The last two fields are created_at and updated_at, which are also immutable by the client.
    if (field_index < schema_manager.first_user_field_index or
        field_index >= tbl_md.fields.len - 2) return StorageError.ImmutableField;
    const field = tbl_md.fields[field_index];

    if (field.required and value == .nil) return StorageError.NullNotAllowed;

    if (value != .nil) {
        try storage_mod.TypedValue.validateValue(field.sql_type, value);

        if (field.sql_type == .array) {
            if (field.items_type) |items_type| {
                for (value.arr) |item| {
                    storage_mod.TypedValue.validateValue(items_type, item) catch {
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
    schema_manager: *const schema_manager.SchemaManager,

    pub fn init(allocator: Allocator, storage_engine: *StorageEngine, sm: *const schema_manager.SchemaManager) StoreService {
        return .{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .schema_manager = sm,
        };
    }

    pub fn deinit(_: *StoreService) void {}

    /// Set a value at a path.
    /// Handles both full-document replacement (path len 2) and field-level updates (path len 3).
    pub fn set(
        self: *StoreService,
        table_index: usize,
        doc_id: DocId,
        namespace_id: i64,
        owner_doc_id: DocId,
        segments_len: usize,
        field_index: ?usize,
        value: msgpack.Payload,
    ) !void {
        const tbl_md = self.schema_manager.getTableByIndex(table_index) orelse return StorageError.UnknownTable;

        if (segments_len == 2) {
            // Full document replacement
            if (value != .map) return error.InvalidPayload;

            // Validate schema and construct columns in a single pass
            var columns = std.ArrayListUnmanaged(storage_mod.ColumnValue).empty;
            defer {
                for (columns.items) |col| col.value.deinit(self.allocator);
                columns.deinit(self.allocator);
            }

            var it = value.map.iterator();
            while (it.next()) |entry| {
                // Value map keys are field indices. Accept both integer keys and numeric strings
                // because JS objects in MessagePack decode with string keys.
                const f_idx = blk: {
                    if (msgpack.extractPayloadUint(entry.key_ptr.*)) |idx| break :blk idx;
                    if (entry.key_ptr.* == .str) {
                        const key_str = entry.key_ptr.*.str.value();
                        break :blk std.fmt.parseUnsigned(usize, key_str, 10) catch return StorageError.UnknownField;
                    }
                    return StorageError.UnknownField;
                };

                const field = try validateFieldWrite(tbl_md, f_idx, entry.value_ptr.*);
                const typed = try storage_mod.TypedValue.fromPayload(self.allocator, field.sql_type, field.items_type, entry.value_ptr.*);

                try columns.append(self.allocator, .{
                    .index = f_idx,
                    .value = typed,
                });
            }

            try self.storage_engine.insertOrReplace(table_index, doc_id, namespace_id, owner_doc_id, columns.items);
        } else if (segments_len == 3) {
            // Partial update / field-level update
            const f_index = field_index orelse return StorageError.InvalidPath;
            const field = try validateFieldWrite(tbl_md, f_index, value);
            const typed = try storage_mod.TypedValue.fromPayload(self.allocator, field.sql_type, field.items_type, value);
            defer typed.deinit(self.allocator);

            const col = [_]storage_mod.ColumnValue{.{
                .index = f_index,
                .value = typed,
            }};
            try self.storage_engine.insertOrReplace(table_index, doc_id, namespace_id, owner_doc_id, &col);
        } else {
            return StorageError.InvalidPath;
        }
    }

    /// Remove a value at a path.
    /// Handles document deletion (path len 2). Field-level removal is not supported (use set to null).
    pub fn remove(
        self: *StoreService,
        table_index: usize,
        doc_id: DocId,
        namespace_id: i64,
        segments_len: usize,
    ) !void {
        _ = self.schema_manager.getTableByIndex(table_index) orelse return StorageError.UnknownTable;

        if (segments_len == 2) {
            try self.storage_engine.deleteDocument(table_index, doc_id, namespace_id);
        } else {
            return StorageError.InvalidPath;
        }
    }

    /// Execute a filtered query against a collection.
    /// Returns both the results and the parsed QueryFilter.
    /// The caller owns the returned QueryResult and must call deinit().
    pub fn query(
        self: *StoreService,
        allocator: Allocator,
        table_index: usize,
        namespace_id: i64,
        payload: msgpack.Payload,
    ) !QueryResult {
        const filter = try query_parser.parseQueryFilter(allocator, self.schema_manager, table_index, payload);
        errdefer filter.deinit(allocator);

        if (isIdEqualsFilter(filter, schema_manager.id_field_index)) |id| {
            // Fast path: use selectDocument with cache
            const result = try self.storage_engine.selectDocument(allocator, table_index, id, namespace_id);
            return QueryResult{
                .results = result,
                .filter = filter,
            };
        }

        const results = try self.storage_engine.selectQuery(allocator, table_index, namespace_id, filter);
        return QueryResult{
            .results = results,
            .filter = filter,
        };
    }

    /// Execute a query with an existing filter and apply a cursor.
    /// The caller is responsible for parsing the cursor from the wire format.
    pub fn queryWithCursor(
        self: *StoreService,
        allocator: Allocator,
        table_index: usize,
        namespace_id: i64,
        filter: *query_parser.QueryFilter,
        cursor: query_parser.Cursor,
    ) !storage_mod.ManagedResult {
        if (filter.after) |*old| old.deinit(allocator);
        filter.after = cursor;

        return try self.storage_engine.selectQuery(allocator, table_index, namespace_id, filter.*);
    }
};

pub const QueryResult = struct {
    results: storage_mod.ManagedResult,
    filter: query_parser.QueryFilter,

    pub fn deinit(self: *QueryResult, allocator: Allocator) void {
        self.results.deinit();
        self.filter.deinit(allocator);
    }
};
