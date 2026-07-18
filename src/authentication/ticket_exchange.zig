const std = @import("std");
const Allocator = std.mem.Allocator;
const JwtValidator = @import("jwt_validator.zig").JwtValidator;
const JwtValidationConfig = @import("jwt_validator.zig").JwtValidationConfig;
const Session = @import("session.zig").Session;
const typed = @import("../typed/types.zig");
const typed_codec = @import("../typed/codec.zig");
const c = @import("../uwebsockets_wrapper.zig").c;
const json_read = @import("../json/read.zig");
const json_iterate = @import("../json/iterate.zig");
const json_write = @import("../json/write.zig");
const base64_utils = @import("base64_utils.zig");

pub const TicketExchange = struct {
    allocator: Allocator,
    ticket_secret: [32]u8,
    ttl_seconds: u32,
    single_use: bool,
    jwt_validator: ?JwtValidator,
    anonymous_enabled: bool,
    anonymous_prefix: []const u8,
    ssl: bool,
    claims_mapping: std.StringHashMapUnmanaged([]const u8) = .{},

    /// Requests parked waiting for a JWKS refresh. Each entry is a RequestContext
    /// that was deferred because validateWithClaims returned JwksRefreshInProgress.
    /// Only accessed from the event loop thread (no lock needed).
    pending_requests: std.ArrayListUnmanaged(*RequestContext) = .{},

    redeemed_tickets: std.StringHashMap(i64),
    mutex: std.Thread.Mutex = .{},
    verifications_since_cleanup: u32 = 0,
    cleanup_interval: u32 = 100,

    pub fn init(
        allocator: Allocator,
        ticket_secret_opt: ?[]const u8,
        ttl_seconds: u32,
        single_use: bool,
        jwt_config: ?JwtValidationConfig,
        anonymous_enabled: bool,
        anonymous_prefix: ?[]const u8,
        ssl: bool,
        claims_mapping: std.StringHashMapUnmanaged([]const u8),
    ) !*TicketExchange {
        const self = try allocator.create(TicketExchange);
        errdefer allocator.destroy(self);

        var secret_key: [32]u8 = undefined;
        if (ticket_secret_opt) |secret| {
            if (secret.len >= 32) {
                @memcpy(secret_key[0..32], secret[0..32]);
            } else {
                @memset(&secret_key, 0);
                @memcpy(secret_key[0..secret.len], secret);
            }
        } else {
            std.crypto.random.bytes(&secret_key);
        }

        const validator = if (jwt_config) |cfg| JwtValidator.init(cfg) else null;
        const prefix = if (anonymous_prefix) |p| try allocator.dupe(u8, p) else try allocator.dupe(u8, "anon:");
        errdefer allocator.free(prefix);

        var claims_copy: std.StringHashMapUnmanaged([]const u8) = .{};
        errdefer {
            var it = claims_copy.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            claims_copy.deinit(allocator);
        }
        var mapping_it = claims_mapping.iterator();
        while (mapping_it.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const val = try allocator.dupe(u8, entry.value_ptr.*);
            errdefer allocator.free(val);
            try claims_copy.put(allocator, key, val);
        }

        self.* = .{
            .allocator = allocator,
            .ticket_secret = secret_key,
            .ttl_seconds = ttl_seconds,
            .single_use = single_use,
            .jwt_validator = validator,
            .anonymous_enabled = anonymous_enabled,
            .anonymous_prefix = prefix,
            .ssl = ssl,
            .claims_mapping = claims_copy,
            .redeemed_tickets = std.StringHashMap(i64).init(allocator),
            .mutex = .{},
        };

        return self;
    }

    pub fn deinit(self: *TicketExchange) void {
        // Clean up any parked requests that never got resumed.
        for (self.pending_requests.items) |ctx| {
            ctx.body.deinit(ctx.allocator);
            if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
            ctx.allocator.destroy(ctx);
        }
        self.pending_requests.deinit(self.allocator);

        self.allocator.free(self.anonymous_prefix);
        {
            var it = self.claims_mapping.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.claims_mapping.deinit(self.allocator);
        }
        var it = self.redeemed_tickets.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.redeemed_tickets.deinit();
        self.allocator.destroy(self);
    }

    /// Verifies a ticket string. Returns the subject name allocated with `allocator` if valid.
    pub fn verifyTicket(self: *TicketExchange, allocator: Allocator, ticket: []const u8) !Session {
        const parts = try parseTicketParts(ticket);

        try verifyTicketHmac(self.ticket_secret[0..], parts.payload_b64, parts.sig_b64);

        const payload_json = try base64_utils.urlDecodeAlloc(allocator, parts.payload_b64);
        defer allocator.free(payload_json);

        const extracted = extractTicketPayloadFast(payload_json) orelse return error.InvalidTicket;

        const now = std.time.timestamp();
        if (now >= extracted.exp) {
            return error.TokenExpired;
        }

        try self.redeemIfSingleUse(extracted.jti, extracted.exp, now);

        const external_id_slice = extracted.external_id orelse extracted.sub;
        const external_id = try allocator.dupe(u8, external_id_slice);

        var claims: std.StringHashMapUnmanaged(typed.Value) = .{};
        errdefer {
            allocator.free(external_id);
            var it = claims.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            claims.deinit(allocator);
        }

        if (extracted.claims_json) |claims_json| {
            claims = try extractClaims(allocator, claims_json);
        }

        return Session{
            .external_id = external_id,
            .is_anonymous = extracted.is_anonymous,
            .token_expires_at = extracted.exp,
            .claims = claims,
        };
    }

    fn redeemIfSingleUse(self: *TicketExchange, jti: []const u8, exp: i64, now: i64) !void {
        if (!self.single_use) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.verifications_since_cleanup += 1;
        if (self.verifications_since_cleanup >= self.cleanup_interval) {
            self.cleanupExpiredTicketsLocked(now);
            self.verifications_since_cleanup = 0;
        }

        if (self.redeemed_tickets.contains(jti)) {
            return error.AuthFailed;
        }

        const jti_owned = try self.allocator.dupe(u8, jti);
        var jti_owned_transferred = false;
        errdefer if (!jti_owned_transferred) self.allocator.free(jti_owned);
        try self.redeemed_tickets.put(jti_owned, exp);
        jti_owned_transferred = true;
    }

    /// Generates a signed ticket string.
    pub fn generateTicket(
        self: *TicketExchange,
        allocator: Allocator,
        subject: []const u8,
        is_anonymous: bool,
        claims: *const std.StringHashMapUnmanaged(typed.Value),
    ) ![]const u8 {
        const exp = std.time.timestamp() + self.ttl_seconds;
        var jti_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&jti_bytes);
        const jti_hex = std.fmt.bytesToHex(jti_bytes, .lower);

        var payload_buf = std.ArrayListUnmanaged(u8).empty;
        defer payload_buf.deinit(allocator);
        var value_json_buf = std.ArrayListUnmanaged(u8).empty;
        defer value_json_buf.deinit(allocator);
        var w = json_write.Writer{ .buf = &payload_buf, .allocator = allocator };

        try w.beginObject();
        try w.field("sub", subject);
        try w.intField("exp", exp);
        try w.field("jti", &jti_hex);
        try w.beginObjectField("session");
        try w.field("externalId", subject);
        try w.boolField("isAnonymous", is_anonymous);
        try w.beginObjectField("claims");
        var claims_it = claims.iterator();
        while (claims_it.next()) |entry| {
            value_json_buf.clearRetainingCapacity();
            try typed_codec.writeJsonToBuf(&value_json_buf, allocator, entry.value_ptr.*);
            try w.rawField(entry.key_ptr.*, value_json_buf.items);
        }
        try w.endObject();
        try w.endObject();
        try w.endObject();

        const payload_b64 = try base64_utils.urlEncodeAlloc(allocator, payload_buf.items);
        defer allocator.free(payload_b64);

        var sig_bytes: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&sig_bytes, payload_b64, &self.ticket_secret);

        var sig_b64_buf: [48]u8 = undefined;
        const sig_b64_len = std.base64.url_safe_no_pad.Encoder.calcSize(32);
        const sig_b64 = sig_b64_buf[0..sig_b64_len];
        _ = std.base64.url_safe_no_pad.Encoder.encode(sig_b64, &sig_bytes);

        return try std.fmt.allocPrint(allocator, "zyc_tk_{s}.{s}", .{ payload_b64, sig_b64 });
    }

    pub fn handlePostTicketComplete(self: *TicketExchange, ctx: *RequestContext) !void {
        const allocator = ctx.allocator;

        // SAFETY: subject is always assigned before use in the if/else branches below
        var subject: []const u8 = undefined;
        var is_anonymous = false;
        var claims: std.StringHashMapUnmanaged(typed.Value) = .{};
        defer {
            var it = claims.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            claims.deinit(allocator);
        }

        if (ctx.auth_header) |hdr| {
            if (hdr.len > 7 and std.ascii.eqlIgnoreCase(hdr[0..7], "bearer ")) {
                const token = hdr[7..];
                if (self.jwt_validator) |val| {
                    const validated = val.validateWithClaims(allocator, token, self.claims_mapping) catch |err| {
                        if (err == error.JwksRefreshInProgress) {
                            // Park this request — a JWKS refresh is in progress.
                            // The caller (onDataCallback) must NOT destroy ctx.
                            return error.JwksRefreshInProgress;
                        }
                        return err;
                    };
                    subject = validated.subject;
                    claims = validated.claims;
                } else {
                    std.log.warn("JWT authentication attempted but JWT validator not configured", .{});
                    return error.AuthFailed;
                }
            } else {
                return error.InvalidMessage;
            }
        } else {
            const body = ctx.body.items;
            const anon_sub = extractAnonymousSubject(body) orelse return error.InvalidMessage;
            try self.validateAnonymousSubject(anon_sub);
            subject = try allocator.dupe(u8, anon_sub);
            is_anonymous = true;
        }

        defer allocator.free(subject);

        const exp = std.time.timestamp() + self.ttl_seconds;
        const ticket = try self.generateTicket(allocator, subject, is_anonymous, &claims);
        defer allocator.free(ticket);

        const response_body = try std.fmt.allocPrint(allocator,
            \\{{"ticket":"{s}","expiresAt":{d}}}
        , .{ ticket, exp });
        defer allocator.free(response_body);

        if (!ctx.aborted) {
            const ssl_val: c_int = if (ctx.ssl) 1 else 0;
            c.uws_res_write_status(ssl_val, ctx.res, "200 OK", "200 OK".len);
            c.uws_res_write_header(ssl_val, ctx.res, "Content-Type", "Content-Type".len, "application/json", "application/json".len);
            c.uws_res_end(ssl_val, ctx.res, response_body.ptr, response_body.len, 0);
        }
    }

    pub fn validateAnonymousSubject(self: *TicketExchange, subject: []const u8) !void {
        if (!self.anonymous_enabled) return error.AnonymousDisabled;
        if (!std.mem.startsWith(u8, subject, self.anonymous_prefix)) return error.InvalidAnonymousSubject;
        const hex = subject[self.anonymous_prefix.len..];
        if (hex.len < 32) return error.InvalidAnonymousSubject;
        for (hex) |char| {
            switch (char) {
                '0'...'9', 'a'...'f', 'A'...'F' => {},
                else => return error.InvalidAnonymousSubject,
            }
        }
    }

    /// Called from the event loop (via Loop::defer) after a JWKS refresh
    /// completes. Retries all parked ticket requests.
    /// Also called from notifyPostHandler to check for parking timeouts.
    pub fn retryPendingRequests(self: *TicketExchange) void {
        if (self.pending_requests.items.len == 0) return;

        var i: usize = 0;
        while (i < self.pending_requests.items.len) {
            const ctx = self.pending_requests.items[i];

            // Skip aborted requests — clean them up.
            if (ctx.aborted) {
                _ = self.pending_requests.swapRemove(i);
                ctx.body.deinit(ctx.allocator);
                if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
                ctx.allocator.destroy(ctx);
                continue;
            }

            // Retry the validation.
            self.handlePostTicketComplete(ctx) catch |err| {
                if (err == error.JwksRefreshInProgress) {
                    // Still refreshing — keep parked. Update timestamp.
                    // (refreshing flag may have auto-reset, but a new thread
                    // was spawned by getJwk inside handlePostTicketComplete.)
                    ctx.parked_at = std.time.timestamp();
                    i += 1;
                    continue;
                }

                // Validation failed — send error response and clean up.
                _ = self.pending_requests.swapRemove(i);
                if (!ctx.aborted) {
                    const ssl_val: c_int = if (ctx.ssl) 1 else 0;
                    const status = if (err == error.InvalidMessage or err == error.InvalidAnonymousSubject)
                        "400 Bad Request"
                    else
                        "401 Unauthorized";
                    const code = if (err == error.InvalidMessage or err == error.InvalidAnonymousSubject)
                        "INVALID_MESSAGE"
                    else
                        "AUTH_FAILED";
                    c.uws_res_write_status(ssl_val, ctx.res, status.ptr, status.len);
                    c.uws_res_write_header(ssl_val, ctx.res, "Content-Type", "Content-Type".len, "application/json", "application/json".len);
                    var resp_buf: [256]u8 = undefined;
                    const resp = std.fmt.bufPrint(&resp_buf, "{{\"code\":\"{s}\"}}", .{code}) catch "{\"code\":\"AUTH_FAILED\"}"; // zwanzig-disable-line: swallowed-error
                    c.uws_res_end(ssl_val, ctx.res, resp.ptr, resp.len, 0);
                }
                ctx.body.deinit(ctx.allocator);
                if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
                ctx.allocator.destroy(ctx);
                continue;
            };

            // Success — handlePostTicketComplete already sent the response.
            // We are the caller here (not onDataCallback), so we own the ctx
            // and must free it. (handlePostTicketComplete does not free ctx.)
            _ = self.pending_requests.swapRemove(i);
            ctx.body.deinit(ctx.allocator);
            if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
            ctx.allocator.destroy(ctx);
        }
    }

    /// Called from notifyPostHandler on every loop iteration.
    /// Fails parked requests that have waited longer than 10 seconds.
    pub fn checkParkedTimeouts(self: *TicketExchange) void {
        if (self.pending_requests.items.len == 0) return;

        const now = std.time.timestamp();
        const timeout_seconds: i64 = 10;

        var i: usize = 0;
        while (i < self.pending_requests.items.len) {
            const ctx = self.pending_requests.items[i];
            if (ctx.aborted) {
                _ = self.pending_requests.swapRemove(i);
                ctx.body.deinit(ctx.allocator);
                if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
                ctx.allocator.destroy(ctx);
                continue;
            }
            if (now - ctx.parked_at > timeout_seconds) {
                // Timed out — send AUTH_FAILED and clean up.
                _ = self.pending_requests.swapRemove(i);
                if (!ctx.aborted) {
                    const ssl_val: c_int = if (ctx.ssl) 1 else 0;
                    c.uws_res_write_status(ssl_val, ctx.res, "401 Unauthorized", "401 Unauthorized".len);
                    c.uws_res_write_header(ssl_val, ctx.res, "Content-Type", "Content-Type".len, "application/json", "application/json".len);
                    c.uws_res_end(ssl_val, ctx.res, "{\"code\":\"AUTH_FAILED\",\"message\":\"JWKS refresh timeout\"}", 52, 0);
                }
                ctx.body.deinit(ctx.allocator);
                if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
                ctx.allocator.destroy(ctx);
                continue;
            }
            i += 1;
        }
    }

    fn cleanupExpiredTicketsLocked(self: *TicketExchange, now: i64) void {
        var expired_keys = std.ArrayListUnmanaged([]const u8).empty;
        defer expired_keys.deinit(self.allocator);
        var cleanup_it = self.redeemed_tickets.iterator();
        while (cleanup_it.next()) |entry| {
            if (now >= entry.value_ptr.*) {
                expired_keys.append(self.allocator, entry.key_ptr.*) catch |err| {
                    std.log.warn("Failed to collect expired ticket key: {}", .{err});
                };
            }
        }
        for (expired_keys.items) |key| {
            _ = self.redeemed_tickets.remove(key);
            self.allocator.free(key);
        }
    }
};

