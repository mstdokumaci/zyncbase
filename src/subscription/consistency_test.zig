const std = @import("std");

const query_ast = @import("../query/ast.zig");
const qth = @import("../query/test_helpers.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const tth = @import("../typed/test_helpers.zig");
const typed = @import("../typed/types.zig");
const sub_eng = @import("engine.zig");
const OwnedRecordChange = @import("change_queue.zig").OwnedRecordChange;

const testing = std.testing;
const RecordChange = sub_eng.RecordChange;
const SubscriptionEngine = sub_eng.SubscriptionEngine;

test "Subscription Consistency: write-before-subscribe is captured and delivered" {
    const allocator = std.heap.smp_allocator;

    // 1) Setup a minimal engine/table and subscription engine
    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("val", .text),
    };
    const table = schema_helpers.makeTable("items", &fields_arr);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "write-before-subscribe-capture", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    var sub_engine = SubscriptionEngine.init(testing.io, allocator);
    defer sub_engine.deinit();

    // 2) Queue a write BEFORE any subscription exists.
    //    This is the behavior that used to be dropped when capture was optional.
    try ctx.insertText("items", 1, 1, "val", "task 1");

    // 3) Subscribe AFTER write is acknowledged/queued but BEFORE commit/flush.
    //    Filter matches exactly the row above.
    const items_md = ctx.schema.table("items") orelse return error.UnknownTable;
    const val_index = items_md.fieldIndex("val") orelse return error.UnknownField;
    const conditions = try allocator.alloc(query_ast.Condition, 1);
    conditions[0] = query_ast.Condition{
        .field_index = val_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "task 1"),
        .field_type = .text,
        .items_type = null,
    };

    var filter = try qth.makeDefaultFilter(allocator);
    filter.predicate.conditions = conditions;
    defer filter.deinit(allocator);

    _ = try sub_engine.subscribe(1, (ctx.schema.table("items") orelse return error.TestExpectedValue).index, filter, 42, 101, 0);

    // 4) Flush queued writes into DB + change queue.
    try engine.flushPendingWrites();

    // 5) Drain captured changes and verify the queued write was captured.
    var change_queue = ctx.test_context.change_queue orelse return error.TestExpectedValue;
    var drain_buf = std.ArrayListUnmanaged(OwnedRecordChange).empty;
    defer {
        for (drain_buf.items) |*c| c.deinit(allocator);
        drain_buf.deinit(allocator);
    }

    // Drain all shards (test uses 1 shard)
    var shard = (&change_queue).getShard(0);
    while (shard.popTimed(0)) |job| {
        try drain_buf.append(allocator, job.change);
    }

    try testing.expectEqual(@as(usize, 1), drain_buf.items.len);

    // 6) Feed the captured change into subscription engine and verify delivery.
    const captured = drain_buf.items[0];
    const row_change = RecordChange{
        .namespace_id = captured.namespace_id,
        .table_index = captured.table_index,
        .operation = @enumFromInt(@intFromEnum(captured.operation)),
        .new_record = captured.new_record,
        .old_record = captured.old_record,
    };

    const matches = try sub_engine.handleRecordChange(row_change, allocator);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(u64, 42), matches[0].connection_id);
    try testing.expectEqual(@as(u64, 101), matches[0].subscription_id);
}

test "Subscription Consistency: delta matching agrees with SQL snapshots on NULL fields" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("name", .text),
        schema_helpers.makeField("score", .integer),
    };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "null-consistency", schema_helpers.makeTable("items", &fields_arr));
    defer ctx.deinit();

    const items = try ctx.tableMetadata("items");
    const score_index = items.fieldIndex("score") orelse return error.UnknownField;
    try ctx.insertText("items", 1, 1, "name", "no score");
    try ctx.insertInt("items", 2, 1, "score", 5);
    try ctx.insertInt("items", 3, 1, "score", 20);
    try ctx.engine.flushPendingWrites();

    var stored: [3]typed.Record = undefined;
    for (&stored, 1..) |*record, id| {
        record.* = (try sth.readDoc(allocator, &ctx.engine, items.index, @intCast(id), 1)) orelse return error.TestExpectedValue;
    }
    defer for (stored) |record| record.deinit(allocator);

    var members = [_]typed.ScalarValue{.{ .integer = 5 }};
    const ops = [_]query_ast.Operator{ .eq, .ne, .gt, .lt, .gte, .lte, .in, .notIn, .isNull, .isNotNull };
    for (ops) |op| {
        const operand: ?typed.Value = switch (op) {
            .isNull, .isNotNull => null,
            .in, .notIn => .{ .array = &members },
            else => tth.valInt(10),
        };
        var filter = try qth.makeFilterWithConditions(allocator, &.{.{ .field_index = score_index, .op = op, .value = operand, .field_type = .integer, .items_type = null }});
        defer filter.deinit(allocator);
        _ = try expectDeltasAgreeWithSnapshot(allocator, &ctx, items, &stored, &filter, op);
    }
}

