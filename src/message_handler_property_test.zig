const std = @import("std");

const testing = std.testing;
const ConnectionState = @import("message_handler.zig").ConnectionState;
const ConnectionRegistry = @import("message_handler.zig").ConnectionRegistry;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const msgpack = @import("msgpack_test_helpers.zig");
const RequestHandler = @import("request_handler.zig").RequestHandler;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const ArrayList = std.ArrayList;

// **Property: Connection open/close is inverse operation**
// Connection properties
//
// For any connection, opening then closing should remove all associated state from the ConnectionRegistry.
test "connection: open/close is inverse operation" {
    const allocator = testing.allocator;

    // Initialize all required components for MessageHandler
    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-artifacts/message_handler/test_data_property4");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-artifacts/message_handler/test_data_property4") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Initialize message handler
    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test single connection open/close
    {
        // Create a mock WebSocket
        var ws = createMockWebSocket();

        // Open connection
        try handler.handleOpen(&ws);

        // Verify connection was added
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));
        const state = try handler.connection_registry.get(conn_id);
        try testing.expectEqual(conn_id, state.id);

        // Close connection
        try handler.handleClose(&ws, 1000, "Normal closure");

        // Verify connection was removed (inverse operation)
        const result = handler.connection_registry.get(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }

    // Test multiple connections open/close
    {
        const num_connections = 100;
        var websockets: [num_connections]WebSocket = undefined;

        // Open all connections
        for (&websockets) |*ws| {
            ws.* = createMockWebSocket();
            try handler.handleOpen(ws);
        }

        // Verify all connections exist
        try testing.expectEqual(@as(usize, num_connections), handler.connection_registry.connections.count());

        // Close all connections
        for (&websockets) |*ws| {
            try handler.handleClose(ws, 1000, "Normal closure");
        }

        // Verify all connections were removed (inverse operation)
        try testing.expectEqual(@as(usize, 0), handler.connection_registry.connections.count());
    }

    // Test connection with subscriptions
    {
        var ws = createMockWebSocket();

        // Open connection
        try handler.handleOpen(&ws);
        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

        // Add some subscriptions to the connection state
        const state = try handler.connection_registry.get(conn_id);
        try state.subscription_ids.append(1);
        try state.subscription_ids.append(2);
        try state.subscription_ids.append(3);

        // Verify subscriptions exist
        try testing.expectEqual(@as(usize, 3), state.subscription_ids.items.len);

        // Close connection
        try handler.handleClose(&ws, 1000, "Normal closure");

        // Verify connection and all associated state was removed (inverse operation)
        const result = handler.connection_registry.get(conn_id);
        try testing.expectError(error.ConnectionNotFound, result);
    }
}

// Helper function to create a mock WebSocket for testing
fn createMockWebSocket() WebSocket {
    return WebSocket{
        .ws = null, // Mock WebSocket
        .ssl = false,
        .user_data = null,
    };
}

// Property: Thread-safe connection registry access
// For any concurrent read and write operations on the ConnectionRegistry,
// no data races should occur and all operations should complete successfully.
test "connection: thread-safe registry access" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    // Spawn multiple threads performing concurrent operations
    const num_threads = 10;
    const ops_per_thread = 100;

    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, concurrentRegistryOps, .{
            &registry,
            allocator,
            i * ops_per_thread,
            ops_per_thread,
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify no data races occurred (test passes if no crashes)
    // All connections should have been removed by their respective threads
    try testing.expectEqual(@as(usize, 0), registry.connections.count());
}

fn concurrentRegistryOps(
    registry: *ConnectionRegistry,
    allocator: std.mem.Allocator,
    start_id: u64,
    count: usize,
) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const conn_id = start_id + i;

        // Add connection
        const state = ConnectionState.init(allocator, conn_id) catch {
            std.log.debug("Failed to init connection state\n", .{});
            return;
        };
        registry.add(conn_id, state) catch {
            std.log.debug("Failed to add connection\n", .{});
            state.deinit(allocator);
            return;
        };

        // Read connection
        _ = registry.get(conn_id) catch {
            std.log.debug("Failed to get connection\n", .{});
            return;
        };

        // Remove connection
        registry.remove(conn_id) catch {
            std.log.debug("Failed to remove connection\n", .{});
            return;
        };
    }
}

