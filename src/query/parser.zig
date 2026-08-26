const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const schema_system = @import("../schema/system.zig");
const schema_types = @import("../schema/types.zig");
const typed_codec = @import("../typed/codec.zig");
const typed = @import("../typed/types.zig");
const query_ast = @import("ast.zig");

const Schema = schema_types.Schema;
const typedValueFromPayload = typed_codec.fromPayload;
const writeValueMsgPack = typed_codec.writeMsgPack;
const Cursor = typed.Cursor;
const ScalarValue = typed.ScalarValue;
const Value = typed.Value;
const Condition = query_ast.Condition;
const Operator = query_ast.Operator;
const QueryFilter = query_ast.QueryFilter;
const SortDescriptor = query_ast.SortDescriptor;

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
    UnsupportedSortFieldType,
    InvalidCursorSortValue,
    OutOfMemory,
};

/// Maximum number of client-supplied sort clauses.
pub const max_sort_clauses: usize = 8;

/// Decodes a Base64-encoded MessagePack cursor token into a Cursor.
/// Decoded shape: [table_index, [[field_index, desc], ...], [value_0, ..., id_bin]]
/// The embedded table index and descriptor list must exactly match the active
/// query's canonical order; values are decoded against each field's schema type.
pub fn decodeCursorToken(
    allocator: std.mem.Allocator,
    token: []const u8,
    table_index: usize,
    table_metadata: *const schema_types.Table,
    descriptors: []const query_ast.SortDescriptor,
) ParserError!Cursor {
    // single decode pass; consumed-byte check rejects trailing data.
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(token) catch
        return error.InvalidMessageFormat;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, token) catch return error.InvalidMessageFormat;

    var reader: std.Io.Reader = .fixed(decoded);
    const decode_result = msgpack.decodeConsumed(allocator, &reader) catch
        return error.InvalidMessageFormat;
    defer decode_result.payload.free(allocator);
    if (decode_result.consumed != decoded.len) return error.InvalidMessageFormat;

    const token_values = try validateCursorIdentity(decode_result.payload, table_index, descriptors);
    const values = try decodeCursorValues(allocator, table_metadata, descriptors, token_values);
    return Cursor{ .values = values };
}

inline fn validateCursorIdentity(
    payload: msgpack.Payload,
    table_index: usize,
    descriptors: []const query_ast.SortDescriptor,
) ParserError![]const msgpack.Payload {
    if (payload != .arr or payload.arr.len != 3) return error.InvalidMessageFormat;

    const token_table_index = msgpack.extractPayloadUsize(payload.arr[0]) orelse return error.InvalidMessageFormat;
    if (token_table_index != table_index) return error.InvalidCursorSortValue;

    const token_descriptors = payload.arr[1];
    if (token_descriptors != .arr or token_descriptors.arr.len != descriptors.len) return error.InvalidCursorSortValue;
    try validateCursorDescriptors(token_descriptors.arr, descriptors);

    const token_values = payload.arr[2];
    if (token_values != .arr or token_values.arr.len != descriptors.len) return error.InvalidCursorSortValue;
    return token_values.arr;
}

inline fn validateCursorDescriptors(
    token_descriptors: []const msgpack.Payload,
    descriptors: []const query_ast.SortDescriptor,
) ParserError!void {
    for (token_descriptors, descriptors) |td, d| {
        if (td != .arr or td.arr.len != 2) return error.InvalidCursorSortValue;
        const field_index = msgpack.extractPayloadUsize(td.arr[0]) orelse return error.InvalidCursorSortValue;
        const desc = switch (msgpack.extractPayloadUsize(td.arr[1]) orelse return error.InvalidCursorSortValue) {
            0 => false,
            1 => true,
            else => return error.InvalidCursorSortValue,
        };
        if (field_index != d.field_index or desc != d.desc) return error.InvalidCursorSortValue;
    }
}

inline fn decodeCursorValues(
    allocator: std.mem.Allocator,
    table_metadata: *const schema_types.Table,
    descriptors: []const query_ast.SortDescriptor,
    payloads: []const msgpack.Payload,
) ParserError![]typed.Value {
    const values = try allocator.alloc(typed.Value, payloads.len);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |v| v.deinit(allocator);
        allocator.free(values);
    }

    for (payloads, 0..) |item, i| {
        const field = table_metadata.fields[descriptors[i].field_index];
        if (item == .nil and field.required) return error.InvalidCursorSortValue;
        if (item == .arr) return error.InvalidCursorSortValue;
        values[i] = typedValueFromPayload(allocator, field.storage_type, field.items_type, item) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidCursorSortValue,
        };
        initialized += 1;
    }
    return values;
}

