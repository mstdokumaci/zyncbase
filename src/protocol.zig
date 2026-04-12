const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const storage_mod = @import("storage_engine/types.zig");

pub const Envelope = struct {
    type: []const u8,
    id: u64,
};

pub const StorePathRequest = struct {
    namespace: []const u8,
    path: []const []const u8,
    value: ?Payload = null,
};

pub const StoreCollectionRequest = struct {
    namespace: []const u8,
    collection: []const u8,
};

pub const StoreUnsubscribeRequest = struct {
    subId: u64,
};

pub const StoreLoadMoreRequest = struct {
    subId: u64,
    nextCursor: []const u8,
};

pub fn extractAs(comptime T: type, allocator: Allocator, payload: Payload) !T {
    if (payload != .map) return error.InvalidMessageFormat;
    // SAFETY: All fields will be set by the loop below for non-optional fields,
    // and optional fields default to null. Missing required fields are caught
    // by the found-array check after the loop.
    var result: T = undefined;
    var found = comptime blk: {
        var bytes: [std.meta.fields(T).len]u8 = undefined;
        for (&bytes) |*b| b.* = 0;
        break :blk bytes;
    };

    var it = payload.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (key != .str) continue;
        const key_str = key.str.value();

        inline for (std.meta.fields(T), 0..) |field, i| {
            if (std.mem.eql(u8, key_str, field.name)) {
                found[i] = 1;
                switch (@typeInfo(field.type)) {
                    .bool => {
                        if (val == .bool) {
                            @field(result, field.name) = val.bool;
                        } else {
                            return error.InvalidMessageFormat;
                        }
                    },
                    .pointer => |ptr| {
                        if (ptr.child == u8) {
                            if (val == .str) {
                                @field(result, field.name) = val.str.value();
                            } else {
                                return error.InvalidMessageFormat;
                            }
                        } else if (ptr.child == []const u8) {
                            if (val == .arr) {
                                const arr = val.arr;
                                const slice = try allocator.alloc([]const u8, arr.len);
                                var valid = true;
                                for (arr, 0..) |elem, j| {
                                    if (elem == .str) {
                                        slice[j] = elem.str.value();
                                    } else {
                                        valid = false;
                                    }
                                }
                                if (!valid) {
                                    allocator.free(slice);
                                    return error.InvalidMessageFormat;
                                }
                                @field(result, field.name) = slice;
                            } else {
                                return error.InvalidMessageFormat;
                            }
                        } else {
                            @compileError("Unsupported pointer field type: " ++ field.name);
                        }
                    },
                    .int => {
                        if (val == .uint) {
                            @field(result, field.name) = @intCast(val.uint);
                        } else if (val == .int) {
                            @field(result, field.name) = @intCast(val.int);
                        } else {
                            return error.InvalidMessageFormat;
                        }
                    },
                    .optional => {
                        @field(result, field.name) = val;
                    },
                    else => {
                        @compileError("Unsupported field type for field: " ++ field.name ++ " of type: " ++ @typeName(field.type));
                    },
                }
            }
        }
    }

    inline for (std.meta.fields(T), 0..) |field, i| {
        const is_optional = @typeInfo(field.type) == .optional;
        if (!is_optional and found[i] == 0) {
            return error.MissingRequiredFields;
        }
        if (is_optional and found[i] == 0) {
            @field(result, field.name) = null;
        }
    }

    return result;
}

// === Pre-encoded MsgPack headers (computed at comptime) ===

pub const ok_id_header = blk: {
    var buf: [16]u8 = undefined;
    var stream = std.Io.fixedBufferStream(&buf);
    const writer = stream.writer();
    msgpack.writeMsgPackStr(writer, "type") catch @panic("comptime: failed to write type key");
    msgpack.writeMsgPackStr(writer, "ok") catch @panic("comptime: failed to write type value");
    msgpack.writeMsgPackStr(writer, "id") catch @panic("comptime: failed to write id key");
    break :blk buf[0..stream.pos].*;
};

pub const success_header = blk: {
    var buf: [1 + ok_id_header.len]u8 = undefined;
    buf[0] = 0x82; // fixmap(2)
    @memcpy(buf[1..], &ok_id_header);
    break :blk buf[0..].*;
};

pub const error_type_header = blk: {
    var buf: [24]u8 = undefined;
    var stream = std.Io.fixedBufferStream(&buf);
    const writer = stream.writer();
    msgpack.writeMsgPackStr(writer, "type") catch @panic("comptime: failed to write type key");
    msgpack.writeMsgPackStr(writer, "error") catch @panic("comptime: failed to write type value");
    msgpack.writeMsgPackStr(writer, "code") catch @panic("comptime: failed to write code key");
    break :blk buf[0..stream.pos].*;
};

