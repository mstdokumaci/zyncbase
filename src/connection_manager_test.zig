const std = @import("std");
const testing = std.testing;
const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const createMockWebSocket = helpers.createMockWebSocket;

test "ConnectionManager - init and deinit" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-init", &.{});
    defer app.deinit();

    try testing.expectEqual(@as(usize, 0), app.connection_manager.map.count());
}

test "ConnectionManager - onOpen and onClose" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-open", &.{});
    defer app.deinit();

    var dummy_ws = createMockWebSocket();

    // Test onOpen
    {
        const sc = try app.openScopedConnection(&dummy_ws);
        defer sc.deinit();
        try testing.expectEqual(@as(usize, 1), app.connection_manager.map.count());
        try testing.expectEqual(dummy_ws.getConnId(), sc.conn.id);
    }

    // Test onClose (after sc.deinit() has run)
    try testing.expectEqual(@as(usize, 0), app.connection_manager.map.count());
}

test "ConnectionManager - onClose clears violation state" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-violations", &.{});
    defer app.deinit();

    var dummy_ws = createMockWebSocket();
    const conn_id = dummy_ws.getConnId();

    {
        const sc = try app.openScopedConnection(&dummy_ws);
        defer sc.deinit();

        _ = try app.violation_tracker.recordViolation(conn_id);
        try testing.expectEqual(@as(u32, 1), app.violation_tracker.getViolationCount(conn_id));
    }

    try testing.expectEqual(@as(u32, 0), app.violation_tracker.getViolationCount(conn_id));
}

test "ConnectionManager - max connections" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "cm-max", &.{});
    defer app.deinit();

    // Set a small limit for testing
    app.connection_manager.max_connections = 2;

    var ws1 = createMockWebSocket();
    var ws2 = createMockWebSocket();
    var ws3 = createMockWebSocket();

    // Open 2 connections (at the limit)
    const sc1 = try app.openScopedConnection(&ws1);
    defer sc1.deinit();
    const sc2 = try app.openScopedConnection(&ws2);
    defer sc2.deinit();

    try testing.expectEqual(@as(usize, 2), app.connection_manager.map.count());

    // Third connection should be rejected (close called on ws)
    // Note: AppTestContext.openScopedConnection calls manager.onOpen
    // We should check if it's in the map.
    app.connection_manager.onOpen(&ws3) catch unreachable;
    try testing.expectEqual(@as(usize, 2), app.connection_manager.map.count());
    // The connection should not be in the map
    try testing.expectError(error.ConnectionNotFound, app.connection_manager.acquireConnection(ws3.getConnId()));
}

test "ConnectionManager - acquire and release" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-mgr-id-reuse", &.{});
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();

    // Manual acquire incrementing refcount
    const conn = try app.connection_manager.acquireConnection(ws.getConnId());

    // We now have 3 references:
    // 1. Owned by the ConnectionManager (onOpen)
    // 2. Owned by the ScopedConnection (sc)
    // 3. Owned by this 'conn' pointer (manual acquire)
    // All 3 must be released for the memory to return to the pool.

    // sc.deinit() will drop its reference (sc.conn.release()) and call onClose.
    // onClose will drop manager's reference.
    // The connection will still exist until we drop our manual reference.

    // Drop our manual reference
    if (conn.release()) app.memory_strategy.releaseConnection(conn);
}