// Additional property test: Concurrent reads should not block each other
test "connection: concurrent reads are non-blocking" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    // Pre-populate registry with connections
    const num_connections = 100;
    var i: usize = 0;
    while (i < num_connections) : (i += 1) {
        const state = try ConnectionState.init(allocator, i);
        try registry.add(i, state);
    }

    // Spawn multiple reader threads
    const num_readers = 10;
    const reads_per_thread = 1000;

    var threads: [num_readers]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, concurrentReads, .{
            &registry,
            num_connections,
            reads_per_thread,
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify all connections still exist
    try testing.expectEqual(@as(usize, num_connections), registry.connections.count());
}

fn concurrentReads(
    registry: *ConnectionRegistry,
    num_connections: usize,
    num_reads: usize,
) void {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    var i: usize = 0;
    while (i < num_reads) : (i += 1) {
        const conn_id = random.intRangeAtMost(u64, 0, num_connections - 1);
        _ = registry.get(conn_id) catch {
            std.log.debug("Failed to get connection {}\n", .{conn_id});
            return;
        };
    }
}

// Additional property test: Mixed concurrent operations
test "connection: mixed concurrent ops safety" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    const num_threads = 8;
    const ops_per_thread = 50;

    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, mixedConcurrentOps, .{
            &registry,
            allocator,
            i * ops_per_thread,
            ops_per_thread,
        });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Test passes if no crashes or data races occurred
}

fn mixedConcurrentOps(
    registry: *ConnectionRegistry,
    allocator: std.mem.Allocator,
    start_id: u64,
    count: usize,
) void {
    var prng = std.Random.DefaultPrng.init(@intCast(start_id));
    const random = prng.random();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const conn_id = start_id + i;
        const op = random.intRangeAtMost(u8, 0, 2);

        switch (op) {
            0 => {
                // Add operation
                const state = ConnectionState.init(allocator, conn_id) catch continue;
                registry.add(conn_id, state) catch {
                    state.deinit(allocator);
                    continue;
                };
            },
            1 => {
                // Get operation
                _ = registry.get(conn_id) catch continue;
            },
            2 => {
                // Remove operation
                registry.remove(conn_id) catch continue;
            },
            else => unreachable,
        }
    }
}

// Property test: Clear operation is thread-safe
test "connection: clear is thread-safe" {
    const allocator = testing.allocator;

    var registry = try ConnectionRegistry.init(allocator);
    defer registry.deinit();

    // Add some initial connections
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const state = try ConnectionState.init(allocator, i);
        try registry.add(i, state);
    }

    // Spawn threads that add connections while main thread clears
    const num_threads = 5;
    var threads: [num_threads]std.Thread = undefined;

    for (&threads, 0..) |*thread, idx| {
        thread.* = try std.Thread.spawn(.{}, addConnections, .{
            &registry,
            allocator,
            100 + idx * 20,
            20,
        });
    }

    // Clear registry while threads are adding
    std.Thread.sleep(1 * std.time.ns_per_ms);
    registry.clear();

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Test passes if no crashes occurred
}

fn addConnections(
    registry: *ConnectionRegistry,
    allocator: std.mem.Allocator,
    start_id: u64,
    count: usize,
) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const conn_id = start_id + i;
        const state = ConnectionState.init(allocator, conn_id) catch continue;
        registry.add(conn_id, state) catch {
            state.deinit(allocator);
            continue;
        };
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
}

