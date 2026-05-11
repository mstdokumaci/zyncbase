const std = @import("std");
const filter_eval = @import("filter_eval.zig");
const query_ast = @import("query_ast.zig");
const tth = @import("typed_test_helpers.zig");

test "evaluatePredicate respects explicit predicate states" {
    const allocator = std.testing.allocator;

    var record = try tth.recordFromValues(allocator, &.{});
    defer record.deinit(allocator);

    var match_all = query_ast.FilterPredicate{ .state = .match_all };
    var match_none = query_ast.FilterPredicate{ .state = .match_none };
    try std.testing.expect(try filter_eval.evaluatePredicate(&match_all, &record));
    try std.testing.expect(!try filter_eval.evaluatePredicate(&match_none, &record));
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

    var predicate = query_ast.FilterPredicate{
        .conditions = conds,
        .or_conditions = or_conds,
    };
    defer predicate.deinit(allocator);

    var matching = try tth.recordFromValues(allocator, &.{ tth.valText("high"), tth.valText("active") });
    defer matching.deinit(allocator);
    try std.testing.expect(try filter_eval.evaluatePredicate(&predicate, &matching));

    var wrong_or = try tth.recordFromValues(allocator, &.{ tth.valText("high"), tth.valText("closed") });
    defer wrong_or.deinit(allocator);
    try std.testing.expect(!try filter_eval.evaluatePredicate(&predicate, &wrong_or));
}
