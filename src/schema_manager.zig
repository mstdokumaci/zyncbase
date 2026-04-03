const std = @import("std");
const Allocator = std.mem.Allocator;
const schema_parser = @import("schema_parser.zig");
const types = @import("storage_engine/types.zig");
const msgpack = @import("msgpack_utils.zig");

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

/// SchemaManager centralizes schema metadata and provides efficient lookup and validation.
/// It is initialized once at startup and remains immutable for the lifetime of the server.
pub const SchemaManager = struct {
    allocator: Allocator,
    schema: Schema,
    metadata: SchemaMetadata,

    /// Parse schema JSON, build indexed metadata, and discard the parser.
    /// The returned SchemaManager is allocated on the heap and owned by the caller.
    pub fn init(allocator: Allocator, json_text: []const u8) !*SchemaManager {
        const self = try allocator.create(SchemaManager);
        errdefer allocator.destroy(self);

        var parser = schema_parser.SchemaParser.init(allocator);
        const schema = try parser.parse(json_text);
        errdefer schema_parser.freeSchema(allocator, schema);

        const metadata = try SchemaMetadata.init(allocator, &schema);
        errdefer {
            var m = metadata;
            m.deinit();
        }

        self.* = .{
            .allocator = allocator,
            .schema = schema,
            .metadata = metadata,
        };
        return self;
    }

    /// Clean up schema and metadata resources.
    pub fn deinit(self: *SchemaManager) void {
        self.metadata.deinit();
        schema_parser.freeSchema(self.allocator, self.schema);
        self.allocator.destroy(self);
    }

    /// Find a table metadata by name. Returns null if not found.
    pub fn getTable(self: *const SchemaManager, name: []const u8) ?TableMetadata {
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

    /// Validate columns for an operation (e.g., insert/update).
    /// Checks if the table exists, each column exists, and obeys type/nullability constraints.
    pub fn validateColumns(self: *const SchemaManager, table_name: []const u8, columns: []const types.ColumnValue) !void {
        const table_metadata = self.getTable(table_name) orelse return types.StorageError.UnknownTable;
        for (columns) |col| {
            const f = table_metadata.getField(col.name) orelse return types.StorageError.UnknownField;
            if (f.required and col.value == .nil) return types.StorageError.NullNotAllowed;
            if (col.value != .nil) {
                try validateValueType(f.sql_type, col.value);
            }
        }
    }
};

/// Helper to validate a msgpack payload against a field type.
pub fn validateValueType(ft: FieldType, value: msgpack.Payload) !void {
    const match = switch (ft) {
        .text => value == .str,
        .integer => value == .uint or value == .int,
        .real => value == .float or value == .uint or value == .int,
        .boolean => value == .bool,
        .array => value == .arr,
    };
    if (!match) return types.StorageError.TypeMismatch;
}
