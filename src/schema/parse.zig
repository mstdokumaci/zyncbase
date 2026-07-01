const std = @import("std");
const types = @import("types.zig");
const system = @import("system.zig");
const json_read = @import("../json/read.zig");
const index = @import("index.zig");

const Allocator = std.mem.Allocator;

const planned_constraint_keys = [_][]const u8{
    "enum",
    "pattern",
    "format",
    "minLength",
    "maxLength",
    "minimum",
    "maximum",
};

pub fn initFromJson(allocator: Allocator, json_text: []const u8) !types.Schema {
    var parsed = try json_read.parseValue(allocator, json_text);
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidSchema;

    try rejectUnknownRootKeys(root);

    const version_val = root.object.get("version") orelse return error.MissingVersion;
    if (version_val != .string) return error.InvalidVersion;

    const store_val = root.object.get("store") orelse return error.MissingStore;
    if (store_val != .object) return error.InvalidStore;

    const root_metadata = if (root.object.get("metadata")) |metadata|
        try json_read.cloneMetadata(allocator, metadata)
    else
        null;
    defer if (root_metadata) |metadata| metadata.deinit(allocator);

    var declared_tables = std.ArrayListUnmanaged(types.Table).empty;
    defer {
        for (declared_tables.items) |*table| table.deinit(allocator);
        declared_tables.deinit(allocator);
    }

    try collectTables(allocator, store_val.object, &declared_tables);

    // Parse presence block if exists, else synthesize implicit minimal schema
    var presence_user_fields = std.ArrayListUnmanaged(types.PresenceField).empty;
    var presence_shared_fields = std.ArrayListUnmanaged(types.PresenceField).empty;
    defer {
        for (presence_user_fields.items) |f| f.deinit(allocator);
        presence_user_fields.deinit(allocator);
        for (presence_shared_fields.items) |f| f.deinit(allocator);
        presence_shared_fields.deinit(allocator);
    }

    try collectPresenceFields(allocator, root.object, &presence_user_fields, &presence_shared_fields);

    // Build name arrays for presence fields
    var user_names = std.ArrayListUnmanaged([]const u8).empty;
    defer user_names.deinit(allocator);
    for (presence_user_fields.items) |f| try user_names.append(allocator, f.name);

    var shared_names = std.ArrayListUnmanaged([]const u8).empty;
    defer shared_names.deinit(allocator);
    for (presence_shared_fields.items) |f| try shared_names.append(allocator, f.name);

    return initFromTables(
        allocator,
        version_val.string,
        root_metadata,
        declared_tables.items,
        presence_user_fields.items,
        presence_shared_fields.items,
        user_names.items,
        shared_names.items,
    );
}

fn collectTables(
    allocator: Allocator,
    store_obj: std.json.ObjectMap,
    declared_tables: *std.ArrayListUnmanaged(types.Table),
) !void {
    // Users table first — explicit or implicit
    if (store_obj.get("users")) |users_def| {
        var table = try parseTable(allocator, "users", users_def, true);
        var appended = false;
        errdefer if (!appended) table.deinit(allocator);
        try declared_tables.append(allocator, table);
        appended = true;
    } else {
        var table = try implicitUsersTable(allocator);
        var appended = false;
        errdefer if (!appended) table.deinit(allocator);
        try declared_tables.append(allocator, table);
        appended = true;
    }

    // Remaining store tables
    var store_iter = store_obj.iterator();
    while (store_iter.next()) |entry| {
        const table_name = entry.key_ptr.*;
        if (std.mem.eql(u8, table_name, "users")) continue;
        var table = try parseTable(allocator, table_name, entry.value_ptr.*, false);
        var appended = false;
        errdefer if (!appended) table.deinit(allocator);
        try declared_tables.append(allocator, table);
        appended = true;
    }
}

fn collectPresenceFields(
    allocator: Allocator,
    root_obj: std.json.ObjectMap,
    presence_user_fields: *std.ArrayListUnmanaged(types.PresenceField),
    presence_shared_fields: *std.ArrayListUnmanaged(types.PresenceField),
) !void {
    if (root_obj.get("presence")) |presence_val| {
        if (presence_val != .object) return error.InvalidSchema;
        const po = presence_val.object;
        if (po.get("user")) |user_val| {
            try parsePresenceTier(allocator, user_val, presence_user_fields);
        }
        if (po.get("shared")) |shared_val| {
            try parsePresenceTier(allocator, shared_val, presence_shared_fields);
        }
    } else {
        // Synthesize implicit minimal schema: user.status: string
        const status_name = try allocator.dupe(u8, "status");
        errdefer allocator.free(status_name);
        try presence_user_fields.append(allocator, .{
            .name = status_name,
            .declared_type = .text,
        });
    }
}

