# Patches and Stubs for Bun's uWebSockets Integration

## Overview

ZyncBase uses Bun's production-tested uWebSockets integration, but Bun includes several dependencies and runtime hooks that we don't need. Rather than forking Bun or creating a completely custom integration, we use a minimal patching approach combined with stub functions.

## Philosophy

1. **Minimal Patches**: Only patch what's absolutely necessary
2. **Non-Invasive**: Comment out code rather than deleting it
3. **Documented**: Each patch explains why it's needed
4. **Maintainable**: Easy to reapply when updating Bun submodule

## Patches Applied

### 1. Disable libdeflate (`patches/bun-uws-disable-libdeflate.patch`)

**File**: `vendor/bun/packages/bun-uws/src/PerMessageDeflate.h`

**Why**: Bun uses libdeflate for WebSocket compression. We disable this because:
- We don't need WebSocket compression for the MVP
- Avoids adding another C library dependency
- Can be re-enabled later if needed

**Change**: Comments out `#define UWS_USE_LIBDEFLATE 1` and the libdeflate include

### 2. Disable SIMDUTF (`patches/bun-uws-disable-simdutf.patch`)

**File**: `vendor/bun/packages/bun-uws/src/WebSocketProtocol.h`

**Why**: Bun uses SIMDUTF (from WebKit) for fast UTF-8 validation. We stub this because:
- SIMDUTF requires WebKit's WTF library
- UTF-8 validation can be added later with a simpler library
- For MVP, we trust client input (acceptable for development)

**Change**: Comments out SIMDUTF include and replaces validation with a stub that returns `true`

**TODO**: Implement proper UTF-8 validation before production use

## Stub Functions (`src/uws_stubs.c`)

Bun's uWebSockets fork calls Bun-specific runtime functions. We provide stub implementations to allow linking.

### Categories of Stubs

#### 1. DNS Resolution
- `Bun__addrinfo_get()`, `Bun__addrinfo_set()`, `Bun__addrinfo_freeRequest()`, `Bun__addrinfo_getRequestResult()`
- **Current**: Return errors or no-op (DNS not implemented)
- **TODO**: Integrate with system `getaddrinfo()` or custom DNS resolver

#### 2. Event Loop Integration
- `Bun__JSC_onBeforeWait()`, `Bun__internal_dispatch_ready_poll()`, `Bun__internal_ensureDateHeaderTimerIsEnabled()`
- **Current**: No-ops (we don't use JavaScriptCore or Bun's specific timers)
- **Future**: May integrate with ZyncBase's event loop if needed

#### 3. Thread Safety
- `Bun__lock()`, `Bun__unlock()`, `Bun__lock__size`
- **Current**: No-ops (single-threaded MVP). `Bun__lock__size` returns the size of a dummy mutex structure.
- **TODO**: Implement proper mutexes when adding multi-threading

#### 4. HTTP Parsing
- `Bun__HTTPMethod__from()`
- `BUN_DEFAULT_MAX_HTTP_HEADER_SIZE`: Default header size limit (16KB).
- **Current**: `Bun__HTTPMethod__from()` returns 0 (unknown). `BUN_DEFAULT_MAX_HTTP_HEADER_SIZE` is set to 16KB.
- **TODO**: Implement method detection if needed.

#### 5. Platform Detection and Networking
- `Bun__doesMacOSVersionSupportSendRecvMsgX()`: Returns 1 on macOS, 0 elsewhere.
- `Bun__isEpollPwait2SupportedOnLinuxKernel()`: Returns 0 to trigger fallback.
- `sys_epoll_pwait2()`: Returns `-ENOSYS` (not supported).
- **Status**: Complete (simple platform checks and fallbacks)

#### 6. C-Ares and SSL Compatibility
- `ares_inet_ntop()`: Wraps standard `inet_ntop()`.
- `us_get_default_ca_store()`, `us_internal_raw_root_certs()`: Return NULL/0.
- `Bun__Node__UseSystemCA`: Boolean flag set to `true`.
- **Status**: Complete for MVP requirements

#### 7. Error Handling and Lifecycle
- `Bun__panic()`: Aborts the process with a message.
- `bun_is_exiting()`, `set_bun_is_exiting()`: Managed lifecycle flags.
- **Status**: Functional for basic process management

## Future Work

### Short Term (MVP)
- ✅ Disable libdeflate
- ✅ Stub SIMDUTF
- ✅ Stub Bun runtime hooks
- ✅ Test WebSocket connections work

### Medium Term (Post-MVP)
- [ ] Implement proper UTF-8 validation
- [ ] Implement DNS resolution
- [ ] Add proper mutex implementations
- [ ] Consider re-enabling compression

### Long Term (Production)
- [ ] Evaluate if we need any Bun-specific features
- [ ] Consider contributing patches back to Bun
- [ ] Benchmark performance vs vanilla uWebSockets

## Maintenance Guidelines

When updating the Bun submodule:

1. **Check for conflicts**: See if patches still apply cleanly
2. **Review changes**: Check Bun's changelog for relevant uWebSockets changes
3. **Test thoroughly**: Ensure WebSocket functionality still works
4. **Update patches**: Regenerate patches if files changed significantly
5. **Update stubs**: Add new stubs if Bun added new function calls
