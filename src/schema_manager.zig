const std = @import("std");
const Allocator = std.mem.Allocator;
const schema_parser = @import("schema_parser.zig");

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
pub const owner_id_field_index = schema_parser.owner_id_field_index;
pub const first_user_field_index = schema_parser.first_user_field_index;
pub const getSystemColumn = schema_parser.getSystemColumn;
pub const isSystemColumn = schema_parser.isSystemColumn;
pub const global_namespace_id = schema_parser.global_namespace_id;
pub const global_namespace_name = schema_parser.global_namespace_name;
pub const implicit_users_schema_json = schema_parser.implicit_users_schema_json;
pub const effectiveNamespaceLabel = schema_parser.effectiveNamespaceLabel;
pub const quoted_id = schema_parser.quoted_id;
pub const quoted_namespace_id = schema_parser.quoted_namespace_id;
pub const quoted_owner_id = schema_parser.quoted_owner_id;
pub const quoted_external_id = schema_parser.quoted_external_id;
pub const quoted_created_at = schema_parser.quoted_created_at;
pub const quoted_updated_at = schema_parser.quoted_updated_at;

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

    /// Get table metadata by positional index (as used in SchemaSync / wire protocol).
    pub fn getTableByIndex(self: *const SchemaManager, index: usize) ?*const TableMetadata {
        return self.metadata.getTableByIndex(index);
    }
};