const max_presence_fields: usize = 500;
pub const max_store_fields: usize = 1024;

fn parsePresenceTier(
    allocator: Allocator,
    tier_val: std.json.Value,
    fields_list: *std.ArrayListUnmanaged(types.PresenceField),
) !void {
    if (tier_val != .object) return error.InvalidSchema;
    var ctx = PresenceFieldContext{ .fields_list = fields_list };
    try parseObjectFields(allocator, tier_val, "", PresenceFieldContext, &ctx);
}

/// Shared recursive object-field parser. Flattens nested objects using `__` prefix.
/// Parameterized via comptime Ctx for store vs presence field logic.
fn parseObjectFields(
    allocator: Allocator,
    fields_value: std.json.Value,
    prefix: []const u8,
    comptime Ctx: type,
    ctx: *Ctx,
) !void {
    if (fields_value != .object) return error.InvalidSchema;

    var it = fields_value.object.iterator();
    while (it.next()) |entry| {
        const field_name = entry.key_ptr.*;
        const field_def = entry.value_ptr.*;
        if (!isValidFieldIdentifier(field_name)) return error.InvalidFieldName;
        if (field_def != .object) return error.InvalidFieldDefinition;

        try ctx.preValidate(field_name, field_def);

        const type_value = field_def.object.get("type") orelse return error.MissingFieldType;
        if (type_value != .string) return error.InvalidFieldType;

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}__{s}", .{ prefix, field_name })
        else
            try allocator.dupe(u8, field_name);
        errdefer allocator.free(full_name);

        if (std.mem.eql(u8, type_value.string, "object")) {
            try ctx.preObjectValidate(full_name);
            const nested_fields = field_def.object.get("fields") orelse return error.MissingFields;
            if (nested_fields != .object) return error.InvalidSchema;
            try parseObjectFields(allocator, nested_fields, full_name, Ctx, ctx);
            allocator.free(full_name);
        } else {
            const declared_type = try Ctx.fieldType(type_value.string);
            try ctx.emitField(allocator, full_name, declared_type, field_def);
        }
    }
}

/// Context for store-field parsing (handles required_set, array items, references, etc.)
const StoreFieldContext = struct {
    fields: *std.ArrayListUnmanaged(types.Field),
    required_set: *std.StringHashMap(bool),
    reserve_external_id: bool,

    fn preValidate(ctx: *@This(), name: []const u8, def: std.json.Value) !void {
        if (system.isSystemColumn(name)) return error.ReservedFieldName;
        if (ctx.reserve_external_id and std.mem.eql(u8, name, "external_id")) return error.ReservedFieldName;
        try rejectUnknownFieldKeys(def);
    }

    fn preObjectValidate(ctx: *@This(), full_name: []const u8) !void {
        if (ctx.required_set.contains(full_name)) return error.InvalidRequiredField;
    }

    fn fieldType(type_str: []const u8) !types.FieldType {
        return mapType(type_str);
    }

    fn emitField(ctx: *@This(), allocator: Allocator, full_name: []const u8, declared_type: types.FieldType, field_def: std.json.Value) !void {
        if (ctx.fields.items.len >= max_store_fields) return error.TooManyFields;
        var storage_type = declared_type;
        var required = false;
        if (ctx.required_set.getPtr(full_name)) |seen| {
            seen.* = true;
            required = true;
        }

        const items_type = try extractArrayItemsType(declared_type, field_def);
        const indexed = try extractBoolOrDefault(field_def.object, "indexed", false);
        const references = try extractReferences(allocator, field_def.object);
        errdefer if (references) |ref| allocator.free(ref);

        if (references != null) {
            if (declared_type != .text) return error.InvalidFieldType;
            storage_type = .doc_id;
        }

        const on_delete = try extractOnDelete(field_def.object, references != null, required);

        const metadata = if (field_def.object.get("metadata")) |value|
            try json_read.cloneMetadata(allocator, value)
        else
            null;
        errdefer if (metadata) |md| md.deinit(allocator);

        const name_quoted = try quoteIdentifier(allocator, full_name);
        errdefer allocator.free(name_quoted);

        try ctx.fields.append(allocator, .{
            .name = full_name,
            .name_quoted = name_quoted,
            .declared_type = declared_type,
            .storage_type = storage_type,
            .items_type = items_type,
            .required = required,
            .indexed = indexed,
            .references = references,
            .on_delete = on_delete,
            .kind = .user,
            .metadata = metadata,
        });
    }
};

