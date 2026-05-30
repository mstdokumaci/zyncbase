#include "uws_bridge.h"
#include "libusockets.h"
#include "App.h"
#include "AsyncSocket.h"
#include "internal/internal.h"
#include <string_view>

#define uws_res_r uws_res_t*

static inline std::string_view stringViewFromC(const char* message, size_t length) {
    if (length) {
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
            return (uws_app_t *)new uWS::SSLApp(socket_context_options);
        }
        return (uws_app_t *)new uWS::App();
    }

    void uws_app_get(int ssl, uws_app_t *app, const char *pattern_ptr,
                     size_t pattern_len, uws_method_handler handler,
                     void *user_data)
    {
        std::string pattern(pattern_ptr, pattern_len);
        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            if (handler == nullptr) {
                uwsApp->get(pattern, nullptr);
                return;
            }
            uwsApp->get(pattern,
                        [handler, user_data](auto *res, auto *req) {
                            handler((uws_res_t *)res, (uws_req_t *)req,
                                    user_data);
                        });
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            if (handler == nullptr) {
                uwsApp->get(pattern, nullptr);
                return;
            }
            uwsApp->get(pattern,
                        [handler, user_data](auto *res, auto *req) {
                            handler((uws_res_t *)res, (uws_req_t *)req,
                                    user_data);
                        });
        }
    }

    void uws_app_post(int ssl, uws_app_t *app, const char *pattern_ptr,
                      size_t pattern_len, uws_method_handler handler,
                      void *user_data)
    {
        std::string pattern(pattern_ptr, pattern_len);
        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            if (handler == nullptr) {
                uwsApp->post(pattern, nullptr);
                return;
            }
            uwsApp->post(pattern,
                         [handler, user_data](auto *res, auto *req) {
                             handler((uws_res_t *)res, (uws_req_t *)req,
                                     user_data);
                         });
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            if (handler == nullptr) {
                uwsApp->post(pattern, nullptr);
                return;
            }
            uwsApp->post(pattern,
                         [handler, user_data](auto *res, auto *req) {
                             handler((uws_res_t *)res, (uws_req_t *)req,
                                     user_data);
                         });
        }
    }

    void uws_app_options(int ssl, uws_app_t *app, const char *pattern_ptr,
                         size_t pattern_len, uws_method_handler handler,
                         void *user_data)
    {
        std::string pattern(pattern_ptr, pattern_len);
        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            if (handler == nullptr) {
                uwsApp->options(pattern, nullptr);
                return;
            }
            uwsApp->options(
                pattern, [handler, user_data](auto *res, auto *req) {
                    handler((uws_res_t *)res, (uws_req_t *)req, user_data);
                });
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            if (handler == nullptr) {
                uwsApp->options(pattern, nullptr);
                return;
            }
            uwsApp->options(
                pattern, [handler, user_data](auto *res, auto *req) {
                    handler((uws_res_t *)res, (uws_req_t *)req, user_data);
                });
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

    void uws_app_listen(int ssl, uws_app_t *app, int port,
                        uws_listen_handler handler, void *user_data)
    {
        if (ssl) {
            uWS::SSLApp *uwsApp = (uWS::SSLApp *)app;
            uwsApp->listen(
                port, [handler, user_data](struct us_listen_socket_t *listen_socket) {
                    handler((struct us_listen_socket_t *)listen_socket,
                            user_data);
                });
        } else {
            uWS::App *uwsApp = (uWS::App *)app;
            uwsApp->listen(
                port, [handler, user_data](struct us_listen_socket_t *listen_socket) {
                    handler((struct us_listen_socket_t *)listen_socket,
                            user_data);
                });
        }
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
            uwsApp->ws<void *>(std::string(pattern, pattern_length),
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
            uwsApp->ws<void *>(std::string(pattern, pattern_length),
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

    void uws_res_end(int ssl, uws_res_r res, const char *data, size_t length,
                     bool close_connection)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            uwsRes->end(stringViewFromC(data, length), close_connection);
        } else {
            uWS::HttpResponse<false> *uwsRes = (uWS::HttpResponse<false> *)res;
            uwsRes->end(stringViewFromC(data, length), close_connection);
        }
    }

    void uws_res_on_aborted(int ssl, uws_res_r res,
                            void (*handler)(uws_res_r res,
                                            void *optional_data),
                            void *optional_data)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            if (handler) {
                uwsRes->onAborted([handler, res, optional_data]() {
                    handler(res, optional_data);
                });
            } else {
                uwsRes->onAborted(nullptr);
            }
        } else {
            uWS::HttpResponse<false> *uwsRes =
                (uWS::HttpResponse<false> *)res;
            if (handler) {
                uwsRes->onAborted([handler, res, optional_data]() {
                    handler(res, optional_data);
                });
            } else {
                uwsRes->onAborted(nullptr);
            }
        }
    }

    void uws_res_on_data(int ssl, uws_res_r res,
                         void (*handler)(uws_res_r res, const char *chunk,
                                         size_t chunk_length, bool is_end,
                                         void *optional_data),
                         void *optional_data)
    {
        if (ssl) {
            uWS::HttpResponse<true> *uwsRes = (uWS::HttpResponse<true> *)res;
            if (handler) {
                uwsRes->onData(
                    [handler, res, optional_data](
                        std::string_view chunk, bool is_end) {
                        handler(res, chunk.data(), chunk.size(), is_end,
                                optional_data);
                    });
            } else {
                uwsRes->onData(nullptr);
            }
        } else {
            uWS::HttpResponse<false> *uwsRes =
                (uWS::HttpResponse<false> *)res;
            if (handler) {
                uwsRes->onData(
                    [handler, res, optional_data](
                        std::string_view chunk, bool is_end) {
                        handler(res, chunk.data(), chunk.size(), is_end,
                                optional_data);
                    });
            } else {
                uwsRes->onData(nullptr);
            }
        }
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
}
