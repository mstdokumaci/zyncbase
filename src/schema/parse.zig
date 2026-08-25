const std = @import("std");

const json_read = @import("../json/read.zig");
const sql_strings = @import("../sql/build.zig");
const schema_constraints = @import("constraints.zig");
const field_path = @import("field_path.zig");
const index = @import("index.zig");
const system = @import("system.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const store_field_keys = [_][]const u8{
    "type", "indexed", "references", "onDelete",  "items",     "fields",  "metadata",
    "enum", "pattern", "format",     "minLength", "maxLength", "minimum", "maximum",
};

const presence_leaf_field_keys = [_][]const u8{
    "type", "enum", "pattern", "format", "minLength", "maxLength", "minimum", "maximum",
};

fn cloneMetadata(allocator: Allocator, value: std.json.Value) !types.Metadata {
    if (value != .object) return error.InvalidMetadata;
    return .{ .json = try std.json.Stringify.valueAlloc(allocator, value, .{}) };
}

pub fn initFromJson(allocator: Allocator, json_text: []const u8) !types.Schema {
    var parsed = try json_read.parseValue(allocator, json_text);
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidSchema;

    try json_read.rejectUnknownKeys(error.UnknownSchemaKey, &.{ "version", "store", "metadata", "presence" }, root.object);

    const version_val = (json_read.getString(root.object, "version") catch return error.InvalidVersion) orelse return error.MissingVersion;

    const store_val = (json_read.getObject(root.object, "store") catch return error.InvalidStore) orelse return error.MissingStore;

    const root_metadata = if (root.object.get("metadata")) |metadata|
        try cloneMetadata(allocator, metadata)
    else
        null;
    defer if (root_metadata) |metadata| metadata.deinit(allocator);

    var declared_tables = std.ArrayListUnmanaged(types.Table).empty;
    defer {
        for (declared_tables.items) |*table| table.deinit(allocator);
        declared_tables.deinit(allocator);
    }

    try collectTables(allocator, store_val, &declared_tables);

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
    try user_names.ensureTotalCapacityPrecise(allocator, presence_user_fields.items.len);
    for (presence_user_fields.items) |f| user_names.appendAssumeCapacity(f.name);

    var shared_names = std.ArrayListUnmanaged([]const u8).empty;
    defer shared_names.deinit(allocator);
    try shared_names.ensureTotalCapacityPrecise(allocator, presence_shared_fields.items.len);
    for (presence_shared_fields.items) |f| shared_names.appendAssumeCapacity(f.name);

    return initFromTables(
        allocator,
        version_val,
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
        try json_read.rejectUnknownKeys(error.UnknownSchemaKey, &.{ "user", "shared" }, po);
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
    try parseObjectFields(allocator, tier_val.object, "", PresenceFieldContext, &ctx);
}

fn hasConstraintKeys(field_obj: std.json.ObjectMap) bool {
    return field_obj.contains("enum") or
        field_obj.contains("pattern") or
        field_obj.contains("format") or
        field_obj.contains("minLength") or
        field_obj.contains("maxLength") or
        field_obj.contains("minimum") or
        field_obj.contains("maximum");
}

/// Shared recursive object-field parser. Flattens nested objects using `__` prefix.
/// Parameterized via comptime Ctx for store vs presence field logic.
fn parseObjectFields(
    allocator: Allocator,
    fields_value: std.json.ObjectMap,
    prefix: []const u8,
    comptime Ctx: type,
    ctx: *Ctx,
) !void {
    var it = fields_value.iterator();
    while (it.next()) |entry| {
        const field_name = entry.key_ptr.*;
        const field_def = entry.value_ptr.*;
        if (!isValidFieldIdentifier(field_name)) return error.InvalidFieldName;
        if (field_def != .object) return error.InvalidFieldDefinition;

        const type_value = (json_read.getString(field_def.object, "type") catch return error.InvalidFieldType) orelse return error.MissingFieldType;
        try ctx.preValidate(field_name, type_value, field_def);

        const full_name = try field_path.join(allocator, prefix, field_name);
        errdefer allocator.free(full_name);

        if (std.mem.eql(u8, type_value, "object")) {
            if (hasConstraintKeys(field_def.object)) {
                return error.InvalidConstraint;
            }
            try ctx.preObjectValidate(full_name);
            const nested_fields = (json_read.getObject(field_def.object, "fields") catch return error.InvalidSchema) orelse return error.MissingFields;
            try parseObjectFields(allocator, nested_fields, full_name, Ctx, ctx);
            allocator.free(full_name);
        } else {
            const declared_type = try Ctx.fieldType(type_value);
            try ctx.emitField(allocator, full_name, declared_type, field_def);
        }
    }
}

fn parseConstraints(allocator: Allocator, declared_type: types.FieldType, field_obj: std.json.ObjectMap) !?types.Constraints {
    if (!hasConstraintKeys(field_obj)) {
        return null;
    }

    const has_pattern = field_obj.contains("pattern");
    const has_format = field_obj.contains("format");
    const has_min_length = field_obj.contains("minLength");
    const has_max_length = field_obj.contains("maxLength");
    const has_min = field_obj.contains("minimum");
    const has_max = field_obj.contains("maximum");

    // Type compatibility checks
    if (declared_type == .array or declared_type == .boolean or declared_type == .doc_id) {
        return error.InvalidConstraint;
    }
    if (declared_type != .text and (has_pattern or has_format or has_min_length or has_max_length)) {
        return error.InvalidConstraint;
    }
    if (declared_type != .integer and declared_type != .real and (has_min or has_max)) {
        return error.InvalidConstraint;
    }

    var enum_values: ?[]const types.Constraints.EnumValue = null;
    var pattern_source: ?[]const u8 = null;
    var compiled_regex: ?*anyopaque = null;
    var format: ?types.Constraints.Format = null;
    var min_length: ?u64 = null;
    var max_length: ?u64 = null;
    var minimum: ?types.Constraints.Bound = null;
    var maximum: ?types.Constraints.Bound = null;

    errdefer {
        if (enum_values) |enums| {
            for (enums) |e| e.deinit(allocator);
            allocator.free(enums);
        }
        if (pattern_source) |p| allocator.free(p);
        if (compiled_regex) |r| schema_constraints.freePattern(allocator, r);
    }

    if (field_obj.get("enum")) |enum_val| {
        if (enum_val != .array) return error.InvalidConstraint;
        const items = enum_val.array.items;
        if (items.len == 0) return error.InvalidConstraint;

        const list = try allocator.alloc(types.Constraints.EnumValue, items.len);
        var built: usize = 0;
        errdefer {
            for (list[0..built]) |e| e.deinit(allocator);
            allocator.free(list);
        }

        for (items) |item| {
            switch (declared_type) {
                .text => {
                    if (item != .string) return error.InvalidConstraint;
                    list[built] = .{ .text = try allocator.dupe(u8, item.string) };
                },
                .integer => {
                    if (item != .integer) return error.InvalidConstraint;
                    list[built] = .{ .integer = item.integer };
                },
                .real => {
                    const num: f64 = switch (item) {
                        .float => |f| f,
                        .integer => |i| @floatFromInt(i),
                        else => return error.InvalidConstraint,
                    };
                    list[built] = .{ .real = num };
                },
                else => return error.InvalidConstraint,
            }
            built += 1;
        }
        enum_values = list;
    }

    if (field_obj.get("pattern")) |pattern_val| {
        if (pattern_val != .string or pattern_val.string.len == 0 or std.mem.indexOfScalar(u8, pattern_val.string, 0) != null) return error.InvalidConstraint;
        const reg = schema_constraints.compilePattern(allocator, pattern_val.string) catch return error.InvalidConstraint;
        compiled_regex = reg;
        pattern_source = try allocator.dupe(u8, pattern_val.string);
    }

    if (field_obj.get("format")) |format_val| {
        if (format_val != .string) return error.InvalidConstraint;
        format = types.Constraints.Format.fromString(format_val.string) orelse return error.InvalidConstraint;
    }

    if (field_obj.get("minLength")) |min_l_val| {
        if (min_l_val != .integer or min_l_val.integer < 0) return error.InvalidConstraint;
        min_length = @intCast(min_l_val.integer);
    }

    if (field_obj.get("maxLength")) |max_l_val| {
        if (max_l_val != .integer or max_l_val.integer < 0) return error.InvalidConstraint;
        max_length = @intCast(max_l_val.integer);
    }

    if (min_length != null and max_length != null) {
        if (min_length.? > max_length.?) return error.InvalidConstraint;
    }

    if (field_obj.get("minimum")) |min_val| {
        switch (declared_type) {
            .integer => {
                const val: i64 = switch (min_val) {
                    .integer => |i| i,
                    .float => |f| blk: {
                        if (std.math.isNan(f) or std.math.isInf(f)) return error.InvalidConstraint;
                        if (f != @trunc(f)) return error.InvalidConstraint;
                        if (f < -9007199254740992.0 or f > 9007199254740992.0) return error.InvalidConstraint;
                        break :blk @intFromFloat(f);
                    },
                    else => return error.InvalidConstraint,
                };
                minimum = .{ .integer = val };
            },
            .real => {
                const val: f64 = switch (min_val) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => return error.InvalidConstraint,
                };
                if (std.math.isNan(val) or std.math.isInf(val)) return error.InvalidConstraint;
                minimum = .{ .real = val };
            },
            else => return error.InvalidConstraint,
        }
    }

    if (field_obj.get("maximum")) |max_val| {
        switch (declared_type) {
            .integer => {
                const val: i64 = switch (max_val) {
                    .integer => |i| i,
                    .float => |f| blk: {
                        if (std.math.isNan(f) or std.math.isInf(f)) return error.InvalidConstraint;
                        if (f != @trunc(f)) return error.InvalidConstraint;
                        if (f < -9007199254740992.0 or f > 9007199254740992.0) return error.InvalidConstraint;
                        break :blk @intFromFloat(f);
                    },
                    else => return error.InvalidConstraint,
                };
                maximum = .{ .integer = val };
            },
            .real => {
                const val: f64 = switch (max_val) {
                    .float => |f| f,
                    .integer => |i| @floatFromInt(i),
                    else => return error.InvalidConstraint,
                };
                if (std.math.isNan(val) or std.math.isInf(val)) return error.InvalidConstraint;
                maximum = .{ .real = val };
            },
            else => return error.InvalidConstraint,
        }
    }

    if (minimum != null and maximum != null) {
        switch (declared_type) {
            .integer => {
                if (minimum.?.integer > maximum.?.integer) return error.InvalidConstraint;
            },
            .real => {
                if (minimum.?.real > maximum.?.real) return error.InvalidConstraint;
            },
            else => return error.InvalidConstraint,
        }
    }

    return .{
        .enum_values = enum_values,
        .pattern_source = pattern_source,
        .compiled_regex = compiled_regex,
        .format = format,
        .min_length = min_length,
        .max_length = max_length,
        .minimum = minimum,
        .maximum = maximum,
    };
}