pub const error_envelope_header = blk: {
    var buf: [1 + error_type_header.len]u8 = undefined;
    buf[0] = 0x84; // fixmap(4)
    @memcpy(buf[1..], &error_type_header);
    break :blk buf[0..].*;
};

fn comptimeEncodeKey(comptime key: []const u8) []const u8 { // zwanzig-disable-line: unused-parameter
    return &(struct {
        const val = blk: {
            var buf: [key.len + 5]u8 = undefined;
            var stream = std.Io.fixedBufferStream(&buf);
            msgpack.writeMsgPackStr(stream.writer(), key) catch @panic("comptime: failed to write key");
            break :blk buf[0..stream.pos].*;
        };
    }.val);
}

pub const message_key = comptimeEncodeKey("message");
pub const id_key = comptimeEncodeKey("id");
pub const sub_id_key = comptimeEncodeKey("subId");
pub const value_key = comptimeEncodeKey("value");
pub const has_more_key = comptimeEncodeKey("hasMore");
pub const next_cursor_key = comptimeEncodeKey("nextCursor");

// === Pre-encoded Error Codes ===
pub const err_code_collection_not_found = comptimeEncodeKey("COLLECTION_NOT_FOUND");
pub const err_code_field_not_found = comptimeEncodeKey("FIELD_NOT_FOUND");
pub const err_code_immutable_field = comptimeEncodeKey("IMMUTABLE_FIELD");
pub const err_code_schema_validation_failed = comptimeEncodeKey("SCHEMA_VALIDATION_FAILED");
pub const err_code_invalid_array_element = comptimeEncodeKey("INVALID_ARRAY_ELEMENT");
pub const err_code_invalid_field_name = comptimeEncodeKey("INVALID_FIELD_NAME");
pub const err_code_invalid_message = comptimeEncodeKey("INVALID_MESSAGE");
pub const err_code_invalid_message_format = comptimeEncodeKey("INVALID_MESSAGE_FORMAT");
pub const err_code_subscription_not_found = comptimeEncodeKey("SUBSCRIPTION_NOT_FOUND");
pub const err_code_auth_failed = comptimeEncodeKey("AUTH_FAILED");
pub const err_code_token_expired = comptimeEncodeKey("TOKEN_EXPIRED");
pub const err_code_permission_denied = comptimeEncodeKey("PERMISSION_DENIED");
pub const err_code_namespace_unauthorized = comptimeEncodeKey("NAMESPACE_UNAUTHORIZED");
pub const err_code_message_too_large = comptimeEncodeKey("MESSAGE_TOO_LARGE");
pub const err_code_rate_limited = comptimeEncodeKey("RATE_LIMITED");
pub const err_code_hook_server_unavailable = comptimeEncodeKey("HOOK_SERVER_UNAVAILABLE");
pub const err_code_hook_denied = comptimeEncodeKey("HOOK_DENIED");
pub const err_code_internal_error = comptimeEncodeKey("INTERNAL_ERROR");

// === Pre-encoded Error Messages ===
pub const err_msg_collection_not_found = comptimeEncodeKey("Collection missing in schema");
pub const err_msg_field_not_found = comptimeEncodeKey("Field missing in schema");
pub const err_msg_immutable_field = comptimeEncodeKey("Attempted to modify a system-protected field");
pub const err_msg_field_type_mismatch = comptimeEncodeKey("Field type mismatch");
pub const err_msg_schema_constraint_violation = comptimeEncodeKey("Schema constraint violation");
pub const err_msg_invalid_array_element = comptimeEncodeKey("Array field contains non-literal value");
pub const err_msg_invalid_field_name = comptimeEncodeKey("Field name contains forbidden characters");
pub const err_msg_malformed_frame = comptimeEncodeKey("Malformed MessagePack frame");
pub const err_msg_invalid_payload = comptimeEncodeKey("Invalid payload structure");
pub const err_msg_invalid_query_filter = comptimeEncodeKey("Invalid query filter format");
pub const err_msg_unknown_operator = comptimeEncodeKey("Unknown query operator");
pub const err_msg_malformed_sort = comptimeEncodeKey("Malformed sort parameters");
pub const err_msg_invalid_sub_id_format = comptimeEncodeKey("Invalid subscription ID format");
pub const err_msg_missing_required_fields = comptimeEncodeKey("Request missing required fields");
pub const err_msg_missing_sub_id = comptimeEncodeKey("Request missing subscription ID");
pub const err_msg_subscription_not_found = comptimeEncodeKey("Subscription not found");
pub const err_msg_auth_failed = comptimeEncodeKey("Identity verification failed");
pub const err_msg_token_expired = comptimeEncodeKey("Session has expired");
pub const err_msg_permission_denied = comptimeEncodeKey("Rule blocked operation");
pub const err_msg_namespace_unauthorized = comptimeEncodeKey("No access to namespace");
pub const err_msg_payload_too_big = comptimeEncodeKey("Payload too big");
pub const err_msg_threshold_exceeded = comptimeEncodeKey("Threshold exceeded");
pub const err_msg_logic_runtime_down = comptimeEncodeKey("Logic runtime down");
pub const err_msg_logic_rejected_write = comptimeEncodeKey("Logic rejected write");
pub const err_msg_zig_core_failure = comptimeEncodeKey("Zig core failure");

