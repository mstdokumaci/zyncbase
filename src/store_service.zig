const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const storage_mod = @import("storage_engine/types.zig");
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const StorageError = storage_mod.StorageError;

fn isBuiltInField(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "namespace_id") or
        std.mem.eql(u8, name, "created_at") or
        std.mem.eql(u8, name, "updated_at");
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
            defer columns.deinit(self.allocator);

            var it = value.map.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* != .str) continue;
                const fn_inner = entry.key_ptr.*.str.value();

                const field = tbl_md.getField(fn_inner) orelse {
                    if (isBuiltInField(fn_inner)) return StorageError.ImmutableField;
                    return StorageError.UnknownField;
                };

                if (field.sql_type == .array) {
                    msgpack.ensureLiteralArray(entry.value_ptr.*) catch |err| switch (err) {
                        error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
                        else => |e| return e,
                    };
                }
                try columns.append(self.allocator, .{
                    .name = fn_inner,
                    .value = entry.value_ptr.*,
                });
            }

            try self.storage_engine.insertOrReplace(table, doc_id, namespace, columns.items);
        } else if (segments_len == 3) {
            // Partial update / field-level update
            const fn_inner = field_name orelse return StorageError.InvalidPath;

            const fld = tbl_md.getField(fn_inner) orelse {
                if (isBuiltInField(fn_inner)) return StorageError.ImmutableField;
                return StorageError.UnknownField;
            };

            if (fld.sql_type == .array) {
                msgpack.ensureLiteralArray(value) catch |err| switch (err) {
                    error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
                    else => |e| return e,
                };
            }

            const col = [_]storage_mod.ColumnValue{.{ .name = fn_inner, .value = value }};
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
        _ = self.schema_manager.getTable(table) orelse return StorageError.UnknownTable;

        if (segments_len == 2) {
            try self.storage_engine.deleteDocument(table, doc_id, namespace);
        } else {
            return StorageError.InvalidPath;
        }
    }
};
