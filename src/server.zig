const std = @import("std");

pub const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
pub const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
pub const MessageType = @import("uwebsockets_wrapper.zig").MessageType;

const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const SubscriptionEngine = @import("subscription/engine.zig").SubscriptionEngine;
const CheckpointWorker = @import("checkpoint_worker.zig").CheckpointWorker;
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Config = @import("config_loader.zig").Config;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const SubscriptionWorkerPool = @import("subscription/worker_pool.zig").SubscriptionWorkerPool;
const ChangeQueue = @import("subscription/change_queue.zig").ChangeQueue;
const session_resolver = @import("authorization/session_resolver.zig");
const connection_manager = @import("connection/manager.zig");
const connection_violations = @import("connection/violations.zig");
const ticket_exchange = @import("authentication/ticket_exchange.zig");
const authentication_session = @import("authentication/session.zig");
const SessionResolver = session_resolver.SessionResolver;
const ConnectionManager = connection_manager.ConnectionManager;
const ViolationTracker = connection_violations.ConnectionViolationTracker;
const schema_types = @import("schema/types.zig");
const schema_system = @import("schema/system.zig");
const schema_parse = @import("schema/parse.zig");
const Schema = schema_types.Schema;
const authorization_types = @import("authorization/types.zig");
const authorization_defaults = @import("authorization/defaults.zig");
const authorization_parse = @import("authorization/parse.zig");
const DDLGenerator = @import("sql/ddl.zig").DDLGenerator;
const MigrationDetector = @import("migration_detector.zig").MigrationDetector;
const MigrationExecutor = @import("migration_executor.zig").MigrationExecutor;
const StoreService = @import("store_service.zig").StoreService;
const PresenceManager = @import("presence/manager.zig").PresenceManager;
const PresenceWorker = @import("presence/worker.zig").PresenceWorker;
const PresenceService = @import("presence/service.zig").PresenceService;
const send_queue_type = @import("connection/send_queue.zig").send_queue;
const TicketExchange = ticket_exchange.TicketExchange;
const JwtValidationConfig = @import("authentication/jwt_validator.zig").JwtValidationConfig;
const JwtValidator = @import("authentication/jwt_validator.zig").JwtValidator;
const Jwks = @import("authentication/jwt_validator.zig").Jwks;
const Session = authentication_session.Session;
const ThreadBudget = @import("thread_budget.zig").ThreadBudget;
pub const uws_c = @import("uwebsockets_wrapper.zig").c;

// Atomic global server reference for signal handlers (written once before registration,
// read from signal handler thread). Explicit acquire/release atomics are required as
// plain pointer loads on AArch64 are not guaranteed to be atomic.
var global_server: std.atomic.Value(?*ZyncBaseServer) = std.atomic.Value(?*ZyncBaseServer).init(null);

