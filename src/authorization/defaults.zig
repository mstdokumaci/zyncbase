const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const parse = @import("parse.zig");
const schema = @import("../schema.zig");
const AuthConfig = types.AuthConfig;
const NamespaceRule = types.NamespaceRule;
const StoreRule = types.StoreRule;
const Condition = types.Condition;
const PatternSegment = types.PatternSegment;

/// Returns a pre-built AuthConfig from the implicit defaults.
/// Caller owns the returned config and must call deinit().
pub fn implicitConfig(allocator: Allocator, schema_manager: *const schema.Schema) !AuthConfig {
    const ns_rules = try allocator.alloc(NamespaceRule, 1);
    var ns_rules_len: usize = 0;
    errdefer {
        for (ns_rules[0..ns_rules_len]) |*rule| rule.deinit(allocator);
        allocator.free(ns_rules);
    }

    ns_rules[0] = try makePublicNamespaceRule(allocator);
    ns_rules_len = 1;

    const st_rules = try allocator.alloc(StoreRule, 1);
    var st_rules_len: usize = 0;
    errdefer {
        for (st_rules[0..st_rules_len]) |*rule| rule.deinit(allocator);
        allocator.free(st_rules);
    }

    st_rules[0] = try makeWildcardStoreRule(allocator);
    st_rules_len = 1;

    var config = AuthConfig{
        .allocator = allocator,
        .namespace_rules = ns_rules,
        .store_rules = st_rules,
        .wildcard_store_index = 0,
    };

    try parse.validateConfig(&config, schema_manager);
    return config;
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
