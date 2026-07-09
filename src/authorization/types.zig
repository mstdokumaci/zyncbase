const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed.zig");
const query_ast = @import("../query_ast.zig");
const Value = typed.Value;

/// Result of matching namespace against pattern.
/// Lifetime: borrows capture keys from `AuthConfig` segments and values from namespace (do not use after either is freed).
/// Call `deinit(allocator)` to release the hash map's internal bucket storage.
pub const PatternMatch = struct {
    captures: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *PatternMatch, allocator: Allocator) void {
        self.captures.deinit(allocator);
    }

    pub fn get(self: *const PatternMatch, key: []const u8) ?[]const u8 {
        return self.captures.get(key);
    }
};

pub const AuthConfig = struct {
    allocator: Allocator,
    namespace_rules: []NamespaceRule,
    store_rules: []StoreRule,
    wildcard_store_index: ?usize,

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
        captures: PatternMatch,

        pub fn deinit(self: *NamespaceRuleMatch, allocator: Allocator) void {
            self.captures.deinit(allocator);
        }
    };
};

pub const NamespaceRule = struct {
    pattern: []const u8,
    segments: []PatternSegment,
    store_filter: Condition,
    presence_read: Condition,
    presence_write: Condition,
    presence_shared_write: Condition,

    pub fn deinit(self: *NamespaceRule, allocator: Allocator) void {
        allocator.free(self.pattern);
        for (self.segments) |seg| seg.deinit(allocator);
        allocator.free(self.segments);
        self.store_filter.deinit(allocator);
        self.presence_read.deinit(allocator);
        self.presence_write.deinit(allocator);
        self.presence_shared_write.deinit(allocator);
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
    logical_and: []Condition,
    logical_or: []Condition,
    comparison: Comparison,

    pub fn deinit(self: Condition, allocator: Allocator) void {
        var mutable = self;
        switch (mutable) {
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
    op: query_ast.Operator,
    rhs: ?Operand,

    pub fn deinit(self: *Comparison, allocator: Allocator) void {
        self.lhs.deinit(allocator);
        if (self.rhs) |rhs| rhs.deinit(allocator);
    }
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
