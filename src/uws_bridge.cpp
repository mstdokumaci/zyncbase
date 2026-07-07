#include "uws_bridge.h"
#include "libusockets.h"
#include "App.h"
#include "AsyncSocket.h"
#include "internal/internal.h"
#include <string_view>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/param_build.h>
#include <openssl/core_names.h>


#define uws_res_r uws_res_t*

static inline std::string_view stringViewFromC(const char* message, size_t length) {
    if (message && length) {
        return std::string_view(message, length);
    }
    return std::string_view();
}

using TLSWebSocket = uWS::WebSocket<true, true, void *>;
using TCPWebSocket = uWS::WebSocket<false, true, void *>;

extern "C"
{

    uws_app_t *uws_create_app(int ssl, struct us_socket_context_options_t options)
    {
        if (ssl) {
            uWS::SocketContextOptions socket_context_options;
            memcpy(&socket_context_options, &options,
                   sizeof(uWS::SocketContextOptions));
            auto *app = new uWS::SSLApp(socket_context_options);
            if (app->constructorFailed()) {
                delete app;
                return nullptr;
            }
            return (uws_app_t *)app;
        }
        auto *app = new uWS::App();
        if (app->constructorFailed()) {
            delete app;
            return nullptr;
        }
        return (uws_app_t *)app;
    }

    void uws_destroy_app(int ssl, uws_app_t *app)
    {
        if (ssl) {
            delete (uWS::SSLApp *)app;
        } else {
            delete (uWS::App *)app;
        }
    }

    void uws_app_run(int ssl, uws_app_t *app)
    {
        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            uwsApp->run();
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            uwsApp->run();
        }
    }

    void uws_app_close(int ssl, uws_app_t *app)
    {
        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            uwsApp->close();
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            uwsApp->close();
        }
    }

    struct us_listen_socket_t *uws_app_listen(
        int ssl, uws_app_t *app, const char *host, size_t host_length, int port,
        uws_listen_handler handler, void *user_data)
    {
        struct us_listen_socket_t *listen_socket = nullptr;
        auto listen_handler = [handler, user_data,
                               &listen_socket](struct us_listen_socket_t *ls) {
            listen_socket = ls;
            handler(ls, user_data);
        };

        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            if (host && host_length) {
                uwsApp->listen(std::string(host, host_length), port,
                               std::move(listen_handler));
            } else {
                uwsApp->listen(port, std::move(listen_handler));
            }
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            if (host && host_length) {
                uwsApp->listen(std::string(host, host_length), port,
                               std::move(listen_handler));
            } else {
                uwsApp->listen(port, std::move(listen_handler));
            }
        }

        return listen_socket;
    }

    void uws_ws(int ssl, uws_app_t *app, void *upgradeContext,
                const char *pattern, size_t pattern_length, size_t id,
                const uws_socket_behavior_t *behavior_)
    {
        uws_socket_behavior_t behavior = *behavior_;

        if (ssl) {
            auto generic_handler = uWS::SSLApp::WebSocketBehavior<void *>{
                .compression =
                    (uWS::CompressOptions)(uint64_t)behavior.compression,
                .maxPayloadLength = behavior.maxPayloadLength,
                .idleTimeout = behavior.idleTimeout,
                .maxBackpressure = behavior.maxBackpressure,
                .closeOnBackpressureLimit = behavior.closeOnBackpressureLimit,
                .resetIdleTimeoutOnSend = behavior.resetIdleTimeoutOnSend,
                .sendPingsAutomatically = behavior.sendPingsAutomatically,
                .maxLifetime = behavior.maxLifetime,
            };

            if (behavior.upgrade)
                generic_handler.upgrade =
                    [behavior, upgradeContext,
                     id](auto *res, auto *req, auto *context) {
                        behavior.upgrade(upgradeContext, (uws_res_t *)res,
                                         (uws_req_t *)req,
                                         (uws_socket_context_t *)context, id);
                    };
            if (behavior.open)
                generic_handler.open = [behavior](auto *ws) {
                    behavior.open((uws_websocket_t *)ws);
                };
            if (behavior.message)
                generic_handler.message =
                    [behavior](auto *ws, auto message, auto opcode) {
                        behavior.message((uws_websocket_t *)ws,
                                         message.data(), message.length(),
                                         (uws_opcode_t)opcode);
                    };
            if (behavior.drain)
                generic_handler.drain = [behavior](auto *ws) {
                    behavior.drain((uws_websocket_t *)ws);
                };
            if (behavior.ping)
                generic_handler.ping = [behavior](auto *ws, auto message) {
                    behavior.ping((uws_websocket_t *)ws, message.data(),
                                  message.length());
                };
            if (behavior.pong)
                generic_handler.pong = [behavior](auto *ws, auto message) {
                    behavior.pong((uws_websocket_t *)ws, message.data(),
                                  message.length());
                };
            if (behavior.close)
                generic_handler.close =
                    [behavior](auto *ws, int code, auto message) {
                        behavior.close((uws_websocket_t *)ws, code,
                                       message.data(), message.length());
                    };
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            uwsApp->ws<void *>(pattern ? std::string(pattern, pattern_length) : std::string(),
                               std::move(generic_handler));
        } else {
            auto generic_handler = uWS::App::WebSocketBehavior<void *>{
                .compression =
                    (uWS::CompressOptions)(uint64_t)behavior.compression,
                .maxPayloadLength = behavior.maxPayloadLength,
                .idleTimeout = behavior.idleTimeout,
                .maxBackpressure = behavior.maxBackpressure,
                .closeOnBackpressureLimit = behavior.closeOnBackpressureLimit,
                .resetIdleTimeoutOnSend = behavior.resetIdleTimeoutOnSend,
                .sendPingsAutomatically = behavior.sendPingsAutomatically,
                .maxLifetime = behavior.maxLifetime,
            };

            if (behavior.upgrade)
                generic_handler.upgrade =
                    [behavior, upgradeContext,
                     id](auto *res, auto *req, auto *context) {
                        behavior.upgrade(upgradeContext, (uws_res_t *)res,
                                         (uws_req_t *)req,
                                         (uws_socket_context_t *)context, id);
                    };
            if (behavior.open)
                generic_handler.open = [behavior](auto *ws) {
                    behavior.open((uws_websocket_t *)ws);
                };
            if (behavior.message)
                generic_handler.message =
                    [behavior](auto *ws, auto message, auto opcode) {
                        behavior.message((uws_websocket_t *)ws,
                                         message.data(), message.length(),
                                         (uws_opcode_t)opcode);
                    };
            if (behavior.drain)
                generic_handler.drain = [behavior](auto *ws) {
                    behavior.drain((uws_websocket_t *)ws);
                };
            if (behavior.ping)
                generic_handler.ping = [behavior](auto *ws, auto message) {
                    behavior.ping((uws_websocket_t *)ws, message.data(),
                                  message.length());
                };
            if (behavior.pong)
                generic_handler.pong = [behavior](auto *ws, auto message) {
                    behavior.pong((uws_websocket_t *)ws, message.data(),
                                  message.length());
                };
            if (behavior.close)
                generic_handler.close =
                    [behavior](auto *ws, int code, auto message) {
                        behavior.close((uws_websocket_t *)ws, code,
                                       message.data(), message.length());
                    };
            uWS::App *uwsApp = (uWS::App *)app;
            uwsApp->ws<void *>(pattern ? std::string(pattern, pattern_length) : std::string(),
                               std::move(generic_handler));
        }
    }

    void *uws_ws_get_user_data(int ssl, uws_websocket_t *ws)
    {
        if (ssl) {
            TLSWebSocket *uws = (TLSWebSocket *)ws;
            return *uws->getUserData();
        }
        TCPWebSocket *uws = (TCPWebSocket *)ws;
        return *uws->getUserData();
    }

    void uws_ws_close(int ssl, uws_websocket_t *ws)
    {
        if (ssl) {
            TLSWebSocket *uws = (TLSWebSocket *)ws;
            uws->close();
        } else {
            TCPWebSocket *uws = (TCPWebSocket *)ws;
            uws->close();
        }
    }

    uws_sendstatus_t uws_ws_send(int ssl, uws_websocket_t *ws,
                                 const char *message, size_t length,
                                 uws_opcode_t opcode)
    {
        if (ssl) {
            TLSWebSocket *uws = (TLSWebSocket *)ws;
            return (uws_sendstatus_t)uws->send(
                stringViewFromC(message, length),
                (uWS::OpCode)(unsigned char)opcode);
        }
        TCPWebSocket *uws = (TCPWebSocket *)ws;
        return (uws_sendstatus_t)uws->send(
            stringViewFromC(message, length),
            (uWS::OpCode)(unsigned char)opcode);
    }

    size_t uws_req_get_header(uws_req_t *res, const char *lower_case_header,
                              size_t lower_case_header_length,
                              const char **dest)
    {
        uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
        std::string_view value = uwsReq->getHeader(
            stringViewFromC(lower_case_header, lower_case_header_length));
        *dest = value.data();
        return value.length();
    }

    size_t uws_req_get_query(uws_req_t *res, const char *key,
                             size_t key_length, const char **dest)
    {
        uWS::HttpRequest *uwsReq = (uWS::HttpRequest *)res;
        std::string_view value =
            uwsReq->getQuery(stringViewFromC(key, key_length));
        *dest = value.data();
        return value.length();
    }

    void uws_res_upgrade(
        int ssl, uws_res_r res, void *data,
        const char *sec_web_socket_key, size_t sec_web_socket_key_length,
        const char *sec_web_socket_protocol,
        size_t sec_web_socket_protocol_length,
        const char *sec_web_socket_extensions,
        size_t sec_web_socket_extensions_length, uws_socket_context_t *ws)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            uwsRes->template upgrade<void *>(
                data ? std::move(data) : nullptr,
                stringViewFromC(sec_web_socket_key,
                                sec_web_socket_key_length),
                stringViewFromC(sec_web_socket_protocol,
                                sec_web_socket_protocol_length),
                stringViewFromC(sec_web_socket_extensions,
                                sec_web_socket_extensions_length),
                (struct us_socket_context_t *)ws);
        } else {
            uWS::HttpResponse<false> *uwsRes =
                (uWS::HttpResponse<false> *)res;
            uwsRes->template upgrade<void *>(
                data ? std::move(data) : nullptr,
                stringViewFromC(sec_web_socket_key,
                                sec_web_socket_key_length),
                stringViewFromC(sec_web_socket_protocol,
                                sec_web_socket_protocol_length),
                stringViewFromC(sec_web_socket_extensions,
                                sec_web_socket_extensions_length),
                (struct us_socket_context_t *)ws);
        }
    }

    struct us_loop_t *uws_get_loop()
    {
        return (struct us_loop_t *)uWS::Loop::get();
    }

    void uws_loop_addPostHandler(us_loop_t *loop, void *ctx_,
                                 void (*cb)(void *ctx, us_loop_t *loop))
    {
        uWS::Loop *uwsLoop = (uWS::Loop *)loop;
        uwsLoop->addPostHandler(ctx_, [ctx_, cb](uWS::Loop *uwsLoop_) {
            cb(ctx_, (us_loop_t *)uwsLoop_);
        });
    }

    void uws_loop_removePostHandler(us_loop_t *loop, void *key)
    {
        uWS::Loop *uwsLoop = (uWS::Loop *)loop;
        uwsLoop->removePostHandler(key);
    }

    void uws_app_post(int ssl, uws_app_t *app, const char *pattern, size_t pattern_length, uws_http_handler handler, void *user_data)
    {
        std::string pat = pattern ? std::string(pattern, pattern_length) : std::string();
        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            uwsApp->post(pat, [handler, user_data](auto *res, auto *req) {
                handler((uws_res_t *)res, (uws_req_t *)req, user_data);
            });
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            uwsApp->post(pat, [handler, user_data](auto *res, auto *req) {
                handler((uws_res_t *)res, (uws_req_t *)req, user_data);
            });
        }
    }

    void uws_res_write_status(int ssl, uws_res_t *res, const char *status, size_t status_length)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            uwsRes->writeStatus(std::string_view(status, status_length));
        } else {
            uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
            uwsRes->writeStatus(std::string_view(status, status_length));
        }
    }

    void uws_res_write_header(int ssl, uws_res_t *res, const char *key, size_t key_length, const char *value, size_t value_length)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            uwsRes->writeHeader(std::string_view(key, key_length), std::string_view(value, value_length));
        } else {
            uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
            uwsRes->writeHeader(std::string_view(key, key_length), std::string_view(value, value_length));
        }
    }

    void uws_res_end(int ssl, uws_res_t *res, const char *body, size_t body_length, int close_connection)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            uwsRes->end(std::string_view(body, body_length), close_connection ? true : false);
        } else {
            uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
            uwsRes->end(std::string_view(body, body_length), close_connection ? true : false);
        }
    }

    void uws_res_on_data(int ssl, uws_res_t *res, uws_res_data_handler handler, void *user_data)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            uwsRes->onData([handler, res, user_data](std::string_view chunk, bool is_last) {
                handler(res, chunk.data(), chunk.length(), is_last ? 1 : 0, user_data);
            });
        } else {
            uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
            uwsRes->onData([handler, res, user_data](std::string_view chunk, bool is_last) {
                handler(res, chunk.data(), chunk.length(), is_last ? 1 : 0, user_data);
            });
        }
    }

    void uws_res_on_aborted(int ssl, uws_res_t *res, uws_res_aborted_handler handler, void *user_data)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            uwsRes->onAborted([handler, user_data]() {
                handler(user_data);
            });
        } else {
            uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
            uwsRes->onAborted([handler, user_data]() {
                handler(user_data);
            });
        }
    }

    int openssl_verify_rsa(
        const char *hash_alg,
        const unsigned char *n_bytes, size_t n_len,
        const unsigned char *e_bytes, size_t e_len,
        const unsigned char *data, size_t data_len,
        const unsigned char *sig, size_t sig_len)
    {
        OSSL_PARAM_BLD *param_bld = OSSL_PARAM_BLD_new();
        if (!param_bld) return 0;

        BIGNUM *bn_n = BN_bin2bn(n_bytes, n_len, nullptr);
        BIGNUM *bn_e = BN_bin2bn(e_bytes, e_len, nullptr);
        if (!bn_n || !bn_e) {
            if (bn_n) BN_free(bn_n);
            if (bn_e) BN_free(bn_e);
            OSSL_PARAM_BLD_free(param_bld);
            return 0;
        }

        OSSL_PARAM_BLD_push_BN(param_bld, OSSL_PKEY_PARAM_RSA_N, bn_n);
        OSSL_PARAM_BLD_push_BN(param_bld, OSSL_PKEY_PARAM_RSA_E, bn_e);

        OSSL_PARAM *params = OSSL_PARAM_BLD_to_param(param_bld);
        OSSL_PARAM_BLD_free(param_bld);
        BN_free(bn_n);
        BN_free(bn_e);

        if (!params) return 0;

        EVP_PKEY_CTX *pkey_ctx = EVP_PKEY_CTX_new_from_name(nullptr, "RSA", nullptr);
        EVP_PKEY *pkey = nullptr;
        if (pkey_ctx) {
            if (EVP_PKEY_fromdata_init(pkey_ctx) == 1) {
                EVP_PKEY_fromdata(pkey_ctx, &pkey, EVP_PKEY_PUBLIC_KEY, params);
            }
            EVP_PKEY_CTX_free(pkey_ctx);
        }
        OSSL_PARAM_free(params);

        if (!pkey) return 0;

        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        if (!ctx) {
            EVP_PKEY_free(pkey);
            return 0;
        }

        const EVP_MD *md = EVP_get_digestbyname(hash_alg);
        if (!md) {
            EVP_MD_CTX_free(ctx);
            EVP_PKEY_free(pkey);
            return 0;
        }

        int ret = 0;
        if (EVP_DigestVerifyInit(ctx, nullptr, md, nullptr, pkey) == 1) {
            if (EVP_DigestVerifyUpdate(ctx, data, data_len) == 1) {
                ret = EVP_DigestVerifyFinal(ctx, sig, sig_len);
            }
        }

        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        return ret == 1 ? 1 : 0;
    }

    int openssl_verify_rsa_pss(
        const char *hash_alg,
        const unsigned char *n_bytes, size_t n_len,
        const unsigned char *e_bytes, size_t e_len,
        const unsigned char *data, size_t data_len,
        const unsigned char *sig, size_t sig_len)
    {
        OSSL_PARAM_BLD *param_bld = OSSL_PARAM_BLD_new();
        if (!param_bld) return 0;

        BIGNUM *bn_n = BN_bin2bn(n_bytes, n_len, nullptr);
        BIGNUM *bn_e = BN_bin2bn(e_bytes, e_len, nullptr);
        if (!bn_n || !bn_e) {
            if (bn_n) BN_free(bn_n);
            if (bn_e) BN_free(bn_e);
            OSSL_PARAM_BLD_free(param_bld);
            return 0;
        }

        if (OSSL_PARAM_BLD_push_BN(param_bld, OSSL_PKEY_PARAM_RSA_N, bn_n) != 1 ||
            OSSL_PARAM_BLD_push_BN(param_bld, OSSL_PKEY_PARAM_RSA_E, bn_e) != 1) {
            BN_free(bn_n);
            BN_free(bn_e);
            OSSL_PARAM_BLD_free(param_bld);
            return 0;
        }

        OSSL_PARAM *params = OSSL_PARAM_BLD_to_param(param_bld);
        OSSL_PARAM_BLD_free(param_bld);
        BN_free(bn_n);
        BN_free(bn_e);

        if (!params) return 0;

        EVP_PKEY_CTX *pkey_ctx = EVP_PKEY_CTX_new_from_name(nullptr, "RSA", nullptr);
        EVP_PKEY *pkey = nullptr;
        if (pkey_ctx) {
            if (EVP_PKEY_fromdata_init(pkey_ctx) == 1) {
                EVP_PKEY_fromdata(pkey_ctx, &pkey, EVP_PKEY_PUBLIC_KEY, params);
            }
            EVP_PKEY_CTX_free(pkey_ctx);
        }
        OSSL_PARAM_free(params);

        if (!pkey) return 0;

        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        if (!ctx) {
            EVP_PKEY_free(pkey);
            return 0;
        }

        const EVP_MD *md = EVP_get_digestbyname(hash_alg);
        if (!md) {
            EVP_MD_CTX_free(ctx);
            EVP_PKEY_free(pkey);
            return 0;
        }

        int ret = 0;
        EVP_PKEY_CTX *pctx = nullptr;
        if (EVP_DigestVerifyInit(ctx, &pctx, md, nullptr, pkey) == 1) {
            if (EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) == 1 &&
                EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) == 1) {
                if (EVP_DigestVerifyUpdate(ctx, data, data_len) == 1) {
                    ret = EVP_DigestVerifyFinal(ctx, sig, sig_len);
                }
            }
        }

        EVP_MD_CTX_free(ctx);
        EVP_PKEY_free(pkey);
        return ret == 1 ? 1 : 0;
    }

    int openssl_verify_ec(
        const char *curve_name,
        const unsigned char *x_bytes, size_t x_len,
        const unsigned char *y_bytes, size_t y_len,
        const unsigned char *data, size_t data_len,
        const unsigned char *sig, size_t sig_len)
    {
        OSSL_PARAM_BLD *param_bld = OSSL_PARAM_BLD_new();
        if (!param_bld) return 0;

        const char *group_name = nullptr;
        if (strcmp(curve_name, "P-256") == 0 || strcmp(curve_name, "ES256") == 0) {
            group_name = "P-256";
        } else if (strcmp(curve_name, "P-384") == 0 || strcmp(curve_name, "ES384") == 0) {
            group_name = "P-384";
        } else if (strcmp(curve_name, "P-521") == 0 || strcmp(curve_name, "ES512") == 0) {
            group_name = "P-521";
        } else {
            OSSL_PARAM_BLD_free(param_bld);
            return 0;
        }

        OSSL_PARAM_BLD_push_utf8_string(param_bld, OSSL_PKEY_PARAM_GROUP_NAME, group_name, 0);

        size_t pub_key_len = 1 + x_len + y_len;
        unsigned char *pub_key_oct = (unsigned char *)malloc(pub_key_len);
        if (!pub_key_oct) {
            OSSL_PARAM_BLD_free(param_bld);
            return 0;
        }
        pub_key_oct[0] = 0x04; // uncompressed format
        memcpy(pub_key_oct + 1, x_bytes, x_len);
        memcpy(pub_key_oct + 1 + x_len, y_bytes, y_len);

        OSSL_PARAM_BLD_push_octet_string(param_bld, OSSL_PKEY_PARAM_PUB_KEY, pub_key_oct, pub_key_len);

        OSSL_PARAM *params = OSSL_PARAM_BLD_to_param(param_bld);
        OSSL_PARAM_BLD_free(param_bld);
        free(pub_key_oct);

        if (!params) return 0;

        EVP_PKEY_CTX *pkey_ctx = EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr);
        EVP_PKEY *pkey = nullptr;
        if (pkey_ctx) {
            if (EVP_PKEY_fromdata_init(pkey_ctx) == 1) {
                EVP_PKEY_fromdata(pkey_ctx, &pkey, EVP_PKEY_PUBLIC_KEY, params);
            }
            EVP_PKEY_CTX_free(pkey_ctx);
        }
        OSSL_PARAM_free(params);

        if (!pkey) return 0;

        if (sig_len % 2 != 0) {
            EVP_PKEY_free(pkey);
            return 0;
        }

        size_t half_len = sig_len / 2;
        BIGNUM *bn_r = BN_bin2bn(sig, half_len, nullptr);
        BIGNUM *bn_s = BN_bin2bn(sig + half_len, half_len, nullptr);
        if (!bn_r || !bn_s) {
            if (bn_r) BN_free(bn_r);
            if (bn_s) BN_free(bn_s);
            EVP_PKEY_free(pkey);
            return 0;
        }

        ECDSA_SIG *ec_sig = ECDSA_SIG_new();
        if (!ec_sig) {
            BN_free(bn_r);
            BN_free(bn_s);
            EVP_PKEY_free(pkey);
            return 0;
        }
        ECDSA_SIG_set0(ec_sig, bn_r, bn_s);

        unsigned char *der_sig = nullptr;
        int der_sig_len = i2d_ECDSA_SIG(ec_sig, &der_sig);
        ECDSA_SIG_free(ec_sig);

        if (der_sig_len <= 0 || !der_sig) {
            EVP_PKEY_free(pkey);
            return 0;
        }

        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        if (!ctx) {
            OPENSSL_free(der_sig);
            EVP_PKEY_free(pkey);
            return 0;
        }

        const EVP_MD *md = nullptr;
        if (strcmp(group_name, "P-256") == 0) {
            md = EVP_sha256();
        } else if (strcmp(group_name, "P-384") == 0) {
            md = EVP_sha384();
        } else if (strcmp(group_name, "P-521") == 0) {
            md = EVP_sha512();
        }

        if (!md) {
            EVP_MD_CTX_free(ctx);
            OPENSSL_free(der_sig);
            EVP_PKEY_free(pkey);
            return 0;
        }

        int ret = 0;
        if (EVP_DigestVerifyInit(ctx, nullptr, md, nullptr, pkey) == 1) {
            if (EVP_DigestVerifyUpdate(ctx, data, data_len) == 1) {
                ret = EVP_DigestVerifyFinal(ctx, der_sig, der_sig_len);
            }
        }

        EVP_MD_CTX_free(ctx);
        OPENSSL_free(der_sig);
        EVP_PKEY_free(pkey);
        return ret == 1 ? 1 : 0;
    }
}