pub const RequestContext = struct {
    allocator: Allocator,
    exchange: *TicketExchange,
    res: *c.uws_res_t,
    ssl: bool,
    body: std.ArrayListUnmanaged(u8),
    auth_header: ?[]const u8,
    aborted: bool,
    parked_at: i64 = 0, // timestamp when parked for timeout checking
};

fn onAbortedCallback(user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const ctx: *RequestContext = @ptrCast(@alignCast(user_data.?));
    ctx.aborted = true;
    // Do NOT deinit/destroy here — the context may be in pending_requests.
    // The retry/timeout sweep will clean it up when it sees aborted == true.
    // If the context was already successfully handled (response sent),
    // uWebSockets may call onAborted for the same response object. In that case
    // the context has already been destroyed by the success path. This is a
    // uWebSockets quirk — the existing code has the same risk. We preserve the
    // existing behavior: mark aborted, let the cleanup happen elsewhere.
}

fn onDataCallback(res: ?*c.uws_res_t, chunk: [*c]const u8, chunk_len: usize, is_last: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = res;
    if (user_data == null) return;
    const ctx: *RequestContext = @ptrCast(@alignCast(user_data.?));
    if (ctx.aborted) return;

    ctx.body.appendSlice(ctx.allocator, chunk[0..chunk_len]) catch {
        const ssl_val: c_int = if (ctx.ssl) 1 else 0;
        c.uws_res_write_status(ssl_val, ctx.res, "500 Internal Server Error", "500 Internal Server Error".len);
        c.uws_res_end(ssl_val, ctx.res, "Internal Server Error", "Internal Server Error".len, 0);
        ctx.body.deinit(ctx.allocator);
        if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
        ctx.allocator.destroy(ctx);
        return;
    };

    if (is_last != 0) {
        ctx.exchange.handlePostTicketComplete(ctx) catch |err| {
            if (err == error.JwksRefreshInProgress) {
                // Park the request — do NOT send a response or destroy ctx.
                // The retry callback (triggered by Loop::defer after the
                // JWKS refresh completes) will call handlePostTicketComplete
                // again.
                ctx.parked_at = std.time.timestamp();
                ctx.exchange.pending_requests.append(ctx.allocator, ctx) catch {
                    // If we can't park (OOM), fail the request.
                    std.log.err("Failed to park ticket request: out of memory", .{});
                    if (!ctx.aborted) {
                        const ssl_val: c_int = if (ctx.ssl) 1 else 0;
                        c.uws_res_write_status(ssl_val, ctx.res, "500 Internal Server Error", "500 Internal Server Error".len);
                        c.uws_res_end(ssl_val, ctx.res, "Internal Server Error", "Internal Server Error".len, 0);
                    }
                    ctx.body.deinit(ctx.allocator);
                    if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
                    ctx.allocator.destroy(ctx);
                };
                return; // Do NOT deinit/destroy ctx — it's parked.
            }

            std.log.warn("Error handling ticket POST: {}", .{err});
            if (!ctx.aborted) {
                const ssl_val: c_int = if (ctx.ssl) 1 else 0;
                const status = if (err == error.InvalidMessage or err == error.InvalidAnonymousSubject)
                    "400 Bad Request"
                else
                    "401 Unauthorized";
                const code = if (err == error.InvalidMessage or err == error.InvalidAnonymousSubject)
                    "INVALID_MESSAGE"
                else
                    "AUTH_FAILED";
                const message = if (err == error.AnonymousDisabled)
                    "Anonymous authentication is disabled"
                else if (err == error.InvalidAnonymousSubject)
                    "Anonymous subject formatted incorrectly"
                else
                    "Identity verification failed";

                c.uws_res_write_status(ssl_val, ctx.res, status.ptr, status.len);
                c.uws_res_write_header(ssl_val, ctx.res, "Content-Type", "Content-Type".len, "application/json", "application/json".len);

                var resp_buf: [256]u8 = undefined;
                const resp = std.fmt.bufPrint(&resp_buf, "{{\"code\":\"{s}\",\"message\":\"{s}\"}}", .{ code, message }) catch |fmt_err| blk: {
                    std.log.warn("Failed to format error response: {}", .{fmt_err});
                    break :blk "{\"code\":\"AUTH_FAILED\"}";
                };
                c.uws_res_end(ssl_val, ctx.res, resp.ptr, resp.len, 0);
            }
        };

        ctx.body.deinit(ctx.allocator);
        if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
        ctx.allocator.destroy(ctx);
    }
}

