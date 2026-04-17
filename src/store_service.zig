const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const storage_mod = @import("storage_engine.zig");
const query_parser = @import("query_parser.zig");
const StorageEngine = storage_mod.StorageEngine;
const StorageError = storage_mod.StorageError;

/// Returns the id value if the filter is a simple `id = ?` point lookup.
fn isIdEqualsFilter(filter: query_parser.QueryFilter) ?[]const u8 {
    // Must have: exactly 1 AND condition, no OR, no order, no cursor
    const conds = filter.conditions orelse return null;
    if (conds.len != 1) return null;
    if (filter.or_conditions != null) return null;
    if (!std.mem.eql(u8, filter.order_by.field, "id") or filter.order_by.desc) return null;
    if (filter.after != null) return null;

    const cond = conds[0];
    if (cond.op != .eq) return null;
    if (!std.mem.eql(u8, cond.field, "id")) return null;

    // Extract string value
    const val = cond.value orelse return null;
    return val.scalar.text;
}

/// Validates a single field write operation.
/// Checks for immutability, existence, nullability, and type constraints.
pub fn validateFieldWrite(
    tbl_md: *const schema_manager.TableMetadata,
    field_name: []const u8,
    value: msgpack.Payload,
) !schema_manager.Field {
    if (schema_manager.isSystemColumn(field_name)) return StorageError.ImmutableField;

    const field = tbl_md.getField(field_name) orelse return StorageError.UnknownField;

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
        table: []const u8,
        doc_id: []const u8,
        namespace: []const u8,
        segments_len: usize,
        field_name: ?[]const u8,
        value: msgpack.Payload,
    ) !void {
        const tbl_md = self.schema_manager.getTable(table) orelse return StorageError.UnknownTable;

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
                if (entry.key_ptr.* != .str) continue;
                const fn_inner = entry.key_ptr.*.str.value();

                const field = try validateFieldWrite(tbl_md, fn_inner, entry.value_ptr.*);
                const typed = try storage_mod.TypedValue.fromPayload(self.allocator, field.sql_type, field.items_type, entry.value_ptr.*);

                try columns.append(self.allocator, .{
                    .name = fn_inner,
                    .value = typed,
                    .field_type = field.sql_type,
                });
            }

            try self.storage_engine.insertOrReplace(table, doc_id, namespace, columns.items);
        } else if (segments_len == 3) {
            // Partial update / field-level update
            const fn_inner = field_name orelse return StorageError.InvalidPath;
            const field = try validateFieldWrite(tbl_md, fn_inner, value);
            const typed = try storage_mod.TypedValue.fromPayload(self.allocator, field.sql_type, field.items_type, value);
            defer typed.deinit(self.allocator);

            const col = [_]storage_mod.ColumnValue{.{
                .name = fn_inner,
                .value = typed,
                .field_type = field.sql_type,
            }};
            try self.storage_engine.insertOrReplace(table, doc_id, namespace, &col);
        } else {
            return StorageError.InvalidPath;
        }
    }

    /// Remove a value at a path.
    /// Handles document deletion (path len 2). Field-level removal is not supported (use set to null).
    pub fn remove(
        self: *StoreService,
        table: []const u8,
        doc_id: []const u8,
        namespace: []const u8,
        segments_len: usize,
        field_name: ?[]const u8,
    ) !void {
        _ = field_name;
        try self.schema_manager.validateTable(table);

        if (segments_len == 2) {
            try self.storage_engine.deleteDocument(table, doc_id, namespace);
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
        collection: []const u8,
        namespace: []const u8,
        payload: msgpack.Payload,
    ) !QueryResult {
        const filter = try query_parser.parseQueryFilter(allocator, self.schema_manager, collection, payload);
        errdefer filter.deinit(allocator);

        if (isIdEqualsFilter(filter)) |id| {
            // Fast path: use selectDocument with cache
            const result = try self.storage_engine.selectDocument(allocator, collection, id, namespace);
            return QueryResult{
                .results = result,
                .filter = filter,
            };
        }

        const results = try self.storage_engine.selectQuery(allocator, collection, namespace, filter);
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
        collection: []const u8,
        namespace: []const u8,
        filter: *query_parser.QueryFilter,
        cursor: query_parser.Cursor,
    ) !storage_mod.ManagedResult {
        if (filter.after) |*old| old.deinit(allocator);
        filter.after = cursor;

        return try self.storage_engine.selectQuery(allocator, collection, namespace, filter.*);
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
