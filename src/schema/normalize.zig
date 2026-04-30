const std = @import("std");
const types = @import("types.zig");
const system = @import("system.zig");
const json = @import("json.zig");
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
    var parsed = try json.parseValue(allocator, json_text);
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidSchema;

    try rejectUnknownRootKeys(root);

    const version_val = root.object.get("version") orelse return error.MissingVersion;
    if (version_val != .string) return error.InvalidVersion;

    const store_val = root.object.get("store") orelse return error.MissingStore;
    if (store_val != .object) return error.InvalidStore;

    const root_metadata = if (root.object.get("metadata")) |metadata|
        try json.cloneMetadata(allocator, metadata)
    else
        null;
    defer if (root_metadata) |metadata| metadata.deinit(allocator);

    var declared_tables = std.ArrayListUnmanaged(types.Table).empty;
    defer {
        for (declared_tables.items) |*table| table.deinit(allocator);
        declared_tables.deinit(allocator);
    }

    if (store_val.object.get("users")) |users_def| {
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

    var store_iter = store_val.object.iterator();
    while (store_iter.next()) |entry| {
        const table_name = entry.key_ptr.*;
        if (std.mem.eql(u8, table_name, "users")) continue;
        var table = try parseTable(allocator, table_name, entry.value_ptr.*, false);
        var appended = false;
        errdefer if (!appended) table.deinit(allocator);
        try declared_tables.append(allocator, table);
        appended = true;
    }

    return initFromTables(allocator, version_val.string, root_metadata, declared_tables.items);
}

pub fn initFromTables(
    allocator: Allocator,
    version: []const u8,
    root_metadata: ?types.Metadata,
    declared_tables: []const types.Table,
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

    const has_users = blk: {
        for (declared_tables) |table| {
            if (std.mem.eql(u8, table.name, "users")) break :blk true;
        }
        break :blk false;
    };

    const table_count = declared_tables.len + @intFromBool(!has_users);
    var tables = try allocator.alloc(types.Table, table_count);
    var built_count: usize = 0;
    var tables_owned_by_schema = false;
    errdefer if (!tables_owned_by_schema) {
        for (tables[0..built_count]) |*table| table.deinit(allocator);
        allocator.free(tables);
    };

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

    var schema = types.Schema{
        .allocator = allocator,
        .version = version_owned,
        .tables = tables,
        .has_index = false,
        .metadata = metadata_owned,
    };
    version_owned_by_schema = true;
    metadata_owned_by_schema = true;
    tables_owned_by_schema = true;
    errdefer schema.deinit();

    try index.buildTableIndex(allocator, &schema);
    try validateReferences(&schema);
    return schema;
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
        try json.cloneMetadata(allocator, metadata)
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
    if (fields_value != .object) return error.InvalidSchema;

    var it = fields_value.object.iterator();
    while (it.next()) |entry| {
        const field_name = entry.key_ptr.*;
        const field_def = entry.value_ptr.*;

        if (!isValidFieldIdentifier(field_name)) return error.InvalidFieldName;
        if (system.isSystemColumn(field_name)) return error.ReservedFieldName;
        if (reserve_external_id and std.mem.eql(u8, field_name, "external_id")) return error.ReservedFieldName;
        if (field_def != .object) return error.InvalidFieldDefinition;
        try rejectUnknownFieldKeys(field_def);

        const type_value = field_def.object.get("type") orelse return error.MissingFieldType;
        if (type_value != .string) return error.InvalidFieldType;

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}__{s}", .{ prefix, field_name })
        else
            try allocator.dupe(u8, field_name);
        errdefer allocator.free(full_name);

        if (std.mem.eql(u8, type_value.string, "object")) {
            if (required_set.contains(full_name)) return error.InvalidRequiredField;
            const nested_fields = field_def.object.get("fields") orelse return error.MissingFields;
            try parseFields(allocator, nested_fields, fields, required_set, full_name, reserve_external_id);
            allocator.free(full_name);
            continue;
        }

        const declared_type = try mapType(type_value.string);
        var storage_type = declared_type;

        var required = false;
        if (required_set.getPtr(full_name)) |seen| {
            seen.* = true;
            required = true;
        }

        var items_type: ?types.FieldType = null;
        if (declared_type == .array) {
            const items_value = field_def.object.get("items") orelse return error.MissingArrayItems;
            if (items_value != .string) return error.InvalidArrayItems;
            items_type = try mapPrimitiveType(items_value.string);
        }

        const indexed = if (field_def.object.get("indexed")) |value| blk: {
            if (value != .bool) return error.InvalidFieldDefinition;
            break :blk value.bool;
        } else false;

        const references = if (field_def.object.get("references")) |value| blk: {
            if (value != .string) return error.InvalidReference;
            if (!isValidTableIdentifier(value.string)) return error.InvalidTableName;
            break :blk try allocator.dupe(u8, value.string);
        } else null;
        errdefer if (references) |ref| allocator.free(ref);

        if (references != null) {
            if (declared_type != .text) return error.InvalidFieldType;
            storage_type = .doc_id;
        }

        const on_delete: ?types.OnDelete = if (field_def.object.get("onDelete")) |value| blk: {
            if (value != .string) return error.InvalidOnDelete;
            break :blk try parseOnDelete(value.string);
        } else if (references != null) .restrict else null;

        if (on_delete) |on_del| {
            if (on_del == .set_null and required) return error.InvalidOnDelete;
        }

        const metadata = if (field_def.object.get("metadata")) |value|
            try json.cloneMetadata(allocator, value)
        else
            null;
        errdefer if (metadata) |md| md.deinit(allocator);

        const name_quoted = try quoteIdentifier(allocator, full_name);
        errdefer allocator.free(name_quoted);

        try fields.append(allocator, .{
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
}

fn buildRuntimeTable(allocator: Allocator, declared: types.Table, table_index: usize) !types.Table {
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
        fields[count] = try field.clone(allocator);
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
        fields[count] = try field.clone(allocator);
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