/// Encodes a Cursor to a Base64-encoded MessagePack cursor token.
/// Encoded shape: [table_index, [[field_index, desc], ...], [values...]]
pub fn encodeCursorToken(
    allocator: std.mem.Allocator,
    table_index: usize,
    descriptors: []const query_ast.SortDescriptor,
    values: []const typed.Value,
) ![]const u8 {
    std.debug.assert(descriptors.len == values.len);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;

    try msgpack.encodeArrayHeader(writer, 3);
    try msgpack.encode(msgpack.Payload{ .uint = table_index }, writer);

    try msgpack.encodeArrayHeader(writer, descriptors.len);
    for (descriptors) |d| {
        try msgpack.encodeArrayHeader(writer, 2);
        try msgpack.encode(msgpack.Payload{ .uint = d.field_index }, writer);
        try msgpack.encode(msgpack.Payload{ .uint = @intFromBool(d.desc) }, writer);
    }

    try msgpack.encodeArrayHeader(writer, values.len);
    for (values) |v| {
        try writeValueMsgPack(v, writer);
    }

    const bytes = output.written();
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
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
    var order_by: []SortDescriptor = &[_]SortDescriptor{};
    var has_explicit_order = false;
    var limit: ?u32 = null;
    var after_token: ?[]u8 = null;

    errdefer {
        predicate.deinit(allocator);
        if (order_by.len > 0) allocator.free(order_by);
        if (after_token) |token| allocator.free(token);
    }

    var ctx = FilterParseCtx{
        .allocator = allocator,
        .table_metadata = table_metadata,
        .predicate = &predicate,
        .order_by = &order_by,
        .has_explicit_order = &has_explicit_order,
        .limit = &limit,
        .after_token = &after_token,
    };

    var it = payload.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .str) continue;
        try ctx.handleFilterKey(entry.key_ptr.*.str.value(), entry.value_ptr.*);
    }

    // Canonicalize after map iteration so key order cannot influence the result.
    if (!has_explicit_order) {
        order_by = try defaultOrderBy(allocator);
    } else {
        order_by = try canonicalizeOrderBy(allocator, order_by);
    }

    var after: ?Cursor = null;
    errdefer if (after) |*a| a.deinit(allocator);
    if (after_token) |token| {
        after = try decodeCursorToken(allocator, token, table_index, table_metadata, order_by);
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

fn defaultOrderBy(allocator: std.mem.Allocator) ParserError![]SortDescriptor {
    const slice = try allocator.alloc(SortDescriptor, 1);
    errdefer allocator.free(slice);
    slice[0] = .{ .field_index = schema_system.id_field_index, .desc = false };
    return slice;
}

/// Appends the hidden `id ASC` tie-breaker unless `id` is already the final clause.
/// Rejects `id` anywhere except the final position.
fn canonicalizeOrderBy(
    allocator: std.mem.Allocator,
    client_clauses: []SortDescriptor,
) ParserError![]SortDescriptor {
    std.debug.assert(client_clauses.len >= 1);
    for (client_clauses[0 .. client_clauses.len - 1]) |clause| {
        if (clause.field_index == schema_system.id_field_index) return error.InvalidSortFormat;
    }

    const last = client_clauses[client_clauses.len - 1];
    if (last.field_index == schema_system.id_field_index) return client_clauses;

    const extended = try allocator.alloc(SortDescriptor, client_clauses.len + 1);
    errdefer allocator.free(extended);
    @memcpy(extended[0..client_clauses.len], client_clauses);
    extended[client_clauses.len] = .{ .field_index = schema_system.id_field_index, .desc = false };
    allocator.free(client_clauses);
    return extended;
}

const FilterParseCtx = struct {
    allocator: std.mem.Allocator,
    table_metadata: *const schema_types.Table,
    predicate: *query_ast.FilterPredicate,
    order_by: *[]SortDescriptor,
    has_explicit_order: *bool,
    limit: *?u32,
    after_token: *?[]u8,

    fn handleFilterKey(self: *FilterParseCtx, key: []const u8, value: msgpack.Payload) ParserError!void {
        if (std.mem.eql(u8, key, "conditions") and value == .arr) {
            try self.replaceConditions(self.predicate.conditions, value, &self.predicate.conditions);
        } else if (std.mem.eql(u8, key, "orConditions") and value == .arr) {
            try self.replaceOrConditions(value);
        } else if (std.mem.eql(u8, key, "orderBy")) {
            const new_order = try parseSortDescriptors(self.allocator, self.table_metadata, value);
            if (self.order_by.len > 0) self.allocator.free(self.order_by.*);
            self.order_by.* = new_order;
            self.has_explicit_order.* = true;
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

/// Parses the outer `orderBy` array of positional sort tuples.
/// Validates clause count, tuple shape, directions, duplicates, and sortable types.
fn parseSortDescriptors(
    allocator: std.mem.Allocator,
    table_metadata: *const schema_types.Table,
    payload: msgpack.Payload,
) ParserError![]SortDescriptor {
    if (payload != .arr) return error.InvalidSortFormat;
    const arr = payload.arr;
    if (arr.len < 1 or arr.len > max_sort_clauses) return error.InvalidSortFormat;

    const result = try allocator.alloc(SortDescriptor, arr.len);
    var count: usize = 0;
    errdefer allocator.free(result);

    for (arr) |item| {
        const descriptor = try parseSortDescriptor(table_metadata, item);
        // Bounded O(n²) duplicate check — at most eight client clauses.
        for (result[0..count]) |prev| {
            if (prev.field_index == descriptor.field_index) return error.InvalidSortFormat;
        }
        result[count] = descriptor;
        count += 1;
    }
    return result;
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
    if (field_index >= table_metadata.fields.len) return error.UnknownField;
    const field = table_metadata.fields[field_index];
    if (field.storage_type == .array) return error.UnsupportedSortFieldType;

    const desc = try parseSortDirection(arr[1]);

    return SortDescriptor{
        .field_index = field_index,
        .desc = desc,
    };
}
