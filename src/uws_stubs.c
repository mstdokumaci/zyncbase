#include <stdint.h>
#include <stdlib.h>

/**
 * Bun-specific function stubs for uWebSockets integration
 * 
 * Bun's fork of uWebSockets includes calls to Bun-specific functions that don't exist
 * in the standard uWebSockets library. These stubs allow us to link successfully while
 * providing minimal implementations.
 * 
 * TODO: Implement these properly as ZyncBase features are developed:
 * - DNS resolution (Bun__addrinfo_*)
 * - UTF-8 validation (currently stubbed in WebSocketProtocol.h)
 * - Event loop integration (Bun__JSC_onBeforeWait, etc.)
 */

// =============================================================================
// DNS Resolution Stubs
// =============================================================================
// Bun uses custom async DNS resolution integrated with their event loop.
// For now, we return errors. A real implementation would use getaddrinfo()
// or integrate with ZyncBase's DNS resolver.

int Bun__addrinfo_get(void* loop, const char* host, uint16_t port, void** ptr) {
    (void)loop; (void)host; (void)port; (void)ptr;
    return -1; // Fail - DNS resolution not implemented
}

int Bun__addrinfo_set(void* ptr, void* socket) {
    (void)ptr; (void)socket;
    return -1;
}

void Bun__addrinfo_freeRequest(void* addrinfo_req, int error) {
    (void)addrinfo_req; (void)error;
}

void* Bun__addrinfo_getRequestResult(void* addrinfo_req) {
    (void)addrinfo_req;
    return NULL;
}

// =============================================================================
// Bun Runtime Hooks
// =============================================================================

int bun_is_exiting() {
    // Bun checks this to avoid operations during shutdown
    return 0; // Never exiting in our case
}

void* us_get_default_ca_store() {
    // Bun's default CA certificate store
    // TODO: Provide system CA store or custom certificates
    return NULL;
}

int us_internal_raw_root_certs(void** out) {
    // Bun's embedded root certificates
    (void)out;
    return 0; // No embedded certs
}

// =============================================================================
// Configuration Constants
// =============================================================================

// Maximum HTTP header size (16KB default)
int BUN_DEFAULT_MAX_HTTP_HEADER_SIZE = 16 * 1024;

// =============================================================================
// Mutex Stubs
// =============================================================================
// Bun uses custom mutexes for thread safety in uSockets.
// Since we're single-threaded for now, these are no-ops.
// TODO: Implement proper mutexes when adding multi-threading

void Bun__lock(void* mutex) { (void)mutex; }
void Bun__unlock(void* mutex) { (void)mutex; }

// =============================================================================
// Event Loop Integration Stubs
// =============================================================================
// Bun integrates uSockets with JavaScriptCore's event loop.
// We don't need these for our Zig-based server.

void Bun__JSC_onBeforeWait(void* loop) { (void)loop; }

void Bun__internal_dispatch_ready_poll(void* p, int error, int eof, int events) {
    (void)p; (void)error; (void)eof; (void)events;
}

void Bun__internal_ensureDateHeaderTimerIsEnabled(void* loop) { (void)loop; }

// =============================================================================
// Platform Detection
// =============================================================================

int Bun__doesMacOSVersionSupportSendRecvMsgX() {
#ifdef __APPLE__
    return 1; // Assume modern macOS
#else
    return 0;
#endif
}

// =============================================================================
// HTTP Method Parsing
// =============================================================================

int Bun__HTTPMethod__from(void* str, size_t len) {
    // Bun's HTTP method enum parser
    // TODO: Implement if we need HTTP method detection
    (void)str; (void)len;
    return 0; // Unknown/None
}

// =============================================================================
// C-Ares Compatibility
// =============================================================================
// Bun's uSockets uses c-ares for DNS, which has this helper function.
// We provide a simple wrapper around standard inet_ntop.

#include <arpa/inet.h>

const char *ares_inet_ntop(int af, const void *src, char *dst, size_t size) {
    return inet_ntop(af, src, dst, (socklen_t)size);
}
