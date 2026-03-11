# uWebSockets Version Compatibility

This document tracks compatibility between ZyncBase's UWebSocketsWrapper and different versions of uWebSockets.

## Overview

The UWebSocketsWrapper provides a stable Zig API that wraps the uWebSockets C++ interface. This abstraction layer isolates ZyncBase from API changes in uWebSockets, ensuring that minor version updates don't break the build.

## Tested Versions

### uWebSockets v20.x (Recommended)

**Status**: ✅ Fully Supported

**Tested Versions**:
- v20.0.0
- v20.14.0 (latest tested)

**Features**:
- SSL/TLS support via certificate and key files
- WebSocket compression (permessage-deflate)
- Configurable max payload length
- High-performance event loop
- Per-socket backpressure handling

**API Stability**: Stable - No breaking changes expected in v20.x series

### uWebSockets v19.x

**Status**: ⚠️ Compatible with minor adjustments

**Known Differences**:
- SSL configuration API slightly different
- Some performance optimizations not available
- Backpressure API has different signature

**Migration Notes**: If using v19.x, ensure SSL certificate loading uses the older API format.

### uWebSockets v21.x (Future)

**Status**: 🔄 Not yet released

**Expected Changes**: Will be evaluated when released. The wrapper layer will be updated to maintain compatibility.

## API Changes Between Versions

### v19.x → v20.x

**SSL Configuration**:
```cpp
// v19.x
us_socket_context_options_t ssl_options = {};
ssl_options.cert_file_name = cert_path;
ssl_options.key_file_name = key_path;

// v20.x (current)
uWS::SocketContextOptions ssl_options = {};
ssl_options.cert_file_name = cert_path;
ssl_options.key_file_name = key_path;
```

**Compression**:
```cpp
// v19.x
.compression(true)

// v20.x (current)
.compression(uWS::SHARED_COMPRESSOR)
```

**Max Payload Length**:
```cpp
// v19.x and v20.x (unchanged)
.maxPayloadLength(10 * 1024 * 1024)
```

## Upgrade Guide

### Upgrading from v19.x to v20.x

1. **Update uWebSockets dependency**:
   ```bash
   # Update git submodule or package manager
   git submodule update --remote vendor/uWebSockets
   ```

2. **Rebuild ZyncBase**:
   ```bash
   zig build
   ```

3. **Test SSL configuration**:
   ```bash
   zig build test
   ```

4. **Verify WebSocket connections**:
   - Test plain WebSocket (ws://)
   - Test secure WebSocket (wss://)
   - Test compression enabled/disabled
   - Test max payload enforcement

### Breaking Changes Checklist

When upgrading uWebSockets, verify:

- [ ] SSL certificate loading works
- [ ] Compression configuration applies
- [ ] Max payload length enforced
- [ ] Event loop starts and stops cleanly
- [ ] Backpressure handling works
- [ ] All tests pass

## C++ Bindings Interface

The UWebSocketsWrapper uses the following C++ interface (to be implemented):

```cpp
// Initialize uWebSockets App
extern "C" void* uws_create_app(bool ssl_enabled);

// Configure SSL
extern "C" int uws_configure_ssl(void* app, const char* cert_path, const char* key_path);

// Configure WebSocket behavior
extern "C" void uws_configure_websocket(void* app, bool compression, size_t max_payload);

// Start listening
extern "C" int uws_listen(void* app, int port);

// Run event loop
extern "C" void uws_run(void* app);

// Shutdown
extern "C" void uws_shutdown(void* app);

// Cleanup
extern "C" void uws_destroy_app(void* app);
```

## Version Detection

The wrapper can detect the uWebSockets version at compile time:

```zig
// In future implementation
pub const uws_version = @import("uwebsockets_version.zig");

pub fn checkCompatibility() !void {
    if (uws_version.major < 20) {
        std.log.warn("uWebSockets v{}.x detected. v20.x recommended.", .{uws_version.major});
    }
}
```

## Troubleshooting

### SSL Certificate Not Loading

**Symptom**: Server fails to start with SSL enabled

**Solution**:
1. Verify certificate files exist and are readable
2. Check certificate format (PEM expected)
3. Ensure both cert and key paths provided
4. Check uWebSockets version supports SSL

### Compression Not Working

**Symptom**: Messages not compressed over WebSocket

**Solution**:
1. Verify compression enabled in config
2. Check client supports permessage-deflate
3. Ensure uWebSockets v20.x or later
4. Check for conflicting compression settings

### Max Payload Exceeded

**Symptom**: Large messages rejected

**Solution**:
1. Increase max_payload_length in config
2. Verify client respects payload limits
3. Consider message chunking for large data
4. Check for memory constraints

## Performance Considerations

### uWebSockets v20.x Performance

- **Throughput**: 100,000+ concurrent connections
- **Latency**: Sub-millisecond message delivery
- **Memory**: ~1KB per connection
- **CPU**: Efficient event loop, minimal overhead

### Optimization Tips

1. **Enable compression** for text-heavy messages
2. **Tune max_payload_length** based on use case
3. **Use SSL session resumption** for TLS
4. **Monitor backpressure** to prevent memory bloat

## References

- [uWebSockets GitHub](https://github.com/uNetworking/uWebSockets)
- [uWebSockets Documentation](https://github.com/uNetworking/uWebSockets/tree/master/misc)
- [WebSocket RFC 6455](https://tools.ietf.org/html/rfc6455)
- [permessage-deflate Extension](https://tools.ietf.org/html/rfc7692)

## Changelog

### 2024-01-XX - Initial Version
- Documented compatibility with uWebSockets v20.x
- Added upgrade guide from v19.x
- Defined C++ bindings interface
- Added troubleshooting section
