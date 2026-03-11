# Network Layer

**Last Updated**: 2026-03-09

---

## Overview

zyncBase uses uWebSockets (C++) as its networking foundation, integrated directly with Zig for maximum performance. This is the same engine that powers Bun, providing 200,000+ requests/second with microsecond latency.

**Key Innovation**: Direct Zig + uWebSockets integration = Bun-level performance without JavaScript overhead

---

## uWebSockets Architecture

### Core Components

```
┌─────────────────────────────────────────────────────┐
│  uWebSockets (C++)                                  │
│                                                     │
│  ┌───────────────────────────────────────────────┐ │
│  │  µSockets Foundation                          │ │
│  │  ┌─────────────┐  ┌─────────────┐            │ │
│  │  │  Eventing   │  │  Networking │            │ │
│  │  │  (epoll/    │  │  (TCP/UDP)  │            │ │
│  │  │   kqueue)   │  │             │            │ │
│  │  └─────────────┘  └─────────────┘            │ │
│  │  ┌─────────────────────────────────┐         │ │
│  │  │  Cryptography (TLS 1.3)         │         │ │
│  │  │  (BoringSSL)                    │         │ │
│  │  └─────────────────────────────────┘         │ │
│  └───────────────────────────────────────────────┘ │
│                                                     │
│  ┌───────────────────────────────────────────────┐ │
│  │  Multi-threaded Event Loop                    │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐   │ │
│  │  │ Thread 1 │  │ Thread 2 │  │ Thread N │   │ │
│  │  │ WebSocket│  │ WebSocket│  │ WebSocket│   │ │
│  │  │ + HTTP   │  │ + HTTP   │  │ + HTTP   │   │ │
│  │  └──────────┘  └──────────┘  └──────────┘   │ │
│  └───────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### Key Features

**1. Multi-threaded Event Loop**
- One app per thread model
- Shares listening port across threads
- Automatic load balancing
- Scales with CPU cores

**2. Zero-Copy I/O**
- Minimizes memory copies
- Direct buffer access
- Efficient data transfer
- Low CPU overhead

**3. Native Kernel Features**
- epoll on Linux
- kqueue on BSD/macOS
- IOCP on Windows
- Zero-abstraction penalty

---

## Zig Integration

### Build Configuration

```zig
// build.zig - Link uWebSockets
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "zyncBase-server",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    
    // Link C++ standard library
    exe.linkLibCpp();
    
    // Add uWebSockets source files
    exe.addIncludePath(.{ .path = "vendor/uWebSockets/src" });
    exe.addCSourceFiles(&.{
        "vendor/uWebSockets/src/App.h",
        "vendor/uWebSockets/src/HttpContext.h",
        "vendor/uWebSockets/src/HttpResponse.h",
        "vendor/uWebSockets/src/WebSocket.h",
    }, &.{
        "-std=c++20",
        "-fno-exceptions",
        "-fno-rtti",
    });
}
```

### Server Implementation

```zig
// src/websocket.zig
const uws = @cImport({
    @cDefine("UWS_NO_ZLIB", "1"); // Optional: disable compression
    @cInclude("uWebSockets/App.h");
});

