const std = @import("std");
const testing = std.testing;
const change_buffer = @import("change_buffer.zig");
const ChangeBuffer = change_buffer.ChangeBuffer;
const OwnedRowChange = change_buffer.OwnedRowChange;
const Allocator = std.mem.Allocator;

test "ChangeBuffer: basic push and drain" {
    const alloc = testing.allocator;
    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    // Push one item
    try cb.push(.{
        .namespace_id = 1,
        .table_index = 1,
        .operation = .insert,
        .old_row = null,
        .new_row = null,
    });

    var out = std.ArrayListUnmanaged(OwnedRowChange).empty;
    defer {
        for (out.items) |*item| item.deinit(alloc);
        out.deinit(alloc);
    }

    try cb.drainInto(&out, alloc);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(i64, 1), out.items[0].namespace_id);
    try testing.expectEqual(@as(usize, 1), out.items[0].table_index);
    try testing.expectEqual(OwnedRowChange.Operation.insert, out.items[0].operation);

    // Drain again should be empty
    var out2 = std.ArrayListUnmanaged(OwnedRowChange).empty;
    defer out2.deinit(alloc);
    try cb.drainInto(&out2, alloc);
    try testing.expectEqual(@as(usize, 0), out2.items.len);
}

test "ChangeBuffer: concurrent push and drain stress" {
    const alloc = testing.allocator;
    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    const Context = struct {
        cb: *ChangeBuffer,
        alloc: Allocator,
        items_to_push: usize,
    };

    const producer = struct {
        fn run(ctx: *Context) !void {
            for (0..ctx.items_to_push) |i| {
                try ctx.cb.push(.{
                    .namespace_id = @intCast(i),
                    .table_index = i,
                    .operation = .update,
                    .old_row = null,
                    .new_row = null,
                });
            }
        }
    }.run;

    var ctx = Context{
        .cb = &cb,
        .alloc = alloc,
        .items_to_push = 2048,
    };

    const thread = try std.Thread.spawn(.{}, producer, .{&ctx});

    var out = std.ArrayListUnmanaged(OwnedRowChange).empty;
    defer {
        for (out.items) |*item| item.deinit(alloc);
        out.deinit(alloc);
    }

    var total_drained: usize = 0;
    while (total_drained < ctx.items_to_push) {
        try cb.drainInto(&out, alloc);
        total_drained = out.items.len;
    }

    thread.join();
    try testing.expectEqual(ctx.items_to_push, out.items.len);

    // Verify ordering
    for (0..ctx.items_to_push) |i| {
        try testing.expectEqual(@as(i64, @intCast(i)), out.items[i].namespace_id);
    }
}
