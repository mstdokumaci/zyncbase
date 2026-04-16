const std = @import("std");
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const types = @import("storage_engine/types.zig");
const TypedValue = types.TypedValue;

pub const Operator = enum(u8) {
    eq = 0,
    ne = 1,
    gt = 2,
    lt = 3,
    gte = 4,
    lte = 5,
    contains = 6,
    startsWith = 7,
    endsWith = 8,
    in = 9,
    notIn = 10,
    isNull = 11,
    isNotNull = 12,
};

pub const Condition = struct {
    field: []const u8,
    op: Operator,
    value: ?TypedValue,
    field_type: schema_manager.FieldType,
    items_type: ?schema_manager.FieldType,

    pub fn deinit(self: Condition, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        if (self.value) |v| v.deinit(allocator);
    }

    pub fn clone(self: Condition, allocator: std.mem.Allocator) !Condition {
        const field = try allocator.dupe(u8, self.field);
        errdefer allocator.free(field);
        return .{
            .field = field,
            .op = self.op,
            .value = if (self.value) |v| try v.clone(allocator) else null,
            .field_type = self.field_type,
            .items_type = self.items_type,
        };
    }
};

pub const SortDescriptor = struct {
    field: []const u8,
    desc: bool,
    field_type: schema_manager.FieldType,
    items_type: ?schema_manager.FieldType,

    pub fn deinit(self: SortDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
    }

    pub fn clone(self: SortDescriptor, allocator: std.mem.Allocator) !SortDescriptor {
        return .{
            .field = try allocator.dupe(u8, self.field),
            .desc = self.desc,
            .field_type = self.field_type,
            .items_type = self.items_type,
        };
    }
};

pub const Cursor = struct {
    sort_value: TypedValue,
    id: []const u8,

    pub fn deinit(self: Cursor, allocator: std.mem.Allocator) void {
        self.sort_value.deinit(allocator);
        allocator.free(self.id);
    }

    pub fn clone(self: Cursor, allocator: std.mem.Allocator) !Cursor {
        const sort_value = try self.sort_value.clone(allocator);
        errdefer sort_value.deinit(allocator);
        return .{
            .sort_value = sort_value,
            .id = try allocator.dupe(u8, self.id),
        };
    }
};

pub const QueryFilter = struct {
    conditions: ?[]const Condition = null,
    or_conditions: ?[]const Condition = null,
    order_by: SortDescriptor,
    limit: ?u32 = null,
    after: ?Cursor = null,

    pub fn deinit(self: QueryFilter, allocator: std.mem.Allocator) void {
        if (self.conditions) |conds| {
            for (conds) |c| c.deinit(allocator);
            allocator.free(conds);
        }
        if (self.or_conditions) |or_conds| {
            for (or_conds) |c| c.deinit(allocator);
            allocator.free(or_conds);
        }
        self.order_by.deinit(allocator);
        if (self.after) |a| a.deinit(allocator);
    }

    pub fn clone(self: QueryFilter, allocator: std.mem.Allocator) !QueryFilter {
        var copy = self;
        if (self.conditions) |conds| {
            const new_conds = try allocator.alloc(Condition, conds.len);
            errdefer allocator.free(new_conds);
            for (conds, 0..) |c, i| {
                new_conds[i] = try c.clone(allocator);
            }
            copy.conditions = new_conds;
        }
        if (self.or_conditions) |or_conds| {
            const new_or = try allocator.alloc(Condition, or_conds.len);
            errdefer allocator.free(new_or);
            for (or_conds, 0..) |c, i| {
                new_or[i] = try c.clone(allocator);
            }
            copy.or_conditions = new_or;
        }
        copy.order_by = try self.order_by.clone(allocator);
        if (self.after) |a| {
            copy.after = try a.clone(allocator);
        }
        return copy;
    }
};

pub const ParserError = error{
    InvalidMessageFormat,
    InvalidConditionFormat,
    InvalidOperatorCode,
    InvalidSortFormat,
    InvalidFieldName,
    InvalidTableName,
    MissingRequiredFields,
    UnknownTable,
    UnknownField,
    OutOfMemory,
};

