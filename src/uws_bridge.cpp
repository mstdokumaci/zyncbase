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

// ---------------------------------------------------------------------------
// Template implementations. Each SSL/non-SSL pair collapses into one body
// parameterized on the compile-time bool SSL, matching uWebSockets' own
// `template<bool SSL>` design. The extern "C" wrappers below dispatch to the
// two instantiations at runtime.
// ---------------------------------------------------------------------------

template<bool SSL>
static uws_app_t *uws_create_app_impl(struct us_socket_context_options_t options) {
    uWS::TemplatedApp<SSL> *app;
    if constexpr (SSL) {
        uWS::SocketContextOptions socket_context_options;
        memcpy(&socket_context_options, &options,
               sizeof(uWS::SocketContextOptions));
        app = new uWS::TemplatedApp<SSL>(socket_context_options);
    } else {
        app = new uWS::TemplatedApp<SSL>();
    }
    if (app->constructorFailed()) {
        delete app;
        return nullptr;
    }
    return (uws_app_t *)app;
}

template<bool SSL>
static void uws_destroy_app_impl(uws_app_t *app) {
    delete (uWS::TemplatedApp<SSL> *)app;
}

template<bool SSL>
static void uws_app_run_impl(uws_app_t *app) {
    ((uWS::TemplatedApp<SSL> *)app)->run();
}

template<bool SSL>
static void uws_app_close_impl(uws_app_t *app) {
    ((uWS::TemplatedApp<SSL> *)app)->close();
}

template<bool SSL>
static struct us_listen_socket_t *uws_app_listen_impl(
    uws_app_t *app, const char *host, size_t host_length, int port,
    uws_listen_handler handler, void *user_data) {
    struct us_listen_socket_t *listen_socket = nullptr;
    auto listen_handler = [handler, user_data,
                           &listen_socket](struct us_listen_socket_t *ls) {
        listen_socket = ls;
        handler(ls, user_data);
    };

    auto *uwsApp = (uWS::TemplatedApp<SSL> *)app;
    if (host && host_length) {
        uwsApp->listen(std::string(host, host_length), port,
                       std::move(listen_handler));
    } else {
        uwsApp->listen(port, std::move(listen_handler));
    }

    return listen_socket;
}

