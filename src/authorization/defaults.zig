const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const AuthConfig = types.AuthConfig;
const NamespaceRule = types.NamespaceRule;
const StoreRule = types.StoreRule;
const Condition = types.Condition;
const PatternSegment = types.PatternSegment;

/// Returns a pre-built AuthConfig from the implicit defaults.
/// Caller owns the returned config and must call deinit().
pub fn implicitConfig(allocator: Allocator) !AuthConfig {
    var result: AuthConfig = .{
        .allocator = allocator,
        .namespace_rules = &.{},
        .store_rules = &.{},
        .wildcard_store_index = null,
    };
    errdefer result.deinit();

    // Build namespace rules
    const ns_rules = try allocator.alloc(NamespaceRule, 1);
    errdefer allocator.free(ns_rules);

    ns_rules[0] = try makePublicNamespaceRule(allocator);
    errdefer ns_rules[0].deinit(allocator);

    // Build store rules
    const st_rules = try allocator.alloc(StoreRule, 1);
    errdefer allocator.free(st_rules);

    st_rules[0] = try makeWildcardStoreRule(allocator);
    errdefer st_rules[0].deinit(allocator);

    result.namespace_rules = ns_rules;
    result.store_rules = st_rules;
    result.wildcard_store_index = 0;

    return result;
}

fn makePublicNamespaceRule(allocator: Allocator) !NamespaceRule {
    const pattern = try allocator.dupe(u8, "public");
    errdefer allocator.free(pattern);

    const segments = try allocator.alloc(PatternSegment, 1);
    errdefer allocator.free(segments);
    segments[0] = .{ .literal = try allocator.dupe(u8, "public") };
    errdefer switch (segments[0]) {
        .literal => |s| allocator.free(s),
        .capture => |s| allocator.free(s),
    };

    return .{
        .pattern = pattern,
        .segments = segments,
        .store_filter = .{ .boolean = true },
        .presence_read = .{ .boolean = true },
        .presence_write = .{ .boolean = true },
    };
}

fn makeWildcardStoreRule(allocator: Allocator) !StoreRule {
    const collection = try allocator.dupe(u8, "*");
    errdefer allocator.free(collection);

    const owner_id_field = try allocator.dupe(u8, "owner_id");
    errdefer allocator.free(owner_id_field);

    const user_id_field = try allocator.dupe(u8, "userId");
    errdefer allocator.free(user_id_field);

    const write_cond = Condition{
        .comparison = .{
            .lhs = .{ .scope = .doc, .field = owner_id_field },
            .op = .eq,
            .rhs = .{ .context_var = .{ .scope = .session, .field = user_id_field } },
        },
    };

    return .{
        .collection = collection,
        .is_wildcard = true,
        .read = .{ .boolean = true },
        .write = write_cond,
    };
}
