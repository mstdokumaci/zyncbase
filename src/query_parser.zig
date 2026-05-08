const std = @import("std");
const msgpack = @import("msgpack_utils.zig");
const schema = @import("schema.zig");
const Schema = schema.Schema;
const doc_id = @import("doc_id.zig");
const typedValueFromPayload = @import("storage_engine.zig").typedValueFromPayload;
const writeTypedValueMsgPack = @import("storage_engine.zig").writeTypedValueMsgPack;
const ScalarValue = @import("storage_engine.zig").ScalarValue;
const TypedValue = @import("storage_engine.zig").TypedValue;
const TypedCursor = @import("storage_engine.zig").TypedCursor;

const query_ast = @import("query_ast.zig");
const Operator = query_ast.Operator;
const Condition = query_ast.Condition;
const SortDescriptor = query_ast.SortDescriptor;
const QueryFilter = query_ast.QueryFilter;

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

/// Decodes a Base64-encoded MessagePack cursor tuple token into a TypedCursor.
/// Expected decoded MessagePack shape: [sort_value, id_bin]
pub fn decodeCursorToken(
    allocator: std.mem.Allocator,
    token: []const u8,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
) ParserError!TypedCursor {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(token) catch
        return error.InvalidMessageFormat;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, token) catch return error.InvalidMessageFormat;

    var reader: std.Io.Reader = .fixed(decoded);
    const cursor_payload = msgpack.decodeTrusted(allocator, &reader) catch
        return error.InvalidMessageFormat;
    defer cursor_payload.free(allocator);

    if (cursor_payload != .arr or cursor_payload.arr.len != 2) return error.InvalidMessageFormat;
    if (cursor_payload.arr[1] != .bin) return error.InvalidMessageFormat;

    const sort_value = try decodeCursorSortValue(allocator, field_type, items_type, cursor_payload.arr[0]);
    errdefer sort_value.deinit(allocator);

    return TypedCursor{
        .sort_value = sort_value,
        .id = doc_id.fromBytes(cursor_payload.arr[1].bin.value()) catch return error.InvalidMessageFormat,
    };
}

/// Encodes a TypedCursor to a Base64-encoded MessagePack cursor tuple token.
/// Encoded shape: [sort_value, id_bin]
pub fn encodeCursorToken(allocator: std.mem.Allocator, cursor: TypedCursor) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try msgpack.encodeArrayHeader(writer, 2);
    try writeTypedValueMsgPack(cursor.sort_value, writer);
    const id_bytes = doc_id.toBytes(cursor.id);
    try msgpack.writeMsgPackBin(writer, &id_bytes);
    const encoded_len = std.base64.standard.Encoder.calcSize(buf.items.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, buf.items);
    return encoded;
}

fn decodeCursorSortValue(
    allocator: std.mem.Allocator,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
    payload: msgpack.Payload,
) ParserError!TypedValue {
    if (payload == .nil) return error.InvalidCursorSortValue;
    return typedValueFromPayload(allocator, field_type, items_type, payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidCursorSortValue,
    };
}

