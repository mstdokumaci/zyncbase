// Wrapper header for Zig to import ZyncBase's uWebSockets C bridge.
// This header provides C-compatible declarations for the C++ enums

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "libusockets.h"

#ifdef __cplusplus
extern "C" {
#endif

// Forward declarations
struct uws_app_s;
struct uws_req_s;
struct uws_res_s;
struct uws_websocket_s;
struct uws_socket_context_s;  // other structs from libusockets.h

typedef struct uws_app_s uws_app_t;
typedef struct uws_req_s uws_req_t;
typedef struct uws_res_s uws_res_t;
typedef struct uws_socket_context_s uws_socket_context_t;
typedef struct uws_websocket_s uws_websocket_t;

// Opcode enum (C-compatible)
typedef enum {
    UWS_OPCODE_TEXT = 1,
    UWS_OPCODE_BINARY = 2,
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
typedef void (*uws_websocket_upgrade_handler)(void *upgrade_context, uws_res_t *res, uws_req_t *req, uws_socket_context_t *context, size_t id);
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
    
    uws_websocket_upgrade_handler upgrade;
    uws_websocket_handler open;
    uws_websocket_message_handler message;
    uws_websocket_handler drain;
    uws_websocket_ping_pong_handler ping;
    uws_websocket_ping_pong_handler pong;
    uws_websocket_close_handler close;
} uws_socket_behavior_t;

// SSL options struct (defined in libusockets.h)
// us_socket_context_options_t — see vendor/usockets/libusockets.h

// Function declarations
uws_app_t *uws_create_app(int ssl, struct us_socket_context_options_t options);
void uws_destroy_app(int ssl, uws_app_t *app);
void uws_app_run(int ssl, uws_app_t *app);
void uws_app_close(int ssl, uws_app_t *app);
struct us_listen_socket_t *uws_app_listen(int ssl, uws_app_t *app, const char *host, size_t host_length, int port, uws_listen_handler handler, void *user_data);

// Loop helpers — us_wakeup_loop, us_listen_socket_close declared in libusockets.h
struct us_loop_t *uws_get_loop();
void uws_loop_addPostHandler(void *loop, void *ctx, void (*cb)(void *ctx, void *loop));
void uws_loop_removePostHandler(void *loop, void *key);

void uws_ws(int ssl, uws_app_t *app, void *upgrade_context, const char *pattern, size_t pattern_length, size_t id, const uws_socket_behavior_t *behavior);
uws_sendstatus_t uws_ws_send(int ssl, uws_websocket_t *ws, const char *message, size_t length, uws_opcode_t opcode);
void uws_ws_close(int ssl, uws_websocket_t *ws);
void *uws_ws_get_user_data(int ssl, uws_websocket_t *ws);

// Upgrade and Request helpers
size_t uws_req_get_header(uws_req_t *req, const char *lower_case_header, size_t lower_case_header_length, const char **dest);
size_t uws_req_get_query(uws_req_t *req, const char *key, size_t key_length, const char **dest);
void uws_res_upgrade(int ssl, uws_res_t *res, void *data, const char *sec_web_socket_key, size_t sec_web_socket_key_length, const char *sec_web_socket_protocol, size_t sec_web_socket_protocol_length, const char *sec_web_socket_extensions, size_t sec_web_socket_extensions_length, uws_socket_context_t *context);

// HTTP POST routing and response writing helpers
typedef void (*uws_http_handler)(uws_res_t *res, uws_req_t *req, void *user_data);
typedef void (*uws_res_data_handler)(uws_res_t *res, const char *chunk, size_t chunk_length, int is_last, void *user_data);
typedef void (*uws_res_aborted_handler)(void *user_data);

void uws_app_post(int ssl, uws_app_t *app, const char *pattern, size_t pattern_length, uws_http_handler handler, void *user_data);
void uws_res_write_status(int ssl, uws_res_t *res, const char *status, size_t status_length);
void uws_res_write_header(int ssl, uws_res_t *res, const char *key, size_t key_length, const char *value, size_t value_length);
void uws_res_end(int ssl, uws_res_t *res, const char *body, size_t body_length, int close_connection);
void uws_res_on_data(int ssl, uws_res_t *res, uws_res_data_handler handler, void *user_data);
void uws_res_on_aborted(int ssl, uws_res_t *res, uws_res_aborted_handler handler, void *user_data);

// OpenSSL signature verification helpers
int openssl_verify_rsa(
    const char *hash_alg,
    const unsigned char *n_bytes, size_t n_len,
    const unsigned char *e_bytes, size_t e_len,
    const unsigned char *data, size_t data_len,
    const unsigned char *sig, size_t sig_len);

int openssl_verify_rsa_pss(
    const char *hash_alg,
    const unsigned char *n_bytes, size_t n_len,
    const unsigned char *e_bytes, size_t e_len,
    const unsigned char *data, size_t data_len,
    const unsigned char *sig, size_t sig_len);

int openssl_verify_ec(
    const char *curve_name,
    const unsigned char *x_bytes, size_t x_len,
    const unsigned char *y_bytes, size_t y_len,
    const unsigned char *data, size_t data_len,
    const unsigned char *sig, size_t sig_len);

#ifdef __cplusplus
}
#endif

