const std = @import("std");

const authentication_session = @import("authentication/session.zig");
const ticket_exchange = @import("authentication/ticket_exchange.zig");
const authorization_defaults = @import("authorization/defaults.zig");
const authorization_parse = @import("authorization/parse.zig");
const session_resolver = @import("authorization/session_resolver.zig");
const authorization_types = @import("authorization/types.zig");
const backup = @import("backup.zig");
const connection_manager = @import("connection/manager.zig");
const connection_violations = @import("connection/violations.zig");
const migration_source = @import("migration/source.zig");
const migration_startup = @import("migration/startup.zig");
const migration_target = @import("migration/target.zig");
const http_handlers = @import("observability/http_handlers.zig");
const observability_log = @import("observability/log.zig");
const canonical = @import("schema/canonical.zig");
const schema_types = @import("schema/types.zig");
const uws_timer = @import("uws_timer.zig");
const ActionsService = @import("actions/service.zig").ActionsService;
const Jwks = @import("authentication/jwt_validator.zig").Jwks;
const JwtValidationConfig = @import("authentication/jwt_validator.zig").JwtValidationConfig;
const JwtValidator = @import("authentication/jwt_validator.zig").JwtValidator;
const CheckpointWorker = @import("checkpoint_worker.zig").CheckpointWorker;
const ConfigLoader = @import("config/loader.zig").ConfigLoader;
const Config = @import("config/state.zig").Config;
const SendQueueType = @import("connection/send_queue.zig").SendQueue;
const DataLock = @import("data_lock.zig").DataLock;
const MemoryStrategy = @import("memory/strategy.zig").MemoryStrategy;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const Diagnostics = @import("migration/diagnostics.zig").Diagnostics;
const ServerMetrics = @import("observability/metrics.zig").ServerMetrics;
const PresenceManager = @import("presence/manager.zig").PresenceManager;
const PresenceService = @import("presence/service.zig").PresenceService;
const PresenceWorker = @import("presence/worker.zig").PresenceWorker;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const StoreService = @import("store_service.zig").StoreService;
const ChangeQueue = @import("subscription/change_queue.zig").ChangeQueue;
const SubscriptionEngine = @import("subscription/engine.zig").SubscriptionEngine;
const SubscriptionWorkerPool = @import("subscription/worker_pool.zig").SubscriptionWorkerPool;
const ThreadBudget = @import("thread_budget.zig").ThreadBudget;
const event_loop_count = @import("thread_budget.zig").event_loop_count;
const MessageType = @import("uwebsockets_wrapper.zig").MessageType;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;
const WebSocketServer = @import("uwebsockets_wrapper.zig").WebSocketServer;
const uws_c = @import("uwebsockets_wrapper.zig").c;

const Session = authentication_session.Session;
const TicketExchange = ticket_exchange.TicketExchange;
const SessionResolver = session_resolver.SessionResolver;
const ConnectionManager = connection_manager.ConnectionManager;
const ViolationTracker = connection_violations.ConnectionViolationTracker;
const Schema = schema_types.Schema;

// Atomic global server reference for signal handlers (written once before registration,
// read from signal handler thread). Explicit acquire/release atomics are required as
// plain pointer loads on AArch64 are not guaranteed to be atomic.

var global_server: std.atomic.Value(?*ZyncBaseServer) = std.atomic.Value(?*ZyncBaseServer).init(null);

// A termination signal that arrived before the server was published. The handler
// cannot touch ZyncBaseServer yet, so it parks the request here and
// activateSignalHandling() replays it once the instance is safe to read.
pub var pending_signal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Set by the first termination signal; the next one skips the graceful path.
pub var signal_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const EventLoopContext = struct {
    server: *ZyncBaseServer,
    id: u8,
    websocket_server: WebSocketServer,
    thread: ?std.Thread = null,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    app_initialized: bool = false,
    shutdown_started: bool = false,
    app_closed: bool = false,
    shutdown_timer: ?*uws_c.struct_us_timer_t = null,
};

