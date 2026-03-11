const std = @import("std");
const testing = std.testing;
const hook_server = @import("hook_server_client.zig");

const HookServerClient = hook_server.HookServerClient;
const AuthRequest = hook_server.AuthRequest;
const ConnectionState = hook_server.ConnectionState;

// **Property 5: Hook Server Circuit Breaker**
// **Validates: Requirements 5.3, 5.4, 5.5**
//
// This property test verifies that the circuit breaker correctly:
// 1. Opens after threshold failures
// 2. Fails fast when circuit is open
// 3. Transitions to half-open after timeout
// 4. Closes on successful request in half-open state
test "Property 5: Circuit breaker opens after threshold failures" {
    const allocator = testing.allocator;

    // Create client with low threshold for testing
    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 100,
        .max_retries = 1,
        .circuit_breaker_threshold = 3, // Open after 3 failures
        .circuit_breaker_timeout_sec = 2, // 2 second timeout for testing
        .use_tls = false,
    });
    defer client.deinit();

    // Create a test request
    const req = AuthRequest{
        .user_id = "test-user",
        .namespace = "test-namespace",
        .operation = .read,
        .resource = "test-resource",
        .timestamp = std.time.timestamp(),
    };

    // Simulate failures by not connecting
    // Each authorize call should fail and increment failure count
    var failure_count: u32 = 0;
    while (failure_count < 3) : (failure_count += 1) {
        const result = client.authorize(req);
        try testing.expectError(error.ConnectionFailed, result);

        // Verify failure count incremented
        const current_failures = client.getFailureCount();
        try testing.expectEqual(failure_count + 1, current_failures);
    }

    // After 3 failures, circuit should be open
    try testing.expectEqual(ConnectionState.circuit_open, client.getState());

    // Next request should fail fast with CircuitBreakerOpen
    const result = client.authorize(req);
    try testing.expectError(error.CircuitBreakerOpen, result);

    // Failure count should not increase (circuit is open, not trying)
    try testing.expectEqual(@as(u32, 3), client.getFailureCount());
}

test "Property 5: Circuit breaker transitions to half-open after timeout" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 100,
        .max_retries = 1,
        .circuit_breaker_threshold = 2,
        .circuit_breaker_timeout_sec = 1, // 1 second timeout
        .use_tls = false,
    });
    defer client.deinit();

    const req = AuthRequest{
        .user_id = "test-user",
        .namespace = "test-namespace",
        .operation = .read,
        .resource = "test-resource",
        .timestamp = std.time.timestamp(),
    };

    // Cause 2 failures to open circuit
    _ = client.authorize(req) catch {};
    _ = client.authorize(req) catch {};

    // Circuit should be open
    try testing.expectEqual(ConnectionState.circuit_open, client.getState());

    // Wait for timeout to expire
    std.Thread.sleep(1100 * std.time.ns_per_ms); // 1.1 seconds

    // Next request should attempt to connect (half-open state)
    // It will fail because we're not actually connected, but state should change
    const result = client.authorize(req);

    // Should get ConnectionFailed error, not CircuitBreakerOpen
    // This proves the circuit transitioned to half-open
    try testing.expectError(error.ConnectionFailed, result);
}

test "Property 5: Circuit breaker resets on successful authorization" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 5000,
        .max_retries = 1,
        .circuit_breaker_threshold = 5,
        .circuit_breaker_timeout_sec = 60,
        .use_tls = false,
    });
    defer client.deinit();

    const req = AuthRequest{
        .user_id = "test-user",
        .namespace = "test-namespace",
        .operation = .read,
        .resource = "test-resource",
        .timestamp = std.time.timestamp(),
    };

    // Cause some failures
    _ = client.authorize(req) catch {};
    _ = client.authorize(req) catch {};

    // Verify failures recorded
    try testing.expect(client.getFailureCount() > 0);

    // Now connect and authorize successfully
    // Need to recreate connection with success URL
    if (client.connection) |conn| {
        conn.deinit();
    }
    client.connection = try hook_server.WebSocketConnection.init(allocator, "ws://localhost:3001/success", false);
    try client.connection.?.connect();
    const result = try client.authorize(req);

    // Verify success
    try testing.expect(result.allowed);

    // Verify failure count reset to 0
    try testing.expectEqual(@as(u32, 0), client.getFailureCount());

    // Verify state is connected
    try testing.expectEqual(ConnectionState.connected, client.getState());
}

