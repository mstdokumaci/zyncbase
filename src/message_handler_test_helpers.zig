const std = @import("std");
const Allocator = std.mem.Allocator;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const Connection = @import("connection.zig").Connection;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const schema_parser = @import("schema_parser.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const msgpack = @import("msgpack_test_helpers.zig");

/// Shared atomic counter for unique connection IDs in tests
var next_mock_ws_id = std.atomic.Value(u64).init(1);

/// Helper function to create a mock WebSocket for testing
pub fn createMockWebSocket() WebSocket {
    return WebSocket{
        .ws = null,
        .ssl = false,
        .user_data = @ptrFromInt(next_mock_ws_id.fetchAdd(1, .monotonic)),
    };
}

/// Helper function to route a message through an arena and return a duped result for testing.
/// The caller is responsible for freeing the returned []u8.
pub fn routeWithArena(handler: *MessageHandler, allocator: Allocator, conn: *Connection, msg_info: MessageHandler.MessageInfo, parsed: msgpack.Payload) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const result = try handler.routeMessage(arena.allocator(), conn, msg_info, parsed);
    return try allocator.dupe(u8, result);
}

/// Unified context for integration and property tests.
/// Handles the lifecycle of the entire ZyncBase stack.
pub const AppTestContext = struct {
    allocator: Allocator,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    storage_engine: *StorageEngine,
    subscription_manager: *SubscriptionManager,
    handler: *MessageHandler,
    manager: *ConnectionManager,
    schema: *schema_parser.Schema,
    test_context: schema_helpers.TestContext,

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8, table_defs: []const schema_helpers.TableDef) !AppTestContext {
        const schema = try schema_helpers.createTestSchema(allocator, table_defs);
        errdefer schema_helpers.freeTestSchema(allocator, schema);
        return initWithSchema(allocator, prefix, schema);
    }

    pub fn initWithSchema(allocator: std.mem.Allocator, prefix: []const u8, schema: *schema_parser.Schema) !AppTestContext {
        // 1. Initialize Memory Strategy
        const ms = try allocator.create(MemoryStrategy);
        errdefer allocator.destroy(ms);
        try ms.init(allocator);
        errdefer ms.deinit();

        // 2. Initialize Violation Tracker
        const vt = try allocator.create(ViolationTracker);
        errdefer allocator.destroy(vt);
        vt.init(allocator, 10);
        errdefer vt.deinit();

        // 3. Initialize Schema Helpers TestContext (handles directory storage)
        var tc = try schema_helpers.TestContext.init(allocator, prefix);
        errdefer tc.deinit();

        // 4. Initialize Storage Engine
        const se = try schema_helpers.setupTestEngine(allocator, ms, &tc, schema);
        errdefer se.deinit();

        // 5. Initialize Subscription Manager
        const sm = try SubscriptionManager.init(allocator);
        errdefer sm.deinit();

        // 6. Initialize Message Handler
        const mh = try MessageHandler.init(allocator, ms, vt, se, sm, .{});
        errdefer mh.deinit();

        // 7. Initialize Connection Manager
        const cm = try ConnectionManager.init(allocator, ms, mh);
        errdefer cm.deinit();

        return AppTestContext{
            .allocator = allocator,
            .memory_strategy = ms,
            .violation_tracker = vt,
            .test_context = tc,
            .schema = schema,
            .storage_engine = se,
            .subscription_manager = sm,
            .handler = mh,
            .manager = cm,
        };
    }

    pub fn deinit(self: *AppTestContext) void {
        self.manager.deinit();
        self.handler.deinit();
        self.subscription_manager.deinit();
        self.storage_engine.deinit();
        schema_helpers.freeTestSchema(self.allocator, self.schema);
        self.test_context.deinit(); // Deletes artifacts directory
        self.violation_tracker.deinit();
        self.allocator.destroy(self.violation_tracker);
        self.memory_strategy.deinit();
        self.allocator.destroy(self.memory_strategy);
    }

    /// Helper to open a test connection and return a scoped wrapper.
    /// This ensures the correct LIFO release order for test and manager references.
    pub fn openScopedConnection(self: *AppTestContext, ws: *WebSocket) !ScopedConnection {
        try self.manager.onOpen(ws);
        const conn = try self.manager.acquireConnection(ws.getConnId());
        return ScopedConnection{
            .app = self,
            .ws = ws,
            .conn = conn,
        };
    }

    /// Helper to release a connection back to the memory strategy pool.
    /// Should be used with 'defer if (conn.release()) app.releaseConnection(conn);'
    pub fn releaseConnection(self: *AppTestContext, conn: *Connection) void {
        self.memory_strategy.releaseConnection(conn);
    }

    /// Scoped wrapper for a connection's test lifecycle.
    pub const ScopedConnection = struct {
        app: *AppTestContext,
        ws: *WebSocket,
        conn: *Connection,

        pub fn deinit(self: ScopedConnection) void {
            // 1. Manager drops its reference (removes from map, runs teardown)
            self.app.manager.onClose(self.ws, 1000, "normal");

            // 2. Test drops its reference (may return to pool)
            if (self.conn.release()) {
                self.app.memory_strategy.releaseConnection(self.conn);
            }
        }
    };

    /// Helper to simulate a graceful shutdown of all connections in a test environment.
    /// This calls ConnectionManager.closeAllConnections() and then manually triggers
    /// the onClose callbacks for all mock WebSockets, since the test environment
    /// lacks the asynchronous event loop that would normally handle this.
    pub fn closeAllConnections(self: *AppTestContext) void {
        self.manager.closeAllConnections();

        // Pump onClose for all remaining connections in the manager.
        // We iterate and remove until empty to avoid concurrent modification issues.
        while (true) {
            const maybe_conn = blk: {
                self.manager.mutex.lock();
                defer self.manager.mutex.unlock();
                var it = self.manager.map.valueIterator();
                if (it.next()) |conn_ptr| {
                    const conn = conn_ptr.*;
                    // Create a local copy of the WebSocket to avoid accessing
                    // connection memory after it might be released.
                    break :blk conn.ws;
                }
                break :blk null;
            };

            if (maybe_conn) |ws| {
                var local_ws = ws; // Mutability for callback
                self.manager.onClose(&local_ws, 1000, "shutdown");
            } else {
                break;
            }
        }
    }
};
