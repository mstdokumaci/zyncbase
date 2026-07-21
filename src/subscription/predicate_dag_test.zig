const std = @import("std");
const query_ast = @import("../query/ast.zig");
const predicate_dag = @import("predicate_dag.zig");
const tth = @import("../typed/test_helpers.zig");
const qth = @import("../query/test_helpers.zig");

const testing = std.testing;
const Condition = query_ast.Condition;
const PredicateDag = predicate_dag.PredicateDag;

test "PredicateDag: shared equality prefix and GC" {
    const allocator = testing.allocator;
    var dag = PredicateDag.init(allocator);
    defer dag.deinit();

    var filter_a = try qth.makeFilterWithConditions(allocator, &[_]Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
        .{ .field_index = 4, .op = .eq, .value = tth.valInt(1), .field_type = .integer, .items_type = null },
    });
    defer filter_a.deinit(allocator);

    var filter_b = try qth.makeFilterWithConditions(allocator, &[_]Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
        .{ .field_index = 4, .op = .eq, .value = tth.valInt(2), .field_type = .integer, .items_type = null },
    });
    defer filter_b.deinit(allocator);

    var filter_c = try qth.makeFilterWithConditions(allocator, &[_]Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
        .{ .field_index = 5, .op = .eq, .value = tth.valInt(7), .field_type = .integer, .items_type = null },
    });
    defer filter_c.deinit(allocator);

    try testing.expect(try dag.insertGroup(1, &filter_a));
    try testing.expect(try dag.insertGroup(2, &filter_b));
    try testing.expect(try dag.insertGroup(3, &filter_c));

    // Shared eq(status)=active node: single field branch under root.
    try testing.expectEqual(@as(u32, 1), dag.root.eq_branches.count());

    var rec_a = try tth.recordFromValues(allocator, &.{
        tth.valText("active"),
        tth.valInt(1),
        tth.valInt(0),
    });
    defer rec_a.deinit(allocator);

    var matches: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer matches.deinit(allocator);
    try dag.collectMatches(&rec_a, &matches, allocator);
    try testing.expect(matches.contains(1));
    try testing.expect(!matches.contains(2));
    try testing.expect(!matches.contains(3));

    var rec_active_other = try tth.recordFromValues(allocator, &.{
        tth.valText("active"),
        tth.valInt(2),
        tth.valInt(7),
    });
    defer rec_active_other.deinit(allocator);
    matches.clearRetainingCapacity();
    try dag.collectMatches(&rec_active_other, &matches, allocator);
    try testing.expect(!matches.contains(1));
    try testing.expect(matches.contains(2));
    try testing.expect(matches.contains(3));

    dag.removeGroup(1, &filter_a);
    dag.removeGroup(2, &filter_b);
    // Shared status=active node remains while C is live.
    try testing.expectEqual(@as(u32, 1), dag.root.eq_branches.count());

    dag.removeGroup(3, &filter_c);
    try testing.expect(dag.isEmpty());
}

test "PredicateDag: match_all and match_none" {
    const allocator = testing.allocator;
    var dag = PredicateDag.init(allocator);
    defer dag.deinit();

    var filter_all = try qth.makeDefaultFilter(allocator);
    defer filter_all.deinit(allocator);
    filter_all.predicate.state = .match_all;

    var filter_none = try qth.makeDefaultFilter(allocator);
    defer filter_none.deinit(allocator);
    filter_none.predicate.state = .match_none;

    try testing.expect(try dag.insertGroup(10, &filter_all));
    try testing.expect(!try dag.insertGroup(11, &filter_none));

    var rec = try tth.recordFromValues(allocator, &.{tth.valText("x")});
    defer rec.deinit(allocator);

    var matches: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer matches.deinit(allocator);
    try dag.collectMatches(&rec, &matches, allocator);
    try testing.expect(matches.contains(10));
    try testing.expect(!matches.contains(11));

    dag.removeGroup(10, &filter_all);
    dag.removeGroup(11, &filter_none);
    try testing.expect(dag.isEmpty());
}

