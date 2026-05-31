# uWebSockets Version Compatibility

**Drivers**: [Networking Implementation](./networking.md)

This document describes the actual C binding interface ZyncBase uses to call uWebSockets, the version currently pinned, and the compatibility contract.

---

## Vendored Version

uWebSockets and µSockets are directly vendored into the repository:

```
vendor/uwebsockets/            — uWebSockets C++ headers (37 files)
vendor/usockets/               — µSockets C sources and headers
src/uws_bridge.cpp             — Purpose-built C++→C bridge (~300 lines)
src/uws_wrapper.h              — C ABI imported by Zig
```

The vendored files are tracked in-tree from upstream uWebSockets/µSockets. ZyncBase does
not depend on an external runtime fork or a prebuilt uWebSockets binary for the server
binary. TLS is compiled through µSockets' OpenSSL backend.

---

## C Binding Interface

ZyncBase calls uWebSockets exclusively through `src/uws_wrapper.h`, which is included via `@cImport` in `src/uwebsockets_wrapper.zig`. The C ABI is owned by ZyncBase and implemented by `src/uws_bridge.cpp`.

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

### Behavior Configuration (fixed at init)

```zig
behavior.compression            = c.UWS_COMPRESS_DISABLED;
behavior.maxPayloadLength       = config.security.max_message_size;
behavior.idleTimeout            = 120; // seconds by default
behavior.maxBackpressure        = 16 * 1024 * 1024;
behavior.sendPingsAutomatically = true;
```

---

## Compatibility Contract

ZyncBase guarantees compatibility with the directly vendored uWebSockets/µSockets code in `vendor/uwebsockets/` and `vendor/usockets/`. No other version is tested or supported.

| Guarantee | Detail |
|-----------|--------|
| API surface | Only the functions listed above are called. Any uWebSockets change that does not affect these symbols is safe. |
| ABI | `src/uws_bridge.cpp` and vendored µSockets C/C++ files are compiled from source at build time. |
| TLS | TLS is compiled in (`-DLIBUS_USE_OPENSSL=1`) and uses system OpenSSL. Certificate and key paths are copied to owned NUL-terminated buffers before crossing into C. |
| Compression | Disabled by `-DUWS_NO_ZLIB` and `UWS_COMPRESS_DISABLED`. Enabling it requires adding zlib/libdeflate linkage and re-testing. |

### Updating the Pinned Version

To update uWebSockets, update the vendored files in `vendor/uwebsockets/` and `vendor/usockets/` from upstream uNetworking sources:

```bash
# 1. Fetch upstream uWebSockets and µSockets into a temporary directory.
# 2. Copy the uWebSockets headers into vendor/uwebsockets/.
# 3. Copy µSockets C/C++ sources and headers into vendor/usockets/.
# 4. Reconcile include paths and compression/TLS build flags.
# 5. Update src/uws_bridge.cpp and src/uws_wrapper.h if the C++ API changed.
zig build test   # must pass before committing
```

If the update changes any function in the C binding interface above, `src/uws_wrapper.h` and `src/uwebsockets_wrapper.zig` must be updated to match.

---

## Invariants & Error Conditions

| Invariant | Description |
|-----------|-------------|
| Owned C strings | Host, certificate, and key paths are copied to NUL-terminated buffers owned by `WebSocketServer`. |
| Listen failure | `WebSocketServer.listen()` returns `error.ListenFailed` if uWS cannot bind the configured host/port. |
| App lifecycle | `WebSocketServer.deinit()` destroys the uWS app and releases owned C string buffers. |
| TLS config | `ssl = true` requires both certificate and key paths; invalid files fail initialization. |

| Error | Cause |
|-------|-------|
| `error.FailedToCreateApp` | `uws_create_app` returned null (OOM or invalid SSL options) |
| `error.ListenFailed` | Port already in use or permission denied |
| `error.InvalidConfig` | TLS enabled without both certificate and key paths |

---

## Verification Commands

```bash
# Build and link uWebSockets from source
zig build

# Run wrapper-focused tests
zig build test -Dtest-filter=WebSocketServer
```

---

## See Also
- [Networking Implementation](./networking.md) — Server struct and connection lifecycle
- [Threading Implementation](./threading.md) — Event loop threading model
