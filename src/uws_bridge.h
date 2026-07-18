#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum uws_compress_options_t : int32_t {
    _COMPRESSOR_MASK = 0x00FF,
    _DECOMPRESSOR_MASK = 0x0F00,
    DISABLED = 0,
    SHARED_COMPRESSOR = 1,
    SHARED_DECOMPRESSOR = 1 << 8,
};

enum uws_opcode_t : int32_t {
    CONTINUATION = 0,
    TEXT = 1,
    BINARY = 2,
    CLOSE = 8,
    PING = 9,
    PONG = 10
};

enum uws_sendstatus_t : uint32_t { BACKPRESSURE, SUCCESS, DROPPED };

struct uws_app_s;
struct uws_req_s;
struct uws_res_s;
struct uws_websocket_s;
typedef struct uws_app_s uws_app_t;
typedef struct uws_req_s uws_req_t;
typedef struct uws_res_s uws_res_t;
typedef struct uws_socket_context_s uws_socket_context_t;
typedef struct uws_websocket_s uws_websocket_t;

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
typedef void (*uws_websocket_upgrade_handler)(void *, uws_res_t *response,
                                              uws_req_t *request,
                                              uws_socket_context_t *context,
                                              size_t id);

typedef struct {
    uws_compress_options_t compression;
    unsigned int maxPayloadLength;
    unsigned short idleTimeout;
    unsigned int maxBackpressure;
    bool closeOnBackpressureLimit;
    bool resetIdleTimeoutOnSend;
    bool sendPingsAutomatically;
    unsigned short maxLifetime;
    uws_websocket_upgrade_handler upgrade;
    uws_websocket_handler open;
    uws_websocket_message_handler message;
    uws_websocket_handler drain;
    uws_websocket_ping_pong_handler ping;
    uws_websocket_ping_pong_handler pong;
    uws_websocket_close_handler close;
} uws_socket_behavior_t;

typedef void (*uws_listen_handler)(struct us_listen_socket_t *listen_socket,
                                   void *user_data);

typedef void (*uws_http_handler)(uws_res_t *res, uws_req_t *req, void *user_data);
typedef void (*uws_res_data_handler)(uws_res_t *res, const char *chunk, size_t chunk_length, int is_last, void *user_data);
typedef void (*uws_res_aborted_handler)(void *user_data);

struct us_loop_t *uws_get_loop();
void uws_loop_defer(struct us_loop_t *loop, void *ctx, void (*cb)(void *ctx));

#ifdef __cplusplus
}
#endif