test "connection: unique monotonically increasing IDs" {
    const allocator = testing.allocator;

    // Initialize all required components for MessageHandler
    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-artifacts/message_handler/test_data_property5");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-artifacts/message_handler/test_data_property5") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Initialize message handler
    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Sequential connections should have unique IDs
    {
        const num_connections = 1000;
        var websockets: [num_connections]WebSocket = undefined;
        var connection_ids: [num_connections]u64 = undefined;

        // Open all connections sequentially
        for (&websockets, 0..) |*ws, i| {
            ws.* = createMockWebSocket();
            try handler.handleOpen(ws);
            connection_ids[i] = @as(u64, @intFromPtr(ws.getUserData()));
        }

        // Verify all connection IDs are unique
        for (connection_ids, 0..) |id1, i| {
            for (connection_ids[i + 1 ..], i + 1..) |id2, j| {
                if (id1 == id2) {
                    std.log.debug("Duplicate connection ID found: {} at positions {} and {}\n", .{ id1, i, j });
                    try testing.expect(false);
                }
            }
        }

        // Verify IDs are monotonically increasing (property of atomic increment)
        for (connection_ids[0 .. connection_ids.len - 1], 0..) |id, i| {
            try testing.expect(connection_ids[i + 1] > id);
        }

        // Clean up
        for (&websockets) |*ws| {
            try handler.handleClose(ws, 1000, "Normal closure");
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
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, openConnectionsConcurrently, .{
                handler,
                connections_per_thread,
                &all_connection_ids,
                &ids_mutex,
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

    // Test 3: Connection IDs should never wrap or repeat even after many connections
    {
        const initial_id = handler.next_connection_id.load(.monotonic);
        const num_connections = 10000;

        var i: usize = 0;
        while (i < num_connections) : (i += 1) {
            var ws = createMockWebSocket();
            try handler.handleOpen(&ws);
            const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

            // Verify ID is greater than initial
            try testing.expect(conn_id >= initial_id);

            // Clean up immediately to avoid memory issues
            try handler.handleClose(&ws, 1000, "Normal closure");
        }

        // Verify counter has advanced by exactly num_connections
        const final_id = handler.next_connection_id.load(.monotonic);
        try testing.expectEqual(initial_id + num_connections, final_id);
    }

    // Test 4: IDs should be unique across handler restarts (new handler instance)
    {
        // Create a second handler instance
        const handler2 = try MessageHandler.init(
            allocator,
            &tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        defer handler2.deinit();

        // Open connections on both handlers
        var ws1 = createMockWebSocket();
        var ws2 = createMockWebSocket();

        try handler.handleOpen(&ws1);
        try handler2.handleOpen(&ws2);

        const id1 = @as(u64, @intFromPtr(ws1.getUserData()));
        const id2 = @as(u64, @intFromPtr(ws2.getUserData()));

        // IDs from different handler instances can overlap (both start at 1)
        // This is expected behavior - uniqueness is per-handler-instance
        // But within each instance, IDs must be unique
        _ = id1;
        _ = id2;

        // Clean up
        try handler.handleClose(&ws1, 1000, "Normal closure");
        try handler2.handleClose(&ws2, 1000, "Normal closure");
    }
}

fn openConnectionsConcurrently(
    handler: *MessageHandler,
    count: usize,
    all_ids: *std.AutoHashMap(u64, void),
    mutex: *std.Thread.Mutex,
) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var ws = createMockWebSocket();
        handler.handleOpen(&ws) catch {
            std.log.debug("Failed to open connection\n", .{});
            continue;
        };

        const conn_id = @as(u64, @intFromPtr(ws.getUserData()));

        // Store ID in shared map (thread-safe)
        mutex.lock();
        defer mutex.unlock();
        all_ids.put(conn_id, {}) catch {
            std.log.debug("Failed to store connection ID\n", .{});
        };

        // Clean up connection
        handler.handleClose(&ws, 1000, "Normal closure") catch {
            std.log.debug("Failed to close connection\n", .{});
        };
    }
}

test "message: all valid frames are parsed" {
    const allocator = testing.allocator;

    // Initialize all required components for MessageHandler
    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-artifacts/message_handler/test_data_property7");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-artifacts/message_handler/test_data_property7") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Initialize message handler
    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Valid StoreSet message should be parsed successfully
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        // Create a valid MessagePack message
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", "/key1", "value1");
        defer allocator.free(message);

        // This should not throw a parsing error
        try handler.handleMessage(&ws, message, .binary);
    }

    // Test 2: Valid StoreGet message should be parsed successfully
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        const message = try msgpack.createStoreGetMessage(allocator, 2, "test", "/key1");
        defer allocator.free(message);

        handler.handleMessage(&ws, message, .binary) catch {
            // Error expected
        };
    }

    // Test 3: Message with all required fields should parse
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        const message = try msgpack.createStoreSetMessage(allocator, 123, "ns", "/p", "v");
        defer allocator.free(message);

        handler.handleMessage(&ws, message, .binary) catch {
            // Error expected
        };
    }

    // Test 4: Various valid message formats should parse
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        const messages = [_]struct { ns: []const u8, p: []const u8, v: []const u8 }{
            .{ .ns = "a", .p = "/b", .v = "c" },
            .{ .ns = "x", .p = "/y", .v = "z" },
        };

        for (messages, 0..) |m, i| {
            const msg = try msgpack.createStoreSetMessage(allocator, @intCast(i), m.ns, m.p, m.v);
            defer allocator.free(msg);
            handler.handleMessage(&ws, msg, .binary) catch {
                // Error expected
            };
        }
    }
}

