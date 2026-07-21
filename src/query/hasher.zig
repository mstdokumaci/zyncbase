const std = @import("std");
const query_ast = @import("ast.zig");

const QueryFilter = query_ast.QueryFilter;
const Condition = query_ast.Condition;
const OrClause = query_ast.OrClause;
const FilterPredicate = query_ast.FilterPredicate;

/// Computes a u64 structural hash of a QueryFilter.
/// The hash identifies the SQL template — it includes all structural
/// elements that affect the generated SQL string, but excludes literal
/// values (which are bound as ? parameters at execution time).
pub fn computeStructuralHash(filter: *const QueryFilter) u64 {
    var hasher = std.hash.Wyhash.init(0);

    // 1. Predicate state
    std.hash.autoHash(&hasher, filter.predicate.state);

    // 2. AND conditions (structural parts only)
    const conds = filter.predicate.conditions orelse @as([]const Condition, &.{});
    std.hash.autoHash(&hasher, conds.len);
    for (conds) |c| {
        hashConditionStructure(&hasher, c);
    }

    // 3. OR clauses (structural parts only)
    const clauses = filter.predicate.or_clauses orelse @as([]const OrClause, &.{});
    std.hash.autoHash(&hasher, clauses.len);
    for (clauses) |clause| {
        std.hash.autoHash(&hasher, clause.len);
        for (clause) |c| {
            hashConditionStructure(&hasher, c);
        }
    }

    // 4. Order by
    std.hash.autoHash(&hasher, filter.order_by.field_index);
    std.hash.autoHash(&hasher, filter.order_by.desc);
    std.hash.autoHash(&hasher, filter.order_by.field_type);
    std.hash.autoHash(&hasher, filter.order_by.items_type);

    // 5. Limit presence (not value)
    const has_limit = filter.limit != null;
    std.hash.autoHash(&hasher, has_limit);

    // 6. After presence (not values)
    const has_after = filter.after != null;
    std.hash.autoHash(&hasher, has_after);

    return hasher.final();
}

/// Hashes the structure of a single condition (field, op, types, in-array length).
pub fn hashConditionStructure(hasher: *std.hash.Wyhash, c: Condition) void {
    std.hash.autoHash(hasher, c.field_index);
    std.hash.autoHash(hasher, c.op);
    std.hash.autoHash(hasher, c.field_type);
    std.hash.autoHash(hasher, c.items_type);

    // Array length for in/notIn — determines number of ? placeholders
    if (c.op == .in or c.op == .notIn) {
        if (c.value) |v| {
            if (v == .array) {
                std.hash.autoHash(hasher, v.array.len);
            }
        }
    }
}

/// Hashes the full structure of a FilterPredicate (conditions + or_clauses + state).
/// Used by the write path to compute a cache key for guarded writes.
pub fn hashPredicateStructure(hasher: *std.hash.Wyhash, pred: *const FilterPredicate) void {
    std.hash.autoHash(hasher, pred.state);

    const conds = pred.conditions orelse @as([]const Condition, &.{});
    std.hash.autoHash(hasher, conds.len);
    for (conds) |c| {
        hashConditionStructure(hasher, c);
    }

    const clauses = pred.or_clauses orelse @as([]const OrClause, &.{});
    std.hash.autoHash(hasher, clauses.len);
    for (clauses) |clause| {
        std.hash.autoHash(hasher, clause.len);
        for (clause) |c| {
            hashConditionStructure(hasher, c);
        }
    }
}
