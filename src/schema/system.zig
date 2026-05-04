const std = @import("std");
const types = @import("types.zig");

pub const global_namespace_id: i64 = 0;
pub const global_namespace_name = "$global";

pub const implicit_users_schema_json =
    \\{"version":"1.0.0","store":{"users":{"namespaced":false,"fields":{}}}}
;

pub const quoted_id = "\"id\"";
pub const quoted_namespace_id = "\"namespace_id\"";
pub const quoted_owner_id = "\"owner_id\"";
pub const quoted_external_id = "\"external_id\"";
pub const quoted_created_at = "\"created_at\"";
pub const quoted_updated_at = "\"updated_at\"";

pub const id_field_index: usize = 0;
pub const namespace_id_field_index: usize = 1;
pub const owner_id_field_index: usize = 2;
pub const first_user_field_index: usize = 3;
pub const leading_system_field_count: usize = 3;
pub const trailing_system_field_count: usize = 2;

pub const leading_system_fields = [_]types.Field{
    .{ .name = "id", .name_quoted = quoted_id, .declared_type = .doc_id, .storage_type = .doc_id, .required = true, .indexed = true, .kind = .system },
    .{ .name = "namespace_id", .name_quoted = quoted_namespace_id, .declared_type = .integer, .storage_type = .integer, .required = true, .indexed = true, .kind = .system },
    .{ .name = "owner_id", .name_quoted = quoted_owner_id, .declared_type = .doc_id, .storage_type = .doc_id, .required = true, .indexed = true, .kind = .system },
};

pub const trailing_system_fields = [_]types.Field{
    .{ .name = "created_at", .name_quoted = quoted_created_at, .declared_type = .integer, .storage_type = .integer, .required = true, .indexed = false, .kind = .timestamp },
    .{ .name = "updated_at", .name_quoted = quoted_updated_at, .declared_type = .integer, .storage_type = .integer, .required = true, .indexed = false, .kind = .timestamp },
};

pub fn getSystemColumn(name: []const u8) ?types.Field {
    for (leading_system_fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return field;
    }
    for (trailing_system_fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return field;
    }
    return null;
}

pub fn isSystemColumn(name: []const u8) bool {
    return getSystemColumn(name) != null;
}

pub fn effectiveNamespaceLabel(table: *const types.Table, namespace: []const u8) []const u8 {
    return if (table.namespaced) namespace else global_namespace_name;
}

pub fn isInternalTableName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "_zync_");
}
