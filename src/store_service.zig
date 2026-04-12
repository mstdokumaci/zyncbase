const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const storage_mod = @import("storage_engine/types.zig");
const write_command = @import("storage_engine/write_command.zig");
const query_parser = @import("query_parser.zig");
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const StorageError = storage_mod.StorageError;

fn isBuiltInField(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "namespace_id") or
        std.mem.eql(u8, name, "created_at") or
        std.mem.eql(u8, name, "updated_at");
}

/// StoreService provides a domain-level facade for storage operations.
/// It encapsulates schema validation, path resolution, and validated write-command construction.
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
        const command_allocator = self.storage_engine.allocator;

        if (segments_len == 2) {
            // Full document replacement
            if (value != .map) return error.InvalidPayload;

            var write_cmd = write_command.DocumentWrite.empty;
            errdefer write_cmd.deinit(command_allocator);

            write_cmd.table = try command_allocator.dupe(u8, table);
            write_cmd.id = try command_allocator.dupe(u8, doc_id);
            write_cmd.namespace = try command_allocator.dupe(u8, namespace);

            // Validate schema and construct command columns in a single pass.
            var columns = std.ArrayListUnmanaged(write_command.WriteColumn).empty;
            defer columns.deinit(command_allocator);
            errdefer {
                for (columns.items) |col| col.deinit(command_allocator);
            }

            var it = value.map.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* != .str) continue;
                const fn_inner = entry.key_ptr.*.str.value();

                const field = tbl_md.getField(fn_inner) orelse {
                    if (isBuiltInField(fn_inner)) return StorageError.ImmutableField;
                    return StorageError.UnknownField;
                };
                if (field.required and entry.value_ptr.* == .nil) return StorageError.NullNotAllowed;

                if (field.sql_type == .array) {
                    msgpack.ensureLiteralArray(entry.value_ptr.*) catch |err| switch (err) {
                        error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
                        else => |e| return e,
                    };
                }
                const write_value = try write_command.WriteValue.fromPayload(
                    command_allocator,
                    field.sql_type,
                    entry.value_ptr.*,
                );
                try columns.append(command_allocator, .{
                    .name = try command_allocator.dupe(u8, fn_inner),
                    .field_type = field.sql_type,
                    .value = write_value,
                });
            }

            write_cmd.columns = try columns.toOwnedSlice(command_allocator);
            try self.storage_engine.takeDocumentWrite(&write_cmd);
        } else if (segments_len == 3) {
            // Partial update / field-level update
            const fn_inner = field_name orelse return StorageError.InvalidPath;

            const fld = tbl_md.getField(fn_inner) orelse {
                if (isBuiltInField(fn_inner)) return StorageError.ImmutableField;
                return StorageError.UnknownField;
            };
            if (fld.required and value == .nil) return StorageError.NullNotAllowed;

            if (fld.sql_type == .array) {
                msgpack.ensureLiteralArray(value) catch |err| switch (err) {
                    error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
                    else => |e| return e,
                };
            }

            var write_cmd = write_command.FieldWrite.empty;
            errdefer write_cmd.deinit(command_allocator);

            write_cmd.table = try command_allocator.dupe(u8, table);
            write_cmd.id = try command_allocator.dupe(u8, doc_id);
            write_cmd.namespace = try command_allocator.dupe(u8, namespace);
            write_cmd.field = try command_allocator.dupe(u8, fn_inner);
            write_cmd.field_type = fld.sql_type;
            write_cmd.value = try write_command.WriteValue.fromPayload(
                command_allocator,
                fld.sql_type,
                value,
            );

            try self.storage_engine.takeFieldWrite(&write_cmd);
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
        _ = self.schema_manager.getTable(table) orelse return StorageError.UnknownTable;

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
    ) !storage_mod.ManagedPayload {
        if (filter.after) |*old| old.deinit(allocator);
        filter.after = cursor;

        return try self.storage_engine.selectQuery(allocator, collection, namespace, filter.*);
    }
};

pub const QueryResult = struct {
    results: storage_mod.ManagedPayload,
    filter: query_parser.QueryFilter,

    pub fn deinit(self: *QueryResult, allocator: Allocator) void {
        self.results.deinit();
        self.filter.deinit(allocator);
    }
};
