const typed = @import("../typed/types.zig");
const query_ast = @import("ast.zig");

const Record = typed.Record;
const Condition = query_ast.Condition;

pub fn evaluateCondition(cond: *const Condition, record: *const Record) !bool {
    if (cond.field_index >= record.values.len) return cond.op == .isNull;
    const val = record.values[cond.field_index];
    if (cond.op.isNullary()) return cond.op.compareNullary(val);
    return cond.op.compare(val, cond.value orelse return error.MissingConditionValue);
}
