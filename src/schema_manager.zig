const std = @import("std");
const Allocator = std.mem.Allocator;
const schema_parser = @import("schema_parser.zig");
const types = @import("storage_engine/types.zig");

// Re-export all schema types so consumers import only schema_manager.zig
pub const Schema = schema_parser.Schema;
pub const Table = schema_parser.Table;
pub const Field = schema_parser.Field;
pub const FieldType = schema_parser.FieldType;
pub const OnDelete = schema_parser.OnDelete;
pub const TableMetadata = schema_parser.TableMetadata;
pub const SchemaMetadata = schema_parser.SchemaMetadata;
pub const freeSchema = schema_parser.freeSchema;
pub const freeTable = schema_parser.freeTable;
pub const freeField = schema_parser.freeField;
pub const built_in_columns = schema_parser.built_in_columns;
pub const id_field_index = schema_parser.id_field_index;
pub const namespace_id_field_index = schema_parser.namespace_id_field_index;
pub const getSystemColumn = schema_parser.getSystemColumn;
pub const isSystemColumn = schema_parser.isSystemColumn;

/// SchemaManager centralizes schema metadata and provides efficient lookup and validation.
/// It is initialized once at startup and remains immutable for the lifetime of the server.
pub const SchemaManager = struct {
    allocator: Allocator,
    schema: Schema,
    metadata: SchemaMetadata,

    /// Parse schema JSON, build indexed metadata, and discard the parser.
    pub fn init(self: *SchemaManager, allocator: Allocator, json_text: []const u8) !void {
        var parser = schema_parser.SchemaParser.init(allocator);
        const schema = try parser.parse(json_text);
        errdefer schema_parser.freeSchema(allocator, schema);

        const metadata = try SchemaMetadata.init(allocator, &schema);
        errdefer {
            var m = metadata;
            m.deinit(allocator);
        }

        self.* = .{
            .allocator = allocator,
            .schema = schema,
            .metadata = metadata,
        };
    }

    /// Clean up schema and metadata resources.
    pub fn deinit(self: *SchemaManager) void {
        self.metadata.deinit(self.allocator);
        schema_parser.freeSchema(self.allocator, self.schema);
    }

    /// Find a table metadata by name. Returns null if not found.
    pub fn getTable(self: *const SchemaManager, name: []const u8) ?*const TableMetadata {
        return self.metadata.getTable(name);
    }

    /// Find a field definition by table and field name. Returns null if not found.
    pub fn getField(self: *const SchemaManager, table: []const u8, field: []const u8) ?Field {
        const tbl = self.getTable(table) orelse return null;
        return tbl.getField(field);
    }

    /// Validate that a table exists in the schema.
    pub fn validateTable(self: *const SchemaManager, name: []const u8) !void {
        _ = self.getTable(name) orelse return types.StorageError.UnknownTable;
    }

    /// Validate that a field exists in a specific table.
    pub fn validateField(self: *const SchemaManager, table: []const u8, field: []const u8) !void {
        const tbl = self.getTable(table) orelse return types.StorageError.UnknownTable;
        if (tbl.getField(field) == null) return types.StorageError.UnknownField;
    }

    /// Get table metadata by positional index (as used in SchemaSync / wire protocol).
    pub fn getTableByIndex(self: *const SchemaManager, index: usize) ?*const TableMetadata {
        return self.metadata.getTableByIndex(index);
    }
};
