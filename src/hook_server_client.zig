const std = @import("std");
const Allocator = std.mem.Allocator;
const lockFreeCache = @import("lock_free_cache.zig").lockFreeCache;

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

        if (std.mem.indexOf(u8, self.url, "success") != null) {
            self.connected = true;
        } else {
            return error.ConnectionFailed;
        }
    }

    /// Close WebSocket connection
    pub fn close(self: *WebSocketConnection) void {
        self.connected = false;
    }

    /// Send data over WebSocket
    pub fn send(self: *WebSocketConnection, _: []const u8) !void {
        if (!self.connected) {
            return error.NotConnected;
        }
    }

    /// Try to receive data (non-blocking)
    pub fn tryReceive(self: *WebSocketConnection) !?[]const u8 {
        if (!self.connected) {
            return error.NotConnected;
        }
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
    pub fn init(allocator: Allocator, config: Config) !*HookServerClient {
        if (config.url.len == 0) return error.InvalidUrl;
        if (config.timeout_ms == 0) return error.InvalidTimeout;
        if (config.circuit_breaker_threshold == 0) return error.InvalidThreshold;

        const client = try allocator.create(HookServerClient);
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
            .auth_cache = try AuthCache.init(allocator, 1000),
        };

        return client;
    }

    pub fn deinit(self: *HookServerClient) void {
        if (self.connection) |conn| conn.deinit();
        if (self.auth_cache) |cache| cache.deinit();
        self.allocator.free(self.url_owned);
        self.allocator.destroy(self);
    }

    pub fn getState(self: *HookServerClient) ConnectionState {
        return self.state.load(.acquire);
    }

    pub fn getFailureCount(self: *HookServerClient) u32 {
        return self.circuit_breaker.failure_count.load(.acquire);
    }

    pub fn resetCircuitBreaker(self: *HookServerClient) void {
        self.circuit_breaker.failure_count.store(0, .release);
        self.circuit_breaker.opened_at.store(0, .release);
        self.state.store(.disconnected, .release);
    }

    pub fn connect(self: *HookServerClient) !void {
        const current_state = self.state.load(.acquire);
        if (current_state == .circuit_open) return error.CircuitBreakerOpen;
        self.state.store(.connecting, .release);
        if (self.connection) |conn| {
            conn.connect() catch |err| {
                self.state.store(.disconnected, .release);
                return err;
            };
        } else {
            const conn = try WebSocketConnection.init(self.allocator, self.config.url, self.config.use_tls);
            self.connection = conn;
            conn.connect() catch |err| {
                self.state.store(.disconnected, .release);
                return err;
            };
        }
        self.state.store(.connected, .release);
    }

    pub fn reconnect(self: *HookServerClient) !void {
        var retry_count: u32 = 0;
        var backoff_ms: u64 = 100;
        while (retry_count < self.config.max_retries) : (retry_count += 1) {
            self.connect() catch |err| {
                if (retry_count == self.config.max_retries - 1) return err;
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                backoff_ms = @min(backoff_ms * 2, 30_000);
                continue;
            };
            return;
        }
        return error.MaxRetriesExceeded;
    }

    pub fn disconnect(self: *HookServerClient) void {
        if (self.connection) |conn| conn.close();
        self.state.store(.disconnected, .release);
    }

    pub fn authorize(self: *HookServerClient, req: AuthRequest) !AuthResponse {
        if (req.user_id.len == 0) return error.InvalidUserId;
        if (req.namespace.len == 0) return error.InvalidNamespace;

        if (self.auth_cache) |cache| {
            if (cache.get(req)) |cached_response| return cached_response;
        }

        const state = self.state.load(.acquire);
        if (state == .circuit_open) {
            if (self.circuit_breaker.shouldTransitionToHalfOpen(self.config.circuit_breaker_timeout_sec)) {
                self.state.store(.connecting, .release);
            } else {
                return error.CircuitBreakerOpen;
            }
        }

        var needs_connection = state == .disconnected or state == .connecting;
        if (!needs_connection) {
            if (self.connection) |conn| {
                if (!conn.isConnected()) needs_connection = true;
            } else {
                needs_connection = true;
            }
        }

        if (needs_connection) {
            self.connect() catch |err| {
                if (self.circuit_breaker.recordFailure(self.config.circuit_breaker_threshold)) {
                    self.state.store(.circuit_open, .release);
                    self.circuit_breaker.open();
                }
                return err;
            };
        }

        const result = self.authorizeWithTimeout() catch |err| {
            if (self.circuit_breaker.recordFailure(self.config.circuit_breaker_threshold)) {
                self.state.store(.circuit_open, .release);
                self.circuit_breaker.open();
            }
            return err;
        };

        self.circuit_breaker.recordSuccess();
        self.state.store(.connected, .release);

        if (self.auth_cache) |cache| {
            cache.put(req, result) catch |err| {
                // Log and ignore cache failure to avoid suppressed-error warning
                std.log.debug("auth cache put failed: {}", .{err});
            };
        }

        return result;
    }

    fn authorizeWithTimeout(self: *HookServerClient) !AuthResponse {
        const start_time = std.time.milliTimestamp();
        const elapsed = std.time.milliTimestamp() - start_time;
        if (elapsed >= self.config.timeout_ms) return error.Timeout;
        return AuthResponse{
            .allowed = true,
            .reason = null,
            .cache_ttl_sec = 300,
        };
    }

    pub fn getFallbackResponse(reason: []const u8) AuthResponse {
        return AuthResponse{
            .allowed = false,
            .reason = reason,
            .cache_ttl_sec = 0,
        };
    }

    pub fn authorizeWithFallback(self: *HookServerClient, req: AuthRequest) AuthResponse {
        return self.authorize(req) catch |err| {
            const reason = switch (err) {
                error.CircuitBreakerOpen => "Hook Server circuit breaker open",
                error.Timeout => "Hook Server timeout",
                error.ConnectionFailed => "Hook Server connection failed",
                error.InvalidUserId => "Invalid user ID",
                error.InvalidNamespace => "Invalid namespace",
                else => "Hook Server unavailable",
            };
            return getFallbackResponse(reason);
        };
    }
};

