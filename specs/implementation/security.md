# Security Model

**Drivers**: [Auth System](./auth-system.md), [Auth Exchange](./auth-exchange.md), [Networking Implementation](./networking.md)

This document describes the security mechanisms implemented inside ZyncBase. It covers the defense-in-depth layer model, the specific parser limits enforced in Zig, the circuit breaker contract for the Hook Server, and the rate limiter data structures.

---

## Defense-in-Depth Layer Model

ZyncBase enforces security at seven layers, each implemented in a specific component:

```
Layer 1: TLS (uWebSockets / BoringSSL)          — encrypts all client traffic
Layer 2: Rate Limiting (ConnectionLimiter)       — per-IP connection and message limits
Layer 3: Input Validation (MessagePack parser)   — enforces size/depth/type limits before any allocation
Layer 4: Authentication (AuthExchange)           — ticket validation on every new connection
Layer 5: Authorization (Hook Server client)      — per-operation policy check via Hook Server
Layer 6: Namespace Isolation (StorageLayer)      — every query is scoped to namespace_id
Layer 7: Audit Logging (SecurityLogger)          — structured log entry for every security event
```

Each layer is independent. A failure or bypass at one layer does not grant access — the next layer still applies.

---

## MessagePack Parser Limits

The parser enforces these limits before allocating any memory for the parsed value. Exceeding any limit closes the connection after `violation_threshold` violations.

```zig
pub const ParserConfig = struct {
    max_depth:         usize = 32,
    max_size:          usize = 10 * 1024 * 1024,  // 10 MB
    max_string_length: usize = 1 * 1024 * 1024,   // 1 MB
    max_array_length:  usize = 100_000,
    max_map_size:      usize = 100_000,
};
```

The parser is iterative (not recursive). It uses an explicit stack bounded by `max_depth`, so stack overflow is impossible regardless of input nesting.

### Violation Handling

```zig
pub const ViolationTracker = struct {
    count:     u32 = 0,
    threshold: u32 = 3,

    /// Returns true when the connection must be closed.
    pub fn record(self: *ViolationTracker, err: ParserError) bool {
        self.count += 1;
        logSecurityEvent(.msgpack_violation, err);
        return self.count >= self.threshold;
    }
};
```

After `threshold` violations the connection is closed with code `4000 + @intFromError(err)`.

---

## Circuit Breaker Contract

The Hook Server client wraps every authorization call in a circuit breaker. The breaker has three states:

```
Closed  ──(failures >= threshold)──▶  Open
  ▲                                     │
  │                                     │ (timeout elapsed)
  └──────(success)──── Half-Open ◀──────┘
```

| State | Behaviour |
|-------|-----------|
| Closed | Requests forwarded to Hook Server normally |
| Open | All authorization requests denied immediately (`error.CircuitOpen`) without contacting Hook Server |
| Half-Open | One probe request forwarded; success → Closed, failure → Open |

```zig
pub const CircuitBreaker = struct {
    state:             State = .closed,
    failure_count:     u32  = 0,
    failure_threshold: u32  = 5,
    open_timeout_ms:   u64  = 10_000,
    opened_at:         i64  = 0,

    pub fn call(self: *CircuitBreaker, req: AuthRequest) !AuthResponse {
        switch (self.state) {
            .open => {
                if (std.time.milliTimestamp() - self.opened_at >= self.open_timeout_ms) {
                    self.state = .half_open;
                } else {
                    return error.CircuitOpen;
                }
            },
            .closed, .half_open => {},
        }

        const result = hookServerClient.authorize(req) catch |err| {
            self.recordFailure();
            return err;
        };

        self.recordSuccess();
        return result;
    }

    fn recordFailure(self: *CircuitBreaker) void {
        self.failure_count += 1;
        if (self.failure_count >= self.failure_threshold) {
            self.state = .open;
            self.opened_at = std.time.milliTimestamp();
        }
    }

    fn recordSuccess(self: *CircuitBreaker) void {
        self.failure_count = 0;
        self.state = .closed;
    }
};
```

When the circuit is open, ZyncBase denies the operation and returns `error.ServiceUnavailable` to the client. It never fails open.

---

## Rate Limiter Data Structures

### Connection Limiter (per IP)

```zig
pub const ConnectionLimiter = struct {
    // ip_str -> active connection count
    counts: std.StringHashMap(u32),
    max_per_ip: u32 = 100,

    pub fn allow(self: *ConnectionLimiter, ip: []const u8) bool {
        const entry = self.counts.getOrPutValue(ip, 0) catch return false;
        if (entry.value_ptr.* >= self.max_per_ip) return false;
        entry.value_ptr.* += 1;
        return true;
    }

    pub fn release(self: *ConnectionLimiter, ip: []const u8) void {
        if (self.counts.getPtr(ip)) |count| {
            if (count.* > 0) count.* -= 1;
        }
    }
};
```

### Message Rate Limiter (per connection, token bucket)

```zig
pub const RateLimiter = struct {
    tokens:      f64,
    max_tokens:  f64 = 100.0,
    refill_rate: f64 = 100.0, // tokens per second
    last_refill: i64,

    pub fn consume(self: *RateLimiter) bool {
        const now = std.time.milliTimestamp();
        const elapsed_s = @as(f64, @floatFromInt(now - self.last_refill)) / 1000.0;
        self.tokens = @min(self.max_tokens, self.tokens + elapsed_s * self.refill_rate);
        self.last_refill = now;

        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }
};
```

---

## Namespace Isolation

Every SQLite query generated by the query engine includes a `WHERE namespace_id = ?` clause. The `namespace_id` is set from the ready store scope, never from client-supplied data in the operation payload. Cross-namespace access requires an explicit authorization grant from the Hook Server.

`$session.userId` is also scoped server state. It is resolved through the `users` table before store or presence operations are accepted, and it is never derived directly from a raw JWT subject or SDK client ID.

---

## Invariants & Error Conditions

| Invariant | Description |
|-----------|-------------|
| Fail-secure | When the circuit breaker is open or Hook Server times out, access is denied — never granted |
| Parser-before-alloc | No heap allocation occurs for message content until all parser limits pass |
| Namespace scoping | `namespace_id` in every query comes from `AuthContext`, not from the wire message |
| Violation threshold | A connection is closed after exactly `violation_threshold` parser violations |

| Error | Behaviour |
|-------|-----------|
| `error.CircuitOpen` | Deny operation, return `SERVICE_UNAVAILABLE` to client |
| `error.AuthTimeout` | Deny operation, return `UNAUTHORIZED` to client |
| `error.MaxDepthExceeded` | Record violation; close connection if threshold reached |
| `error.MaxSizeExceeded` | Record violation; close connection if threshold reached |

---

## Validation & Success Criteria

- [ ] TSan clean on all auth and rate-limiter paths
- [ ] Parser rejects depth > 32 and size > 10 MB (unit tests in `src/msgpack_parser_test.zig`)
- [ ] Circuit breaker transitions Closed → Open after 5 failures (unit test)
- [ ] Circuit breaker denies all requests while Open (unit test)
- [ ] Connection limiter blocks connection 101 from same IP (unit test)

### Verification Commands
```bash
zig test src/msgpack_parser_test.zig
zig test src/circuit_breaker_test.zig
zig test src/rate_limiter_test.zig
zig build test -Dsanitize=thread
```

---

## See Also
- [Auth System](./auth-system.md) — Hook Server authorization rules
- [Auth Exchange](./auth-exchange.md) — Ticket handshake and session enrichment
- [Sanitizers](./sanitizers.md) — TSan and GPA coverage
- [Networking Implementation](./networking.md) — TLS and connection lifecycle
