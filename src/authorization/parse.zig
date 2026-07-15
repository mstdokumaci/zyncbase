const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const pattern_mod = @import("pattern.zig");
const doc_predicate = @import("doc_predicate.zig");
const schema_mod = @import("../schema.zig");
const query_ast = @import("../query_ast.zig");
const typed = @import("../typed.zig");
const json_read = @import("../json/read.zig");
const ScalarValue = typed.ScalarValue;
const Value = typed.Value;

/// Parse authorization.json text into an AuthConfig.
pub fn initFromJson(allocator: Allocator, json_text: []const u8, schema: *const schema_mod.Schema) !types.AuthConfig {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidAuthConfig;

    try json_read.rejectUnknownKeys(error.UnknownAuthKey, &.{ "namespaces", "store" }, root.object);

    const namespaces_val = (json_read.getArray(root.object, "namespaces") catch return error.InvalidAuthConfig) orelse return error.MissingNamespaces;

    const store_val = (json_read.getArray(root.object, "store") catch return error.InvalidAuthConfig) orelse return error.MissingStore;

    const namespace_rules = try json_read.collectParsedArray(
        allocator,
        types.NamespaceRule,
        std.json.Value,
        namespaces_val.items,
        parseNamespaceRule,
        types.NamespaceRule.deinit,
    );

    var store_rules = std.ArrayListUnmanaged(types.StoreRule).empty;
    errdefer {
        for (store_rules.items) |*rule| rule.deinit(allocator);
        store_rules.deinit(allocator);
    }
    try store_rules.ensureTotalCapacityPrecise(allocator, store_val.items.len);

    var wildcard_index: ?usize = null;
    for (store_val.items) |st_val| {
        var rule = try parseStoreRule(allocator, st_val);
        errdefer rule.deinit(allocator);
        if (rule.is_wildcard) wildcard_index = store_rules.items.len;
        try store_rules.append(allocator, rule);
    }

    var config = types.AuthConfig{
        .allocator = allocator,
        .namespace_rules = namespace_rules,
        .store_rules = try store_rules.toOwnedSlice(allocator),
        .wildcard_store_index = wildcard_index,
    };
    errdefer config.deinit();

    try validateConfig(&config, schema);
    return config;
}

pub fn validateConfig(config: *const types.AuthConfig, schema: *const schema_mod.Schema) !void {
    for (config.store_rules) |rule| {
        if (rule.is_wildcard) {
            for (schema.tables) |*table| {
                try validateStoreRule(rule, table);
            }
        } else {
            const table = schema.table(rule.collection) orelse return error.UnknownTable;
            try validateStoreRule(rule, table);
        }
    }
}

fn validateStoreRule(rule: types.StoreRule, table: *const schema_mod.Table) !void {
    try doc_predicate.validateDocPredicate(rule.read, table);
    try doc_predicate.validateDocPredicate(rule.write, table);
}

fn parseNamespaceRule(allocator: Allocator, value: std.json.Value) !types.NamespaceRule {
    if (value != .object) return error.InvalidNamespaceRule;
    const obj = value.object;
    try json_read.rejectUnknownKeys(error.UnknownAuthKey, &.{ "pattern", "storeFilter", "presenceRead", "presenceWrite", "presenceSharedWrite" }, obj);

    const pattern_val = (json_read.getString(obj, "pattern") catch return error.InvalidNamespaceRule) orelse return error.InvalidNamespaceRule;
    const pattern = try allocator.dupe(u8, pattern_val);
    errdefer allocator.free(pattern);
    const segments = try pattern_mod.parsePattern(allocator, pattern_val);
    errdefer {
        for (segments) |seg| seg.deinit(allocator);
        allocator.free(segments);
    }

    const store_filter = try parseRequiredCondition(allocator, obj, "storeFilter");
    errdefer store_filter.deinit(allocator);
    const presence_read = try parseRequiredCondition(allocator, obj, "presenceRead");
    errdefer presence_read.deinit(allocator);
    const presence_write = try parseRequiredCondition(allocator, obj, "presenceWrite");
    errdefer presence_write.deinit(allocator);
    const presence_shared_write_val = obj.get("presenceSharedWrite") orelse obj.get("presenceWrite").?;
    const presence_shared_write = try parseCondition(allocator, presence_shared_write_val);
    errdefer presence_shared_write.deinit(allocator);

    return types.NamespaceRule{
        .pattern = pattern,
        .segments = segments,
        .store_filter = store_filter,
        .presence_read = presence_read,
        .presence_write = presence_write,
        .presence_shared_write = presence_shared_write,
    };
}

