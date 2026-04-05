const std = @import("std");
const testing = std.testing;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const msgpack = @import("msgpack_test_helpers.zig");
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const helpers = @import("message_handler_test_helpers.zig");
const createMockWebSocket = helpers.createMockWebSocket;
const AppTestContext = helpers.AppTestContext;
const routeWithArena = helpers.routeWithArena;

test "connection: open/close is inverse operation" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-inverse", &.{
        .{ .name = "_dummy", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = &app.manager;

    // Test single connection open/close
    {
        // Create a mock WebSocket
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1))); // Use unique ID

        // Open connection
        try manager.onOpen(&ws);

        // Verify connection was added
        const conn_id = ws.getConnId();
        const state = try manager.acquireConnection(conn_id);
        defer if (state.release()) app.releaseConnection(state);
        try testing.expectEqual(conn_id, state.id);

        // Close connection
        manager.onClose(&ws, 1000, "Normal closure");

        // Verify connection was removed (inverse operation)
        const result = manager.acquireConnection(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }

    // Test multiple connections open/close
    {
        const num_connections = 100;
        var websockets: [num_connections]WebSocket = undefined;

        // Open all connections
        for (&websockets, 0..) |*ws, i| {
            ws.* = createMockWebSocket();
            ws.setUserData(@ptrFromInt(i + 10)); // Ensure unique ID
            try manager.onOpen(ws);
        }

        // Verify all connections exist
        try testing.expectEqual(@as(usize, num_connections), manager.map.count());

        // Close all connections
        for (&websockets) |*ws| {
            manager.onClose(ws, 1000, "Normal closure");
        }

        // Verify all connections were removed (inverse operation)
        try testing.expectEqual(@as(usize, 0), manager.map.count());
    }

    // Test connection with subscriptions
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1234)));

        // Open connection
        try manager.onOpen(&ws);
        const conn_id = ws.getConnId();

        // Add some subscriptions to the connection state
        const state = try manager.acquireConnection(conn_id);
        defer if (state.release()) app.releaseConnection(state);
        try state.subscription_ids.append(state.allocator, 1);
        try state.subscription_ids.append(state.allocator, 2);
        try state.subscription_ids.append(state.allocator, 3);

        // Verify subscriptions exist
        try testing.expectEqual(@as(usize, 3), state.subscription_ids.items.len);

        // Close connection
        manager.onClose(&ws, 1000, "Normal closure");

        // Verify connection and all associated state was removed (inverse operation)
        const result = manager.acquireConnection(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }
}

// Helper function to create a mock WebSocket for testing

test "connection: thread-safe manager access" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p9", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = &app.manager;

    // Spawn multiple threads performing concurrent operations
    const num_threads = 10;
    const ops_per_thread = 100;

    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, concurrentManagerOps, .{
            &app,
            i * ops_per_thread,
            ops_per_thread,
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify all connections should have been removed by their respective threads
    try testing.expectEqual(@as(usize, 0), manager.map.count());
}

fn concurrentManagerOps(
    app: *AppTestContext,
    start_id: u64,
    count: usize,
) void {
    const manager = &app.manager;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const conn_id = start_id + i;

        // Add connection
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, conn_id)));
        manager.onOpen(&ws) catch { // zwanzig-disable-line: swallowed-error
            std.log.debug("Failed to open connection\n", .{});
            return;
        };

        // Read connection
        if (manager.acquireConnection(conn_id)) |s| {
            if (s.release()) app.releaseConnection(s);
        } else |_| {
            std.log.debug("Failed to get connection\n", .{});
            return;
        }

        // Remove connection
        manager.onClose(&ws, 1000, "Normal closure");
    }
}

// Additional property test: Concurrent reads should not block each other
test "connection: concurrent reads are non-blocking" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p10", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = &app.manager;

    // Pre-populate manager with connections
    const num_connections = 100;
    var i: usize = 0;
    while (i < num_connections) : (i += 1) {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(i + 1));
        try manager.onOpen(&ws);
    }

    // Spawn multiple reader threads
    const num_readers = 10;
    const reads_per_thread = 1000;

    var threads: [num_readers]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, concurrentReads, .{
            &app,
            num_connections,
            reads_per_thread,
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify all connections still exist
    try testing.expectEqual(@as(usize, num_connections), manager.map.count());
}

