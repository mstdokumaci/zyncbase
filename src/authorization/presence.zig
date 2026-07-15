const std = @import("std");
const msgpack = @import("../msgpack_utils.zig");
const types = @import("types.zig");
const pattern_mod = @import("pattern.zig");
const evaluate_mod = @import("evaluate.zig");
const typed = @import("../typed/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const schema_types = @import("../schema/types.zig");
const Allocator = std.mem.Allocator;

pub fn authorizePresenceWrite(
    allocator: Allocator,
    config: *const types.AuthConfig,
    namespace: []const u8,
    session_user_id: typed_doc_id.DocId,
    session_external_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
    presence_fields: []const schema_types.PresenceField,
    data_payload: *const msgpack.Payload,
) !void {
    var match = (try pattern_mod.matchNamespaceRule(allocator, config, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const ctx: evaluate_mod.EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .session_claims = session_claims,
        .namespace_captures = &match.captures.captures,
        .value_payload = data_payload,
        .presence_fields = presence_fields,
    };
    if (!evaluate_mod.evaluateConditionStrict(match.rule.presence_write, ctx)) return error.NamespaceUnauthorized;
}

pub fn authorizePresenceSharedWrite(
    allocator: Allocator,
    config: *const types.AuthConfig,
    namespace: []const u8,
    session_user_id: typed_doc_id.DocId,
    session_external_id: []const u8,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value),
    presence_fields: []const schema_types.PresenceField,
    data_payload: *const msgpack.Payload,
) !void {
    var match = (try pattern_mod.matchNamespaceRule(allocator, config, namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const ctx: evaluate_mod.EvalContext = .{
        .allocator = allocator,
        .session_user_id = session_user_id,
        .session_external_id = session_external_id,
        .session_claims = session_claims,
        .namespace_captures = &match.captures.captures,
        .value_payload = data_payload,
        .presence_fields = presence_fields,
    };
    if (!evaluate_mod.evaluateConditionStrict(match.rule.presence_shared_write, ctx)) return error.NamespaceUnauthorized;
}
