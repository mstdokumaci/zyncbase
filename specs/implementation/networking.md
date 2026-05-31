# Network Layer

**Last Updated**: 2026-03-09

---

## Overview

ZyncBase uses uWebSockets (C++) as its networking foundation, integrated directly with Zig. uWebSockets provides the multi-threaded event loop, TLS via OpenSSL, and zero-copy I/O that the ZyncBase server is built on.

---

## uWebSockets Architecture

### Core Components

```
┌─────────────────────────────────────────────────────┐
│  uWebSockets (C++)                                  │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  µSockets Foundation                          │  │
│  │  ┌─────────────┐  ┌─────────────┐             │  │
│  │  │  Eventing   │  │  Networking │             │  │
│  │  │  (epoll/    │  │  (TCP/UDP)  │             │  │
│  │  │   kqueue)   │  │             │             │  │
│  │  └─────────────┘  └─────────────┘             │  │
│  │  ┌─────────────────────────────────┐          │  │
│  │  │  Cryptography (TLS 1.3)         │          │  │
│  │  │  (OpenSSL)                      │          │  │
│  │  └─────────────────────────────────┘          │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  Multi-threaded Event Loop                    │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐     │  │
│  │  │ Thread 1 │  │ Thread 2 │  │ Thread N │     │  │
│  │  │ WebSocket│  │ WebSocket│  │ WebSocket│     │  │
│  │  │ + HTTP   │  │ + HTTP   │  │ + HTTP   │     │  │
│  │  └──────────┘  └──────────┘  └──────────┘     │  │
│  └───────────────────────────────────────────────┘  │
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
fn linkUWS(b: *std.Build, step: *std.Build.Step.Compile, sysroot: ?[]const u8, sanitize: ?[]const u8) void {
    step.linkLibCpp();
    step.linkLibC();
    step.linkSystemLibrary("pthread");
    step.linkSystemLibrary("ssl");
    step.linkSystemLibrary("crypto");

    step.addIncludePath(b.path("vendor/uwebsockets"));
    step.addIncludePath(b.path("vendor/usockets"));
    step.addIncludePath(b.path("src"));

    step.addCSourceFile(.{
        .file = b.path("src/uws_bridge.cpp"),
        .flags = &.{
            "-std=c++20",
            "-fno-exceptions",
            "-fno-rtti",
            "-DUWS_NO_ZLIB",
            "-DLIBUS_USE_OPENSSL=1",
        },
    });

    step.addCSourceFiles(.{
        .files = &.{
            "vendor/usockets/eventing/epoll_kqueue.c",
            "vendor/usockets/crypto/openssl.c",
            "vendor/usockets/context.c",
            "vendor/usockets/loop.c",
            "vendor/usockets/socket.c",
            "vendor/usockets/bsd.c",
            "vendor/usockets/udp.c",
        },
        .flags = &.{
            "-std=c11",
            "-DUWS_NO_ZLIB",
            "-DLIBUS_USE_OPENSSL=1",
        },
    });

    step.addCSourceFile(.{
        .file = b.path("vendor/usockets/crypto/sni_tree.cpp"),
        .flags = &.{
            "-std=c++20",
            "-fno-exceptions",
            "-fno-rtti",
            "-DLIBUS_USE_OPENSSL=1",
        },
    });
}
```

### Server Implementation

