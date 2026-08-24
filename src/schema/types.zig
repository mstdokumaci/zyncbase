const std = @import("std");

const schema_constraints = @import("constraints.zig");

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

pub const Constraints = struct {
    enum_values: ?[]const EnumValue = null,
    pattern_source: ?[]const u8 = null,
    compiled_regex: ?*anyopaque = null,
    format: ?Format = null,
    min_length: ?u64 = null,
    max_length: ?u64 = null,
    minimum: ?Bound = null,
    maximum: ?Bound = null,

    pub const Bound = union(enum) {
        integer: i64,
        real: f64,
    };

    pub const EnumValue = union(enum) {
        text: []const u8,
        integer: i64,
        real: f64,

        pub fn clone(self: EnumValue, allocator: Allocator) !EnumValue {
            return switch (self) {
                .text => |t| .{ .text = try allocator.dupe(u8, t) },
                .integer => |i| .{ .integer = i },
                .real => |r| .{ .real = r },
            };
        }

        pub fn deinit(self: EnumValue, allocator: Allocator) void {
            switch (self) {
                .text => |t| allocator.free(t),
                else => {},
            }
        }
    };

    pub const Format = enum {
        email,
        uuid,
        uri,

        pub fn schemaName(self: Format) []const u8 {
            return switch (self) {
                .email => "email",
                .uuid => "uuid",
                .uri => "uri",
            };
        }

        pub fn fromString(str: []const u8) ?Format {
            if (std.mem.eql(u8, str, "email")) return .email;
            if (std.mem.eql(u8, str, "uuid")) return .uuid;
            if (std.mem.eql(u8, str, "uri")) return .uri;
            return null;
        }
    };

    pub fn hasAny(self: Constraints) bool {
        return self.enum_values != null or
            self.pattern_source != null or
            self.format != null or
            self.min_length != null or
            self.max_length != null or
            self.minimum != null or
            self.maximum != null;
    }

    pub fn clone(self: Constraints, allocator: Allocator) !Constraints {
        var cloned_enums: ?[]const EnumValue = null;
        if (self.enum_values) |enums| {
            const list = try allocator.alloc(EnumValue, enums.len);
            var built: usize = 0;
            errdefer {
                for (list[0..built]) |e| e.deinit(allocator);
                allocator.free(list);
            }
            for (enums) |e| {
                list[built] = try e.clone(allocator);
                built += 1;
            }
            cloned_enums = list;
        }
        errdefer if (cloned_enums) |enums| {
            for (enums) |e| e.deinit(allocator);
            allocator.free(enums);
        };

        var cloned_pattern: ?[]const u8 = null;
        var cloned_regex: ?*anyopaque = null;
        errdefer {
            if (cloned_pattern) |p| allocator.free(p);
            if (cloned_regex) |r| schema_constraints.freePattern(allocator, r);
        }
        if (self.pattern_source) |src| {
            cloned_pattern = try allocator.dupe(u8, src);
            if (self.compiled_regex != null) {
                cloned_regex = try schema_constraints.compilePattern(allocator, src);
            }
        }

        return .{
            .enum_values = cloned_enums,
            .pattern_source = cloned_pattern,
            .compiled_regex = cloned_regex,
            .format = self.format,
            .min_length = self.min_length,
            .max_length = self.max_length,
            .minimum = self.minimum,
            .maximum = self.maximum,
        };
    }

    pub fn deinit(self: Constraints, allocator: Allocator) void {
        if (self.enum_values) |enums| {
            for (enums) |e| e.deinit(allocator);
            allocator.free(enums);
        }
        if (self.pattern_source) |p| allocator.free(p);
        if (self.compiled_regex) |r| schema_constraints.freePattern(allocator, r);
    }
};

pub const FieldKind = enum {
    system,
    user,
    timestamp,
};

/// One declared table-level unique constraint.
/// Indexes are relative to `Table.userFields()`, in schema order.
/// Every non-empty constraint owns its `field_indexes` allocation;
/// empty constraint slices use the static `&.{}` value and are not freed.
pub const UniqueConstraint = struct {
    field_indexes: []const usize = &.{},

    pub fn clone(self: UniqueConstraint, allocator: Allocator) !UniqueConstraint {
        if (self.field_indexes.len == 0) return self;
        return .{ .field_indexes = try allocator.dupe(usize, self.field_indexes) };
    }

    pub fn deinit(self: UniqueConstraint, allocator: Allocator) void {
        if (self.field_indexes.len > 0) allocator.free(self.field_indexes);
    }
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
    constraints: ?Constraints = null,

    pub fn clone(self: Field, allocator: Allocator) !Field {
        const cloned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(cloned_name);

        const cloned_name_quoted = try allocator.dupe(u8, self.name_quoted);
        errdefer allocator.free(cloned_name_quoted);

        const cloned_ref = if (self.references) |ref| try allocator.dupe(u8, ref) else null;
        errdefer if (cloned_ref) |ref| allocator.free(ref);

        const cloned_metadata = if (self.metadata) |metadata| try metadata.clone(allocator) else null;
        errdefer if (cloned_metadata) |metadata| metadata.deinit(allocator);

        const cloned_constraints = if (self.constraints) |c| try c.clone(allocator) else null;
        errdefer if (cloned_constraints) |c| c.deinit(allocator);

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
            .constraints = cloned_constraints,
        };
    }

    pub fn deinit(self: Field, allocator: Allocator) void {
        if (self.kind == .system or self.kind == .timestamp) return;
        allocator.free(self.name);
        allocator.free(self.name_quoted);
        if (self.references) |ref| allocator.free(ref);
        if (self.metadata) |metadata| metadata.deinit(allocator);
        if (self.constraints) |c| c.deinit(allocator);
    }

    pub fn isSystem(self: Field) bool {
        return self.kind == .system or self.kind == .timestamp;
    }

    pub fn needsLengthCheck(self: Field) bool {
        return self.storage_type == .doc_id;
    }
};

