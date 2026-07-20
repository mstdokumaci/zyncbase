const std = @import("std");
const schema_types = @import("../schema/types.zig");
const query_ast = @import("ast.zig");
const typed = @import("../typed/types.zig");
const tth = @import("../typed/test_helpers.zig");

const Operator = query_ast.Operator;
const ValueShape = query_ast.ValueShape;
const Value = typed.Value;

test "operatorExpectsValueShape op x field-type matrix" {
    // Every (op, field_type) combination resolves to a single expected shape,
    // or to UnsupportedOperatorForFieldType. This is the authoritative matrix
    // that both the query parser and the authorization validator derive from,
    // so a regression here means parse/validate can diverge again.

    const scalar_types = [_]schema_types.FieldType{ .text, .integer, .real, .boolean, .doc_id };

    for (scalar_types) |ft| {
        try expectShape(Operator.eq, ft, .scalar);
        try expectShape(Operator.ne, ft, .scalar);
        try expectShape(Operator.gt, ft, .scalar);
        try expectShape(Operator.gte, ft, .scalar);
        try expectShape(Operator.lt, ft, .scalar);
        try expectShape(Operator.lte, ft, .scalar);
        try expectShape(Operator.in, ft, .array_membership);
        try expectShape(Operator.notIn, ft, .array_membership);

        // startsWith / endsWith only on text scalars
        if (ft == .text) {
            try expectShape(Operator.startsWith, ft, .scalar_text);
            try expectShape(Operator.endsWith, ft, .scalar_text);
        } else {
            try expectUnsupported(Operator.startsWith, ft);
            try expectUnsupported(Operator.endsWith, ft);
        }

        // contains only on text scalars
        if (ft == .text) {
            try expectShape(Operator.contains, ft, .contains_text);
        } else {
            try expectUnsupported(Operator.contains, ft);
        }
    }

    // Array fields: eq/ne expect an array of element scalars; comparison,
    // membership, and contains-on-array are unsupported.
    const array_ft: schema_types.FieldType = .array;
    try expectShape(Operator.eq, array_ft, .array_field);
    try expectShape(Operator.ne, array_ft, .array_field);
    try expectUnsupported(Operator.gt, array_ft);
    try expectUnsupported(Operator.gte, array_ft);
    try expectUnsupported(Operator.lt, array_ft);
    try expectUnsupported(Operator.lte, array_ft);
    try expectUnsupported(Operator.in, array_ft);
    try expectUnsupported(Operator.notIn, array_ft);
    try expectUnsupported(Operator.startsWith, array_ft);
    try expectUnsupported(Operator.endsWith, array_ft);
    try expectShape(Operator.contains, array_ft, .contains_element);

    // Nullary operators take no operand for any field type.
    for (scalar_types) |ft| {
        try expectShape(Operator.isNull, ft, .nullary);
        try expectShape(Operator.isNotNull, ft, .nullary);
    }
    try expectShape(Operator.isNull, array_ft, .nullary);
    try expectShape(Operator.isNotNull, array_ft, .nullary);
}

fn expectShape(op: Operator, field_type: schema_types.FieldType, expected: ValueShape) !void {
    const actual = try query_ast.operatorExpectsValueShape(op, field_type);
    try std.testing.expectEqual(expected, actual);
}

fn expectUnsupported(op: Operator, field_type: schema_types.FieldType) !void {
    const result = query_ast.operatorExpectsValueShape(op, field_type);
    try std.testing.expectError(error.UnsupportedOperatorForFieldType, result);
}

test "Operator.compare semantics" {
    const allocator = std.testing.allocator;

    const txt_a = tth.valText("a");
    const txt_b = tth.valText("b");
    const txt_world = tth.valText("World");
    const txt_hello = tth.valText("hello");
    const txt_long = tth.valText("Hello World");
    const int_3 = tth.valInt(3);
    const int_5a = tth.valInt(5);
    const int_5b = tth.valInt(5);

    const arr_abc = try tth.valArray(allocator, &[_]typed.ScalarValue{
        .{ .text = "a" }, .{ .text = "b" }, .{ .text = "c" },
    });
    defer arr_abc.deinit(allocator);
    const arr_empty = try tth.valArray(allocator, &[_]typed.ScalarValue{});
    defer arr_empty.deinit(allocator);

    // eq / ne
    try std.testing.expect(cmp(.eq, txt_a, txt_a));
    try std.testing.expect(!cmp(.eq, txt_a, txt_b));
    try std.testing.expect(cmp(.ne, txt_a, txt_b));
    try std.testing.expect(!cmp(.ne, txt_a, txt_a));
    // mismatched shapes compare to false, never error
    try std.testing.expect(!cmp(.eq, txt_a, int_3));

    // ordering boundaries (equal values are not strictly greater/less)
    try std.testing.expect(cmp(.gt, int_5a, int_3));
    try std.testing.expect(!cmp(.gt, int_3, int_5a));
    try std.testing.expect(!cmp(.gt, int_5a, int_5b));
    try std.testing.expect(cmp(.gte, int_5a, int_5b));
    try std.testing.expect(cmp(.lt, int_3, int_5a));
    try std.testing.expect(!cmp(.lt, int_5a, int_5b));
    try std.testing.expect(cmp(.lte, int_5a, int_5b));

    // startsWith / endsWith are case-insensitive but length-sensitive
    try std.testing.expect(cmp(.startsWith, txt_long, txt_hello));
    try std.testing.expect(!cmp(.startsWith, txt_hello, txt_long));
    try std.testing.expect(cmp(.endsWith, txt_long, txt_world));
    try std.testing.expect(!cmp(.endsWith, txt_world, txt_long));

    // membership: in / notIn over an array RHS
    try std.testing.expect(cmp(.in, txt_b, arr_abc));
    try std.testing.expect(!cmp(.in, txt_a, arr_empty));
    try std.testing.expect(cmp(.notIn, txt_a, arr_empty));
    try std.testing.expect(!cmp(.notIn, txt_b, arr_abc));

    // contains: array field (element membership) and text field (substring)
    try std.testing.expect(cmp(.contains, arr_abc, txt_a));
    try std.testing.expect(!cmp(.contains, arr_abc, tth.valText("z")));
    try std.testing.expect(cmp(.contains, txt_long, tth.valText("world")));
    try std.testing.expect(!cmp(.contains, txt_long, tth.valText("xyz")));
}

