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

    for (schema.tables) |*table| {
        try w.beginObjectField(table.name);
        try w.boolField("namespaced", table.namespaced);
        if (table.metadata) |metadata| {
            try w.rawField("metadata", metadata.json);
        }
        try writeRequiredFields(&w, allocator, table.userFields());
        try writeUniqueConstraints(&w, allocator, table);
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

fn writeUniqueConstraints(w: *json_write.Writer, allocator: std.mem.Allocator, table: *const types.Table) !void {
    if (table.unique_constraints.len == 0) return;
    try w.beginArrayField("unique");
    for (table.unique_constraints) |constraint| {
        try w.beginArrayItem();
        for (constraint.field_indexes) |field_index| {
            const dotted = try field_path.toDotted(allocator, table.userFields()[field_index].name);
            defer allocator.free(dotted);
            try w.stringValue(dotted);
        }
        try w.endArray();
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
        try writeConstraints(w, c);
    }
}

fn writeConstraints(w: *json_write.Writer, constraints: types.Constraints) !void {
    if (constraints.enum_values) |enums| try writeEnumValues(w, enums);
    if (constraints.pattern_source) |pattern| try w.field("pattern", pattern);
    if (constraints.format) |constraint_format| try w.field("format", constraint_format.schemaName());
    if (constraints.min_length) |min_length| try w.intField("minLength", min_length);
    if (constraints.max_length) |max_length| try w.intField("maxLength", max_length);
    if (constraints.minimum) |minimum| try writeBoundField(w, "minimum", minimum);
    if (constraints.maximum) |maximum| try writeBoundField(w, "maximum", maximum);
}

fn writeEnumValues(w: *json_write.Writer, enums: []const types.Constraints.EnumValue) !void {
    try w.beginArrayField("enum");
    for (enums) |value| {
        switch (value) {
            .text => |text| try w.stringValue(text),
            .integer => |integer| try w.intValue(integer),
            .real => |real| try w.floatValue(real),
        }
    }
    try w.endArray();
}

fn writeBoundField(w: *json_write.Writer, key: []const u8, bound: types.Constraints.Bound) !void {
    switch (bound) {
        .integer => |integer| try w.intField(key, integer),
        .real => |real| try w.floatField(key, real),
    }
}
