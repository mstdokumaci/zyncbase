const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const pattern_mod = @import("pattern.zig");
const doc_predicate = @import("doc_predicate.zig");
const schema = @import("../schema.zig");
const typed = @import("../typed.zig");
const ScalarValue = typed.ScalarValue;
const Value = typed.Value;

/// Parse authorization.json text into an AuthConfig.
pub fn initFromJson(allocator: Allocator, json_text: []const u8, schema_manager: *const schema.Schema) !types.AuthConfig {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidAuthConfig;

    try rejectUnknownRootKeys(root);

    const namespaces_val = root.object.get("namespaces") orelse return error.MissingNamespaces;
    if (namespaces_val != .array) return error.InvalidAuthConfig;

    const store_val = root.object.get("store") orelse return error.MissingStore;
    if (store_val != .array) return error.InvalidAuthConfig;

    var namespace_rules = std.ArrayListUnmanaged(types.NamespaceRule).empty;
    errdefer {
        for (namespace_rules.items) |*rule| rule.deinit(allocator);
        namespace_rules.deinit(allocator);
    }

    for (namespaces_val.array.items) |ns_val| {
        var rule = try parseNamespaceRule(allocator, ns_val);
        errdefer rule.deinit(allocator);
        try namespace_rules.append(allocator, rule);
    }

    var store_rules = std.ArrayListUnmanaged(types.StoreRule).empty;
    errdefer {
        for (store_rules.items) |*rule| rule.deinit(allocator);
        store_rules.deinit(allocator);
    }

    var wildcard_index: ?usize = null;
    for (store_val.array.items) |st_val| {
        var rule = try parseStoreRule(allocator, st_val);
        errdefer rule.deinit(allocator);
        if (rule.is_wildcard) wildcard_index = store_rules.items.len;
        try store_rules.append(allocator, rule);
    }

    var config = types.AuthConfig{
        .allocator = allocator,
        .namespace_rules = try namespace_rules.toOwnedSlice(allocator),
        .store_rules = try store_rules.toOwnedSlice(allocator),
        .wildcard_store_index = wildcard_index,
    };
    errdefer config.deinit();

    try validateConfig(&config, schema_manager);
    return config;
}

pub fn validateConfig(config: *const types.AuthConfig, schema_manager: *const schema.Schema) !void {
    for (config.store_rules) |rule| {
        if (rule.is_wildcard) {
            for (schema_manager.tables) |*table| {
                try validateStoreRule(rule, table);
            }
        } else {
            const table = schema_manager.getTable(rule.collection) orelse return error.UnknownTable;
            try validateStoreRule(rule, table);
        }
    }
}

fn validateStoreRule(rule: types.StoreRule, table: *const schema.Table) !void {
    try doc_predicate.validateDocPredicate(rule.read, table);
    try doc_predicate.validateDocPredicate(rule.write, table);
}

fn parseNamespaceRule(allocator: Allocator, value: std.json.Value) !types.NamespaceRule {
    if (value != .object) return error.InvalidNamespaceRule;
    const obj = value.object;
    try rejectUnknownNamespaceKeys(obj);

    const pattern_val = obj.get("pattern") orelse return error.InvalidNamespaceRule;
    if (pattern_val != .string) return error.InvalidNamespaceRule;
    const pattern = try allocator.dupe(u8, pattern_val.string);
    errdefer allocator.free(pattern);
    const segments = try pattern_mod.parsePattern(allocator, pattern_val.string);
    errdefer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const store_filter = try parseCondition(allocator, obj.get("storeFilter") orelse return error.InvalidNamespaceRule);
    errdefer store_filter.deinit(allocator);
    const presence_read = try parseCondition(allocator, obj.get("presenceRead") orelse return error.InvalidNamespaceRule);
    errdefer presence_read.deinit(allocator);
    const presence_write = try parseCondition(allocator, obj.get("presenceWrite") orelse return error.InvalidNamespaceRule);
    errdefer presence_write.deinit(allocator);

    return types.NamespaceRule{
        .pattern = pattern,
        .segments = segments,
        .store_filter = store_filter,
        .presence_read = presence_read,
        .presence_write = presence_write,
    };
}