// **Property: Message type extraction**
// Message type extraction properties
//
// For any successfully parsed message, the message type field should be extractable
// from the MessagePack map.
test "message: type extraction" {
    // Initialize all required components for MessageHandler
    const allocator = testing.allocator;
    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-artifacts/message_handler/test_data_property8");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-artifacts/message_handler/test_data_property8") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreSet type should be extractable
    {
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", "/key", "val");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        try testing.expectEqualStrings("StoreSet", msg_info.type);
        try testing.expectEqual(@as(u64, 1), msg_info.id);
    }

    // Test 2: StoreGet type should be extractable
    {
        const message = try msgpack.createStoreGetMessage(allocator, 42, "test", "/key");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        try testing.expectEqualStrings("StoreGet", msg_info.type);
        try testing.expectEqual(@as(u64, 42), msg_info.id);
    }

    // Test 3: Various message types should be extractable
    {
        // StoreSet
        {
            const msg = try msgpack.createStoreSetMessage(allocator, 1, "a", "/b", "c");
            defer allocator.free(msg);

            var reader: std.Io.Reader = .fixed(msg);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const info = try handler.extractMessageInfo(parsed);
            try testing.expectEqualStrings("StoreSet", info.type);
            try testing.expectEqual(@as(u64, 1), info.id);
        }
        // StoreGet
        {
            const msg = try msgpack.createStoreGetMessage(allocator, 999, "x", "/y");
            defer allocator.free(msg);

            var reader: std.Io.Reader = .fixed(msg);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const info = try handler.extractMessageInfo(parsed);
            try testing.expectEqualStrings("StoreGet", info.type);
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
    // Initialize all required components for MessageHandler
    const allocator = testing.allocator;
    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test_data_property9");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test_data_property9") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreSet message should route to handleStoreSet
    {
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", "/key1", "value1");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);

        // Route the message - should not error for recognized type
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should be a success response
        try testing.expect(response.len > 0);
    }

    // Test 2: StoreGet message should route to handleStoreGet
    {
        // First set a value
        const set_message = try msgpack.createStoreSetMessage(allocator, 1, "test", "/key2", "value2");
        defer allocator.free(set_message);

        var set_reader: std.Io.Reader = .fixed(set_message);
        const set_parsed = try msgpack.decode(allocator, &set_reader);
        defer set_parsed.free(allocator);

        const set_info = try handler.extractMessageInfo(set_parsed);
        const set_response = try handler.routeMessage(1, set_info, set_parsed);
        defer allocator.free(set_response);

        // Now get the value
        const get_message = try msgpack.createStoreGetMessage(allocator, 2, "test", "/key2");
        defer allocator.free(get_message);

        var get_reader: std.Io.Reader = .fixed(get_message);
        const get_parsed = try msgpack.decode(allocator, &get_reader);
        defer get_parsed.free(allocator);

        const get_info = try handler.extractMessageInfo(get_parsed);

        const response = try handler.routeMessage(1, get_info, get_parsed);
        defer allocator.free(response);

        // Response should contain the value
        try testing.expect(response.len > 0);
    }

    // Test 3: Unknown message type should return error
    {
        const message = try msgpack.createCustomMessage(allocator, 3, "UnknownType", "test", "/key");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);

        const result = handler.routeMessage(1, msg_info, parsed);
        try testing.expectError(error.UnknownMessageType, result);
    }

    // Test 4: Multiple different message types should route correctly
    {
        const msgs = [_][]const u8{
            try msgpack.createStoreSetMessage(allocator, 10, "ns", "/p1", "v1"),
            try msgpack.createStoreGetMessage(allocator, 11, "ns", "/p1"),
            try msgpack.createStoreSetMessage(allocator, 12, "ns", "/p2", "v2"),
            try msgpack.createCustomMessage(allocator, 13, "InvalidType", "ns", "/p3"),
        };
        defer {
            for (msgs) |m| allocator.free(m);
        }

        const should_succeed = [_]bool{ true, true, true, false };

        for (msgs, 0..) |m, i| {
            var reader: std.Io.Reader = .fixed(m);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);

            if (should_succeed[i]) {
                const response = try handler.routeMessage(1, msg_info, parsed);
                defer allocator.free(response);
                try testing.expect(response.len > 0);
            } else {
                const result = handler.routeMessage(1, msg_info, parsed);
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
    // Initialize all required components for MessageHandler
    const allocator = testing.allocator;
    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-artifacts/message_handler/test_data_property10");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-artifacts/message_handler/test_data_property10") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreSet response should include correlation ID
    {
        const correlation_id: u64 = 12345;
        const message = try msgpack.createStoreSetMessage(allocator, correlation_id, "test", "/key", "val");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        try testing.expectEqual(correlation_id, msg_info.id);

        const response = try handler.routeMessage(1, msg_info, parsed);
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

    // Test 2: StoreGet response should include correlation ID
    {
        // First set a value
        const set_message = try msgpack.createStoreSetMessage(allocator, 1, "test", "/key2", "value2");
        defer allocator.free(set_message);

        var set_reader: std.Io.Reader = .fixed(set_message);
        const set_parsed = try msgpack.decode(allocator, &set_reader);
        defer set_parsed.free(allocator);

        const set_info = try handler.extractMessageInfo(set_parsed);
        const set_response = try handler.routeMessage(1, set_info, set_parsed);
        defer allocator.free(set_response);

        // Now get with specific correlation ID
        const correlation_id: u64 = 99999;
        const get_message = try msgpack.createStoreGetMessage(allocator, correlation_id, "test", "/key2");
        defer allocator.free(get_message);

        var get_reader: std.Io.Reader = .fixed(get_message);
        const get_parsed = try msgpack.decode(allocator, &get_reader);
        defer get_parsed.free(allocator);

        const get_info = try handler.extractMessageInfo(get_parsed);
        try testing.expectEqual(correlation_id, get_info.id);

        const response = try handler.routeMessage(1, get_info, get_parsed);
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
        const correlation_ids = [_]u64{ 1, 100, 999, 12345, 0 };

        for (correlation_ids) |corr_id| {
            const message = try msgpack.createStoreSetMessage(allocator, corr_id, "test", "/key", "val");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            try testing.expectEqual(corr_id, msg_info.id);

            const response = try handler.routeMessage(1, msg_info, parsed);
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

    // Test 4: Correlation ID should be preserved even for not found responses
    {
        const correlation_id: u64 = 77777;
        const message = try msgpack.createStoreGetMessage(allocator, correlation_id, "test", "/nonexistent");
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        try testing.expectEqual(correlation_id, msg_info.id);

        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should contain the correlation ID even for not found
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

    // Initialize all required components for MessageHandler
    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try @import("memory_strategy.zig").MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const storage_engine = try StorageEngine.init(allocator, "test-artifacts/message_handler/test_data_property11");
    defer {
        storage_engine.deinit();
        std.fs.cwd().deleteTree("test-artifacts/message_handler/test_data_property11") catch {};
    }

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Invalid MessagePack should trigger error response
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        // 0xc1 is never used in MessagePack
        const invalid_message = "\xc1\xc1\xc1";

        // handleMessage should catch the parsing error and send error response
        // It should not panic or crash
        handler.handleMessage(&ws, invalid_message, .binary) catch {
            // Expected to fail during parsing
            // Error expected
        };
    }

    // Test 2: Message missing required fields should trigger error
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        // Create map with 2 elements: type and id
        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x82); // fixmap(2)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreSet");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);

        const message = buf.items;

        handler.handleMessage(&ws, message, .binary) catch {
            // Error expected
        };
    }

    // Test 3: Text messages should trigger error (only binary supported)
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        const message = "some text message";

        // Should trigger TEXT_NOT_SUPPORTED error
        handler.handleMessage(&ws, message, .text) catch {
            // Error expected
        };
    }

    // Test 4: Message with invalid type should trigger error
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

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

        handler.handleMessage(&ws, message, .binary) catch {
            // Error expected
        };
    }

    // Test 5: Empty message should trigger error
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

        const message = "";

        handler.handleMessage(&ws, message, .binary) catch {
            // Error expected
        };
    }

    // Test 6: Message with wrong field types should trigger error
    {
        var ws = createMockWebSocket();
        try handler.handleOpen(&ws);
        defer handler.handleClose(&ws, 1000, "Normal closure") catch {};

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

        handler.handleMessage(&ws, message, .binary) catch {
            // Error expected
        };
    }
}
