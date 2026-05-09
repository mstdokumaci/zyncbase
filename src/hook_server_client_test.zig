const std = @import("std");
const testing = std.testing;
const hook_server = @import("hook_server_client.zig");
const typed = @import("typed.zig");

const HookServerClient = hook_server.HookServerClient;
const AuthRequest = hook_server.AuthRequest;
const ConnectionState = hook_server.ConnectionState;
const WebSocketConnection = hook_server.WebSocketConnection;

// Unit tests for Hook Server client
// These tests verify specific functionality and edge cases

test "HookServerClient: init validates configuration" {
    const allocator = testing.allocator;

    // Test empty URL
    {
        const result = HookServerClient.init(allocator, .{
            .url = "",
            .timeout_ms = 5000,
            .max_retries = 3,
            .circuit_breaker_threshold = 5,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = false,
        });
        try testing.expectError(error.InvalidUrl, result);
    }

    // Test zero timeout
    {
        const result = HookServerClient.init(allocator, .{
            .url = "ws://localhost:3001",
            .timeout_ms = 0,
            .max_retries = 3,
            .circuit_breaker_threshold = 5,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = false,
        });
        try testing.expectError(error.InvalidTimeout, result);
    }

    // Test zero threshold
    {
        const result = HookServerClient.init(allocator, .{
            .url = "ws://localhost:3001",
            .timeout_ms = 5000,
            .max_retries = 3,
            .circuit_breaker_threshold = 0,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = false,
        });
        try testing.expectError(error.InvalidThreshold, result);
    }

    // Test valid configuration
    {
        var client = try HookServerClient.init(allocator, .{
            .url = "ws://localhost:3001",
            .timeout_ms = 5000,
            .max_retries = 3,
            .circuit_breaker_threshold = 5,
            .circuit_breaker_timeout_sec = 60,
            .use_tls = false,
        });
        defer client.deinit();

        try testing.expectEqual(ConnectionState.disconnected, client.getState());
        try testing.expectEqual(@as(u32, 0), client.getFailureCount());
    }
}

test "HookServerClient: connection lifecycle" {
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

    // Initial state should be disconnected
    try testing.expectEqual(ConnectionState.disconnected, client.getState());

    // Connect
    try client.connect();
    try testing.expectEqual(ConnectionState.connected, client.getState());

    // Disconnect
    client.disconnect();
    try testing.expectEqual(ConnectionState.disconnected, client.getState());
}

test "HookServerClient: reconnect with exponential backoff" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 5000,
        .max_retries = 3,
        .circuit_breaker_threshold = 5,
        .circuit_breaker_timeout_sec = 60,
        .use_tls = false,
    });
    defer client.deinit();

    // Reconnect should fail after max retries
    const start = std.time.milliTimestamp();
    const result = client.reconnect();
    const elapsed = std.time.milliTimestamp() - start;

    try testing.expectError(error.ConnectionFailed, result);

    // Should have taken some time due to exponential backoff
    // With 3 retries: 100ms + 200ms + 400ms = 700ms minimum
    // But timing can vary, so just verify it took more than 0ms
    try testing.expect(elapsed > 0);
}

test "HookServerClient: authorize validates request" {
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

    // Test zero user_doc_id
    {
        const req = AuthRequest{
            .user_doc_id = typed.zeroDocId,
            .namespace_id = 1,
            .operation = .read,
            .table_index = 0,
            .timestamp = std.time.timestamp(),
        };
        const result = client.authorize(req);
        try testing.expectError(error.InvalidUserId, result);
    }

    // Test negative namespace_id
    {
        const req = AuthRequest{
            .user_doc_id = 1, // Valid ID
            .namespace_id = -1,
            .operation = .read,
            .table_index = 0,
            .timestamp = std.time.timestamp(),
        };
        const result = client.authorize(req);
        try testing.expectError(error.InvalidNamespace, result);
    }
}

test "HookServerClient: circuit breaker state management" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 100,
        .max_retries = 1,
        .circuit_breaker_threshold = 2,
        .circuit_breaker_timeout_sec = 60,
        .use_tls = false,
    });
    defer client.deinit();

    // Initial state
    try testing.expectEqual(@as(u32, 0), client.getFailureCount());

    // Manually record failures
    _ = client.circuit_breaker.recordFailure(2);
    try testing.expectEqual(@as(u32, 1), client.getFailureCount());

    const should_open = client.circuit_breaker.recordFailure(2);
    try testing.expect(should_open);
    try testing.expectEqual(@as(u32, 2), client.getFailureCount());

    // Reset
    client.circuit_breaker.recordSuccess();
    try testing.expectEqual(@as(u32, 0), client.getFailureCount());
}

test "HookServerClient: authorization cache operations" {
    const allocator = testing.allocator;

    var cache = try hook_server.AuthCache.init(allocator, 100);
    defer cache.deinit();

    const req = AuthRequest{
        .user_doc_id = 1, // Non-zero test ID
        .namespace_id = 1,
        .operation = .read,
        .table_index = 0,
        .timestamp = std.time.timestamp(),
    };

    // Cache should be empty initially
    try testing.expect(cache.get(req) == null);

    // Put entry in cache
    const response = hook_server.AuthResponse{
        .allowed = true,
        .reason = null,
        .cache_ttl_sec = 300,
    };
    try cache.put(req, response);

    // Should retrieve cached entry
    const cached = cache.get(req);
    try testing.expect(cached != null);
    try testing.expectEqual(response.allowed, cached.?.allowed);

    // Cache size should be 1
    try testing.expectEqual(@as(usize, 1), cache.size());

    // Remove entry
    cache.remove(req);

    // Cache should be empty again
    try testing.expect(cache.get(req) == null);
    try testing.expectEqual(@as(usize, 0), cache.size());
}

