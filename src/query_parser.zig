const std = @import("std");
const msgpack = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const FieldType = schema_manager.FieldType;

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
    value: ?msgpack.Payload = null,
    field_type: ?FieldType = null,
    items_type: ?FieldType = null,
    canonical_value: ?CanonicalValue = null,
    canonical_list: ?[]const CanonicalValue = null,

    pub fn deinit(self: Condition, allocator: std.mem.Allocator) void {
        allocator.free(self.field);
        if (self.value) |v| v.free(allocator);
        if (self.canonical_value) |v| v.deinit(allocator);
        if (self.canonical_list) |list| {
            CanonicalValue.deinitSlice(allocator, list);
            allocator.free(list);
        }
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, slice: []const Condition) void {
        for (slice) |c| c.deinit(allocator);
    }

    pub fn clone(self: Condition, allocator: std.mem.Allocator) !Condition {
        const field = try allocator.dupe(u8, self.field);
        errdefer allocator.free(field);
        const cloned_value = if (self.value) |v| try v.deepClone(allocator) else null;
        errdefer if (cloned_value) |v| v.free(allocator);
        const cloned_canonical_value = if (self.canonical_value) |v| try v.clone(allocator) else null;
        errdefer if (cloned_canonical_value) |v| v.deinit(allocator);
        const cloned_canonical_list = if (self.canonical_list) |items| try cloneCanonicalList(allocator, items) else null;
        return .{
            .field = field,
            .op = self.op,
            .value = cloned_value,
            .field_type = self.field_type,
            .items_type = self.items_type,
            .canonical_value = cloned_canonical_value,
            .canonical_list = cloned_canonical_list,
        };
    }
};

fn cloneCanonicalList(allocator: std.mem.Allocator, items: []const CanonicalValue) ![]CanonicalValue {
    const out = try allocator.alloc(CanonicalValue, items.len);
    var i: usize = 0;
    errdefer {
        while (i > 0) : (i -= 1) out[i - 1].deinit(allocator);
        allocator.free(out);
    }
    for (items, 0..) |it, idx| {
        out[idx] = try it.clone(allocator);
        i += 1;
    }
    return out;
}

pub const SortDescriptor = struct {
    field: []const u8,
    desc: bool,
    field_type: ?FieldType = null,
    items_type: ?FieldType = null,

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
    sort_value: ?msgpack.Payload = null,
    id: []const u8,
    canonical_sort_value: ?CanonicalValue = null,
    sort_field_type: ?FieldType = null,
    sort_items_type: ?FieldType = null,

    pub fn deinit(self: Cursor, allocator: std.mem.Allocator) void {
        if (self.sort_value) |v| v.free(allocator);
        allocator.free(self.id);
        if (self.canonical_sort_value) |v| v.deinit(allocator);
    }

    pub fn clone(self: Cursor, allocator: std.mem.Allocator) !Cursor {
        const sort_value = if (self.sort_value) |v| try v.deepClone(allocator) else null;
        errdefer if (sort_value) |v| v.free(allocator);
        const canonical_sort_value = if (self.canonical_sort_value) |v| try v.clone(allocator) else null;
        errdefer if (canonical_sort_value) |v| v.deinit(allocator);
        return .{
            .sort_value = sort_value,
            .id = try allocator.dupe(u8, self.id),
            .canonical_sort_value = canonical_sort_value,
            .sort_field_type = self.sort_field_type,
            .sort_items_type = self.sort_items_type,
        };
    }
};

