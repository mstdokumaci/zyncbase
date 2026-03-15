const std = @import("std");
const testing = std.testing;
const ConnectionState = @import("message_handler.zig").ConnectionState;
const ConnectionRegistry = @import("message_handler.zig").ConnectionRegistry;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test "ConnectionState - init and deinit" {
    const allocator = testing.allocator;

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try ConnectionState.init(allocator, 1, dummy_ws);
    defer state.deinit(allocator);

    try testing.expectEqual(@as(u64, 1), state.id);
    try testing.expectEqual(@as(?[]const u8, null), state.user_id);
    try testing.expectEqualStrings("default", state.namespace);
    try testing.expectEqual(@as(usize, 0), state.subscription_ids.items.len);
}

test "ConnectionState - add subscription IDs" {
    const allocator = testing.allocator;

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try ConnectionState.init(allocator, 1, dummy_ws);
    defer state.deinit(allocator);

    try state.subscription_ids.append(100);
    try state.subscription_ids.append(200);
    try state.subscription_ids.append(300);

    try testing.expectEqual(@as(usize, 3), state.subscription_ids.items.len);
    try testing.expectEqual(@as(u64, 100), state.subscription_ids.items[0]);
    try testing.expectEqual(@as(u64, 200), state.subscription_ids.items[1]);
    try testing.expectEqual(@as(u64, 300), state.subscription_ids.items[2]);
}

test "ConnectionRegistry - init and deinit" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    try testing.expectEqual(@as(usize, 0), registry.connections.count());
}

test "ConnectionRegistry - add and get connection" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try ConnectionState.init(allocator, 1, dummy_ws);
    try registry.add(1, state);

    const retrieved = try registry.get(1);
    try testing.expectEqual(@as(u64, 1), retrieved.id);
    try testing.expectEqualStrings("default", retrieved.namespace);
}

test "ConnectionRegistry - get non-existent connection" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    const result = registry.get(999);
    try testing.expectError(error.ConnectionNotFound, result);
}

test "ConnectionRegistry - remove connection" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try ConnectionState.init(allocator, 1, dummy_ws);
    try registry.add(1, state);

    try testing.expectEqual(@as(usize, 1), registry.connections.count());

    try registry.remove(1);

    try testing.expectEqual(@as(usize, 0), registry.connections.count());
    const result = registry.get(1);
    try testing.expectError(error.ConnectionNotFound, result);
}

test "ConnectionRegistry - clear all connections" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state1 = try ConnectionState.init(allocator, 1, dummy_ws);
    const state2 = try ConnectionState.init(allocator, 2, dummy_ws);
    const state3 = try ConnectionState.init(allocator, 3, dummy_ws);

    try registry.add(1, state1);
    try registry.add(2, state2);
    try registry.add(3, state3);

    try testing.expectEqual(@as(usize, 3), registry.connections.count());

    registry.clear();

    try testing.expectEqual(@as(usize, 0), registry.connections.count());
}

test "ConnectionRegistry - multiple connections" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    // Add multiple connections
    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    for (1..11) |i| {
        const state = try ConnectionState.init(allocator, i, dummy_ws);
        try registry.add(i, state);
    }

    try testing.expectEqual(@as(usize, 10), registry.connections.count());

    // Verify all connections can be retrieved
    for (1..11) |i| {
        const retrieved = try registry.get(i);
        try testing.expectEqual(@as(u64, i), retrieved.id);
    }
}

test "ConnectionRegistry - iterator" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state1 = try ConnectionState.init(allocator, 1, dummy_ws);
    const state2 = try ConnectionState.init(allocator, 2, dummy_ws);

    try registry.add(1, state1);
    try registry.add(2, state2);

    var count: usize = 0;
    var it = registry.iterator();
    while (it.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "ConnectionRegistry - thread safety simulation" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    // Add connections
    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    for (1..6) |i| {
        const state = try ConnectionState.init(allocator, i, dummy_ws);
        try registry.add(i, state);
    }

    // Simulate concurrent access by doing multiple operations
    for (1..6) |i| {
        const retrieved = try registry.get(i);
        try testing.expectEqual(@as(u64, i), retrieved.id);
    }

    // Remove some connections
    try registry.remove(2);
    try registry.remove(4);

    try testing.expectEqual(@as(usize, 3), registry.connections.count());

    // Verify remaining connections
    _ = try registry.get(1);
    _ = try registry.get(3);
    _ = try registry.get(5);

    // Verify removed connections are gone
    try testing.expectError(error.ConnectionNotFound, registry.get(2));
    try testing.expectError(error.ConnectionNotFound, registry.get(4));
}
