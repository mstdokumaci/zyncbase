const std = @import("std");
const Allocator = std.mem.Allocator;
const JwtValidator = @import("jwt_validator.zig").JwtValidator;
const JwtValidationConfig = @import("jwt_validator.zig").JwtValidationConfig;
const c = @import("uwebsockets_wrapper.zig").c;

pub const TicketExchange = struct {
    allocator: Allocator,
    ticket_secret: [32]u8,
    ttl_seconds: u32,
    single_use: bool,
    jwt_validator: ?JwtValidator,
    anonymous_enabled: bool,
    anonymous_prefix: []const u8,
    ssl: bool,

    redeemed_tickets: std.StringHashMap(i64),
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        allocator: Allocator,
        ticket_secret_opt: ?[]const u8,
        ttl_seconds: u32,
        single_use: bool,
        jwt_config: ?JwtValidationConfig,
        anonymous_enabled: bool,
        anonymous_prefix: ?[]const u8,
        ssl: bool,
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

        self.* = .{
            .allocator = allocator,
            .ticket_secret = secret_key,
            .ttl_seconds = ttl_seconds,
            .single_use = single_use,
            .jwt_validator = validator,
            .anonymous_enabled = anonymous_enabled,
            .anonymous_prefix = prefix,
            .ssl = ssl,
            .redeemed_tickets = std.StringHashMap(i64).init(allocator),
            .mutex = .{},
        };

        return self;
    }

    pub fn deinit(self: *TicketExchange) void {
        self.allocator.free(self.anonymous_prefix);
        self.mutex.lock();
        var it = self.redeemed_tickets.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.redeemed_tickets.deinit();
        self.allocator.destroy(self);
    }

    /// Verifies a ticket string. Returns the subject name allocated with `allocator` if valid.
    pub fn verifyTicket(self: *TicketExchange, allocator: Allocator, ticket: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, ticket, "zyc_tk_")) return error.InvalidTicket;
        const raw_ticket = ticket["zyc_tk_".len..];

        var parts_it = std.mem.splitScalar(u8, raw_ticket, '.');
        const payload_b64 = parts_it.next() orelse return error.InvalidTicket;
        const sig_b64 = parts_it.next() orelse return error.InvalidTicket;
        if (parts_it.next() != null) return error.InvalidTicket;

        var computed_sig: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&computed_sig, payload_b64, &self.ticket_secret);

        const sig_bytes = try decodeBase64Url(allocator, sig_b64);
        defer allocator.free(sig_bytes);

        if (sig_bytes.len != 32 or !std.crypto.timing_safe.eql([32]u8, computed_sig, sig_bytes[0..32].*)) {
            return error.AuthFailed;
        }

        const payload_json = try decodeBase64Url(allocator, payload_b64);
        defer allocator.free(payload_json);

        const TicketPayload = struct {
            sub: []const u8,
            exp: i64,
            jti: []const u8,
        };

        const parsed = try std.json.parseFromSlice(TicketPayload, allocator, payload_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const now = std.time.timestamp();
        if (now >= parsed.value.exp) {
            return error.TokenExpired;
        }

        if (self.single_use) {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Collect expired keys first to avoid iterator invalidation
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

            if (self.redeemed_tickets.contains(parsed.value.jti)) {
                return error.AuthFailed;
            }

            const jti_owned = try self.allocator.dupe(u8, parsed.value.jti);
            try self.redeemed_tickets.put(jti_owned, parsed.value.exp);
        }

        return try allocator.dupe(u8, parsed.value.sub);
    }

    /// Generates a signed ticket string.
    pub fn generateTicket(self: *TicketExchange, allocator: Allocator, subject: []const u8, is_anonymous: bool) ![]const u8 {
        const exp = std.time.timestamp() + self.ttl_seconds;
        var jti_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&jti_bytes);
        const jti_hex = std.fmt.bytesToHex(jti_bytes, .lower);

        const payload_json = try std.fmt.allocPrint(allocator,
            \\{{"sub":"{s}","exp":{d},"jti":"{s}","session":{{"externalId":"{s}","isAnonymous":{s}}}}}
        , .{ subject, exp, jti_hex, subject, if (is_anonymous) "true" else "false" });
        defer allocator.free(payload_json);

        const payload_b64 = try encodeBase64Url(allocator, payload_json);
        defer allocator.free(payload_b64);

        var sig_bytes: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&sig_bytes, payload_b64, &self.ticket_secret);
        const sig_b64 = try encodeBase64Url(allocator, &sig_bytes);
        defer allocator.free(sig_b64);

        return try std.fmt.allocPrint(allocator, "zyc_tk_{s}.{s}", .{ payload_b64, sig_b64 });
    }

    pub fn handlePostTicketComplete(self: *TicketExchange, ctx: *RequestContext) !void {
        const allocator = ctx.allocator;

        // SAFETY: subject is always assigned before use in the if/else branches below
        var subject: []const u8 = undefined;
        var is_anonymous = false;

        if (ctx.auth_header) |hdr| {
            if (hdr.len > 7 and std.ascii.eqlIgnoreCase(hdr[0..7], "bearer ")) {
                const token = hdr[7..];
                if (self.jwt_validator) |val| {
                    subject = try val.validate(allocator, token);
                } else {
                    std.log.warn("JWT authentication attempted but JWT validator not configured", .{});
                    return error.AuthFailed;
                }
            } else {
                return error.InvalidMessage;
            }
        } else {
            const parsed_body = try std.json.parseFromSlice(std.json.Value, allocator, ctx.body.items, .{});
            defer parsed_body.deinit();

            if (parsed_body.value == .object) {
                if (parsed_body.value.object.get("anonymousSubject")) |anon_sub_val| {
                    if (anon_sub_val == .string) {
                        const sub = anon_sub_val.string;
                        try self.validateAnonymousSubject(sub);
                        subject = try allocator.dupe(u8, sub);
                        is_anonymous = true;
                    } else {
                        return error.InvalidMessage;
                    }
                } else {
                    return error.InvalidMessage;
                }
            } else {
                return error.InvalidMessage;
            }
        }

        defer allocator.free(subject);

        const exp = std.time.timestamp() + self.ttl_seconds;
        const ticket = try self.generateTicket(allocator, subject, is_anonymous);
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
};