fn parseStoreRule(allocator: Allocator, value: std.json.Value) !types.StoreRule {
    if (value != .object) return error.InvalidStoreRule;
    const obj = value.object;
    try rejectUnknownStoreKeys(obj);

    const collection_val = obj.get("collection") orelse return error.InvalidStoreRule;
    if (collection_val != .string) return error.InvalidStoreRule;
    const collection = try allocator.dupe(u8, collection_val.string);
    errdefer allocator.free(collection);

    const read = try parseCondition(allocator, obj.get("read") orelse return error.InvalidStoreRule);
    errdefer read.deinit(allocator);
    const write = try parseCondition(allocator, obj.get("write") orelse return error.InvalidStoreRule);
    errdefer write.deinit(allocator);

    return types.StoreRule{
        .collection = collection,
        .is_wildcard = std.mem.eql(u8, collection_val.string, "*"),
        .read = read,
        .write = write,
    };
}

fn parseCondition(allocator: Allocator, value: std.json.Value) !types.Condition {
    switch (value) {
        .bool => |b| return .{ .boolean = b },
        .object => |obj| {
            if (obj.get("hook")) |hook_val| {
                if (obj.count() != 1) return error.InvalidCondition;
                if (hook_val != .string) return error.InvalidHook;
                const hook_name = try allocator.dupe(u8, hook_val.string);
                return .{ .hook = hook_name };
            }
            if (obj.get("and")) |and_val| {
                if (obj.count() != 1) return error.InvalidCondition;
                if (and_val != .array) return error.InvalidCondition;
                const arr = and_val.array.items;
                if (arr.len == 0) return error.InvalidCondition;
                const conds = try allocator.alloc(types.Condition, arr.len);
                var initialized: usize = 0;
                errdefer {
                    for (conds[0..initialized]) |*cond| cond.deinit(allocator);
                    allocator.free(conds);
                }
                for (arr, 0..) |item, i| {
                    conds[i] = try parseCondition(allocator, item);
                    initialized += 1;
                }
                return .{ .logical_and = conds };
            }
            if (obj.get("or")) |or_val| {
                if (obj.count() != 1) return error.InvalidCondition;
                if (or_val != .array) return error.InvalidCondition;
                const arr = or_val.array.items;
                if (arr.len == 0) return error.InvalidCondition;
                const conds = try allocator.alloc(types.Condition, arr.len);
                var initialized: usize = 0;
                errdefer {
                    for (conds[0..initialized]) |*cond| cond.deinit(allocator);
                    allocator.free(conds);
                }
                for (arr, 0..) |item, i| {
                    conds[i] = try parseCondition(allocator, item);
                    initialized += 1;
                }
                return .{ .logical_or = conds };
            }

            // Must be a single-key comparison
            if (obj.count() != 1) return error.InvalidComparison;
            var it = obj.iterator();
            const entry = it.next() orelse return error.InvalidComparison;
            const lhs_str = entry.key_ptr.*;
            const rhs_val = entry.value_ptr.*;
            if (lhs_str.len == 0 or lhs_str[0] != '$') return error.InvalidContextVariable;

            return try parseComparison(allocator, lhs_str, rhs_val);
        },
        else => return error.InvalidCondition,
    }
}

fn parseComparison(allocator: Allocator, lhs_str: []const u8, rhs_val: std.json.Value) !types.Condition {
    const lhs = try parseContextVar(allocator, lhs_str);
    errdefer lhs.deinit(allocator);

    if (rhs_val != .object) return error.InvalidComparison;
    const op_obj = rhs_val.object;
    if (op_obj.count() != 1) return error.InvalidComparison;

    var it = op_obj.iterator();
    const op_entry = it.next() orelse return error.InvalidComparison;
    const op_str = op_entry.key_ptr.*;
    const op = try parseComparisonOp(op_str);

    const rhs = try parseOperand(allocator, op_entry.value_ptr.*);
    errdefer rhs.deinit(allocator);

    return .{ .comparison = .{
        .lhs = lhs,
        .op = op,
        .rhs = rhs,
    } };
}