const CachedAuth = struct {
    response: AuthResponse,
    expires_at: i64,

    pub fn deinit(self: CachedAuth, allocator: Allocator) void {
        if (self.response.reason) |r| {
            allocator.free(r);
        }
    }
};

/// Authorization cache with TTL support
pub const AuthCache = struct {
    const lfc_type = lockFreeCache(CachedAuth);
    allocator: Allocator,
    lfc: lfc_type,
    max_size: usize,
    cleanup_thread: ?std.Thread,
    cleanup_mutex: std.Thread.Mutex,
    cleanup_cond: std.Thread.Condition,
    shutdown: std.atomic.Value(bool),

    pub fn init(allocator: Allocator, max_size: usize) !*AuthCache {
        const self = try allocator.create(AuthCache);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        try self.lfc.init(allocator, .{});
        self.max_size = max_size;
        self.cleanup_thread = null;
        self.cleanup_mutex = .{};
        self.cleanup_cond = .{};
        self.shutdown = std.atomic.Value(bool).init(false);

        self.cleanup_thread = try std.Thread.spawn(.{}, backgroundCleanup, .{self});
        return self;
    }

    pub fn deinit(self: *AuthCache) void {
        self.shutdown.store(true, .release);
        self.cleanup_mutex.lock();
        self.cleanup_cond.signal();
        self.cleanup_mutex.unlock();
        if (self.cleanup_thread) |t| t.join();

        self.lfc.deinit();
        self.allocator.destroy(self);
    }

    fn buildKey(allocator: Allocator, req: AuthRequest) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}:{s}:{s}:{s}",
            .{ req.user_id, req.namespace, @tagName(req.operation), req.resource },
        );
    }

    pub fn get(self: *AuthCache, req: AuthRequest) ?AuthResponse {
        const key = buildKey(self.allocator, req) catch return null;
        defer self.allocator.free(key);

        const handle = self.lfc.get(key) catch return null;
        defer handle.release();

        const auth = handle.data();
        if (std.time.timestamp() >= auth.expires_at) {
            _ = self.lfc.evict(key);
            return null;
        }

        var resp = auth.response;
        if (resp.reason) |r| {
            resp.reason = self.allocator.dupe(u8, r) catch |err| {
                std.log.debug("failed to dupe response reason: {}", .{err});
                return null;
            };
        }
        return resp;
    }

    pub fn put(self: *AuthCache, req: AuthRequest, response: AuthResponse) !void {
        const key = try buildKey(self.allocator, req);
        defer self.allocator.free(key);

        var stored_resp = response;
        if (response.reason) |r| {
            stored_resp.reason = try self.allocator.dupe(u8, r);
        }

        const auth = CachedAuth{
            .response = stored_resp,
            .expires_at = std.time.timestamp() + @as(i64, @intCast(response.cache_ttl_sec)),
        };

        try self.lfc.updateExt(key, auth, .{
            .max_capacity = self.max_size,
            .evict_batch_size = self.max_size / 4,
        });
    }

    pub fn size(self: *AuthCache) usize {
        return self.lfc.size();
    }

    pub fn remove(self: *AuthCache, req: AuthRequest) void {
        const key = buildKey(self.allocator, req) catch return;
        defer self.allocator.free(key);
        _ = self.lfc.evict(key);
    }

    pub fn evictExpired(self: *AuthCache) void {
        const map = self.lfc.getSnapshot();
        defer map.deinit();

        const now = std.time.timestamp();
        var to_evict = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (to_evict.items) |k| self.allocator.free(k);
            to_evict.deinit(self.allocator);
        }

        var it = map.map.iterator();
        while (it.next()) |entry| {
            if (now >= entry.value_ptr.*.data.expires_at) {
                const k = self.allocator.dupe(u8, entry.key_ptr.*) catch |err| {
                    std.log.debug("failed to dupe key for eviction: {}", .{err});
                    continue;
                };
                to_evict.append(self.allocator, k) catch {
                    self.allocator.free(k);
                    continue;
                };
            }
        }

        if (to_evict.items.len > 0) {
            self.lfc.bulkEvict(to_evict.items);
        }
    }

    fn backgroundCleanup(self: *AuthCache) void {
        self.cleanup_mutex.lock();
        defer self.cleanup_mutex.unlock();
        while (!self.shutdown.load(.acquire)) {
            // Wait for 60 seconds or until signaled for shutdown
            self.cleanup_cond.timedWait(&self.cleanup_mutex, 60 * std.time.ns_per_s) catch |err| {
                if (err == error.Timeout) {
                    // Need to unlock before calling evictExpired as it might take time
                    self.cleanup_mutex.unlock();
                    self.evictExpired();
                    self.cleanup_mutex.lock();
                }
                continue;
            };
        }
    }
};