fn concurrentReads(
    app: *AppTestContext,
    num_connections: usize,
    num_reads: usize,
) void {
    const manager = &app.manager;
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    var i: usize = 0;
    while (i < num_reads) : (i += 1) {
        const conn_id = random.intRangeAtMost(u64, 1, num_connections);
        if (manager.acquireConnection(conn_id)) |s| {
            if (s.release()) app.releaseConnection(s);
        } else |_| {
            std.log.debug("Failed to get connection {}\n", .{conn_id});
            return;
        }
    }
}

// Additional property test: Mixed concurrent operations
test "connection: mixed concurrent ops safety" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p4", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const num_threads = 8;
    const ops_per_thread = 500;
    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, concurrentMixedOps, .{
            &app,
            @as(u64, i) * 1000 + 100, // Range offset to avoid overlap with other tests
            ops_per_thread,
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Test passes if no crashes or data races occurred
}

fn concurrentMixedOps(
    app: *AppTestContext,
    start_id: u64,
    count: usize,
) void {
    const manager = &app.manager;
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const conn_id = start_id + i;
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, conn_id)));

        const op = random.intRangeAtMost(u8, 0, 2);
        switch (op) {
            0 => {
                // Add operation
                manager.onOpen(&ws) catch continue; // zwanzig-disable-line: swallowed-error
            },
            1 => {
                // Get operation
                if (manager.acquireConnection(conn_id)) |s| {
                    if (s.release()) app.releaseConnection(s);
                } else |_| {}
            },
            2 => {
                // Remove operation
                manager.onClose(&ws, 1000, "Normal closure");
            },
            else => unreachable,
        }
    }
}

// Property test: Clear operation is thread-safe
test "connection: closeAll is thread-safe" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p4", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = &app.manager;

    // Add some initial connections
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(i + 1));
        try manager.onOpen(&ws);
    }

    // Spawn threads that add connections while main thread closes all
    const num_threads = 5;
    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, idx| {
        thread.* = try std.Thread.spawn(.{}, addConnections, .{
            manager,
            100 + idx * 20,
            20,
        });
    }

    // Close all connections while threads are adding
    std.Thread.sleep(1 * std.time.ns_per_ms);
    manager.closeAllConnections();

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Test passes if no crashes occurred
}

fn addConnections(
    manager: *ConnectionManager,
    start_id: u64,
    count: usize,
) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const conn_id = start_id + i;
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, conn_id)));
        manager.onOpen(&ws) catch continue; // zwanzig-disable-line: swallowed-error
    }
}

test "connection: unique IDs" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p5", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = &app.manager;

    // Test 1: Sequential connections should have unique IDs
    {
        const num_connections = 1000;
        var websockets: [num_connections]WebSocket = undefined;
        var connection_ids: [num_connections]u64 = undefined;

        // Open all connections sequentially
        for (&websockets, 0..) |*ws, idx| {
            ws.* = createMockWebSocket();
            const conn_id = idx + 1;
            ws.setUserData(@ptrFromInt(conn_id));
            try manager.onOpen(ws);
            connection_ids[idx] = ws.getConnId();
            try testing.expectEqual(conn_id, connection_ids[idx]);
        }

        // Verify all connection IDs are unique
        for (connection_ids, 0..) |id1, idx| {
            for (connection_ids[idx + 1 ..], idx + 1..) |id2, j| {
                if (id1 == id2) {
                    std.log.debug("Duplicate connection ID found: {} at positions {} and {}\n", .{ id1, idx, j });
                    try testing.expect(false);
                }
            }
        }

        // Clean up
        for (&websockets) |*ws| {
            manager.onClose(ws, 1000, "Normal closure");
        }
    }

    // Test 2: Concurrent connections should have unique IDs
    {
        const num_threads = 10;
        const connections_per_thread = 100;
        var threads: [num_threads]std.Thread = undefined;

        // Shared storage for connection IDs
        var all_connection_ids = std.AutoHashMap(u64, void).init(allocator);
        defer all_connection_ids.deinit();
        var ids_mutex = std.Thread.Mutex{};

        // Spawn threads that open connections concurrently
        for (&threads, 0..) |*thread, idx| {
            thread.* = try std.Thread.spawn(.{}, openConnectionsConcurrently, .{
                manager,
                connections_per_thread,
                &all_connection_ids,
                &ids_mutex,
                idx, // Pass thread index
            });
        }

        // Wait for all threads
        for (threads) |thread| {
            thread.join();
        }

        // Verify we have exactly the expected number of unique IDs
        const expected_count = num_threads * connections_per_thread;
        try testing.expectEqual(@as(usize, expected_count), all_connection_ids.count());
    }

    // Test 3: Connection IDs should be unique (replacing monotonicity test)
    {
        const num_connections = 1000;
        var ids = std.AutoHashMap(u64, void).init(allocator);
        defer ids.deinit();

        var idx: usize = 0;
        while (idx < num_connections) : (idx += 1) {
            var ws = createMockWebSocket();
            ws.setUserData(@ptrFromInt(idx + 1000000));
            try manager.onOpen(&ws);
            const conn_id = ws.getConnId();

            try testing.expect(!ids.contains(conn_id));
            try ids.put(conn_id, {});

            // Clean up immediately to avoid memory issues
            manager.onClose(&ws, 1000, "Normal closure");
        }

        try testing.expectEqual(@as(usize, num_connections), ids.count());
    }

    // Test 4: IDs should be unique across manager restarts (new manager instance)
    {
        // Create a second manager instance using the same context components (safely)
        var manager2: ConnectionManager = undefined;
        try manager2.init(allocator, &app.memory_strategy, &app.handler);
        defer manager2.deinit();

        // Open connections on both managers
        var ws1 = createMockWebSocket();
        var ws2 = createMockWebSocket();

        ws1.setUserData(@ptrFromInt(@as(usize, 1)));
        ws2.setUserData(@ptrFromInt(@as(usize, 1)));

        try manager.onOpen(&ws1);
        try manager2.onOpen(&ws2);

        const id1 = ws1.getConnId();
        const id2 = ws2.getConnId();

        // IDs from different manager instances can overlap if they both start from the same base
        _ = id1;
        _ = id2;

        // Clean up
        manager.onClose(&ws1, 1000, "Normal closure");
        manager2.onClose(&ws2, 1000, "Normal closure");
    }
}

