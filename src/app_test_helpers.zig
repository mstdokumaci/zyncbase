const std = @import("std");
const Allocator = std.mem.Allocator;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const Connection = @import("connection.zig").Connection;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const schema_helpers = @import("schema_test_helpers.zig");
pub const TableDef = schema_helpers.TableDef;
const msgpack = @import("msgpack_test_helpers.zig");
const msgpack_utils = @import("msgpack_utils.zig");
const StoreService = @import("store_service.zig").StoreService;
const protocol = @import("protocol.zig");
const sth = @import("storage_engine_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");

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
pub fn routeWithArena(handler: *MessageHandler, allocator: Allocator, conn: *Connection, parsed: msgpack.Payload) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const msg_info = try protocol.extractAs(protocol.Envelope, arena_allocator, parsed);

    const result = try handler.routeRequest(arena_allocator, conn, msg_info, parsed);

    return try allocator.dupe(u8, result);
}

/// Parse a response and extract the "type" and "code" fields.
/// Caller is responsible for freeing the fields in the returned struct.
pub fn parseResponse(allocator: std.mem.Allocator, response: []const u8) !struct { resp_type: []const u8, code: ?[]const u8 } {
    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack_utils.decode(allocator, &reader);
    defer parsed.free(allocator);

    const resp_type_val_opt = try msgpack.getMapValue(parsed, "type");
    const resp_type_val = resp_type_val_opt orelse return error.MissingType;
    const resp_code_val = try msgpack.getMapValue(parsed, "code");

    return .{
        .resp_type = try allocator.dupe(u8, resp_type_val.str.value()),
        .code = if (resp_code_val) |v| try allocator.dupe(u8, v.str.value()) else null,
    };
}