pub const err_msg_too_many_requests = comptimeEncodeKey("Too many requests");
pub const err_msg_failed_to_parse = comptimeEncodeKey("Failed to parse MessagePack");
pub const err_msg_missing_type_or_id = comptimeEncodeKey("Missing required fields: type or id");

pub fn buildSuccessResponse(msgpack_allocator: Allocator, msg_id: u64) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(msgpack_allocator);
    const writer = list.writer(msgpack_allocator);

    try list.appendSlice(msgpack_allocator, &success_header);
    try writer.writeByte(0xcf);
    try writer.writeInt(u64, msg_id, .big);

    return list.toOwnedSlice(msgpack_allocator);
}

pub fn buildErrorResponse(msgpack_allocator: Allocator, msg_id: u64, code: []const u8, message: []const u8) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(msgpack_allocator);
    const writer = list.writer(msgpack_allocator);

    try list.appendSlice(msgpack_allocator, &error_envelope_header);
    try list.appendSlice(msgpack_allocator, code);

    try list.appendSlice(msgpack_allocator, id_key);
    try writer.writeByte(0xcf); // msgpack uint64
    try writer.writeInt(u64, msg_id, .big);

    try list.appendSlice(msgpack_allocator, message_key);
    try list.appendSlice(msgpack_allocator, message);

    return list.toOwnedSlice(msgpack_allocator);
}

pub fn buildQueryResponse(
    arena_allocator: std.mem.Allocator,
    msg_id: u64,
    sub_id: ?u64,
    results: *storage_mod.ManagedPayload,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(arena_allocator);
    const writer = list.writer(arena_allocator);

    const map_size: u8 = if (sub_id != null) 6 else 4;
    try writer.writeByte(0x80 | map_size);

    try list.appendSlice(arena_allocator, &ok_id_header);
    try msgpack.encode(msgpack.Payload.uintToPayload(msg_id), writer);

    if (sub_id) |sid| {
        try list.appendSlice(arena_allocator, sub_id_key);
        try msgpack.encode(msgpack.Payload.uintToPayload(sid), writer);
    }

    try list.appendSlice(arena_allocator, value_key);
    if (results.value) |val| {
        try msgpack.encode(val, writer);
        results.value = null;
    } else {
        try msgpack.encode(msgpack.Payload{ .arr = &[_]msgpack.Payload{} }, writer);
    }

    if (sub_id != null) {
        const has_more = results.next_cursor_arr != null;
        try list.appendSlice(arena_allocator, has_more_key);
        try msgpack.encode(msgpack.Payload{ .bool = has_more }, writer);
    }

    try list.appendSlice(arena_allocator, next_cursor_key);
    if (results.next_cursor_arr) |cursor_tuple| {
        const encoded_cursor = try encodeCursor(arena_allocator, cursor_tuple);
        defer arena_allocator.free(encoded_cursor);
        try msgpack.writeMsgPackStr(writer, encoded_cursor);
    } else {
        try msgpack.encode(.nil, writer);
    }

    return list.toOwnedSlice(arena_allocator);
}

