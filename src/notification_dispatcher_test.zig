const std = @import("std");
const testing = std.testing;
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const NotificationDispatcher = @import("notification_dispatcher.zig").NotificationDispatcher;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const schema_manager = @import("schema_manager.zig");
const storage_types = @import("storage_engine.zig");
const sth = @import("storage_engine_test_helpers.zig");

test "NotificationDispatcher: empty poll" {
    const alloc = testing.allocator;

    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    var sub_engine = SubscriptionEngine.init(alloc);
    defer sub_engine.deinit();

    var memory: MemoryStrategy = undefined;
    try memory.init(alloc);
    defer memory.deinit();

    const empty_fields = [_]schema_manager.Field{};
    const table = sth.makeTable("_test", &empty_fields);
    var sm = try sth.createSchemaManager(alloc, &[_]schema_manager.Table{table});
    defer sm.deinit();

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory, &sm);
    defer nd.deinit();

    var cm: ConnectionManager = undefined;
    nd.poll(&cm);
}

test "NotificationDispatcher: poll processes items" {
    const alloc = testing.allocator;

    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    var sub_engine = SubscriptionEngine.init(alloc);
    defer sub_engine.deinit();

    var memory: MemoryStrategy = undefined;
    try memory.init(alloc);
    defer memory.deinit();

    const empty_fields = [_]schema_manager.Field{};
    const table = sth.makeTable("coll", &empty_fields);
    var sm = try sth.createSchemaManager(alloc, &[_]schema_manager.Table{table});
    defer sm.deinit();

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory, &sm);
    defer nd.deinit();

    const tbl_md = sm.getTable("coll") orelse return error.TestExpectedValue;
    const values = try alloc.alloc(storage_types.TypedValue, tbl_md.fields.len);
    errdefer alloc.free(values);
    for (values, 0..) |*value, i| {
        const field = tbl_md.fields[i];
        if (field.sql_type == .integer) {
            value.* = .{ .scalar = .{ .integer = 0 } };
        } else {
            value.* = .nil;
        }
    }

    const id_index = schema_manager.id_field_index;
    values[id_index] = .{ .scalar = .{ .text = try alloc.dupe(u8, "1") } };

    const new_row = storage_types.TypedRow{
        .values = values,
    };

    try cb.push(.{
        .namespace_id = 1,
        .table_index = tbl_md.index,
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    });

    var cm: ConnectionManager = undefined;
    nd.poll(&cm);

    try testing.expectEqual(@as(usize, 0), nd.drain_buf.items.len);
}