pub fn handleAuthTicket(res: ?*c.uws_res_t, req: ?*c.uws_req_t, user_data: ?*anyopaque) callconv(.c) void {
    const res_nn = res orelse return;
    const req_nn = req orelse return;
    const ud = user_data orelse return;
    const exchange: *TicketExchange = @ptrCast(@alignCast(ud));
    const allocator = exchange.allocator;
    const ssl_val: c_int = if (exchange.ssl) 1 else 0;

    // SAFETY: auth_ptr is written by uws_req_get_header before auth_len is checked
    var auth_ptr: [*c]const u8 = undefined;
    const auth_len = c.uws_req_get_header(@ptrCast(req_nn), "authorization", "authorization".len, &auth_ptr);
    var auth_header_dup: ?[]const u8 = null;
    if (auth_len > 0) {
        auth_header_dup = allocator.dupe(u8, auth_ptr[0..auth_len]) catch {
            c.uws_res_write_status(ssl_val, res_nn, "500 Internal Server Error", "500 Internal Server Error".len);
            c.uws_res_end(ssl_val, res_nn, "Internal Server Error", "Internal Server Error".len, 0);
            return;
        };
    }

    const ctx = allocator.create(RequestContext) catch {
        if (auth_header_dup) |hdr| allocator.free(hdr);
        c.uws_res_write_status(ssl_val, res_nn, "500 Internal Server Error", "500 Internal Server Error".len);
        c.uws_res_end(ssl_val, res_nn, "Internal Server Error", "Internal Server Error".len, 0);
        return;
    };

    ctx.* = .{
        .allocator = allocator,
        .exchange = exchange,
        .res = res_nn,
        .ssl = exchange.ssl,
        .body = std.ArrayListUnmanaged(u8).empty,
        .auth_header = auth_header_dup,
        .aborted = false,
    };

    c.uws_res_on_aborted(ssl_val, res_nn, onAbortedCallback, ctx);
    c.uws_res_on_data(ssl_val, res_nn, onDataCallback, ctx);
}