template<bool SSL>
static void uws_ws_impl(uws_app_t *app, void *upgradeContext,
                        const char *pattern, size_t pattern_length, size_t id,
                        const uws_socket_behavior_t *behavior_) {
    if (!behavior_) return;
    uws_socket_behavior_t behavior = *behavior_;
    using AppType = uWS::TemplatedApp<SSL>;

    auto generic_handler = typename AppType::template WebSocketBehavior<void *>{
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

    auto *uwsApp = (AppType *)app;
    uwsApp->template ws<void *>(pattern ? std::string(pattern, pattern_length) : std::string(),
                                std::move(generic_handler));
}

template<bool SSL>
static void *uws_ws_get_user_data_impl(uws_websocket_t *ws) {
    auto *uws = (uWS::WebSocket<SSL, true, void *> *)ws;
    return *uws->getUserData();
}

template<bool SSL>
static void uws_ws_close_impl(uws_websocket_t *ws) {
    ((uWS::WebSocket<SSL, true, void *> *)ws)->close();
}

template<bool SSL>
static uws_sendstatus_t uws_ws_send_impl(uws_websocket_t *ws,
                                         const char *message, size_t length,
                                         uws_opcode_t opcode) {
    auto *uws = (uWS::WebSocket<SSL, true, void *> *)ws;
    return (uws_sendstatus_t)uws->send(
        stringViewFromC(message, length),
        (uWS::OpCode)(unsigned char)opcode);
}

template<bool SSL>
static void uws_res_upgrade_impl(
    uws_res_t *res, void *data,
    const char *sec_web_socket_key, size_t sec_web_socket_key_length,
    const char *sec_web_socket_protocol,
    size_t sec_web_socket_protocol_length,
    const char *sec_web_socket_extensions,
    size_t sec_web_socket_extensions_length, uws_socket_context_t *ws) {
    auto *uwsRes = (uWS::HttpResponse<SSL> *)res;
    uwsRes->template upgrade<void *>(
        std::move(data),
        stringViewFromC(sec_web_socket_key,
                        sec_web_socket_key_length),
        stringViewFromC(sec_web_socket_protocol,
                        sec_web_socket_protocol_length),
        stringViewFromC(sec_web_socket_extensions,
                        sec_web_socket_extensions_length),
        (struct us_socket_context_t *)ws);
}

template<bool SSL>
static void uws_app_post_impl(uws_app_t *app, const char *pattern, size_t pattern_length, uws_http_handler handler, void *user_data) {
    std::string pat = pattern ? std::string(pattern, pattern_length) : std::string();
    auto *uwsApp = (uWS::TemplatedApp<SSL> *)app;
    uwsApp->post(pat, [handler, user_data](auto *res, auto *req) {
        handler((uws_res_t *)res, (uws_req_t *)req, user_data);
    });
}

template<bool SSL>
static void uws_res_write_status_impl(uws_res_t *res, const char *status, size_t status_length) {
    ((uWS::HttpResponse<SSL> *)res)->writeStatus(stringViewFromC(status, status_length));
}

template<bool SSL>
static void uws_res_write_header_impl(uws_res_t *res, const char *key, size_t key_length, const char *value, size_t value_length) {
    ((uWS::HttpResponse<SSL> *)res)->writeHeader(stringViewFromC(key, key_length), stringViewFromC(value, value_length));
}

template<bool SSL>
static void uws_res_end_impl(uws_res_t *res, const char *body, size_t body_length, int close_connection) {
    ((uWS::HttpResponse<SSL> *)res)->end(stringViewFromC(body, body_length), close_connection ? true : false);
}

template<bool SSL>
static void uws_res_on_data_impl(uws_res_t *res, uws_res_data_handler handler, void *user_data) {
    ((uWS::HttpResponse<SSL> *)res)->onData([handler, res, user_data](std::string_view chunk, bool is_last) {
        handler(res, chunk.data(), chunk.length(), is_last ? 1 : 0, user_data);
    });
}

template<bool SSL>
static void uws_res_on_aborted_impl(uws_res_t *res, uws_res_aborted_handler handler, void *user_data) {
    ((uWS::HttpResponse<SSL> *)res)->onAborted([handler, user_data]() {
        handler(user_data);
    });
}

extern "C"
{

    uws_app_t *uws_create_app(int ssl, struct us_socket_context_options_t options)
    {
        if (ssl) return uws_create_app_impl<true>(options);
        return uws_create_app_impl<false>(options);
    }

    void uws_destroy_app(int ssl, uws_app_t *app)
    {
        if (ssl) uws_destroy_app_impl<true>(app);
        else     uws_destroy_app_impl<false>(app);
    }

    void uws_app_run(int ssl, uws_app_t *app)
    {
        if (ssl) uws_app_run_impl<true>(app);
        else     uws_app_run_impl<false>(app);
    }

    void uws_app_close(int ssl, uws_app_t *app)
    {
        if (ssl) uws_app_close_impl<true>(app);
        else     uws_app_close_impl<false>(app);
    }

    struct us_listen_socket_t *uws_app_listen(
        int ssl, uws_app_t *app, const char *host, size_t host_length, int port,
        uws_listen_handler handler, void *user_data)
    {
        if (ssl) return uws_app_listen_impl<true>(app, host, host_length, port, handler, user_data);
        return uws_app_listen_impl<false>(app, host, host_length, port, handler, user_data);
    }

    void uws_ws(int ssl, uws_app_t *app, void *upgradeContext,
                const char *pattern, size_t pattern_length, size_t id,
                const uws_socket_behavior_t *behavior_)
    {
        if (ssl) uws_ws_impl<true>(app, upgradeContext, pattern, pattern_length, id, behavior_);
        else     uws_ws_impl<false>(app, upgradeContext, pattern, pattern_length, id, behavior_);
    }

    void *uws_ws_get_user_data(int ssl, uws_websocket_t *ws)
    {
        if (ssl) return uws_ws_get_user_data_impl<true>(ws);
        return uws_ws_get_user_data_impl<false>(ws);
    }

    void uws_ws_close(int ssl, uws_websocket_t *ws)
    {
        if (ssl) uws_ws_close_impl<true>(ws);
        else     uws_ws_close_impl<false>(ws);
    }

    uws_sendstatus_t uws_ws_send(int ssl, uws_websocket_t *ws,
                                 const char *message, size_t length,
                                 uws_opcode_t opcode)
    {
        if (ssl) return uws_ws_send_impl<true>(ws, message, length, opcode);
        return uws_ws_send_impl<false>(ws, message, length, opcode);
    }

    void uws_res_upgrade(
        int ssl, uws_res_r res, void *data,
        const char *sec_web_socket_key, size_t sec_web_socket_key_length,
        const char *sec_web_socket_protocol,
        size_t sec_web_socket_protocol_length,
        const char *sec_web_socket_extensions,
        size_t sec_web_socket_extensions_length, uws_socket_context_t *ws)
    {
        if (ssl) uws_res_upgrade_impl<true>(res, data, sec_web_socket_key, sec_web_socket_key_length, sec_web_socket_protocol, sec_web_socket_protocol_length, sec_web_socket_extensions, sec_web_socket_extensions_length, ws);
        else     uws_res_upgrade_impl<false>(res, data, sec_web_socket_key, sec_web_socket_key_length, sec_web_socket_protocol, sec_web_socket_protocol_length, sec_web_socket_extensions, sec_web_socket_extensions_length, ws);
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
        if (ssl) uws_app_post_impl<true>(app, pattern, pattern_length, handler, user_data);
        else     uws_app_post_impl<false>(app, pattern, pattern_length, handler, user_data);
    }

    void uws_res_write_status(int ssl, uws_res_t *res, const char *status, size_t status_length)
    {
        if (ssl) uws_res_write_status_impl<true>(res, status, status_length);
        else     uws_res_write_status_impl<false>(res, status, status_length);
    }

    void uws_res_write_header(int ssl, uws_res_t *res, const char *key, size_t key_length, const char *value, size_t value_length)
    {
        if (ssl) uws_res_write_header_impl<true>(res, key, key_length, value, value_length);
        else     uws_res_write_header_impl<false>(res, key, key_length, value, value_length);
    }

    void uws_res_end(int ssl, uws_res_t *res, const char *body, size_t body_length, int close_connection)
    {
        if (ssl) uws_res_end_impl<true>(res, body, body_length, close_connection);
        else     uws_res_end_impl<false>(res, body, body_length, close_connection);
    }

    void uws_res_on_data(int ssl, uws_res_t *res, uws_res_data_handler handler, void *user_data)
    {
        if (ssl) uws_res_on_data_impl<true>(res, handler, user_data);
        else     uws_res_on_data_impl<false>(res, handler, user_data);
    }

    void uws_res_on_aborted(int ssl, uws_res_t *res, uws_res_aborted_handler handler, void *user_data)
    {
        if (ssl) uws_res_on_aborted_impl<true>(res, handler, user_data);
        else     uws_res_on_aborted_impl<false>(res, handler, user_data);
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

    void* openssl_build_rsa_pkey(
        const unsigned char *n_bytes, size_t n_len,
        const unsigned char *e_bytes, size_t e_len)
    {
        OSSL_PARAM_BLD *param_bld = OSSL_PARAM_BLD_new();
        if (!param_bld) return nullptr;

        BIGNUM *bn_n = BN_bin2bn(n_bytes, n_len, nullptr);
        BIGNUM *bn_e = BN_bin2bn(e_bytes, e_len, nullptr);
        if (!bn_n || !bn_e) {
            if (bn_n) BN_free(bn_n);
            if (bn_e) BN_free(bn_e);
            OSSL_PARAM_BLD_free(param_bld);
            return nullptr;
        }

        OSSL_PARAM_BLD_push_BN(param_bld, OSSL_PKEY_PARAM_RSA_N, bn_n);
        OSSL_PARAM_BLD_push_BN(param_bld, OSSL_PKEY_PARAM_RSA_E, bn_e);

        OSSL_PARAM *params = OSSL_PARAM_BLD_to_param(param_bld);
        OSSL_PARAM_BLD_free(param_bld);
        BN_free(bn_n);
        BN_free(bn_e);

        if (!params) return nullptr;

        EVP_PKEY_CTX *pkey_ctx = EVP_PKEY_CTX_new_from_name(nullptr, "RSA", nullptr);
        EVP_PKEY *pkey = nullptr;
        if (pkey_ctx) {
            if (EVP_PKEY_fromdata_init(pkey_ctx) == 1) {
                EVP_PKEY_fromdata(pkey_ctx, &pkey, EVP_PKEY_PUBLIC_KEY, params);
            }
            EVP_PKEY_CTX_free(pkey_ctx);
        }
        OSSL_PARAM_free(params);

        return (void*)pkey;
    }

    void* openssl_build_ec_pkey(
        const char *curve_name,
        const unsigned char *x_bytes, size_t x_len,
        const unsigned char *y_bytes, size_t y_len)
    {
        OSSL_PARAM_BLD *param_bld = OSSL_PARAM_BLD_new();
        if (!param_bld) return nullptr;

        const char *group_name = nullptr;
        if (strcmp(curve_name, "P-256") == 0) {
            group_name = "P-256";
        } else if (strcmp(curve_name, "P-384") == 0) {
            group_name = "P-384";
        } else if (strcmp(curve_name, "P-521") == 0) {
            group_name = "P-521";
        } else {
            OSSL_PARAM_BLD_free(param_bld);
            return nullptr;
        }

        OSSL_PARAM_BLD_push_utf8_string(param_bld, OSSL_PKEY_PARAM_GROUP_NAME, group_name, 0);

        size_t pub_key_len = 1 + x_len + y_len;
        unsigned char *pub_key_oct = (unsigned char *)malloc(pub_key_len);
        if (!pub_key_oct) {
            OSSL_PARAM_BLD_free(param_bld);
            return nullptr;
        }
        pub_key_oct[0] = 0x04; // uncompressed format
        memcpy(pub_key_oct + 1, x_bytes, x_len);
        memcpy(pub_key_oct + 1 + x_len, y_bytes, y_len);

        OSSL_PARAM_BLD_push_octet_string(param_bld, OSSL_PKEY_PARAM_PUB_KEY, pub_key_oct, pub_key_len);

        OSSL_PARAM *params = OSSL_PARAM_BLD_to_param(param_bld);
        OSSL_PARAM_BLD_free(param_bld);
        free(pub_key_oct);

        if (!params) return nullptr;

        EVP_PKEY_CTX *pkey_ctx = EVP_PKEY_CTX_new_from_name(nullptr, "EC", nullptr);
        EVP_PKEY *pkey = nullptr;
        if (pkey_ctx) {
            if (EVP_PKEY_fromdata_init(pkey_ctx) == 1) {
                EVP_PKEY_fromdata(pkey_ctx, &pkey, EVP_PKEY_PUBLIC_KEY, params);
            }
            EVP_PKEY_CTX_free(pkey_ctx);
        }
        OSSL_PARAM_free(params);

        return (void*)pkey;
    }

    int openssl_pkey_up_ref(void *pkey_ptr)
    {
        if (!pkey_ptr) return 0;
        return EVP_PKEY_up_ref((EVP_PKEY*)pkey_ptr);
    }

    void openssl_pkey_free(void *pkey_ptr)
    {
        if (pkey_ptr) EVP_PKEY_free((EVP_PKEY*)pkey_ptr);
    }

    int openssl_verify_rsa_with_key(
        void *pkey_ptr,
        const char *hash_alg,
        const unsigned char *data, size_t data_len,
        const unsigned char *sig, size_t sig_len)
    {
        if (!pkey_ptr) return 0;
        EVP_PKEY *pkey = (EVP_PKEY*)pkey_ptr;

        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        if (!ctx) return 0;

        const EVP_MD *md = EVP_get_digestbyname(hash_alg);
        if (!md) {
            EVP_MD_CTX_free(ctx);
            return 0;
        }

        int ret = 0;
        if (EVP_DigestVerifyInit(ctx, nullptr, md, nullptr, pkey) == 1) {
            if (EVP_DigestVerifyUpdate(ctx, data, data_len) == 1) {
                ret = EVP_DigestVerifyFinal(ctx, sig, sig_len);
            }
        }

        EVP_MD_CTX_free(ctx);
        return ret == 1 ? 1 : 0;
    }

    int openssl_verify_rsa_pss_with_key(
        void *pkey_ptr,
        const char *hash_alg,
        const unsigned char *data, size_t data_len,
        const unsigned char *sig, size_t sig_len)
    {
        if (!pkey_ptr) return 0;
        EVP_PKEY *pkey = (EVP_PKEY*)pkey_ptr;

        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        if (!ctx) return 0;

        const EVP_MD *md = EVP_get_digestbyname(hash_alg);
        if (!md) {
            EVP_MD_CTX_free(ctx);
            return 0;
        }

        int ret = 0;
        EVP_PKEY_CTX *pctx = nullptr;
        if (EVP_DigestVerifyInit(ctx, &pctx, md, nullptr, pkey) == 1) {
            if (pctx &&
                EVP_PKEY_CTX_set_rsa_padding(pctx, RSA_PKCS1_PSS_PADDING) == 1 &&
                EVP_PKEY_CTX_set_rsa_mgf1_md(pctx, md) == 1 &&
                EVP_PKEY_CTX_set_rsa_pss_saltlen(pctx, RSA_PSS_SALTLEN_DIGEST) == 1) {
                if (EVP_DigestVerifyUpdate(ctx, data, data_len) == 1) {
                    ret = EVP_DigestVerifyFinal(ctx, sig, sig_len);
                }
            }
        }

        EVP_MD_CTX_free(ctx);
        return ret == 1 ? 1 : 0;
    }

    int openssl_verify_ec_with_key(
        void *pkey_ptr,
        const char *curve_name,
        const unsigned char *data, size_t data_len,
        const unsigned char *r_bytes, size_t r_len,
        const unsigned char *s_bytes, size_t s_len)
    {
        if (!pkey_ptr) return 0;
        EVP_PKEY *pkey = (EVP_PKEY*)pkey_ptr;

        BIGNUM *bn_r = BN_bin2bn(r_bytes, r_len, nullptr);
        BIGNUM *bn_s = BN_bin2bn(s_bytes, s_len, nullptr);
        if (!bn_r || !bn_s) {
            if (bn_r) BN_free(bn_r);
            if (bn_s) BN_free(bn_s);
            return 0;
        }

        ECDSA_SIG *ec_sig = ECDSA_SIG_new();
        if (!ec_sig) {
            BN_free(bn_r);
            BN_free(bn_s);
            return 0;
        }
        ECDSA_SIG_set0(ec_sig, bn_r, bn_s);

        unsigned char *der_sig = nullptr;
        int der_sig_len = i2d_ECDSA_SIG(ec_sig, &der_sig);
        ECDSA_SIG_free(ec_sig);

        if (der_sig_len <= 0 || !der_sig) {
            BN_free(bn_r);
            BN_free(bn_s);
            return 0;
        }

        const EVP_MD *md = nullptr;
        if (strcmp(curve_name, "P-256") == 0) {
            md = EVP_sha256();
        } else if (strcmp(curve_name, "P-384") == 0) {
            md = EVP_sha384();
        } else if (strcmp(curve_name, "P-521") == 0) {
            md = EVP_sha512();
        }
        if (!md) {
            OPENSSL_free(der_sig);
            return 0;
        }

        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        if (!ctx) {
            OPENSSL_free(der_sig);
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
        return ret == 1 ? 1 : 0;
    }
}
