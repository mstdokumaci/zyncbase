const std = @import("std");
const comptimeEncodeKey = @import("comptime.zig").comptimeEncodeKey;

pub const WireError = struct {
    code: []const u8,
    message: []const u8,
    retry_after_ms: ?u64 = null,
};

fn wireError(comptime code: []const u8, comptime message: []const u8) WireError {
    return .{
        .code = comptimeEncodeKey(code),
        .message = comptimeEncodeKey(message),
    };
}

const internal_error = wireError("INTERNAL_ERROR", "Zig core failure");

const wire_error_map = std.StaticStringMap(WireError).initComptime(.{
    .{ "UnknownTable", wireError("COLLECTION_NOT_FOUND", "Collection missing in schema") },
    .{ "UnknownField", wireError("FIELD_NOT_FOUND", "Field missing in schema") },
    .{ "ImmutableField", wireError("IMMUTABLE_FIELD", "Attempted to modify a system-protected field") },
    .{ "TypeMismatch", wireError("SCHEMA_VALIDATION_FAILED", "Field type mismatch") },
    .{ "ConstraintViolation", wireError("SCHEMA_VALIDATION_FAILED", "Schema constraint violation") },
    .{ "MissingRequiredField", wireError("SCHEMA_VALIDATION_FAILED", "Required field missing during document creation") },
    .{ "InvalidArrayElement", wireError("INVALID_ARRAY_ELEMENT", "Array field contains non-literal value") },
    .{ "InvalidFieldName", wireError("INVALID_FIELD_NAME", "Field name contains forbidden characters") },
    .{ "InvalidMessageFormat", wireError("INVALID_MESSAGE_FORMAT", "Malformed MessagePack frame") },
    .{ "InvalidMessageType", wireError("INVALID_MESSAGE_TYPE", "Only binary MessagePack frames are supported") },
    .{ "MissingRequiredFields", wireError("INVALID_MESSAGE", "Request missing required fields") },
    .{ "MissingSubscriptionId", wireError("INVALID_MESSAGE_FORMAT", "Request missing subscription ID") },
    .{ "InvalidPayload", wireError("INVALID_MESSAGE", "Invalid payload structure") },
    .{ "InvalidConditionFormat", wireError("INVALID_MESSAGE", "Invalid query filter format") },
    .{ "InvalidOperatorCode", wireError("INVALID_MESSAGE", "Unknown query operator") },
    .{ "InvalidSortFormat", wireError("INVALID_MESSAGE", "Malformed sort parameters") },
    .{ "MissingOperand", wireError("INVALID_MESSAGE", "Query operator is missing an operand") },
    .{ "UnexpectedOperand", wireError("INVALID_MESSAGE", "Query operator does not accept an operand") },
    .{ "InvalidOperandType", wireError("INVALID_MESSAGE", "Query operand type is invalid for this field") },
    .{ "InvalidInOperand", wireError("INVALID_MESSAGE", "IN and NOT IN require an array operand") },
    .{ "NullOperandUnsupported", wireError("INVALID_MESSAGE", "Null is not allowed as a query operand") },
    .{ "UnsupportedOperatorForFieldType", wireError("INVALID_MESSAGE", "Query operator is not supported for this field type") },
    .{ "InvalidCursorSortValue", wireError("INVALID_MESSAGE", "Cursor sort value does not match the active sort field") },
    .{ "InvalidSubscriptionId", wireError("INVALID_MESSAGE", "Invalid subscription ID format") },
    .{ "SubscriptionNotFound", wireError("SUBSCRIPTION_NOT_FOUND", "Subscription not found") },
    .{ "MissingExternalIdentity", wireError("AUTH_FAILED", "Identity verification failed") },
    .{ "AuthFailed", wireError("AUTH_FAILED", "Identity verification failed") },
    .{ "TokenExpired", wireError("TOKEN_EXPIRED", "Session has expired") },
    .{ "PermissionDenied", wireError("PERMISSION_DENIED", "Rule blocked operation") },
    .{ "AccessDenied", wireError("PERMISSION_DENIED", "Rule blocked operation") },
    .{ "SessionNotReady", wireError("SESSION_NOT_READY", "Scoped session is not ready") },
    .{ "NamespaceUnauthorized", wireError("NAMESPACE_UNAUTHORIZED", "No access to namespace") },
    .{ "NamespaceSwitchRejected", wireError("NAMESPACE_SWITCH_REJECTED", "Namespace switching is not allowed when users.namespaced is enabled") },
    .{ "MaxDepthExceeded", wireError("MESSAGE_TOO_LARGE", "Payload too big") },
    .{ "RateLimited", wireError("RATE_LIMITED", "Too many requests") },
    .{ "RequestSuperseded", wireError("REQUEST_SUPERSEDED", "Scope superseded by newer request") },
    .{ "BatchTooLarge", wireError("BATCH_TOO_LARGE", "Batch exceeds 500 operations") },
    .{ "InvalidWriteAck", wireError("INVALID_MESSAGE", "writeId requires confirm: committed") },
    .{ "EngineUnhealthy", wireError("ENGINE_UNHEALTHY", "Write engine is in a degraded state") },
});

pub fn getWireError(err: anyerror) WireError {
    return wire_error_map.get(@errorName(err)) orelse internal_error;
}
