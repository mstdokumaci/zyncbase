const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Metadata = struct {
    json: []const u8,

    pub fn clone(self: Metadata, allocator: Allocator) !Metadata {
        return .{ .json = try allocator.dupe(u8, self.json) };
    }

    pub fn deinit(self: Metadata, allocator: Allocator) void {
        allocator.free(self.json);
    }
};

pub const FieldType = enum {
    text,
    doc_id,
    integer,
    real,
    boolean,
    array,

    pub fn toSqlType(self: FieldType) []const u8 {
        return switch (self) {
            .text => "TEXT",
            .doc_id => "BLOB",
            .integer => "INTEGER",
            .real => "REAL",
            .boolean => "INTEGER",
            .array => "BLOB",
        };
    }

    pub fn schemaName(self: FieldType) []const u8 {
        return switch (self) {
            .text => "string",
            .doc_id => "string",
            .integer => "integer",
            .real => "number",
            .boolean => "boolean",
            .array => "array",
        };
    }
};

pub const StorageType = FieldType;

pub const OnDelete = enum {
    cascade,
    restrict,
    set_null,

    pub fn schemaName(self: OnDelete) []const u8 {
        return switch (self) {
            .cascade => "cascade",
            .restrict => "restrict",
            .set_null => "set_null",
        };
    }
};

pub const FieldKind = enum {
    system,
    user,
    timestamp,
};

pub const Field = struct {
    name: []const u8,
    name_quoted: []const u8 = "",
    declared_type: FieldType,
    storage_type: StorageType,
    items_type: ?FieldType = null,
    required: bool = false,
    indexed: bool = false,
    references: ?[]const u8 = null,
    on_delete: ?OnDelete = null,
    kind: FieldKind = .user,
    metadata: ?Metadata = null,

    pub fn clone(self: Field, allocator: Allocator) !Field {
        const cloned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(cloned_name);

        const cloned_name_quoted = try allocator.dupe(u8, self.name_quoted);
        errdefer allocator.free(cloned_name_quoted);

        const cloned_ref = if (self.references) |ref| try allocator.dupe(u8, ref) else null;
        errdefer if (cloned_ref) |ref| allocator.free(ref);

        const cloned_metadata = if (self.metadata) |metadata| try metadata.clone(allocator) else null;
        errdefer if (cloned_metadata) |metadata| metadata.deinit(allocator);

        return .{
            .name = cloned_name,
            .name_quoted = cloned_name_quoted,
            .declared_type = self.declared_type,
            .storage_type = self.storage_type,
            .items_type = self.items_type,
            .required = self.required,
            .indexed = self.indexed,
            .references = cloned_ref,
            .on_delete = self.on_delete,
            .kind = self.kind,
            .metadata = cloned_metadata,
        };
    }

    pub fn deinit(self: Field, allocator: Allocator) void {
        if (self.kind == .system or self.kind == .timestamp) return;
        allocator.free(self.name);
        allocator.free(self.name_quoted);
        if (self.references) |ref| allocator.free(ref);
        if (self.metadata) |metadata| metadata.deinit(allocator);
    }

    pub fn isSystem(self: Field) bool {
        return self.kind == .system or self.kind == .timestamp;
    }
};

pub const Table = struct {
    name: []const u8,
    name_quoted: []const u8 = "",
    fields: []const Field,
    namespaced: bool = true,
    is_users_table: bool = false,
    index: usize = 0,
    field_index_map: ?std.StringHashMap(usize) = null,
    has_index: bool = false,
    canonical_fields: bool = false,
    user_field_start: usize = 0,
    user_field_end: usize = 0,
    metadata: ?Metadata = null,

    pub fn deinit(self: *Table, allocator: Allocator) void {
        if (self.has_index) {
            if (self.field_index_map) |*map| map.deinit();
        }
        for (self.fields) |f| f.deinit(allocator);
        allocator.free(self.fields);
        allocator.free(self.name);
        allocator.free(self.name_quoted);
        if (self.metadata) |metadata| metadata.deinit(allocator);
    }

    pub fn field(self: *const Table, name: []const u8) ?Field {
        const idx = self.fieldIndex(name) orelse return null;
        return self.fields[idx];
    }

    pub fn fieldIndex(self: *const Table, name: []const u8) ?usize {
        if (self.has_index) {
            const map = self.field_index_map orelse return null;
            return map.get(name);
        }
        for (self.fields, 0..) |candidate, idx| {
            if (std.mem.eql(u8, candidate.name, name)) return idx;
        }
        return null;
    }

    pub fn userFields(self: *const Table) []const Field {
        if (!self.canonical_fields) return self.fields;
        return self.fields[self.user_field_start..self.user_field_end];
    }
};

pub const Schema = struct {
    allocator: Allocator,
    version: []const u8,
    tables: []Table,
    table_index_map: ?std.StringHashMap(usize) = null,
    has_index: bool = false,
    metadata: ?Metadata = null,

    pub fn init(allocator: Allocator, json_text: []const u8) !Schema {
        return @import("parse.zig").initFromJson(allocator, json_text);
    }

    pub fn initFromTables(allocator: Allocator, version: []const u8, tables: []const Table) !Schema {
        return @import("parse.zig").initFromTables(allocator, version, null, tables);
    }

    pub fn deinit(self: *Schema) void {
        if (self.has_index) {
            if (self.table_index_map) |*map| map.deinit();
        }
        for (self.tables) |*tbl| tbl.deinit(self.allocator);
        self.allocator.free(self.tables);
        self.allocator.free(self.version);
        if (self.metadata) |metadata| metadata.deinit(self.allocator);
    }

    pub fn table(self: *const Schema, name: []const u8) ?*const Table {
        const idx = (self.table_index_map orelse return null).get(name) orelse return null;
        return &self.tables[idx];
    }

    pub fn getTable(self: *const Schema, name: []const u8) ?*const Table {
        return self.table(name);
    }

    pub fn tableByIndex(self: *const Schema, index: usize) ?*const Table {
        if (index >= self.tables.len) return null;
        return &self.tables[index];
    }

    pub fn getTableByIndex(self: *const Schema, index: usize) ?*const Table {
        return self.tableByIndex(index);
    }

    pub fn format(self: *const Schema, allocator: Allocator) ![]const u8 {
        return @import("format.zig").format(allocator, self);
    }
};
