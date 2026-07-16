const std = @import("std");
const Allocator = std.mem.Allocator;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const connection_manager = @import("connection/manager.zig");
const connection_violations = @import("connection/violations.zig");
const session_resolver = @import("authorization/session_resolver.zig");
const connection_state = @import("connection/state.zig");
const authentication_session = @import("authentication/session.zig");
const ConnectionManager = connection_manager.ConnectionManager;
const ViolationTracker = connection_violations.ConnectionViolationTracker;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const typed_doc_id = @import("typed/doc_id.zig");
const typed = @import("typed/types.zig");
const SessionResolver = session_resolver.SessionResolver;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const Connection = connection_state.Connection;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const send_queue_mod = @import("send_queue.zig");
const Session = authentication_session.Session;
const schema_types = @import("schema/types.zig");
const schema_mod_format = @import("schema/format.zig");
const schema_parse = @import("schema/parse.zig");
const Schema = schema_types.Schema;
const schema_helpers = @import("schema/test_helpers.zig");
pub const TableDef = schema_helpers.TableDef;
const msgpack = @import("msgpack_test_helpers.zig");
const msgpack_utils = @import("msgpack_utils.zig");
const StoreService = @import("store_service.zig").StoreService;
const PresenceManager = @import("presence/manager.zig").PresenceManager;
const wire_decode = @import("wire/decode.zig");
const wire_encode = @import("wire/encode.zig");
const wire_errors = @import("wire/errors.zig");
const sth = @import("storage_engine_test_helpers.zig");
const tth = @import("typed/test_helpers.zig");
const authorization_types = @import("authorization/types.zig");
const authorization_test_helpers = @import("authorization/test_helpers.zig");

/// Shared atomic counter for unique connection IDs in tests
var next_mock_ws_id = std.atomic.Value(u64).init(1);
var next_test_resolution_id = std.atomic.Value(u64).init(@as(u64, 1) << 62);

pub const test_external_user_id = "test-client";

pub fn createMockWebSocket(allocator: Allocator) WebSocket {
    return createMockWebSocketWithExternalId(allocator, test_external_user_id);
}

pub fn createMockWebSocketWithExternalId(allocator: Allocator, external_id: []const u8) WebSocket {
    return WebSocket{
        .ws = null,
        .ssl = false,
        .user_data = @ptrFromInt(next_mock_ws_id.fetchAdd(1, .monotonic)),
        .session = Session{
            .external_id = allocator.dupe(u8, external_id) catch @panic("OOM creating mock WebSocket"),
            .is_anonymous = false,
            .token_expires_at = std.time.timestamp() + 3600,
        },
    };
}

pub fn destroyMockWebSocket(allocator: Allocator, ws: *WebSocket) void {
    if (ws.session) |*sess| {
        sess.deinit(allocator);
        ws.session = null;
    }
}
/// Helper function to route a message through an arena and return a duped result for testing.
/// Errors on async (deferred) responses. The caller is responsible for freeing the returned []u8.
pub fn routeWithArena(handler: *MessageHandler, allocator: Allocator, conn: *Connection, bytes: []const u8) ![]u8 {
    const result = try routeWithArenaOptional(handler, allocator, conn, bytes);
    return result orelse error.TestAsyncResponseNotSupported;
}