pub const CanonicalValue = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8,
    boolean: bool,
    nil: void,

    pub fn deinit(self: CanonicalValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn deinitSlice(allocator: std.mem.Allocator, slice: []const CanonicalValue) void {
        for (slice) |v| v.deinit(allocator);
    }

    pub fn clone(self: CanonicalValue, allocator: std.mem.Allocator) !CanonicalValue {
        return switch (self) {
            .integer => |v| .{ .integer = v },
            .real => |v| .{ .real = v },
            .text => |s| .{ .text = try allocator.dupe(u8, s) },
            .boolean => |b| .{ .boolean = b },
            .nil => .nil,
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
        deinitConditions(allocator, self.conditions);
        deinitConditions(allocator, self.or_conditions);
        if (self.order_by) |sb| sb.deinit(allocator);
        if (self.after) |a| a.deinit(allocator);
    }

    pub fn deinitConditions(allocator: std.mem.Allocator, conditions: ?[]const Condition) void {
        if (conditions) |conds| {
            Condition.deinitSlice(allocator, conds);
            allocator.free(conds);
        }
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
    TypeMismatch,
    MissingOperand,
    UnexpectedOperand,
    InvalidOperandType,
    InvalidInOperand,
    NullOperandUnsupported,
    UnsupportedOperatorForFieldType,
    InvalidCursorSortValue,
    OutOfMemory,
};

/// Parse a Base64-encoded JSON cursor tuple token into a Cursor.
/// Expected decoded JSON shape: [sort_value, id]
pub fn parseCursorToken(
    allocator: std.mem.Allocator,
    token: []const u8,
) ParserError!Cursor {
    const cursor_payload = msgpack.decodeBase64(allocator, token) catch
        return error.InvalidMessageFormat;
    defer cursor_payload.free(allocator);

    if (cursor_payload != .arr or cursor_payload.arr.len != 2) return error.InvalidMessageFormat;
    if (cursor_payload.arr[1] != .str) return error.InvalidMessageFormat;

    return Cursor{
        .sort_value = blk: {
            const p = try cursor_payload.arr[0].deepClone(allocator);
            errdefer p.free(allocator);
            break :blk p;
        },
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

    // Find the table metadata in schema for validation and normalization
    const table_metadata = sm.getTable(collection) orelse return error.UnknownTable;

    var filter = QueryFilter{};
    errdefer filter.deinit(allocator);

    var it = payload.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .str) continue;
        const key = entry.key_ptr.*.str.value();
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, key, "conditions") and value == .arr) {
            QueryFilter.deinitConditions(allocator, filter.conditions);
            filter.conditions = try parseConditions(allocator, table_metadata, value);
        } else if (std.mem.eql(u8, key, "orConditions") and value == .arr) {
            QueryFilter.deinitConditions(allocator, filter.or_conditions);
            filter.or_conditions = try parseConditions(allocator, table_metadata, value);
        } else if (std.mem.eql(u8, key, "orderBy")) {
            if (filter.order_by) |old| old.deinit(allocator);
            filter.order_by = try parseSortDescriptor(allocator, table_metadata, value);
        } else if (std.mem.eql(u8, key, "limit")) {
            if (value == .uint) {
                filter.limit = @intCast(value.uint);
            } else if (value == .int and value.int >= 0) {
                filter.limit = @intCast(value.int);
            }
            if (filter.limit != null and filter.limit.? == 0) return error.InvalidMessageFormat;
        } else if (std.mem.eql(u8, key, "after")) {
            if (value != .str) return error.InvalidMessageFormat;
            if (filter.after) |old| old.deinit(allocator);
            filter.after = try parseCursorToken(allocator, value.str.value());
        }
    }
    try normalizeFilterInPlace(allocator, table_metadata, &filter);
    return filter;
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
        Condition.deinitSlice(allocator, result[0..count]);
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

    var value: ?msgpack.Payload = null;
    if (arr.len == 3) {
        value = try arr[2].deepClone(allocator);
    } else {
        // isNull and isNotNull don't require value
        if (op != .isNull and op != .isNotNull) return error.InvalidConditionFormat;
    }
    errdefer if (value) |v| v.free(allocator);

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

pub const ResolvedField = struct {
    field_type: FieldType,
    items_type: ?FieldType,
};

pub fn resolveFieldMetadata(table_metadata: schema_manager.TableMetadata, field: []const u8) ParserError!ResolvedField {
    if (table_metadata.getField(field)) |f| {
        return .{ .field_type = f.sql_type, .items_type = f.items_type };
    }
    if (std.mem.eql(u8, field, "id")) return .{ .field_type = .text, .items_type = null };
    if (std.mem.eql(u8, field, "namespace_id")) return .{ .field_type = .text, .items_type = null };
    if (std.mem.eql(u8, field, "created_at")) return .{ .field_type = .integer, .items_type = null };
    if (std.mem.eql(u8, field, "updated_at")) return .{ .field_type = .integer, .items_type = null };
    return error.UnknownField;
}

fn normalizePayloadValue(
    allocator: std.mem.Allocator,
    field_type: FieldType,
    items_type: ?FieldType,
    payload: msgpack.Payload,
) ParserError!CanonicalValue {
    // Phase 1 scope: canonical scalar query semantics only.
    // Array-element typing (`items_type`) remains handled by the array compatibility path.
    _ = items_type;
    return switch (field_type) {
        .text => switch (payload) {
            .str => |s| .{ .text = try allocator.dupe(u8, s.value()) },
            .nil => .nil,
            else => error.TypeMismatch,
        },
        .integer => switch (payload) {
            .int => |v| .{ .integer = v },
            .uint => |v| .{ .integer = std.math.cast(i64, v) orelse return error.TypeMismatch },
            .nil => .nil,
            else => error.TypeMismatch,
        },
        .real => switch (payload) {
            .float => |v| .{ .real = v },
            .int => |v| .{ .real = @floatFromInt(v) },
            .uint => |v| .{ .real = @floatFromInt(v) },
            .nil => .nil,
            else => error.TypeMismatch,
        },
        .boolean => switch (payload) {
            .bool => |b| .{ .boolean = b },
            .nil => .nil,
            else => error.TypeMismatch,
        },
        .array => return error.TypeMismatch,
    };
}

