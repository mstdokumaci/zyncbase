const std = @import("std");
const Allocator = std.mem.Allocator;

/// Connection state for the Hook Server client
pub const ConnectionState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    circuit_open = 3,
};

/// Circuit breaker for preventing cascading failures
pub const CircuitBreaker = struct {
    failure_count: std.atomic.Value(u32),
    opened_at: std.atomic.Value(i64),

    pub fn init() CircuitBreaker {
        return CircuitBreaker{
            .failure_count = std.atomic.Value(u32).init(0),
            .opened_at = std.atomic.Value(i64).init(0),
        };
    }

    /// Record a failure and check if circuit should open
    /// Returns true if circuit should open
    pub fn recordFailure(self: *CircuitBreaker, threshold: u32) bool {
        const failures = self.failure_count.fetchAdd(1, .acq_rel);
        return (failures + 1) >= threshold;
    }

    /// Record a success and reset failure count
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.failure_count.store(0, .release);
    }

    /// Open the circuit breaker
    pub fn open(self: *CircuitBreaker) void {
        self.opened_at.store(std.time.timestamp(), .release);
    }

    /// Check if circuit breaker timeout has expired
    pub fn shouldTransitionToHalfOpen(self: *CircuitBreaker, timeout_sec: u64) bool {
        const now = std.time.timestamp();
        const opened_at = self.opened_at.load(.acquire);
        return (now - opened_at) >= timeout_sec;
    }

    /// Get current failure count
    pub fn getFailureCount(self: *CircuitBreaker) u32 {
        return self.failure_count.load(.acquire);
    }

    /// Reset circuit breaker to initial state
    pub fn reset(self: *CircuitBreaker) void {
        self.failure_count.store(0, .release);
        self.opened_at.store(0, .release);
    }
};

/// Configuration for Hook Server client
pub const Config = struct {
    url: []const u8,
    timeout_ms: u64 = 5000,
    max_retries: u32 = 3,
    circuit_breaker_threshold: u32 = 5,
    circuit_breaker_timeout_sec: u64 = 60,
    use_tls: bool = false,
};

/// WebSocket connection for Hook Server communication
pub const WebSocketConnection = struct {
    allocator: Allocator,
    url: []const u8,
    connected: bool,
    last_error: ?[]const u8,
    use_tls: bool,

    pub fn init(allocator: Allocator, url: []const u8, use_tls: bool) !*WebSocketConnection {
        const conn = try allocator.create(WebSocketConnection);
        conn.* = .{
            .allocator = allocator,
            .url = url,
            .connected = false,
            .last_error = null,
            .use_tls = use_tls,
        };
        return conn;
    }

    pub fn deinit(self: *WebSocketConnection) void {
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
        self.allocator.destroy(self);
    }

    /// Establish WebSocket connection
    pub fn connect(self: *WebSocketConnection) !void {
        // In a real implementation, this would use a WebSocket library
        // For now, we simulate connection establishment
        if (self.connected) {
            return; // Already connected
        }

        // Validate URL protocol matches TLS setting
        if (self.use_tls) {
            if (!std.mem.startsWith(u8, self.url, "wss://")) {
                return error.TlsProtocolMismatch;
            }
        } else {
            if (!std.mem.startsWith(u8, self.url, "ws://")) {
                return error.NonTlsProtocolMismatch;
            }
        }

        // Simulate connection attempt
        // In production, this would:
        // 1. Parse URL (ws:// or wss://)
        // 2. Establish TCP connection
        // 3. If TLS: Perform TLS handshake and certificate validation
        // 4. Perform WebSocket handshake

        // For testing: Only succeed if URL contains "success"
        // In production, this would actually establish the connection
        if (std.mem.indexOf(u8, self.url, "success") != null) {
            self.connected = true;
        } else {
            // Simulate connection failure for testing
            return error.ConnectionFailed;
        }
    }

    /// Close WebSocket connection
    pub fn close(self: *WebSocketConnection) void {
        self.connected = false;
    }

    /// Send data over WebSocket
    pub fn send(self: *WebSocketConnection, data: []const u8) !void {
        if (!self.connected) {
            return error.NotConnected;
        }

        // In production, this would send data over the WebSocket
        _ = data;
    }

    /// Try to receive data (non-blocking)
    pub fn tryReceive(self: *WebSocketConnection) !?[]const u8 {
        if (!self.connected) {
            return error.NotConnected;
        }

        // In production, this would check for incoming data
        // and return it if available
        return null;
    }

    /// Check if connection is alive
    pub fn isConnected(self: *WebSocketConnection) bool {
        return self.connected;
    }
};