/// Parse a Base64-encoded JSON cursor tuple token into a Cursor.
/// Expected decoded JSON shape: [sort_value, id]
pub fn parseCursorToken(
    allocator: std.mem.Allocator,
    token: []const u8,
    field_type: schema_manager.FieldType,
    items_type: ?schema_manager.FieldType,
) ParserError!Cursor {
    const cursor_payload = msgpack.decodeBase64(allocator, token) catch
        return error.InvalidMessageFormat;
    defer cursor_payload.free(allocator);

    if (cursor_payload != .arr or cursor_payload.arr.len != 2) return error.InvalidMessageFormat;
    if (cursor_payload.arr[1] != .str) return error.InvalidMessageFormat;

    const sort_value = TypedValue.fromPayload(allocator, field_type, items_type, cursor_payload.arr[0]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMessageFormat,
    };
    errdefer sort_value.deinit(allocator);

    return Cursor{
        .sort_value = sort_value,
        .id = try allocator.dupe(u8, cursor_payload.arr[1].str.value()),
    };
}

/// Parse a MessagePack Payload (expected to be a map) into a QueryFilter AST.
/// Validates all field names against the provided schema for the target collection.
/// The caller is responsible for calling `filter.deinit(allocator)` on success.
pub fn parseQueryFilter(
    allocator: std.mem.Allocator,
    sm: *const SchemaManager,
    collection: []const u8,
    payload: msgpack.Payload,
) ParserError!QueryFilter {
    if (payload != .map) return error.InvalidMessageFormat;

    // ADR-019: reject __ from client
    if (std.mem.containsAtLeast(u8, collection, 1, "__")) return error.InvalidTableName;

    // Find the table metadata in schema for validation
    const table_metadata = sm.getTable(collection) orelse return error.UnknownTable;

    var conditions: ?[]Condition = null;
    var or_conditions: ?[]Condition = null;
    const resolved_id = try resolveFieldMetadata(table_metadata, "id");
    var order_by: SortDescriptor = .{
        .field = try allocator.dupe(u8, "id"),
        .desc = false,
        .field_type = resolved_id.field_type,
        .items_type = resolved_id.items_type,
    };
    var limit: ?u32 = null;
    var after: ?Cursor = null;

    errdefer {
        if (conditions) |conds| {
            for (conds) |c| c.deinit(allocator);
            allocator.free(conds);
        }
        if (or_conditions) |or_conds| {
            for (or_conds) |c| c.deinit(allocator);
            allocator.free(or_conds);
        }
        order_by.deinit(allocator);
        if (after) |a| a.deinit(allocator);
    }

    var it = payload.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .str) continue;
        const key = entry.key_ptr.*.str.value();
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "conditions") and value == .arr) {
            const new_conds = try parseConditions(allocator, table_metadata, value);
            if (conditions) |old| {
                for (old) |c| c.deinit(allocator);
                allocator.free(old);
            }
            conditions = new_conds;
        } else if (std.mem.eql(u8, key, "orConditions") and value == .arr) {
            const new_or = try parseConditions(allocator, table_metadata, value);
            if (or_conditions) |old| {
                for (old) |c| c.deinit(allocator);
                allocator.free(old);
            }
            or_conditions = new_or;
        } else if (std.mem.eql(u8, key, "orderBy")) {
            const new_order_by = try parseSortDescriptor(allocator, table_metadata, value);
            order_by.deinit(allocator);
            order_by = new_order_by;
        } else if (std.mem.eql(u8, key, "limit")) {
            if (value == .uint) {
                limit = @intCast(value.uint);
            } else if (value == .int and value.int >= 0) {
                limit = @intCast(value.int);
            }
            if (limit != null and limit.? == 0) return error.InvalidMessageFormat;
        } else if (std.mem.eql(u8, key, "after")) {
            if (value != .str) return error.InvalidMessageFormat;
            const new_after = try parseCursorToken(allocator, value.str.value(), order_by.field_type, order_by.items_type);
            if (after) |old| old.deinit(allocator);
            after = new_after;
        }
    }

    return QueryFilter{
        .conditions = conditions,
        .or_conditions = or_conditions,
        .order_by = order_by,
        .limit = limit,
        .after = after,
    };
}

