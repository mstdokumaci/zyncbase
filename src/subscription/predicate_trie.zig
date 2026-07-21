const std = @import("std");
const Allocator = std.mem.Allocator;
const query_ast = @import("../query/ast.zig");
const query_eval = @import("../query/eval.zig");
const hash_context = @import("../query/hash_context.zig");
const typed = @import("../typed/types.zig");

const Condition = query_ast.Condition;
const FilterPredicate = query_ast.FilterPredicate;
const Operator = query_ast.Operator;
const QueryFilter = query_ast.QueryFilter;
const Record = typed.Record;
const Value = typed.Value;

/// Hash/eq context for owned `Value` keys in equality branches.
pub const ValueContext = struct {
    pub fn hash(_: ValueContext, v: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hash_context.hashValue(&hasher, v);
        return hasher.final();
    }

    pub fn eql(_: ValueContext, a: Value, b: Value) bool {
        return a.eql(b);
    }
};

/// Hash/eq context for owned non-eq `Condition` edge keys.
pub const ConditionContext = struct {
    pub fn hash(_: ConditionContext, c: Condition) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hash_context.hashCondition(&hasher, c);
        return hasher.final();
    }

    pub fn eql(_: ConditionContext, a: Condition, b: Condition) bool {
        return hash_context.eqlCondition(a, b);
    }
};

/// Evaluation-order tier: equality first, then cheap ops, then expensive string ops.
fn conditionTier(op: Operator) u8 {
    return switch (op) {
        .eq => 0,
        .isNull, .isNotNull, .ne, .gt, .lt, .gte, .lte, .in, .notIn => 1,
        .contains, .startsWith, .endsWith => 2,
    };
}

fn pathConditionLessThan(_: void, a: Condition, b: Condition) bool {
    const ta = conditionTier(a.op);
    const tb = conditionTier(b.op);
    if (ta != tb) return ta < tb;
    if (a.field_index != b.field_index) return a.field_index < b.field_index;
    if (a.op != b.op) return @intFromEnum(a.op) < @intFromEnum(b.op);
    if (a.field_type != b.field_type) return @intFromEnum(a.field_type) < @intFromEnum(b.field_type);
    const a_items = a.items_type;
    const b_items = b.items_type;
    if (a_items != null and b_items != null) {
        if (a_items.? != b_items.?) return @intFromEnum(a_items.?) < @intFromEnum(b_items.?);
    } else if (a_items == null and b_items != null) {
        return true;
    } else if (a_items != null and b_items == null) {
        return false;
    }
    return hash_context.conditionValueLessThan(a.value, b.value);
}

const ValueMap = std.HashMapUnmanaged(Value, *Node, ValueContext, 80);
const CondMap = std.HashMapUnmanaged(Condition, *Node, ConditionContext, 80);
const FieldEqMap = std.AutoHashMapUnmanaged(usize, ValueMap);

/// One node in the per-collection condition-prefix trie.
pub const Node = struct {
    /// Groups whose full AND path ends at this node.
    leaf_groups: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Equality multi-way branches: field_index → (value → child).
    eq_branches: FieldEqMap = .empty,
    /// Non-equality condition edges: full condition → child (pass only).
    cond_branches: CondMap = .empty,

    fn isEmpty(self: *const Node) bool {
        return self.leaf_groups.count() == 0 and self.eq_branches.count() == 0 and self.cond_branches.count() == 0;
    }

    fn deinit(self: *Node, allocator: Allocator) void {
        self.leaf_groups.deinit(allocator);

        var eq_it = self.eq_branches.iterator();
        while (eq_it.next()) |field_entry| {
            var val_it = field_entry.value_ptr.iterator();
            while (val_it.next()) |val_entry| {
                val_entry.value_ptr.*.deinit(allocator);
                allocator.destroy(val_entry.value_ptr.*);
                var key = val_entry.key_ptr.*;
                key.deinit(allocator);
            }
            field_entry.value_ptr.deinit(allocator);
        }
        self.eq_branches.deinit(allocator);

        var cond_it = self.cond_branches.iterator();
        while (cond_it.next()) |cond_entry| {
            cond_entry.value_ptr.*.deinit(allocator);
            allocator.destroy(cond_entry.value_ptr.*);
            var key = cond_entry.key_ptr.*;
            key.deinit(allocator);
        }
        self.cond_branches.deinit(allocator);
    }
};

