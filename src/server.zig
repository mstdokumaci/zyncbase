const std = @import("std");

pub const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
pub const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
pub const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
pub const MessageType = @import("uwebsockets_wrapper.zig").MessageType;

const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const CheckpointManager = @import("checkpoint_manager.zig").CheckpointManager;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Config = @import("config_loader.zig").Config;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const MessageHandler = @import("message_handler.zig").MessageHandler;
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
    cache: *LockFreeCache,
    violation_tracker: *ViolationTracker,
    subscription_manager: *SubscriptionManager,
    checkpoint_manager: *CheckpointManager,
    storage_layer: *CheckpointManager.StorageLayer,
    request_handler: RequestHandler,
    storage_engine: *StorageEngine,
    websocket_server: *WebSocketServer,
    message_handler: *MessageHandler,
    checkpoint_thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool),
    /// Loaded schema (owned).
    loaded_schema: schema_parser.Schema = undefined,
    /// Parser used to free loaded_schema on deinit.
    schema_parser_instance: SchemaParser = undefined,
    schema_loaded: bool = false,

    /// Initialize the ZyncBase server with all components
    pub fn init(allocator: std.mem.Allocator) !*ZyncBaseServer {
        return initDetailed(allocator, null, null, null);
    }

    /// Initialize the ZyncBase server with optional custom configuration and data directory
    pub fn initDetailed(
        allocator: std.mem.Allocator,
        custom_config: ?Config,
        custom_data_dir: ?[]const u8,
        custom_schema_file: ?[]const u8,
    ) !*ZyncBaseServer {
        const self = try allocator.create(ZyncBaseServer);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.checkpoint_thread = null;
        self.schema_loaded = false;

        // Initialize memory strategy
        const memory_strategy = try allocator.create(MemoryStrategy);
        errdefer allocator.destroy(memory_strategy);
        memory_strategy.* = try MemoryStrategy.init();
        errdefer memory_strategy.deinit();

        // Load configuration or use provided one
        var config = if (custom_config) |c| c else blk: {
            const path = "zyncbase-config.json";
            break :blk ConfigLoader.load(memory_strategy.generalAllocator(), path) catch |err| {
                std.log.warn("Failed to load config, using defaults: {}", .{err});
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

        // Initialize LockFreeCache
        std.log.debug("Initializing LockFreeCache", .{});
        const cache = try LockFreeCache.init(
            memory_strategy.generalAllocator(),
            .{},
        );
        errdefer cache.deinit();

        // Initialize violation tracker
        std.log.debug("Initializing violation tracker", .{});
        const violation_tracker = try allocator.create(ViolationTracker);
        errdefer allocator.destroy(violation_tracker);
        violation_tracker.* = ViolationTracker.init(
            memory_strategy.generalAllocator(),
            config.security.violation_threshold,
        );
        errdefer violation_tracker.deinit();

        // Initialize subscription manager
        std.log.debug("Initializing subscription manager", .{});
        const subscription_manager = try SubscriptionManager.init(
            memory_strategy.generalAllocator(),
        );
        errdefer subscription_manager.deinit();

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
            config.data_dir,
            &self.loaded_schema,
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

        // Initialize request handler
        std.log.debug("Initializing request handler", .{});
        var request_handler = RequestHandler.init(memory_strategy);

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

        // Initialize message handler
        std.log.debug("Initializing message handler", .{});
        const message_handler = try MessageHandler.init(
            memory_strategy.generalAllocator(),
            violation_tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        errdefer message_handler.deinit();

        std.log.debug("Setting up ZyncBaseServer struct", .{});

        self.config = config;
        self.memory_strategy = memory_strategy;
        self.cache = cache;
        self.violation_tracker = violation_tracker;
        self.subscription_manager = subscription_manager;
        self.checkpoint_manager = checkpoint_manager;
        self.storage_layer = storage_layer;
        self.request_handler = request_handler;
        self.storage_engine = storage_engine;
        self.websocket_server = websocket_server;
        self.message_handler = message_handler;
        self.shutdown_requested = std.atomic.Value(bool).init(false);

        // Wire request_handler pointer into message_handler since it was passed from our stack
        self.message_handler.request_handler = &self.request_handler;

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
        self.checkpoint_thread = try self.checkpoint_manager.startBackgroundLoop();

        // Setup signal handlers for graceful shutdown
        try self.setupSignalHandlers();

        // Start listening on configured port
        try self.websocket_server.listen(self.config.server.port);

        std.log.info("Server started successfully", .{});

        // Run event loop (blocks until shutdown)
        self.websocket_server.run();
    }

    /// Initiate graceful shutdown of the server
    pub fn shutdown(self: *ZyncBaseServer) !void {
        std.log.info("Initiating graceful shutdown", .{});

        // Set shutdown flag
        self.shutdown_requested.store(true, .release);
        uws_c.set_bun_is_exiting(1);

        // Stop background checkpoint loop
        self.checkpoint_manager.stop();

        // Stop accepting new connections
        self.websocket_server.close();

        // Close all active connections
        try self.message_handler.closeAllConnections();

        // Wake up the event loop to ensure it notices the closed handles
        if (uws_c.uws_get_loop()) |loop| {
            uws_c.us_wakeup_loop(loop);
        }

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

        // Stop checkpoint thread if running
        if (self.checkpoint_thread) |thread| {
            thread.join();
        }

        // Deinitialize components in reverse order
        std.log.debug("Deinitializing message_handler", .{});
        self.message_handler.deinit();
        std.log.debug("Deinitializing websocket_server", .{});
        self.websocket_server.deinit();
        std.log.debug("Deinitializing checkpoint_manager", .{});
        self.checkpoint_manager.deinit();
        std.log.debug("Deinitializing storage_layer", .{});
        self.storage_layer.deinit();
        std.log.debug("Deinitializing storage_engine", .{});
        self.storage_engine.deinit();
        std.log.debug("Deinitializing subscription_manager", .{});
        self.subscription_manager.deinit();
        std.log.debug("Deinitializing violation_tracker", .{});
        self.violation_tracker.deinit();
        self.allocator.destroy(self.violation_tracker);
        std.log.debug("Deinitializing cache", .{});
        self.cache.deinit();
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
fn handleSignal(sig: c_int) callconv(.c) void {
    std.log.info("Received signal {d}, initiating shutdown", .{sig});

    if (global_server) |server| {
        server.shutdown() catch |err| {
            std.log.err("Error during shutdown: {}", .{err});
        };
    }
}

fn onWebSocketOpen(ws: *WebSocket, user_data: ?*anyopaque) void {
    const server = @as(*ZyncBaseServer, @ptrCast(@alignCast(user_data.?)));
    server.message_handler.handleOpen(ws) catch |err| {
        std.log.err("Error handling WebSocket open: {}", .{err});
    };
}

fn onWebSocketMessage(
    ws: *WebSocket,
    message: []const u8,
    msg_type: MessageType,
    user_data: ?*anyopaque,
) void {
    const server = @as(*ZyncBaseServer, @ptrCast(@alignCast(user_data.?)));
    server.message_handler.handleMessage(ws, message, msg_type) catch |err| {
        std.log.err("Error handling WebSocket message: {}", .{err});
    };
}

fn onWebSocketClose(
    ws: *WebSocket,
    code: i32,
    message: []const u8,
    user_data: ?*anyopaque,
) void {
    const server = @as(*ZyncBaseServer, @ptrCast(@alignCast(user_data.?)));
    server.message_handler.handleClose(ws, code, message) catch |err| {
        std.log.err("Error handling WebSocket close: {}", .{err});
    };
}