pub const Table = struct {
    name: []const u8,
    name_quoted: []const u8 = "",
    fields: []const Field,
    namespaced: bool = true,
    is_users_table: bool = false,
    index: usize = 0,
    has_incoming_cascade_or_set_null: bool = false,
    /// Always populated for runtime tables (built by `buildRuntimeTable`).
    /// Bare declared-table literals use the empty default — they are never
    /// queried and only `deinit`'d (a no-op on an empty map).
    field_index_map: std.StringHashMapUnmanaged(usize) = .{},
    canonical_fields: bool = false,
    user_field_start: usize = 0,
    user_field_end: usize = 0,
    metadata: ?Metadata = null,
    /// Declared unique constraints; indexes are relative to `userFields()`.
    /// Empty slices use the static `&.{}` value and are not freed.
    unique_constraints: []const UniqueConstraint = &.{},
    /// Pre-built `SELECT <cols> FROM "<table>"`. Empty on bare Table literals.
    select_from_sql: []const u8 = "",
    /// Pre-built `SELECT <cols> FROM "<table>" WHERE "id"=? AND "namespace_id"=?`. Empty on bare literals.
    select_document_sql: []const u8 = "",
    /// DELETE prefix `DELETE FROM "<t>" WHERE "id"=? AND "namespace_id"=?`. Empty on bare literals.
    delete_document_sql_prefix: []const u8 = "",
    /// DELETE ` RETURNING <cols>` suffix. Empty on bare literals.
    delete_document_sql_suffix: []const u8 = "",

    pub fn deinit(self: *Table, allocator: Allocator) void {
        self.field_index_map.deinit(allocator);
        for (self.unique_constraints) |c| c.deinit(allocator);
        if (self.unique_constraints.len > 0) allocator.free(self.unique_constraints);
        for (self.fields) |f| f.deinit(allocator);
        allocator.free(self.fields);
        allocator.free(self.name);
        allocator.free(self.name_quoted);
        if (self.metadata) |metadata| metadata.deinit(allocator);
        if (self.select_from_sql.len > 0) allocator.free(self.select_from_sql);
        if (self.select_document_sql.len > 0) allocator.free(self.select_document_sql);
        if (self.delete_document_sql_prefix.len > 0) allocator.free(self.delete_document_sql_prefix);
        if (self.delete_document_sql_suffix.len > 0) allocator.free(self.delete_document_sql_suffix);
    }

    pub fn field(self: *const Table, name: []const u8) ?Field {
        const idx = self.fieldIndex(name) orelse return null;
        return self.fields[idx];
    }

    pub fn fieldIndex(self: *const Table, name: []const u8) ?usize {
        return self.field_index_map.get(name);
    }

    pub fn userFields(self: *const Table) []const Field {
        if (!self.canonical_fields) return self.fields;
        return self.fields[self.user_field_start..self.user_field_end];
    }
};

pub const PresenceField = struct {
    name: []const u8,
    declared_type: FieldType,
    constraints: ?Constraints = null,

    pub fn clone(self: PresenceField, allocator: Allocator) !PresenceField {
        const cloned_name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(cloned_name);

        const cloned_constraints = if (self.constraints) |c| try c.clone(allocator) else null;
        errdefer if (cloned_constraints) |c| c.deinit(allocator);

        return .{
            .name = cloned_name,
            .declared_type = self.declared_type,
            .constraints = cloned_constraints,
        };
    }

    pub fn deinit(self: PresenceField, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.constraints) |c| c.deinit(allocator);
    }
};

pub const Schema = struct {
    allocator: Allocator,
    version: []const u8,
    tables: []Table,
    /// Always populated for runtime schemas (built by `buildTableIndex`).
    /// A bare `Schema` literal uses the empty default — never queried,
    /// `deinit` is a no-op on an empty map.
    table_index_map: std.StringHashMapUnmanaged(usize) = .{},
    metadata: ?Metadata = null,

    // Presence fields
    presence_user_fields: []const PresenceField,
    presence_shared_fields: []const PresenceField,
    presence_user_fields_names: []const []const u8,
    presence_shared_fields_names: []const []const u8,

    pub fn deinit(self: *Schema) void {
        self.table_index_map.deinit(self.allocator);
        for (self.tables) |*tbl| tbl.deinit(self.allocator);
        self.allocator.free(self.tables);
        self.allocator.free(self.version);
        if (self.metadata) |metadata| metadata.deinit(self.allocator);

        for (self.presence_user_fields) |f| f.deinit(self.allocator);
        self.allocator.free(self.presence_user_fields);
        for (self.presence_shared_fields) |f| f.deinit(self.allocator);
        self.allocator.free(self.presence_shared_fields);

        for (self.presence_user_fields_names) |name| self.allocator.free(name);
        self.allocator.free(self.presence_user_fields_names);
        for (self.presence_shared_fields_names) |name| self.allocator.free(name);
        self.allocator.free(self.presence_shared_fields_names);
    }

    pub fn table(self: *const Schema, name: []const u8) ?*const Table {
        const idx = self.table_index_map.get(name) orelse return null;
        return &self.tables[idx];
    }

    pub fn tableByIndex(self: *const Schema, index: usize) ?*const Table {
        if (index >= self.tables.len) return null;
        return &self.tables[index];
    }
};
