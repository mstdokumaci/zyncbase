const std = @import("std");

pub const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
pub const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
pub const MessageType = @import("uwebsockets_wrapper.zig").MessageType;

const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const CheckpointManager = @import("checkpoint_manager.zig").CheckpointManager;
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Config = @import("config_loader.zig").Config;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const WriteCoordinator = @import("write_coordinator.zig").WriteCoordinator;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const SchemaParser = @import("schema_parser.zig").SchemaParser;
const schema_parser = @import("schema_parser.zig");
const DDLGenerator = @import("ddl_generator.zig").DDLGenerator;
const MigrationDetector = @import("migration_detector.zig").MigrationDetector;
const MigrationExecutor = @import("migration_executor.zig").MigrationExecutor;
pub const uws_c = @import("uwebsockets_wrapper.zig").c;

// Global server reference for signal handlers
var global_server: ?*ZyncBaseServer = null;

/// ZyncBaseServer integrates all components to create a complete real-time database server
pub const ZyncBaseServer = struct {
    allocator: std.mem.Allocator,
    config: Config,
    memory_strategy: *MemoryStrategy,
    violation_tracker: *ViolationTracker,
    subscription_engine: *SubscriptionEngine,
    checkpoint_manager: *CheckpointManager,
    storage_layer: *CheckpointManager.StorageLayer,
    storage_engine: *StorageEngine,
    write_coordinator: *WriteCoordinator,
    websocket_server: *WebSocketServer,
    connection_manager: *ConnectionManager,
    message_handler: *MessageHandler,
    shutdown_requested: std.atomic.Value(bool),
    /// Loaded schema (owned).
    loaded_schema: schema_parser.Schema,
    /// Parser used to free loaded_schema on deinit.
    schema_parser_instance: SchemaParser,
    schema_loaded: bool = false,
    shutdown_mutex: std.Thread.Mutex = .{},
    shutdown_performed: bool = false,

    /// Initialize the ZyncBase server with all components
    pub fn init(allocator: std.mem.Allocator, custom_config_path: ?[]const u8) !*ZyncBaseServer {
        return initDetailed(allocator, null, null, null, custom_config_path);
    }

    /// Initialize the ZyncBase server with optional custom configuration and data directory
    pub fn initDetailed(
        allocator: std.mem.Allocator,
        custom_config: ?Config,
        custom_data_dir: ?[]const u8,
        custom_schema_file: ?[]const u8,
        custom_config_path: ?[]const u8,
    ) !*ZyncBaseServer {
        const self = try allocator.create(ZyncBaseServer);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.schema_loaded = false;

        // Initialize memory strategy
        const memory_strategy = try allocator.create(MemoryStrategy);
        errdefer allocator.destroy(memory_strategy);
        try memory_strategy.init(allocator);
        errdefer memory_strategy.deinit();

        // Load configuration or use provided one
        var config = if (custom_config) |c| c else blk: {
            const path = custom_config_path orelse "zyncbase-config.json";
            break :blk ConfigLoader.load(memory_strategy.generalAllocator(), path) catch |err| {
                std.log.warn("Failed to load config from {s}, using defaults: {}", .{ path, err });
                break :blk try ConfigLoader.loadDefaults(memory_strategy.generalAllocator());
            };
        };
        errdefer {
            config.deinit();
        }

        // Override data_dir if provided
        if (custom_data_dir) |dir| {
            memory_strategy.generalAllocator().free(config.data_dir);
            config.data_dir = try memory_strategy.generalAllocator().dupe(u8, dir);
        }

        // Override schema_file if provided
        if (custom_schema_file) |file| {
            memory_strategy.generalAllocator().free(config.schema_file);
            config.schema_file = try memory_strategy.generalAllocator().dupe(u8, file);
        }

        // Initialize violation tracker
        std.log.debug("Initializing violation tracker", .{});
        const violation_tracker = try allocator.create(ViolationTracker);
        errdefer allocator.destroy(violation_tracker);
        violation_tracker.init(
            memory_strategy.generalAllocator(),
            config.security.violation_threshold,
        );
        errdefer violation_tracker.deinit();

        // Initialize subscription engine
        std.log.debug("Initializing subscription engine", .{});
        const subscription_engine = try allocator.create(SubscriptionEngine);
        errdefer allocator.destroy(subscription_engine);
        subscription_engine.* = SubscriptionEngine.init(
            memory_strategy.generalAllocator(),
        );
        errdefer subscription_engine.deinit();

        const schema_path = config.schema_file;
        {
            std.log.info("Loading schema from: {s}", .{schema_path});
            const json_text = std.fs.cwd().readFileAlloc(
                memory_strategy.generalAllocator(),
                schema_path,
                10 * 1024 * 1024,
            ) catch |err| {
                std.log.err("Failed to read schema file '{s}': {}", .{ schema_path, err });
                return err;
            };
            defer memory_strategy.generalAllocator().free(json_text);

            var parser = SchemaParser.init(memory_strategy.generalAllocator());
            const schema = parser.parse(json_text) catch |err| {
                std.log.err("Failed to parse schema file '{s}': {}", .{ schema_path, err });
                return err;
            };
            errdefer parser.deinit(schema);
            self.loaded_schema = schema;
            self.schema_parser_instance = parser;
            self.schema_loaded = true;
        }

        // Initialize storage engine, which now requires a schema
        std.log.debug("Initializing storage engine with data_dir: {s}", .{config.data_dir});
        const storage_engine = try StorageEngine.init(
            memory_strategy.generalAllocator(),
            memory_strategy,
            config.data_dir,
            &self.loaded_schema,
            config.performance,
            .{},
        );
        errdefer storage_engine.deinit();

        // Run migrations and DDL
        {
            const schema_ptr = &self.loaded_schema;
            // Apply DDL for each table
            var gen = DDLGenerator.init(memory_strategy.generalAllocator());
            for (schema_ptr.tables) |table| {
                const ddl = try gen.generateDDL(table);
                defer memory_strategy.generalAllocator().free(ddl);
                const ddl_z = try memory_strategy.generalAllocator().dupeZ(u8, ddl);
                defer memory_strategy.generalAllocator().free(ddl_z);
                storage_engine.writer_conn.execMulti(ddl_z, .{}) catch |err| {
                    std.log.err("Failed to apply DDL for table '{s}': {}", .{ table.name, err });
                    return err;
                };
            }

            // Detect and execute migrations
            var detector = MigrationDetector.init(memory_strategy.generalAllocator(), &storage_engine.writer_conn);
            const plan = try detector.detectChanges(schema_ptr.*);
            defer detector.deinit(plan);

            if (plan.changes.len > 0) {
                std.log.info("Applying {} schema migration(s)", .{plan.changes.len});
                var executor = MigrationExecutor.init(
                    memory_strategy.generalAllocator(),
                    &storage_engine.writer_conn,
                    &gen,
                    .{},
                );
                executor.execute(plan, schema_ptr.*) catch |err| {
                    std.log.err("Schema migration failed: {}", .{err});
                    return err;
                };
            }
        }

        // Get storage layer for checkpoint manager
        std.log.debug("Getting storage layer", .{});
        const storage_layer = try storage_engine.getStorageLayer();
        errdefer storage_layer.deinit();

        // Initialize checkpoint manager
        std.log.debug("Initializing checkpoint manager", .{});
        const checkpoint_manager = try CheckpointManager.init(
            memory_strategy.generalAllocator(),
            storage_layer,
            .{}, // Use default config
        );
        errdefer checkpoint_manager.deinit();

        // Initialize WebSocket server
        std.log.debug("Initializing WebSocket server", .{});
        const websocket_server = try WebSocketServer.init(
            memory_strategy.generalAllocator(),
            .{
                .port = config.server.port,
                .host = config.server.host,
            },
        );
        errdefer websocket_server.deinit();

        // Initialize Write Coordinator
        const write_coordinator = try WriteCoordinator.init(
            memory_strategy.generalAllocator(),
            storage_engine,
            subscription_engine,
            memory_strategy,
        );
        errdefer write_coordinator.deinit();

        const message_handler = try MessageHandler.init(
            memory_strategy.generalAllocator(),
            memory_strategy,
            violation_tracker,
            storage_engine,
            subscription_engine,
            write_coordinator,
            config.security,
        );
        errdefer message_handler.deinit();

        // Initialize connection manager
        std.log.debug("Initializing connection manager", .{});
        const connection_manager = try ConnectionManager.init(
            memory_strategy.generalAllocator(),
            memory_strategy,
            message_handler,
        );
        errdefer connection_manager.deinit();

        message_handler.setConnectionManager(@ptrCast(connection_manager));
        write_coordinator.setConnectionManager(connection_manager);

        std.log.debug("Setting up ZyncBaseServer struct", .{});

        self.config = config;
        self.memory_strategy = memory_strategy;
        self.violation_tracker = violation_tracker;
        self.subscription_engine = subscription_engine;
        self.checkpoint_manager = checkpoint_manager;
        self.storage_layer = storage_layer;
        self.storage_engine = storage_engine;
        self.write_coordinator = write_coordinator;
        self.websocket_server = websocket_server;
        self.connection_manager = connection_manager;
        self.message_handler = message_handler;
        self.shutdown_performed = false;
        self.shutdown_mutex = .{};
        self.shutdown_requested = std.atomic.Value(bool).init(false);

        return self;
    }

    /// Start the server and run the event loop
    pub fn start(self: *ZyncBaseServer) !void {
        std.log.info("Starting ZyncBase server on {s}:{d}", .{
            self.config.server.host,
            self.config.server.port,
        });

        // Register WebSocket handlers with server as user data
        self.websocket_server.registerWebSocketHandlers(
            "/*",
            .{
                .on_open = onWebSocketOpen,
                .on_message = onWebSocketMessage,
                .on_close = onWebSocketClose,
            },
            self,
        );

        // Start checkpoint manager background thread
        try self.checkpoint_manager.startBackgroundLoop();

        // Setup signal handlers for graceful shutdown (signal-safe)
        try self.setupSignalHandlers();

        // Start listening on configured port
        try self.websocket_server.listen(self.config.server.port);

        std.log.info("Server started successfully", .{});

        // Run event loop (blocks until shutdown signal or close)
        self.websocket_server.run();

        // Arrive here after the event loop exits (graceful or forced)
        // Check if we need to perform graceful shutdown
        try self.shutdown();
    }

    /// Initiate graceful shutdown of the server.
    /// SAFE to call multiple times, but will only perform logic once.
    /// Safe to call from main thread after start() returns.
    pub fn shutdown(self: *ZyncBaseServer) !void {
        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();
        if (self.shutdown_performed) return;
        self.shutdown_performed = true;

        std.log.info("Initiating graceful shutdown", .{});

        // Set shutdown flag
        self.shutdown_requested.store(true, .release);
        uws_c.set_bun_is_exiting(1);

        // Stop background checkpoint loop
        self.checkpoint_manager.stop();

        // Stop accepting new connections
        self.websocket_server.close();

        // Close all active connections
        self.connection_manager.closeAllConnections();

        // Flush pending writes
        try self.storage_engine.flushPendingWrites();

        // Perform final checkpoint
        _ = try self.checkpoint_manager.performCheckpoint(.full);

        std.log.info("Graceful shutdown complete", .{});
    }

    /// Setup signal handlers for SIGTERM and SIGINT
    fn setupSignalHandlers(self: *ZyncBaseServer) !void {
        // Store global reference for signal handler
        global_server = self;

        // Setup SIGTERM handler
        const sigterm_action = std.posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &sigterm_action, null);

        // Setup SIGINT handler
        const sigint_action = std.posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &sigint_action, null);
    }

    /// Deinitialize the server and free all resources
    pub fn deinit(self: *ZyncBaseServer) void {
        std.log.debug("ZyncBaseServer.deinit() called", .{});

        // Deinitialize components in reverse order
        std.log.debug("Deinitializing connection_manager", .{});
        self.connection_manager.deinit();
        std.log.debug("Deinitializing message_handler", .{});
        self.message_handler.deinit();
        std.log.debug("Deinitializing write_coordinator", .{});
        self.write_coordinator.deinit();
        std.log.debug("Deinitializing websocket_server", .{});
        self.websocket_server.deinit();
        std.log.debug("Deinitializing checkpoint_manager", .{});
        self.checkpoint_manager.deinit();
        std.log.debug("Deinitializing storage_layer", .{});
        self.storage_layer.deinit();
        std.log.debug("Deinitializing storage_engine", .{});
        self.storage_engine.deinit();
        std.log.debug("Deinitializing subscription_engine", .{});
        self.subscription_engine.deinit();
        self.allocator.destroy(self.subscription_engine);
        std.log.debug("Deinitializing violation_tracker", .{});
        self.violation_tracker.deinit();
        self.allocator.destroy(self.violation_tracker);
        // Free config - need to use pointer to field
        std.log.debug("About to deinit config", .{});
        var config_ptr = &self.config;
        config_ptr.deinit();
        std.log.debug("config deinitialized", .{});

        // Free loaded schema if present before destroying the allocator it uses
        if (self.schema_loaded) {
            self.schema_parser_instance.deinit(self.loaded_schema);
        }

        std.log.debug("Deinitializing memory_strategy", .{});
        self.memory_strategy.deinit();
        std.log.debug("About to destroy memory_strategy", .{});
        self.allocator.destroy(self.memory_strategy);
        std.log.debug("memory_strategy destroyed", .{});

        std.log.debug("About to destroy self", .{});
        self.allocator.destroy(self);
        std.log.debug("self destroyed", .{});
    }
};

/// Signal handler for SIGTERM and SIGINT
/// ASYNC-SIGNAL-SAFE: only sets atomic flag and wakes event loop
fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    if (global_server) |server| {
        server.shutdown_requested.store(true, .release);
        server.websocket_server.close();
    }
}

fn onWebSocketOpen(ws: *WebSocket, user_data: ?*anyopaque) void {
    const server: *ZyncBaseServer = @ptrCast(@alignCast(user_data.?));
    server.connection_manager.onOpen(ws) catch |err| {
        std.log.err("Error handling WebSocket open: {}", .{err});
    };
}

fn onWebSocketMessage(
    ws: *WebSocket,
    message: []const u8,
    msg_type: MessageType,
    user_data: ?*anyopaque,
) void {
    const server: *ZyncBaseServer = @ptrCast(@alignCast(user_data.?));
    server.connection_manager.onMessage(ws, message, msg_type);
}

fn onWebSocketClose(
    ws: *WebSocket,
    code: i32,
    message: []const u8,
    user_data: ?*anyopaque,
) void {
    const server: *ZyncBaseServer = @ptrCast(@alignCast(user_data.?));
    server.connection_manager.onClose(ws, code, message);
}
