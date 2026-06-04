const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("uwebsockets_wrapper.zig").c;
const lockFreeCache = @import("lock_free_cache.zig").lockFreeCache;

pub const Jwk = struct {
    kty: []const u8,
    kid: []const u8,
    alg: ?[]const u8 = null,
    n: ?[]const u8 = null,
    e: ?[]const u8 = null,
    crv: ?[]const u8 = null,
    x: ?[]const u8 = null,
    y: ?[]const u8 = null,

    pub fn clone(self: Jwk, allocator: Allocator) !Jwk {
        return Jwk{
            .kty = try allocator.dupe(u8, self.kty),
            .kid = try allocator.dupe(u8, self.kid),
            .alg = if (self.alg) |a| try allocator.dupe(u8, a) else null,
            .n = if (self.n) |n| try allocator.dupe(u8, n) else null,
            .e = if (self.e) |e| try allocator.dupe(u8, e) else null,
            .crv = if (self.crv) |crv_v| try allocator.dupe(u8, crv_v) else null,
            .x = if (self.x) |x| try allocator.dupe(u8, x) else null,
            .y = if (self.y) |y| try allocator.dupe(u8, y) else null,
        };
    }

    pub fn deinit(self: Jwk, allocator: Allocator) void {
        allocator.free(self.kty);
        allocator.free(self.kid);
        if (self.alg) |a| allocator.free(a);
        if (self.n) |n| allocator.free(n);
        if (self.e) |e| allocator.free(e);
        if (self.crv) |crv_v| allocator.free(crv_v);
        if (self.x) |x| allocator.free(x);
        if (self.y) |y| allocator.free(y);
    }
};

pub const JwksState = struct {
    keys: []Jwk,
    last_fetched: i64,

    pub fn deinit(self: JwksState, allocator: Allocator) void {
        for (self.keys) |key| {
            key.deinit(allocator);
        }
        allocator.free(self.keys);
    }
};

const jwks_state_cache_type = lockFreeCache(JwksState, u8);

pub const JwksCache = struct {
    allocator: Allocator,
    jwks_url: ?[]const u8 = null,
    state_cache: *jwks_state_cache_type,

    pub fn init(allocator: Allocator, jwks_url: ?[]const u8) !JwksCache {
        const state_cache = try allocator.create(jwks_state_cache_type);
        errdefer allocator.destroy(state_cache);
        try state_cache.init(allocator, .{});

        return JwksCache{
            .allocator = allocator,
            .jwks_url = if (jwks_url) |url| try allocator.dupe(u8, url) else null,
            .state_cache = state_cache,
        };
    }

    pub fn deinit(self: *JwksCache) void {
        if (self.jwks_url) |url| self.allocator.free(url);
        self.state_cache.deinit();
        self.allocator.destroy(self.state_cache);
    }

    pub fn getJwk(self: *JwksCache, kid: []const u8) !Jwk {
        const url = self.jwks_url orelse return error.JwksNotConfigured;
        const now = std.time.timestamp();

        // 1. Try to read from the lock-free cache
        var found_key: ?Jwk = null;
        if (self.state_cache.get(0)) |handle| {
            defer handle.release();
            const state = handle.data();
            if (now - state.last_fetched <= 3600) {
                for (state.keys) |key| {
                    if (std.mem.eql(u8, key.kid, kid)) {
                        found_key = try key.clone(self.allocator);
                        break;
                    }
                }
            }
        } else |_| {}

        if (found_key) |key| {
            return key;
        }

        // 2. Fetch outside lock-free atomic context
        const keys = try fetchJwks(self.allocator, url);
        errdefer {
            for (keys) |k| k.deinit(self.allocator);
            self.allocator.free(keys);
        }

        const new_state = JwksState{
            .keys = keys,
            .last_fetched = std.time.timestamp(),
        };

        // 3. Atomically update/swap the cache
        try self.state_cache.update(0, new_state);

        // 4. Return from locally fetched keys (already validated/stored)
        for (keys) |key| {
            if (std.mem.eql(u8, key.kid, kid)) {
                return try key.clone(self.allocator);
            }
        }

        return error.KeyNotFound;
    }

    pub fn setKeys(self: *JwksCache, keys: []Jwk, timestamp: i64) !void {
        const state = JwksState{
            .keys = keys,
            .last_fetched = timestamp,
        };
        try self.state_cache.update(0, state);
    }
};

