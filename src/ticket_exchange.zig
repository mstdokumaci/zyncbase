const std = @import("std");
const Allocator = std.mem.Allocator;
const JwtValidator = @import("jwt_validator.zig").JwtValidator;
const JwtValidationConfig = @import("jwt_validator.zig").JwtValidationConfig;
const Session = @import("session.zig").Session;
const typed = @import("typed.zig");
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
    claims_mapping: std.StringHashMapUnmanaged([]const u8) = .{},

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
        if (!std.mem.startsWith(u8, ticket, "zyc_tk_")) return error.InvalidTicket;
        const raw_ticket = ticket["zyc_tk_".len..];

        var parts_it = std.mem.splitScalar(u8, raw_ticket, '.');
        const payload_b64 = parts_it.next() orelse return error.InvalidTicket;
        const sig_b64 = parts_it.next() orelse return error.InvalidTicket;
        if (parts_it.next() != null) return error.InvalidTicket;

        var computed_sig: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&computed_sig, payload_b64, &self.ticket_secret);

        var sig_bytes_stack: [48]u8 = undefined;
        const sig_stripped = stripBase64Padding(sig_b64);
        const sig_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(sig_stripped) catch return error.InvalidBase64;
        if (sig_len != 32) return error.InvalidBase64;
        const sig_bytes = sig_bytes_stack[0..sig_len];
        std.base64.url_safe_no_pad.Decoder.decode(sig_bytes, sig_stripped) catch return error.InvalidBase64;

        if (!std.crypto.timing_safe.eql([32]u8, computed_sig, sig_bytes_stack[0..32].*)) {
            return error.AuthFailed;
        }

        const payload_json = try decodeBase64Url(allocator, payload_b64);
        defer allocator.free(payload_json);

        const extracted = extractTicketPayloadFast(payload_json) orelse return error.InvalidTicket;

        const now = std.time.timestamp();
        if (now >= extracted.exp) {
            return error.TokenExpired;
        }

        if (self.single_use) {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.verifications_since_cleanup += 1;
            if (self.verifications_since_cleanup >= self.cleanup_interval) {
                self.cleanupExpiredTicketsLocked(now);
                self.verifications_since_cleanup = 0;
            }

            if (self.redeemed_tickets.contains(extracted.jti)) {
                return error.AuthFailed;
            }

            const jti_owned = try self.allocator.dupe(u8, extracted.jti);
            var jti_owned_transferred = false;
            errdefer if (!jti_owned_transferred) self.allocator.free(jti_owned);
            try self.redeemed_tickets.put(jti_owned, extracted.exp);
            jti_owned_transferred = true;
        }

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
            const parsed_claims = std.json.parseFromSlice(std.json.Value, allocator, claims_json, .{}) catch return error.InvalidTicket;
            defer parsed_claims.deinit();

            if (parsed_claims.value == .object) {
                var claims_it = parsed_claims.value.object.iterator();
                while (claims_it.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key);
                    const val = try typed.valueFromDynamicJson(allocator, entry.value_ptr.*);
                    errdefer val.deinit(allocator);
                    try claims.put(allocator, key, val);
                }
            }
        }

        return Session{
            .external_id = external_id,
            .is_anonymous = extracted.is_anonymous,
            .claims = claims,
        };
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
        const writer = payload_buf.writer(allocator);

        try writer.print(
            \\{{"sub":"{s}","exp":{d},"jti":"{s}","session":{{"externalId":"{s}","isAnonymous":{s},"claims":
        ,
            .{ subject, exp, jti_hex, subject, if (is_anonymous) "true" else "false" },
        );

        if (claims.count() == 0) {
            try writer.writeAll("{}");
        } else {
            try writer.writeByte('{');
            var first = true;
            var claims_it = claims.iterator();
            while (claims_it.next()) |entry| {
                if (!first) try writer.writeByte(',');
                first = false;
                const key_json = try std.json.Stringify.valueAlloc(allocator, entry.key_ptr.*, .{});
                defer allocator.free(key_json);
                try writer.writeAll(key_json);
                try writer.writeByte(':');
                const value_json = try typed.jsonAlloc(allocator, entry.value_ptr.*);
                defer allocator.free(value_json);
                try writer.writeAll(value_json);
            }
            try writer.writeByte('}');
        }

        try writer.writeAll("}}");

        const payload_b64 = try encodeBase64Url(allocator, payload_buf.items);
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
                    const validated = try val.validateWithClaims(allocator, token, self.claims_mapping);
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
};

fn decodeBase64Url(allocator: Allocator, input: []const u8) ![]u8 {
    const stripped = stripBase64Padding(input);
    const exact_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(stripped) catch return error.InvalidBase64;
    const dest = try allocator.alloc(u8, exact_len);
    errdefer allocator.free(dest);
    try std.base64.url_safe_no_pad.Decoder.decode(dest, stripped);
    return dest;
}

fn stripBase64Padding(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == '=') {
        end -= 1;
    }
    return input[0..end];
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
        ctx.body.deinit(ctx.allocator);
        if (ctx.auth_header) |hdr| ctx.allocator.free(hdr);
        ctx.allocator.destroy(ctx);
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
    const key = "\"anonymousSubject\"";
    const key_pos = std.mem.indexOf(u8, json_body, key) orelse return null;
    const after_key = json_body[key_pos + key.len ..];

    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) {
        i += 1;
    }
    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1;

    const value_start = i;
    while (i < after_key.len and after_key[i] != '"') {
        if (after_key[i] == '\\') i += 1;
        i += 1;
    }
    if (i >= after_key.len) return null;

    return after_key[value_start..i];
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
    // SAFETY: sub, exp, jti are undefined initially but guaranteed to be set before return
    // because we check found_sub, found_exp, found_jti and return null if any is false.
    var result: TicketPayload = .{
        .sub = undefined,
        .exp = undefined,
        .jti = undefined,
        .external_id = null,
        .is_anonymous = false,
        .claims_json = null,
    };

    var found_sub = false;
    var found_exp = false;
    var found_jti = false;

    var pos: usize = 0;
    if (pos >= json.len or json[pos] != '{') return null;
    pos += 1;

    while (pos < json.len) {
        skipWhitespace(json, &pos);
        if (pos >= json.len) return null;
        if (json[pos] == '}') break;
        if (json[pos] == ',') {
            pos += 1;
            continue;
        }

        const key = extractJsonKey(json, &pos) orelse return null;
        skipWhitespace(json, &pos);
        if (pos >= json.len or json[pos] != ':') return null;
        pos += 1;
        skipWhitespace(json, &pos);

        if (std.mem.eql(u8, key, "sub")) {
            result.sub = extractJsonString(json, &pos) orelse return null;
            found_sub = true;
        } else if (std.mem.eql(u8, key, "exp")) {
            result.exp = extractJsonInt(json, &pos) orelse return null;
            found_exp = true;
        } else if (std.mem.eql(u8, key, "jti")) {
            result.jti = extractJsonString(json, &pos) orelse return null;
            found_jti = true;
        } else if (std.mem.eql(u8, key, "session")) {
            const session_start = pos;
            skipJsonValue(json, &pos) orelse return null;
            const session_json = json[session_start..pos];
            extractSessionFields(session_json, &result);
        } else {
            skipJsonValue(json, &pos) orelse return null;
        }
    }

    if (!found_sub or !found_exp or !found_jti) return null;
    return result;
}

fn extractSessionFields(session_json: []const u8, result: *TicketPayload) void {
    var pos: usize = 0;
    if (pos >= session_json.len or session_json[pos] != '{') return;
    pos += 1;

    while (pos < session_json.len) {
        skipWhitespace(session_json, &pos);
        if (pos >= session_json.len) return;
        if (session_json[pos] == '}') break;
        if (session_json[pos] == ',') {
            pos += 1;
            continue;
        }

        const key = extractJsonKey(session_json, &pos) orelse return;
        skipWhitespace(session_json, &pos);
        if (pos >= session_json.len or session_json[pos] != ':') return;
        pos += 1;
        skipWhitespace(session_json, &pos);

        if (std.mem.eql(u8, key, "externalId")) {
            result.external_id = extractJsonString(session_json, &pos);
        } else if (std.mem.eql(u8, key, "isAnonymous")) {
            if (pos + 4 <= session_json.len and std.mem.eql(u8, session_json[pos..][0..4], "true")) {
                result.is_anonymous = true;
                pos += 4;
            } else if (pos + 5 <= session_json.len and std.mem.eql(u8, session_json[pos..][0..5], "false")) {
                result.is_anonymous = false;
                pos += 5;
            } else {
                return;
            }
        } else if (std.mem.eql(u8, key, "claims")) {
            const claims_start = pos;
            if (skipJsonValue(session_json, &pos) == null) return;
            const claims_json = session_json[claims_start..pos];
            if (claims_json.len > 2 and claims_json[0] == '{' and claims_json[1] != '}') {
                result.claims_json = claims_json;
            }
        } else {
            if (skipJsonValue(session_json, &pos) == null) return;
        }
    }
}

fn skipWhitespace(json: []const u8, pos: *usize) void {
    while (pos.* < json.len) {
        switch (json[pos.*]) {
            ' ', '\t', '\n', '\r' => pos.* += 1,
            else => break,
        }
    }
}

fn extractJsonKey(json: []const u8, pos: *usize) ?[]const u8 {
    return extractJsonString(json, pos);
}

fn extractJsonString(json: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= json.len or json[pos.*] != '"') return null;
    pos.* += 1;
    const start = pos.*;
    while (pos.* < json.len) {
        if (json[pos.*] == '"') {
            const result = json[start..pos.*];
            pos.* += 1;
            return result;
        }
        if (json[pos.*] == '\\') {
            pos.* += 1;
        }
        pos.* += 1;
    }
    return null;
}