pub fn mapErrorToCode(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownTable => err_code_collection_not_found,
        error.UnknownField => err_code_field_not_found,
        error.ImmutableField => err_code_immutable_field,
        error.TypeMismatch, error.ConstraintViolation => err_code_schema_validation_failed,
        error.InvalidArrayElement => err_code_invalid_array_element,
        error.InvalidFieldName => err_code_invalid_field_name,
        error.InvalidMessageFormat, error.InvalidPayload, error.InvalidConditionFormat, error.InvalidOperatorCode, error.InvalidSortFormat, error.InvalidSubscriptionId => err_code_invalid_message,
        error.MissingRequiredFields, error.MissingSubscriptionId => err_code_invalid_message_format,
        error.SubscriptionNotFound => err_code_subscription_not_found,
        error.AuthFailed => err_code_auth_failed,
        error.TokenExpired => err_code_token_expired,
        error.PermissionDenied => err_code_permission_denied,
        error.NamespaceUnauthorized => err_code_namespace_unauthorized,
        error.MaxDepthExceeded => err_code_message_too_large,
        error.RateLimited => err_code_rate_limited,
        error.HookServerUnavailable => err_code_hook_server_unavailable,
        error.HookDenied => err_code_hook_denied,
        else => err_code_internal_error,
    };
}

pub fn mapErrorToMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownTable => err_msg_collection_not_found,
        error.UnknownField => err_msg_field_not_found,
        error.ImmutableField => err_msg_immutable_field,
        error.TypeMismatch => err_msg_field_type_mismatch,
        error.ConstraintViolation => err_msg_schema_constraint_violation,
        error.InvalidArrayElement => err_msg_invalid_array_element,
        error.InvalidFieldName => err_msg_invalid_field_name,
        error.InvalidMessageFormat => err_msg_malformed_frame,
        error.InvalidPayload => err_msg_invalid_payload,
        error.InvalidConditionFormat => err_msg_invalid_query_filter,
        error.InvalidOperatorCode => err_msg_unknown_operator,
        error.InvalidSortFormat => err_msg_malformed_sort,
        error.InvalidSubscriptionId => err_msg_invalid_sub_id_format,
        error.MissingRequiredFields => err_msg_missing_required_fields,
        error.MissingSubscriptionId => err_msg_missing_sub_id,
        error.SubscriptionNotFound => err_msg_subscription_not_found,
        error.AuthFailed => err_msg_auth_failed,
        error.TokenExpired => err_msg_token_expired,
        error.PermissionDenied => err_msg_permission_denied,
        error.NamespaceUnauthorized => err_msg_namespace_unauthorized,
        error.MaxDepthExceeded => err_msg_payload_too_big,
        error.RateLimited => err_msg_threshold_exceeded,
        error.HookServerUnavailable => err_msg_logic_runtime_down,
        error.HookDenied => err_msg_logic_rejected_write,
        else => err_msg_zig_core_failure,
    };
}

pub fn encodeCursor(allocator: Allocator, cursor: msgpack.Payload) ![]const u8 {
    const json_cursor = try msgpack.payloadToJson(cursor, allocator);
    defer allocator.free(json_cursor);

    const encoded_len = std.base64.standard.Encoder.calcSize(json_cursor.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, json_cursor);
    return encoded;
}

// === StoreDelta encoder (moved from notification_dispatcher.zig) ===

pub const store_delta_header = blk: {
    var buf: [64]u8 = undefined;
    var stream = std.Io.fixedBufferStream(&buf);
    const writer = stream.writer();
    writer.writeByte(0x83) catch @panic("comptime: failed to write map header");
    msgpack.writeMsgPackStr(writer, "type") catch @panic("comptime: failed to write type key");
    msgpack.writeMsgPackStr(writer, "StoreDelta") catch @panic("comptime: failed to write type value");
    msgpack.writeMsgPackStr(writer, "subId") catch @panic("comptime: failed to write subId key");
    break :blk buf[0..stream.pos].*;
};

pub fn encodeDeltaSuffix(
    allocator: Allocator,
    collection: []const u8,
    id_payload: Payload,
    is_delete: bool,
    new_row: ?Payload,
) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    const writer = list.writer(allocator);

    try msgpack.writeMsgPackStr(writer, "ops");
    try writer.writeByte(0x91); // fixarray(1)

    try writer.writeByte(if (is_delete) 0x82 else 0x83);

    try msgpack.writeMsgPackStr(writer, "op");
    try msgpack.writeMsgPackStr(writer, if (is_delete) "remove" else "set");

    try msgpack.writeMsgPackStr(writer, "path");
    try writer.writeByte(0x92); // fixarray(2)
    try msgpack.writeMsgPackStr(writer, collection);
    try msgpack.encode(id_payload, writer);

    if (!is_delete) {
        try msgpack.writeMsgPackStr(writer, "value");
        try msgpack.encode(new_row orelse Payload.nil, writer);
    }

    return list.toOwnedSlice(allocator);
}