test "Subscription Consistency: delta matching agrees with SQL snapshots on array equality" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("name", .text),
        schema_helpers.makeField("tags", .array),
    };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "array-eq-consistency", schema_helpers.makeTable("items", &fields_arr));
    defer ctx.deinit();

    const items = try ctx.tableMetadata("items");
    const tags_index = items.fieldIndex("tags") orelse return error.UnknownField;
    var both = [_]typed.ScalarValue{ .{ .text = "a" }, .{ .text = "b" } };
    var only_a = [_]typed.ScalarValue{.{ .text = "a" }};
    try ctx.insertField("items", 1, 1, "tags", .{ .array = &both });
    try ctx.insertField("items", 2, 1, "tags", .{ .array = &only_a });
    try ctx.insertText("items", 3, 1, "name", "no tags");
    try ctx.engine.flushPendingWrites();

    var stored: [3]typed.Record = undefined;
    for (&stored, 1..) |*record, id| {
        record.* = (try sth.readDoc(allocator, &ctx.engine, items.index, @intCast(id), 1)) orelse return error.TestExpectedValue;
    }
    defer for (stored) |record| record.deinit(allocator);

    for ([_]query_ast.Operator{ .eq, .ne }) |op| {
        var filter = try qth.makeFilterWithConditions(allocator, &.{.{ .field_index = tags_index, .op = op, .value = .{ .array = &both }, .field_type = .array, .items_type = .text }});
        defer filter.deinit(allocator);
        const matched = try expectDeltasAgreeWithSnapshot(allocator, &ctx, items, &stored, &filter, op);
        try testing.expectEqual(@as(usize, 1), matched);
    }
}

/// Asserts that each stored record produces a delta exactly when the SQL
/// snapshot for `filter` contains it. Returns the snapshot size.
fn expectDeltasAgreeWithSnapshot(
    allocator: std.mem.Allocator,
    ctx: *sth.EngineTestContext,
    items: *const sth.TableMetadata,
    stored: []const typed.Record,
    filter: *const query_ast.QueryFilter,
    op: query_ast.Operator,
) !usize {
    const snapshot = try sth.queryDocs(allocator, &ctx.engine, items.index, 1, filter);
    defer snapshot.deinit(allocator);

    var snapshot_ids = std.AutoHashMap(typed_doc_id.DocId, void).init(allocator);
    defer snapshot_ids.deinit();
    for (snapshot.records) |record| {
        const id = sth.getFieldDocIdOrNull(record, items, "id") orelse return error.TestExpectedValue;
        try snapshot_ids.put(id, {});
    }

    var sub_engine = SubscriptionEngine.init(testing.io, allocator);
    defer sub_engine.deinit();
    try sub_engine.subscribe(1, items.index, filter.*, 42, 1, 0);

    for (stored) |record| {
        const matches = try sub_engine.handleRecordChange(.{
            .namespace_id = 1,
            .table_index = items.index,
            .operation = .insert,
            .new_record = record,
            .old_record = null,
        }, allocator);
        defer allocator.free(matches);
        const id = sth.getFieldDocIdOrNull(record, items, "id") orelse return error.TestExpectedValue;
        const in_snapshot = snapshot_ids.contains(id);
        testing.expectEqual(in_snapshot, matches.len > 0) catch |err| {
            std.debug.print("operator {s}: record {d} in SQL snapshot: {}, deltas matched: {d}\n", .{ @tagName(op), id, in_snapshot, matches.len });
            return err;
        };
    }
    return snapshot.records.len;
}
