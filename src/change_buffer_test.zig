const std = @import("std");
const testing = std.testing;
const change_buffer = @import("change_buffer.zig");
const ChangeBuffer = change_buffer.ChangeBuffer;
const OwnedRowChange = change_buffer.OwnedRowChange;
const Allocator = std.mem.Allocator;

test "ChangeBuffer: basic push and drain" {
    var alloc = testing.allocator;
    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    // Push one item
    try cb.push(.{
        .namespace = try alloc.dupe(u8, "ns"),
        .collection = try alloc.dupe(u8, "coll"),
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
    try testing.expectEqualStrings("ns", out.items[0].namespace);
    try testing.expectEqualStrings("coll", out.items[0].collection);
    try testing.expectEqual(OwnedRowChange.Operation.insert, out.items[0].operation);

    // Drain again should be empty
    var out2 = std.ArrayListUnmanaged(OwnedRowChange).empty;
    defer out2.deinit(alloc);
    try cb.drainInto(&out2, alloc);
    try testing.expectEqual(@as(usize, 0), out2.items.len);
}

test "ChangeBuffer: concurrent push and drain stress" {
    var alloc = testing.allocator;
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
                const ns = try std.fmt.allocPrint(ctx.alloc, "ns{}", .{i});
                const coll = try std.fmt.allocPrint(ctx.alloc, "coll{}", .{i});
                try ctx.cb.push(.{
                    .namespace = ns,
                    .collection = coll,
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
        const expected_ns = try std.fmt.allocPrint(alloc, "ns{}", .{i});
        defer alloc.free(expected_ns);
        try testing.expectEqualStrings(expected_ns, out.items[i].namespace);
    }
}
