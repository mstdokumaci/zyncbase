const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed.zig");
const schema = @import("../schema.zig");
const Value = typed.Value;

pub const AuthConfig = struct {
    allocator: Allocator,
    namespace_rules: []NamespaceRule,
    store_rules: []StoreRule,
    wildcard_store_index: ?usize,

    pub fn init(allocator: Allocator, json_text: []const u8, schema_manager: *const schema.Schema) !AuthConfig {
        return @import("parse.zig").initFromJson(allocator, json_text, schema_manager);
    }

    pub fn deinit(self: *AuthConfig) void {
        for (self.namespace_rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.namespace_rules);
        for (self.store_rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.store_rules);
    }

    /// Find the StoreRule for a given collection name.
    /// Returns the first exact match, then wildcard, then null.
    pub fn storeRuleFor(self: *const AuthConfig, collection: []const u8) ?*const StoreRule {
        var found: ?*const StoreRule = null;
        for (self.store_rules) |*rule| {
            if (std.mem.eql(u8, rule.collection, collection)) return rule;
            if (rule.is_wildcard) found = rule;
        }
        return found;
    }

    pub const NamespaceRuleMatch = struct {
        rule: *const NamespaceRule,
        captures: @import("pattern.zig").PatternMatch,

        pub fn deinit(self: *NamespaceRuleMatch, allocator: Allocator) void {
            self.captures.deinit(allocator);
        }
    };

    /// Find the first NamespaceRule whose pattern matches the given namespace string.
    /// Caller must call deinit() on the returned match to free captures.
    pub fn namespaceRuleFor(self: *const AuthConfig, allocator: Allocator, namespace: []const u8) !?NamespaceRuleMatch {
        const pattern_mod = @import("pattern.zig");
        for (self.namespace_rules) |*rule| {
            if (try pattern_mod.matchNamespace(allocator, rule.segments, namespace)) |match| {
                return .{ .rule = rule, .captures = match };
            }
        }
        return null;
    }
};

pub const NamespaceRule = struct {
    pattern: []const u8,
    segments: []PatternSegment,
    store_filter: Condition,
    presence_read: Condition,
    presence_write: Condition,

    pub fn deinit(self: *NamespaceRule, allocator: Allocator) void {
        allocator.free(self.pattern);
        for (self.segments) |seg| seg.deinit(allocator);
        allocator.free(self.segments);
        self.store_filter.deinit(allocator);
        self.presence_read.deinit(allocator);
        self.presence_write.deinit(allocator);
    }
};

pub const PatternSegment = union(enum) {
    literal: []const u8,
    capture: []const u8,

    pub fn deinit(self: PatternSegment, allocator: Allocator) void {
        switch (self) {
            .literal => |s| allocator.free(s),
            .capture => |s| allocator.free(s),
        }
    }
};

pub const StoreRule = struct {
    collection: []const u8,
    is_wildcard: bool,
    read: Condition,
    write: Condition,

    pub fn deinit(self: *StoreRule, allocator: Allocator) void {
        allocator.free(self.collection);
        self.read.deinit(allocator);
        self.write.deinit(allocator);
    }
};

pub const Condition = union(enum) {
    boolean: bool,
    hook: []const u8,
    logical_and: []Condition,
    logical_or: []Condition,
    comparison: Comparison,

    pub fn deinit(self: Condition, allocator: Allocator) void {
        var mutable = self;
        switch (mutable) {
            .hook => |h| allocator.free(h),
            .logical_and => |conds| {
                for (conds) |*cond| cond.deinit(allocator);
                allocator.free(conds);
            },
            .logical_or => |conds| {
                for (conds) |*cond| cond.deinit(allocator);
                allocator.free(conds);
            },
            .comparison => |*comp| comp.deinit(allocator),
            else => {},
        }
    }
};

pub const Comparison = struct {
    lhs: ContextVar,
    op: ComparisonOp,
    rhs: Operand,

    pub fn deinit(self: *Comparison, allocator: Allocator) void {
        self.lhs.deinit(allocator);
        self.rhs.deinit(allocator);
    }
};

pub const ComparisonOp = enum {
    eq,
    ne,
    gt,
    gte,
    lt,
    lte,
    in_set,
    not_in_set,
    contains,
};

pub const ContextVar = struct {
    scope: VarScope,
    field: []const u8,

    pub fn deinit(self: ContextVar, allocator: Allocator) void {
        allocator.free(self.field);
    }
};

pub const VarScope = enum {
    session,
    namespace,
    path,
    value,
    doc,
};

pub const Operand = union(enum) {
    literal: Value,
    context_var: ContextVar,

    pub fn deinit(self: Operand, allocator: Allocator) void {
        switch (self) {
            .literal => |v| v.deinit(allocator),
            .context_var => |cv| cv.deinit(allocator),
        }
    }
};