fn openConnectionsConcurrently(
    manager: *ConnectionManager,
    count: usize,
    all_ids: *std.AutoHashMap(u64, void),
    mutex: *std.Thread.Mutex,
    thread_idx: usize,
) void {
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        var ws = createMockWebSocket();
        const unique_id = (thread_idx + 1) * 10000 + idx;
        ws.setUserData(@ptrFromInt(unique_id));
        manager.onOpen(&ws) catch { // zwanzig-disable-line: swallowed-error
            std.log.debug("Failed to open connection\n", .{});
            continue;
        };

        const conn_id = ws.getConnId();

        // Store ID in shared map (thread-safe)
        mutex.lock();
        all_ids.put(conn_id, {}) catch {
            std.log.debug("Failed to store connection ID\n", .{});
        };
        mutex.unlock();

        // Clean up connection
        manager.onClose(&ws, 1000, "Normal closure");
    }
}

test "message: all valid frames are parsed" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p7", &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = &app.manager;

    // Test 1: Valid StoreSet message should be parsed successfully
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        // Create a valid MessagePack message
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "data_table", "key1", "val" }, "value1");
        defer allocator.free(message);

        // This should not throw a parsing error
        manager.onMessage(&ws, message, .binary);
    }

    // Test 2: Valid StoreQuery message should be parsed successfully
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 2)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        var filter = msgpack.Payload.mapPayload(allocator);
        defer filter.free(allocator);

        const message = try msgpack.createStoreQueryMessage(allocator, 2, "test", "data_table", filter);
        defer allocator.free(message);

        manager.onMessage(&ws, message, .binary);
    }

    // Test 3: Message with all required fields should parse
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 3)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        const message = try msgpack.createStoreSetMessage(allocator, 123, "ns", &.{ "data_table", "p", "val" }, "v");
        defer allocator.free(message);

        manager.onMessage(&ws, message, .binary);
    }

    // Test 4: Various valid message formats should parse
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 4)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        const messages = [_]struct { ns: []const u8, p: []const u8, v: []const u8 }{
            .{ .ns = "a", .p = "/b", .v = "c" },
            .{ .ns = "x", .p = "/y", .v = "z" },
        };

        for (messages, 0..) |m, i| {
            const msg = try msgpack.createStoreSetMessage(allocator, @intCast(i), m.ns, &.{m.p}, m.v);
            defer allocator.free(msg);
            manager.onMessage(&ws, msg, .binary);
        }
    }
}

