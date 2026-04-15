const std = @import("std");
const Allocator = std.mem.Allocator;

// ─── Public types ────────────────────────────────────────────────────────────

pub const FieldType = enum {
    text,
    integer,
    real,
    boolean,
    array,

    pub fn toSqlType(self: FieldType) []const u8 {
        return switch (self) {
            .text => "TEXT",
            .integer => "INTEGER",
            .real => "REAL",
            .boolean => "INTEGER",
            .array => "BLOB",
        };
    }
};

pub const OnDelete = enum { cascade, restrict, set_null };

pub const built_in_columns = [_]Field{
    .{ .name = "id", .sql_type = .text, .items_type = null, .required = true, .indexed = true, .references = null, .on_delete = null },
    .{ .name = "namespace_id", .sql_type = .text, .items_type = null, .required = true, .indexed = true, .references = null, .on_delete = null },
    .{ .name = "created_at", .sql_type = .integer, .items_type = null, .required = true, .indexed = false, .references = null, .on_delete = null },
    .{ .name = "updated_at", .sql_type = .integer, .items_type = null, .required = true, .indexed = false, .references = null, .on_delete = null },
};

pub fn getSystemColumn(name: []const u8) ?Field {
    for (built_in_columns) |col| {
        if (std.mem.eql(u8, name, col.name)) return col;
    }
    return null;
}

pub fn isSystemColumn(name: []const u8) bool {
    return getSystemColumn(name) != null;
}

pub const Field = struct {
    name: []const u8, // flattened name, e.g. "address__city"
    sql_type: FieldType,
    items_type: ?FieldType, // used for array fields
    required: bool,
    indexed: bool,
    references: ?[]const u8, // target table name, or null
    on_delete: ?OnDelete,

    pub fn clone(self: Field, allocator: Allocator) !Field {
        const cloned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(cloned_name);

        const cloned_ref = if (self.references) |ref| try allocator.dupe(u8, ref) else null;
        errdefer if (cloned_ref) |r| allocator.free(r);

        return .{
            .name = cloned_name,
            .sql_type = self.sql_type,
            .items_type = self.items_type,
            .required = self.required,
            .indexed = self.indexed,
            .references = cloned_ref,
            .on_delete = self.on_delete,
        };
    }
};

pub const Table = struct {
    name: []const u8,
    fields: []const Field,

    pub fn clone(self: Table, allocator: Allocator) !Table {
        const cloned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(cloned_name);

        const cloned_fields = try allocator.alloc(Field, self.fields.len);
        var i: usize = 0;
        errdefer {
            for (cloned_fields[0..i]) |f| freeField(allocator, f);
            allocator.free(cloned_fields);
        }
        for (self.fields) |f| {
            cloned_fields[i] = try f.clone(allocator);
            i += 1;
        }

        return .{
            .name = cloned_name,
            .fields = cloned_fields,
        };
    }
};

pub const TableMetadata = struct {
    table: *const Table,
    field_map: std.StringHashMap(Field),

    pub fn init(allocator: Allocator, table: *const Table) !TableMetadata {
        var field_map = std.StringHashMap(Field).init(allocator);
        errdefer field_map.deinit();

        for (table.fields) |f| {
            try field_map.put(f.name, f);
        }

        return .{
            .table = table,
            .field_map = field_map,
        };
    }

    pub fn deinit(self: *TableMetadata, _: Allocator) void {
        self.field_map.deinit();
    }

    pub fn getField(self: *const TableMetadata, name: []const u8) ?Field {
        return self.field_map.get(name);
    }
};

pub const Schema = struct {
    version: []const u8, // "MAJOR.MINOR.PATCH"
    tables: []const Table,

    pub fn clone(self: Schema, allocator: Allocator) !Schema {
        const cloned_version = try allocator.dupe(u8, self.version);
        errdefer allocator.free(cloned_version);

        const cloned_tables = try allocator.alloc(Table, self.tables.len);
        var i: usize = 0;
        errdefer {
            for (cloned_tables[0..i]) |t| freeTable(allocator, t);
            allocator.free(cloned_tables);
        }
        for (self.tables) |t| {
            cloned_tables[i] = try t.clone(allocator);
            i += 1;
        }

        return .{
            .version = cloned_version,
            .tables = cloned_tables,
        };
    }
};

