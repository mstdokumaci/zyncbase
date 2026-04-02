#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <sys/types.h>

/**
 * Bun-specific function stubs for uWebSockets integration
 * 
 * Bun's fork of uWebSockets includes calls to Bun-specific functions that don't exist
 * in the standard uWebSockets library. These stubs allow us to link successfully while
 * providing minimal implementations.
 */

// =============================================================================
// Mutex and Lock Stubs
// =============================================================================
// Bun uses custom mutexes for thread safety in uWebSockets.
// We define a dummy type and size to satisfy Bun's runtime checks.

typedef struct { char dummy[64]; } zig_mutex_t;
const size_t Bun__lock__size = sizeof(zig_mutex_t);

void Bun__lock(zig_mutex_t *mutex) { (void)mutex; }
void Bun__unlock(zig_mutex_t *mutex) { (void)mutex; }

// =============================================================================
// DNS Resolution Stubs
// =============================================================================
// Bun uses custom async DNS resolution. For now, we return errors.

int Bun__addrinfo_get(void* loop, const char* host, uint16_t port, void** ptr) {
    (void)loop; (void)host; (void)port; (void)ptr;
    return -1;
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
// Event Loop and Runtime Hooks
// =============================================================================

void Bun__JSC_onBeforeWait(void* loop) { (void)loop; }

// Fixed signature: matches epoll_kqueue.c expectation
void Bun__internal_dispatch_ready_poll(void* loop, void* poll) {
    (void)loop; (void)poll;
}

void Bun__internal_ensureDateHeaderTimerIsEnabled(void* loop) { 
    (void)loop; 
}

void __attribute__((__noreturn__)) Bun__panic(const char* message, size_t length) {
    (void)message; (void)length;
    abort();
}

static int is_exiting_flag = 0;

int bun_is_exiting() { return is_exiting_flag; }

void set_bun_is_exiting(int exiting) {
    is_exiting_flag = exiting;
}

bool Bun__Node__UseSystemCA = true;

// =============================================================================
// Networking and Platform Stubs
// =============================================================================

int Bun__doesMacOSVersionSupportSendRecvMsgX() {
#ifdef __APPLE__
    return 1;
#else
    return 0;
#endif
}

#ifdef __linux__
#include <sys/epoll.h>
#include <signal.h>
#include <time.h>
#else
struct epoll_event;
#ifndef _SIGSET_T
#define _SIGSET_T
typedef struct { unsigned long sig[2]; } sigset_t;
#endif
#endif

#include <errno.h>

int Bun__isEpollPwait2SupportedOnLinuxKernel() {
    return 0; // Return 0 to trigger fallback to standard epoll_pwait
}

ssize_t sys_epoll_pwait2(int epfd, struct epoll_event* events, int maxevents, const struct timespec* timeout, const sigset_t* sigmask) {
    (void)epfd; (void)events; (void)maxevents; (void)timeout; (void)sigmask;
    return -ENOSYS;
}

// =============================================================================
// Other Bun Utilities
// =============================================================================

void* us_get_default_ca_store() { return NULL; }

int us_internal_raw_root_certs(void** out) {
    (void)out;
    return 0;
}

int BUN_DEFAULT_MAX_HTTP_HEADER_SIZE = 16 * 1024;

int Bun__HTTPMethod__from(void* str, size_t len) {
    (void)str; (void)len;
    return 0;
}

#include <arpa/inet.h>
const char *ares_inet_ntop(int af, const void *src, char *dst, size_t size) {
    return inet_ntop(af, src, dst, (socklen_t)size);
}

// =============================================================================
// SQLite Helpers
// =============================================================================
// Define a sentinel symbol that mirrors SQLITE_TRANSIENT (-1).
// This is used by Zig to avoid alignment errors that occur when casting -1 
// directly to a function pointer type in a TSAN-instrumented ARM64 build.
const void* const zyncbase_sqlite_transient = (void*)(intptr_t)-1;