test "PredicateDag: non-eq condition branch" {
    const allocator = testing.allocator;
    var dag = PredicateDag.init(allocator);
    defer dag.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]Condition{
        .{ .field_index = 3, .op = .gte, .value = tth.valInt(5), .field_type = .integer, .items_type = null },
    });
    defer filter.deinit(allocator);

    try testing.expect(try dag.insertGroup(1, &filter));

    var high = try tth.recordFromValues(allocator, &.{tth.valInt(8)});
    defer high.deinit(allocator);
    var low = try tth.recordFromValues(allocator, &.{tth.valInt(2)});
    defer low.deinit(allocator);

    var matches: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer matches.deinit(allocator);
    try dag.collectMatches(&high, &matches, allocator);
    try testing.expect(matches.contains(1));

    matches.clearRetainingCapacity();
    try dag.collectMatches(&low, &matches, allocator);
    try testing.expect(!matches.contains(1));

    dag.removeGroup(1, &filter);
    try testing.expect(dag.isEmpty());
}

test "PredicateDag: eq then non-eq path order" {
    const allocator = testing.allocator;
    var dag = PredicateDag.init(allocator);
    defer dag.deinit();

    // status eq (tier 0) before age gte (tier 1), regardless of field_index order input.
    var filter = try qth.makeFilterWithConditions(allocator, &[_]Condition{
        .{ .field_index = 4, .op = .gte, .value = tth.valInt(18), .field_type = .integer, .items_type = null },
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try dag.insertGroup(1, &filter);
    try testing.expect(dag.root.eq_branches.contains(3));
    try testing.expectEqual(@as(u32, 0), dag.root.cond_branches.count());

    var ok = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(20) });
    defer ok.deinit(allocator);
    var bad_status = try tth.recordFromValues(allocator, &.{ tth.valText("draft"), tth.valInt(20) });
    defer bad_status.deinit(allocator);
    var bad_age = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(10) });
    defer bad_age.deinit(allocator);

    var matches: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer matches.deinit(allocator);
    try dag.collectMatches(&ok, &matches, allocator);
    try testing.expect(matches.contains(1));
    matches.clearRetainingCapacity();
    try dag.collectMatches(&bad_status, &matches, allocator);
    try testing.expect(!matches.contains(1));
    matches.clearRetainingCapacity();
    try dag.collectMatches(&bad_age, &matches, allocator);
    try testing.expect(!matches.contains(1));
}

test "PredicateDag: OR clause residual filtering" {
    const allocator = testing.allocator;
    var dag = PredicateDag.init(allocator);
    defer dag.deinit();

    // Filter: status=active AND (owner=1 OR owner=2)
    var filter = try qth.makeFilterWithOrClauses(allocator, &[_]Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    }, &[_][]const Condition{
        &[_]Condition{
            .{ .field_index = 4, .op = .eq, .value = tth.valInt(1), .field_type = .integer, .items_type = null },
            .{ .field_index = 4, .op = .eq, .value = tth.valInt(2), .field_type = .integer, .items_type = null },
        },
    });
    defer filter.deinit(allocator);

    try testing.expect(try dag.insertGroup(1, &filter));

    // status=active, owner=1 → AND path matches, OR clause passes
    var rec_match = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(1), tth.valInt(0) });
    defer rec_match.deinit(allocator);
    var matches: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer matches.deinit(allocator);
    try dag.collectMatches(&rec_match, &matches, allocator);
    try testing.expect(matches.contains(1));
    try testing.expect(try predicate_dag.residualMatches(&filter.predicate, &rec_match));

    // status=active, owner=3 → AND path matches, OR clause fails
    var rec_or_fail = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(3), tth.valInt(0) });
    defer rec_or_fail.deinit(allocator);
    matches.clearRetainingCapacity();
    try dag.collectMatches(&rec_or_fail, &matches, allocator);
    try testing.expect(matches.contains(1)); // AND path still matches
    try testing.expect(!try predicate_dag.residualMatches(&filter.predicate, &rec_or_fail)); // OR fails

    // status=draft, owner=1 → AND path fails (trie never reaches leaf)
    var rec_and_fail = try tth.recordFromValues(allocator, &.{ tth.valText("draft"), tth.valInt(1), tth.valInt(0) });
    defer rec_and_fail.deinit(allocator);
    matches.clearRetainingCapacity();
    try dag.collectMatches(&rec_and_fail, &matches, allocator);
    try testing.expect(!matches.contains(1));

    dag.removeGroup(1, &filter);
    try testing.expect(dag.isEmpty());
}
