const std = @import("std");

const tth = @import("../typed/test_helpers.zig");
const typed = @import("../typed/types.zig");
const query_ast = @import("ast.zig");
const query_eval = @import("eval.zig");
const qth = @import("test_helpers.zig");

test "evaluatePredicate respects explicit predicate states" {
    const allocator = std.testing.allocator;

    var record = try tth.recordFromValues(allocator, &.{});
    defer record.deinit(allocator);

    var match_all = query_ast.FilterPredicate{ .state = .match_all };
    var match_none = query_ast.FilterPredicate{ .state = .match_none };
    try std.testing.expect(try qth.evaluatePredicate(&match_all, &record));
    try std.testing.expect(!try qth.evaluatePredicate(&match_none, &record));
}

test "evaluatePredicate keeps conditional AND plus OR semantics" {
    const allocator = std.testing.allocator;

    var conds = try allocator.alloc(query_ast.Condition, 1);
    conds[0] = .{
        .field_index = 3,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "high"),
        .field_type = .text,
        .items_type = null,
    };

    var or_conds = try allocator.alloc(query_ast.Condition, 1);
    or_conds[0] = .{
        .field_index = 4,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "active"),
        .field_type = .text,
        .items_type = null,
    };

    var clause_slice = try allocator.alloc(query_ast.OrClause, 1);
    clause_slice[0] = or_conds;

    var predicate = query_ast.FilterPredicate{
        .conditions = conds,
        .or_clauses = clause_slice,
    };
    defer predicate.deinit(allocator);

    var matching = try tth.recordFromValues(allocator, &.{ tth.valText("high"), tth.valText("active") });
    defer matching.deinit(allocator);
    try std.testing.expect(try qth.evaluatePredicate(&predicate, &matching));

    var wrong_or = try tth.recordFromValues(allocator, &.{ tth.valText("high"), tth.valText("closed") });
    defer wrong_or.deinit(allocator);
    try std.testing.expect(!try qth.evaluatePredicate(&predicate, &wrong_or));
}

test "evaluateCondition: a NULL field fails every binary operator, as in SQL" {
    const allocator = std.testing.allocator;
    var record = try tth.recordFromValues(allocator, &.{.nil});
    defer record.deinit(allocator);

    var members = [_]typed.ScalarValue{.{ .integer = 10 }};
    for (std.enums.values(query_ast.Operator)) |op| {
        const operand: ?typed.Value = switch (op) {
            .isNull, .isNotNull => null,
            .in, .notIn => .{ .array = &members },
            .startsWith, .endsWith, .contains => tth.valText("a"),
            else => tth.valInt(10),
        };
        const cond = query_ast.Condition{ .field_index = 3, .op = op, .value = operand, .field_type = .integer, .items_type = null };
        try std.testing.expectEqual(op == .isNull, try query_eval.evaluateCondition(&cond, &record));
    }
}