/// ZyncBaseServer integrates all components to create a complete real-time database server
pub const ZyncBaseServer = struct {
    allocator: std.mem.Allocator,
    config: Config,
    memory_strategy: MemoryStrategy,
    thread_budget: ThreadBudget,
    violation_tracker: ViolationTracker,
    subscription_engine: SubscriptionEngine,
    checkpoint_manager: CheckpointWorker,
    storage_engine: StorageEngine,
    change_queue: ChangeQueue,
    subscription_worker_pool: ?SubscriptionWorkerPool,
    session_resolver: SessionResolver,
    websocket_server: WebSocketServer,
    connection_manager: ConnectionManager,
    store_service: StoreService,
    presence_manager: PresenceManager,
    presence_worker: ?*PresenceWorker,
    presence_service: PresenceService,
    send_queue: send_queue_type,
    send_node_pool: MemoryStrategy.IndexPool(send_queue_type.Node),
    message_handler: MessageHandler,
    shutdown_requested: std.atomic.Value(bool),
    schema: Schema,
    auth_config: authorization_types.AuthConfig,
    ticket_exchange: ?*TicketExchange = null,
    jwks: ?*Jwks = null,
    jwt_validator: ?JwtValidator = null,
    shutdown_mutex: std.Thread.Mutex = .{},
    shutdown_performed: bool = false,
    shutdown_in_progress: bool = false,
    shutdown_start_time: i64 = 0,
    workers_stopped: bool = false,
    last_token_sweep_ms: i64 = 0,

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

        try self.memory_strategy.init(allocator);
        errdefer _ = self.memory_strategy.deinit();

        var config = try self.initConfigAndBudget(custom_config, custom_data_dir, custom_schema_file, custom_config_path);
        errdefer config.deinit();

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

        try self.loadSchema(&config);
        errdefer self.schema.deinit();

        try self.loadAuthConfig(&config);
        errdefer self.auth_config.deinit();

        try self.initQueues();
        errdefer self.send_node_pool.deinit();
        errdefer self.send_queue.deinit();
        errdefer self.change_queue.deinit();

        try self.initStorageAndMigrations(&config);
        errdefer self.storage_engine.deinit();

        try self.initCheckpoint();
        errdefer self.checkpoint_manager.deinit();

        try self.initWebSocketServer(&config);
        errdefer self.websocket_server.deinit();

        self.store_service = StoreService.init(
            self.memory_strategy.generalAllocator(),
            &self.storage_engine,
            &self.schema,
            &self.auth_config,
        );

        self.presence_manager.init(
            self.memory_strategy.generalAllocator(),
            self.schema.presence_user_fields,
            self.schema.presence_shared_fields,
        );

        const presence_worker = try self.initPresenceWorkerInternal();
        errdefer self.memory_strategy.generalAllocator().destroy(presence_worker);
        errdefer presence_worker.deinit();
        errdefer presence_worker.stop();
        self.presence_worker = presence_worker;

        self.presence_service = PresenceService.init(
            self.memory_strategy.generalAllocator(),
            presence_worker,
            &self.auth_config,
            &self.schema,
        );

        const jwt_config = try self.initJWT(&config);
        errdefer if (self.jwks) |jc| {
            jc.deinit();
            self.memory_strategy.generalAllocator().destroy(jc);
            self.jwks = null;
        };

        self.initMessageHandlerWired(&config);
        errdefer self.message_handler.deinit();

        try self.initConnectionManagerInternal(&config);
        errdefer self.connection_manager.deinit();

        var pool = try self.initSubscriptionPoolInternal();
        errdefer {
            pool.stop();
            pool.deinit();
        }
        try pool.start();
        self.subscription_worker_pool = pool;

        self.session_resolver.init(
            self.memory_strategy.generalAllocator(),
            &self.connection_manager,
            &self.memory_strategy,
        );
        errdefer self.session_resolver.deinit();

        // Wire Subscription Dispatcher hook into WebSocket Server
        self.websocket_server.post_handler = notifyPostHandler;
        self.websocket_server.post_handler_ctx = self;
        self.websocket_server.drain_handler = drainHandler;
        self.websocket_server.drain_handler_ctx = self;

        try self.initTicketExchangeInternal(&config, jwt_config);
        errdefer if (self.ticket_exchange) |te| {
            te.deinit();
            self.ticket_exchange = null;
        };
        self.websocket_server.verify_ticket_cb = verifyTicketCallback;

        std.log.debug("Setting up ZyncBaseServer state", .{});

        self.config = config;
        self.shutdown_performed = false;
        self.shutdown_in_progress = false;
        self.shutdown_start_time = 0;
        self.shutdown_mutex = .{};
        self.shutdown_requested = std.atomic.Value(bool).init(false);
        self.workers_stopped = false;
        self.last_token_sweep_ms = 0;

        return self;
    }

    fn initConfigAndBudget(
        self: *ZyncBaseServer,
        custom_config: ?Config,
        custom_data_dir: ?[]const u8,
        custom_schema_file: ?[]const u8,
        custom_config_path: ?[]const u8,
    ) !Config {
        var config = try loadOrCreateConfig(&self.memory_strategy, custom_config, custom_config_path);
        if (custom_data_dir) |dir| {
            self.memory_strategy.generalAllocator().free(config.data_dir);
            config.data_dir = try self.memory_strategy.generalAllocator().dupe(u8, dir);
        }
        if (custom_schema_file) |file| {
            self.memory_strategy.generalAllocator().free(config.schema_file);
            config.schema_file = try self.memory_strategy.generalAllocator().dupe(u8, file);
        }
        const cpu_count = std.Thread.getCpuCount() catch {
            return error.CpuCountDetectionFailed;
        };
        self.thread_budget = ThreadBudget.init(cpu_count) catch {
            return error.InsufficientCpuCores;
        };
        self.thread_budget.logSummary();
        return config;
    }

    fn initQueues(self: *ZyncBaseServer) !void {
        try self.send_node_pool.init(self.memory_strategy.generalAllocator(), 4096, null, null);
        errdefer self.send_node_pool.deinit();
        self.send_queue = try send_queue_type.init(&self.send_node_pool);
        errdefer self.send_queue.deinit();
        self.change_queue = try ChangeQueue.init(
            self.memory_strategy.generalAllocator(),
            self.thread_budget.subscription,
        );
    }

    fn initStorageAndMigrations(self: *ZyncBaseServer, config: *const Config) !void {
        std.log.debug("Initializing storage engine with data_dir: {s}", .{config.data_dir});
        try self.storage_engine.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            config.data_dir,
            &self.schema,
            config.performance,
            .{ .reader_pool_size = self.thread_budget.readers },
            storageEngineWakeup,
            self,
        );
        try self.runMigrationsAndStartEngine();
    }

    fn initCheckpoint(self: *ZyncBaseServer) !void {
        std.log.debug("Initializing checkpoint manager", .{});
        try self.checkpoint_manager.init(
            self.memory_strategy.generalAllocator(),
            &self.storage_engine,
            .{},
        );
    }

    fn initWebSocketServer(self: *ZyncBaseServer, config: *const Config) !void {
        std.log.debug("Initializing WebSocket server", .{});
        try self.websocket_server.init(
            self.memory_strategy.generalAllocator(),
            .{
                .port = config.server.port,
                .host = config.server.host,
                .max_payload_length = config.security.max_message_size,
            },
        );
    }

    fn initPresenceWorkerInternal(self: *ZyncBaseServer) !*PresenceWorker {
        const pw = try self.memory_strategy.generalAllocator().create(PresenceWorker);
        errdefer self.memory_strategy.generalAllocator().destroy(pw);
        try pw.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.presence_manager,
            &self.send_queue,
            storageEngineWakeup,
            self,
        );
        errdefer pw.deinit();
        errdefer pw.stop();
        try pw.spawn();
        return pw;
    }

    fn initJWT(self: *ZyncBaseServer, config: *const Config) !?JwtValidationConfig {
        const auth_cfg = &config.authentication;
        var jwks_ptr: ?*Jwks = null;
        if (auth_cfg.jwt_jwks_url) |jwks_url| {
            const jc = try self.memory_strategy.generalAllocator().create(Jwks);
            errdefer self.memory_strategy.generalAllocator().destroy(jc);
            jc.* = try Jwks.init(self.memory_strategy.generalAllocator(), jwks_url);
            jwks_ptr = jc;

            // Fetch JWKS synchronously at startup. Server must have valid
            // keys before accepting connections.
            try jc.loadJwks();
        }
        self.jwks = jwks_ptr;
        const jwt_config: ?JwtValidationConfig = if (auth_cfg.jwt_secret != null or jwks_ptr != null)
            JwtValidationConfig{
                .secret = auth_cfg.jwt_secret,
                .algorithm = auth_cfg.jwt_algorithm,
                .issuer = auth_cfg.jwt_issuer,
                .audience = auth_cfg.jwt_audience,
                .subject_claim = auth_cfg.jwt_subject_claim,
                .jwks = jwks_ptr,
            }
        else
            null;
        if (jwt_config) |cfg| {
            self.jwt_validator = JwtValidator.init(cfg);
        }
        return jwt_config;
    }

    fn initMessageHandlerWired(self: *ZyncBaseServer, config: *const Config) void {
        self.message_handler.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.violation_tracker,
            &self.store_service,
            &self.presence_service,
            &self.subscription_engine,
            config.security,
            &self.auth_config,
            &self.schema,
            if (self.jwt_validator) |*jv| jv else null,
            &config.authentication.session.claims,
        );
    }

    fn initConnectionManagerInternal(self: *ZyncBaseServer, config: *const Config) !void {
        std.log.debug("Initializing connection manager", .{});
        try self.connection_manager.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.message_handler,
            &self.schema,
            config.security.max_connections,
        );
    }

    fn initSubscriptionPoolInternal(self: *ZyncBaseServer) !SubscriptionWorkerPool {
        return try SubscriptionWorkerPool.init(
            self.memory_strategy.generalAllocator(),
            self.thread_budget.subscription,
            &self.change_queue,
            &self.subscription_engine,
            &self.memory_strategy,
            &self.schema,
            &self.send_queue,
            storageEngineWakeup,
            self,
        );
    }

    fn initTicketExchangeInternal(self: *ZyncBaseServer, config: *const Config, jwt_config: ?JwtValidationConfig) !void {
        const auth_cfg = &config.authentication;
        self.ticket_exchange = try TicketExchange.init(
            self.memory_strategy.generalAllocator(),
            auth_cfg.ticket_secret,
            auth_cfg.ticket_ttl_seconds,
            auth_cfg.ticket_single_use,
            jwt_config,
            auth_cfg.anonymous_enabled,
            auth_cfg.anonymous_subject_prefix,
            self.websocket_server.ssl,
            auth_cfg.session.claims,
        );
    }

    fn loadOrCreateConfig(
        memory_strategy: *MemoryStrategy,
        custom_config: ?Config,
        custom_config_path: ?[]const u8,
    ) !Config {
        if (custom_config) |c| return c;
        const path = custom_config_path orelse "zyncbase-config.json";
        return ConfigLoader.load(memory_strategy.generalAllocator(), path) catch |err| {
            std.log.warn("Failed to load config from {s}, using defaults: {}", .{ path, err });
            return ConfigLoader.loadDefaults(memory_strategy.generalAllocator());
        };
    }

    fn loadSchema(self: *ZyncBaseServer, config: *const Config) !void {
        const SchemaSource = enum { borrowed_config, borrowed_builtin, owned_file_read };
        const json_text: []const u8 = blk: {
            if (config.schema_content) |content| break :blk content;
            const schema_path = config.schema_file;
            std.log.info("Loading schema from: {s}", .{schema_path});
            const loaded = std.fs.cwd().readFileAlloc(
                self.memory_strategy.generalAllocator(),
                schema_path,
                10 * 1024 * 1024,
            ) catch |err| {
                if (err == error.FileNotFound) {
                    std.log.info("Schema file '{s}' not found, using implicit users-only schema", .{schema_path});
                    break :blk schema_system.implicit_users_schema_json;
                }
                std.log.err("Failed to read schema file '{s}': {}", .{ schema_path, err });
                return err;
            };
            break :blk loaded;
        };
        const schema_source: SchemaSource = if (config.schema_content != null)
            .borrowed_config
        else if (json_text.ptr == schema_system.implicit_users_schema_json.ptr)
            .borrowed_builtin
        else
            .owned_file_read;
        defer if (schema_source == .owned_file_read) self.memory_strategy.generalAllocator().free(json_text);

        self.schema = try schema_parse.initFromJson(self.memory_strategy.generalAllocator(), json_text);
    }

    fn loadAuthConfig(self: *ZyncBaseServer, config: *const Config) !void {
        if (config.authorization_file) |file| {
            const auth_json = std.fs.cwd().readFileAlloc(
                self.memory_strategy.generalAllocator(),
                file,
                1 * 1024 * 1024,
            ) catch |err| {
                if (err == error.FileNotFound) {
                    std.log.info("Auth file '{s}' not found, using implicit defaults", .{file});
                    self.auth_config = try authorization_defaults.implicitConfig(self.memory_strategy.generalAllocator(), &self.schema);
                    return;
                }
                return err;
            };
            defer self.memory_strategy.generalAllocator().free(auth_json);
            self.auth_config = try authorization_parse.initFromJson(self.memory_strategy.generalAllocator(), auth_json, &self.schema);
        } else {
            self.auth_config = try authorization_defaults.implicitConfig(self.memory_strategy.generalAllocator(), &self.schema);
        }
    }

    fn runMigrationsAndStartEngine(self: *ZyncBaseServer) !void {
        const schema_ptr = &self.schema;
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
        try self.storage_engine.start(&self.send_queue, &self.change_queue, &self.session_resolver);
    }

    /// Start the server and run the event loop
    pub fn start(self: *ZyncBaseServer) !void {
        std.log.info("Starting ZyncBase server on {s}:{d}", .{
            self.config.server.host,
            self.config.server.port,
        });

        // Register HTTP POST /auth/ticket route
        if (self.ticket_exchange) |te| {
            self.websocket_server.post("/auth/ticket", te, ticket_exchange.handleAuthTicket);
        }

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
        try self.checkpoint_manager.spawn();

        // Setup signal handlers for graceful shutdown (signal-safe)
        try self.setupSignalHandlers();

        // Start JWKS background refresh timer
        if (self.jwks) |jc| {
            try jc.startRefreshTimer();
        }

        // Start listening on configured port
        try self.websocket_server.listen();

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
        try self.startGracefulShutdown();
        try self.finishGracefulShutdown();
        self.stopBackgroundWorkers();
    }

    pub fn startGracefulShutdown(self: *ZyncBaseServer) !void {
        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();
        if (self.shutdown_in_progress or self.shutdown_performed) return;
        self.shutdown_in_progress = true;
        self.shutdown_start_time = std.time.milliTimestamp();

        // Set shutdown flag
        self.shutdown_requested.store(true, .release);

        std.log.info("Initiating graceful shutdown", .{});

        // Stop background checkpoint loop
        self.checkpoint_manager.stop();

        // Stop accepting new connections by closing the listen socket
        if (self.websocket_server.listen_socket) |ls| {
            uws_c.us_listen_socket_close(if (self.websocket_server.ssl) 1 else 0, ls);
            self.websocket_server.listen_socket = null;
        }

        // Send ServerDisconnect to all connections and close them
        self.connection_manager.sendDisconnectToAll("SHUTDOWN", "Server is shutting down.");

        // Wake loop to ensure another post-handler iteration fires so
        // finishGracefulShutdown can be called once all connections drain.
        if (self.websocket_server.loop.load(.acquire)) |loop| {
            uws_c.us_wakeup_loop(loop);
        }
    }

    pub fn finishGracefulShutdown(self: *ZyncBaseServer) !void {
        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();
        if (!self.shutdown_in_progress or self.shutdown_performed) return;
        self.shutdown_in_progress = false;
        self.shutdown_performed = true;

        std.log.info("Flushing pending writes and performing final checkpoint", .{});

        // Flush pending writes
        try self.storage_engine.flushPendingWrites();

        // Perform final checkpoint with retry for transient failures
        _ = try self.checkpoint_manager.performCheckpointWithRetry(.full, 5);

        // Stop the uWebSockets event loop
        self.websocket_server.close();

        std.log.info("Graceful shutdown complete", .{});
    }

    /// Stop all background worker threads before resource deinitialization.
    /// Must be called after finishGracefulShutdown() and before deinit().
    /// Idempotent: safe to call multiple times.
    pub fn stopBackgroundWorkers(self: *ZyncBaseServer) void {
        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();
        if (self.workers_stopped) return;
        self.workers_stopped = true;

        std.log.info("Stopping background workers", .{});

        // Stop JWKS refresh timer thread.
        if (self.jwks) |jc| jc.stopRefreshTimer();

        // Stop the storage engine writer thread. Must be after final flush+checkpoint
        // in finishGracefulShutdown(), which uses the writer thread. Safe to call
        // even if already stopped — stop() checks and sets write_thread to null.
        self.storage_engine.write_worker.stop();

        // Stop subscription workers to ensure no one pushes to change_queue/send_queue during their deinit.
        if (self.subscription_worker_pool) |*pool| pool.stop();

        // Stop presence dispatcher thread to ensure no one pushes to send_queue during its deinit.
        if (self.presence_worker) |presence_worker| presence_worker.stop();

        // Stop reader threads to ensure no one pushes to send_queue during its deinit.
        self.storage_engine.stopReaderPool();
    }

    /// Setup signal handlers for SIGTERM and SIGINT
    fn setupSignalHandlers(self: *ZyncBaseServer) !void {
        // Store global reference for signal handler with release ordering so the
        // signal handler (which uses acquire) always sees a fully-initialized pointer.
        global_server.store(self, .release);

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

    /// Deinit everything. Order: stop background threads → deinit cross-thread
    /// resources → deinit consumers → deinit infrastructure.
    pub fn deinit(self: *ZyncBaseServer) void {
        std.log.debug("ZyncBaseServer.deinit() called", .{});

        // Stop background threads before any shared-resource deinit.
        self.stopBackgroundWorkers();

        // send_queue.deinit() releases the stub node. Drain remaining entries first.
        std.log.debug("Deinitializing send_queue", .{});
        while (self.send_queue.pop()) |entry| {
            entry.deinit();
        }
        self.send_queue.deinit();
        self.send_node_pool.deinit();

        // change_queue.deinit() frees any remaining unconsumed change jobs.
        std.log.debug("Deinitializing change_queue", .{});
        self.change_queue.deinit();

        std.log.debug("Deinitializing connection_manager", .{});
        self.connection_manager.deinit();

        std.log.debug("Deinitializing message_handler", .{});
        self.message_handler.deinit();

        std.log.debug("Deinitializing presence_service", .{});
        self.presence_service.deinit();

        std.log.debug("Deinitializing store_service", .{});
        self.store_service.deinit();

        std.log.debug("Deinitializing presence_worker", .{});
        if (self.presence_worker) |presence_worker| {
            presence_worker.deinit();
            self.memory_strategy.generalAllocator().destroy(presence_worker);
        }

        std.log.debug("Deinitializing presence_manager", .{});
        self.presence_manager.deinit();

        std.log.debug("Deinitializing session_resolver", .{});
        self.session_resolver.deinit();

        std.log.debug("Deinitializing subscription_worker_pool", .{});
        if (self.subscription_worker_pool) |*pool| pool.deinit();

        std.log.debug("Deinitializing websocket_server", .{});
        self.websocket_server.deinit();

        std.log.debug("Deinitializing checkpoint_manager", .{});
        self.checkpoint_manager.deinit();

        // WriteWorker already stopped in stopBackgroundWorkers().
        // storage_engine.deinit() guards double-join via state check.
        std.log.debug("Deinitializing storage_engine", .{});
        self.storage_engine.deinit();

        std.log.debug("Deinitializing subscription_engine", .{});
        self.subscription_engine.deinit();

        std.log.debug("Deinitializing violation_tracker", .{});
        self.violation_tracker.deinit();

        // Deinitialize ticket exchange and JWKS cache.
        // Jwks.deinit() must run first: it stops the refresh timer thread
        // and frees the cached keys. ticket_exchange and message_handler deinit
        // then free their resources.
        if (self.jwks) |jc| {
            jc.deinit();
            self.memory_strategy.generalAllocator().destroy(jc);
        }
        if (self.ticket_exchange) |te| te.deinit();

        // Free config - need to use pointer to field
        std.log.debug("About to deinit config", .{});
        var config_ptr = &self.config;
        config_ptr.deinit();
        std.log.debug("config deinitialized", .{});

        // Free auth config
        self.auth_config.deinit();

        // Free schema manager
        self.schema.deinit();

        std.log.debug("Deinitializing memory_strategy", .{});
        _ = self.memory_strategy.deinit();

        std.log.debug("About to destroy self", .{});
        self.allocator.destroy(self);
        std.log.debug("self destroyed", .{});
    }

    fn notifyPostHandler(ctx: ?*anyopaque) void {
        if (ctx == null) return;
        const self: *ZyncBaseServer = @ptrCast(@alignCast(ctx.?));

        // Handle graceful shutdown state machine
        if (self.shutdown_requested.load(.acquire)) {
            if (!self.shutdown_in_progress and !self.shutdown_performed) {
                self.startGracefulShutdown() catch |err| {
                    std.log.err("Failed to start graceful shutdown: {}", .{err});
                };
            }
            if (self.shutdown_in_progress) {
                self.connection_manager.mutex.lock();
                const count = self.connection_manager.map.count();
                self.connection_manager.mutex.unlock();
                const elapsed = std.time.milliTimestamp() - self.shutdown_start_time;
                if (count == 0 or elapsed > 3000) {
                    self.finishGracefulShutdown() catch |err| {
                        std.log.err("Failed to finish graceful shutdown: {}", .{err});
                    };
                }
            }
            if (self.shutdown_performed or self.shutdown_in_progress) {
                return;
            }
        }

        self.connection_manager.drainSendQueue(&self.send_queue);

        const now_ms = std.time.milliTimestamp();
        if (now_ms - self.last_token_sweep_ms >= 15_000) {
            self.last_token_sweep_ms = now_ms;
            self.connection_manager.sweepExpiredTokens(self.config.authentication.session.token_grace_period_seconds);
        }
    }

    fn drainHandler(ctx: ?*anyopaque, conn_id: u64) void {
        if (ctx == null) return;
        const self: *ZyncBaseServer = @ptrCast(@alignCast(ctx.?));
        self.connection_manager.flushOutbox(conn_id);
    }

    fn verifyTicketCallback(user_data: ?*anyopaque, ticket: []const u8, allocator: std.mem.Allocator) anyerror!Session {
        if (user_data == null) return error.AuthFailed;
        const self: *ZyncBaseServer = @ptrCast(@alignCast(user_data.?));
        const te = self.ticket_exchange orelse return error.AuthFailed;
        return te.verifyTicket(allocator, ticket);
    }
};

/// Signal handler for SIGTERM and SIGINT
/// ASYNC-SIGNAL-SAFE: only sets atomic flag and wakes event loop
fn handleSignal(_: c_int) callconv(.c) void {
    if (global_server.load(.acquire)) |server| {
        server.shutdown_requested.store(true, .release);
        if (server.websocket_server.loop.load(.acquire)) |loop| {
            uws_c.us_wakeup_loop(loop);
        }
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