pub const SchemaMetadata = struct {
    table_metadata: std.StringHashMap(TableMetadata),

    pub fn init(allocator: Allocator, schema: *const Schema) !SchemaMetadata {
        var table_metadata = std.StringHashMap(TableMetadata).init(allocator);
        for (schema.tables) |*t| {
            try table_metadata.put(t.name, try TableMetadata.init(allocator, t));
        }
        return .{
            .table_metadata = table_metadata,
        };
    }

    pub fn deinit(self: *SchemaMetadata, allocator: Allocator) void {
        var it = self.table_metadata.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.table_metadata.deinit();
    }

    pub fn getTable(self: *const SchemaMetadata, name: []const u8) ?TableMetadata {
        return self.table_metadata.get(name);
    }
};

// ─── SchemaParser ────────────────────────────────────────────────────────────

pub const SchemaParser = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SchemaParser {
        return .{ .allocator = allocator };
    }

    /// Parse JSON text into an in-memory Schema.
    /// The caller owns the returned Schema and must call `deinit` on it.
    pub fn parse(self: *SchemaParser, json_text: []const u8) !Schema {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidSchema;

        // version
        const version_val = root.object.get("version") orelse return error.MissingVersion;
        if (version_val != .string) return error.InvalidVersion;
        const version = try self.allocator.dupe(u8, version_val.string);
        errdefer self.allocator.free(version);

        // store
        const store_val = root.object.get("store") orelse return error.MissingStore;
        if (store_val != .object) return error.InvalidStore;

        var tables: std.ArrayList(Table) = .{};
        errdefer {
            for (tables.items) |t| freeTable(self.allocator, t);
            tables.deinit(self.allocator);
        }

        var store_iter = store_val.object.iterator();
        while (store_iter.next()) |table_entry| {
            const table_name_raw = table_entry.key_ptr.*;
            if (table_name_raw.len == 0 or std.mem.containsAtLeast(u8, table_name_raw, 1, "__")) return error.InvalidTableName;

            const table_name = try self.allocator.dupe(u8, table_name_raw);
            errdefer self.allocator.free(table_name);

            const table_def = table_entry.value_ptr.*;
            if (table_def != .object) return error.InvalidTableDefinition;

            // Warn on unknown keys
            var def_iter = table_def.object.iterator();
            while (def_iter.next()) |kv| {
                const key = kv.key_ptr.*;
                if (!std.mem.eql(u8, key, "fields") and !std.mem.eql(u8, key, "required")) {
                    std.log.warn("schema: unknown key \"{s}\" in table \"{s}\" definition — ignoring", .{ key, table_name });
                }
            }

            // required list
            var required_set = std.StringHashMap(void).init(self.allocator);
            defer required_set.deinit();
            errdefer {
                var it = required_set.keyIterator();
                while (it.next()) |k| self.allocator.free(k.*);
            }

            if (table_def.object.get("required")) |req_val| {
                if (req_val == .array) {
                    for (req_val.array.items) |item| {
                        if (item == .string) {
                            const normalized = try std.mem.replaceOwned(u8, self.allocator, item.string, ".", "__");
                            try required_set.put(normalized, {});
                        }
                    }
                }
            }

            // fields
            var fields: std.ArrayList(Field) = .{};
            errdefer {
                for (fields.items) |f| freeField(self.allocator, f);
                fields.deinit(self.allocator);
            }

            if (table_def.object.get("fields")) |fields_val| {
                try self.parseFields(fields_val, &fields, &required_set, "");
            }

            try tables.append(self.allocator, .{
                .name = table_name,
                .fields = try fields.toOwnedSlice(self.allocator),
            });

            // Clean up normalized required names
            var req_it = required_set.keyIterator();
            while (req_it.next()) |k| {
                self.allocator.free(k.*);
            }
        }

        const tables_slice = try tables.toOwnedSlice(self.allocator);
        return Schema{
            .version = version,
            .tables = tables_slice,
        };
    }

    fn parseFields(
        self: *SchemaParser,
        fields_val: std.json.Value,
        fields: *std.ArrayList(Field),
        required_set: *std.StringHashMap(void),
        prefix: []const u8,
    ) !void {
        if (fields_val != .object) return error.InvalidSchema;

        var it = fields_val.object.iterator();
        while (it.next()) |entry| {
            const field_name = entry.key_ptr.*;
            const field_def = entry.value_ptr.*;

            if (field_def != .object) return error.InvalidFieldDefinition;

            const type_val = field_def.object.get("type") orelse return error.MissingFieldType;
            if (type_val != .string) return error.InvalidFieldType;
            const type_str = type_val.string;

            // Validate field name before allocating: reject empty names and internal separator.
            if (field_name.len == 0 or std.mem.containsAtLeast(u8, field_name, 1, "__")) return error.InvalidFieldName;

            // Generate the flattened full name
            const full_name = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, field_name })
            else
                try self.allocator.dupe(u8, field_name);
            errdefer self.allocator.free(full_name);

            if (isSystemColumn(full_name)) return error.ReservedFieldName;

            if (std.mem.eql(u8, type_str, "object")) {
                const nested_fields = field_def.object.get("fields") orelse return error.MissingFields;
                try self.parseFields(nested_fields, fields, required_set, full_name);
                self.allocator.free(full_name); // prefix is no longer needed after recursion
            } else {
                // Leaf field
                const sql_type = try mapType(type_str);
                const is_required = required_set.contains(full_name);

                var items_type: ?FieldType = null;
                if (sql_type == .array) {
                    const items_val = field_def.object.get("items") orelse return error.MissingArrayItems;
                    if (items_val != .string) return error.InvalidArrayItems;
                    items_type = try mapPrimitiveType(items_val.string);
                }

                const is_indexed = if (field_def.object.get("indexed")) |iv|
                    iv == .bool and iv.bool
                else
                    false;

                const refs = if (field_def.object.get("references")) |rv| blk: {
                    if (rv == .string) break :blk try self.allocator.dupe(u8, rv.string);
                    break :blk null;
                } else null;
                errdefer if (refs) |r| self.allocator.free(r);

                const on_del: ?OnDelete = if (field_def.object.get("onDelete")) |odv| blk: {
                    if (odv != .string) return error.InvalidOnDelete;
                    break :blk try parseOnDelete(odv.string);
                } else if (refs != null)
                    .restrict // default per spec when references is set
                else
                    null;

                // Validate: set_null on a required field is invalid
                if (on_del) |od| {
                    if (od == .set_null and is_required) return error.InvalidOnDelete;
                }

                try fields.append(self.allocator, .{
                    .name = full_name,
                    .sql_type = sql_type,
                    .items_type = items_type,
                    .required = is_required,
                    .indexed = is_indexed,
                    .references = refs,
                    .on_delete = on_del,
                });
            }
        }
    }

    /// Serialise an in-memory Schema back to canonical JSON.
    /// The caller owns the returned slice.
    pub fn print(self: *SchemaParser, schema: Schema) ![]const u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "{\"version\":");
        try writeJsonString(&buf, self.allocator, schema.version);
        try buf.appendSlice(self.allocator, ",\"store\":{");

        for (schema.tables, 0..) |table, ti| {
            if (ti > 0) try buf.append(self.allocator, ',');
            try writeJsonString(&buf, self.allocator, table.name);
            try buf.appendSlice(self.allocator, ":{");
            try self.printObjectContent(&buf, table.fields, "");
            try buf.append(self.allocator, '}');
        }

        try buf.appendSlice(self.allocator, "}}");
        return buf.toOwnedSlice(self.allocator);
    }

    fn printObjectContent(self: *SchemaParser, buf: *std.ArrayList(u8), fields: []const Field, prefix: []const u8) !void {
        try buf.appendSlice(self.allocator, "\"fields\":{");

        var first_field = true;
        var processed_segments = std.StringHashMap(void).init(self.allocator);
        defer processed_segments.deinit();

        for (fields) |field| {
            if (prefix.len > 0) {
                if (!std.mem.startsWith(u8, field.name, prefix)) continue;
                if (field.name.len <= prefix.len + 2) continue; // Should not happen for valid flattened names
                if (!std.mem.eql(u8, field.name[prefix.len .. prefix.len + 2], "__")) continue;
            }

            const remaining = if (prefix.len > 0) field.name[prefix.len + 2 ..] else field.name;
            const dot_idx = std.mem.indexOf(u8, remaining, "__");

            if (dot_idx) |idx| {
                const segment = remaining[0..idx];
                if (processed_segments.contains(segment)) continue;
                try processed_segments.put(segment, {});

                if (!first_field) try buf.append(self.allocator, ',');
                try writeJsonString(buf, self.allocator, segment);
                try buf.appendSlice(self.allocator, ":{\"type\":\"object\",");

                const new_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, segment })
                else
                    try self.allocator.dupe(u8, segment);
                defer self.allocator.free(new_prefix);

                try self.printObjectContent(buf, fields, new_prefix);
                try buf.append(self.allocator, '}');
                first_field = false;
            } else {
                // Leaf field
                if (!first_field) try buf.append(self.allocator, ',');
                try writeJsonString(buf, self.allocator, remaining);
                try buf.appendSlice(self.allocator, ":{\"type\":");
                try writeJsonString(buf, self.allocator, fieldTypeName(field.sql_type));
                if (field.sql_type == .array) {
                    if (field.items_type) |items_type| {
                        try buf.appendSlice(self.allocator, ",\"items\":");
                        try writeJsonString(buf, self.allocator, fieldTypeName(items_type));
                    }
                }
                if (field.indexed) try buf.appendSlice(self.allocator, ",\"indexed\":true");
                if (field.references) |ref| {
                    try buf.appendSlice(self.allocator, ",\"references\":");
                    try writeJsonString(buf, self.allocator, ref);
                }
                if (field.on_delete) |od| {
                    try buf.appendSlice(self.allocator, ",\"onDelete\":");
                    try writeJsonString(buf, self.allocator, onDeleteName(od));
                }
                try buf.append(self.allocator, '}');
                first_field = false;
            }
        }

        try buf.appendSlice(self.allocator, "},\"required\":[");
        var first_req = true;
        processed_segments.clearRetainingCapacity();

        for (fields) |field| {
            if (!field.required) continue;
            if (prefix.len > 0) {
                if (!std.mem.startsWith(u8, field.name, prefix)) continue;
                if (field.name.len <= prefix.len + 2) continue;
                if (!std.mem.eql(u8, field.name[prefix.len .. prefix.len + 2], "__")) continue;
            }

            const remaining = if (prefix.len > 0) field.name[prefix.len + 2 ..] else field.name;
            const dot_idx = std.mem.indexOf(u8, remaining, "__");
            const segment = if (dot_idx) |idx| remaining[0..idx] else remaining;

            if (processed_segments.contains(segment)) continue;
            try processed_segments.put(segment, {});

            if (!first_req) try buf.append(self.allocator, ',');
            try writeJsonString(buf, self.allocator, segment);
            first_req = false;
        }
        try buf.appendSlice(self.allocator, "]");
    }

    /// Free a Schema produced by `parse`.
    pub fn deinit(self: *SchemaParser, schema: Schema) void {
        self.allocator.free(schema.version);
        for (schema.tables) |t| freeTable(self.allocator, t);
        self.allocator.free(schema.tables);
    }
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