/// Per-collection predicate discrimination trie.
/// Parent/child topology is fully determined by a fixed total order on AND conditions.
/// Subscribe/unsubscribe only insert/delete along that path — no periodic recalculation.
pub const PredicateTrie = struct {
    allocator: Allocator,
    root: Node = .{},

    pub fn init(allocator: Allocator) PredicateTrie {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PredicateTrie) void {
        self.root.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn isEmpty(self: *const PredicateTrie) bool {
        return self.root.isEmpty();
    }

    /// Insert `group_id` under the canonical AND path of `filter`.
    /// `match_none` filters are not inserted (they never match).
    /// Returns true if the group was placed in the trie.
    pub fn insertGroup(self: *PredicateTrie, group_id: u64, filter: *const QueryFilter) !bool {
        switch (filter.predicate.state) {
            .match_none => return false,
            .match_all => {
                try self.root.leaf_groups.put(self.allocator, group_id, {});
                return true;
            },
            .conditional => {},
        }

        var path_buf: std.ArrayListUnmanaged(Condition) = .empty;
        defer path_buf.deinit(self.allocator);
        try buildPath(self.allocator, &filter.predicate, &path_buf);

        var node: *Node = &self.root;
        for (path_buf.items) |step| {
            node = try self.getOrCreateChild(node, step);
        }
        try node.leaf_groups.put(self.allocator, group_id, {});
        return true;
    }

    /// Remove `group_id` using the same canonical path as insert. Frees empty nodes.
    pub fn removeGroup(self: *PredicateTrie, group_id: u64, filter: *const QueryFilter) void {
        switch (filter.predicate.state) {
            .match_none => return,
            .match_all => {
                _ = self.root.leaf_groups.remove(group_id);
                return;
            },
            .conditional => {},
        }

        var path_buf: std.ArrayListUnmanaged(Condition) = .empty;
        defer path_buf.deinit(self.allocator);
        buildPath(self.allocator, &filter.predicate, &path_buf) catch {
            _ = removeGroupBySearch(self.allocator, &self.root, group_id);
            return;
        };

        _ = removeAlongPath(self.allocator, &self.root, path_buf.items, 0, group_id);
    }

    /// Collect group ids whose AND path is satisfied by `record`.
    /// Caller owns the list and must deinit it. Residual OR checks are the caller's responsibility.
    pub fn collectMatches(
        self: *const PredicateTrie,
        record: *const Record,
        out: *std.ArrayListUnmanaged(u64),
        out_allocator: Allocator,
    ) !void {
        try collectFromNode(&self.root, record, out, out_allocator);
    }

    fn getOrCreateChild(self: *PredicateTrie, parent: *Node, step: Condition) !*Node {
        if (step.op == .eq) {
            const value = step.value orelse return error.MissingConditionValue;
            const field_gop = try parent.eq_branches.getOrPut(self.allocator, step.field_index);
            if (!field_gop.found_existing) {
                field_gop.value_ptr.* = ValueMap.empty;
            }
            var value_map = field_gop.value_ptr;

            if (value_map.get(value)) |existing| return existing;

            const child = try self.allocator.create(Node);
            child.* = .{};
            errdefer {
                child.deinit(self.allocator);
                self.allocator.destroy(child);
            }

            const owned_value = try value.clone(self.allocator);
            errdefer owned_value.deinit(self.allocator);

            try value_map.put(self.allocator, owned_value, child);
            return child;
        }

        if (parent.cond_branches.get(step)) |existing| return existing;

        const child = try self.allocator.create(Node);
        child.* = .{};
        errdefer {
            child.deinit(self.allocator);
            self.allocator.destroy(child);
        }

        const owned_cond = try step.clone(self.allocator);
        errdefer {
            var c = owned_cond;
            c.deinit(self.allocator);
        }

        try parent.cond_branches.put(self.allocator, owned_cond, child);
        return child;
    }
};

fn buildPath(
    allocator: Allocator,
    predicate: *const FilterPredicate,
    out: *std.ArrayListUnmanaged(Condition),
) !void {
    out.clearRetainingCapacity();
    const conds = predicate.conditions orelse return;
    try out.appendSlice(allocator, conds);
    std.mem.sort(Condition, out.items, {}, pathConditionLessThan);
}

fn removeAlongPath(
    allocator: Allocator,
    node: *Node,
    path: []const Condition,
    index: usize,
    group_id: u64,
) bool {
    if (index == path.len) {
        _ = node.leaf_groups.remove(group_id);
        return node.isEmpty();
    }

    const step = path[index];
    if (step.op == .eq) {
        const value = step.value orelse return node.isEmpty();
        const value_map_ptr = node.eq_branches.getPtr(step.field_index) orelse return node.isEmpty();
        const child = value_map_ptr.get(value) orelse return node.isEmpty();

        const child_empty = removeAlongPath(allocator, child, path, index + 1, group_id);
        if (child_empty) {
            if (value_map_ptr.fetchRemove(value)) |kv| {
                var key = kv.key;
                key.deinit(allocator);
                child.deinit(allocator);
                allocator.destroy(child);
            }
            if (value_map_ptr.count() == 0) {
                value_map_ptr.deinit(allocator);
                _ = node.eq_branches.remove(step.field_index);
            }
        }
        return node.isEmpty();
    }

    const child = node.cond_branches.get(step) orelse return node.isEmpty();
    const child_empty = removeAlongPath(allocator, child, path, index + 1, group_id);
    if (child_empty) {
        if (node.cond_branches.fetchRemove(step)) |kv| {
            var key = kv.key;
            key.deinit(allocator);
            child.deinit(allocator);
            allocator.destroy(child);
        }
    }
    return node.isEmpty();
}

/// Fallback for removeGroup when buildPath OOMs: walk the entire trie,
/// remove group_id from every leaf, and prune empty subtrees bottom-up.
/// Allocation-free — split into two passes so no temporary buffers are needed.
fn removeGroupBySearch(allocator: Allocator, node: *Node, group_id: u64) bool {
    removeFromLeaves(node, group_id);
    return pruneEmptyChildren(allocator, node);
}

/// Pass 1: remove group_id from every leaf_groups in the trie.
fn removeFromLeaves(node: *Node, group_id: u64) void {
    _ = node.leaf_groups.remove(group_id);

    var eq_it = node.eq_branches.iterator();
    while (eq_it.next()) |field_entry| {
        var val_it = field_entry.value_ptr.iterator();
        while (val_it.next()) |val_entry| {
            removeFromLeaves(val_entry.value_ptr.*, group_id);
        }
    }

    var cond_it = node.cond_branches.iterator();
    while (cond_it.next()) |entry| {
        removeFromLeaves(entry.value_ptr.*, group_id);
    }
}

/// Pass 2: prune empty children bottom-up. Returns true if `node` is empty after pruning.
fn pruneEmptyChildren(allocator: Allocator, node: *Node) bool {
    var fields_to_prune: [16]usize = undefined;
    var fields_count: usize = 0;

    var eq_it = node.eq_branches.iterator();
    while (eq_it.next()) |field_entry| {
        var value_map_ptr = field_entry.value_ptr;
        var values_to_prune: [16]Value = undefined;
        var values_count: usize = 0;

        var val_it = value_map_ptr.iterator();
        while (val_it.next()) |val_entry| {
            if (pruneEmptyChildren(allocator, val_entry.value_ptr.*)) {
                if (values_count < values_to_prune.len) {
                    values_to_prune[values_count] = val_entry.key_ptr.*;
                    values_count += 1;
                }
            }
        }
        for (0..values_count) |i| {
            if (value_map_ptr.fetchRemove(values_to_prune[i])) |kv| {
                var k = kv.key;
                k.deinit(allocator);
                kv.value.deinit(allocator);
                allocator.destroy(kv.value);
            }
        }
        if (value_map_ptr.count() == 0) {
            if (fields_count < fields_to_prune.len) {
                fields_to_prune[fields_count] = field_entry.key_ptr.*;
                fields_count += 1;
            }
        }
    }
    for (0..fields_count) |i| {
        if (node.eq_branches.fetchRemove(fields_to_prune[i])) |kv| {
            var map = kv.value;
            map.deinit(allocator);
        }
    }

    var conds_to_prune: [16]Condition = undefined;
    var conds_count: usize = 0;

    var cond_it = node.cond_branches.iterator();
    while (cond_it.next()) |entry| {
        if (pruneEmptyChildren(allocator, entry.value_ptr.*)) {
            if (conds_count < conds_to_prune.len) {
                conds_to_prune[conds_count] = entry.key_ptr.*;
                conds_count += 1;
            }
        }
    }
    for (0..conds_count) |i| {
        if (node.cond_branches.fetchRemove(conds_to_prune[i])) |kv| {
            var k = kv.key;
            k.deinit(allocator);
            kv.value.deinit(allocator);
            allocator.destroy(kv.value);
        }
    }

    return node.isEmpty();
}

fn collectFromNode(
    node: *const Node,
    record: *const Record,
    out: *std.ArrayListUnmanaged(u64),
    allocator: Allocator,
) !void {
    var leaf_it = node.leaf_groups.keyIterator();
    while (leaf_it.next()) |gid| {
        try out.append(allocator, gid.*);
    }

    var eq_it = node.eq_branches.iterator();
    while (eq_it.next()) |field_entry| {
        const field_index = field_entry.key_ptr.*;
        if (field_index >= record.values.len) continue;
        const val = record.values[field_index];
        if (field_entry.value_ptr.get(val)) |child| {
            try collectFromNode(child, record, out, allocator);
        }
    }

    var cond_it = node.cond_branches.iterator();
    while (cond_it.next()) |cond_entry| {
        if (try query_eval.evaluateCondition(cond_entry.key_ptr, record)) {
            try collectFromNode(cond_entry.value_ptr.*, record, out, allocator);
        }
    }
}

/// True when AND path is already proven and residual OR (if any) also passes.
pub fn residualMatches(predicate: *const FilterPredicate, record: *const Record) !bool {
    switch (predicate.state) {
        .match_all => return true,
        .match_none => return false,
        .conditional => {},
    }
    // AND already satisfied by the trie walk; only OR residuals remain.
    if (predicate.or_clauses) |clauses| {
        for (clauses) |clause| {
            if (clause.len == 0) continue;
            var clause_matched = false;
            for (clause) |condition| {
                if (try query_eval.evaluateCondition(&condition, record)) {
                    clause_matched = true;
                    break;
                }
            }
            if (!clause_matched) return false;
        }
    }
    return true;
}