test "Property 5: Fail-fast latency when circuit open" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 5000, // 5 second timeout
        .max_retries = 1,
        .circuit_breaker_threshold = 2,
        .circuit_breaker_timeout_sec = 60,
        .use_tls = false,
    });
    defer client.deinit();

    const req = AuthRequest{
        .user_id = "test-user",
        .namespace = "test-namespace",
        .operation = .read,
        .resource = "test-resource",
        .timestamp = std.time.timestamp(),
    };

    // Open the circuit
    _ = client.authorize(req) catch {};
    _ = client.authorize(req) catch {};
    try testing.expectEqual(ConnectionState.circuit_open, client.getState());

    // Measure time for fail-fast response
    const start = std.time.milliTimestamp();
    const result = client.authorize(req);
    const elapsed = std.time.milliTimestamp() - start;

    // Should fail with CircuitBreakerOpen
    try testing.expectError(error.CircuitBreakerOpen, result);

    // Should be nearly instant (< 10ms), not wait for timeout
    try testing.expect(elapsed < 10);
}

test "Property 5: Authorization response caching" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001/success",
        .timeout_ms = 5000,
        .max_retries = 1,
        .circuit_breaker_threshold = 5,
        .circuit_breaker_timeout_sec = 60,
        .use_tls = false,
    });
    defer client.deinit();

    const req = AuthRequest{
        .user_id = "test-user",
        .namespace = "test-namespace",
        .operation = .read,
        .resource = "test-resource",
        .timestamp = std.time.timestamp(),
    };

    // Connect and authorize
    try client.connect();
    const result1 = try client.authorize(req);
    try testing.expect(result1.allowed);

    // Second request should be served from cache
    // We can verify this by checking the cache directly
    if (client.auth_cache) |cache| {
        const cached = cache.get(req);
        try testing.expect(cached != null);
        try testing.expectEqual(result1.allowed, cached.?.allowed);
    }

    // Authorize again - should get cached response
    const result2 = try client.authorize(req);
    try testing.expectEqual(result1.allowed, result2.allowed);
}

test "Property 5: Cache eviction on TTL expiration" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 5000,
        .max_retries = 1,
        .circuit_breaker_threshold = 5,
        .circuit_breaker_timeout_sec = 60,
        .use_tls = false,
    });
    defer client.deinit();

    // Create a cache entry with short TTL
    if (client.auth_cache) |cache| {
        const req = AuthRequest{
            .user_id = "test-user",
            .namespace = "test-namespace",
            .operation = .read,
            .resource = "test-resource",
            .timestamp = std.time.timestamp(),
        };

        const response = hook_server.AuthResponse{
            .allowed = true,
            .reason = null,
            .cache_ttl_sec = 1, // 1 second TTL
        };

        try cache.put(req, response);

        // Verify entry exists
        const cached1 = cache.get(req);
        try testing.expect(cached1 != null);

        // Wait for TTL to expire
        std.Thread.sleep(1100 * std.time.ns_per_ms); // 1.1 seconds

        // Entry should be expired and return null
        const cached2 = cache.get(req);
        try testing.expect(cached2 == null);
    }
}

test "Property 5: TLS protocol validation" {
    const allocator = testing.allocator;

    // Test wss:// with TLS enabled - should succeed
    {
        var client = try HookServerClient.init(allocator, .{
            .url = "wss://localhost:3001/success",
            .timeout_ms = 5000,
            .max_retries = 1,
            .circuit_breaker_threshold = 5,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = true,
        });
        defer client.deinit();

        // Should connect successfully
        try client.connect();
        try testing.expectEqual(ConnectionState.connected, client.getState());
    }

    // Test ws:// with TLS disabled - should succeed
    {
        var client = try HookServerClient.init(allocator, .{
            .url = "ws://localhost:3001/success",
            .timeout_ms = 5000,
            .max_retries = 1,
            .circuit_breaker_threshold = 5,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = false,
        });
        defer client.deinit();

        try client.connect();
        try testing.expectEqual(ConnectionState.connected, client.getState());
    }

    // Test wss:// with TLS disabled - should fail
    {
        var client = try HookServerClient.init(allocator, .{
            .url = "wss://localhost:3001",
            .timeout_ms = 5000,
            .max_retries = 1,
            .circuit_breaker_threshold = 5,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = false,
        });
        defer client.deinit();

        const result = client.connect();
        try testing.expectError(error.NonTlsProtocolMismatch, result);
    }

    // Test ws:// with TLS enabled - should fail
    {
        var client = try HookServerClient.init(allocator, .{
            .url = "ws://localhost:3001",
            .timeout_ms = 5000,
            .max_retries = 1,
            .circuit_breaker_threshold = 5,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = true,
        });
        defer client.deinit();

        const result = client.connect();
        try testing.expectError(error.TlsProtocolMismatch, result);
    }
}
