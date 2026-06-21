# Networking

**Drivers**: [ADR-007](../architecture/adrs.md#adr-007-uwebsockets-as-the-network-layer), [ADR-008](../architecture/adrs.md#adr-008-wire-encoding), [Auth Exchange](./auth-exchange.md), [Wire Protocol](./wire-protocol.md), [Security](./security.md)

ZyncBase uses vendored uWebSockets/usockets through a narrow Zig wrapper. The network layer owns transport lifecycle, WebSocket callback bridging, TLS/OpenSSL linkage, connection registration, and delivery of binary MessagePack frames to `MessageHandler`.

## Source Files

| File | Responsibility |
|------|----------------|
| `src/server.zig` | Server composition, start/stop lifecycle, and subsystem wiring. |
| `src/uwebsockets_wrapper.zig` | Zig-facing wrapper types for app, socket, handlers, send status, and message type. |
| `src/uws_bridge.cpp` | C/C++ bridge that binds uWebSockets callbacks to Zig-callable functions. |
| `src/uws_wrapper.h` | C ABI declarations shared by Zig and the C++ bridge. |
| `src/connection/manager.zig` | Connection registry and targeted send helper. |
| `src/connection/state.zig` | Per-connection WebSocket handle, outbox, session state, and send/close behavior. |
| `src/message_handler.zig` | Message callback consumer and request router. |
| `build.zig` | uWebSockets/usockets/OpenSSL/C++ link configuration. |
| `vendor/uwebsockets`, `vendor/usockets` | Pinned upstream networking dependencies. |

## Important Types

| Type | Dependencies | Responsibility |
|------|--------------|----------------|
| `WebSocketServer` | uWebSockets app pointer, config | Owns listen/run/deinit lifecycle for the network app. |
| `WebSocketHandlers` | Open/message/close callback function pointers | Defines callback surface passed into the C++ bridge. |
| `WebSocket` | uWebSockets socket pointer | Sends binary payloads and closes the transport. |
| `MessageType` | uWebSockets frame type | Distinguishes binary WebSocket frames from unsupported frame kinds. |
| `SocketUserData` | `Connection` id/state pointer | Binds transport callbacks to ZyncBase connection state. |
| `ConnectionManager` | allocator, registry | Registers, looks up, and removes live connections. |
| `MessageHandler` | `Connection`, `wire`, services | Consumes binary payloads after the network layer accepts the frame. |

## Transport Contract

- WebSocket is the only client transport for database operations.
- Production payloads are binary MessagePack, not JSON.
- Text frames are rejected through the canonical error path.
- Compression is disabled; MessagePack size/depth limits are enforced before domain routing.
- TLS is provided by OpenSSL through usockets when configured.
- The network layer does not authorize store/presence operations; it authenticates/initializes the connection and delegates authorization to `MessageHandler` and `authorization/*`.

## Connection Lifecycle

1. HTTP ticket exchange creates a short-lived connection ticket. See [Auth Exchange](./auth-exchange.md).
2. WebSocket upgrade is accepted only for the configured endpoint and origin policy.
3. The bridge allocates/registers a `Connection` and attaches socket user data.
4. The server sends connection/schema bootstrap pushes as required by the active protocol.
5. Binary frames are delivered to `MessageHandler.handleMessage`.
6. Close/error callbacks detach subscriptions, clear scoped session state, and remove connection-owned presence.

## Backpressure And Sends

- Encoded responses are owned by the request arena or dispatcher buffer until handed to `Connection.send`.
- Send failure closes the connection through the centralized close path.
- Cross-connection fanout goes through `ConnectionManager`/dispatchers instead of storing raw sockets in domain services.
- Large or repeated outbound failures should be treated as transport instability, not domain errors.

## Security Boundaries

- Origin validation and frame type checks happen before domain routing.
- Parser limit violations are tracked by `ConnectionViolationTracker`.
- Repeated malformed/security-sensitive messages close the connection.
- Namespace authorization, store authorization, and presence authorization are server-side only and fail closed.
- Public error codes are owned by [Error Taxonomy](./error-taxonomy.md).

## uWebSockets C ABI Interface

The C++ bridge library `src/uws_bridge.cpp` implements the C functions defined in `src/uws_wrapper.h`, which are imported by Zig:

```c
// App lifecycle
uws_app_t* uws_create_app(int ssl, struct us_socket_context_options_t options);
void       uws_destroy_app(int ssl, uws_app_t* app);
void       uws_app_run(int ssl, uws_app_t* app);
void       uws_app_close(int ssl, uws_app_t* app);
struct us_listen_socket_t* uws_app_listen(
    int ssl,
    uws_app_t* app,
    const char* host,
    size_t host_length,
    int port,
    uws_listen_handler handler,
    void* user_data
);

// WebSocket route registration
void uws_ws(int ssl, uws_app_t* app, void* upgrade_context,
            const char* pattern, size_t pattern_len,
            size_t id, const uws_socket_behavior_t* behavior);

// WebSocket operations
uws_sendstatus_t uws_ws_send(int ssl, uws_websocket_t* ws,
                             const char* msg, size_t len, uws_opcode_t opcode);
void uws_ws_close(int ssl, uws_websocket_t* ws);
void* uws_ws_get_user_data(int ssl, uws_websocket_t* ws);

// Request and upgrade helpers
size_t uws_req_get_header(uws_req_t* req, const char* lower_case_header,
                          size_t lower_case_header_length, const char** dest);
size_t uws_req_get_query(uws_req_t* req, const char* key,
                         size_t key_length, const char** dest);
void uws_res_upgrade(int ssl, uws_res_t* res, void* data,
                     const char* sec_web_socket_key, size_t sec_web_socket_key_length,
                     const char* sec_web_socket_protocol, size_t sec_web_socket_protocol_length,
                     const char* sec_web_socket_extensions, size_t sec_web_socket_extensions_length,
                     uws_socket_context_t* context);

// Loop helpers
struct us_loop_t* uws_get_loop(void);
void uws_loop_addPostHandler(void* loop, void* ctx, void (*cb)(void* ctx, void* loop));
void uws_loop_removePostHandler(void* loop, void* key);
```

### Socket Behavior Configuration

The uWebSockets socket behaviour is configured at server initialization using the following parameters:

```zig
behavior.compression            = c.UWS_COMPRESS_DISABLED;
behavior.maxPayloadLength       = config.security.max_message_size;
behavior.idleTimeout            = 120; // seconds by default
behavior.maxBackpressure        = 16 * 1024 * 1024;
behavior.sendPingsAutomatically = true;
```

## Pinned Upgrade Rules

When updating the vendored uWebSockets or µSockets source files from upstream:
- Upstream files must be copied into `vendor/uwebsockets/` and `vendor/usockets/`.
- Build scripts and include paths inside `build.zig` must be adjusted.
- `src/uws_bridge.cpp` and `src/uws_wrapper.h` must be updated to align with any upstream API changes.
- Port-binding failure must propagate back to the host process as `error.ListenFailed`.

## Performance Contract

### Transport Limits

| Property | Value | Notes |
|----------|-------|-------|
| Max message size (app layer) | 1 MB | Passed to uWS `maxPayloadLength`. |
| Max message size (uWS layer) | 16 MB | Hard limit; connections sending larger frames are dropped. |
| Max backpressure | 16 MB | Maximum bytes uWS will buffer per connection before dropping. |
| Idle timeout | 120 sec | Seconds of inactivity before uWS closes the connection. |
| Max connections | 100,000 | Hard cap on concurrent WebSocket connections. |

### Rate Limiting

| Property | Value | Notes |
|----------|-------|-------|
| Max messages per second | 100 | Per-connection token bucket rate. |
| Burst capacity | 200 | Token bucket burst (2× rate). |
| Violation threshold | 10 | Security violations before connection is forcibly closed. |

### Connection State

| Property | Value | Notes |
|----------|-------|-------|
| Outbox capacity | 16 slots | Per-connection bounded ring buffer for outgoing messages. |
| Subscription ID pre-alloc | 16 | Pre-allocated capacity to avoid heap allocs on event loop. |

### MessagePack Parse Limits

| Property | Value | Notes |
|----------|-------|-------|
| Max nesting depth | 32 | Maximum MessagePack nesting. |
| Max array length | 100,000 | Maximum array elements. |
| Max map size | 100,000 | Maximum map entries. |
| Max string length | 1 MB | Maximum string bytes. |
| Max binary length | 1 MB | Maximum binary data bytes. |
| Max extension length | 1 MB | Maximum extension data bytes. |

### Server Lifecycle

| Property | Value | Notes |
|----------|-------|-------|
| Shutdown drain timeout | 3,000 ms | Maximum time to wait for connections to drain during graceful shutdown. |
| Token sweep interval | 15,000 ms | How often expired JWT tokens are swept across connections. |

## See Also

- [Wire Protocol](./wire-protocol.md)
- [Message Handler](./message-handler.md)
- [Security](./security.md)