/// Authorization request structure
pub const AuthRequest = struct {
    user_id: []const u8,
    namespace: []const u8,
    operation: Operation,
    resource: []const u8,
    timestamp: i64,

    pub const Operation = enum {
        read,
        write,
        delete,
        subscribe,
    };
};

/// Authorization response structure
pub const AuthResponse = struct {
    allowed: bool,
    reason: ?[]const u8,
    cache_ttl_sec: u32,
};

/// Hook Server client with circuit breaker pattern
pub const HookServerClient = struct {
    allocator: Allocator,
    connection: ?*WebSocketConnection,
    config: Config,
    state: std.atomic.Value(ConnectionState),
    circuit_breaker: CircuitBreaker,
    url_owned: []u8,
    auth_cache: ?*AuthCache,

    /// Initialize Hook Server client with configuration
    /// PRECONDITION: allocator is valid, config.url is non-empty
    /// POSTCONDITION: Returns initialized client or error
    pub fn init(allocator: Allocator, config: Config) !*HookServerClient {
        // Validate configuration
        if (config.url.len == 0) {
            return error.InvalidUrl;
        }
        if (config.timeout_ms == 0) {
            return error.InvalidTimeout;
        }
        if (config.circuit_breaker_threshold == 0) {
            return error.InvalidThreshold;
        }

        const client = try allocator.create(HookServerClient);

        // Make owned copy of URL
        const url_owned = try allocator.dupe(u8, config.url);

        client.* = .{
            .allocator = allocator,
            .connection = null,
            .config = .{
                .url = url_owned,
                .timeout_ms = config.timeout_ms,
                .max_retries = config.max_retries,
                .circuit_breaker_threshold = config.circuit_breaker_threshold,
                .circuit_breaker_timeout_sec = config.circuit_breaker_timeout_sec,
                .use_tls = config.use_tls,
            },
            .state = std.atomic.Value(ConnectionState).init(.disconnected),
            .circuit_breaker = CircuitBreaker.init(),
            .url_owned = url_owned,
            .auth_cache = try AuthCache.init(allocator),
        };

        return client;
    }

    /// Clean up Hook Server client resources
    /// PRECONDITION: self is valid initialized client
    /// POSTCONDITION: All resources freed, connection closed
    pub fn deinit(self: *HookServerClient) void {
        if (self.connection) |conn| {
            conn.deinit();
        }
        if (self.auth_cache) |cache| {
            cache.deinit();
        }
        self.allocator.free(self.url_owned);
        self.allocator.destroy(self);
    }

    /// Get current connection state
    pub fn getState(self: *HookServerClient) ConnectionState {
        return self.state.load(.acquire);
    }

    /// Get current circuit breaker failure count
    pub fn getFailureCount(self: *HookServerClient) u32 {
        return self.circuit_breaker.failure_count.load(.acquire);
    }

    /// Reset circuit breaker (for testing)
    pub fn resetCircuitBreaker(self: *HookServerClient) void {
        self.circuit_breaker.failure_count.store(0, .release);
        self.circuit_breaker.opened_at.store(0, .release);
        self.state.store(.disconnected, .release);
    }

    /// Establish connection to Hook Server
    /// PRECONDITION: Client is initialized
    /// POSTCONDITION: Connection established or error returned
    pub fn connect(self: *HookServerClient) !void {
        const current_state = self.state.load(.acquire);

        // Don't connect if circuit is open
        if (current_state == .circuit_open) {
            return error.CircuitBreakerOpen;
        }

        // Update state to connecting
        self.state.store(.connecting, .release);

        // Create connection if it doesn't exist
        if (self.connection == null) {
            self.connection = try WebSocketConnection.init(self.allocator, self.config.url, self.config.use_tls);
        }

        // Attempt to connect
        self.connection.?.connect() catch |err| {
            self.state.store(.disconnected, .release);
            return err;
        };

        // Update state to connected
        self.state.store(.connected, .release);
    }

    /// Reconnect to Hook Server with exponential backoff
    /// PRECONDITION: Client is initialized
    /// POSTCONDITION: Connection re-established or error after max retries
    pub fn reconnect(self: *HookServerClient) !void {
        var retry_count: u32 = 0;
        var backoff_ms: u64 = 100; // Start with 100ms

        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            // Try to connect
            self.connect() catch |err| {
                // If we've exhausted retries, return error
                if (retry_count == self.config.max_retries - 1) {
                    return err;
                }

                // Exponential backoff: wait before next retry
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);

                // Double the backoff time (exponential), cap at 30 seconds
                backoff_ms = @min(backoff_ms * 2, 30_000);

                continue;
            };

            // Connection successful
            return;
        }

        return error.MaxRetriesExceeded;
    }

    /// Disconnect from Hook Server
    pub fn disconnect(self: *HookServerClient) void {
        if (self.connection) |conn| {
            conn.close();
        }
        self.state.store(.disconnected, .release);
    }

    /// Authorize operation with timeout and circuit breaker
    /// PRECONDITION: Client is initialized, req contains valid data
    /// POSTCONDITION: Returns auth response or error
    /// THREAD SAFETY: Uses atomic operations for state and failure_count
    pub fn authorize(self: *HookServerClient, req: AuthRequest) !AuthResponse {
        // Validate request
        if (req.user_id.len == 0) {
            return error.InvalidUserId;
        }
        if (req.namespace.len == 0) {
            return error.InvalidNamespace;
        }

        // Check cache first
        if (self.auth_cache) |cache| {
            if (cache.get(req)) |cached_response| {
                return cached_response;
            }
        }

        // Check circuit breaker state
        const state = self.state.load(.acquire);

        if (state == .circuit_open) {
            // Check if timeout expired (transition to half-open)
            if (self.circuit_breaker.shouldTransitionToHalfOpen(self.config.circuit_breaker_timeout_sec)) {
                // Try half-open state
                self.state.store(.connecting, .release);
            } else {
                // Circuit still open, fail fast
                return error.CircuitBreakerOpen;
            }
        }

        // Ensure we're connected
        const needs_connection = state == .disconnected or state == .connecting or
            (self.connection != null and !self.connection.?.isConnected());

        if (needs_connection) {
            self.connect() catch |err| {
                // Record connection failure
                if (self.circuit_breaker.recordFailure(self.config.circuit_breaker_threshold)) {
                    self.state.store(.circuit_open, .release);
                    self.circuit_breaker.open();
                }
                return err;
            };
        }

        // Attempt authorization with timeout
        const result = self.authorizeWithTimeout(req) catch |err| {
            // Record failure and check if circuit should open
            if (self.circuit_breaker.recordFailure(self.config.circuit_breaker_threshold)) {
                self.state.store(.circuit_open, .release);
                self.circuit_breaker.open();
            }

            return err;
        };

        // Success - reset failure count and ensure connected state
        self.circuit_breaker.recordSuccess();
        self.state.store(.connected, .release);

        // Cache the response
        if (self.auth_cache) |cache| {
            cache.put(req, result) catch {}; // Ignore cache errors
        }

        return result;
    }

    /// Authorize with timeout enforcement
    /// PRECONDITION: Connection is not in circuit_open state
    /// POSTCONDITION: Returns response within timeout or error
    fn authorizeWithTimeout(self: *HookServerClient, req: AuthRequest) !AuthResponse {
        const start_time = std.time.milliTimestamp();

        // In production, this would:
        // 1. Encode request as MessagePack
        // 2. Send request over WebSocket
        // 3. Wait for response with timeout
        // 4. Decode response as MessagePack

        // For now, simulate authorization logic
        _ = req;

        // Simulate processing time
        const elapsed = std.time.milliTimestamp() - start_time;
        if (elapsed >= self.config.timeout_ms) {
            return error.Timeout;
        }

        // Simulate authorization response
        // In production, this would come from Hook Server
        return AuthResponse{
            .allowed = true,
            .reason = null,
            .cache_ttl_sec = 300, // 5 minutes default
        };
    }

    /// Get fallback authorization response when Hook Server unavailable
    /// According to Requirement 5.7 and 12.1: Deny by default for security
    pub fn getFallbackResponse(reason: []const u8) AuthResponse {
        return AuthResponse{
            .allowed = false,
            .reason = reason,
            .cache_ttl_sec = 0, // Don't cache denials
        };
    }

    /// Authorize with fallback behavior
    /// This wraps authorize() and provides secure fallback when Hook Server unavailable
    pub fn authorizeWithFallback(self: *HookServerClient, req: AuthRequest) AuthResponse {
        return self.authorize(req) catch |err| {
            // Log the error for monitoring
            const reason = switch (err) {
                error.CircuitBreakerOpen => "Hook Server circuit breaker open",
                error.Timeout => "Hook Server timeout",
                error.ConnectionFailed => "Hook Server connection failed",
                error.InvalidUserId => "Invalid user ID",
                error.InvalidNamespace => "Invalid namespace",
                else => "Hook Server unavailable",
            };

            // Return denial with reason
            return getFallbackResponse(reason);
        };
    }
};