pub fn mapType(type_str: []const u8) !FieldType {
    if (std.mem.eql(u8, type_str, "string")) return .text;
    if (std.mem.eql(u8, type_str, "integer")) return .integer;
    if (std.mem.eql(u8, type_str, "number")) return .real;
    if (std.mem.eql(u8, type_str, "boolean")) return .boolean;
    if (std.mem.eql(u8, type_str, "array")) return .array;
    return error.UnknownFieldType;
}

pub fn mapPrimitiveType(type_str: []const u8) !FieldType {
    const ft = mapType(type_str) catch return error.UnsupportedArrayItemsType;
    if (ft == .array) return error.UnsupportedArrayItemsType;
    return ft;
}

pub fn fieldTypeName(ft: FieldType) []const u8 {
    return switch (ft) {
        .text => "string",
        .integer => "integer",
        .real => "number",
        .boolean => "boolean",
        .array => "array",
    };
}

pub fn parseOnDelete(s: []const u8) !OnDelete {
    if (std.mem.eql(u8, s, "cascade")) return .cascade;
    if (std.mem.eql(u8, s, "restrict")) return .restrict;
    if (std.mem.eql(u8, s, "set_null")) return .set_null;
    return error.InvalidOnDelete;
}

pub fn onDeleteName(od: OnDelete) []const u8 {
    return switch (od) {
        .cascade => "cascade",
        .restrict => "restrict",
        .set_null => "set_null",
    };
}

fn writeJsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

pub fn freeField(allocator: Allocator, f: Field) void {
    allocator.free(f.name);
    if (f.references) |r| allocator.free(r);
}

pub fn freeTable(allocator: Allocator, t: Table) void {
    allocator.free(t.name);
    for (t.fields) |f| freeField(allocator, f);
    allocator.free(t.fields);
}

pub fn freeSchema(allocator: Allocator, schema: Schema) void {
    allocator.free(schema.version);
    for (schema.tables) |t| freeTable(allocator, t);
    allocator.free(schema.tables);
}