test "Operator.compareNullary semantics" {
    const nil_val = tth.valNil();
    const txt = tth.valText("x");

    try std.testing.expect(Operator.isNull.compareNullary(nil_val));
    try std.testing.expect(!Operator.isNull.compareNullary(txt));
    try std.testing.expect(!Operator.isNotNull.compareNullary(nil_val));
    try std.testing.expect(Operator.isNotNull.compareNullary(txt));
}

test "FilterPredicate.normalize collapses in/notIn empty sets" {
    const allocator = std.testing.allocator;

    const empty = try tth.valArray(allocator, &[_]typed.ScalarValue{});
    defer empty.deinit(allocator);

    // `in` with an empty array is trivially false -> whole AND predicate is match_none.
    {
        var conds = try allocator.alloc(query_ast.Condition, 1);
        conds[0] = cond(allocator, .in, try empty.clone(allocator));
        var p = query_ast.FilterPredicate{ .conditions = conds };
        defer p.deinit(allocator);
        try std.testing.expectEqual(query_ast.PredicateState.match_none, try p.normalize(allocator));
        try std.testing.expect(p.conditions == null);
    }

    // `notIn` with an empty array is trivially true -> term dropped; lone term -> match_all.
    {
        var conds = try allocator.alloc(query_ast.Condition, 1);
        conds[0] = cond(allocator, .notIn, try empty.clone(allocator));
        var p = query_ast.FilterPredicate{ .conditions = conds };
        defer p.deinit(allocator);
        try std.testing.expectEqual(query_ast.PredicateState.match_all, try p.normalize(allocator));
        try std.testing.expect(p.conditions == null);
    }

    // `notIn` empty in or_clauses is a tautology -> dropped, AND conditions kept (conditional).
    {
        var and_conds = try allocator.alloc(query_ast.Condition, 1);
        and_conds[0] = condText(allocator, .eq, "x");
        var or_conds = try allocator.alloc(query_ast.Condition, 1);
        or_conds[0] = cond(allocator, .notIn, try empty.clone(allocator));
        var clause_slice = try allocator.alloc(query_ast.OrClause, 1);
        clause_slice[0] = or_conds;
        var p = query_ast.FilterPredicate{ .conditions = and_conds, .or_clauses = clause_slice };
        defer p.deinit(allocator);
        try std.testing.expectEqual(query_ast.PredicateState.conditional, try p.normalize(allocator));
        try std.testing.expect(p.or_clauses == null);
        try std.testing.expect(p.conditions != null);
    }

    // `in` empty in or_clauses -> all OR terms false -> match_none.
    {
        var or_conds = try allocator.alloc(query_ast.Condition, 1);
        or_conds[0] = cond(allocator, .in, try empty.clone(allocator));
        var clause_slice = try allocator.alloc(query_ast.OrClause, 1);
        clause_slice[0] = or_conds;
        var p = query_ast.FilterPredicate{ .or_clauses = clause_slice };
        defer p.deinit(allocator);
        try std.testing.expectEqual(query_ast.PredicateState.match_none, try p.normalize(allocator));
        try std.testing.expect(p.or_clauses == null);
    }
}

fn cmp(op: Operator, lhs: Value, rhs: Value) bool {
    return op.compare(lhs, rhs);
}

fn cond(allocator: std.mem.Allocator, op: Operator, value: Value) query_ast.Condition {
    _ = allocator;
    return .{
        .field_index = 0,
        .op = op,
        .value = value,
        .field_type = .text,
        .items_type = null,
    };
}

fn condText(allocator: std.mem.Allocator, op: Operator, text: []const u8) query_ast.Condition {
    return cond(allocator, op, tth.valTextOwned(allocator, text) catch @panic("oom"));
}