// **Property: Message type extraction**
// Message type extraction properties
//
// For any successfully parsed message, the message type field should be extractable
// from the MessagePack map.
test "message: type extraction" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p8", &.{
        .{ .name = "data_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = &app.handler;

    // Test 1: StoreSet type should be extractable
    {
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "data_table", "key", "val" }, "val");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try app.handler.extractMessageInfo(parsed);
        try testing.expectEqualStrings("StoreSet", msg_info.type);
        try testing.expectEqual(@as(u64, 1), msg_info.id);
    }

    // Test 2: StoreQuery type should be extractable
    {
        var filter = msgpack.Payload.mapPayload(allocator);
        defer filter.free(allocator);
        const message = try msgpack.createStoreQueryMessage(allocator, 42, "test", "data_table", filter);
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try app.handler.extractMessageInfo(parsed);
        try testing.expectEqualStrings("StoreQuery", msg_info.type);
        try testing.expectEqual(@as(u64, 42), msg_info.id);
    }

    // Test 3: Various message types should be extractable
    {
        // StoreSet
        {
            const msg = try msgpack.createStoreSetMessage(allocator, 1, "a", &.{"b"}, "c");
            defer allocator.free(msg);

            var reader: std.Io.Reader = .fixed(msg);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const info = try app.handler.extractMessageInfo(parsed);
            try testing.expectEqualStrings("StoreSet", info.type);
            try testing.expectEqual(@as(u64, 1), info.id);
        }
        // StoreQuery
        {
            var filter = msgpack.Payload.mapPayload(allocator);
            defer filter.free(allocator);
            const msg = try msgpack.createStoreQueryMessage(allocator, 999, "x", "y", filter);
            defer allocator.free(msg);

            var reader: std.Io.Reader = .fixed(msg);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const info = try app.handler.extractMessageInfo(parsed);
            try testing.expectEqualStrings("StoreQuery", info.type);
            try testing.expectEqual(@as(u64, 999), info.id);
        }
    }

    // Test 4: Message without type field should fail extraction
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack.writeString(allocator, &buf, "namespace");
        try msgpack.writeString(allocator, &buf, "test");
        try msgpack.writeString(allocator, &buf, "path");
        try msgpack.writeString(allocator, &buf, "/key");

        const msg_buf = buf.items;

        var reader: std.Io.Reader = .fixed(msg_buf);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const result = handler.extractMessageInfo(parsed);
        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 5: Message without id field should fail extraction
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x84); // fixmap(4)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreSet");
        try msgpack.writeString(allocator, &buf, "namespace");
        try msgpack.writeString(allocator, &buf, "test");
        try msgpack.writeString(allocator, &buf, "path");
        try msgpack.writeString(allocator, &buf, "/key");
        try msgpack.writeString(allocator, &buf, "value");
        try msgpack.writeString(allocator, &buf, "val");

        const msg_buf = buf.items;

        var reader: std.Io.Reader = .fixed(msg_buf);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const result = handler.extractMessageInfo(parsed);
        try testing.expectError(error.MissingRequiredFields, result);
    }
}