fn normalizeConditionInPlace(
    allocator: std.mem.Allocator,
    cond: *Condition,
) ParserError!void {
    if (cond.value == null) {
        return switch (cond.op) {
            .isNull, .isNotNull => {},
            .in, .notIn => if (cond.canonical_list != null) {} else error.MissingOperand,
            else => if (cond.canonical_value != null) {} else error.MissingOperand,
        };
    }

    if (cond.canonical_value) |v| {
        v.deinit(allocator);
        cond.canonical_value = null;
    }
    if (cond.canonical_list) |list| {
        CanonicalValue.deinitSlice(allocator, list);
        allocator.free(list);
        cond.canonical_list = null;
    }

    const ft = cond.field_type orelse return error.UnknownField;
    const it = cond.items_type;

    if (cond.op == .isNull or cond.op == .isNotNull) {
        if (cond.value != null) return error.UnexpectedOperand;
        return;
    }

    const raw = cond.value orelse return error.MissingOperand;
    if (raw == .nil) return error.NullOperandUnsupported;

    if (cond.op == .in or cond.op == .notIn) {
        if (raw != .arr) return error.InvalidInOperand;
        if (ft == .array) return error.UnsupportedOperatorForFieldType;
        const list = try allocator.alloc(CanonicalValue, raw.arr.len);
        var count: usize = 0;
        errdefer {
            while (count > 0) : (count -= 1) list[count - 1].deinit(allocator);
            allocator.free(list);
        }
        for (raw.arr, 0..) |item, i| {
            if (item == .nil) return error.NullOperandUnsupported;
            list[i] = try normalizePayloadValue(allocator, ft, it, item);
            count += 1;
        }
        cond.canonical_list = list;
        return;
    }

    if (cond.op == .contains or cond.op == .startsWith or cond.op == .endsWith) {
        if (ft == .text) {
            if (raw != .str) return error.InvalidOperandType;
            cond.canonical_value = .{ .text = try allocator.dupe(u8, raw.str.value()) };
            return;
        }
        if (ft == .array) {
            if (cond.op != .contains) return error.UnsupportedOperatorForFieldType;
            const elem_type = it orelse return error.TypeMismatch;
            cond.canonical_value = try normalizePayloadValue(allocator, elem_type, null, raw);
            return;
        }
        return error.UnsupportedOperatorForFieldType;
    }

    if (ft == .array) {
        return error.UnsupportedOperatorForFieldType;
    }

    cond.canonical_value = try normalizePayloadValue(allocator, ft, it, raw);
}

fn clearConditionRawValues(allocator: std.mem.Allocator, conditions: []Condition) void {
    for (conditions) |*cond| {
        if (cond.value) |v| {
            v.free(allocator);
            cond.value = null;
        }
    }
}

fn normalizeConditionsInPlace(
    allocator: std.mem.Allocator,
    conditions: []Condition,
) ParserError!void {
    for (conditions) |*cond| {
        try normalizeConditionInPlace(allocator, cond);
    }
    clearConditionRawValues(allocator, conditions);
}

fn clearCursorRawValue(allocator: std.mem.Allocator, cursor: *Cursor) void {
    if (cursor.sort_value) |v| {
        v.free(allocator);
        cursor.sort_value = null;
    }
}

pub fn normalizeFilterInPlace(
    allocator: std.mem.Allocator,
    table_metadata: schema_manager.TableMetadata,
    filter: *QueryFilter,
) ParserError!void {
    _ = table_metadata;
    // Transactional normalization: on error, keep input filter untouched.
    var working = try filter.clone(allocator);
    errdefer working.deinit(allocator);

    if (working.conditions) |conds| {
        try normalizeConditionsInPlace(allocator, @constCast(conds));
    }

    if (working.or_conditions) |conds| {
        try normalizeConditionsInPlace(allocator, @constCast(conds));
    }

    if (working.order_by) |*order_by| {
        if (order_by.field_type == null) return error.UnknownField;
    }

    if (working.after) |*after| {
        try normalizeCursorForFilter(allocator, working.order_by, after);
    }

    filter.deinit(allocator);
    filter.* = working;
}

pub fn normalizeCursorForFilter(
    allocator: std.mem.Allocator,
    order_by: ?SortDescriptor,
    cursor: *Cursor,
) ParserError!void {
    const sort_ft: FieldType = if (order_by) |o| o.field_type orelse .text else .text;
    const sort_it: ?FieldType = if (order_by) |o| o.items_type else null;
    if (cursor.canonical_sort_value != null and cursor.sort_field_type == sort_ft and cursor.sort_items_type == sort_it) {
        return;
    }
    if (cursor.canonical_sort_value) |v| {
        v.deinit(allocator);
        cursor.canonical_sort_value = null;
    }
    const raw = cursor.sort_value orelse return error.InvalidCursorSortValue;
    if (raw == .nil) return error.NullOperandUnsupported;
    cursor.canonical_sort_value = normalizePayloadValue(allocator, sort_ft, sort_it, raw) catch |err| switch (err) {
        error.TypeMismatch => return error.InvalidCursorSortValue,
        else => return err,
    };
    cursor.sort_field_type = sort_ft;
    cursor.sort_items_type = sort_it;
    clearCursorRawValue(allocator, cursor);
}

pub fn parseAndNormalizeCursorToken(
    allocator: std.mem.Allocator,
    order_by: ?SortDescriptor,
    token: []const u8,
) ParserError!Cursor {
    var cursor = try parseCursorToken(allocator, token);
    errdefer cursor.deinit(allocator);
    try normalizeCursorForFilter(allocator, order_by, &cursor);
    return cursor;
}
