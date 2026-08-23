const std = @import("std");

const json_write = @import("../json/write.zig");
const field_path = @import("field_path.zig");
const types = @import("types.zig");

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

    for (schema.tables) |table| {
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
    for (fields) |field| {
        if (!field.required) continue;
        const dotted = try field_path.toDotted(allocator, field.name);
        defer allocator.free(dotted);
        try w.stringValue(dotted);
    }
    try w.endArray();
}

fn writeFieldsForPrefix(
    w: *json_write.Writer,
    allocator: std.mem.Allocator,
    fields: []const types.Field,
    prefix: []const u8,
) !void {
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);

    for (fields) |field| {
        const rem = field_path.remainder(field.name, prefix) orelse continue;
        const split = field_path.splitFirst(rem);
        const segment = split.segment;

        const gop = try seen.getOrPut(allocator, segment);
        if (gop.found_existing) continue;

        try w.beginObjectField(segment);
        if (split.rest != null) {
            const child_prefix = try field_path.join(allocator, prefix, segment);
            defer allocator.free(child_prefix);

            try w.field("type", "object");
            try w.beginObjectField("fields");
            try writeFieldsForPrefix(w, allocator, fields, child_prefix);
            try w.endObject();
        } else {
            try writeFieldDefinition(w, field);
        }
        try w.endObject();
    }
}

fn writeFieldDefinition(w: *json_write.Writer, field: types.Field) !void {
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
    if (field.constraints) |c| {
        if (c.enum_values) |enums| {
            try w.beginArrayField("enum");
            for (enums) |e| {
                switch (e) {
                    .text => |t| try w.stringValue(t),
                    .integer => |i| try w.intValue(i),
                    .real => |r| try w.floatValue(r),
                }
            }
            try w.endArray();
        }
        if (c.pattern_source) |pat| {
            try w.field("pattern", pat);
        }
        if (c.format) |fmt| {
            try w.field("format", fmt.schemaName());
        }
        if (c.min_length) |min_l| {
            try w.intField("minLength", min_l);
        }
        if (c.max_length) |max_l| {
            try w.intField("maxLength", max_l);
        }
        if (c.minimum) |min_val| {
            if (field.declared_type == .integer and min_val >= @as(f64, @floatFromInt(std.math.minInt(i64))) and min_val < @as(f64, @floatFromInt(std.math.maxInt(i64))) and min_val == @trunc(min_val)) {
                try w.intField("minimum", @as(i64, @intFromFloat(min_val)));
            } else {
                try w.floatField("minimum", min_val);
            }
        }
        if (c.maximum) |max_val| {
            if (field.declared_type == .integer and max_val >= @as(f64, @floatFromInt(std.math.minInt(i64))) and max_val < @as(f64, @floatFromInt(std.math.maxInt(i64))) and max_val == @trunc(max_val)) {
                try w.intField("maximum", @as(i64, @intFromFloat(max_val)));
            } else {
                try w.floatField("maximum", max_val);
            }
        }
    }
}
