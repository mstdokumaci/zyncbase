# uWebSockets Version Compatibility

**Drivers**: [Networking Implementation](./networking.md)

This document describes the actual C binding interface ZyncBase uses to call uWebSockets, the version currently pinned, and the compatibility contract.

---

## Pinned Version

uWebSockets and µSockets are directly vendored into the repository:

```
vendor/uwebsockets/            — uWebSockets C++ headers (37 files)
vendor/usockets/               — µSockets C sources and headers
src/uws_bridge.cpp             — Purpose-built C++→C bridge (~300 lines)
src/uws_bridge.h               — Bridge type definitions
```

The vendored files were extracted from Bun's fork of uWebSockets/uSockets, with patches
permanently baked into `vendor/uwebsockets/` (libdeflate disabled, SIMDUTF disabled,
include paths fixed).

---

## C Binding Interface

ZyncBase calls uWebSockets exclusively through `src/uws_wrapper.h`, which is included via `@cImport` in `src/uwebsockets_wrapper.zig`. The functions used are:

```c
// App lifecycle
uws_app_t* uws_create_app(int ssl, us_bun_socket_context_options_t options);
void       uws_app_listen(int ssl, uws_app_t* app, int port, uws_listen_handler handler, void* user_data);
void       uws_app_run(int ssl, uws_app_t* app);

// WebSocket route registration
void uws_ws(int ssl, uws_app_t* app, void* ctx,
            const char* pattern, size_t pattern_len,
            int id, const uws_socket_behavior_t* behavior);

// WebSocket operations
int  uws_ws_send(int ssl, uws_websocket_t* ws,
                 const char* msg, size_t len, uws_opcode_t opcode);
void uws_ws_close(int ssl, uws_websocket_t* ws);
void* uws_ws_get_user_data(int ssl, uws_websocket_t* ws);
```

### Behavior Configuration (fixed at init)

```zig
behavior.compression          = c.UWS_COMPRESS_DISABLED;
behavior.maxPayloadLength     = 10 * 1024 * 1024; // 10 MB
behavior.idleTimeout          = 120;               // seconds
behavior.maxBackpressure      = 64 * 1024;         // 64 KB
behavior.sendPingsAutomatically = true;
```

---

## Compatibility Contract

ZyncBase guarantees compatibility with the directly vendored uWebSockets/µSockets code in `vendor/uwebsockets/` and `vendor/usockets/`. No other version is tested or supported.

| Guarantee | Detail |
|-----------|--------|
| API surface | Only the functions listed above are called. Any uWebSockets change that does not affect these symbols is safe. |
| ABI | `libuwsockets.cpp` is compiled from source at build time — no pre-built binary dependency. |
| SSL | SSL is compiled in (`-DLIBUS_USE_OPENSSL=1`) but `WebSocketServer.Config.ssl = false` by default. SSL paths are not exercised in current tests. |
| Compression | Disabled (`UWS_COMPRESS_DISABLED`). Enabling it requires updating `behavior.compression` and re-testing. |

### Updating the Pinned Version

To update uWebSockets, update the vendored files in `vendor/uwebsockets/` and `vendor/usockets/`:

```bash
# 1. Fetch the latest Bun uWebSockets from the bun repo (if tracking Bun's fork)
git clone --depth 1 https://github.com/oven-sh/bun.git /tmp/bun-uws-sync
# 2. Copy updated files
cp /tmp/bun-uws-sync/packages/bun-uws/src/*.h vendor/uwebsockets/
cp /tmp/bun-uws-sync/packages/bun-usockets/src/*.c vendor/usockets/
cp /tmp/bun-uws-sync/packages/bun-usockets/src/*.h vendor/usockets/
cp -r /tmp/bun-uws-sync/packages/bun-usockets/src/internal vendor/usockets/
# 3. Re-apply patches (libdeflate, SIMDUTF, AsyncSocket.h include path)
# 4. Re-slice the bridge if API surface changed
zig build test   # must pass before committing
```

If the update changes any function in the C binding interface above, `src/uws_wrapper.h` and `src/uwebsockets_wrapper.zig` must be updated to match.

---

## Invariants & Error Conditions

| Invariant | Description |
|-----------|-------------|
| Single app instance | `global_server` in `uwebsockets_wrapper.zig` holds one server pointer. Multiple `WebSocketServer` instances are not supported. |
| App not destroyed | `uws_app_destroy` is not exposed by the C wrapper; the app lives until process exit. |
| SSL not validated | SSL certificate paths are accepted by `Config` but not tested in CI. |

| Error | Cause |
|-------|-------|
| `error.FailedToCreateApp` | `uws_create_app` returned null (OOM or invalid SSL options) |
| `error.ListenFailed` | Port already in use or permission denied |

---

## Verification Commands

```bash
# Build and link uWebSockets from source
zig build

# Run wrapper unit tests
zig test src/uwebsockets_wrapper_test.zig

# Run wrapper property tests
zig test src/uwebsockets_wrapper_property_test.zig
```

---

## See Also
- [Networking Implementation](./networking.md) — Server struct and connection lifecycle
- [Threading Implementation](./threading.md) — Event loop threading model