pub const ResolvedField = struct {
    field_type: schema_manager.FieldType,
    items_type: ?schema_manager.FieldType,
};

/// Resolves the metadata (FieldType and items_type) for a given field.
/// Handles both schema-defined fields and built-in system columns.
pub fn resolveFieldMetadata(
    table_metadata: schema_manager.TableMetadata,
    field: []const u8,
) ParserError!ResolvedField {
    if (table_metadata.getField(field)) |f| {
        return .{ .field_type = f.sql_type, .items_type = f.items_type };
    }
    // Built-in columns
    if (schema_manager.getSystemColumn(field)) |col| {
        return .{ .field_type = col.sql_type, .items_type = col.items_type };
    }
    return error.UnknownField;
}

fn parseConditions(
    allocator: std.mem.Allocator,
    table_metadata: schema_manager.TableMetadata,
    payload: msgpack.Payload,
) ParserError![]Condition {
    if (payload != .arr) return error.InvalidConditionFormat;
    const arr = payload.arr;
    const result = try allocator.alloc(Condition, arr.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |c| c.deinit(allocator);
        allocator.free(result);
    }

    for (arr) |item| {
        result[count] = try parseCondition(allocator, table_metadata, item);
        count += 1;
    }
    return result;
}

fn parseCondition(
    allocator: std.mem.Allocator,
    table_metadata: schema_manager.TableMetadata,
    payload: msgpack.Payload,
) ParserError!Condition {
    if (payload != .arr) return error.InvalidConditionFormat;
    const arr = payload.arr;
    if (arr.len < 2 or arr.len > 3) return error.InvalidConditionFormat;

    if (arr[0] != .str) return error.InvalidFieldName;
    const field = arr[0].str.value();
    const resolved = try resolveFieldMetadata(table_metadata, field);

    if (arr[1] != .uint and arr[1] != .int) return error.InvalidOperatorCode;
    const op_code = if (arr[1] == .uint) arr[1].uint else @as(u64, @intCast(arr[1].int));
    if (op_code > 12) return error.InvalidOperatorCode;
    const op: Operator = @enumFromInt(@as(u8, @intCast(op_code)));

    var value: ?TypedValue = null;
    if (arr.len == 3) {
        value = TypedValue.fromPayload(allocator, resolved.field_type, resolved.items_type, arr[2]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidConditionFormat,
        };
    } else {
        // isNull and isNotNull don't require value
        if (op != .isNull and op != .isNotNull) return error.InvalidConditionFormat;
    }
    errdefer if (value) |v| v.deinit(allocator);

    return Condition{
        .field = try allocator.dupe(u8, field),
        .op = op,
        .value = value,
        .field_type = resolved.field_type,
        .items_type = resolved.items_type,
    };
}

fn parseSortDescriptor(
    allocator: std.mem.Allocator,
    table_metadata: schema_manager.TableMetadata,
    payload: msgpack.Payload,
) ParserError!SortDescriptor {
    if (payload != .arr) return error.InvalidSortFormat;
    const arr = payload.arr;
    if (arr.len != 2) return error.InvalidSortFormat;

    if (arr[0] != .str) return error.InvalidFieldName;
    const field = arr[0].str.value();
    const resolved = try resolveFieldMetadata(table_metadata, field);

    if (arr[1] != .uint and arr[1] != .int) return error.InvalidSortFormat;
    const desc_val = if (arr[1] == .uint) arr[1].uint else @as(u64, @intCast(arr[1].int));

    return SortDescriptor{
        .field = try allocator.dupe(u8, field),
        .desc = desc_val == 1,
        .field_type = resolved.field_type,
        .items_type = resolved.items_type,
    };
}
