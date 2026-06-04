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

        const sig_bytes = try decodeBase64Url(allocator, sig_b64);
        defer allocator.free(sig_bytes);

        if (sig_bytes.len != 32 or !std.crypto.timing_safe.eql([32]u8, computed_sig, sig_bytes[0..32].*)) {
            return error.AuthFailed;
        }

        const payload_json = try decodeBase64Url(allocator, payload_b64);
        defer allocator.free(payload_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidTicket;
        const payload_obj = parsed.value.object;

        const sub = getJsonString(payload_obj, "sub") orelse return error.InvalidTicket;
        const exp = getJsonInt(payload_obj, "exp") orelse return error.InvalidTicket;
        const jti = getJsonString(payload_obj, "jti") orelse return error.InvalidTicket;

        const now = std.time.timestamp();
        if (now >= exp) {
            return error.TokenExpired;
        }

        if (self.single_use) {
            self.mutex.lock();
            defer self.mutex.unlock();

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

            if (self.redeemed_tickets.contains(jti)) {
                return error.AuthFailed;
            }

            const jti_owned = try self.allocator.dupe(u8, jti);
            var jti_owned_transferred = false;
            errdefer if (!jti_owned_transferred) self.allocator.free(jti_owned);
            try self.redeemed_tickets.put(jti_owned, exp);
            jti_owned_transferred = true;
        }

        const session_val = payload_obj.get("session");
        const external_id = if (session_val) |sess| blk: {
            if (sess != .object) break :blk try allocator.dupe(u8, sub);
            const eid = getJsonString(sess.object, "externalId") orelse break :blk try allocator.dupe(u8, sub);
            break :blk try allocator.dupe(u8, eid);
        } else try allocator.dupe(u8, sub);

        const is_anonymous = if (session_val) |sess| blk: {
            if (sess != .object) break :blk false;
            const anon_val = sess.object.get("isAnonymous") orelse break :blk false;
            break :blk anon_val == .bool and anon_val.bool;
        } else false;

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

        if (session_val) |sess| {
            if (sess == .object) {
                if (sess.object.get("claims")) |claims_val| {
                    if (claims_val == .object) {
                        var claims_it = claims_val.object.iterator();
                        while (claims_it.next()) |entry| {
                            const key = try allocator.dupe(u8, entry.key_ptr.*);
                            errdefer allocator.free(key);
                            const val = try jsonToTypedValue(allocator, entry.value_ptr.*);
                            errdefer val.deinit(allocator);
                            try claims.put(allocator, key, val);
                        }
                    }
                }
            }
        }

        return Session{
            .external_id = external_id,
            .is_anonymous = is_anonymous,
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

        var claims_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer claims_buf.deinit(allocator);
        try claimsBufAppend(allocator, &claims_buf, "{", claims);
        var first = true;
        var claims_it = claims.iterator();
        while (claims_it.next()) |entry| {
            if (!first) try claimsBufAppend(allocator, &claims_buf, ",", claims);
            first = false;
            try claimsBufAppend(allocator, &claims_buf, "\"", claims);
            try claimsBufAppend(allocator, &claims_buf, entry.key_ptr.*, claims);
            try claimsBufAppend(allocator, &claims_buf, "\":", claims);
            try typedValueToJson(allocator, &claims_buf, entry.value_ptr.*);
        }
        try claimsBufAppend(allocator, &claims_buf, "}", claims);

        const payload_json = try std.fmt.allocPrint(allocator,
            \\{{"sub":"{s}","exp":{d},"jti":"{s}","session":{{"externalId":"{s}","isAnonymous":{s},"claims":{s}}}}}
        , .{ subject, exp, jti_hex, subject, if (is_anonymous) "true" else "false", claims_buf.items });
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
                    var validated_mut = validated;
                    defer validated_mut.deinit(allocator);
                    subject = validated_mut.subject;
                    claims = try Session.cloneClaims(validated_mut.claims, allocator);
                } else {
                    std.log.warn("JWT authentication attempted but JWT validator not configured", .{});
                    return error.AuthFailed;
                }
            } else {
                return error.InvalidMessage;
            }
        } else {
            const parsed_body = std.json.parseFromSlice(std.json.Value, allocator, ctx.body.items, .{}) catch {
                return error.InvalidMessage;
            };
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
    const exact_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(stripped) catch return error.InvalidBase64;
    const dest = try allocator.alloc(u8, exact_len);
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

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v == .string) return v.string;
    return null;
}