/// Context for store-field parsing (handles required_set, array items, references, etc.)
const StoreFieldContext = struct {
    fields: *std.ArrayListUnmanaged(types.Field),
    required_set: *std.StringHashMap(bool),
    reserve_external_id: bool,

    fn preValidate(ctx: *@This(), name: []const u8, _: []const u8, def: std.json.Value) !void {
        if (system.isSystemColumn(name)) return error.ReservedFieldName;
        if (ctx.reserve_external_id and std.mem.eql(u8, name, "external_id")) return error.ReservedFieldName;
        try json_read.rejectUnknownKeys(error.UnknownSchemaKey, &store_field_keys, def.object);
    }

    fn preObjectValidate(ctx: *@This(), full_name: []const u8) !void {
        if (ctx.required_set.contains(full_name)) return error.InvalidRequiredField;
    }

    fn fieldType(type_str: []const u8) !types.FieldType {
        return field_type_map.get(type_str) orelse error.UnknownFieldType;
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
        const indexed = (json_read.getBool(field_def.object, "indexed") catch return error.InvalidFieldDefinition) orelse false;
        const references = try extractReferences(allocator, field_def.object);
        errdefer if (references) |ref| allocator.free(ref);

        if (references != null) {
            if (declared_type != .text) return error.InvalidFieldType;
            storage_type = .doc_id;
        }

        const on_delete = try extractOnDelete(field_def.object, references != null, required);

        const metadata = if (field_def.object.get("metadata")) |value|
            try cloneMetadata(allocator, value)
        else
            null;
        errdefer if (metadata) |md| md.deinit(allocator);

        const constraints = try parseConstraints(allocator, declared_type, field_def.object);
        errdefer if (constraints) |c| c.deinit(allocator);

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
            .constraints = constraints,
        });
    }
};

