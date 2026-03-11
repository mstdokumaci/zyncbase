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
- `Bun__addrinfo_get()`, `Bun__addrinfo_set()`, etc.
- **Current**: Return errors (DNS not implemented)
- **TODO**: Integrate with system `getaddrinfo()` or custom DNS resolver

#### 2. Event Loop Integration
- `Bun__JSC_onBeforeWait()`, `Bun__internal_dispatch_ready_poll()`, etc.
- **Current**: No-ops (we don't use JavaScriptCore)
- **Future**: May integrate with ZyncBase's event loop if needed

#### 3. Thread Safety
- `Bun__lock()`, `Bun__unlock()`
- **Current**: No-ops (single-threaded MVP)
- **TODO**: Implement proper mutexes when adding multi-threading

#### 4. HTTP Parsing
- `Bun__HTTPMethod__from()`
- **Current**: Returns 0 (unknown method)
- **TODO**: Implement if we need HTTP method detection

#### 5. Platform Detection
- `Bun__doesMacOSVersionSupportSendRecvMsgX()`
- **Current**: Returns 1 on macOS, 0 elsewhere
- **Status**: Complete (simple platform check)

#### 6. C-Ares Compatibility
- `ares_inet_ntop()`
- **Current**: Wraps standard `inet_ntop()`
- **Status**: Complete (simple wrapper)

## Applying Patches

### Initial Setup

```bash
# After cloning with submodules
./scripts/apply-patches.sh
```

### After Updating Bun Submodule

```bash
# Reset patches
cd vendor/bun
git checkout packages/bun-uws/src/PerMessageDeflate.h
git checkout packages/bun-uws/src/WebSocketProtocol.h
cd ../..

# Reapply
./scripts/apply-patches.sh
```

### Verifying Patches

```bash
cd vendor/bun
git diff packages/bun-uws/src/PerMessageDeflate.h
git diff packages/bun-uws/src/WebSocketProtocol.h
```

## Alternative Approaches Considered

### 1. Fork Bun's uWebSockets
**Pros**: Complete control
**Cons**: Maintenance burden, diverges from Bun's updates
**Decision**: Rejected - too much maintenance

### 2. Use Vanilla uWebSockets
**Pros**: No Bun dependencies
**Cons**: Lose Bun's production testing and improvements
**Decision**: Rejected - Bun's version is battle-tested

### 3. Create Custom C Wrapper
**Pros**: No Bun dependencies
**Cons**: ~5000+ lines of code to write and maintain
**Decision**: Rejected - reinventing the wheel

### 4. Minimal Patches + Stubs (Current Approach)
**Pros**: 
- Leverage Bun's production code
- Minimal maintenance
- Easy to update
- Clear separation of concerns

**Cons**:
- Requires patch management
- Some features stubbed out

**Decision**: Accepted - best balance of benefits

## Future Work

### Short Term (MVP)
- ✅ Disable libdeflate
- ✅ Stub SIMDUTF
- ✅ Stub Bun runtime hooks
- ⏳ Test WebSocket connections work

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

## Questions?

If you're unsure about:
- Why a patch is needed: See the "Why" section above
- How to apply patches: See "Applying Patches" section
- What a stub does: See comments in `src/uws_stubs.c`
- Whether to add a new stub: Check if it's called by uWebSockets code

## Summary

This approach allows us to use Bun's production-tested uWebSockets integration with minimal modifications. The patches are small, well-documented, and easy to maintain. As ZyncBase matures, we can implement the stubbed functions properly or re-enable disabled features as needed.
