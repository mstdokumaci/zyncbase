const std = @import("std");
const types = @import("types.zig");

pub fn buildFieldIndex(allocator: std.mem.Allocator, table: *types.Table) !void {
    var map = std.StringHashMap(usize).init(allocator);
    errdefer map.deinit();

    for (table.fields, 0..) |field, idx| {
        if (map.contains(field.name)) return error.DuplicateFieldName;
        try map.put(field.name, idx);
    }

    table.field_index_map = map;
    table.has_index = true;
}

pub fn buildTableIndex(allocator: std.mem.Allocator, schema: *types.Schema) !void {
    var map = std.StringHashMap(usize).init(allocator);
    errdefer map.deinit();

    for (schema.tables, 0..) |table, idx| {
        if (map.contains(table.name)) return error.DuplicateTableName;
        try map.put(table.name, idx);
    }

    schema.table_index_map = map;
    schema.has_index = true;
}
