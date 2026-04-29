const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

const sub_eng = @import("subscription_engine.zig");
const cb = @import("change_buffer.zig");
const SubscriptionEngine = sub_eng.SubscriptionEngine;
const RowChange = sub_eng.RowChange;
const query_parser = @import("query_parser.zig");

test "Subscription Consistency: write-before-subscribe is captured and delivered" {
    const allocator = testing.allocator;

    // 1) Setup a minimal engine/table and subscription engine
    var fields_arr = [_]sth.Field{
        sth.makeField("val", .text, false),
    };
    const table = sth.Table{ .name = "items", .name_quoted = "\"items\"", .fields = &fields_arr };

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "write-before-subscribe-capture", table);
    defer ctx.deinit();
    const engine = &ctx.engine;

    var sub_engine = SubscriptionEngine.init(allocator);
    defer sub_engine.deinit();

    // 2) Queue a write BEFORE any subscription exists.
    //    This is the behavior that used to be dropped when capture was optional.
    try ctx.insertText("items", 1, 1, "val", "task 1");

    // 3) Subscribe AFTER write is acknowledged/queued but BEFORE commit/flush.
    //    Filter matches exactly the row above.
    const items_md = ctx.sm.getTable("items") orelse return error.UnknownTable;
    const val_index = items_md.field_index_map.get("val") orelse return error.UnknownField;
    const conditions = try allocator.alloc(query_parser.Condition, 1);
    conditions[0] = query_parser.Condition{
        .field_index = val_index,
        .op = .eq,
        .value = try tth.valTextOwned(allocator, "task 1"),
        .field_type = .text,
        .items_type = null,
    };

    var filter = try qth.makeDefaultFilter(allocator);
    filter.conditions = conditions;
    defer filter.deinit(allocator);

    _ = try sub_engine.subscribe(1, (ctx.sm.getTable("items") orelse return error.TestExpectedValue).index, filter, 42, 101);

    // 4) Flush queued writes into DB + change buffer.
    try engine.flushPendingWrites();

    // 5) Drain captured changes and verify the queued write was captured.
    var drain_buf = std.ArrayListUnmanaged(cb.OwnedRowChange).empty;
    defer {
        for (drain_buf.items) |*c| c.deinit(allocator);
        drain_buf.deinit(allocator);
    }

    try engine.change_buffer.drainInto(&drain_buf, allocator);
    try testing.expectEqual(@as(usize, 1), drain_buf.items.len);

    // 6) Feed the captured change into subscription engine and verify delivery.
    const captured = drain_buf.items[0];
    const row_change = RowChange{
        .namespace_id = captured.namespace_id,
        .table_index = captured.table_index,
        .operation = @enumFromInt(@intFromEnum(captured.operation)),
        .new_row = captured.new_row,
        .old_row = captured.old_row,
    };

    const matches = try sub_engine.handleRowChange(row_change, allocator);
    defer allocator.free(matches);

    try testing.expectEqual(@as(usize, 1), matches.len);
    try testing.expectEqual(@as(u64, 42), matches[0].connection_id);
    try testing.expectEqual(@as(u64, 101), matches[0].subscription_id);
}