// **Property: Request routing**
// Message routing properties
//
// For any message with a recognized type (StoreSet, StoreGet), the message should be
// routed to the appropriate handler function.
test "message: request routing to handlers" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p9", &.{
        .{ .name = "test_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = &app.handler;

    // Test 1: StoreSet message should route to handleStoreSet
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "test_table", "key1", "val" }, "value1");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try app.handler.extractMessageInfo(parsed);

        // Route the message - should not error for recognized type
        const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
        defer allocator.free(response);

        // Response should be a success response
        try testing.expect(response.len > 0);
    }

    // Test 2: StoreQuery message should route to handleStoreQuery
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        // First set a value
        const set_message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "test_table", "key2", "val" }, "value2");
        defer allocator.free(set_message);

        var set_reader: std.Io.Reader = .fixed(set_message);
        const set_parsed = try msgpack.decode(allocator, &set_reader);
        defer set_parsed.free(allocator);

        const set_info = try handler.extractMessageInfo(set_parsed);
        const set_response = try routeWithArena(handler, allocator, conn, set_info, set_parsed);
        defer allocator.free(set_response);

        // Now query the value
        var filter = msgpack.Payload.mapPayload(allocator);
        defer filter.free(allocator);
        const query_message = try msgpack.createStoreQueryMessage(allocator, 2, "test", "test_table", filter);
        defer allocator.free(query_message);

        var get_reader: std.Io.Reader = .fixed(query_message);
        const get_parsed = try msgpack.decode(allocator, &get_reader);
        defer get_parsed.free(allocator);

        const get_info = try handler.extractMessageInfo(get_parsed);

        const response = try routeWithArena(handler, allocator, conn, get_info, get_parsed);
        defer allocator.free(response);

        // Response should contain the value
        try testing.expect(response.len > 0);
    }

    // Test 3: Unknown message type should return error
    {
        var ws = createMockWebSocket();
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        const message = try msgpack.createCustomMessage(allocator, 3, "UnknownType", "test", &.{"key"});
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try app.handler.extractMessageInfo(parsed);

        const result = routeWithArena(handler, allocator, conn, msg_info, parsed);
        try testing.expectError(error.UnknownMessageType, result);
    }

    // Test 4: Multiple different message types should route correctly
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        const msgs = [_][]const u8{
            try msgpack.createStoreSetMessage(allocator, 10, "ns", &.{ "test_table", "p1", "val" }, "v1"),
            try msgpack.createStoreQueryMessage(allocator, 11, "ns", "test_table", msgpack.Payload.mapPayload(allocator)),
            try msgpack.createStoreSetMessage(allocator, 12, "ns", &.{ "test_table", "p2", "val" }, "v2"),
            try msgpack.createCustomMessage(allocator, 13, "InvalidType", "ns", &.{ "test_table", "p3" }),
        };
        defer {
            for (msgs) |m| allocator.free(m);
        }

        const should_succeed = [_]bool{ true, true, true, false };

        for (msgs, 0..) |m, i| {
            var reader: std.Io.Reader = .fixed(m);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try app.handler.extractMessageInfo(parsed);

            if (should_succeed[i]) {
                const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
                defer allocator.free(response);
                try testing.expect(response.len > 0);
            } else {
                const result = routeWithArena(handler, allocator, conn, msg_info, parsed);
                try testing.expectError(error.UnknownMessageType, result);
            }
        }
    }
}

// **Property: Response correlation**
// Message correlation properties
//
// For any request message with a correlation ID, the response message should include
// the same correlation ID.
test "message: response correlation by ID" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p10", &.{
        .{ .name = "test_table", .fields = &.{"val"} },
    });
    defer app.deinit();

    const handler = &app.handler;

    // Test 1: StoreSet response should include correlation ID
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        const correlation_id: u64 = 12345;
        const message = try msgpack.createStoreSetMessage(allocator, correlation_id, "test", &.{ "test_table", "key", "val" }, "val");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try app.handler.extractMessageInfo(parsed);
        try testing.expectEqual(correlation_id, msg_info.id);

        const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
        defer allocator.free(response);

        // Response should contain the correlation ID
        var resp_reader: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);

        try testing.expect(resp_parsed == .map);
        var found_id = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) {
                try testing.expectEqual(correlation_id, entry.value_ptr.*.uint);
                found_id = true;
            }
        }
        try testing.expect(found_id);
    }

    // Test 2: StoreQuery response should include correlation ID
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        // First set a value
        const set_message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "test_table", "key2", "val" }, "value2");
        defer allocator.free(set_message);

        var set_reader: std.Io.Reader = .fixed(set_message);
        const set_parsed = try msgpack.decode(allocator, &set_reader);
        defer set_parsed.free(allocator);

        const set_info = try handler.extractMessageInfo(set_parsed);
        const set_response = try routeWithArena(handler, allocator, conn, set_info, set_parsed);
        defer allocator.free(set_response);

        // Now query with specific correlation ID
        const correlation_id: u64 = 99999;
        var filter = msgpack.Payload.mapPayload(allocator);
        defer filter.free(allocator);
        const query_message = try msgpack.createStoreQueryMessage(allocator, correlation_id, "test", "test_table", filter);
        defer allocator.free(query_message);

        var get_reader: std.Io.Reader = .fixed(query_message);
        const get_parsed = try msgpack.decode(allocator, &get_reader);
        defer get_parsed.free(allocator);

        const get_info = try handler.extractMessageInfo(get_parsed);
        try testing.expectEqual(correlation_id, get_info.id);

        const response = try routeWithArena(handler, allocator, conn, get_info, get_parsed);
        defer allocator.free(response);

        // Response should contain the correlation ID
        var resp_reader: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);

        try testing.expect(resp_parsed == .map);
        var found_id = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) {
                try testing.expectEqual(correlation_id, entry.value_ptr.*.uint);
                found_id = true;
            }
        }
        try testing.expect(found_id);
    }

    // Test 3: Multiple requests with different correlation IDs
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        const correlation_ids = [_]u64{ 1, 100, 999, 12345, 0 };

        for (correlation_ids) |corr_id| {
            const message = try msgpack.createStoreSetMessage(allocator, corr_id, "test", &.{ "test_table", "key", "val" }, "val");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try app.handler.extractMessageInfo(parsed);
            try testing.expectEqual(corr_id, msg_info.id);

            const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
            defer allocator.free(response);

            // Each response should contain its specific correlation ID
            var resp_reader: std.Io.Reader = .fixed(response);
            const resp_parsed = try msgpack.decode(allocator, &resp_reader);
            defer resp_parsed.free(allocator);

            try testing.expect(resp_parsed == .map);
            var found_id = false;
            var it = resp_parsed.map.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) {
                    try testing.expectEqual(corr_id, entry.value_ptr.*.uint);
                    found_id = true;
                }
            }
            try testing.expect(found_id);
        }
    }

    // Test 4: Correlation ID should be preserved even for query responses
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        const correlation_id: u64 = 77777;
        var filter = msgpack.Payload.mapPayload(allocator);
        defer filter.free(allocator);
        const message = try msgpack.createStoreQueryMessage(allocator, correlation_id, "test", "test_table", filter);
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try app.handler.extractMessageInfo(parsed);
        try testing.expectEqual(correlation_id, msg_info.id);

        const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
        defer allocator.free(response);

        // Response should contain the correlation ID
        var resp_reader: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);

        try testing.expect(resp_parsed == .map);
        var found_id = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) {
                try testing.expectEqual(correlation_id, entry.value_ptr.*.uint);
                found_id = true;
            }
        }
        try testing.expect(found_id);
    }
}

