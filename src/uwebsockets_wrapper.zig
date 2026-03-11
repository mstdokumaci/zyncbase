const std = @import("std");
const Allocator = std.mem.Allocator;

/// Stable Zig API wrapping uWebSockets C++ interface
/// Provides version compatibility and isolates ZyncBase from uWebSockets API changes
pub const UWebSocketsWrapper = struct {
    app: ?*anyopaque, // Opaque pointer to uWS::App
    ssl_options: ?*anyopaque, // Opaque pointer to uWS::SSLOptions
    config: Config,
    allocator: Allocator,

    /// Configuration for WebSocket server
    pub const Config = struct {
        port: u16,
        ssl_cert_path: ?[]const u8 = null,
        ssl_key_path: ?[]const u8 = null,
        compression: bool = false,
        max_payload_length: usize = 10 * 1024 * 1024, // 10MB default
    };

    pub const Error = error{
        InvalidConfig,
        SSLCertNotFound,
        SSLKeyNotFound,
        InitFailed,
        ListenFailed,
        OutOfMemory,
    };

    /// Initialize UWebSocketsWrapper with configuration
    /// PRECONDITION: config is valid with existing SSL files if paths provided
    /// POSTCONDITION: Returns initialized wrapper or error
    pub fn init(allocator: Allocator, config: Config) Error!*UWebSocketsWrapper {
        // Validate configuration
        if (config.port == 0) {
            return error.InvalidConfig;
        }

        // Validate both SSL paths provided together
        if ((config.ssl_cert_path != null) != (config.ssl_key_path != null)) {
            return error.InvalidConfig;
        }

        // Validate SSL certificate files if provided
        if (config.ssl_cert_path) |cert_path| {
            std.fs.cwd().access(cert_path, .{}) catch {
                return error.SSLCertNotFound;
            };
        }

        if (config.ssl_key_path) |key_path| {
            std.fs.cwd().access(key_path, .{}) catch {
                return error.SSLKeyNotFound;
            };
        }

        const wrapper = try allocator.create(UWebSocketsWrapper);
        wrapper.* = .{
            .app = null, // Will be initialized by C++ bindings
            .ssl_options = null, // Will be initialized if SSL configured
            .config = config,
            .allocator = allocator,
        };

        return wrapper;
    }

    /// Clean up resources
    /// PRECONDITION: wrapper is initialized
    /// POSTCONDITION: All resources freed
    pub fn deinit(self: *UWebSocketsWrapper) void {
        // C++ bindings will handle cleanup of app and ssl_options
        // through external functions
        self.allocator.destroy(self);
    }

    /// Load SSL/TLS configuration if certificate paths provided
    /// PRECONDITION: SSL certificate and key files exist and are readable
    /// POSTCONDITION: SSL options configured or error returned
    fn loadSSLConfig(self: *UWebSocketsWrapper) Error!void {
        if (self.config.ssl_cert_path == null or self.config.ssl_key_path == null) {
            return; // No SSL configuration needed
        }

        // SSL configuration will be handled by C++ bindings
        // The C++ code will:
        // 1. Read certificate file from ssl_cert_path
        // 2. Read key file from ssl_key_path
        // 3. Create uWS::SSLOptions with certificate data
        // 4. Store in self.ssl_options

        // For now, we just validate the files are accessible
        // The actual SSL setup happens in the C++ layer
        return;
    }

    /// Start listening on configured port
    /// PRECONDITION: wrapper is initialized
    /// POSTCONDITION: Server listening or error returned
    pub fn listen(self: *UWebSocketsWrapper) Error!void {
        // Load SSL configuration if needed
        try self.loadSSLConfig();

        // This will be implemented by C++ bindings
        // For now, return success to allow compilation
        return;
    }

    /// Run the event loop
    /// PRECONDITION: listen() has been called successfully
    /// POSTCONDITION: Event loop running (blocks until shutdown)
    pub fn run(self: *UWebSocketsWrapper) void {
        _ = self;
        // This will be implemented by C++ bindings
        // The C++ code will:
        // 1. Configure compression based on self.config.compression
        // 2. Set max_payload_length limit from self.config.max_payload_length
        // 3. Start the uWebSockets event loop
        // 4. Block until shutdown signal received

        // Event loop will run until shutdown signal
    }

    /// Shutdown the server gracefully
    /// PRECONDITION: Server is running
    /// POSTCONDITION: Server stopped, connections closed
    pub fn shutdown(self: *UWebSocketsWrapper) void {
        _ = self;
        // This will be implemented by C++ bindings
        // The C++ code will:
        // 1. Stop accepting new connections
        // 2. Close existing connections gracefully
        // 3. Exit the event loop
    }

    /// Get current server status
    pub const ServerStatus = struct {
        is_running: bool,
        active_connections: usize,
        port: u16,
        ssl_enabled: bool,
    };

    pub fn getStatus(self: *UWebSocketsWrapper) ServerStatus {
        return .{
            .is_running = self.app != null,
            .active_connections = 0, // Will be tracked by C++ bindings
            .port = self.config.port,
            .ssl_enabled = self.config.ssl_cert_path != null,
        };
    }
};
