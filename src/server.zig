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
const NotificationDispatcher = @import("notification_dispatcher.zig").NotificationDispatcher;
const SessionResolver = @import("session_resolver.zig").SessionResolver;
const ConnectionManager = @import("connection_manager.zig").ConnectionManager;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const authorization = @import("authorization.zig");
const DDLGenerator = @import("ddl_generator.zig").DDLGenerator;
const MigrationDetector = @import("migration_detector.zig").MigrationDetector;
const MigrationExecutor = @import("migration_executor.zig").MigrationExecutor;
const StoreService = @import("store_service.zig").StoreService;
pub const uws_c = @import("uwebsockets_wrapper.zig").c;

// Global server reference for signal handlers
var global_server: ?*ZyncBaseServer = null;

/// ZyncBaseServer integrates all components to create a complete real-time database server
pub const ZyncBaseServer = struct {
    allocator: std.mem.Allocator,
    config: Config,
    memory_strategy: MemoryStrategy,
    violation_tracker: ViolationTracker,
    subscription_engine: SubscriptionEngine,
    checkpoint_manager: CheckpointManager,
    storage_engine: StorageEngine,
    notification_dispatcher: NotificationDispatcher,
    session_resolver: SessionResolver,
    websocket_server: WebSocketServer,
    connection_manager: ConnectionManager,
    store_service: StoreService,
    message_handler: MessageHandler,
    shutdown_requested: std.atomic.Value(bool),
    schema_manager: Schema,
    auth_config: authorization.AuthConfig,
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
        // schema_manager will be initialized later

        // Initialize memory strategy
        try self.memory_strategy.init(allocator);
        errdefer self.memory_strategy.deinit();

        // Load configuration or use provided one
        var config = if (custom_config) |c| c else blk: {
            const path = custom_config_path orelse "zyncbase-config.json";
            break :blk ConfigLoader.load(self.memory_strategy.generalAllocator(), path) catch |err| {
                std.log.warn("Failed to load config from {s}, using defaults: {}", .{ path, err });
                break :blk try ConfigLoader.loadDefaults(self.memory_strategy.generalAllocator());
            };
        };
        errdefer {
            config.deinit();
        }

        // Override data_dir if provided
        if (custom_data_dir) |dir| {
            self.memory_strategy.generalAllocator().free(config.data_dir);
            config.data_dir = try self.memory_strategy.generalAllocator().dupe(u8, dir);
        }

        // Override schema_file if provided
        if (custom_schema_file) |file| {
            self.memory_strategy.generalAllocator().free(config.schema_file);
            config.schema_file = try self.memory_strategy.generalAllocator().dupe(u8, file);
        }

        // Initialize violation tracker
        std.log.debug("Initializing violation tracker", .{});
        self.violation_tracker.init(
            self.memory_strategy.generalAllocator(),
            config.security.violation_threshold,
        );
        errdefer self.violation_tracker.deinit();

        // Initialize subscription engine
        std.log.debug("Initializing subscription engine", .{});
        self.subscription_engine = SubscriptionEngine.init(
            self.memory_strategy.generalAllocator(),
        );

        {
            const json_text = if (config.schema_content) |content|
                content
            else blk: {
                const schema_path = config.schema_file;
                std.log.info("Loading schema from: {s}", .{schema_path});
                const loaded = std.fs.cwd().readFileAlloc(
                    self.memory_strategy.generalAllocator(),
                    schema_path,
                    10 * 1024 * 1024,
                ) catch |err| {
                    if (err == error.FileNotFound) {
                        std.log.info("Schema file '{s}' not found, using implicit users-only schema", .{schema_path});
                        break :blk schema_mod.implicit_users_schema_json;
                    }
                    std.log.err("Failed to read schema file '{s}': {}", .{ schema_path, err });
                    return err;
                };
                break :blk loaded;
            };
            defer if (config.schema_content == null and json_text.ptr != schema_mod.implicit_users_schema_json.ptr) self.memory_strategy.generalAllocator().free(json_text);

            self.schema_manager = try Schema.init(self.memory_strategy.generalAllocator(), json_text);
            errdefer self.schema_manager.deinit();
        }

        auth_init: {
            if (config.authorization_file) |file| {
                const auth_json = std.fs.cwd().readFileAlloc(
                    self.memory_strategy.generalAllocator(),
                    file,
                    1 * 1024 * 1024,
                ) catch |err| {
                    if (err == error.FileNotFound) {
                        std.log.info("Auth file '{s}' not found, using implicit defaults", .{file});
                        self.auth_config = try authorization.implicitConfig(self.memory_strategy.generalAllocator(), &self.schema_manager);
                        break :auth_init;
                    }
                    return err;
                };
                self.auth_config = try authorization.AuthConfig.init(self.memory_strategy.generalAllocator(), auth_json, &self.schema_manager);
                self.memory_strategy.generalAllocator().free(auth_json);
            } else {
                self.auth_config = try authorization.implicitConfig(self.memory_strategy.generalAllocator(), &self.schema_manager);
            }
            errdefer self.auth_config.deinit();
        }

        // Initialize storage engine, which now requires a schema and notification callbacks
        std.log.debug("Initializing storage engine with data_dir: {s}", .{config.data_dir});
        try self.storage_engine.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            config.data_dir,
            &self.schema_manager,
            config.performance,
            .{},
            storageEngineWakeup,
            self,
        );
        errdefer self.storage_engine.deinit();

        // Run migrations and DDL
        {
            const schema_ptr = &self.schema_manager;
            // Apply DDL for each table
            var gen = DDLGenerator.init(self.memory_strategy.generalAllocator());
            for (schema_ptr.tables) |table| {
                const ddl = try gen.generateDDL(table);
                defer self.memory_strategy.generalAllocator().free(ddl);
                const ddl_z = try self.memory_strategy.generalAllocator().dupeZ(u8, ddl);
                defer self.memory_strategy.generalAllocator().free(ddl_z);
                try self.storage_engine.execSetupSQL(ddl_z);
            }

            // Detect and execute migrations
            const setup_conn = try self.storage_engine.getSetupConn();
            var detector = MigrationDetector.init(self.memory_strategy.generalAllocator(), setup_conn, schema_ptr);
            const plan = try detector.detectChanges(schema_ptr);
            defer detector.deinit(plan);

            if (plan.changes.len > 0) {
                std.log.info("Applying {} schema migration(s)", .{plan.changes.len});
                var executor = MigrationExecutor.init(
                    self.memory_strategy.generalAllocator(),
                    setup_conn,
                    &gen,
                    .{},
                );
                executor.execute(plan, schema_ptr.version) catch |err| {
                    std.log.err("Schema migration failed: {}", .{err});
                    return err;
                };
            }

            // Lock the engine and start the runtime thread
            try self.storage_engine.start();
        }

        // Initialize checkpoint manager
        std.log.debug("Initializing checkpoint manager", .{});
        try self.checkpoint_manager.init(
            self.memory_strategy.generalAllocator(),
            &self.storage_engine,
            .{}, // Use default config
        );
        errdefer self.checkpoint_manager.deinit();

        // Initialize WebSocket server
        std.log.debug("Initializing WebSocket server", .{});
        try self.websocket_server.init(
            self.memory_strategy.generalAllocator(),
            .{
                .port = config.server.port,
                .host = config.server.host,
            },
        );
        errdefer self.websocket_server.deinit();

        self.store_service = StoreService.init(
            self.memory_strategy.generalAllocator(),
            &self.storage_engine,
            &self.schema_manager,
            &self.auth_config,
        );

        self.message_handler.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.violation_tracker,
            &self.store_service,
            &self.subscription_engine,
            config.security,
            &self.auth_config,
            &self.schema_manager,
        );
        errdefer self.message_handler.deinit();

        // Initialize connection manager
        std.log.debug("Initializing connection manager", .{});
        try self.connection_manager.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.message_handler,
            &self.schema_manager,
        );
        errdefer self.connection_manager.deinit();

        // Initialize Notification Dispatcher
        try self.notification_dispatcher.init(
            self.memory_strategy.generalAllocator(),
            self.storage_engine.changeBuffer(),
            &self.subscription_engine,
            &self.memory_strategy,
            &self.schema_manager,
        );
        errdefer self.notification_dispatcher.deinit();

        self.session_resolver.init(
            self.memory_strategy.generalAllocator(),
            self.storage_engine.sessionResolutionBuffer(),
            &self.memory_strategy,
        );
        errdefer self.session_resolver.deinit();

        // Wire Notification Dispatcher hook into WebSocket Server
        self.websocket_server.post_handler = notifyPostHandler;
        self.websocket_server.post_handler_ctx = self;

        std.log.debug("Setting up ZyncBaseServer state", .{});

        self.config = config;
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

        // Perform final checkpoint with retry for transient failures
        _ = try self.checkpoint_manager.performCheckpointWithRetry(.full, 5);

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

        std.log.debug("Deinitializing store_service", .{});
        self.store_service.deinit();

        std.log.debug("Deinitializing session_resolver", .{});
        self.session_resolver.deinit();

        std.log.debug("Deinitializing notification_dispatcher", .{});
        self.notification_dispatcher.deinit();

        std.log.debug("Deinitializing websocket_server", .{});
        self.websocket_server.deinit();

        std.log.debug("Deinitializing checkpoint_manager", .{});
        self.checkpoint_manager.deinit();

        std.log.debug("Deinitializing storage_engine", .{});
        self.storage_engine.deinit();

        std.log.debug("Deinitializing subscription_engine", .{});
        self.subscription_engine.deinit();

        std.log.debug("Deinitializing violation_tracker", .{});
        self.violation_tracker.deinit();

        // Free config - need to use pointer to field
        std.log.debug("About to deinit config", .{});
        var config_ptr = &self.config;
        config_ptr.deinit();
        std.log.debug("config deinitialized", .{});

        // Free auth config
        self.auth_config.deinit();

        // Free schema manager
        self.schema_manager.deinit();

        std.log.debug("Deinitializing memory_strategy", .{});
        self.memory_strategy.deinit();

        std.log.debug("About to destroy self", .{});
        self.allocator.destroy(self);
        std.log.debug("self destroyed", .{});
    }

    fn notifyPostHandler(ctx: ?*anyopaque) void {
        if (ctx == null) return;
        const self: *ZyncBaseServer = @ptrCast(@alignCast(ctx.?));
        self.notification_dispatcher.poll(&self.connection_manager);
        self.session_resolver.poll(&self.connection_manager);
    }
};

/// Signal handler for SIGTERM and SIGINT
/// ASYNC-SIGNAL-SAFE: only sets atomic flag and wakes event loop
fn handleSignal(_: c_int) callconv(.c) void {
    if (global_server) |server| {
        server.shutdown_requested.store(true, .release);
        server.websocket_server.close();
    }
}

fn storageEngineWakeup(ctx: ?*anyopaque) void {
    if (ctx == null) return;
    const server: *ZyncBaseServer = @ptrCast(@alignCast(ctx.?));
    if (server.websocket_server.loop.load(.acquire)) |loop| {
        uws_c.us_wakeup_loop(loop);
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
    _: i32,
    _: []const u8,
    user_data: ?*anyopaque,
) void {
    const server: *ZyncBaseServer = @ptrCast(@alignCast(user_data.?));
    server.connection_manager.onClose(ws);
}