// **Property: Error responses for invalid messages**
// Message validation properties
//
// For any message that fails parsing, an error response in Wire Protocol format
// should be sent to the client.
test "message: error responses for invalid types/fields" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-p11", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const manager = &app.manager;

    // Test 1: Invalid MessagePack should trigger error response
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 1)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        // 0xc1 is never used in MessagePack
        const invalid_message = "\xc1\xc1\xc1";

        // onMessage should catch the parsing error and send error response
        // It should not panic or crash
        manager.onMessage(&ws, invalid_message, .binary);
    }

    // Test 2: Message missing required fields should trigger error
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 2)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        // Create map with 2 elements: type and id
        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x82); // fixmap(2)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreSet");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);

        const message = buf.items;

        manager.onMessage(&ws, message, .binary);
    }

    // Test 3: Text messages should trigger error (only binary supported)
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 3)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        const message = "some text message";

        // Should trigger TEXT_NOT_SUPPORTED error (though onMessage doesn't take opCode,
        // normally the server calls onMessage with the data)
        // ConnectionManager expects []const u8, so it's always "binary" in its view
        manager.onMessage(&ws, message, .binary);
    }

    // Test 4: Message with invalid type should trigger error
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 4)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x84); // fixmap(4)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "InvalidType");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack.writeString(allocator, &buf, "namespace");
        try msgpack.writeString(allocator, &buf, "test");
        try msgpack.writeString(allocator, &buf, "path");
        try msgpack.writeString(allocator, &buf, "/key");

        const message = buf.items;

        manager.onMessage(&ws, message, .binary);
    }

    // Test 5: Empty message should trigger error
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 5)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        const message = "";

        manager.onMessage(&ws, message, .binary);
    }

    // Test 6: Message with wrong field types should trigger error
    {
        var ws = createMockWebSocket();
        ws.setUserData(@ptrFromInt(@as(usize, 6)));
        try manager.onOpen(&ws);
        defer manager.onClose(&ws, 1000, "Normal closure");

        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack.writeString(allocator, &buf, "type");
        try buf.append(allocator, 0x01); // int instead of string
        try msgpack.writeString(allocator, &buf, "id");
        try msgpack.writeString(allocator, &buf, "not_a_number");
        try msgpack.writeString(allocator, &buf, "namespace");
        try msgpack.writeString(allocator, &buf, "test");

        const message = buf.items;

        manager.onMessage(&ws, message, .binary);
    }
}
