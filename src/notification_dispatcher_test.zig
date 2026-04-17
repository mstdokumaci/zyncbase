const std = @import("std");
const testing = std.testing;
const ChangeBuffer = @import("change_buffer.zig").ChangeBuffer;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const NotificationDispatcher = @import("notification_dispatcher.zig").NotificationDispatcher;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const schema_manager = @import("schema_manager.zig");
const storage_types = @import("storage_engine/types.zig");
// ============================================================
// Full dispatch integration tests
// ============================================================

test "NotificationDispatcher: empty poll" {
    const alloc = testing.allocator;

    var cb = try ChangeBuffer.init(alloc);
    defer cb.deinit();

    var sub_engine = SubscriptionEngine.init(alloc);
    defer sub_engine.deinit();

    var memory: MemoryStrategy = undefined;
    try memory.init(alloc);
    defer memory.deinit();

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory);
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

    var nd: NotificationDispatcher = undefined;
    try nd.init(alloc, &cb, &sub_engine, &memory);
    defer nd.deinit();

    // Create a row with an "id" field so dispatchChange doesn't skip it.
    // Build metadata explicitly to avoid helper-owned metadata leaks when the row
    // is moved into ChangeBuffer ownership.
    const empty_fields = [_]schema_manager.Field{};
    const table = schema_manager.Table{
        .name = "_test",
        .fields = &empty_fields,
    };
    var metadata = try schema_manager.TableMetadata.init(alloc, &table);
    defer metadata.deinit(alloc);

    const values = try alloc.alloc(storage_types.TypedValue, metadata.fields.len);
    errdefer alloc.free(values);
    for (values, 0..) |*value, i| {
        const field = metadata.fields[i];
        if (field.sql_type == .integer) {
            value.* = .{ .scalar = .{ .integer = 0 } };
        } else {
            value.* = .nil;
        }
    }

    const id_index = metadata.field_index_map.get("id") orelse return error.TestExpectedValue;
    values[id_index] = .{ .scalar = .{ .text = try alloc.dupe(u8, "1") } };

    const new_row = storage_types.TypedRow{
        .table_metadata = &metadata,
        .values = values,
    };

    try cb.push(.{
        .namespace = try alloc.dupe(u8, "ns"),
        .collection = try alloc.dupe(u8, "coll"),
        .operation = .insert,
        .old_row = null,
        .new_row = new_row,
    });

    var cm: ConnectionManager = undefined;
    nd.poll(&cm);

    try testing.expectEqual(@as(usize, 0), nd.drain_buf.items.len);
}
