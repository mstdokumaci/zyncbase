// Wrapper header for Zig to import Bun's uWebSockets C API
// This header provides C-compatible declarations for the C++ enums

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
struct uws_app_s;
struct uws_req_s;
struct uws_res_s;
struct uws_websocket_s;
struct uws_socket_context_s;
struct us_listen_socket_t;
struct us_bun_socket_context_options_t;

typedef struct uws_app_s uws_app_t;
typedef struct uws_req_s uws_req_t;
typedef struct uws_res_s uws_res_t;
typedef struct uws_socket_context_s uws_socket_context_t;
typedef struct uws_websocket_s uws_websocket_t;

// Opcode enum (C-compatible)
typedef enum {
    UWS_OPCODE_CONTINUATION = 0,
    UWS_OPCODE_TEXT = 1,
    UWS_OPCODE_BINARY = 2,
    UWS_OPCODE_CLOSE = 8,
    UWS_OPCODE_PING = 9,
    UWS_OPCODE_PONG = 10
} uws_opcode_t;

// Send status enum (C-compatible)
typedef enum {
    UWS_SENDSTATUS_BACKPRESSURE = 0,
    UWS_SENDSTATUS_SUCCESS = 1,
    UWS_SENDSTATUS_DROPPED = 2
} uws_sendstatus_t;

// Compression options enum (C-compatible)
typedef enum {
    UWS_COMPRESS_DISABLED = 0,
    UWS_COMPRESS_SHARED_COMPRESSOR = 1,
    UWS_COMPRESS_SHARED_DECOMPRESSOR = 256
} uws_compress_options_t;

// Callback function types
typedef void (*uws_websocket_handler)(uws_websocket_t *ws);
typedef void (*uws_websocket_message_handler)(uws_websocket_t *ws,
                                              const char *message,
                                              size_t length,
                                              uws_opcode_t opcode);
typedef void (*uws_websocket_ping_pong_handler)(uws_websocket_t *ws,
                                                const char *message,
                                                size_t length);
typedef void (*uws_websocket_close_handler)(uws_websocket_t *ws, int code,
                                            const char *message, size_t length);
typedef void (*uws_listen_handler)(struct us_listen_socket_t *listen_socket,
                                   void *user_data);

// WebSocket behavior configuration
typedef struct {
    uws_compress_options_t compression;
    unsigned int maxPayloadLength;
    unsigned short idleTimeout;
    unsigned int maxBackpressure;
    bool closeOnBackpressureLimit;
    bool resetIdleTimeoutOnSend;
    bool sendPingsAutomatically;
    unsigned short maxLifetime;
    
    void *upgrade; // uws_websocket_upgrade_handler
    uws_websocket_handler open;
    uws_websocket_message_handler message;
    uws_websocket_handler drain;
    uws_websocket_ping_pong_handler ping;
    uws_websocket_ping_pong_handler pong;
    uws_websocket_close_handler close;
} uws_socket_behavior_t;

// SSL options struct (opaque for now)
typedef struct {
    char _placeholder;
} us_bun_socket_context_options_t;

// Function declarations
uws_app_t *uws_create_app(int ssl, us_bun_socket_context_options_t options);
void uws_app_run(int ssl, uws_app_t *app);
void uws_app_close(int ssl, uws_app_t *app);
void set_bun_is_exiting(int exiting);
void uws_app_listen(int ssl, uws_app_t *app, int port, uws_listen_handler handler, void *user_data);
void *uws_get_loop();
void us_wakeup_loop(void *loop);
void uws_ws(int ssl, uws_app_t *app, void *upgrade_context, const char *pattern, size_t pattern_length, size_t id, const uws_socket_behavior_t *behavior);
uws_sendstatus_t uws_ws_send(int ssl, uws_websocket_t *ws, const char *message, size_t length, uws_opcode_t opcode);
void uws_ws_close(int ssl, uws_websocket_t *ws);
void *uws_ws_get_user_data(int ssl, uws_websocket_t *ws);

#ifdef __cplusplus
}
#endif
