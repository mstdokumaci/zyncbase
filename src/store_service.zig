const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const storage_mod = @import("storage_engine/types.zig");
const write_command = @import("storage_engine/write_command.zig");
const query_parser = @import("query_parser.zig");
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const StorageError = storage_mod.StorageError;

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
        const command_allocator = self.storage_engine.allocator;

        if (segments_len == 2) {
            var write_cmd = try write_command.buildDocumentWriteFromPayload(
                command_allocator,
                self.schema_manager,
                table,
                doc_id,
                namespace,
                value,
            );
            errdefer write_cmd.deinit(command_allocator);
            try self.storage_engine.takeDocumentWrite(&write_cmd);
        } else if (segments_len == 3) {
            const fn_inner = field_name orelse return StorageError.InvalidPath;
            var write_cmd = try write_command.buildFieldWriteFromPayload(
                command_allocator,
                self.schema_manager,
                table,
                doc_id,
                namespace,
                fn_inner,
                value,
            );
            errdefer write_cmd.deinit(command_allocator);
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
