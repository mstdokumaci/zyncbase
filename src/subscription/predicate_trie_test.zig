const std = @import("std");
const query_ast = @import("../query/ast.zig");
const predicate_trie = @import("predicate_trie.zig");
const tth = @import("../typed/test_helpers.zig");
const qth = @import("../query/test_helpers.zig");

const testing = std.testing;
const Condition = query_ast.Condition;
const PredicateTrie = predicate_trie.PredicateTrie;

fn listContains(list: *const std.ArrayListUnmanaged(u64), val: u64) bool {
    for (list.items) |item| {
        if (item == val) return true;
    }
    return false;
}

test "PredicateDag: shared equality prefix and GC" {
    const allocator = testing.allocator;
    var trie = PredicateTrie.init(allocator);
    defer trie.deinit();

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

    try testing.expect(try trie.insertGroup(1, &filter_a));
    try testing.expect(try trie.insertGroup(2, &filter_b));
    try testing.expect(try trie.insertGroup(3, &filter_c));

    // Shared eq(status)=active node: single field branch under root.
    try testing.expectEqual(@as(u32, 1), trie.root.eq_branches.count());

    var rec_a = try tth.recordFromValues(allocator, &.{
        tth.valText("active"),
        tth.valInt(1),
        tth.valInt(0),
    });
    defer rec_a.deinit(allocator);

    var matches: std.ArrayListUnmanaged(u64) = .empty;
    defer matches.deinit(allocator);
    try trie.collectMatches(&rec_a, &matches, allocator);
    try testing.expect(listContains(&matches, 1));
    try testing.expect(!listContains(&matches, 2));
    try testing.expect(!listContains(&matches, 3));

    var rec_active_other = try tth.recordFromValues(allocator, &.{
        tth.valText("active"),
        tth.valInt(2),
        tth.valInt(7),
    });
    defer rec_active_other.deinit(allocator);
    matches.clearRetainingCapacity();
    try trie.collectMatches(&rec_active_other, &matches, allocator);
    try testing.expect(!listContains(&matches, 1));
    try testing.expect(listContains(&matches, 2));
    try testing.expect(listContains(&matches, 3));

    trie.removeGroup(1, &filter_a);
    trie.removeGroup(2, &filter_b);
    // Shared status=active node remains while C is live.
    try testing.expectEqual(@as(u32, 1), trie.root.eq_branches.count());

    trie.removeGroup(3, &filter_c);
    try testing.expect(trie.isEmpty());
}

test "PredicateDag: match_all and match_none" {
    const allocator = testing.allocator;
    var trie = PredicateTrie.init(allocator);
    defer trie.deinit();

    var filter_all = try qth.makeDefaultFilter(allocator);
    defer filter_all.deinit(allocator);
    filter_all.predicate.state = .match_all;

    var filter_none = try qth.makeDefaultFilter(allocator);
    defer filter_none.deinit(allocator);
    filter_none.predicate.state = .match_none;

    try testing.expect(try trie.insertGroup(10, &filter_all));
    try testing.expect(!try trie.insertGroup(11, &filter_none));

    var rec = try tth.recordFromValues(allocator, &.{tth.valText("x")});
    defer rec.deinit(allocator);

    var matches: std.ArrayListUnmanaged(u64) = .empty;
    defer matches.deinit(allocator);
    try trie.collectMatches(&rec, &matches, allocator);
    try testing.expect(listContains(&matches, 10));
    try testing.expect(!listContains(&matches, 11));

    trie.removeGroup(10, &filter_all);
    trie.removeGroup(11, &filter_none);
    try testing.expect(trie.isEmpty());
}

