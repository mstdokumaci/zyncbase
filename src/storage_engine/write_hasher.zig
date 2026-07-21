const std = @import("std");
const query_ast = @import("../query/ast.zig");
const query_hasher = @import("../query/hasher.zig");
const sql = @import("sql.zig");

const FilterPredicate = query_ast.FilterPredicate;
const ColumnValue = sql.ColumnValue;

/// Computes a structural hash for an upsert SQL template.
/// Covers: table, is_users_table, column indices, guard predicate structure.
/// The hash identifies the SQL template; param_count (derived from the same
/// structure) provides collision safety in the stmt cache.
pub fn computeUpsertHash(
    table_index: usize,
    is_users_table: bool,
    columns: []const ColumnValue,
    guard: ?*const FilterPredicate,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, table_index);
    std.hash.autoHash(&hasher, is_users_table);
    std.hash.autoHash(&hasher, columns.len);
    for (columns) |col| {
        std.hash.autoHash(&hasher, col.index);
    }
    std.hash.autoHash(&hasher, guard != null);
    if (guard) |g| {
        query_hasher.hashPredicateStructure(&hasher, g);
    }
    return hasher.final();
}

/// Computes the bind parameter count for an upsert SQL template.
/// Mirrors the placeholder layout in `buildUpsertDocumentSql`:
///   id, namespace_id, owner_id [, external_id] , <columns>, created_at, updated_at [, guard...]
pub fn computeUpsertParamCount(
    is_users_table: bool,
    columns_len: usize,
    guard: ?*const FilterPredicate,
) c_int {
    var count: c_int = 3; // id, namespace_id, owner_id
    if (is_users_table) count += 1; // external_id
    count += @intCast(columns_len);
    count += 2; // created_at, updated_at
    if (guard) |g| {
        count += @intCast(predicateParamCount(g));
    }
    return count;
}

/// Computes a structural hash for an update SQL template.
/// Covers: table, column indices, guard predicate structure.
pub fn computeUpdateHash(
    table_index: usize,
    columns: []const ColumnValue,
    guard: ?*const FilterPredicate,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, table_index);
    std.hash.autoHash(&hasher, columns.len);
    for (columns) |col| {
        std.hash.autoHash(&hasher, col.index);
    }
    std.hash.autoHash(&hasher, guard != null);
    if (guard) |g| {
        query_hasher.hashPredicateStructure(&hasher, g);
    }
    return hasher.final();
}

/// Computes the bind parameter count for an update SQL template.
/// Mirrors the placeholder layout in `buildUpdateDocumentSql`:
///   <columns>, updated_at, id, namespace_id [, guard...]
pub fn computeUpdateParamCount(
    columns_len: usize,
    guard: ?*const FilterPredicate,
) c_int {
    var count: c_int = @intCast(columns_len);
    count += 1; // updated_at
    count += 2; // id, namespace_id
    if (guard) |g| {
        count += @intCast(predicateParamCount(g));
    }
    return count;
}

/// Computes a structural hash for a delete SQL template.
/// Covers: table, guard predicate structure.
pub fn computeDeleteHash(
    table_index: usize,
    guard: ?*const FilterPredicate,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, table_index);
    std.hash.autoHash(&hasher, guard != null);
    if (guard) |g| {
        query_hasher.hashPredicateStructure(&hasher, g);
    }
    return hasher.final();
}

/// Computes the bind parameter count for a delete SQL template.
/// Mirrors the placeholder layout: id, namespace_id [, guard...]
pub fn computeDeleteParamCount(guard: ?*const FilterPredicate) c_int {
    var count: c_int = 2; // id, namespace_id
    if (guard) |g| {
        count += @intCast(predicateParamCount(g));
    }
    return count;
}

/// Counts the bind parameters a FilterPredicate will produce when rendered.
/// Must match `filter_sql.appendFilterPredicateSql` / `appendFilterValues`.
fn predicateParamCount(pred: *const FilterPredicate) usize {
    if (pred.isAlwaysTrue() or pred.isAlwaysFalse()) return 0;

    var count: usize = 0;
    const conds = pred.conditions orelse @as([]const query_ast.Condition, &.{});
    for (conds) |*cond| {
        count += conditionParamCount(cond);
    }

    const clauses = pred.or_clauses orelse @as([]const query_ast.OrClause, &.{});
    for (clauses) |clause| {
        for (clause) |*cond| {
            count += conditionParamCount(cond);
        }
    }
    return count;
}

fn conditionParamCount(cond: *const query_ast.Condition) usize {
    return switch (cond.op) {
        .eq, .ne, .gt, .lt, .gte, .lte => 1,
        .contains => blk: {
            if (cond.field_type == .array) break :blk 1;
            break :blk 1; // escaped like pattern
        },
        .startsWith, .endsWith => 1,
        .in, .notIn => blk: {
            if (cond.value) |val| {
                if (val == .array) break :blk val.array.len;
                break :blk 1;
            }
            break :blk 0;
        },
        .isNull, .isNotNull => 0,
    };
}
