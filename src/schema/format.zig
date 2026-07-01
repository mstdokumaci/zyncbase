const std = @import("std");
const types = @import("types.zig");
const json_write = @import("../json/write.zig");
const writeJsonString = json_write.writeJsonString;

pub fn format(allocator: std.mem.Allocator, schema: *const types.Schema) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    var w = json_write.Writer{ .buf = &buf, .allocator = allocator };

    try w.beginObject();
    try w.field("version", schema.version);
    if (schema.metadata) |metadata| {
        try w.rawField("metadata", metadata.json);
    }
    try w.beginObjectField("store");

    for (schema.tables, 0..) |table, table_index| {
        if (table_index > 0) try w.separator();
        try w.beginObjectField(table.name);
        try w.boolField("namespaced", table.namespaced);
        if (table.metadata) |metadata| {
            try w.rawField("metadata", metadata.json);
        }
        try writeRequiredFields(&w, allocator, table.userFields());
        try w.beginObjectField("fields");
        try writeFieldsForPrefix(&w, allocator, table.userFields(), "");
        try w.endObject();
        try w.endObject();
    }

    try w.endObject();
    try w.endObject();
    return buf.toOwnedSlice(allocator);
}

fn writeRequiredFields(w: *json_write.Writer, allocator: std.mem.Allocator, fields: []const types.Field) !void {
    var count: usize = 0;
    for (fields) |field| {
        if (field.required) count += 1;
    }
    if (count == 0) return;

    try w.beginArrayField("required");
    var emitted: usize = 0;
    for (fields) |field| {
        if (!field.required) continue;
        if (emitted > 0) try w.separator();
        const dotted = try replaceAll(allocator, field.name, "__", ".");
        defer allocator.free(dotted);
        try writeJsonString(w.buf, allocator, dotted);
        emitted += 1;
    }
    try w.endArray();
}

fn writeFieldsForPrefix(
    w: *json_write.Writer,
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

        if (emitted > 0) try w.separator();
        try writeJsonString(w.buf, allocator, segment);
        try w.buf.append(allocator, ':');

        if (segment_end < remainder.len) {
            const child_prefix = if (prefix.len == 0)
                try allocator.dupe(u8, segment)
            else
                try std.fmt.allocPrint(allocator, "{s}__{s}", .{ prefix, segment });
            defer allocator.free(child_prefix);

            try w.beginObject();
            try w.field("type", "object");
            try w.beginObjectField("fields");
            try writeFieldsForPrefix(w, allocator, fields, child_prefix);
            try w.endObject();
            try w.endObject();
        } else {
            try writeFieldDefinition(w, field);
        }

        emitted += 1;
    }
}

fn writeFieldDefinition(w: *json_write.Writer, field: types.Field) !void {
    try w.beginObject();
    try w.field("type", field.declared_type.schemaName());
    if (field.declared_type == .array) {
        try w.field("items", (field.items_type orelse types.FieldType.text).schemaName());
    }
    if (field.indexed) try w.boolField("indexed", true);
    if (field.references) |ref| {
        try w.field("references", ref);
    }
    if (field.on_delete) |on_delete| {
        try w.field("onDelete", on_delete.schemaName());
    }
    if (field.metadata) |metadata| {
        try w.rawField("metadata", metadata.json);
    }
    try w.endObject();
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