/// Parse a MessagePack Payload (expected to be a map) into a QueryFilter AST.
/// Validates all field names against the provided schema for the target collection.
/// The caller is responsible for calling `filter.deinit(allocator)` on success.
pub fn parseQueryFilter(
    allocator: std.mem.Allocator,
    sm: *const Schema,
    table_index: usize,
    payload: msgpack.Payload,
) ParserError!QueryFilter {
    if (payload != .map) return error.InvalidMessageFormat;

    // Find the table metadata in schema for validation
    const table_metadata = sm.getTableByIndex(table_index) orelse return error.UnknownTable;

    var conditions: ?[]Condition = null;
    var or_conditions: ?[]Condition = null;
    const id_field = table_metadata.fields[schema.id_field_index];
    var order_by: SortDescriptor = .{
        .field_index = schema.id_field_index,
        .desc = false,
        .field_type = id_field.storage_type,
        .items_type = id_field.items_type,
    };
    var limit: ?u32 = null;
    var after: ?TypedCursor = null;
    var after_token: ?[]u8 = null;

    errdefer {
        if (conditions) |conds| {
            for (conds) |c| c.deinit(allocator);
            allocator.free(conds);
        }
        if (or_conditions) |or_conds| {
            for (or_conds) |c| c.deinit(allocator);
            allocator.free(or_conds);
        }
        if (after) |*a| a.deinit(allocator);
        if (after_token) |token| allocator.free(token);
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
            order_by = try parseSortDescriptor(table_metadata, value);
        } else if (std.mem.eql(u8, key, "limit")) {
            if (value == .uint) {
                limit = @intCast(value.uint);
            } else if (value == .int and value.int >= 0) {
                limit = @intCast(value.int);
            }
            if (limit != null and limit.? == 0) return error.InvalidMessageFormat;
        } else if (std.mem.eql(u8, key, "after")) {
            if (value != .str) return error.InvalidMessageFormat;
            if (after_token) |old| allocator.free(old);
            after_token = try allocator.dupe(u8, value.str.value());
        }
    }

    if (after_token) |token| {
        after = try decodeCursorToken(allocator, token, order_by.field_type, order_by.items_type);
        allocator.free(token);
        after_token = null;
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
    field_index: usize,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
};

/// Resolves the metadata (FieldType and items_type) for a given field by index.
pub fn resolveFieldMetadata(
    table_metadata: *const schema.Table,
    field_index: usize,
) ParserError!ResolvedField {
    if (field_index >= table_metadata.fields.len) return error.UnknownField;
    const f = table_metadata.fields[field_index];
    return .{
        .field_index = field_index,
        .field_type = f.storage_type,
        .items_type = f.items_type,
    };
}

fn parseOperator(payload: msgpack.Payload) ParserError!Operator {
    if (payload != .uint and payload != .int) return error.InvalidOperatorCode;
    const op_code = if (payload == .uint) payload.uint else blk: {
        if (payload.int < 0) return error.InvalidOperatorCode;
        break :blk @as(u64, @intCast(payload.int));
    };
    if (op_code > @intFromEnum(Operator.isNotNull)) return error.InvalidOperatorCode;
    return @enumFromInt(@as(u8, @intCast(op_code)));
}

fn parseSortDirection(payload: msgpack.Payload) ParserError!bool {
    if (payload != .uint and payload != .int) return error.InvalidSortFormat;
    const raw = if (payload == .uint) payload.uint else blk: {
        if (payload.int < 0) return error.InvalidSortFormat;
        break :blk @as(u64, @intCast(payload.int));
    };
    return switch (raw) {
        0 => false,
        1 => true,
        else => error.InvalidSortFormat,
    };
}

fn parseScalarValue(
    allocator: std.mem.Allocator,
    field_type: schema.FieldType,
    payload: msgpack.Payload,
) ParserError!TypedValue {
    if (payload == .nil) return error.NullOperandUnsupported;
    if (field_type == .array) return error.UnsupportedOperatorForFieldType;
    return typedValueFromPayload(allocator, field_type, null, payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TypeMismatch,
    };
}

fn parseFieldValue(
    allocator: std.mem.Allocator,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
    payload: msgpack.Payload,
) ParserError!TypedValue {
    if (payload == .nil) return error.NullOperandUnsupported;
    return typedValueFromPayload(allocator, field_type, items_type, payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TypeMismatch,
    };
}

fn parseArrayElementValue(
    allocator: std.mem.Allocator,
    items_type: ?schema.FieldType,
    payload: msgpack.Payload,
) ParserError!TypedValue {
    const item_type = items_type orelse return error.TypeMismatch;
    return parseScalarValue(allocator, item_type, payload);
}