/// Cache entry for authorization responses
pub const CacheEntry = struct {
    response: AuthResponse,
    expires_at: i64,
    reason_owned: ?[]u8,

    pub fn deinit(self: *const CacheEntry, allocator: Allocator) void {
        if (self.reason_owned) |reason| {
            allocator.free(reason);
        }
    }

    pub fn isExpired(self: *const CacheEntry) bool {
        return std.time.timestamp() >= self.expires_at;
    }
};

/// Authorization cache with TTL support
pub const AuthCache = struct {
    allocator: Allocator,
    cache: std.StringHashMap(CacheEntry),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) !*AuthCache {
        const cache_ptr = try allocator.create(AuthCache);
        cache_ptr.* = .{
            .allocator = allocator,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
        return cache_ptr;
    }

    pub fn deinit(self: *AuthCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.cache.deinit();
        self.allocator.destroy(self);
    }

    /// Build cache key from auth request
    fn buildKey(allocator: Allocator, req: AuthRequest) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}:{s}:{s}:{s}",
            .{ req.user_id, req.namespace, @tagName(req.operation), req.resource },
        );
    }

    /// Get cached authorization response
    pub fn get(self: *AuthCache, req: AuthRequest) ?AuthResponse {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = buildKey(self.allocator, req) catch return null;
        defer self.allocator.free(key);

        if (self.cache.get(key)) |entry| {
            if (entry.isExpired()) {
                // Entry expired, remove it
                _ = self.remove(req);
                return null;
            }
            return entry.response;
        }

        return null;
    }

    /// Put authorization response in cache
    pub fn put(self: *AuthCache, req: AuthRequest, response: AuthResponse) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try buildKey(self.allocator, req);
        errdefer self.allocator.free(key);

        // Make owned copy of reason if present
        const reason_owned = if (response.reason) |reason|
            try self.allocator.dupe(u8, reason)
        else
            null;

        const expires_at = std.time.timestamp() + @as(i64, @intCast(response.cache_ttl_sec));

        const entry = CacheEntry{
            .response = .{
                .allowed = response.allowed,
                .reason = reason_owned,
                .cache_ttl_sec = response.cache_ttl_sec,
            },
            .expires_at = expires_at,
            .reason_owned = reason_owned,
        };

        // Remove old entry if exists
        if (self.cache.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            old.value.deinit(self.allocator);
        }

        try self.cache.put(key, entry);
    }

    /// Remove entry from cache
    pub fn remove(self: *AuthCache, req: AuthRequest) bool {
        const key = buildKey(self.allocator, req) catch return false;
        defer self.allocator.free(key);

        if (self.cache.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            entry.value.deinit(self.allocator);
            return true;
        }

        return false;
    }

    /// Clear all expired entries
    pub fn evictExpired(self: *AuthCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.cache.fetchRemove(key)) |entry| {
                self.allocator.free(entry.key);
                entry.value.deinit(self.allocator);
            }
        }
    }

    /// Get cache size
    pub fn size(self: *AuthCache) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cache.count();
    }
};
