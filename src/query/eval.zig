const query_ast = @import("ast.zig");
const typed = @import("../typed/types.zig");

const Condition = query_ast.Condition;
const FilterPredicate = query_ast.FilterPredicate;
const Record = typed.Record;

pub fn evaluatePredicate(predicate: *const FilterPredicate, record: *const Record) !bool {
    switch (predicate.state) {
        .match_all => return true,
        .match_none => return false,
        .conditional => {},
    }

    if (predicate.conditions) |conds| {
        for (conds) |condition| {
            if (!try evaluateCondition(&condition, record)) return false;
        }
    }

    if (predicate.or_clauses) |clauses| {
        for (clauses) |clause| {
            if (clause.len == 0) continue;
            var clause_matched = false;
            for (clause) |condition| {
                if (try evaluateCondition(&condition, record)) {
                    clause_matched = true;
                    break;
                }
            }
            if (!clause_matched) return false;
        }
    }

    return true;
}

pub fn evaluateCondition(cond: *const Condition, record: *const Record) !bool {
    if (cond.field_index >= record.values.len) return cond.op == .isNull;
    const val = record.values[cond.field_index];
    if (cond.op.isNullary()) return cond.op.compareNullary(val);
    return cond.op.compare(val, cond.value orelse return error.MissingConditionValue);
}