```zig
// src/uwebsockets_wrapper.zig
const uws = @cImport({
    @cInclude("uws_wrapper.h");
});

pub const WebSocketServer = struct {
    app: *uws.uws_app_t,
    host_z: [:0]u8,
    port: u16,
    ssl: bool,

    pub fn init(self: *WebSocketServer, allocator: Allocator, config: Config) !void {
        const host_z = try allocator.dupeZ(u8, config.host);
        var options = std.mem.zeroes(uws.struct_us_socket_context_options_t);
        const app = uws.uws_create_app(if (config.ssl) 1 else 0, options) orelse
            return error.FailedToCreateApp;

        self.* = .{
            .app = app,
            .host_z = host_z,
            .port = config.port,
            .ssl = config.ssl,
        };
    }

    pub fn listen(self: *WebSocketServer) !void {
        const listen_socket = uws.uws_app_listen(
            if (self.ssl) 1 else 0,
            self.app,
            self.host_z.ptr,
            self.host_z.len,
            self.port,
            listenCallback,
            self,
        );
        if (listen_socket == null) return error.ListenFailed;
    }

    pub fn run(self: *WebSocketServer) void {
        uws.uws_app_run(if (self.ssl) 1 else 0, self.app);
    }

    pub fn deinit(self: *WebSocketServer, allocator: Allocator) void {
        uws.uws_destroy_app(if (self.ssl) 1 else 0, self.app);
        allocator.free(self.host_z);
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
│     - Transport-level Connected push            │
│     - Store/presence scopes resolve separately  │
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

Transport establishment is not the same as scoped session readiness. After the WebSocket is accepted, only lifecycle messages are valid until the relevant scope is ready: `AuthRefresh`, `StoreSetNamespace`, `PresenceSetNamespace`, ping/pong, and close. Store messages require a ready store scope. Presence messages require a ready presence scope.

### Frame Format

WebSocket frames have minimal overhead:

```
┌─────────────────────────────────────────────────┐
│  Frame Header (2-6 bytes)                       │
│  ┌──────────┬──────────┬──────────┬──────────┐  │
│  │ FIN (1)  │ Opcode   │ Mask (1) │ Length   │  │
│  │          │ (4 bits) │          │ (7 bits) │  │
│  └──────────┴──────────┴──────────┴──────────┘  │
│                                                 │
│  Payload (MessagePack binary data)              │
│  ┌───────────────────────────────────────────┐  │
│  │  Efficient binary serialization           │  │
│  │  Small integers: 1 byte                   │  │
│  │  Short strings: 2-6 bytes overhead        │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

**Overhead**: Only 2-6 bytes per message (vs HTTP's 100+ bytes)

---

## MessagePack Serialization

### Message Format

```zig
const Message = struct {
    type: MessageType,
    id: ?u64,              // Request ID (client→server only)
    // Type-specific fields are decoded inline per the wire protocol spec
};

const MessageType = enum {
    // Client→Server (Store)
    StoreSet,
    StoreRemove,
    StoreBatch,
    StoreQuery,
    StoreSubscribe,
    StoreUnsubscribe,
    StoreLoadMore,
    // Client→Server (Presence)
    PresenceSet,
    PresenceSubscribe,
    PresenceUnsubscribe,
    PresenceRemove,
    // Client→Server (Namespace / Auth)
    StoreSetNamespace,
    PresenceSetNamespace,
    AuthRefresh,
    // Server→Client
    ok,
    @"error",
    SchemaSync,
    Connected,
    StoreDelta,
    PresenceBroadcast,
    ServerDisconnect,
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
    external_user_id: []const u8,
    store_scope: ?ScopedSession,
    presence_scope: ?ScopedSession,
    subscriptions: ArrayList(SubscriptionId),
    presence: ?json.Value,
    
    pub fn send(self: *Connection, msg: Message) !void {
        const bytes = try msgpack.encode(msg);
        try self.socket.send(bytes);
    }
};

const ScopedSession = struct {
    namespace_id: i64,
    user_doc_id: DocId,
    ready: bool,
};
```

### Authentication

**Ticket-based authentication** (recommended):

*Note: The ZyncBase SDK abstracts this process. Developers simply provide `createClient({ token: 'jwt' })`, and the SDK automatically performs this exchange under the hood to ensure the token never touches the `ws://` URL.*

```
1. Client requests ticket from HTTP endpoint
   POST /auth/ticket
   Authorization: Bearer <JWT>
   
2. Server validates JWT, returns short-lived ticket
   { "ticket": "abc123...", "expires": 1234567890 }
   
3. Client connects with ticket
   ws://server/ws?ticket=abc123...
   
4. Server validates ticket, establishes transport connection
5. Client selects store/presence namespaces
6. Server resolves scoped `users.id` values and marks scopes ready
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

## See Also

- [Core Principles](../architecture/core-principles.md) - Why we chose uWebSockets
- [Threading Model](../architecture/threading-model.md) - How multi-threading works
- [Storage Layer](../architecture/storage-layer.md) - SQLite integration
- [Query Engine](./query-engine.md) - Message processing
- [Research](../architecture/research.md) - Performance validation