pub const RequestContext = struct {
    allocator: Allocator,
    exchange: *TicketExchange,
    res: *c.uws_res_t,
    ssl: bool,
    body: std.ArrayListUnmanaged(u8),
    auth_header: ?[]const u8,
    aborted: bool,
};

fn decodeBase64Url(allocator: Allocator, input: []const u8) ![]u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == '=') {
        end -= 1;
    }
    const stripped = input[0..end];
    const max_len = std.base64.url_safe_no_pad.Decoder.calcSizeUpperBound(stripped.len) catch return error.InvalidBase64;
    const dest = try allocator.alloc(u8, max_len);
    errdefer allocator.free(dest);
    try std.base64.url_safe_no_pad.Decoder.decode(dest, stripped);
    return dest;
}

fn encodeBase64Url(allocator: Allocator, input: []const u8) ![]u8 {
    const len = std.base64.url_safe_no_pad.Encoder.calcSize(input.len);
    const dest = try allocator.alloc(u8, len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(dest, input);
    return dest;
}

fn onAbortedCallback(user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const ctx: *RequestContext = @ptrCast(@alignCast(user_data.?));
    ctx.aborted = true;
    ctx.body.deinit(ctx.allocator);
    if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
    ctx.allocator.destroy(ctx);
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
        return;
    };

    if (is_last != 0) {
        ctx.exchange.handlePostTicketComplete(ctx) catch |err| {
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
    const auth_header_dup = if (auth_len > 0) allocator.dupe(u8, auth_ptr[0..auth_len]) catch null else null;

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