pub const Server = struct {
    app: *uws.uWS_App,
    core: *CoreEngine,
    
    pub fn init(allocator: Allocator, core: *CoreEngine) !*Server {
        const app = uws.uWS_App_create(0, null);
        
        const self = try allocator.create(Server);
        self.* = .{
            .app = app,
            .core = core,
        };
        
        // Register WebSocket handlers
        uws.uWS_App_ws(app, "/*", .{
            .open = onOpen,
            .message = onMessage,
            .close = onClose,
        }, @ptrCast(self));
        
        return self;
    }
    
    fn onMessage(
        ws: *uws.uWS_WebSocket, 
        message: [*]const u8, 
        length: usize, 
        opcode: uws.uWS_OpCode, 
        user_data: ?*anyopaque
    ) callconv(.C) void {
        const self = @ptrCast(*Server, @alignCast(@alignOf(Server), user_data));
        
        // Parse MessagePack
        const msg = msgpack.decode(message[0..length]) catch return;
        
        // Process in core engine
        const response = self.core.handleMessage(msg) catch return;
        
        // Send response
        const bytes = msgpack.encode(response) catch return;
        uws.uWS_WebSocket_send(ws, bytes.ptr, bytes.len, .BINARY);
    }
    
    pub fn listen(self: *Server, port: u16) !void {
        uws.uWS_App_listen(self.app, port, null);
    }
    
    pub fn run(self: *Server) void {
        uws.uWS_App_run(self.app);
    }
};
```

---

## WebSocket Protocol

### Connection Lifecycle

```
┌─────────────────────────────────────────────────┐
│  1. HTTP Upgrade Request                        │
│     GET /ws HTTP/1.1                            │
│     Upgrade: websocket                          │
│     Connection: Upgrade                         │
│     Sec-WebSocket-Key: ...                      │
│     Sec-WebSocket-Version: 13                   │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  2. Handshake Validation                        │
│     - Validate Sec-WebSocket-Key                │
│     - Check Origin header (CSWSH prevention)    │
│     - Authenticate user (JWT/ticket)            │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  3. HTTP 101 Switching Protocols                │
│     HTTP/1.1 101 Switching Protocols            │
│     Upgrade: websocket                          │
│     Connection: Upgrade                         │
│     Sec-WebSocket-Accept: ...                   │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  4. WebSocket Connection Established            │
│     - Binary frames (MessagePack)               │
│     - Bidirectional communication               │
│     - Real-time state updates                   │
└─────────────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────┐
│  5. Connection Close                            │
│     - Clean shutdown                            │
│     - Clear presence data                       │
│     - Cleanup subscriptions                     │
└─────────────────────────────────────────────────┘
```

### Frame Format

WebSocket frames have minimal overhead:

```
┌─────────────────────────────────────────────────┐
│  Frame Header (2-6 bytes)                       │
│  ┌──────────┬──────────┬──────────┬──────────┐ │
│  │ FIN (1)  │ Opcode   │ Mask (1) │ Length   │ │
│  │          │ (4 bits) │          │ (7 bits) │ │
│  └──────────┴──────────┴──────────┴──────────┘ │
│                                                 │
│  Payload (MessagePack binary data)              │
│  ┌───────────────────────────────────────────┐ │
│  │  Efficient binary serialization           │ │
│  │  Small integers: 1 byte                   │ │
│  │  Short strings: 2-6 bytes overhead        │ │
│  └───────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

