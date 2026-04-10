const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const storage_mod = @import("storage_engine/types.zig");
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const StorageError = storage_mod.StorageError;

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
                for (columns.items) |col| {
                    self.allocator.free(col.name);
                }
                columns.deinit(self.allocator);
            }

            var it = value.map.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* != .str) continue;
                const fn_inner = entry.key_ptr.*.str.value();

                if (tbl_md.getField(fn_inner)) |field| {
                    if (field.sql_type == .array) {
                        msgpack.ensureLiteralArray(entry.value_ptr.*) catch |err| switch (err) {
                            error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
                            else => |e| return e,
                        };
                    }
                    try columns.append(self.allocator, .{
                        .name = try self.allocator.dupe(u8, fn_inner),
                        .value = entry.value_ptr.*,
                    });
                } else {
                    // Skip built-ins, reject others
                    if (!std.mem.eql(u8, fn_inner, "id") and
                        !std.mem.eql(u8, fn_inner, "namespace_id") and
                        !std.mem.eql(u8, fn_inner, "created_at") and
                        !std.mem.eql(u8, fn_inner, "updated_at"))
                    {
                        return StorageError.UnknownField;
                    }
                }
            }

            try self.storage_engine.insertOrReplace(table, doc_id, namespace, columns.items);
        } else if (segments_len == 3) {
            // Partial update / field-level update
            const fn_inner = field_name orelse return StorageError.InvalidPath;

            if (tbl_md.getField(fn_inner)) |fld| {
                if (fld.sql_type == .array) {
                    msgpack.ensureLiteralArray(value) catch |err| switch (err) {
                        error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
                        else => |e| return e,
                    };
                }
            } else {
                return StorageError.UnknownField;
            }

            const col = [_]storage_mod.ColumnValue{.{ .name = fn_inner, .value = value }};
            try self.storage_engine.insertOrReplace(table, doc_id, namespace, &col);
        } else {
            return StorageError.InvalidPath;
        }
    }

    /// Remove a value at a path.
    /// Handles document deletion (path len 2) and setting a field to nil (path len 3).
    pub fn remove(
        self: *StoreService,
        table: []const u8,
        doc_id: []const u8,
        namespace: []const u8,
        segments_len: usize,
        field_name: ?[]const u8,
    ) !void {
        // Validation check for table existence
        _ = self.schema_manager.getTable(table) orelse return StorageError.UnknownTable;

        if (segments_len == 2) {
            try self.storage_engine.deleteDocument(table, doc_id, namespace);
        } else if (segments_len == 3) {
            const fn_inner = field_name orelse return StorageError.InvalidPath;
            try self.storage_engine.updateField(table, doc_id, namespace, fn_inner, .nil);
        } else {
            return StorageError.InvalidPath;
        }
    }
};