/// Context for presence-field parsing (no nesting limit, max 500 flat fields)
const PresenceFieldContext = struct {
    fields_list: *std.ArrayListUnmanaged(types.PresenceField),

    fn preValidate(_: *@This(), _: []const u8, _: std.json.Value) !void {}

    fn preObjectValidate(_: *@This(), _: []const u8) !void {}

    fn fieldType(type_str: []const u8) !types.FieldType {
        return mapPrimitiveType(type_str);
    }

    fn emitField(ctx: *@This(), allocator: Allocator, full_name: []const u8, declared_type: types.FieldType, _: std.json.Value) !void {
        if (ctx.fields_list.items.len >= max_presence_fields) return error.InvalidSchema;
        try ctx.fields_list.append(allocator, .{
            .name = full_name,
            .declared_type = declared_type,
        });
    }
};

pub fn initFromTables(
    allocator: Allocator,
    version: []const u8,
    root_metadata: ?types.Metadata,
    declared_tables: []const types.Table,
    presence_user_fields: []const types.PresenceField,
    presence_shared_fields: []const types.PresenceField,
    presence_user_fields_names: []const []const u8,
    presence_shared_fields_names: []const []const u8,
) !types.Schema {
    const version_owned = try allocator.dupe(u8, version);
    var version_owned_by_schema = false;
    errdefer if (!version_owned_by_schema) allocator.free(version_owned);

    var metadata_owned: ?types.Metadata = null;
    if (root_metadata) |metadata| {
        metadata_owned = try metadata.clone(allocator);
    }
    var metadata_owned_by_schema = false;
    errdefer if (!metadata_owned_by_schema) if (metadata_owned) |metadata| metadata.deinit(allocator);

    const owned_tables = try buildTablesSlice(allocator, declared_tables);
    var tables_owned_by_schema = false;
    errdefer if (!tables_owned_by_schema) {
        for (owned_tables.tables[0..owned_tables.built_count]) |*table| table.deinit(allocator);
        allocator.free(owned_tables.tables);
    };

    var presence_state = try clonePresenceState(
        allocator,
        presence_user_fields,
        presence_shared_fields,
        presence_user_fields_names,
        presence_shared_fields_names,
    );
    var presence_owned_by_schema = false;
    errdefer if (!presence_owned_by_schema) presence_state.deinit(allocator);

    var schema = types.Schema{
        .allocator = allocator,
        .version = version_owned,
        .tables = owned_tables.tables,
        .has_index = false,
        .metadata = metadata_owned,
        .presence_user_fields = presence_state.user_fields,
        .presence_shared_fields = presence_state.shared_fields,
        .presence_user_fields_names = presence_state.user_fields_names,
        .presence_shared_fields_names = presence_state.shared_fields_names,
    };
    version_owned_by_schema = true;
    metadata_owned_by_schema = true;
    tables_owned_by_schema = true;
    presence_owned_by_schema = true;
    errdefer schema.deinit();

    try index.buildTableIndex(allocator, &schema);
    try validateReferences(&schema);
    return schema;
}

fn clonePresenceFields(allocator: Allocator, fields: []const types.PresenceField) ![]const types.PresenceField {
    const cloned = try allocator.alloc(types.PresenceField, fields.len);
    var built: usize = 0;
    errdefer {
        for (cloned[0..built]) |f| f.deinit(allocator);
        allocator.free(cloned);
    }
    for (fields) |field| {
        cloned[built] = try field.clone(allocator);
        built += 1;
    }
    return cloned;
}

fn cloneStringSlice(allocator: Allocator, strings: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, strings.len);
    var built: usize = 0;
    errdefer {
        for (cloned[0..built]) |s| allocator.free(s);
        allocator.free(cloned);
    }
    for (strings) |s| {
        cloned[built] = try allocator.dupe(u8, s);
        built += 1;
    }
    return cloned;
}

const OwnedTables = struct {
    tables: []types.Table,
    built_count: usize,
};

