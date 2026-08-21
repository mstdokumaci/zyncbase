const std = @import("std");

const types = @import("types.zig");

pub fn buildFieldIndex(allocator: std.mem.Allocator, table: *types.Table) !void {
    var map = std.StringHashMapUnmanaged(usize){};
    errdefer map.deinit(allocator);

    for (table.fields, 0..) |field, idx| {
        if (map.contains(field.name)) return error.DuplicateFieldName;
        try map.put(allocator, field.name, idx);
    }

    table.field_index_map = map;
}

pub fn buildTableIndex(allocator: std.mem.Allocator, schema: *types.Schema) !void {
    var map = std.StringHashMapUnmanaged(usize){};
    errdefer map.deinit(allocator);

    for (schema.tables, 0..) |table, idx| {
        if (map.contains(table.name)) return error.DuplicateTableName;
        try map.put(allocator, table.name, idx);
    }

    for (schema.tables) |table| {
        for (table.userFields()) |field| {
            const target = field.references orelse continue;
            if ((field.on_delete orelse .restrict) == .restrict) continue;
            const target_index = map.get(target) orelse continue;
            schema.tables[target_index].has_incoming_cascade_or_set_null = true;
        }
    }

    schema.table_index_map = map;
}