/// Unified context for integration and property tests.
/// Handles the lifecycle of the entire ZyncBase stack.
pub const AppTestContext = struct {
    allocator: Allocator,
    memory_strategy: MemoryStrategy,
    violation_tracker: ViolationTracker,
    storage_engine: StorageEngine,
    subscription_engine: SubscriptionEngine,
    store_service: StoreService,
    handler: MessageHandler,
    connection_manager: ConnectionManager,
    schema_manager: SchemaManager,
    test_context: schema_helpers.TestContext,

    pub fn init(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, table_defs: []const schema_helpers.TableDef) !void {
        try self.initWithOptions(allocator, prefix, table_defs, .{ .in_memory = true });
    }

    pub fn initWithOptions(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, table_defs: []const schema_helpers.TableDef, options: StorageEngine.Options) !void {
        const sm = try schema_helpers.createTestSchemaManager(allocator, table_defs);
        try self.initWithSchemaManagerAndOptions(allocator, prefix, sm, options);
    }

    pub fn initWithSchema(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, schema: schema_manager.Schema) !void {
        const cloned_schema = try schema.clone(allocator);
        errdefer schema_manager.freeSchema(allocator, cloned_schema);

        const metadata = try schema_manager.SchemaMetadata.init(allocator, &cloned_schema);
        errdefer {
            var m = metadata;
            m.deinit(allocator);
        }

        const sm = SchemaManager{
            .allocator = allocator,
            .schema = cloned_schema,
            .metadata = metadata,
        };

        try self.initWithSchemaManagerAndOptions(allocator, prefix, sm, .{ .in_memory = true });
    }

    pub fn initWithSchemaJSON(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, json: []const u8) !void {
        // SAFETY: sm is immediately initialized by sm.init() before use.
        var sm: SchemaManager = undefined;
        try sm.init(allocator, json);
        try self.initWithSchemaManagerAndOptions(allocator, prefix, sm, .{ .in_memory = true });
    }

    pub fn initWithSchemaManagerAndOptions(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, sm: SchemaManager, options: StorageEngine.Options) !void {
        self.allocator = allocator;
        self.schema_manager = sm;
        errdefer self.schema_manager.deinit();

        // 1. Initialize Memory Strategy
        try self.memory_strategy.init(allocator);
        errdefer self.memory_strategy.deinit();

        // 2. Initialize Violation Tracker
        self.violation_tracker.init(allocator, 10);
        errdefer self.violation_tracker.deinit();

        // 3. Initialize Schema Helpers TestContext
        self.test_context = if (options.in_memory)
            try schema_helpers.TestContext.initInMemory(allocator)
        else
            try schema_helpers.TestContext.init(allocator, prefix);
        errdefer self.test_context.deinit();

        // 4. Initialize Storage Engine
        try schema_helpers.setupTestEngine(&self.storage_engine, allocator, &self.memory_strategy, &self.test_context, &self.schema_manager, options);
        errdefer self.storage_engine.deinit();

        // 5. Initialize Subscription Engine
        self.subscription_engine = SubscriptionEngine.init(allocator);
        errdefer self.subscription_engine.deinit();

        // 6 Initialize Store Service
        self.store_service = StoreService.init(allocator, &self.storage_engine, &self.schema_manager);

        // 7. Initialize Handler and Manager
        try self.handler.init(allocator, &self.memory_strategy, &self.violation_tracker, &self.storage_engine, &self.store_service, &self.subscription_engine, &self.schema_manager, .{});
        errdefer self.handler.deinit();

        // 8. Initialize Connection Manager
        try self.connection_manager.init(allocator, &self.memory_strategy, &self.handler, &self.schema_manager);
        errdefer self.connection_manager.deinit();
    }

    pub fn deinit(self: *AppTestContext) void {
        // 1. Stop background activity (write worker) first
        self.storage_engine.deinit();

        // 2. Shut down subsystems
        self.connection_manager.deinit();

        // 4. Now safe to tear down subsystems that were needed for session teardown
        self.subscription_engine.deinit();
        self.handler.deinit();
        self.store_service.deinit();

        // 5. Cleanup remaining infrastructure
        self.schema_manager.deinit();
        self.test_context.deinit();
        self.violation_tracker.deinit();
        self.memory_strategy.deinit();
    }

    pub fn tableMetadata(self: *const AppTestContext, table_name: []const u8) !*const schema_manager.TableMetadata {
        return self.schema_manager.getTable(table_name) orelse error.UnknownTable;
    }

    pub fn table(self: *AppTestContext, table_name: []const u8) !sth.TableFixture {
        return .{
            .engine = &self.storage_engine,
            .metadata = try self.tableMetadata(table_name),
        };
    }

    pub fn insertNamed(
        self: *AppTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        columns: anytype,
    ) !void {
        const tbl = try self.table(table_name);
        try tbl.insertNamed(id, namespace, columns);
    }

    pub fn insertField(
        self: *AppTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: @import("storage_engine.zig").TypedValue,
    ) !void {
        const tbl = try self.table(table_name);
        try tbl.insertField(id, namespace, field, value);
    }

    pub fn insertText(
        self: *AppTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: []const u8,
    ) !void {
        try self.insertField(table_name, id, namespace, field, tth.valText(value));
    }

    pub fn insertInt(
        self: *AppTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: i64,
    ) !void {
        try self.insertField(table_name, id, namespace, field, tth.valInt(value));
    }

    /// Helper to open a test connection and return a scoped wrapper.
    /// This ensures the correct LIFO release order for test and manager references.
    pub fn openScopedConnection(self: *AppTestContext, ws: *WebSocket) !ScopedConnection {
        try self.connection_manager.onOpen(ws);
        const conn = try self.connection_manager.acquireConnection(ws.getConnId());
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
        owns_ws: bool = false,

        pub fn deinit(self: ScopedConnection) void {
            // 1. Manager drops its reference (removes from map, runs teardown)
            self.app.connection_manager.onClose(self.ws);

            // 2. Test drops its reference (may return to pool)
            if (self.conn.release()) {
                self.app.memory_strategy.releaseConnection(self.conn);
            }

            // 3. Free ws if we own it
            if (self.owns_ws) {
                self.app.allocator.destroy(self.ws);
            }
        }
    };

    /// High-level helper to completely create, open, and manage a mock connection for tests.
    pub fn setupMockConnection(self: *AppTestContext) !ScopedConnection {
        const ws = try self.allocator.create(WebSocket);
        ws.* = createMockWebSocket();
        try self.connection_manager.onOpen(ws);
        const conn = try self.connection_manager.acquireConnection(ws.getConnId());
        return ScopedConnection{
            .app = self,
            .ws = ws,
            .conn = conn,
            .owns_ws = true,
        };
    }

    /// Helper to simulate a graceful shutdown of all connections in a test environment.
    /// This calls ConnectionManager.closeAllConnections() and then manually triggers
    /// the onClose callbacks for all mock WebSockets, since the test environment
    /// lacks the asynchronous event loop that would normally handle this.
    pub fn closeAllConnections(self: *AppTestContext) void {
        self.connection_manager.closeAllConnections();

        // Pump onClose for all remaining connections in the manager.
        // We iterate and remove until empty to avoid concurrent modification issues.
        while (true) {
            const maybe_conn = blk: {
                self.connection_manager.mutex.lock();
                defer self.connection_manager.mutex.unlock();
                var it = self.connection_manager.map.valueIterator();
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
                self.connection_manager.onClose(&local_ws);
            } else {
                break;
            }
        }
    }
};