fn buildTablesSlice(allocator: Allocator, declared_tables: []const types.Table) !OwnedTables {
    const has_users = blk: {
        for (declared_tables) |table| {
            if (std.mem.eql(u8, table.name, "users")) break :blk true;
        }
        break :blk false;
    };

    const table_count = declared_tables.len + @intFromBool(!has_users);
    var tables = try allocator.alloc(types.Table, table_count);
    var built_count: usize = 0;
    errdefer {
        for (tables[0..built_count]) |*table| table.deinit(allocator);
        allocator.free(tables);
    }

    if (has_users) {
        for (declared_tables) |table| {
            if (std.mem.eql(u8, table.name, "users")) {
                tables[built_count] = try buildRuntimeTable(allocator, table, built_count);
                built_count += 1;
                break;
            }
        }
    } else {
        const users = try implicitUsersTable(allocator);
        defer {
            var owned = users;
            owned.deinit(allocator);
        }
        tables[built_count] = try buildRuntimeTable(allocator, users, built_count);
        built_count += 1;
    }

    for (declared_tables) |table| {
        if (std.mem.eql(u8, table.name, "users")) continue;
        tables[built_count] = try buildRuntimeTable(allocator, table, built_count);
        built_count += 1;
    }

    return .{ .tables = tables, .built_count = built_count };
}

const PresenceState = struct {
    user_fields: []const types.PresenceField,
    shared_fields: []const types.PresenceField,
    user_fields_names: []const []const u8,
    shared_fields_names: []const []const u8,

    fn deinit(self: *PresenceState, allocator: Allocator) void {
        for (self.user_fields) |f| f.deinit(allocator);
        allocator.free(self.user_fields);
        for (self.shared_fields) |f| f.deinit(allocator);
        allocator.free(self.shared_fields);
        for (self.user_fields_names) |name| allocator.free(name);
        allocator.free(self.user_fields_names);
        for (self.shared_fields_names) |name| allocator.free(name);
        allocator.free(self.shared_fields_names);
    }
};

fn clonePresenceState(
    allocator: Allocator,
    presence_user_fields: []const types.PresenceField,
    presence_shared_fields: []const types.PresenceField,
    presence_user_fields_names: []const []const u8,
    presence_shared_fields_names: []const []const u8,
) !PresenceState {
    const user_fields = try clonePresenceFields(allocator, presence_user_fields);
    errdefer {
        for (user_fields) |f| f.deinit(allocator);
        allocator.free(user_fields);
    }

    const shared_fields = try clonePresenceFields(allocator, presence_shared_fields);
    errdefer {
        for (shared_fields) |f| f.deinit(allocator);
        allocator.free(shared_fields);
    }

    const user_fields_names = try cloneStringSlice(allocator, presence_user_fields_names);
    errdefer {
        for (user_fields_names) |name| allocator.free(name);
        allocator.free(user_fields_names);
    }

    const shared_fields_names = try cloneStringSlice(allocator, presence_shared_fields_names);
    errdefer {
        for (shared_fields_names) |name| allocator.free(name);
        allocator.free(shared_fields_names);
    }

    return .{
        .user_fields = user_fields,
        .shared_fields = shared_fields,
        .user_fields_names = user_fields_names,
        .shared_fields_names = shared_fields_names,
    };
}

fn implicitUsersTable(allocator: Allocator) !types.Table {
    const name = try allocator.dupe(u8, "users");
    errdefer allocator.free(name);
    const name_quoted = try quoteIdentifier(allocator, "users");
    errdefer allocator.free(name_quoted);
    const fields = try allocator.alloc(types.Field, 0);
    return .{
        .name = name,
        .name_quoted = name_quoted,
        .fields = fields,
        .namespaced = false,
        .is_users_table = true,
    };
}

