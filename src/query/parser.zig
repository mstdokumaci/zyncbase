const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const schema_types = @import("../schema/types.zig");
const schema_system = @import("../schema/system.zig");
const Schema = schema_types.Schema;
const typed_codec = @import("../typed/codec.zig");
const typed = @import("../typed/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typedValueFromPayload = typed_codec.fromPayload;
const writeValueMsgPack = typed_codec.writeMsgPack;
const ScalarValue = typed.ScalarValue;
const Value = typed.Value;
const Cursor = typed.Cursor;

const query_ast = @import("ast.zig");
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

/// Decodes a Base64-encoded MessagePack cursor tuple token into a Cursor.
/// Expected decoded MessagePack shape: [sort_value, id_bin]
pub fn decodeCursorToken(
    allocator: std.mem.Allocator,
    token: []const u8,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
) ParserError!Cursor {
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

    return Cursor{
        .sort_value = sort_value,
        .id = typed_doc_id.fromBytes(cursor_payload.arr[1].bin.value()) catch return error.InvalidMessageFormat,
    };
}

/// Encodes a Cursor to a Base64-encoded MessagePack cursor tuple token.
/// Encoded shape: [sort_value, id_bin]
pub fn encodeCursorToken(allocator: std.mem.Allocator, cursor: Cursor) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try msgpack.encodeArrayHeader(writer, 2);
    try writeValueMsgPack(cursor.sort_value, writer);
    const id_bytes = typed_doc_id.toBytes(cursor.id);
    try msgpack.writeMsgPackBin(writer, &id_bytes);
    const encoded_len = std.base64.standard.Encoder.calcSize(buf.items.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, buf.items);
    return encoded;
}

fn decodeCursorSortValue(
    allocator: std.mem.Allocator,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
    payload: msgpack.Payload,
) ParserError!Value {
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
    schema: *const Schema,
    table_index: usize,
    payload: msgpack.Payload,
) ParserError!QueryFilter {
    if (payload != .map) return error.InvalidMessageFormat;

    // Find the table metadata in schema for validation
    const table_metadata = schema.tableByIndex(table_index) orelse return error.UnknownTable;

    var predicate = query_ast.FilterPredicate{};
    const id_field = table_metadata.fields[schema_system.id_field_index];
    var order_by: SortDescriptor = .{
        .field_index = schema_system.id_field_index,
        .desc = false,
        .field_type = id_field.storage_type,
        .items_type = id_field.items_type,
    };
    var limit: ?u32 = null;
    var after: ?Cursor = null;
    var after_token: ?[]u8 = null;

    errdefer {
        if (predicate.conditions) |conds| {
            for (conds) |*c| c.deinit(allocator);
            allocator.free(conds);
        }
        if (predicate.or_clauses) |clauses| {
            for (clauses) |clause| {
                for (clause) |*c| c.deinit(allocator);
                allocator.free(clause);
            }
            allocator.free(clauses);
        }
        if (after) |*a| a.deinit(allocator);
        if (after_token) |token| allocator.free(token);
    }

    var ctx = FilterParseCtx{
        .allocator = allocator,
        .table_metadata = table_metadata,
        .predicate = &predicate,
        .order_by = &order_by,
        .limit = &limit,
        .after_token = &after_token,
    };

    var it = payload.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .str) continue;
        try ctx.handleFilterKey(entry.key_ptr.*.str.value(), entry.value_ptr.*);
    }

    if (after_token) |token| {
        after = try decodeCursorToken(allocator, token, order_by.field_type, order_by.items_type);
        allocator.free(token);
        after_token = null;
    }

    _ = try predicate.normalize(allocator);

    return QueryFilter{
        .predicate = predicate,
        .order_by = order_by,
        .limit = limit,
        .after = after,
    };
}

const FilterParseCtx = struct {
    allocator: std.mem.Allocator,
    table_metadata: *const schema_types.Table,
    predicate: *query_ast.FilterPredicate,
    order_by: *SortDescriptor,
    limit: *?u32,
    after_token: *?[]u8,

    fn handleFilterKey(self: *FilterParseCtx, key: []const u8, value: msgpack.Payload) ParserError!void {
        if (std.mem.eql(u8, key, "conditions") and value == .arr) {
            try self.replaceConditions(self.predicate.conditions, value, &self.predicate.conditions);
        } else if (std.mem.eql(u8, key, "orConditions") and value == .arr) {
            try self.replaceOrConditions(value);
        } else if (std.mem.eql(u8, key, "orderBy")) {
            self.order_by.* = try parseSortDescriptor(self.table_metadata, value);
        } else if (std.mem.eql(u8, key, "limit")) {
            try self.parseLimit(value);
        } else if (std.mem.eql(u8, key, "after")) {
            if (value != .str) return error.InvalidMessageFormat;
            if (self.after_token.*) |old| self.allocator.free(old);
            self.after_token.* = try self.allocator.dupe(u8, value.str.value());
        }
    }

    fn replaceConditions(
        self: *FilterParseCtx,
        old: ?[]Condition,
        value: msgpack.Payload,
        dest: *?[]Condition,
    ) ParserError!void {
        const new_conds = try parseConditions(self.allocator, self.table_metadata, value);
        if (old) |old_conds| {
            for (old_conds) |*c| c.deinit(self.allocator);
            self.allocator.free(old_conds);
        }
        dest.* = new_conds;
    }

    fn replaceOrConditions(
        self: *FilterParseCtx,
        value: msgpack.Payload,
    ) ParserError!void {
        const new_conds = try parseConditions(self.allocator, self.table_metadata, value);
        errdefer {
            for (new_conds) |*c| c.deinit(self.allocator);
            self.allocator.free(new_conds);
        }
        // Free existing or_clauses if any
        if (self.predicate.or_clauses) |clauses| {
            for (clauses) |clause| {
                for (clause) |*c| c.deinit(self.allocator);
                self.allocator.free(clause);
            }
            self.allocator.free(clauses);
        }
        // Wrap the conditions array as a single OrClause
        const clause_slice = try self.allocator.alloc(query_ast.OrClause, 1);
        clause_slice[0] = new_conds;
        self.predicate.or_clauses = clause_slice;
    }

    fn parseLimit(self: *FilterParseCtx, value: msgpack.Payload) ParserError!void {
        if (value == .uint) {
            self.limit.* = @intCast(value.uint);
        } else if (value == .int and value.int >= 0) {
            self.limit.* = @intCast(value.int);
        }
        if (self.limit.* != null and self.limit.*.? == 0) return error.InvalidMessageFormat;
    }
};