fn fetchJwks(allocator: Allocator, url_str: []const u8) ![]Jwk {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body_buf = std.ArrayListUnmanaged(u8).empty;
    var body_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &body_buf);
    defer body_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url_str },
        .response_writer = &body_writer.writer,
    });

    if (result.status != .ok) return error.HttpFetchFailed;

    const parsed = try std.json.parseFromSlice(
        struct { keys: []Jwk },
        allocator,
        body_writer.written(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    var list = std.ArrayListUnmanaged(Jwk).empty;
    errdefer {
        for (list.items) |jwk| jwk.deinit(allocator);
        list.deinit(allocator);
    }
    for (parsed.value.keys) |key| {
        try list.append(allocator, try key.clone(allocator));
    }
    return list.toOwnedSlice(allocator);
}

pub const JwtValidationConfig = struct {
    secret: ?[]const u8 = null,
    algorithm: []const u8 = "HS256",
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    subject_claim: []const u8 = "sub",
    jwks_cache: ?*JwksCache = null,
};

pub const JwtValidator = struct {
    config: JwtValidationConfig,

    pub fn init(config: JwtValidationConfig) JwtValidator {
        return .{ .config = config };
    }

    /// Verifies a JWT token. Returns the subject claim value allocated using `allocator`.
    pub fn validate(self: JwtValidator, allocator: Allocator, token: []const u8) ![]const u8 {
        var parts_it = std.mem.splitScalar(u8, token, '.');
        const header_b64 = parts_it.next() orelse return error.InvalidToken;
        const payload_b64 = parts_it.next() orelse return error.InvalidToken;
        const sig_b64 = parts_it.next() orelse return error.InvalidToken;
        if (parts_it.next() != null) return error.InvalidToken;

        // Extract message for signature checks
        const msg = token[0..(header_b64.len + 1 + payload_b64.len)];

        // Decode parts
        const header_bytes = try decodeBase64Url(allocator, header_b64);
        defer allocator.free(header_bytes);

        const payload_bytes = try decodeBase64Url(allocator, payload_b64);
        defer allocator.free(payload_bytes);

        const sig_bytes = try decodeBase64Url(allocator, sig_b64);
        defer allocator.free(sig_bytes);

        // Parse header
        const Header = struct {
            alg: []const u8,
            kid: ?[]const u8 = null,
        };
        const header = try std.json.parseFromSlice(Header, allocator, header_bytes, .{ .ignore_unknown_fields = true });
        defer header.deinit();

        // Parse payload as json Value
        const parsed_payload = try std.json.parseFromSlice(std.json.Value, allocator, payload_bytes, .{});
        defer parsed_payload.deinit();
        const payload = parsed_payload.value;

        // Verify algorithm matches config
        if (!std.mem.eql(u8, header.value.alg, self.config.algorithm)) {
            return error.AlgorithmMismatch;
        }

        // Verify signature
        if (std.mem.startsWith(u8, header.value.alg, "HS")) {
            const secret = self.config.secret orelse return error.SecretMissing;
            const verified = blk: {
                var computed_sig: [64]u8 = undefined;
                const sig_len = if (std.mem.eql(u8, header.value.alg, "HS256")) len: {
                    std.crypto.auth.hmac.sha2.HmacSha256.create(computed_sig[0..32], msg, secret);
                    break :len @as(usize, 32);
                } else if (std.mem.eql(u8, header.value.alg, "HS384")) len: {
                    std.crypto.auth.hmac.sha2.HmacSha384.create(computed_sig[0..48], msg, secret);
                    break :len @as(usize, 48);
                } else if (std.mem.eql(u8, header.value.alg, "HS512")) len: {
                    std.crypto.auth.hmac.sha2.HmacSha512.create(computed_sig[0..64], msg, secret);
                    break :len @as(usize, 64);
                } else return error.UnsupportedAlgorithm;

                if (sig_bytes.len != sig_len) break :blk false;
                break :blk std.mem.eql(u8, computed_sig[0..sig_len], sig_bytes);
            };

            if (!verified) return error.AuthFailed;
        } else {
            // Asymmetric signature validation using OpenSSL EVP
            const kid = header.value.kid orelse return error.KidMissing;
            const jwks_cache = self.config.jwks_cache orelse return error.JwksNotConfigured;
            const jwk = try jwks_cache.getJwk(kid);
            defer jwk.deinit(allocator);

            const verified = try verifyAsymmetricSignature(allocator, header.value.alg, jwk, msg, sig_bytes);
            if (!verified) return error.AuthFailed;
        }

        // Validate claims
        const now = std.time.timestamp();

        // 1. Time bounds
        if (!validateTimeClaims(payload, now)) {
            return error.TokenExpired;
        }

        // 2. Issuer
        if (self.config.issuer) |expected_iss| {
            const iss = getJsonString(payload, "iss") orelse return error.IssuerMismatch;
            if (!std.mem.eql(u8, iss, expected_iss)) return error.IssuerMismatch;
        }

        // 3. Audience
        if (self.config.audience) |expected_aud| {
            if (!validateAudience(payload, expected_aud)) return error.AudienceMismatch;
        }

        // Extract subject claim
        const sub = getJsonString(payload, self.config.subject_claim) orelse return error.SubjectClaimMissing;
        return try allocator.dupe(u8, sub);
    }
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

fn getJsonString(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const obj = val.object;
    const v = obj.get(key) orelse return null;
    if (v == .string) return v.string;
    return null;
}

fn validateAudience(payload: std.json.Value, expected_aud: []const u8) bool {
    if (payload != .object) return false;
    const obj = payload.object;
    const aud_val = obj.get("aud") orelse return false;
    switch (aud_val) {
        .string => |s| return std.mem.eql(u8, s, expected_aud),
        .array => |arr| {
            for (arr.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, expected_aud)) {
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn validateTimeClaims(payload: std.json.Value, current_time: i64) bool {
    if (payload != .object) return false;
    const obj = payload.object;

    if (obj.get("exp")) |exp_val| {
        const exp = switch (exp_val) {
            .integer => exp_val.integer,
            .float => @as(i64, @intFromFloat(exp_val.float)),
            else => return false,
        };
        if (current_time >= exp) return false;
    } else {
        return false;
    }

    if (obj.get("nbf")) |nbf_val| {
        const nbf = switch (nbf_val) {
            .integer => nbf_val.integer,
            .float => @as(i64, @intFromFloat(nbf_val.float)),
            else => return false,
        };
        if (current_time < nbf) return false;
    }

    return true;
}

fn verifyAsymmetricSignature(
    allocator: Allocator,
    alg: []const u8,
    jwk: Jwk,
    msg: []const u8,
    sig: []const u8,
) !bool {
    if (std.mem.startsWith(u8, alg, "RS") or std.mem.startsWith(u8, alg, "PS")) {
        const n_b64 = jwk.n orelse return error.InvalidJwk;
        const e_b64 = jwk.e orelse return error.InvalidJwk;

        const n_bytes = try decodeBase64Url(allocator, n_b64);
        defer allocator.free(n_bytes);
        const e_bytes = try decodeBase64Url(allocator, e_b64);
        defer allocator.free(e_bytes);

        const hash_alg = if (std.mem.eql(u8, alg, "RS256") or std.mem.eql(u8, alg, "PS256"))
            "SHA256"
        else if (std.mem.eql(u8, alg, "RS384") or std.mem.eql(u8, alg, "PS384"))
            "SHA384"
        else if (std.mem.eql(u8, alg, "RS512") or std.mem.eql(u8, alg, "PS512"))
            "SHA512"
        else
            return error.UnsupportedAlgorithm;

        const verified = c.openssl_verify_rsa(
            hash_alg.ptr,
            n_bytes.ptr,
            n_bytes.len,
            e_bytes.ptr,
            e_bytes.len,
            msg.ptr,
            msg.len,
            sig.ptr,
            sig.len,
        );
        return verified != 0;
    } else if (std.mem.startsWith(u8, alg, "ES")) {
        const crv = jwk.crv orelse return error.InvalidJwk;
        const x_b64 = jwk.x orelse return error.InvalidJwk;
        const y_b64 = jwk.y orelse return error.InvalidJwk;

        const x_bytes = try decodeBase64Url(allocator, x_b64);
        defer allocator.free(x_bytes);
        const y_bytes = try decodeBase64Url(allocator, y_b64);
        defer allocator.free(y_bytes);

        const curve_name = if (std.mem.eql(u8, crv, "P-256"))
            "P-256"
        else if (std.mem.eql(u8, crv, "P-384"))
            "P-384"
        else if (std.mem.eql(u8, crv, "P-521"))
            "P-521"
        else
            return error.UnsupportedCurve;

        const verified = c.openssl_verify_ec(
            curve_name.ptr,
            x_bytes.ptr,
            x_bytes.len,
            y_bytes.ptr,
            y_bytes.len,
            msg.ptr,
            msg.len,
            sig.ptr,
            sig.len,
        );
        return verified != 0;
    } else {
        return error.UnsupportedAlgorithm;
    }
}
