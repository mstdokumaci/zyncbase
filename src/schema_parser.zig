const std = @import("std");
const Allocator = std.mem.Allocator;

// ─── Public types ────────────────────────────────────────────────────────────

pub const FieldType = enum { text, integer, real, boolean, array };

pub const OnDelete = enum { cascade, restrict, set_null };

pub const Field = struct {
    name: []const u8, // flattened name, e.g. "address_city"
    sql_type: FieldType,
    required: bool,
    indexed: bool,
    references: ?[]const u8, // target table name, or null
    on_delete: ?OnDelete,

    pub fn clone(self: Field, allocator: Allocator) !Field {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .sql_type = self.sql_type,
            .required = self.required,
            .indexed = self.indexed,
            .references = if (self.references) |ref| try allocator.dupe(u8, ref) else null,
            .on_delete = self.on_delete,
        };
    }
};

pub const Table = struct {
    name: []const u8,
    fields: []Field,

    pub fn clone(self: Table, allocator: Allocator) !Table {
        const cloned_fields = try allocator.alloc(Field, self.fields.len);
        errdefer allocator.free(cloned_fields);
        for (self.fields, 0..) |f, i| {
            cloned_fields[i] = try f.clone(allocator);
        }
        return .{
            .name = try allocator.dupe(u8, self.name),
            .fields = cloned_fields,
        };
    }
};

pub const Schema = struct {
    version: []const u8, // "MAJOR.MINOR.PATCH"
    tables: []Table,
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
            const table_name = try self.allocator.dupe(u8, table_entry.key_ptr.*);
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

            if (table_def.object.get("required")) |req_val| {
                if (req_val == .array) {
                    for (req_val.array.items) |item| {
                        if (item == .string) {
                            try required_set.put(item.string, {});
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
                if (fields_val != .object) return error.InvalidFields;

                var fields_iter = fields_val.object.iterator();
                while (fields_iter.next()) |field_entry| {
                    const field_name = field_entry.key_ptr.*;
                    const field_def = field_entry.value_ptr.*;

                    if (field_def != .object) return error.InvalidFieldDefinition;

                    const type_val = field_def.object.get("type") orelse {
                        return error.MissingFieldType;
                    };
                    if (type_val != .string) return error.InvalidFieldType;

                    const type_str = type_val.string;

                    if (std.mem.eql(u8, type_str, "object")) {
                        // Flatten one level deep
                        if (field_def.object.get("properties")) |props_val| {
                            if (props_val == .object) {
                                var props_iter = props_val.object.iterator();
                                while (props_iter.next()) |prop_entry| {
                                    const prop_name = prop_entry.key_ptr.*;
                                    const flat_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ field_name, prop_name });
                                    errdefer self.allocator.free(flat_name);

                                    const prop_def = prop_entry.value_ptr.*;
                                    var prop_sql_type: FieldType = .text;
                                    if (prop_def == .object) {
                                        if (prop_def.object.get("type")) |pt| {
                                            if (pt == .string) {
                                                prop_sql_type = mapType(pt.string) catch .text;
                                            }
                                        }
                                    }

                                    const is_required = required_set.contains(flat_name) or required_set.contains(field_name);
                                    const is_indexed = if (prop_def == .object) blk: {
                                        if (prop_def.object.get("indexed")) |iv| {
                                            break :blk iv == .bool and iv.bool;
                                        }
                                        break :blk false;
                                    } else false;

                                    const refs = if (prop_def == .object) blk: {
                                        if (prop_def.object.get("references")) |rv| {
                                            if (rv == .string) break :blk try self.allocator.dupe(u8, rv.string);
                                        }
                                        break :blk null;
                                    } else null;
                                    errdefer if (refs) |r| self.allocator.free(r);

                                    const on_del = if (prop_def == .object) blk: {
                                        if (prop_def.object.get("onDelete")) |odv| {
                                            if (odv == .string) break :blk parseOnDelete(odv.string);
                                        }
                                        break :blk null;
                                    } else null;

                                    try fields.append(self.allocator, .{
                                        .name = flat_name,
                                        .sql_type = prop_sql_type,
                                        .required = is_required,
                                        .indexed = is_indexed,
                                        .references = refs,
                                        .on_delete = on_del,
                                    });
                                }
                            }
                        }
                        // object fields without properties produce no columns
                    } else {
                        const sql_type = try mapType(type_str);
                        const is_required = required_set.contains(field_name);
                        const is_indexed = if (field_def.object.get("indexed")) |iv|
                            iv == .bool and iv.bool
                        else
                            false;

                        const refs = if (field_def.object.get("references")) |rv|
                            if (rv == .string) try self.allocator.dupe(u8, rv.string) else null
                        else
                            null;
                        errdefer if (refs) |r| self.allocator.free(r);

                        const on_del = if (field_def.object.get("onDelete")) |odv|
                            if (odv == .string) parseOnDelete(odv.string) else null
                        else
                            null;

                        const owned_name = try self.allocator.dupe(u8, field_name);
                        errdefer self.allocator.free(owned_name);

                        try fields.append(self.allocator, .{
                            .name = owned_name,
                            .sql_type = sql_type,
                            .required = is_required,
                            .indexed = is_indexed,
                            .references = refs,
                            .on_delete = on_del,
                        });
                    }
                }
            }

            try tables.append(self.allocator, .{
                .name = table_name,
                .fields = try fields.toOwnedSlice(self.allocator),
            });
        }

        return Schema{
            .version = version,
            .tables = try tables.toOwnedSlice(self.allocator),
        };
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
            try buf.appendSlice(self.allocator, ":{\"fields\":{");

            for (table.fields, 0..) |field, fi| {
                if (fi > 0) try buf.append(self.allocator, ',');
                try writeJsonString(&buf, self.allocator, field.name);
                try buf.appendSlice(self.allocator, ":{\"type\":");
                try writeJsonString(&buf, self.allocator, fieldTypeName(field.sql_type));
                if (field.indexed) try buf.appendSlice(self.allocator, ",\"indexed\":true");
                if (field.references) |ref| {
                    try buf.appendSlice(self.allocator, ",\"references\":");
                    try writeJsonString(&buf, self.allocator, ref);
                }
                if (field.on_delete) |od| {
                    try buf.appendSlice(self.allocator, ",\"onDelete\":");
                    try writeJsonString(&buf, self.allocator, onDeleteName(od));
                }
                try buf.append(self.allocator, '}');
            }

            try buf.appendSlice(self.allocator, "},\"required\":[");
            var first_req = true;
            for (table.fields) |field| {
                if (field.required) {
                    if (!first_req) try buf.append(self.allocator, ',');
                    try writeJsonString(&buf, self.allocator, field.name);
                    first_req = false;
                }
            }
            try buf.appendSlice(self.allocator, "]}");
        }

        try buf.appendSlice(self.allocator, "}}");
        return buf.toOwnedSlice(self.allocator);
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

pub fn fieldTypeName(ft: FieldType) []const u8 {
    return switch (ft) {
        .text => "string",
        .integer => "integer",
        .real => "number",
        .boolean => "boolean",
        .array => "array",
    };
}

pub fn parseOnDelete(s: []const u8) ?OnDelete {
    if (std.mem.eql(u8, s, "cascade")) return .cascade;
    if (std.mem.eql(u8, s, "restrict")) return .restrict;
    if (std.mem.eql(u8, s, "set_null")) return .set_null;
    return null;
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