fn extractAnonymousSubject(json_body: []const u8) ?[]const u8 {
    const AnonCtx = struct {
        subject: ?[]const u8 = null,
    };
    const S = struct {
        fn anonHandler(ctx: *AnonCtx, key: []const u8, value: []const u8) void {
            if (std.mem.eql(u8, key, "anonymousSubject")) {
                var pos: usize = 0;
                ctx.subject = json_read.extractJsonString(value, &pos);
            }
        }
    };
    var ctx = AnonCtx{};
    json_iterate.forEachJsonFieldExtract(json_body, AnonCtx, &ctx, S.anonHandler);
    return ctx.subject;
}

const TicketPayload = struct {
    sub: []const u8,
    exp: i64,
    jti: []const u8,
    external_id: ?[]const u8,
    is_anonymous: bool,
    claims_json: ?[]const u8,
};

fn extractTicketPayloadFast(json: []const u8) ?TicketPayload {
    const Ctx = struct {
        result: TicketPayload = .{
            .sub = "",
            .exp = 0,
            .jti = "",
            .external_id = null,
            .is_anonymous = false,
            .claims_json = null,
        },
        found_sub: bool = false,
        found_exp: bool = false,
        found_jti: bool = false,
    };
    const S = struct {
        fn handler(ctx: *Ctx, key: []const u8, value: []const u8) void {
            if (std.mem.eql(u8, key, "sub")) {
                var pos: usize = 0;
                ctx.result.sub = json_read.extractJsonString(value, &pos) orelse return;
                ctx.found_sub = true;
            } else if (std.mem.eql(u8, key, "exp")) {
                var pos: usize = 0;
                ctx.result.exp = json_read.extractJsonInt(value, &pos) orelse return;
                ctx.found_exp = true;
            } else if (std.mem.eql(u8, key, "jti")) {
                var pos: usize = 0;
                ctx.result.jti = json_read.extractJsonString(value, &pos) orelse return;
                ctx.found_jti = true;
            } else if (std.mem.eql(u8, key, "session")) {
                extractSessionFields(value, &ctx.result);
            }
        }
    };
    var ctx = Ctx{};
    json_iterate.forEachJsonFieldExtract(json, Ctx, &ctx, S.handler);
    if (!ctx.found_sub or !ctx.found_exp or !ctx.found_jti) return null;
    return ctx.result;
}