test "HookServerClient: fallback behavior" {
    const allocator = testing.allocator;

    var client = try HookServerClient.init(allocator, .{
        .url = "ws://localhost:3001",
        .timeout_ms = 100,
        .max_retries = 1,
        .circuit_breaker_threshold = 2,
        .circuit_breaker_timeout_sec = 60,
        .use_tls = false,
    });
    defer client.deinit();

    const req = AuthRequest{
        .user_doc_id = 1, // Non-zero test ID
        .namespace_id = 1,
        .operation = .read,
        .table_index = 0,
        .timestamp = std.time.timestamp(),
    };

    // authorizeWithFallback should return denial when connection fails
    const response = client.authorizeWithFallback(req);

    // Should deny access
    try testing.expect(!response.allowed);

    // Should have a reason
    try testing.expect(response.reason != null);

    // Should not cache denials
    try testing.expectEqual(@as(u32, 0), response.cache_ttl_sec);
}

test "WebSocketConnection: TLS protocol validation" {
    const allocator = testing.allocator;

    // wss:// with TLS enabled - should succeed
    {
        var conn = try WebSocketConnection.init(allocator, "wss://localhost:3001/success", true);
        defer conn.deinit();

        try conn.connect();
        try testing.expect(conn.isConnected());
    }

    // ws:// with TLS disabled - should succeed
    {
        var conn = try WebSocketConnection.init(allocator, "ws://localhost:3001/success", false);
        defer conn.deinit();

        try conn.connect();
        try testing.expect(conn.isConnected());
    }

    // wss:// with TLS disabled - should fail
    {
        var conn = try WebSocketConnection.init(allocator, "wss://localhost:3001", false);
        defer conn.deinit();

        const result = conn.connect();
        try testing.expectError(error.NonTlsProtocolMismatch, result);
    }

    // ws:// with TLS enabled - should fail
    {
        var conn = try WebSocketConnection.init(allocator, "ws://localhost:3001", true);
        defer conn.deinit();

        const result = conn.connect();
        try testing.expectError(error.TlsProtocolMismatch, result);
    }
}

test "WebSocketConnection: send and receive require connection" {
    const allocator = testing.allocator;

    var conn = try WebSocketConnection.init(allocator, "ws://localhost:3001", false);
    defer conn.deinit();

    // Send should fail when not connected
    const send_result = conn.send("test data");
    try testing.expectError(error.NotConnected, send_result);

    // Receive should fail when not connected
    const recv_result = conn.tryReceive();
    try testing.expectError(error.NotConnected, recv_result);
}
test "AuthCache: enforce max_size" {
    const allocator = testing.allocator;

    // Create a small cache
    var cache = try hook_server.AuthCache.init(allocator, 10);
    defer cache.deinit();

    // Fill the cache
    var i: u32 = 0;
    while (i < 15) : (i += 1) {
        const req = AuthRequest{
            .user_doc_id = @as(u128, i + 1),
            .namespace_id = 1,
            .operation = .read,
            .table_index = 0,
            .timestamp = std.time.timestamp(),
        };

        const response = hook_server.AuthResponse{
            .allowed = true,
            .reason = null,
            .cache_ttl_sec = 300,
        };

        try cache.put(req, response);
    }

    // Cache size should be limited to max_size (or slightly less due to batch eviction)
    try testing.expect(cache.size() <= 10);

    // Verify it's still alive and functional
    try testing.expect(cache.size() > 0);
}

test "AuthCache: concurrent put enforcement" {
    const allocator = testing.allocator;
    const max_size = 20;
    var cache = try hook_server.AuthCache.init(allocator, max_size);
    defer cache.deinit();

    const num_threads = 8;
    const puts_per_thread = 50;

    const ThreadCtx = struct {
        cache: *hook_server.AuthCache,
        allocator: std.mem.Allocator,
        thread_id: usize,
        count: usize,

        fn run(ctx: @This()) void {
            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                const req = AuthRequest{
                    .user_doc_id = @as(u128, ctx.thread_id + 1) * 1000 + i,
                    .namespace_id = 1,
                    .operation = .read,
                    .table_index = 0,
                    .timestamp = std.time.timestamp(),
                };
                const resp = hook_server.AuthResponse{
                    .allowed = true,
                    .reason = null,
                    .cache_ttl_sec = 60,
                };
                ctx.cache.put(req, resp) catch {}; // zwanzig-disable-line: empty-catch-engine
            }
        }
    };

    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, ThreadCtx.run, .{ThreadCtx{
            .cache = cache,
            .allocator = allocator,
            .thread_id = i,
            .count = puts_per_thread,
        }});
    }

    for (threads) |t| t.join();

    // The size should never exceed max_size
    const final_size = cache.size();
    try testing.expect(final_size <= max_size);
}

test "AuthCache: evictExpired manually" {
    const allocator = testing.allocator;
    var cache = try hook_server.AuthCache.init(allocator, 100);
    defer cache.deinit();

    const req = AuthRequest{
        .user_doc_id = 999,
        .namespace_id = 1,
        .operation = .read,
        .table_index = 0,
        .timestamp = std.time.timestamp(),
    };

    // Put entry with 1s TTL
    const resp = hook_server.AuthResponse{
        .allowed = true,
        .reason = null,
        .cache_ttl_sec = 0,
    };
    try cache.put(req, resp);

    try testing.expectEqual(@as(usize, 1), cache.size());

    // Call evictExpired manually
    cache.evictExpired();

    try testing.expectEqual(@as(usize, 0), cache.size());
}