test "PredicateDag: non-eq condition branch" {
    const allocator = testing.allocator;
    var trie = PredicateTrie.init(allocator);
    defer trie.deinit();

    var filter = try qth.makeFilterWithConditions(allocator, &[_]Condition{
        .{ .field_index = 3, .op = .gte, .value = tth.valInt(5), .field_type = .integer, .items_type = null },
    });
    defer filter.deinit(allocator);

    try testing.expect(try trie.insertGroup(1, &filter));

    var high = try tth.recordFromValues(allocator, &.{tth.valInt(8)});
    defer high.deinit(allocator);
    var low = try tth.recordFromValues(allocator, &.{tth.valInt(2)});
    defer low.deinit(allocator);

    var matches: std.ArrayListUnmanaged(u64) = .empty;
    defer matches.deinit(allocator);
    try trie.collectMatches(&high, &matches, allocator);
    try testing.expect(listContains(&matches, 1));

    matches.clearRetainingCapacity();
    try trie.collectMatches(&low, &matches, allocator);
    try testing.expect(!listContains(&matches, 1));

    trie.removeGroup(1, &filter);
    try testing.expect(trie.isEmpty());
}

test "PredicateDag: eq then non-eq path order" {
    const allocator = testing.allocator;
    var trie = PredicateTrie.init(allocator);
    defer trie.deinit();

    // status eq (tier 0) before age gte (tier 1), regardless of field_index order input.
    var filter = try qth.makeFilterWithConditions(allocator, &[_]Condition{
        .{ .field_index = 4, .op = .gte, .value = tth.valInt(18), .field_type = .integer, .items_type = null },
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    _ = try trie.insertGroup(1, &filter);
    try testing.expect(trie.root.eq_branches.contains(3));
    try testing.expectEqual(@as(u32, 0), trie.root.cond_branches.count());

    var ok = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(20) });
    defer ok.deinit(allocator);
    var bad_status = try tth.recordFromValues(allocator, &.{ tth.valText("draft"), tth.valInt(20) });
    defer bad_status.deinit(allocator);
    var bad_age = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(10) });
    defer bad_age.deinit(allocator);

    var matches: std.ArrayListUnmanaged(u64) = .empty;
    defer matches.deinit(allocator);
    try trie.collectMatches(&ok, &matches, allocator);
    try testing.expect(listContains(&matches, 1));
    matches.clearRetainingCapacity();
    try trie.collectMatches(&bad_status, &matches, allocator);
    try testing.expect(!listContains(&matches, 1));
    matches.clearRetainingCapacity();
    try trie.collectMatches(&bad_age, &matches, allocator);
    try testing.expect(!listContains(&matches, 1));
}

test "PredicateDag: OR clause residual filtering" {
    const allocator = testing.allocator;
    var trie = PredicateTrie.init(allocator);
    defer trie.deinit();

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

    try testing.expect(try trie.insertGroup(1, &filter));

    // status=active, owner=1 → AND path matches, OR clause passes
    var rec_match = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(1), tth.valInt(0) });
    defer rec_match.deinit(allocator);
    var matches: std.ArrayListUnmanaged(u64) = .empty;
    defer matches.deinit(allocator);
    try trie.collectMatches(&rec_match, &matches, allocator);
    try testing.expect(listContains(&matches, 1));
    try testing.expect(try predicate_trie.residualMatches(&filter.predicate, &rec_match));

    // status=active, owner=3 → AND path matches, OR clause fails
    var rec_or_fail = try tth.recordFromValues(allocator, &.{ tth.valText("active"), tth.valInt(3), tth.valInt(0) });
    defer rec_or_fail.deinit(allocator);
    matches.clearRetainingCapacity();
    try trie.collectMatches(&rec_or_fail, &matches, allocator);
    try testing.expect(listContains(&matches, 1)); // AND path still matches
    try testing.expect(!try predicate_trie.residualMatches(&filter.predicate, &rec_or_fail)); // OR fails

    // status=draft, owner=1 → AND path fails (trie never reaches leaf)
    var rec_and_fail = try tth.recordFromValues(allocator, &.{ tth.valText("draft"), tth.valInt(1), tth.valInt(0) });
    defer rec_and_fail.deinit(allocator);
    matches.clearRetainingCapacity();
    try trie.collectMatches(&rec_and_fail, &matches, allocator);
    try testing.expect(!listContains(&matches, 1));

    trie.removeGroup(1, &filter);
    try testing.expect(trie.isEmpty());
}
