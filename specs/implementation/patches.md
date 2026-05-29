# Patches and Stubs for uWebSockets Integration

## Overview

ZyncBase uses uWebSockets/µSockets extracted from Bun's production-tested fork. The source
is directly vendored at `vendor/uwebsockets/` and `vendor/usockets/`. Patches are permanently
baked into the vendored files.

## Baked-In Patches (vendor/uwebsockets/)

### 1. Disable libdeflate (`PerMessageDeflate.h`)

**Why**: Bun uses libdeflate for WebSocket compression. Disabled because:
- Not needed for MVP
- Avoids additional C library dependency
- Can be re-enabled later

**Change**: Comments out `#define UWS_USE_LIBDEFLATE 1` and wraps the libdeflate include in `#if 0`

### 2. Disable SIMDUTF (`WebSocketProtocol.h`)

**Why**: Bun uses SIMDUTF (from WebKit) for UTF-8 validation. Stubbed because:
- SIMDUTF requires WebKit's WTF library
- For MVP, client input is trusted

**Change**: Comments out SIMDUTF include and replaces validation with `return true` stub

**TODO**: Implement proper UTF-8 validation before production

### 3. Fix Include Path (`AsyncSocket.h`)

**Why**: Bun's fork uses `bun-usockets/src/internal/internal.h` include path that assumes a
`bun-usockets` parent directory.

**Change**: `#include "bun-usockets/src/internal/internal.h"` → `#include "internal/internal.h"`

## Stub Functions (`src/uws_stubs.c`)

Bun's µSockets fork calls Bun-specific runtime functions. We provide stub implementations
to allow linking.

### Categories of Stubs

#### 1. DNS Resolution
- `Bun__addrinfo_get()`, `Bun__addrinfo_set()`, `Bun__addrinfo_freeRequest()`, `Bun__addrinfo_getRequestResult()`
- **Current**: Return errors or no-op (DNS not implemented)
- **TODO**: Integrate with system `getaddrinfo()` or custom DNS resolver

#### 2. Event Loop Integration
- `Bun__JSC_onBeforeWait()`, `Bun__internal_dispatch_ready_poll()`, `Bun__internal_ensureDateHeaderTimerIsEnabled()`
- **Current**: No-ops (we don't use JavaScriptCore or Bun's specific timers)

#### 3. Thread Safety
- `Bun__lock()`, `Bun__unlock()`, `Bun__lock__size`
- **Current**: No-ops (single-threaded MVP)
- **TODO**: Implement proper mutexes when adding multi-threading

#### 4. HTTP Parsing
- `Bun__HTTPMethod__from()`: Returns 0 (unknown)
- `BUN_DEFAULT_MAX_HTTP_HEADER_SIZE`: Default header size limit (16KB)

#### 5. Platform Detection
- `Bun__doesMacOSVersionSupportSendRecvMsgX()`: Returns 1 on macOS, 0 elsewhere
- `Bun__isEpollPwait2SupportedOnLinuxKernel()`: Returns 0 to trigger fallback
- `sys_epoll_pwait2()`: Returns `-ENOSYS` (not supported)

#### 6. SSL Compatibility
- `ares_inet_ntop()`: Wraps standard `inet_ntop()`
- `us_get_default_ca_store()`, `us_internal_raw_root_certs()`: Return NULL/0
- `Bun__Node__UseSystemCA`: Boolean flag set to `true`

#### 7. Error Handling and Lifecycle
- `Bun__panic()`: Aborts process with message
- `bun_is_exiting()`, `set_bun_is_exiting()`: Managed lifecycle flags

## Future Work

### Short Term (MVP)
- ✅ Disable libdeflate
- ✅ Stub SIMDUTF
- ✅ Stub Bun runtime hooks
- ✅ Fix include paths
- ✅ Extract from Bun submodule into direct vendor files

### Medium Term (Post-MVP)
- [ ] Implement proper UTF-8 validation
- [ ] Implement DNS resolution
- [ ] Add proper mutex implementations
- [ ] Consider re-enabling compression

### Long Term (Production)
- [ ] Evaluate switching to upstream uWebSockets (eliminates stubs)
- [ ] Benchmark performance vs vanilla uWebSockets

## Maintenance Guidelines

When updating the vendored uWebSockets/µSockets:

1. **Fetch upstream**: Get latest from Bun's fork of uWebSockets
2. **Copy files**: Replace `vendor/uwebsockets/` and `vendor/usockets/` contents
3. **Re-apply baked patches**: libdeflate disable, SIMDUTF disable, include path fix
4. **Review bridge**: Check if `src/uws_bridge.cpp` needs updates for API changes
5. **Check stubs**: Add new stubs if Bun added new function calls
6. **Test thoroughly**: `zig build test` and `bun run test:e2e`