pub const ResolvedField = struct {
    field_index: usize,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
};

/// Resolves the metadata (FieldType and items_type) for a given field by index.
pub fn resolveFieldMetadata(
    table_metadata: *const schema_types.Table,
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
    const op_code = msgpack.extractPayloadUsize(payload) orelse return error.InvalidOperatorCode;
    if (op_code > @intFromEnum(Operator.isNotNull)) return error.InvalidOperatorCode;
    return @enumFromInt(@as(u8, @intCast(op_code)));
}

fn parseSortDirection(payload: msgpack.Payload) ParserError!bool {
    return switch (msgpack.extractPayloadUsize(payload) orelse return error.InvalidSortFormat) {
        0 => false,
        1 => true,
        else => error.InvalidSortFormat,
    };
}

fn parseScalarValue(
    allocator: std.mem.Allocator,
    field_type: schema_types.FieldType,
    payload: msgpack.Payload,
) ParserError!Value {
    if (payload == .nil) return error.NullOperandUnsupported;
    if (field_type == .array) return error.UnsupportedOperatorForFieldType;
    return typedValueFromPayload(allocator, field_type, null, payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TypeMismatch,
    };
}

fn parseFieldValue(
    allocator: std.mem.Allocator,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
    payload: msgpack.Payload,
) ParserError!Value {
    if (payload == .nil) return error.NullOperandUnsupported;
    return typedValueFromPayload(allocator, field_type, items_type, payload) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TypeMismatch,
    };
}

fn parseArrayElementValue(
    allocator: std.mem.Allocator,
    items_type: ?schema_types.FieldType,
    payload: msgpack.Payload,
) ParserError!Value {
    const item_type = items_type orelse return error.TypeMismatch;
    return parseScalarValue(allocator, item_type, payload);
}

fn parseInOperand(
    allocator: std.mem.Allocator,
    field_type: schema_types.FieldType,
    payload: msgpack.Payload,
) ParserError!Value {
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
        const parsed_value = try parseScalarValue(allocator, field_type, item);
        switch (parsed_value) {
            .scalar => |scalar| {
                items[i] = scalar;
                count += 1;
            },
            else => unreachable,
        }
    }

    var result: Value = .{ .array = items };
    try result.sortedSet(allocator);
    return result;
}

fn parseConditionValueForOperator(
    allocator: std.mem.Allocator,
    op: Operator,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
    payload: ?msgpack.Payload,
) ParserError!?Value {
    const shape = try query_ast.operatorExpectsValueShape(op, field_type);

    if (shape == .nullary) {
        if (payload != null) return error.UnexpectedOperand;
        return null;
    }

    const raw = payload orelse return error.MissingOperand;

    return switch (shape) {
        .scalar_text, .contains_text => {
            if (raw != .str) return error.InvalidOperandType;
            return try parseScalarValue(allocator, .text, raw);
        },
        .scalar, .array_field => try parseFieldValue(allocator, field_type, items_type, raw),
        .array_membership => try parseInOperand(allocator, field_type, raw),
        .contains_element => try parseArrayElementValue(allocator, items_type, raw),
        .nullary => unreachable,
    };
}

fn parseConditions(
    allocator: std.mem.Allocator,
    table_metadata: *const schema_types.Table,
    payload: msgpack.Payload,
) ParserError![]Condition {
    if (payload != .arr) return error.InvalidConditionFormat;
    const arr = payload.arr;
    const result = try allocator.alloc(Condition, arr.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |*c| c.deinit(allocator);
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
    table_metadata: *const schema_types.Table,
    payload: msgpack.Payload,
) ParserError!Condition {
    if (payload != .arr) return error.InvalidConditionFormat;
    const arr = payload.arr;
    if (arr.len < 2 or arr.len > 3) return error.InvalidConditionFormat;

    // Field is now an integer index
    const field_index = msgpack.extractPayloadUsize(arr[0]) orelse return error.InvalidFieldName;
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
    table_metadata: *const schema_types.Table,
    payload: msgpack.Payload,
) ParserError!SortDescriptor {
    if (payload != .arr) return error.InvalidSortFormat;
    const arr = payload.arr;
    if (arr.len != 2) return error.InvalidSortFormat;

    // Field is now an integer index
    const field_index = msgpack.extractPayloadUsize(arr[0]) orelse return error.InvalidFieldName;
    const resolved = try resolveFieldMetadata(table_metadata, field_index);
    const desc = try parseSortDirection(arr[1]);

    return SortDescriptor{
        .field_index = resolved.field_index,
        .desc = desc,
        .field_type = resolved.field_type,
        .items_type = resolved.items_type,
    };
}