/// Helper function to route a message through an arena and return a duped result for testing.
/// Returns null for async (deferred) responses. The caller is responsible for freeing the returned []u8.
pub fn routeWithArenaOptional(handler: *MessageHandler, allocator: Allocator, conn: *Connection, bytes: []const u8) !?[]u8 {
    const envelope = try wire_decode.extractEnvelopeFast(bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const result = (handler.routeMessageFast(arena_allocator, conn, envelope, bytes) catch |err| {
        const error_msg = try wire_encode.encodeError(arena_allocator, envelope.id, wire_errors.getWireError(err));
        return try allocator.dupe(u8, error_msg);
    }) orelse return null;

    return try allocator.dupe(u8, result);
}

pub fn encodePayloadToBytes(allocator: Allocator, payload: msgpack.Payload) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    defer list.deinit(allocator);
    try msgpack.encode(payload, list.writer(allocator));
    return list.toOwnedSlice(allocator);
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
    session_resolver: SessionResolver,
    subscription_engine: SubscriptionEngine,
    store_service: StoreService,
    presence_manager: PresenceManager,
    handler: MessageHandler,
    connection_manager: ConnectionManager,
    schema: Schema,
    auth_config: authorization_types.AuthConfig,
    test_context: schema_helpers.TestContext,
    test_resolution_mutex: std.Thread.Mutex,
    empty_claims: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, table_defs: []const schema_helpers.TableDef) !void {
        try self.initWithOptions(allocator, prefix, table_defs, .{ .in_memory = true, .reader_pool_size = 1 });
    }

    pub fn initWithOptions(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, table_defs: []const schema_helpers.TableDef, options: StorageEngine.Options) !void {
        const schema = try schema_helpers.createTestSchema(allocator, table_defs);
        try self.initWithSchemaAndOptions(allocator, prefix, schema, options);
    }

    pub fn initWithSchema(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, schema_value: Schema) !void {
        const json_text = try schema_mod_format.format(allocator, &schema_value);
        defer allocator.free(json_text);

        const schema = try schema_parse.initFromJson(allocator, json_text);
        // No errdefer here — ownership transfers to initWithSchemaAndOptions
        try self.initWithSchemaAndOptions(allocator, prefix, schema, .{ .in_memory = true, .reader_pool_size = 1 });
    }

    pub fn initWithSchemaJSON(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, json: []const u8) !void {
        const schema = try schema_parse.initFromJson(allocator, json);
        // No errdefer here — ownership transfers to initWithSchemaAndOptions
        try self.initWithSchemaAndOptions(allocator, prefix, schema, .{ .in_memory = true, .reader_pool_size = 1 });
    }

    pub fn initWithSchemaAndOptions(self: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, schema: Schema, options: StorageEngine.Options) !void {
        self.allocator = allocator;
        self.test_resolution_mutex = .{};
        self.schema = schema;
        errdefer self.schema.deinit();

        // 1. Initialize Memory Strategy
        try self.memory_strategy.init(allocator);
        errdefer _ = self.memory_strategy.deinit();

        const gpa = self.memory_strategy.generalAllocator();

        // 2. Initialize Violation Tracker
        self.violation_tracker.init(gpa, 10);
        errdefer self.violation_tracker.deinit();

        // 3. Initialize Schema Helpers TestContext
        self.test_context = if (options.in_memory)
            try schema_helpers.TestContext.initInMemory(gpa)
        else
            try schema_helpers.TestContext.init(gpa, prefix);
        errdefer self.test_context.deinit();

        // 4. Initialize Storage Engine
        try schema_helpers.setupTestEngine(&self.storage_engine, gpa, &self.memory_strategy, &self.test_context, &self.schema, options);
        errdefer self.storage_engine.deinit();

        // 5. Initialize Subscription Engine
        self.subscription_engine = SubscriptionEngine.init(gpa);
        errdefer self.subscription_engine.deinit();

        // 6. Initialize Auth Config
        self.auth_config = try authorization_test_helpers.permissiveTestConfig(gpa, &self.schema);
        errdefer self.auth_config.deinit();

        // 7. Initialize Store Service
        self.store_service = StoreService.init(gpa, &self.storage_engine, &self.schema, &self.auth_config);

        // 8. Initialize Presence Manager
        self.presence_manager.init(gpa, self.schema.presence_user_fields, self.schema.presence_shared_fields);

        // 9. Initialize Handler and Manager
        self.handler.init(gpa, &self.memory_strategy, &self.violation_tracker, &self.store_service, &self.presence_manager, &self.subscription_engine, .{}, &self.auth_config, &self.schema, null, &self.empty_claims);
        errdefer self.handler.deinit();

        // 9. Initialize Connection Manager
        try self.connection_manager.init(gpa, &self.memory_strategy, &self.handler, &self.schema, 100_000);
        errdefer self.connection_manager.deinit();

        // 10. Initialize Session Resolver
        self.session_resolver.init(gpa, &self.connection_manager, &self.memory_strategy);
        errdefer self.session_resolver.deinit();

        // 11. Wire session_resolver to storage engine for scope resolution
        self.storage_engine.setSessionResolver(&self.session_resolver);
    }

    pub fn deinit(self: *AppTestContext) void {
        // 1. Stop async session delivery before its storage buffer is released.
        self.session_resolver.deinit();

        // 2. Stop background activity (write worker)
        self.storage_engine.deinit();

        // 3. Shut down subsystems
        self.connection_manager.deinit();

        // 4. Now safe to tear down subsystems that were needed for session teardown
        self.subscription_engine.deinit();
        self.handler.deinit();
        self.store_service.deinit();

        // 5. Cleanup remaining infrastructure
        self.auth_config.deinit();
        self.schema.deinit();
        self.test_context.deinit();
        self.violation_tracker.deinit();
        std.debug.assert(self.memory_strategy.deinit() == .ok);
    }

    pub fn tableMetadata(self: *const AppTestContext, table_name: []const u8) !*const schema_types.Table {
        return self.schema.table(table_name) orelse error.UnknownTable;
    }

    pub fn tableIndex(self: *const AppTestContext, table_name: []const u8) usize {
        const md = self.schema.table(table_name) orelse std.debug.panic("test schema missing table '{s}'", .{table_name});
        return md.index;
    }

    pub fn fieldIndex(self: *const AppTestContext, table_name: []const u8, field_name: []const u8) usize {
        const tbl = self.schema.table(table_name) orelse std.debug.panic("test schema missing table '{s}'", .{table_name});
        return tbl.fieldIndex(field_name) orelse std.debug.panic("test schema table '{s}' missing field '{s}'", .{ table_name, field_name });
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
        id: typed_doc_id.DocId,
        namespace_id: i64,
        columns: anytype,
    ) !void {
        const tbl = try self.table(table_name);
        try tbl.insertNamed(id, namespace_id, columns);
    }

    pub fn insertField(
        self: *AppTestContext,
        table_name: []const u8,
        id: typed_doc_id.DocId,
        namespace_id: i64,
        field: []const u8,
        value: typed.Value,
    ) !void {
        const tbl = try self.table(table_name);
        try tbl.insertField(id, namespace_id, field, value);
    }

    pub fn insertText(
        self: *AppTestContext,
        table_name: []const u8,
        id: typed_doc_id.DocId,
        namespace_id: i64,
        field: []const u8,
        value: []const u8,
    ) !void {
        try self.insertField(table_name, id, namespace_id, field, tth.valText(value));
    }

    pub fn insertInt(
        self: *AppTestContext,
        table_name: []const u8,
        id: typed_doc_id.DocId,
        namespace_id: i64,
        field: []const u8,
        value: i64,
    ) !void {
        try self.insertField(table_name, id, namespace_id, field, tth.valInt(value));
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

    pub fn resolveStoreScopeForTest(
        self: *AppTestContext,
        namespace: []const u8,
        external_user_id: []const u8,
    ) !StoreService.ScopedSession {
        self.test_resolution_mutex.lock();
        defer self.test_resolution_mutex.unlock();

        if (try self.store_service.tryResolveScopeCached(namespace, external_user_id)) |scope| {
            return scope;
        }

        const mock_conn = try self.memory_strategy.acquireConnection();
        defer if (mock_conn.release()) self.memory_strategy.releaseConnection(mock_conn);

        const resolution_id = next_test_resolution_id.fetchAdd(1, .monotonic);
        const msg_id = resolution_id +% 1;

        mock_conn.id = resolution_id;
        mock_conn.ref_count.store(1, .release);

        // Use mock_conn.allocator (pool's GPA) for strings that the connection will own/free
        const external_id_dupe = try mock_conn.allocator.dupe(u8, external_user_id);
        var external_id_transferred = false;
        errdefer if (!external_id_transferred) mock_conn.allocator.free(external_id_dupe);
        mock_conn.setSession(.{
            .external_id = external_id_dupe,
            .is_anonymous = false,
            .token_expires_at = std.time.timestamp() + 3600,
        });
        external_id_transferred = true;

        self.connection_manager.mutex.lock();
        try self.connection_manager.map.put(self.connection_manager.allocator, mock_conn.id, mock_conn);
        self.connection_manager.mutex.unlock();
        defer {
            self.connection_manager.mutex.lock();
            _ = self.connection_manager.map.remove(mock_conn.id);
            self.connection_manager.mutex.unlock();
        }

        // Dupe namespace using mock_conn.allocator since beginStoreScopeResolutionLocked
        // will store the pointer and resetStoreScopeLocked will free it later.
        const namespace_dupe = try mock_conn.allocator.dupe(u8, namespace);
        mock_conn.beginStoreScopeResolutionLocked(namespace_dupe);
        const scope_seq = mock_conn.scope_seq;

        try self.store_service.enqueueResolveScope(mock_conn.id, msg_id, scope_seq, namespace, external_user_id, false);
        try self.storage_engine.flushPendingWrites();

        var matched_entry: ?send_queue_mod.Entry = null;
        while (self.test_context.send_queue.?.pop()) |entry| {
            if (entry.conn_id == mock_conn.id) {
                if (matched_entry != null) {
                    // Unexpected multiple results. Deinit both and fail.
                    if (matched_entry) |m| m.deinit();
                    entry.deinit();
                    return error.TestUnexpectedSessionResolutionResult;
                }
                matched_entry = entry;
            } else {
                entry.deinit();
            }
        }
        defer if (matched_entry) |entry| entry.deinit();

        if (mock_conn.store_ready) {
            const session = mock_conn.getStoreSession();
            return .{
                .namespace_id = session.namespace_id,
                .user_doc_id = session.user_doc_id,
            };
        }

        return error.TestExpectedValue;
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
                self.app.memory_strategy.generalAllocator().destroy(self.ws);
            }
        }
    };

    /// High-level helper to completely create, open, and manage a mock connection for tests.
    pub fn setupMockConnection(self: *AppTestContext) !ScopedConnection {
        const gpa = self.memory_strategy.generalAllocator();
        const ws = try gpa.create(WebSocket);
        errdefer gpa.destroy(ws);

        ws.* = createMockWebSocket(gpa);
        try self.connection_manager.onOpen(ws);
        errdefer self.connection_manager.onClose(ws);

        const conn = try self.connection_manager.acquireConnection(ws.getConnId());
        errdefer {
            if (conn.release()) {
                self.memory_strategy.releaseConnection(conn);
            }
        }

        const namespace = "public";
        const scope = try self.resolveStoreScopeForTest(namespace, test_external_user_id);
        try conn.setStoreScopeForNamespace(namespace, scope.namespace_id, scope.user_doc_id);

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
