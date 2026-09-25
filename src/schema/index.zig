const std = @import("std");

const types = @import("types.zig");

fn buildNameIndex(allocator: std.mem.Allocator, comptime F: type, fields: []const F) !std.StringHashMapUnmanaged(usize) {
    var map = std.StringHashMapUnmanaged(usize){};
    errdefer map.deinit(allocator);

    for (fields, 0..) |field, idx| {
        if (map.contains(field.name)) return error.DuplicateFieldName;
        try map.put(allocator, field.name, idx);
    }

    return map;
}

pub fn buildFieldIndex(allocator: std.mem.Allocator, table: *types.Table) !void {
    table.field_index_map = try buildNameIndex(allocator, types.Field, table.fields);
}

pub fn buildActionIndex(allocator: std.mem.Allocator, schema: *types.Schema) !void {
    var map = std.StringHashMapUnmanaged(usize){};
    errdefer map.deinit(allocator);

    for (schema.actions, 0..) |action, idx| {
        if (map.contains(action.name)) return error.DuplicateActionName;
        try map.put(allocator, action.name, idx);
    }

    for (schema.actions) |*action| {
        action.param_index_map = try buildNameIndex(allocator, types.ActionField, action.params);
        if (action.returns) |returns| {
            action.return_index_map = try buildNameIndex(allocator, types.ActionField, returns);
        }
    }

    schema.action_index_map = map;
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
