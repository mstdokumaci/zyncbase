const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const schema = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const pattern_mod = @import("pattern.zig");
const evaluate_mod = @import("evaluate.zig");
const doc_predicate_mod = @import("doc_predicate.zig");

pub const ReadAuthInput = struct {
    config: *const types.AuthConfig,
    table: *const schema.Table,
    session_user_id: typed_doc_id.DocId,
    session_external_id: ?[]const u8 = null,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value) = null,
    namespace: []const u8,
};

pub fn authorizeStoreRead(
    allocator: Allocator,
    input: ReadAuthInput,
) !?query_ast.FilterPredicate {
    var match = (try pattern_mod.matchNamespaceRule(allocator, input.config, input.namespace)) orelse return error.NamespaceUnauthorized;
    defer match.deinit(allocator);

    const store_rule = input.config.storeRuleFor(input.table.name) orelse return error.AccessDenied;

    const ctx: evaluate_mod.EvalContext = .{
        .allocator = allocator,
        .session_user_id = input.session_user_id,
        .session_external_id = input.session_external_id,
        .session_claims = input.session_claims,
        .namespace_captures = &match.captures.captures,
        .path_table = input.table.name,
    };

    return try doc_predicate_mod.buildDocPredicate(store_rule.read, ctx, input.table);
}