/// Context for presence-field parsing (no nesting limit, max 500 flat fields)
const PresenceFieldContext = struct {
    fields_list: *std.ArrayListUnmanaged(types.PresenceField),

    fn preValidate(_: *@This(), _: []const u8, type_str: []const u8, def: std.json.Value) !void {
        if (std.mem.eql(u8, type_str, "object")) {
            try json_read.rejectUnknownKeys(error.UnknownSchemaKey, &.{ "type", "fields" }, def.object);
        } else {
            try json_read.rejectUnknownKeys(error.UnknownSchemaKey, &presence_leaf_field_keys, def.object);
        }
    }

    fn preObjectValidate(_: *@This(), _: []const u8) !void {}

    fn fieldType(type_str: []const u8) !types.FieldType {
        return array_item_type_map.get(type_str) orelse error.UnknownFieldType;
    }

    fn emitField(ctx: *@This(), allocator: Allocator, full_name: []const u8, declared_type: types.FieldType, field_def: std.json.Value) !void {
        if (ctx.fields_list.items.len >= max_presence_fields) return error.InvalidSchema;
        const constraints = try parseConstraints(allocator, declared_type, field_def.object);
        errdefer if (constraints) |c| c.deinit(allocator);

        try ctx.fields_list.append(allocator, .{
            .name = full_name,
            .declared_type = declared_type,
            .constraints = constraints,
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
    try json_read.rejectUnknownKeys(error.UnknownSchemaKey, &.{ "fields", "required", "namespaced", "metadata", "unique" }, table_def.object);

    const table_name = try allocator.dupe(u8, table_name_raw);
    errdefer allocator.free(table_name);
    const table_name_quoted = try quoteIdentifier(allocator, table_name_raw);
    errdefer allocator.free(table_name_quoted);

    const table_metadata = if (table_def.object.get("metadata")) |metadata|
        try cloneMetadata(allocator, metadata)
    else
        null;
    errdefer if (table_metadata) |metadata| metadata.deinit(allocator);

    const namespaced = (json_read.getBool(table_def.object, "namespaced") catch return error.InvalidTableDefinition) orelse !is_users_table;

    var required_set = std.StringHashMap(bool).init(allocator);
    defer {
        var key_it = required_set.keyIterator();
        while (key_it.next()) |key| allocator.free(key.*);
        required_set.deinit();
    }

    if (json_read.getArray(table_def.object, "required") catch return error.InvalidTableDefinition) |required_value| {
        if (is_users_table) return error.InvalidTableDefinition;
        for (required_value.items) |item| {
            if (item != .string) return error.InvalidTableDefinition;
            const normalized = try field_path.normalizeDots(allocator, item.string);
            errdefer allocator.free(normalized);
            const gop = try required_set.getOrPut(normalized);
            if (gop.found_existing) {
                allocator.free(normalized);
            } else {
                gop.value_ptr.* = false;
            }
        }
    }

    var fields = std.ArrayListUnmanaged(types.Field).empty;
    errdefer {
        for (fields.items) |field| field.deinit(allocator);
        fields.deinit(allocator);
    }

    const fields_value = (json_read.getObject(table_def.object, "fields") catch return error.InvalidSchema) orelse return error.MissingFields;
    try parseFields(allocator, fields_value, &fields, &required_set, "", is_users_table);

    var req_it = required_set.iterator();
    while (req_it.next()) |entry| {
        if (!entry.value_ptr.*) return error.InvalidRequiredField;
    }

    const unique_constraints = try parseUniqueConstraints(allocator, table_def.object, fields.items);
    errdefer if (unique_constraints.len > 0) {
        for (unique_constraints) |c| c.deinit(allocator);
        allocator.free(unique_constraints);
    };

    return .{
        .name = table_name,
        .name_quoted = table_name_quoted,
        .fields = try fields.toOwnedSlice(allocator),
        .namespaced = namespaced,
        .is_users_table = is_users_table,
        .metadata = table_metadata,
        .unique_constraints = unique_constraints,
    };
}

/// Parse the table-level `unique` array into owned constraints whose field
/// indexes are relative to `fields` (the declared user-field list, in order).
fn parseUniqueConstraints(
    allocator: Allocator,
    table_obj: std.json.ObjectMap,
    declared_fields: []const types.Field,
) ![]const types.UniqueConstraint {
    const unique_value = (json_read.getArray(table_obj, "unique") catch return error.InvalidUniqueConstraint) orelse return &.{};
    if (unique_value.items.len == 0) return &.{};

    const constraints = try allocator.alloc(types.UniqueConstraint, unique_value.items.len);
    var built: usize = 0;
    errdefer {
        for (constraints[0..built]) |c| c.deinit(allocator);
        allocator.free(constraints);
    }

    for (unique_value.items) |constraint_value| {
        if (constraint_value != .array) return error.InvalidUniqueConstraint;
        const components = constraint_value.array.items;
        if (components.len == 0) return error.InvalidUniqueConstraint;

        const indexes = try allocator.alloc(usize, components.len);
        errdefer allocator.free(indexes);

        for (components, 0..) |component, ci| {
            if (component != .string) return error.InvalidUniqueConstraint;
            const normalized = try field_path.normalizeDots(allocator, component.string);
            defer allocator.free(normalized);

            const field_index = blk: {
                for (declared_fields, 0..) |field, fi| {
                    if (std.mem.eql(u8, field.name, normalized)) break :blk fi;
                }
                // Missing or system field name.
                return error.InvalidUniqueConstraint;
            };

            // ponytail: O(n²) duplicate-set scan below; schema counts are
            // startup-bounded — hash sets only if startup profiling proves it.
            for (indexes[0..ci]) |seen| {
                if (seen == field_index) return error.InvalidUniqueConstraint;
            }
            indexes[ci] = field_index;
        }

        // Reject duplicate constraint field sets regardless of order.
        for (constraints[0..built]) |existing| {
            if (existing.field_indexes.len != indexes.len) continue;
            var all_matched = true;
            for (indexes) |idx| {
                var found = false;
                for (existing.field_indexes) |other| {
                    if (other == idx) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    all_matched = false;
                    break;
                }
            }
            if (all_matched) return error.InvalidUniqueConstraint;
        }

        constraints[built] = .{ .field_indexes = indexes };
        built += 1;
    }

    return constraints[0..built];
}

fn parseFields(
    allocator: Allocator,
    fields_value: std.json.ObjectMap,
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

    // Constraints stay relative to `userFields()`; no system-field offset is applied.
    var unique_constraints: []const types.UniqueConstraint = &.{};
    var unique_owned_by_table = false;
    errdefer if (!unique_owned_by_table) {
        for (unique_constraints) |c| c.deinit(allocator);
        allocator.free(unique_constraints);
    };
    if (declared.unique_constraints.len > 0) {
        const cloned_constraints = try allocator.alloc(types.UniqueConstraint, declared.unique_constraints.len);
        var built_constraints: usize = 0;
        errdefer {
            for (cloned_constraints[0..built_constraints]) |c| c.deinit(allocator);
            allocator.free(cloned_constraints);
        }
        for (declared.unique_constraints) |c| {
            cloned_constraints[built_constraints] = try c.clone(allocator);
            built_constraints += 1;
        }
        unique_constraints = cloned_constraints;
    }

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
        .unique_constraints = unique_constraints,
    };
    name_owned_by_table = true;
    name_quoted_owned_by_table = true;
    metadata_owned_by_table = true;
    fields_owned_by_table = true;
    unique_owned_by_table = true;
    errdefer table.deinit(allocator);

    try index.buildFieldIndex(allocator, &table);

    table.select_from_sql = try sql_strings.buildSelectFromSql(allocator, &table);
    table.select_document_sql = try sql_strings.buildSelectDocumentSql(allocator, table.select_from_sql);
    table.delete_document_sql_prefix = try sql_strings.buildDeleteDocumentSqlPrefix(allocator, &table);
    table.delete_document_sql_suffix = try sql_strings.buildDeleteDocumentSqlSuffix(allocator, &table);

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

const primitive_type_kvs = .{
    .{ "string", types.FieldType.text },
    .{ "integer", types.FieldType.integer },
    .{ "number", types.FieldType.real },
    .{ "boolean", types.FieldType.boolean },
};

const field_type_map = std.StaticStringMap(types.FieldType).initComptime(primitive_type_kvs ++ .{
    .{ "array", types.FieldType.array },
});

const array_item_type_map = std.StaticStringMap(types.FieldType).initComptime(primitive_type_kvs);

fn quoteIdentifier(allocator: Allocator, name: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{ "\"", name, "\"" });
}

fn extractArrayItemsType(declared_type: types.FieldType, field_def: std.json.Value) !?types.FieldType {
    if (declared_type != .array) return null;
    const items_val = (json_read.getString(field_def.object, "items") catch return error.InvalidArrayItems) orelse return error.MissingArrayItems;
    return array_item_type_map.get(items_val) orelse error.UnsupportedArrayItemsType;
}

fn extractReferences(allocator: Allocator, field_def: std.json.ObjectMap) !?[]const u8 {
    const val = (json_read.getString(field_def, "references") catch return error.InvalidReference) orelse return null;
    if (!isValidTableIdentifier(val)) return error.InvalidTableName;
    return try allocator.dupe(u8, val);
}

fn extractOnDelete(field_def: std.json.ObjectMap, has_references: bool, required: bool) !?types.OnDelete {
    const val = (json_read.getString(field_def, "onDelete") catch return error.InvalidOnDelete) orelse return if (has_references) .restrict else null;
    const parsed = std.meta.stringToEnum(types.OnDelete, val) orelse return error.InvalidOnDelete;
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
