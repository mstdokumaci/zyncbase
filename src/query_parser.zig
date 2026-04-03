const std = @import("std");
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;

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
    value: ?msgpack.Payload,

    pub fn deinit(self: Condition, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        if (self.value) |v| v.free(allocator);
    }

    pub fn clone(self: Condition, allocator: std.mem.Allocator) !Condition {
        return .{
            .field = try allocator.dupe(u8, self.field),
            .op = self.op,
            .value = if (self.value) |v| try v.deepClone(allocator) else null,
        };
    }
};

pub const SortDescriptor = struct {
    field: []const u8,
    desc: bool,

    pub fn deinit(self: SortDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
    }

    pub fn clone(self: SortDescriptor, allocator: std.mem.Allocator) !SortDescriptor {
        return .{
            .field = try allocator.dupe(u8, self.field),
            .desc = self.desc,
        };
    }
};

pub const Cursor = struct {
    sort_value: msgpack.Payload,
    id: []const u8,

    pub fn deinit(self: Cursor, allocator: std.mem.Allocator) void {
        self.sort_value.free(allocator);
        allocator.free(self.id);
    }

    pub fn clone(self: Cursor, allocator: std.mem.Allocator) !Cursor {
        return .{
            .sort_value = try self.sort_value.deepClone(allocator),
            .id = try allocator.dupe(u8, self.id),
        };
    }
};

pub const QueryFilter = struct {
    conditions: ?[]const Condition = null,
    or_conditions: ?[]const Condition = null,
    order_by: ?SortDescriptor = null,
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
        if (self.order_by) |sb| sb.deinit(allocator);
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
        if (self.order_by) |ob| {
            copy.order_by = try ob.clone(allocator);
        }
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
    var order_by: ?SortDescriptor = null;
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
        if (order_by) |sb| sb.deinit(allocator);
        if (after) |a| a.deinit(allocator);
    }

    var it = payload.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .str) continue;
        const key = entry.key_ptr.*.str.value();
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "conditions") and value == .arr) {
            if (conditions) |old| {
                for (old) |c| c.deinit(allocator);
                allocator.free(old);
            }
            conditions = try parseConditions(allocator, table_metadata, value);
        } else if (std.mem.eql(u8, key, "orConditions") and value == .arr) {
            if (or_conditions) |old| {
                for (old) |c| c.deinit(allocator);
                allocator.free(old);
            }
            or_conditions = try parseConditions(allocator, table_metadata, value);
        } else if (std.mem.eql(u8, key, "orderBy")) {
            if (order_by) |old| old.deinit(allocator);
            order_by = try parseSortDescriptor(allocator, table_metadata, value);
        } else if (std.mem.eql(u8, key, "limit")) {
            if (value == .uint) {
                limit = @intCast(value.uint);
            } else if (value == .int and value.int >= 0) {
                limit = @intCast(value.int);
            }
        } else if (std.mem.eql(u8, key, "after")) {
            if (value != .arr or value.arr.len != 2) return error.InvalidMessageFormat;
            if (value.arr[1] != .str) return error.InvalidMessageFormat;
            if (after) |old| old.deinit(allocator);
            after = Cursor{
                .sort_value = try value.arr[0].deepClone(allocator),
                .id = try allocator.dupe(u8, value.arr[1].str.value()),
            };
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

    // Validate field name exists in the schema
    if (table_metadata.getField(field) == null) {
        // Check for built-in fields
        if (!std.mem.eql(u8, field, "id") and
            !std.mem.eql(u8, field, "namespace_id") and
            !std.mem.eql(u8, field, "created_at") and
            !std.mem.eql(u8, field, "updated_at"))
        {
            return error.UnknownField;
        }
    }

    if (arr[1] != .uint and arr[1] != .int) return error.InvalidOperatorCode;
    const op_code = if (arr[1] == .uint) arr[1].uint else @as(u64, @intCast(arr[1].int));
    if (op_code > 12) return error.InvalidOperatorCode;
    const op: Operator = @enumFromInt(@as(u8, @intCast(op_code)));

    var value: ?msgpack.Payload = null;
    if (arr.len == 3) {
        value = try arr[2].deepClone(allocator);
    } else {
        // isNull and isNotNull don't require value
        if (op != .isNull and op != .isNotNull) return error.InvalidConditionFormat;
    }

    return Condition{
        .field = try allocator.dupe(u8, field),
        .op = op,
        .value = value,
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

    // Validate field name exists in the schema
    if (table_metadata.getField(field) == null) {
        // Check for built-in fields
        if (!std.mem.eql(u8, field, "id") and
            !std.mem.eql(u8, field, "namespace_id") and
            !std.mem.eql(u8, field, "created_at") and
            !std.mem.eql(u8, field, "updated_at"))
        {
            return error.UnknownField;
        }
    }

    if (arr[1] != .uint and arr[1] != .int) return error.InvalidSortFormat;
    const desc_val = if (arr[1] == .uint) arr[1].uint else @as(u64, @intCast(arr[1].int));

    return SortDescriptor{
        .field = try allocator.dupe(u8, field),
        .desc = desc_val == 1,
    };
}