fn parseInOperand(
    allocator: std.mem.Allocator,
    field_type: schema.FieldType,
    payload: msgpack.Payload,
) ParserError!TypedValue {
    if (payload == .nil) return error.NullOperandUnsupported;
    if (payload != .arr) return error.InvalidInOperand;
    if (field_type == .array) return error.UnsupportedOperatorForFieldType;

    const items = try allocator.alloc(ScalarValue, payload.arr.len);
    var count: usize = 0;
    errdefer {
        for (items[0..count]) |item| item.deinit(allocator);
        allocator.free(items);
    }

    for (payload.arr, 0..) |item, i| {
        if (item == .nil) return error.NullOperandUnsupported;
        const typed = try parseScalarValue(allocator, field_type, item);
        switch (typed) {
            .scalar => |scalar| {
                items[i] = scalar;
                count += 1;
            },
            else => unreachable,
        }
    }

    var result: TypedValue = .{ .array = items };
    try result.sortedSet(allocator);
    return result;
}

fn parseConditionValueForOperator(
    allocator: std.mem.Allocator,
    op: Operator,
    field_type: schema.FieldType,
    items_type: ?schema.FieldType,
    payload: ?msgpack.Payload,
) ParserError!?TypedValue {
    switch (op) {
        .isNull, .isNotNull => {
            if (payload != null) return error.UnexpectedOperand;
            return null;
        },
        else => {},
    }

    const raw = payload orelse return error.MissingOperand;

    return switch (op) {
        .eq, .ne => try parseFieldValue(allocator, field_type, items_type, raw),
        .gt, .lt, .gte, .lte => {
            if (field_type == .array) return error.UnsupportedOperatorForFieldType;
            return try parseScalarValue(allocator, field_type, raw);
        },
        .contains => switch (field_type) {
            .text => blk: {
                if (raw != .str) return error.InvalidOperandType;
                break :blk try parseScalarValue(allocator, .text, raw);
            },
            .array => try parseArrayElementValue(allocator, items_type, raw),
            else => return error.UnsupportedOperatorForFieldType,
        },
        .startsWith, .endsWith => {
            if (field_type != .text) return error.UnsupportedOperatorForFieldType;
            if (raw != .str) return error.InvalidOperandType;
            return try parseScalarValue(allocator, .text, raw);
        },
        .in, .notIn => try parseInOperand(allocator, field_type, raw),
        .isNull, .isNotNull => unreachable,
    };
}

fn parseConditions(
    allocator: std.mem.Allocator,
    table_metadata: *const schema.Table,
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
    table_metadata: *const schema.Table,
    payload: msgpack.Payload,
) ParserError!Condition {
    if (payload != .arr) return error.InvalidConditionFormat;
    const arr = payload.arr;
    if (arr.len < 2 or arr.len > 3) return error.InvalidConditionFormat;

    // Field is now an integer index
    const field_index = msgpack.extractPayloadUint(arr[0]) orelse return error.InvalidFieldName;
    const resolved = try resolveFieldMetadata(table_metadata, field_index);

    const op = try parseOperator(arr[1]);
    const operand = if (arr.len == 3) arr[2] else null;
    const value = try parseConditionValueForOperator(allocator, op, resolved.field_type, resolved.items_type, operand);
    errdefer if (value) |v| v.deinit(allocator);

    return Condition{
        .field_index = resolved.field_index,
        .op = op,
        .value = value,
        .field_type = resolved.field_type,
        .items_type = resolved.items_type,
    };
}

fn parseSortDescriptor(
    table_metadata: *const schema.Table,
    payload: msgpack.Payload,
) ParserError!SortDescriptor {
    if (payload != .arr) return error.InvalidSortFormat;
    const arr = payload.arr;
    if (arr.len != 2) return error.InvalidSortFormat;

    // Field is now an integer index
    const field_index = msgpack.extractPayloadUint(arr[0]) orelse return error.InvalidFieldName;
    const resolved = try resolveFieldMetadata(table_metadata, field_index);
    const desc = try parseSortDirection(arr[1]);

    return SortDescriptor{
        .field_index = resolved.field_index,
        .desc = desc,
        .field_type = resolved.field_type,
        .items_type = resolved.items_type,
    };
}
