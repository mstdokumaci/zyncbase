const std = @import("std");
const types = @import("types.zig");

pub fn format(allocator: std.mem.Allocator, schema: *const types.Schema) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"version\":");
    try writeJsonString(&buf, allocator, schema.version);
    if (schema.metadata) |metadata| {
        try buf.appendSlice(allocator, ",\"metadata\":");
        try buf.appendSlice(allocator, metadata.json);
    }
    try buf.appendSlice(allocator, ",\"store\":{");

    for (schema.tables, 0..) |table, table_index| {
        if (table_index > 0) try buf.append(allocator, ',');
        try writeJsonString(&buf, allocator, table.name);
        try buf.appendSlice(allocator, ":{\"namespaced\":");
        try buf.appendSlice(allocator, if (table.namespaced) "true" else "false");
        if (table.metadata) |metadata| {
            try buf.appendSlice(allocator, ",\"metadata\":");
            try buf.appendSlice(allocator, metadata.json);
        }
        try writeRequiredFields(&buf, allocator, table.userFields());
        try buf.appendSlice(allocator, ",\"fields\":{");
        try writeFieldsForPrefix(&buf, allocator, table.userFields(), "");
        try buf.appendSlice(allocator, "}}");
    }

    try buf.appendSlice(allocator, "}}");
    return buf.toOwnedSlice(allocator);
}

fn writeRequiredFields(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, fields: []const types.Field) !void {
    var count: usize = 0;
    for (fields) |field| {
        if (field.required) count += 1;
    }
    if (count == 0) return;

    try buf.appendSlice(allocator, ",\"required\":[");
    var emitted: usize = 0;
    for (fields) |field| {
        if (!field.required) continue;
        if (emitted > 0) try buf.append(allocator, ',');
        const dotted = try replaceAll(allocator, field.name, "__", ".");
        defer allocator.free(dotted);
        try writeJsonString(buf, allocator, dotted);
        emitted += 1;
    }
    try buf.append(allocator, ']');
}

fn writeFieldsForPrefix(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    fields: []const types.Field,
    prefix: []const u8,
) !void {
    var emitted: usize = 0;
    for (fields, 0..) |field, field_index| {
        const remainder = fieldRemainder(field.name, prefix) orelse continue;
        const segment_end = std.mem.indexOf(u8, remainder, "__") orelse remainder.len;
        const segment = remainder[0..segment_end];
        if (segmentSeen(fields, prefix, field_index, segment)) continue;

        if (emitted > 0) try buf.append(allocator, ',');
        try writeJsonString(buf, allocator, segment);
        try buf.append(allocator, ':');

        if (segment_end < remainder.len) {
            const child_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, segment)
            else
                try std.fmt.allocPrint(allocator, "{s}__{s}", .{ prefix, segment });
            defer allocator.free(child_prefix);

            try buf.appendSlice(allocator, "{\"type\":\"object\",\"fields\":{");
            try writeFieldsForPrefix(buf, allocator, fields, child_prefix);
            try buf.appendSlice(allocator, "}}");
        } else {
            try writeFieldDefinition(buf, allocator, field);
        }

        emitted += 1;
    }
}

fn writeFieldDefinition(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, field: types.Field) !void {
    try buf.appendSlice(allocator, "{\"type\":");
    try writeJsonString(buf, allocator, field.declared_type.schemaName());
    if (field.declared_type == .array) {
        try buf.appendSlice(allocator, ",\"items\":");
        try writeJsonString(buf, allocator, (field.items_type orelse types.FieldType.text).schemaName());
    }
    if (field.indexed) try buf.appendSlice(allocator, ",\"indexed\":true");
    if (field.references) |ref| {
        try buf.appendSlice(allocator, ",\"references\":");
        try writeJsonString(buf, allocator, ref);
    }
    if (field.on_delete) |on_delete| {
        try buf.appendSlice(allocator, ",\"onDelete\":");
        try writeJsonString(buf, allocator, on_delete.schemaName());
    }
    if (field.metadata) |metadata| {
        try buf.appendSlice(allocator, ",\"metadata\":");
        try buf.appendSlice(allocator, metadata.json);
    }
    try buf.append(allocator, '}');
}

fn fieldRemainder(field_name: []const u8, prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return field_name;
    if (!std.mem.startsWith(u8, field_name, prefix)) return null;
    if (field_name.len <= prefix.len + 2) return null;
    if (!std.mem.eql(u8, field_name[prefix.len .. prefix.len + 2], "__")) return null;
    return field_name[prefix.len + 2 ..];
}

fn segmentSeen(fields: []const types.Field, prefix: []const u8, current_index: usize, segment: []const u8) bool {
    for (fields[0..current_index]) |candidate| {
        const remainder = fieldRemainder(candidate.name, prefix) orelse continue;
        const segment_end = std.mem.indexOf(u8, remainder, "__") orelse remainder.len;
        if (std.mem.eql(u8, remainder[0..segment_end], segment)) return true;
    }
    return false;
}

fn replaceAll(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, allocator, input, needle, replacement);
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |char| {
        switch (char) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, char),
        }
    }
    try buf.append(allocator, '"');
}
