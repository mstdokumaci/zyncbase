const std = @import("std");
const Allocator = std.mem.Allocator;
const authorization_parse = @import("parse.zig");
const authorization_defaults = @import("defaults.zig");
const authorization_types = @import("types.zig");
const schema_types = @import("../schema/types.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const NamespaceRule = authorization_types.NamespaceRule;
const StoreRule = authorization_types.StoreRule;
const PatternSegment = authorization_types.PatternSegment;
const AuthConfig = authorization_types.AuthConfig;

pub fn initTestConfig(allocator: std.mem.Allocator, json: []const u8) !AuthConfig {
    var schema = try makeAuthTestSchema(allocator);
    defer schema.deinit();
    return authorization_parse.initFromJson(allocator, json, &schema);
}

pub fn implicitTestConfig(allocator: std.mem.Allocator) !AuthConfig {
    var schema = try makeAuthTestSchema(allocator);
    defer schema.deinit();
    return authorization_defaults.implicitConfig(allocator, &schema);
}

pub fn permissiveTestConfig(allocator: std.mem.Allocator, schema: *const schema_types.Schema) !AuthConfig {
    const ns_rules = try allocator.alloc(NamespaceRule, 1);
    var ns_rules_len: usize = 0;
    errdefer {
        for (ns_rules[0..ns_rules_len]) |*rule| rule.deinit(allocator);
        allocator.free(ns_rules);
    }

    ns_rules[0] = try makeWildcardNamespaceRule(allocator);
    ns_rules_len = 1;

    const st_rules = try allocator.alloc(StoreRule, 1);
    var st_rules_len: usize = 0;
    errdefer {
        for (st_rules[0..st_rules_len]) |*rule| rule.deinit(allocator);
        allocator.free(st_rules);
    }

    st_rules[0] = try makePermissiveStoreRule(allocator);
    st_rules_len = 1;

    var config = AuthConfig{
        .allocator = allocator,
        .namespace_rules = ns_rules,
        .store_rules = st_rules,
        .wildcard_store_index = 0,
    };

    try authorization_parse.validateConfig(&config, schema);
    return config;
}

fn makeWildcardNamespaceRule(allocator: Allocator) !NamespaceRule {
    const pattern = try allocator.dupe(u8, "*");
    errdefer allocator.free(pattern);

    const segments = try allocator.alloc(PatternSegment, 1);
    errdefer allocator.free(segments);
    const literal_str = try allocator.dupe(u8, "*");
    errdefer allocator.free(literal_str);
    segments[0] = .{ .literal = literal_str };

    return .{
        .pattern = pattern,
        .segments = segments,
        .store_filter = .{ .boolean = true },
        .presence_read = .{ .boolean = true },
        .presence_write = .{ .boolean = true },
        .presence_shared_write = .{ .boolean = true },
    };
}

fn makePermissiveStoreRule(allocator: Allocator) !StoreRule {
    const collection = try allocator.dupe(u8, "*");
    errdefer allocator.free(collection);

    return .{
        .collection = collection,
        .is_wildcard = true,
        .read = .{ .boolean = true },
        .write = .{ .boolean = true },
    };
}

fn makeAuthTestSchema(allocator: std.mem.Allocator) !schema_types.Schema {
    const text_types = [_]schema_types.FieldType{.text};
    return schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{
        .{
            .name = "posts",
            .fields = &[_][]const u8{"visibility"},
            .types = &text_types,
        },
        .{
            .name = "test",
            .fields = &[_][]const u8{"visibility"},
            .types = &text_types,
        },
    });
}