fn parseStoreRule(allocator: Allocator, value: std.json.Value) !types.StoreRule {
    if (value != .object) return error.InvalidStoreRule;
    const obj = value.object;
    try json_read.rejectUnknownKeys(error.UnknownAuthKey, &.{ "collection", "read", "write" }, obj);

    const collection_val = (json_read.getString(obj, "collection") catch return error.InvalidStoreRule) orelse return error.InvalidStoreRule;
    const collection = try allocator.dupe(u8, collection_val);
    errdefer allocator.free(collection);

    const read = try parseCondition(allocator, obj.get("read") orelse return error.InvalidStoreRule);
    errdefer read.deinit(allocator);
    const write = try parseCondition(allocator, obj.get("write") orelse return error.InvalidStoreRule);
    errdefer write.deinit(allocator);

    return types.StoreRule{
        .collection = collection,
        .is_wildcard = std.mem.eql(u8, collection_val, "*"),
        .read = read,
        .write = write,
    };
}

fn parseRequiredCondition(allocator: Allocator, obj: std.json.ObjectMap, key: []const u8) !types.Condition {
    const val = obj.get(key) orelse return error.InvalidNamespaceRule;
    return parseCondition(allocator, val);
}

fn parseCondition(allocator: Allocator, value: std.json.Value) !types.Condition {
    switch (value) {
        .bool => |b| return .{ .boolean = b },
        .object => |obj| {
            if (obj.get("and")) |and_val| {
                if (obj.count() != 1) return error.InvalidCondition;
                return .{ .logical_and = try parseLogicalOpArray(allocator, and_val) };
            }
            if (obj.get("or")) |or_val| {
                if (obj.count() != 1) return error.InvalidCondition;
                return .{ .logical_or = try parseLogicalOpArray(allocator, or_val) };
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

fn deinitAuthCondition(c: *types.Condition, allocator: Allocator) void {
    c.deinit(allocator);
}

fn parseLogicalOpArray(allocator: Allocator, val: std.json.Value) anyerror![]types.Condition {
    if (val != .array) return error.InvalidCondition;
    const arr = val.array.items;
    if (arr.len == 0) return error.InvalidCondition;
    return json_read.collectParsedArray(
        allocator,
        types.Condition,
        std.json.Value,
        arr,
        parseCondition,
        deinitAuthCondition,
    );
}

fn parseComparison(allocator: Allocator, lhs_str: []const u8, rhs_val: std.json.Value) !types.Condition {
    const lhs = try parseContextVar(allocator, lhs_str);
    errdefer lhs.deinit(allocator);

    // Nullary operators: { "$doc.field": "isNull" }
    // The RHS value is the operator name as a plain string — no operand.
    if (rhs_val == .string) {
        const op = try parseNullaryOp(rhs_val.string);
        return .{ .comparison = .{ .lhs = lhs, .op = op, .rhs = null } };
    }

    // Binary operators: { "$doc.field": { "eq": value } }
    if (rhs_val != .object) return error.InvalidComparison;
    const op_obj = rhs_val.object;
    if (op_obj.count() != 1) return error.InvalidComparison;

    var it = op_obj.iterator();
    const op_entry = it.next() orelse return error.InvalidComparison;
    const op_str = op_entry.key_ptr.*;
    const op = try parseBinaryOp(op_str);

    const rhs = try parseOperand(allocator, op_entry.value_ptr.*);
    errdefer rhs.deinit(allocator);

    return .{ .comparison = .{ .lhs = lhs, .op = op, .rhs = rhs } };
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

fn parseNullaryOp(op_str: []const u8) !query_ast.Operator {
    const map = std.StaticStringMap(query_ast.Operator).initComptime(.{
        .{ "isNull", .isNull },
        .{ "isNotNull", .isNotNull },
    });
    return map.get(op_str) orelse error.InvalidComparisonOperator;
}

fn parseBinaryOp(op_str: []const u8) !query_ast.Operator {
    const map = std.StaticStringMap(query_ast.Operator).initComptime(.{
        .{ "eq", .eq },
        .{ "ne", .ne },
        .{ "gt", .gt },
        .{ "gte", .gte },
        .{ "lt", .lt },
        .{ "lte", .lte },
        .{ "in", .in },
        .{ "notIn", .notIn },
        .{ "contains", .contains },
        .{ "startsWith", .startsWith },
        .{ "endsWith", .endsWith },
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