fn extractJsonInt(json: []const u8, pos: *usize) ?i64 {
    var negative = false;
    if (pos.* < json.len and json[pos.*] == '-') {
        negative = true;
        pos.* += 1;
    }
    if (pos.* >= json.len or json[pos.*] < '0' or json[pos.*] > '9') return null;
    var value: i64 = 0;
    while (pos.* < json.len and json[pos.*] >= '0' and json[pos.*] <= '9') {
        const digit: i64 = json[pos.*] - '0';
        const mul_result = @mulWithOverflow(value, 10);
        if (mul_result[1] != 0) return null;
        value = mul_result[0];
        const add_result = @addWithOverflow(value, if (negative) -digit else digit);
        if (add_result[1] != 0) return null;
        value = add_result[0];
        pos.* += 1;
    }
    return value;
}

fn skipJsonValue(json: []const u8, pos: *usize) ?void {
    if (pos.* >= json.len) return null;
    switch (json[pos.*]) {
        '"' => {
            _ = extractJsonString(json, pos) orelse return null;
        },
        '{' => {
            var depth: usize = 1;
            pos.* += 1;
            while (pos.* < json.len and depth > 0) {
                if (json[pos.*] == '{') {
                    depth += 1;
                } else if (json[pos.*] == '}') {
                    depth -= 1;
                } else if (json[pos.*] == '"') {
                    pos.* += 1;
                    while (pos.* < json.len and json[pos.*] != '"') {
                        if (json[pos.*] == '\\') pos.* += 1;
                        pos.* += 1;
                    }
                }
                pos.* += 1;
            }
            if (depth != 0) return null;
        },
        '[' => {
            var depth: usize = 1;
            pos.* += 1;
            while (pos.* < json.len and depth > 0) {
                if (json[pos.*] == '[') {
                    depth += 1;
                } else if (json[pos.*] == ']') {
                    depth -= 1;
                } else if (json[pos.*] == '"') {
                    pos.* += 1;
                    while (pos.* < json.len and json[pos.*] != '"') {
                        if (json[pos.*] == '\\') pos.* += 1;
                        pos.* += 1;
                    }
                }
                pos.* += 1;
            }
            if (depth != 0) return null;
        },
        't' => {
            if (pos.* + 4 > json.len or !std.mem.eql(u8, json[pos.*..][0..4], "true")) return null;
            pos.* += 4;
        },
        'f' => {
            if (pos.* + 5 > json.len or !std.mem.eql(u8, json[pos.*..][0..5], "false")) return null;
            pos.* += 5;
        },
        'n' => {
            if (pos.* + 4 > json.len or !std.mem.eql(u8, json[pos.*..][0..4], "null")) return null;
            pos.* += 4;
        },
        '-', '0'...'9' => {
            while (pos.* < json.len and (json[pos.*] >= '0' and json[pos.*] <= '9' or json[pos.*] == '.' or json[pos.*] == '-' or json[pos.*] == '+' or json[pos.*] == 'e' or json[pos.*] == 'E')) {
                pos.* += 1;
            }
        },
        else => return null,
    }
}
