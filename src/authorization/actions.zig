const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const evaluate_mod = @import("evaluate.zig");
const pattern_mod = @import("pattern.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

/// Authorize an `ActionCall` before params validation and forwarding.
/// `invoke` sees `$session`, `$namespace`, and `$value` (the params pair-array).
pub fn authorizeActionInvoke(
    allocator: Allocator,
    config: *const types.AuthConfig,
    action: *const schema_types.Action,
    namespace: []const u8,
    session_user_id: typed_doc_id.DocId,
    session_external_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
    params_payload: *const msgpack.Payload,
) !void {
    var match = (try pattern_mod.matchNamespaceRule(allocator, config, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const rule = config.actionRuleFor(action.name) orelse return error.PermissionDenied;

    const ctx: evaluate_mod.EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .session_claims = session_claims,
        .namespace_captures = &match.captures.captures,
        .value_payload = params_payload,
        .action_fields = action.params,
    };
    if (!evaluate_mod.evaluateConditionStrict(rule.invoke, ctx)) return error.PermissionDenied;
}

/// Authorize an `ActionRegister` entry for one action. `register` sees
/// `$session` and `$namespace` only.
pub fn authorizeActionRegister(
    allocator: Allocator,
    config: *const types.AuthConfig,
    action: *const schema_types.Action,
    namespace: []const u8,
    session_user_id: typed_doc_id.DocId,
    session_external_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
) !void {
    var match = (try pattern_mod.matchNamespaceRule(allocator, config, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const rule = config.actionRuleFor(action.name) orelse return error.PermissionDenied;

    const ctx: evaluate_mod.EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .session_claims = session_claims,
        .namespace_captures = &match.captures.captures,
    };
    if (!evaluate_mod.evaluateConditionStrict(rule.register, ctx)) return error.PermissionDenied;
}