/// ZyncBaseServer integrates all components to create a complete real-time database server
pub const ZyncBaseServer = struct {
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    config: Config,
    data_lock: ?DataLock = null,
    memory_strategy: MemoryStrategy,
    thread_budget: ThreadBudget,
    violation_tracker: ViolationTracker,
    subscription_engine: SubscriptionEngine,
    checkpoint_manager: CheckpointWorker,
    storage_engine: StorageEngine,
    change_queue: ChangeQueue,
    subscription_worker_pool: ?SubscriptionWorkerPool,
    session_resolver: SessionResolver,
    event_loops: [event_loop_count]EventLoopContext,
    connection_manager: ConnectionManager,
    store_service: StoreService,
    presence_manager: PresenceManager,
    presence_worker: ?*PresenceWorker,
    presence_service: PresenceService,
    actions_service: ActionsService,
    send_queue: SendQueueType,
    message_handler: MessageHandler,
    server_metrics: ServerMetrics,
    http_context: http_handlers.HttpContext,
    shutdown_requested: std.atomic.Value(bool),
    schema: Schema,
    schema_identity: canonical.Identity,
    auth_config: authorization_types.AuthConfig,
    ticket_exchange: ?*TicketExchange = null,
    jwks: ?*Jwks = null,
    jwt_validator: ?JwtValidator = null,
    shutdown_mutex: std.Io.Mutex = .init,
    workers_stopped: bool = false,

    /// Initialize the ZyncBase server with all components
    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, custom_config_path: ?[]const u8) !*ZyncBaseServer {
        return initDetailed(io, environ, allocator, null, null, null, custom_config_path);
    }

    /// Initialize the ZyncBase server with optional custom configuration and data directory
    pub fn initDetailed(
        io: std.Io,
        environ: std.process.Environ,
        allocator: std.mem.Allocator,
        custom_config: ?Config,
        custom_data_dir: ?[]const u8,
        custom_schema_file: ?[]const u8,
        custom_config_path: ?[]const u8,
    ) !*ZyncBaseServer {
        const self = try allocator.create(ZyncBaseServer);
        errdefer allocator.destroy(self);
        self.io = io;
        self.environ = environ;
        self.allocator = allocator;
        for (&self.event_loops, 0..) |*loop, index| {
            loop.* = .{
                .server = self,
                .id = @intCast(index),
                // SAFETY: initLoopWrapper calls WebSocketServer.init on this field before any loop thread touches it.
                .websocket_server = undefined,
                .thread = null,
                .ready = std.atomic.Value(bool).init(index == 0),
                .app_initialized = false,
            };
        }
        self.server_metrics = ServerMetrics.init(std.Io.Clock.real.now(io).toSeconds());

        try self.memory_strategy.initWithAllocator(allocator);
        errdefer self.memory_strategy.deinit();

        self.config = try self.initConfigAndBudget(custom_config, custom_data_dir, custom_schema_file, custom_config_path);
        // Auth consumers retain pointers into this configuration after init returns.
        const config = &self.config;
        errdefer config.deinit();

        // Apply logging before any subsystem logs or spawns worker threads.
        observability_log.init(switch (config.logging.level) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .@"error" => .err,
        }, config.logging.format == .json);

        // Initialize violation tracker
        std.log.debug("Initializing violation tracker", .{});
        self.violation_tracker.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            config.security.violation_threshold,
        );
        errdefer self.violation_tracker.deinit();

        // Initialize subscription engine
        std.log.debug("Initializing subscription engine", .{});
        self.subscription_engine = SubscriptionEngine.init(
            self.io,
            self.memory_strategy.generalAllocator(),
        );

        try self.loadSchema(config);
        errdefer self.schema.deinit();
        errdefer self.schema_identity.deinit(self.memory_strategy.generalAllocator());

        try self.loadAuthConfig(config);
        errdefer self.auth_config.deinit();

        try self.initQueues();
        errdefer self.send_queue.deinit();
        errdefer self.change_queue.deinit();

        try self.initWebSocketServer(config);
        errdefer self.deinitLoopWrapper(0);

        try self.initStorageAndMigrations(config);
        errdefer self.releaseDataLock();
        errdefer self.storage_engine.deinit();

        try self.initCheckpoint();
        errdefer self.checkpoint_manager.deinit();

        self.store_service = StoreService.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            &self.storage_engine,
            &self.schema,
            &self.auth_config,
        );

        self.presence_manager.init(
            self.io,
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

        self.actions_service = ActionsService.init(
            self.memory_strategy.generalAllocator(),
            self.io,
            &self.schema,
            &self.auth_config,
        );

        try self.initJWT(config);
        errdefer if (self.jwks) |jc| {
            jc.deinit();
            self.memory_strategy.generalAllocator().destroy(jc);
            self.jwks = null;
        };

        self.initMessageHandlerWired(config);
        errdefer self.message_handler.deinit();

        try self.initConnectionManagerInternal(config);
        errdefer self.connection_manager.deinit();
        self.actions_service.setConnectionManager(&self.connection_manager);
        self.connection_manager.setSendQueue(&self.send_queue);

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

        // Wire Subscription Dispatcher hook into WebSocket Server
        self.event_loops[0].websocket_server.post_handler = notifyPostHandler;
        self.event_loops[0].websocket_server.post_handler_ctx = &self.event_loops[0];

        try self.initTicketExchangeInternal(config);
        errdefer if (self.ticket_exchange) |te| {
            te.deinit();
            self.ticket_exchange = null;
        };
        self.event_loops[0].websocket_server.verify_ticket_cb = verifyTicketCallback;

        self.http_context = .{
            .ssl = self.event_loops[0].websocket_server.ssl,
            .io = self.io,
            .metrics = &self.server_metrics,
            .active_connection_count = &self.connection_manager.active_connection_count,
            .checkpoint_worker = &self.checkpoint_manager,
            .storage_engine = &self.storage_engine,
        };

        std.log.debug("Setting up ZyncBaseServer state", .{});

        self.shutdown_mutex = .init;
        self.shutdown_requested = std.atomic.Value(bool).init(false);
        self.workers_stopped = false;

        return self;
    }

    fn initConfigAndBudget(
        self: *ZyncBaseServer,
        custom_config: ?Config,
        custom_data_dir: ?[]const u8,
        custom_schema_file: ?[]const u8,
        custom_config_path: ?[]const u8,
    ) !Config {
        var config = try self.loadOrCreateConfig(custom_config, custom_config_path);
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
        self.send_queue = try SendQueueType.init(self.memory_strategy.generalAllocator());
        errdefer self.send_queue.deinit();
        self.change_queue = try ChangeQueue.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            self.thread_budget.subscription,
        );
    }

    fn initStorageAndMigrations(self: *ZyncBaseServer, config: *const Config) !void {
        std.log.debug("Initializing storage engine with data_dir: {s}", .{config.data_dir});

        self.data_lock = DataLock.acquire(
            self.io,
            self.memory_strategy.generalAllocator(),
            config.data_dir,
        ) catch |err| {
            if (err == error.DataDirLocked) {
                std.log.err(
                    "Data directory {s} is locked by another zyncbase process",
                    .{config.data_dir},
                );
            }
            return err;
        };
        errdefer self.releaseDataLock();

        try backup.recoverInterruptedRestore(
            self.io,
            self.memory_strategy.generalAllocator(),
            config.data_dir,
        );
        if (try backup.recoverInterruptedReset(
            self.io,
            self.memory_strategy.generalAllocator(),
            config.data_dir,
        )) |recovered| {
            var info = recovered;
            info.deinit(self.memory_strategy.generalAllocator());
        }

        std.log.info("Storage durability: synchronous={s}", .{@tagName(config.storage.synchronous)});
        try self.storage_engine.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            config.data_dir,
            &self.schema,
            config.performance,
            .{
                .reader_pool_size = self.thread_budget.readers,
                .max_query_response_size = config.security.max_query_response_size,
                .synchronous = config.storage.synchronous,
            },
            storageEngineWakeup,
            self,
        );
        errdefer self.storage_engine.deinit();
        try self.runMigrationsAndStartEngine();

        if (self.data_lock) |*lock| try lock.downgradeToShared(self.io);
    }

    fn releaseDataLock(self: *ZyncBaseServer) void {
        if (self.data_lock) |*lock| {
            lock.release(self.io);
            self.data_lock = null;
        }
    }

    fn initCheckpoint(self: *ZyncBaseServer) !void {
        std.log.debug("Initializing checkpoint manager", .{});
        try self.checkpoint_manager.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            &self.storage_engine,
            .{},
        );
    }

    fn validateTlsPair(cert_file: ?[]const u8, key_file: ?[]const u8) !void {
        if (cert_file == null and key_file == null) return;
        const cert_ok = if (cert_file) |c| c.len > 0 else false;
        const key_ok = if (key_file) |k| k.len > 0 else false;
        if (!(cert_ok and key_ok)) return error.InvalidTlsConfig;
    }

    fn ws(self: *ZyncBaseServer, index: usize) *WebSocketServer {
        return &self.event_loops[index].websocket_server;
    }
    fn deinitLoopWrapper(self: *ZyncBaseServer, index: usize) void {
        if (!self.event_loops[index].app_initialized) return;
        self.event_loops[index].websocket_server.deinit();
        self.event_loops[index].app_initialized = false;
    }
    fn initWebSocketServer(self: *ZyncBaseServer, config: *const Config) !void {
        try self.initLoopWrapper(0, config);
    }
    fn initLoopWrapper(self: *ZyncBaseServer, index: usize, config: *const Config) !void {
        std.log.debug("Initializing WebSocket server loop {d}", .{index});
        try validateTlsPair(config.server.tls_cert_file, config.server.tls_key_file);
        try self.ws(index).init(
            self.memory_strategy.generalAllocator(),
            .{
                .port = config.server.port,
                .host = config.server.host,
                .ssl = config.server.tls_cert_file != null or config.server.tls_key_file != null,
                .ssl_cert_path = config.server.tls_cert_file,
                .ssl_key_path = config.server.tls_key_file,
                .idle_timeout = config.server.idle_timeout_seconds,
                .max_payload_length = config.security.max_message_size,
            },
        );
        self.ws(index).loop_id = @intCast(index);
        self.event_loops[index].app_initialized = true;
    }

    fn initPresenceWorkerInternal(self: *ZyncBaseServer) !*PresenceWorker {
        const pw = try self.memory_strategy.generalAllocator().create(PresenceWorker);
        errdefer self.memory_strategy.generalAllocator().destroy(pw);
        try pw.init(
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.presence_manager,
            &self.send_queue,
            .{
                .timeout_ms = self.config.performance.presence_batch_timeout,
                .max_updates = self.config.performance.presence_batch_max_updates,
            },
            storageEngineWakeup,
            self,
        );
        errdefer pw.deinit();
        errdefer pw.stop();
        try pw.spawn();
        return pw;
    }

    fn initJWT(self: *ZyncBaseServer, config: *const Config) !void {
        const auth_cfg = &config.authentication;
        var jwks_ptr: ?*Jwks = null;
        if (auth_cfg.jwt_jwks_url) |jwks_url| {
            const jc = try self.memory_strategy.generalAllocator().create(Jwks);
            errdefer self.memory_strategy.generalAllocator().destroy(jc);
            jc.* = try Jwks.init(self.io, self.memory_strategy.generalAllocator(), jwks_url);
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
            self.jwt_validator = JwtValidator.init(self.io, cfg);
        }
    }

    fn initMessageHandlerWired(self: *ZyncBaseServer, config: *const Config) void {
        self.message_handler.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.violation_tracker,
            &self.store_service,
            &self.presence_service,
            &self.actions_service,
            &self.subscription_engine,
            config.security,
            &self.auth_config,
            &self.schema,
            if (self.jwt_validator) |*jv| jv else null,
            &config.authentication.session.claims,
        );
        self.message_handler.setMetrics(&self.server_metrics);
    }

    fn initConnectionManagerInternal(self: *ZyncBaseServer, config: *const Config) !void {
        std.log.debug("Initializing connection manager", .{});
        try self.connection_manager.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            &self.memory_strategy,
            &self.message_handler,
            &self.schema,
            config.security.max_connections,
            config.authentication.session.token_grace_period_seconds,
        );
        self.connection_manager.setMetrics(&self.server_metrics);
        self.connection_manager.setLastConnectionNotifier(.{ .callback = lastConnectionClosed, .ctx = self });
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

    fn initTicketExchangeInternal(self: *ZyncBaseServer, config: *const Config) !void {
        const auth_cfg = &config.authentication;
        self.ticket_exchange = try TicketExchange.init(
            self.io,
            self.memory_strategy.generalAllocator(),
            auth_cfg.ticket_secret,
            auth_cfg.ticket_ttl_seconds,
            if (self.jwt_validator) |*jv| jv else null,
            auth_cfg.anonymous_enabled,
            auth_cfg.anonymous_subject_prefix,
            self.event_loops[0].websocket_server.ssl,
            &auth_cfg.session.claims,
        );
    }

    fn loadOrCreateConfig(
        self: *ZyncBaseServer,
        custom_config: ?Config,
        custom_config_path: ?[]const u8,
    ) !Config {
        if (custom_config) |c| return c;
        const path = custom_config_path orelse "zyncbase-config.json";
        const allocator = self.memory_strategy.generalAllocator();
        var environ = try self.environ.createMap(allocator);
        defer environ.deinit();
        return ConfigLoader.load(self.io, &environ, allocator, path) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn("Failed to load config from {s}, using defaults: {}", .{ path, err });
                return ConfigLoader.loadDefaults(allocator);
            },
            else => return err,
        };
    }

    fn loadSchema(self: *ZyncBaseServer, config: *const Config) !void {
        // The source text, minified, becomes the applied-schema snapshot.
        const loaded = try migration_target.load(self.io, self.memory_strategy.generalAllocator(), config);
        self.schema = loaded.schema;
        self.schema_identity = loaded.identity;
    }

    fn loadAuthConfig(self: *ZyncBaseServer, config: *const Config) !void {
        if (config.authorization_file) |file| {
            const auth_json = std.Io.Dir.cwd().readFileAlloc(
                self.io,
                file,
                self.memory_strategy.generalAllocator(),
                .limited(1 * 1024 * 1024),
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
        const gpa = self.memory_strategy.generalAllocator();

        // The migration run is the sole owner of schema DDL: fresh databases
        // are created through it too, inside one transaction.
        const setup_conn = try self.storage_engine.getSetupConn();
        var diag = Diagnostics.init(gpa);
        defer diag.deinit();

        const migrations_dir = try self.config.migrationsDir(gpa);
        defer gpa.free(migrations_dir);
        var migrations = migration_source.load(self.io, gpa, migrations_dir, &diag) catch |err| {
            std.log.err("Cannot start: {s}", .{@errorName(err)});
            diag.logErrors();
            return err;
        };
        defer migrations.deinit();

        const db_path = try backup.dbPath(gpa, self.config.data_dir);
        defer gpa.free(db_path);
        var report = migration_startup.run(self.io, gpa, setup_conn, .{
            .schema = &self.schema,
            .json = self.schema_identity.json,
            .hash = self.schema_identity.hash,
        }, .{
            .migrations = migrations.items,
            .snapshot_of = if (self.config.migrations.snapshot) db_path else null,
        }, &diag) catch |err| {
            std.log.err("Cannot start: {s}", .{@errorName(err)});
            diag.logErrors();
            std.log.err("Nothing was changed.", .{});
            return err;
        };
        defer report.deinit(gpa);
        if (report.migrations_applied > 0) {
            std.log.info("Applied {d} migration(s) from {s}", .{ report.migrations_applied, migrations_dir });
        }
        if (report.post_commit_error) |err| {
            std.log.err("Migrations committed, but restoring foreign-key enforcement failed: {}", .{err});
            return err;
        }

        // Lock the engine and start the runtime thread. The writer reads the
        // subscription count to order outcomes after deltas.
        self.storage_engine.write_worker.subscription_count = &self.subscription_engine.active_count;
        try self.storage_engine.start(&self.send_queue, &self.change_queue, &self.session_resolver);
    }

    /// Start both reactors and run loop 0 on the main thread.
    pub fn start(self: *ZyncBaseServer) !void {
        std.log.info("Starting ZyncBase server on {s}:{d}", .{
            self.config.server.host,
            self.config.server.port,
        });
        try self.registerLoopRoutes(0);
        try self.checkpoint_manager.spawn();
        try self.activateSignalHandling();

        self.event_loops[1].thread = try std.Thread.spawn(.{}, eventLoopThread, .{self});
        while (!self.event_loops[1].ready.load(.acquire)) try std.Thread.yield();

        self.ws(0).listen() catch |err| {
            // Loop 1 is already listening; stop and join it before unwinding.
            self.ws(1).close();
            if (self.event_loops[1].thread) |thread| thread.join();
            return err;
        };
        if (self.ws(0).loop.load(.acquire)) |reactor| self.connection_manager.setLoopWake(0, reactor);
        std.log.info("Server started successfully", .{});

        self.ws(0).run();
        self.connection_manager.clearLoopWake(0);
        self.ws(0).loop.store(null, .release);

        if (!self.shutdown_requested.load(.acquire)) self.ws(1).close();
        if (self.event_loops[1].thread) |thread| thread.join();
        try self.finishShutdown();
    }
    fn registerLoopRoutes(self: *ZyncBaseServer, index: usize) !void {
        const server_ws = self.ws(index);
        server_ws.on_loop_ready = loopReadyDispatcher;
        server_ws.on_loop_ready_ctx = &self.event_loops[index];
        if (self.ticket_exchange) |te| {
            server_ws.post("/auth/ticket", te, ticket_exchange.handleAuthTicket);
        }
        server_ws.get("/health", &self.http_context, http_handlers.handleHealth);
        server_ws.get("/stats", &self.http_context, http_handlers.handleStats);
        server_ws.registerWebSocketHandlers(
            "/*",
            .{
                .on_open = onWebSocketOpen,
                .on_message = onWebSocketMessage,
                .on_close = onWebSocketClose,
            },
            self,
        );
    }
    fn eventLoopThread(self: *ZyncBaseServer) void {
        const loop = &self.event_loops[1];
        self.initLoopWrapper(1, &self.config) catch |err| {
            std.log.err("Failed to initialize event loop 1: {}", .{err});
            std.process.exit(1);
        };
        loop.websocket_server.post_handler = notifyPostHandler;
        loop.websocket_server.post_handler_ctx = loop;
        loop.websocket_server.verify_ticket_cb = verifyTicketCallback;
        self.registerLoopRoutes(1) catch |err| {
            std.log.err("Failed to register event loop 1 routes: {}", .{err});
            std.process.exit(1);
        };
        loop.websocket_server.listen() catch |err| {
            std.log.err("Failed to listen on event loop 1: {}", .{err});
            std.process.exit(1);
        };
        if (loop.websocket_server.loop.load(.acquire)) |reactor| self.connection_manager.setLoopWake(1, reactor);
        loop.ready.store(true, .release);
        loop.websocket_server.run();
        self.connection_manager.clearLoopWake(1);
        loop.websocket_server.loop.store(null, .release);
        // The app and its socket contexts belong to this thread's loop; destroy
        // them before the loop thread exits.
        self.deinitLoopWrapper(1);
    }
    fn finishShutdown(self: *ZyncBaseServer) !void {
        self.connection_manager.stopTokenSweepTimer();
        self.actions_service.stopSweepTimer();
        if (self.jwks) |jc| jc.stopRefreshTimer();
        std.log.info("Flushing pending writes and performing final checkpoint", .{});
        try self.storage_engine.flushPendingWrites();
        _ = try self.checkpoint_manager.performCheckpointWithRetry(.full, 5);
        self.stopBackgroundWorkers();
        std.log.info("Graceful shutdown complete", .{});
    }
    /// Stop all background worker threads before resource deinitialization.
    /// Idempotent: safe to call multiple times.
    pub fn stopBackgroundWorkers(self: *ZyncBaseServer) void {
        self.shutdown_mutex.lockUncancelable(self.io);
        defer self.shutdown_mutex.unlock(self.io);
        if (self.workers_stopped) return;
        self.workers_stopped = true;

        std.log.info("Stopping background workers", .{});

        // Stop JWKS refresh timer thread.
        if (self.jwks) |jc| jc.stopRefreshTimer();

        // Stop token sweep timer.
        self.connection_manager.stopTokenSweepTimer();

        // Stop action deadline sweep timer.
        self.actions_service.stopSweepTimer();

        // Stop the storage engine writer thread. Must be after final flush+checkpoint
        // in finishShutdown(), which uses the writer thread. Safe to call even if
        // already stopped — stop() checks and sets write_thread to null.
        self.storage_engine.write_worker.stop();

        // Stop subscription workers to ensure no one pushes to change_queue/send_queue during their deinit.
        if (self.subscription_worker_pool) |*pool| pool.stop();

        // Stop presence dispatcher thread to ensure no one pushes to send_queue during its deinit.
        if (self.presence_worker) |presence_worker| presence_worker.stop();

        // Stop reader threads to ensure no one pushes to send_queue during its deinit.
        self.storage_engine.stopReaderPool();
    }

    /// Install SIGTERM/SIGINT handlers. Call this before any initialization so a
    /// signal that lands mid-startup is replayed instead of killing the process.
    pub fn installSignalHandlers() void {
        const termination_action = std.posix.Sigaction{
            .handler = .{ .handler = handleSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.TERM, &termination_action, null);
        std.posix.sigaction(std.posix.SIG.INT, &termination_action, null);
    }

    /// Publish this instance to the signal handler and replay a signal that
    /// arrived during startup. Must run after the instance is fully initialized.
    fn activateSignalHandling(self: *ZyncBaseServer) !void {
        // Store global reference for signal handler with release ordering so the
        // signal handler (which uses acquire) always sees a fully-initialized pointer.
        global_server.store(self, .release);

        if (pending_signal.swap(false, .acq_rel)) {
            self.shutdown_requested.store(true, .release);
        }
    }

    /// Deinit everything. Order: stop background threads → deinit cross-thread
    /// resources → deinit consumers → deinit infrastructure.
    pub fn deinit(self: *ZyncBaseServer) void {
        std.log.debug("ZyncBaseServer.deinit() called", .{});

        // Unpublish before freeing so a signal cannot dereference this instance
        // once it is gone.
        global_server.store(null, .release);

        // Stop background threads before any shared-resource deinit.
        self.stopBackgroundWorkers();

        // change_queue.deinit() frees any remaining unconsumed change jobs.
        // Before send_queue: a job's outcome fence may still publish into it.
        std.log.debug("Deinitializing change_queue", .{});
        self.change_queue.deinit();

        // send_queue.deinit() releases the stub node. Drain remaining entries first.
        std.log.debug("Deinitializing send_queue", .{});
        for (0..event_loop_count) |index| {
            while (self.send_queue.popFrom(index)) |entry| {
                entry.deinit();
            }
        }
        self.send_queue.deinit();

        std.log.debug("Deinitializing connection_manager", .{});
        self.connection_manager.deinit();

        std.log.debug("Deinitializing actions_service", .{});
        self.actions_service.deinit();

        std.log.debug("Deinitializing message_handler", .{});
        self.message_handler.deinit();

        std.log.debug("Deinitializing store_service", .{});
        self.store_service.deinit();

        std.log.debug("Deinitializing presence_worker", .{});
        if (self.presence_worker) |presence_worker| {
            presence_worker.deinit();
            self.memory_strategy.generalAllocator().destroy(presence_worker);
        }

        std.log.debug("Deinitializing presence_manager", .{});
        self.presence_manager.deinit();

        std.log.debug("Deinitializing subscription_worker_pool", .{});
        if (self.subscription_worker_pool) |*pool| pool.deinit();

        std.log.debug("Deinitializing websocket_server", .{});
        for (0..self.event_loops.len) |index| self.deinitLoopWrapper(index);

        std.log.debug("Deinitializing checkpoint_manager", .{});
        self.checkpoint_manager.deinit();

        // WriteWorker already stopped in stopBackgroundWorkers().
        // storage_engine.deinit() guards double-join via state check.
        std.log.debug("Deinitializing storage_engine", .{});
        self.storage_engine.deinit();

        self.releaseDataLock();

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
        self.schema_identity.deinit(self.memory_strategy.generalAllocator());

        std.log.debug("Deinitializing memory_strategy", .{});
        self.memory_strategy.deinit();

        std.log.debug("About to destroy self", .{});
        self.allocator.destroy(self);
        std.log.debug("self destroyed", .{});
    }

    fn notifyPostHandler(ctx: ?*anyopaque) void {
        if (ctx == null) return;
        const loop: *EventLoopContext = @ptrCast(@alignCast(ctx.?));
        const self = loop.server;
        if (self.shutdown_requested.load(.acquire)) {
            if (!loop.shutdown_started) {
                loop.shutdown_started = true;
                std.log.info("Event loop {} starting graceful shutdown", .{loop.id});
                // Deliver work this loop accepted before the disconnect frame.
                // Staged action forwards still queued for the other reactor are
                // best effort: it may have entered its own shutdown already.
                if (loop.id == 0) {
                    self.actions_service.lock();
                    self.actions_service.flushOutbox();
                    self.actions_service.unlock();
                }
                self.connection_manager.drainSendQueue(&self.send_queue, loop.id);
                self.connection_manager.stopTokenSweepTimerForLoop(loop.id);
                if (loop.id == 0) {
                    self.actions_service.stopSweepTimer();
                    if (self.jwks) |jc| jc.stopRefreshTimer();
                }
                if (loop.websocket_server.listen_socket) |ls| {
                    uws_c.us_listen_socket_close(if (loop.websocket_server.ssl) 1 else 0, ls);
                    loop.websocket_server.listen_socket = null;
                }
                self.connection_manager.sendDisconnectToAllForLoop(loop.id, "SERVER_SHUTDOWN", "Server is shutting down.", 4002);
                if (self.connection_manager.countForLoop(loop.id) != 0) {
                    if (loop.websocket_server.loop.load(.acquire)) |reactor| {
                        loop.shutdown_timer = uws_timer.startTimer(
                            EventLoopContext,
                            loop,
                            reactor,
                            shutdownLoopTimeoutCallback,
                            3_000,
                            0,
                        ) catch |err| blk: {
                            std.log.warn("Failed to arm shutdown timeout on loop {}: {}", .{ loop.id, err });
                            break :blk null;
                        };
                    }
                } else {
                    loop.app_closed = true;
                    closeLoop(loop);
                }
            } else if (!loop.app_closed and self.connection_manager.countForLoop(loop.id) == 0) {
                loop.app_closed = true;
                closeLoop(loop);
            }
            return;
        }
        // Flush staged action forwards first so their queue entries are drained
        // in this same post-handler pass.
        if (loop.id == 0) {
            self.actions_service.lock();
            defer self.actions_service.unlock();
            self.actions_service.flushOutbox();
        }
        self.connection_manager.drainSendQueue(&self.send_queue, loop.id);
    }
    fn shutdownLoopTimeoutCallback(t: ?*uws_c.struct_us_timer_t) callconv(.c) void {
        const timer = t orelse return;
        const loop = uws_timer.extractPtr(EventLoopContext, timer);
        if (loop.app_closed) return;
        loop.app_closed = true;
        closeLoop(loop);
    }
    fn verifyTicketCallback(user_data: ?*anyopaque, ticket: []const u8, allocator: std.mem.Allocator) anyerror!Session {
        if (user_data == null) return error.AuthFailed;
        const self: *ZyncBaseServer = @ptrCast(@alignCast(user_data.?));
        const te = self.ticket_exchange orelse return error.AuthFailed;
        return te.verifyTicket(allocator, ticket);
    }
};

/// Final reactor close: stop every timer the loop owns, then close its listener
/// and sockets. Application timers are non-fallthrough polls, so `us_loop_run`
/// cannot return while one is still open — including the grace timer whose own
/// callback runs this.
fn closeLoop(loop: *EventLoopContext) void {
    const self = loop.server;
    self.connection_manager.stopTokenSweepTimerForLoop(loop.id);
    if (loop.id == 0) {
        self.actions_service.stopSweepTimer();
        if (self.jwks) |jc| jc.stopRefreshTimer();
    }
    if (loop.websocket_server.listen_socket) |ls| {
        uws_c.us_listen_socket_close(if (loop.websocket_server.ssl) 1 else 0, ls);
        loop.websocket_server.listen_socket = null;
    }
    loop.websocket_server.close();
    uws_timer.stopTimer(&loop.shutdown_timer);
}

/// Signal handler for SIGTERM and SIGINT.
/// ASYNC-SIGNAL-SAFE: atomics, sigaction and raise only.
fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    // A second signal while the graceful path is still running means the
    // operator wants out now: restore the default action and re-raise so the
    // process dies with the conventional exit status instead of hanging on a
    // stuck flush.
    if (signal_seen.swap(true, .acq_rel)) {
        const default_action = std.posix.Sigaction{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(sig, &default_action, null);
        // libc raise directly: async-signal-safe, and the return value is
        // irrelevant because the default action terminates the process.
        _ = std.c.raise(sig);
        return;
    }

    pending_signal.store(true, .release);
    if (global_server.load(.acquire)) |server| {
        server.shutdown_requested.store(true, .release);
        for (0..server.event_loops.len) |index| {
            if (server.ws(index).loop.load(.acquire)) |loop| {
                uws_c.us_wakeup_loop(loop);
            }
        }
    }
}

fn storageEngineWakeup(ctx: ?*anyopaque) void {
    if (ctx == null) return;
    const server: *ZyncBaseServer = @ptrCast(@alignCast(ctx.?));
    for (0..server.event_loops.len) |index| {
        if (server.ws(index).loop.load(.acquire)) |loop| {
            uws_c.us_wakeup_loop(loop);
        }
    }
}
fn loopReadyDispatcher(ctx: ?*anyopaque, loop: ?*uws_c.struct_us_loop_t) void {
    if (ctx == null or loop == null) return;
    const loop_ctx: *EventLoopContext = @ptrCast(@alignCast(ctx.?));
    const server = loop_ctx.server;
    server.connection_manager.startTokenSweepTimer(loop_ctx.id, loop.?) catch |err| {
        std.log.err("Failed to start token sweep timer on loop {}: {}", .{ loop_ctx.id, err });
    };
    if (loop_ctx.id == 0) {
        server.actions_service.startSweepTimer(loop.?) catch |err| {
            std.log.err("Failed to start action deadline sweep timer: {}", .{err});
        };
        if (server.jwks) |jc| {
            jc.startRefreshTimer(loop.?) catch |err| {
                std.log.err("Failed to start JWKS refresh timer: {}", .{err});
            };
        }
    }
}

fn lastConnectionClosed(ctx: ?*anyopaque) void {
    if (ctx == null) return;
    const server: *ZyncBaseServer = @ptrCast(@alignCast(ctx.?));
    for (0..server.event_loops.len) |index| {
        if (server.ws(index).loop.load(.acquire)) |loop| {
            uws_c.us_wakeup_loop(loop);
        }
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
    reason: []const u8,
    user_data: ?*anyopaque,
) void {
    const server: *ZyncBaseServer = @ptrCast(@alignCast(user_data.?));
    server.connection_manager.onClose(ws, code, reason);
}