fn parseTable(allocator: Allocator, table_name_raw: []const u8, table_def: std.json.Value, is_users_table: bool) !types.Table {
    if (!isValidTableIdentifier(table_name_raw)) return error.InvalidTableName;
    if (table_def != .object) return error.InvalidTableDefinition;
    try rejectUnknownTableKeys(table_def);

    const table_name = try allocator.dupe(u8, table_name_raw);
    errdefer allocator.free(table_name);
    const table_name_quoted = try quoteIdentifier(allocator, table_name_raw);
    errdefer allocator.free(table_name_quoted);

    const table_metadata = if (table_def.object.get("metadata")) |metadata|
        try json_read.cloneMetadata(allocator, metadata)
    else
        null;
    errdefer if (table_metadata) |metadata| metadata.deinit(allocator);

    const namespaced = if (table_def.object.get("namespaced")) |value| blk: {
        if (value != .bool) return error.InvalidTableDefinition;
        break :blk value.bool;
    } else !is_users_table;

    var required_set = std.StringHashMap(bool).init(allocator);
    defer {
        var key_it = required_set.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        required_set.deinit();
    }

    if (table_def.object.get("required")) |required_value| {
        if (is_users_table) return error.InvalidTableDefinition;
        if (required_value != .array) return error.InvalidTableDefinition;
        for (required_value.array.items) |item| {
            if (item != .string) return error.InvalidTableDefinition;
            const normalized = try std.mem.replaceOwned(u8, allocator, item.string, ".", "__");
            errdefer allocator.free(normalized);
            try required_set.put(normalized, false);
        }
    }

    var fields = std.ArrayListUnmanaged(types.Field).empty;
    errdefer {
        for (fields.items) |field| field.deinit(allocator);
        fields.deinit(allocator);
    }

    const fields_value = table_def.object.get("fields") orelse return error.MissingFields;
    try parseFields(allocator, fields_value, &fields, &required_set, "", is_users_table);

    var req_it = required_set.iterator();
    while (req_it.next()) |entry| {
        if (!entry.value_ptr.*) return error.InvalidRequiredField;
    }

    return .{
        .name = table_name,
        .name_quoted = table_name_quoted,
        .fields = try fields.toOwnedSlice(allocator),
        .namespaced = namespaced,
        .is_users_table = is_users_table,
        .metadata = table_metadata,
    };
}

fn parseFields(
    allocator: Allocator,
    fields_value: std.json.Value,
    fields: *std.ArrayListUnmanaged(types.Field),
    required_set: *std.StringHashMap(bool),
    prefix: []const u8,
    reserve_external_id: bool,
) !void {
    var ctx = StoreFieldContext{
        .fields = fields,
        .required_set = required_set,
        .reserve_external_id = reserve_external_id,
    };
    try parseObjectFields(allocator, fields_value, prefix, StoreFieldContext, &ctx);
}

pub fn buildRuntimeTable(allocator: Allocator, declared: types.Table, table_index: usize) !types.Table {
    const name = try allocator.dupe(u8, declared.name);
    var name_owned_by_table = false;
    errdefer if (!name_owned_by_table) allocator.free(name);

    const name_quoted = if (declared.name_quoted.len > 0)
        try allocator.dupe(u8, declared.name_quoted)
    else
        try quoteIdentifier(allocator, declared.name);
    var name_quoted_owned_by_table = false;
    errdefer if (!name_quoted_owned_by_table) allocator.free(name_quoted);

    const metadata = if (declared.metadata) |md| try md.clone(allocator) else null;
    var metadata_owned_by_table = false;
    errdefer if (!metadata_owned_by_table) if (metadata) |md| md.deinit(allocator);

    const total_fields = system.leading_system_field_count + declared.fields.len + system.trailing_system_field_count;
    var fields = try allocator.alloc(types.Field, total_fields);
    var count: usize = 0;
    var fields_owned_by_table = false;
    errdefer if (!fields_owned_by_table) {
        for (fields[0..count]) |field| field.deinit(allocator);
        allocator.free(fields);
    };

    for (system.leading_system_fields) |field| {
        fields[count] = field;
        count += 1;
    }

    const user_field_start = count;
    for (declared.fields) |field| {
        fields[count] = try cloneUserField(allocator, field);
        fields[count].kind = .user;
        count += 1;
    }
    const user_field_end = count;

    for (system.trailing_system_fields) |field| {
        fields[count] = field;
        count += 1;
    }

    var table = types.Table{
        .name = name,
        .name_quoted = name_quoted,
        .fields = fields,
        .namespaced = declared.namespaced,
        .is_users_table = std.mem.eql(u8, declared.name, "users") or declared.is_users_table,
        .index = table_index,
        .canonical_fields = true,
        .user_field_start = user_field_start,
        .user_field_end = user_field_end,
        .metadata = metadata,
    };
    name_owned_by_table = true;
    name_quoted_owned_by_table = true;
    metadata_owned_by_table = true;
    fields_owned_by_table = true;
    errdefer table.deinit(allocator);

    try index.buildFieldIndex(allocator, &table);
    return table;
}

fn cloneUserField(allocator: Allocator, field: types.Field) !types.Field {
    var cloned = try field.clone(allocator);
    errdefer cloned.deinit(allocator);

    if (cloned.name_quoted.len == 0) {
        allocator.free(cloned.name_quoted);
        cloned.name_quoted = try quoteIdentifier(allocator, cloned.name);
    }

    return cloned;
}

