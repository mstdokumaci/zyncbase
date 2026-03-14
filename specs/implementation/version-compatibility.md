# uWebSockets Version Compatibility

**Drivers**: [Networking Implementation](./networking.md)

This document describes the actual C binding interface ZyncBase uses to call uWebSockets, the version currently pinned, and the compatibility contract.

---

## Pinned Version

uWebSockets is not a direct submodule. ZyncBase uses the copy bundled inside the `vendor/bun` submodule:

```
vendor/bun/src/deps/libuwsockets.cpp   — C wrapper compiled into ZyncBase
vendor/bun/packages/bun-uws/src/       — uWebSockets C++ headers
vendor/bun/packages/bun-usockets/src/  — µSockets headers
```

The `vendor/bun` submodule is pinned to a specific Bun commit in `.gitmodules`. The effective uWebSockets version is whatever Bun's tree contains at that commit. To determine the exact version:

```bash
git -C vendor/bun log --oneline -1
grep -r "UWS_VERSION" vendor/bun/packages/bun-uws/src/ 2>/dev/null | head -5
```

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

ZyncBase guarantees compatibility with the uWebSockets version embedded in the pinned `vendor/bun` commit. No other version is tested or supported.

| Guarantee | Detail |
|-----------|--------|
| API surface | Only the functions listed above are called. Any uWebSockets change that does not affect these symbols is safe. |
| ABI | `libuwsockets.cpp` is compiled from source at build time — no pre-built binary dependency. |
| SSL | SSL is compiled in (`-DLIBUS_USE_BORINGSSL=1`) but `WebSocketServer.Config.ssl = false` by default. SSL paths are not exercised in current tests. |
| Compression | Disabled (`UWS_COMPRESS_DISABLED`). Enabling it requires updating `behavior.compression` and re-testing. |

### Updating the Pinned Version

To update uWebSockets, update the `vendor/bun` submodule commit:

```bash
git -C vendor/bun fetch origin
git -C vendor/bun checkout <new-commit>
git add vendor/bun
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
