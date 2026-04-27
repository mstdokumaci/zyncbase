const comptimeEncodeKey = @import("comptime.zig").comptimeEncodeKey;

pub const WireError = struct {
    code: []const u8,
    message: []const u8,
};

fn wireError(comptime code: []const u8, comptime message: []const u8) WireError {
    return .{
        .code = comptimeEncodeKey(code),
        .message = comptimeEncodeKey(message),
    };
}

pub fn getWireError(err: anyerror) WireError {
    return switch (err) {
        error.UnknownTable => wireError("COLLECTION_NOT_FOUND", "Collection missing in schema"),
        error.UnknownField => wireError("FIELD_NOT_FOUND", "Field missing in schema"),
        error.ImmutableField => wireError("IMMUTABLE_FIELD", "Attempted to modify a system-protected field"),
        error.TypeMismatch => wireError("SCHEMA_VALIDATION_FAILED", "Field type mismatch"),
        error.ConstraintViolation => wireError("SCHEMA_VALIDATION_FAILED", "Schema constraint violation"),
        error.InvalidArrayElement => wireError("INVALID_ARRAY_ELEMENT", "Array field contains non-literal value"),
        error.InvalidFieldName => wireError("INVALID_FIELD_NAME", "Field name contains forbidden characters"),
        error.InvalidMessageFormat => wireError("INVALID_MESSAGE_FORMAT", "Malformed MessagePack frame"),
        error.MissingRequiredFields => wireError("INVALID_MESSAGE", "Request missing required fields"),
        error.MissingSubscriptionId => wireError("INVALID_MESSAGE_FORMAT", "Request missing subscription ID"),
        error.InvalidPayload => wireError("INVALID_MESSAGE", "Invalid payload structure"),
        error.InvalidConditionFormat => wireError("INVALID_MESSAGE", "Invalid query filter format"),
        error.InvalidOperatorCode => wireError("INVALID_MESSAGE", "Unknown query operator"),
        error.InvalidSortFormat => wireError("INVALID_MESSAGE", "Malformed sort parameters"),
        error.MissingOperand => wireError("INVALID_MESSAGE", "Query operator is missing an operand"),
        error.UnexpectedOperand => wireError("INVALID_MESSAGE", "Query operator does not accept an operand"),
        error.InvalidOperandType => wireError("INVALID_MESSAGE", "Query operand type is invalid for this field"),
        error.InvalidInOperand => wireError("INVALID_MESSAGE", "IN and NOT IN require an array operand"),
        error.NullOperandUnsupported => wireError("INVALID_MESSAGE", "Null is not allowed as a query operand"),
        error.UnsupportedOperatorForFieldType => wireError("INVALID_MESSAGE", "Query operator is not supported for this field type"),
        error.InvalidCursorSortValue => wireError("INVALID_MESSAGE", "Cursor sort value does not match the active sort field"),
        error.InvalidSubscriptionId => wireError("INVALID_MESSAGE", "Invalid subscription ID format"),
        error.SubscriptionNotFound => wireError("SUBSCRIPTION_NOT_FOUND", "Subscription not found"),
        error.AuthFailed => wireError("AUTH_FAILED", "Identity verification failed"),
        error.TokenExpired => wireError("TOKEN_EXPIRED", "Session has expired"),
        error.PermissionDenied => wireError("PERMISSION_DENIED", "Rule blocked operation"),
        error.NamespaceUnauthorized => wireError("NAMESPACE_UNAUTHORIZED", "No access to namespace"),
        error.MaxDepthExceeded => wireError("MESSAGE_TOO_LARGE", "Payload too big"),
        error.RateLimited => wireError("RATE_LIMITED", "Threshold exceeded"),
        error.HookServerUnavailable => wireError("HOOK_SERVER_UNAVAILABLE", "Logic runtime down"),
        error.HookDenied => wireError("HOOK_DENIED", "Logic rejected write"),
        else => wireError("INTERNAL_ERROR", "Zig core failure"),
    };
}