fn getJsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v == .integer) return v.integer;
    return null;
}

fn claimsBufAppend(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), s: []const u8, _: *const std.StringHashMapUnmanaged(typed.Value)) !void {
    try buf.appendSlice(allocator, s);
}

fn typedValueToJson(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), val: typed.Value) !void {
    switch (val) {
        .scalar => |s| switch (s) {
            .text => |t| {
                try buf.append(allocator, '"');
                for (t) |ch| {
                    switch (ch) {
                        '"' => try buf.appendSlice(allocator, "\\\""),
                        '\\' => try buf.appendSlice(allocator, "\\\\"),
                        '\n' => try buf.appendSlice(allocator, "\\n"),
                        '\r' => try buf.appendSlice(allocator, "\\r"),
                        '\t' => try buf.appendSlice(allocator, "\\t"),
                        else => try buf.append(allocator, ch),
                    }
                }
                try buf.append(allocator, '"');
            },
            .integer => |i| {
                var num_buf: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch return error.OutOfMemory;
                try buf.appendSlice(allocator, formatted);
            },
            .real => |f| {
                var num_buf: [64]u8 = undefined;
                const formatted = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch return error.OutOfMemory;
                try buf.appendSlice(allocator, formatted);
            },
            .boolean => |b| {
                try buf.appendSlice(allocator, if (b) "true" else "false");
            },
            .doc_id => |_| {
                try buf.appendSlice(allocator, "null");
            },
        },
        .array => |items| {
            try buf.append(allocator, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try typedScalarValueToJson(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .nil => {
            try buf.appendSlice(allocator, "null");
        },
    }
}

fn typedScalarValueToJson(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), val: typed.ScalarValue) !void {
    switch (val) {
        .text => |t| {
            try buf.append(allocator, '"');
            for (t) |ch| {
                switch (ch) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, ch),
                }
            }
            try buf.append(allocator, '"');
        },
        .integer => |i| {
            var num_buf: [32]u8 = undefined;
            const formatted = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, formatted);
        },
        .real => |f| {
            var num_buf: [64]u8 = undefined;
            const formatted = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch return error.OutOfMemory;
            try buf.appendSlice(allocator, formatted);
        },
        .boolean => |b| {
            try buf.appendSlice(allocator, if (b) "true" else "false");
        },
        .doc_id => |_| {
            try buf.appendSlice(allocator, "null");
        },
    }
}

fn jsonToTypedValue(allocator: Allocator, val: std.json.Value) !typed.Value {
    return switch (val) {
        .string => |s| .{ .scalar = .{ .text = try allocator.dupe(u8, s) } },
        .integer => |i| .{ .scalar = .{ .integer = i } },
        .float => |f| .{ .scalar = .{ .real = f } },
        .bool => |b| .{ .scalar = .{ .boolean = b } },
        .array => |arr| blk: {
            if (arr.items.len > 1000) return error.ClaimArrayTooLarge;
            const items = try allocator.alloc(typed.ScalarValue, arr.items.len);
            errdefer {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            }
            for (arr.items, 0..) |item, i| {
                const scalar = switch (item) {
                    .string => |s| typed.ScalarValue{ .text = try allocator.dupe(u8, s) },
                    .integer => |n| typed.ScalarValue{ .integer = n },
                    .float => |f| typed.ScalarValue{ .real = f },
                    .bool => |b| typed.ScalarValue{ .boolean = b },
                    else => return error.InvalidClaimArrayElement,
                };
                items[i] = scalar;
            }
            break :blk .{ .array = items };
        },
        else => return error.UnsupportedClaimType,
    };
}
