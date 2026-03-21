const std = @import("std");
const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const ConnectionRegistry = @import("message_handler.zig").ConnectionRegistry;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test "Connection - init and deinit" {
    const allocator = testing.allocator;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    // Let pool handle memory free when ref_count goes to 0 by releasing it:
    defer state.release(allocator);

    try testing.expectEqual(@as(u64, 1), state.id);
    try testing.expectEqual(@as(?[]const u8, null), state.user_id);
    try testing.expectEqualStrings("default", state.namespace);
    try testing.expectEqual(@as(usize, 0), state.subscription_ids.items.len);
}

test "Connection - add subscription IDs" {
    const allocator = testing.allocator;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    defer state.release(allocator);

    try state.subscription_ids.append(state.allocator, 100);
    try state.subscription_ids.append(state.allocator, 200);
    try state.subscription_ids.append(state.allocator, 300);

    try testing.expectEqual(@as(usize, 3), state.subscription_ids.items.len);
    try testing.expectEqual(@as(u64, 100), state.subscription_ids.items[0]);
    try testing.expectEqual(@as(u64, 200), state.subscription_ids.items[1]);
    try testing.expectEqual(@as(u64, 300), state.subscription_ids.items[2]);
}

test "ConnectionRegistry - init and deinit" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 0), snap.count());
    }
}

test "ConnectionRegistry - add and get connection" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    try registry.add(1, state);

    const retrieved = try registry.acquireConnection(1);
    defer retrieved.release(allocator);
    try testing.expectEqual(@as(u64, 1), retrieved.id);
    try testing.expectEqualStrings("default", retrieved.namespace);
}

test "ConnectionRegistry - get non-existent connection" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const result = registry.acquireConnection(999);
    try testing.expectError(error.ConnectionNotFound, result);
}

test "ConnectionRegistry - remove connection" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    try registry.add(1, state);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 1), snap.count());
    }

    registry.remove(1);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 0), snap.count());
    }
    const result = registry.acquireConnection(1);
    try testing.expectError(error.ConnectionNotFound, result);
}

test "ConnectionRegistry - clear all connections" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state1 = try memory_strategy.createConnection(1, dummy_ws);
    const state2 = try memory_strategy.createConnection(2, dummy_ws);
    const state3 = try memory_strategy.createConnection(3, dummy_ws);

    try registry.add(1, state1);
    try registry.add(2, state2);
    try registry.add(3, state3);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 3), snap.count());
    }

    registry.clear();

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 0), snap.count());
    }
}

test "ConnectionRegistry - multiple connections" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    // Add multiple connections
    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    for (1..11) |i| {
        const state = try memory_strategy.createConnection(i, dummy_ws);
        try registry.add(i, state);
    }

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 10), snap.count());
    }

    // Verify all connections can be retrieved
    for (1..11) |i| {
        const retrieved = try registry.acquireConnection(i);
        defer retrieved.release(allocator);
        try testing.expectEqual(@as(u64, i), retrieved.id);
    }
}

test "ConnectionRegistry - iterator" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state1 = try memory_strategy.createConnection(1, dummy_ws);
    const state2 = try memory_strategy.createConnection(2, dummy_ws);

    try registry.add(1, state1);
    try registry.add(2, state2);

    var count: usize = 0;
    var snap = try registry.snapshot();
    defer snap.deinit();
    var it = snap.iterator();
    while (it.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "ConnectionRegistry - thread safety simulation" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    // Add connections
    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    for (1..6) |i| {
        const state = try memory_strategy.createConnection(i, dummy_ws);
        try registry.add(i, state);
    }

    // Simulate concurrent access by doing multiple operations
    for (1..6) |i| {
        const retrieved = try registry.acquireConnection(i);
        defer retrieved.release(allocator);
        try testing.expectEqual(@as(u64, i), retrieved.id);
    }

    // Remove some connections
    registry.remove(2);
    registry.remove(4);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 3), snap.count());
    }

    // Verify remaining connections
    {
        const r1 = try registry.acquireConnection(1);
        r1.release(allocator);
        const r3 = try registry.acquireConnection(3);
        r3.release(allocator);
        const r5 = try registry.acquireConnection(5);
        r5.release(allocator);
    }

    // Verify removed connections are gone
    try testing.expectError(error.ConnectionNotFound, registry.acquireConnection(2));
    try testing.expectError(error.ConnectionNotFound, registry.acquireConnection(4));
}