fn validateReferences(schema: *const types.Schema) !void {
    for (schema.tables) |table| {
        for (table.userFields()) |field| {
            if (field.references) |target| {
                if (schema.table(target) == null) return error.InvalidReference;
            }
        }
    }
}

pub fn mapType(type_str: []const u8) !types.FieldType {
    if (std.mem.eql(u8, type_str, "string")) return .text;
    if (std.mem.eql(u8, type_str, "integer")) return .integer;
    if (std.mem.eql(u8, type_str, "number")) return .real;
    if (std.mem.eql(u8, type_str, "boolean")) return .boolean;
    if (std.mem.eql(u8, type_str, "array")) return .array;
    return error.UnknownFieldType;
}

pub fn mapPrimitiveType(type_str: []const u8) !types.FieldType {
    const field_type = mapType(type_str) catch return error.UnsupportedArrayItemsType;
    if (field_type == .array) return error.UnsupportedArrayItemsType;
    return field_type;
}

pub fn parseOnDelete(value: []const u8) !types.OnDelete {
    if (std.mem.eql(u8, value, "cascade")) return .cascade;
    if (std.mem.eql(u8, value, "restrict")) return .restrict;
    if (std.mem.eql(u8, value, "set_null")) return .set_null;
    return error.InvalidOnDelete;
}

fn quoteIdentifier(allocator: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{name});
}

fn rejectUnknownRootKeys(root: std.json.Value) !void {
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "version")) continue;
        if (std.mem.eql(u8, key, "store")) continue;
        if (std.mem.eql(u8, key, "metadata")) continue;
        if (std.mem.eql(u8, key, "presence")) continue;
        return error.UnknownSchemaKey;
    }
}

fn rejectUnknownTableKeys(table_def: std.json.Value) !void {
    var it = table_def.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "fields")) continue;
        if (std.mem.eql(u8, key, "required")) continue;
        if (std.mem.eql(u8, key, "namespaced")) continue;
        if (std.mem.eql(u8, key, "metadata")) continue;
        return error.UnknownSchemaKey;
    }
}

fn rejectUnknownFieldKeys(field_def: std.json.Value) !void {
    var it = field_def.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) continue;
        if (std.mem.eql(u8, key, "indexed")) continue;
        if (std.mem.eql(u8, key, "references")) continue;
        if (std.mem.eql(u8, key, "onDelete")) continue;
        if (std.mem.eql(u8, key, "items")) continue;
        if (std.mem.eql(u8, key, "fields")) continue;
        if (std.mem.eql(u8, key, "metadata")) continue;
        if (isPlannedConstraintKey(key)) continue;
        return error.UnknownSchemaKey;
    }
}

fn isPlannedConstraintKey(key: []const u8) bool {
    for (planned_constraint_keys) |planned| {
        if (std.mem.eql(u8, key, planned)) return true;
    }
    return false;
}

fn extractArrayItemsType(declared_type: types.FieldType, field_def: std.json.Value) !?types.FieldType {
    if (declared_type != .array) return null;
    const items_val = field_def.object.get("items") orelse return error.MissingArrayItems;
    if (items_val != .string) return error.InvalidArrayItems;
    return try mapPrimitiveType(items_val.string);
}

fn extractBoolOrDefault(field_def: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const val = field_def.get(key) orelse return default;
    if (val != .bool) return error.InvalidFieldDefinition;
    return val.bool;
}

fn extractReferences(allocator: Allocator, field_def: std.json.ObjectMap) !?[]const u8 {
    const val = field_def.get("references") orelse return null;
    if (val != .string) return error.InvalidReference;
    if (!isValidTableIdentifier(val.string)) return error.InvalidTableName;
    return try allocator.dupe(u8, val.string);
}

fn extractOnDelete(field_def: std.json.ObjectMap, has_references: bool, required: bool) !?types.OnDelete {
    const val = field_def.get("onDelete") orelse return if (has_references) .restrict else null;
    if (val != .string) return error.InvalidOnDelete;
    const parsed = try parseOnDelete(val.string);
    if (parsed == .set_null and required) return error.InvalidOnDelete;
    return parsed;
}

fn isValidTableIdentifier(name: []const u8) bool {
    if (!isValidSchemaIdentifier(name)) return false;
    if (system.isInternalTableName(name)) return false;
    return true;
}

fn isValidFieldIdentifier(name: []const u8) bool {
    return isValidSchemaIdentifier(name);
}

fn isValidSchemaIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0])) return false;
    if (std.mem.containsAtLeast(u8, name, 1, "__")) return false;

    for (name[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    }
    return true;
}