**Overhead**: Only 2-6 bytes per message (vs HTTP's 100+ bytes)

---

## MessagePack Serialization

### Why MessagePack?

**Advantages over JSON:**
- **Smaller payloads** - Binary encoding
- **Faster parsing** - No string parsing
- **Type safety** - Explicit types
- **Streaming** - Iterative parsing

**Comparison:**

| Format | Size | Parse Speed | Type Safety |
|--------|------|-------------|-------------|
| MessagePack | Smallest | Fastest | Strong |
| JSON | Large | Slow | Weak |
| Protobuf | Small | Fast | Very Strong |

### Message Format

```zig
const Message = struct {
    type: MessageType,
    id: u64, // Request ID
    namespace: []const u8,
    payload: union(MessageType) {
        subscribe: SubscribePayload,
        unsubscribe: UnsubscribePayload,
        query: QueryPayload,
        mutation: MutationPayload,
        presence: PresencePayload,
    },
};

const MessageType = enum {
    subscribe,
    unsubscribe,
    query,
    mutation,
    presence,
    response,
    error,
};
```

### Security: Iterative Parser

**Problem**: Recursive parsers can stack overflow on deeply nested data

**Solution**: Iterative parser with depth limits

```zig
const Parser = struct {
    max_depth: usize = 32,
    max_size: usize = 10 * 1024 * 1024, // 10MB
    
    pub fn parse(self: *Parser, data: []const u8) !Message {
        var depth: usize = 0;
        var pos: usize = 0;
        
        while (pos < data.len) {
            const byte = data[pos];
            
            // Check depth limit
            if (depth > self.max_depth) {
                return error.MaxDepthExceeded;
            }
            
            // Check size limit
            if (pos > self.max_size) {
                return error.MaxSizeExceeded;
            }
            
            // Parse iteratively (not recursively)
            // ...
        }
    }
};
```

**Protections:**
- **Depth bombs** - Deeply nested objects
- **Size bombs** - Excessive data
- **Stack overflow** - Recursive parsing
- **Memory exhaustion** - Unbounded allocation

---

## Connection Management

### Connection State

```zig
const Connection = struct {
    id: u64,
    socket: WebSocket,
    auth_context: AuthContext,
    subscriptions: ArrayList(SubscriptionId),
    presence: ?json.Value,
    
    pub fn send(self: *Connection, msg: Message) !void {
        const bytes = try msgpack.encode(msg);
        try self.socket.send(bytes);
    }
};
```

### Authentication

**Ticket-based authentication** (recommended):

*Note: The zyncBase SDK abstracts this process. Developers simply provide `createClient({ token: 'jwt' })`, and the SDK automatically performs this exchange under the hood to ensure the token never touches the `ws://` URL.*

```
1. Client requests ticket from HTTP endpoint
   POST /auth/ticket
   Authorization: Bearer <JWT>
   
2. Server validates JWT, returns short-lived ticket
   { "ticket": "abc123...", "expires": 1234567890 }
   
3. Client connects with ticket
   ws://server/ws?ticket=abc123...
   
4. Server validates ticket, establishes connection
```

**Why tickets?**
- Short-lived (5-10 minutes)
- Not logged in URLs
- Can be revoked
- Separate from long-lived JWTs

### Origin Validation

**Prevent Cross-Site WebSocket Hijacking (CSWSH):**

```zig
fn validateOrigin(origin: []const u8, allowed: []const []const u8) bool {
    for (allowed) |allowed_origin| {
        if (std.mem.eql(u8, origin, allowed_origin)) {
            return true;
        }
    }
    return false;
}
```

**Configuration:**
```json
{
  "security": {
    "allowedOrigins": [
      "https://app.example.com",
      "https://admin.example.com"
    ]
  }
}
```

---

## Performance Characteristics

### Throughput

| Metric | uWebSockets | Node.js | Deno |
|--------|-------------|---------|------|
| Requests/sec | 200,000+ | ~13,254 | ~22,286 |
| Connections | Millions | 100k+ | 100k+ |
| Latency (p50) | < 1ms | ~5ms | ~3ms |
| Latency (p99) | < 10ms | ~50ms | ~30ms |

### Memory Usage

**Per connection:**
- uWebSockets: < 1KB
- Node.js: ~5KB
- Deno: ~3KB

**For 100,000 connections:**
- uWebSockets: ~100MB
- Node.js: ~500MB
- Deno: ~300MB

---

## Compression

### Per-Message Deflate

**Trade-off:**
- **Pros**: Smaller payloads, less bandwidth
- **Cons**: Higher CPU usage, increased latency

**Recommendation**: Disable for real-time apps

```zig
const app = uws.uWS_App_create(0, null); // No compression
```

**Why?**
- Real-time apps prioritize latency over bandwidth
- MessagePack is already efficient
- Compression adds 1-5ms latency
- CPU better spent on queries/subscriptions

---

## Error Handling

### Connection Errors

```zig
fn onError(ws: *uws.uWS_WebSocket, error_code: c_int) callconv(.C) void {
    switch (error_code) {
        uws.ECONNRESET => {
            // Client disconnected abruptly
            cleanupConnection(ws);
        },
        uws.ETIMEDOUT => {
            // Connection timeout
            closeConnection(ws);
        },
        else => {
            // Unknown error
            logError(error_code);
        },
    }
}
```

### Message Errors

```zig
fn handleMessage(msg: []const u8) !Response {
    const parsed = msgpack.decode(msg) catch |err| {
        return Response{
            .type = .error,
            .code = "INVALID_MESSAGE",
            .message = "Failed to parse MessagePack",
        };
    };
    
    // Process message...
}
```

---

## Security Best Practices

### 1. Validate Origin Header

Prevent CSWSH attacks by checking Origin header during handshake.

### 2. Use Ticket-Based Auth

Don't pass JWTs in query params (they get logged).

### 3. Rate Limiting

Limit messages per connection per second:

```zig
const RateLimiter = struct {
    max_per_second: usize = 100,
    
    pub fn check(self: *RateLimiter, conn_id: u64) bool {
        // Check if connection exceeded rate limit
        // ...
    }
};
```

### 4. Input Validation

Validate all incoming messages against schema:

```zig
fn validateMessage(msg: Message) !void {
    if (msg.namespace.len > 256) {
        return error.NamespaceTooLong;
    }
    
    if (msg.payload.len > 1024 * 1024) { // 1MB
        return error.PayloadTooLarge;
    }
}
```

### 5. Connection Limits

Limit connections per IP address:

```zig
const ConnectionLimiter = struct {
    max_per_ip: usize = 100,
    
    pub fn check(self: *ConnectionLimiter, ip: []const u8) bool {
        // Check if IP exceeded connection limit
        // ...
    }
};
```

---

## See Also

- [Core Principles](./CORE_PRINCIPLES.md) - Why we chose uWebSockets
- [Threading Model](./THREADING.md) - How multi-threading works
- [Storage Layer](./STORAGE.md) - SQLite integration
- [Query Engine](./QUERY_ENGINE.md) - Message processing
- [Research](./RESEARCH.md) - Performance validation