fn extractSessionFields(session_json: []const u8, result: *TicketPayload) void {
    const S = struct {
        fn handler(ctx: *TicketPayload, key: []const u8, value: []const u8) void {
            if (std.mem.eql(u8, key, "externalId")) {
                var pos: usize = 0;
                ctx.external_id = json_read.extractJsonString(value, &pos);
            } else if (std.mem.eql(u8, key, "isAnonymous")) {
                ctx.is_anonymous = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "claims")) {
                if (value.len > 2 and value[0] == '{' and value[1] != '}') {
                    ctx.claims_json = value;
                }
            }
        }
    };
    json_iterate.forEachJsonFieldExtract(session_json, TicketPayload, result, S.handler);
}

const TicketParts = struct { payload_b64: []const u8, sig_b64: []const u8 };

fn parseTicketParts(ticket: []const u8) !TicketParts {
    if (!std.mem.startsWith(u8, ticket, "zyc_tk_")) return error.InvalidTicket;
    const raw_ticket = ticket["zyc_tk_".len..];

    var parts_it = std.mem.splitScalar(u8, raw_ticket, '.');
    const payload_b64 = parts_it.next() orelse return error.InvalidTicket;
    const sig_b64 = parts_it.next() orelse return error.InvalidTicket;
    if (parts_it.next() != null) return error.InvalidTicket;

    return .{ .payload_b64 = payload_b64, .sig_b64 = sig_b64 };
}