fn parseContextVar(allocator: Allocator, raw: []const u8) !types.ContextVar {
    if (raw.len < 2 or raw[0] != '$') return error.InvalidContextVariable;
    const rest = raw[1..];
    const dot = std.mem.indexOfScalar(u8, rest, '.');
    const scope_str = if (dot) |d| rest[0..d] else rest;
    const field = if (dot) |d| try allocator.dupe(u8, rest[d + 1 ..]) else try allocator.dupe(u8, "");
    errdefer allocator.free(field);

    const scope = std.meta.stringToEnum(types.VarScope, scope_str) orelse return error.InvalidContextVariable;
    if (scope == .doc and dot == null) return error.InvalidContextVariable;

    return .{ .scope = scope, .field = field };
}

fn parseComparisonOp(op_str: []const u8) !types.ComparisonOp {
    const map = std.StaticStringMap(types.ComparisonOp).initComptime(.{
        .{ "eq", .eq },
        .{ "ne", .ne },
        .{ "gt", .gt },
        .{ "gte", .gte },
        .{ "lt", .lt },
        .{ "lte", .lte },
        .{ "in", .in_set },
        .{ "notIn", .not_in_set },
        .{ "contains", .contains },
    });
    return map.get(op_str) orelse error.InvalidComparisonOperator;
}

fn parseOperand(allocator: Allocator, value: std.json.Value) !types.Operand {
    switch (value) {
        .string => |s| {
            if (s.len > 0 and s[0] == '$') {
                const ctx_var = try parseContextVar(allocator, s);
                return .{ .context_var = ctx_var };
            }
            return .{ .literal = .{ .scalar = .{ .text = try allocator.dupe(u8, s) } } };
        },
        .integer => |i| return .{ .literal = .{ .scalar = .{ .integer = i } } },
        .float => |f| return .{ .literal = .{ .scalar = .{ .real = f } } },
        .bool => |b| return .{ .literal = .{ .scalar = .{ .boolean = b } } },
        .array => |arr| return parseArrayLiteral(allocator, arr.items),
        else => return error.InvalidValue,
    }
}

fn parseArrayLiteral(allocator: Allocator, values: []const std.json.Value) !types.Operand {
    const items = try allocator.alloc(ScalarValue, values.len);
    var initialized: usize = 0;
    var items_owned = true;
    errdefer if (items_owned) {
        for (items[0..initialized]) |item| item.deinit(allocator);
        allocator.free(items);
    };

    if (values.len > 0) {
        const expected_tag = std.meta.activeTag(values[0]);
        for (values, 0..) |item, i| {
            if (std.meta.activeTag(item) != expected_tag) return error.InvalidValue;
            items[i] = try parseScalarArrayItem(allocator, item);
            initialized += 1;
        }
    }

    items_owned = false;
    var result = Value{ .array = items };
    errdefer result.deinit(allocator);
    try result.sortedSet(allocator);
    return .{ .literal = result };
}

fn parseScalarArrayItem(allocator: Allocator, value: std.json.Value) !ScalarValue {
    return switch (value) {
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .real = f },
        .bool => |b| .{ .boolean = b },
        else => error.InvalidValue,
    };
}

fn rejectUnknownRootKeys(root: std.json.Value) !void {
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "namespaces")) continue;
        if (std.mem.eql(u8, key, "store")) continue;
        return error.UnknownAuthKey;
    }
}

fn rejectUnknownNamespaceKeys(obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "pattern")) continue;
        if (std.mem.eql(u8, key, "storeFilter")) continue;
        if (std.mem.eql(u8, key, "presenceRead")) continue;
        if (std.mem.eql(u8, key, "presenceWrite")) continue;
        return error.UnknownAuthKey;
    }
}

fn rejectUnknownStoreKeys(obj: std.json.ObjectMap) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "collection")) continue;
        if (std.mem.eql(u8, key, "read")) continue;
        if (std.mem.eql(u8, key, "write")) continue;
        return error.UnknownAuthKey;
    }
}