fn verifyTicketHmac(ticket_secret: []const u8, payload_b64: []const u8, sig_b64: []const u8) !void {
    var computed_sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&computed_sig, payload_b64, ticket_secret);

    var sig_bytes_stack: [48]u8 = undefined;
    const sig_stripped = base64_utils.stripBase64Padding(sig_b64);
    const sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(sig_stripped) catch return error.InvalidBase64;
    if (sig_len != 32) return error.InvalidBase64;
    const sig_bytes = sig_bytes_stack[0..sig_len];
    std.base64.url_safe_no_pad.Decoder.decode(sig_bytes, sig_stripped) catch return error.InvalidBase64;

    if (!std.crypto.timing_safe.eql([32]u8, computed_sig, sig_bytes_stack[0..32].*)) {
        return error.AuthFailed;
    }
}

fn extractClaims(allocator: Allocator, claims_json: []const u8) !std.StringHashMapUnmanaged(typed.Value) {
    var claims: std.StringHashMapUnmanaged(typed.Value) = .{};
    errdefer {
        var it = claims.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        claims.deinit(allocator);
    }

    const parsed_claims = std.json.parseFromSlice(std.json.Value, allocator, claims_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidTicket,
    };
    defer parsed_claims.deinit();

    if (parsed_claims.value == .object) {
        var claims_it = parsed_claims.value.object.iterator();
        while (claims_it.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const val = try typed_codec.fromDynamicJson(allocator, entry.value_ptr.*);
            errdefer val.deinit(allocator);

            const gop = try claims.getOrPut(allocator, key);
            if (gop.found_existing) {
                allocator.free(key);
                gop.value_ptr.deinit(allocator);
            }
            gop.value_ptr.* = val;
        }
    }

    return claims;
}
