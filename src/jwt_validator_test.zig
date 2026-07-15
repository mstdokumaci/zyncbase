const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const jwt_validator = @import("jwt_validator.zig");
const JwtValidator = jwt_validator.JwtValidator;
const JwksCache = jwt_validator.JwksCache;
const Jwk = jwt_validator.Jwk;
const json_write = @import("json/write.zig");
const base64_utils = @import("base64_utils.zig");

fn createHmacJwt(
    allocator: Allocator,
    secret: []const u8,
    sub: []const u8,
    exp: i64,
    iss: ?[]const u8,
    aud: ?[]const u8,
) ![]const u8 {
    // 1. Header
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64_utils.urlEncodeAlloc(allocator, header_json);
    defer allocator.free(header_b64);

    // 2. Payload
    var payload_buf = std.ArrayListUnmanaged(u8).empty;
    defer payload_buf.deinit(allocator);
    var w = json_write.Writer{ .buf = &payload_buf, .allocator = allocator };
    try w.beginObject();
    try w.field("sub", sub);
    try w.intField("exp", exp);
    if (iss) |i| {
        try w.field("iss", i);
    }
    if (aud) |a| {
        try w.field("aud", a);
    }
    try w.endObject();
    const payload_b64 = try base64_utils.urlEncodeAlloc(allocator, payload_buf.items);
    defer allocator.free(payload_b64);

    // 3. MSG
    const msg = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(msg);

    // 4. Sign
    var sig_bytes: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&sig_bytes, msg, secret);
    const sig_b64 = try base64_utils.urlEncodeAlloc(allocator, &sig_bytes);
    defer allocator.free(sig_b64);

    return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, sig_b64 });
}

test "JwtValidator: valid HS256 signature and claims" {
    const allocator = testing.allocator;
    const secret = "super-secret-key-1234567890123456";
    const sub = "user_12345";
    const exp = std.time.timestamp() + 3600;

    const token = try createHmacJwt(allocator, secret, sub, exp, "issuer_xyz", "audience_abc");
    defer allocator.free(token);

    const validator = JwtValidator.init(.{
        .secret = secret,
        .algorithm = "HS256",
        .issuer = "issuer_xyz",
        .audience = "audience_abc",
    });

    const validated_sub = try validator.validate(allocator, token);
    defer allocator.free(validated_sub);

    try testing.expectEqualStrings(sub, validated_sub);
}

test "JwtValidator: expired token" {
    const allocator = testing.allocator;
    const secret = "super-secret-key-1234567890123456";
    const sub = "user_12345";
    const exp = std.time.timestamp() - 10; // 10 seconds in the past

    const token = try createHmacJwt(allocator, secret, sub, exp, "issuer_xyz", "audience_abc");
    defer allocator.free(token);

    const validator = JwtValidator.init(.{
        .secret = secret,
        .algorithm = "HS256",
        .issuer = "issuer_xyz",
        .audience = "audience_abc",
    });

    try testing.expectError(error.TokenExpired, validator.validate(allocator, token));
}

test "JwtValidator: secret mismatch fails validation" {
    const allocator = testing.allocator;
    const secret = "super-secret-key-1234567890123456";
    const wrong_secret = "wrong-secret-key-1234567890123456";
    const sub = "user_12345";
    const exp = std.time.timestamp() + 3600;

    const token = try createHmacJwt(allocator, secret, sub, exp, "issuer_xyz", "audience_abc");
    defer allocator.free(token);

    const validator = JwtValidator.init(.{
        .secret = wrong_secret,
        .algorithm = "HS256",
        .issuer = "issuer_xyz",
        .audience = "audience_abc",
    });

    try testing.expectError(error.AuthFailed, validator.validate(allocator, token));
}

test "JwtValidator: issuer mismatch fails validation" {
    const allocator = testing.allocator;
    const secret = "super-secret-key-1234567890123456";
    const sub = "user_12345";
    const exp = std.time.timestamp() + 3600;

    const token = try createHmacJwt(allocator, secret, sub, exp, "issuer_xyz", "audience_abc");
    defer allocator.free(token);

    const validator = JwtValidator.init(.{
        .secret = secret,
        .algorithm = "HS256",
        .issuer = "issuer_other",
        .audience = "audience_abc",
    });

    try testing.expectError(error.IssuerMismatch, validator.validate(allocator, token));
}

test "JwtValidator: audience mismatch fails validation" {
    const allocator = testing.allocator;
    const secret = "super-secret-key-1234567890123456";
    const sub = "user_12345";
    const exp = std.time.timestamp() + 3600;

    const token = try createHmacJwt(allocator, secret, sub, exp, "issuer_xyz", "audience_abc");
    defer allocator.free(token);

    const validator = JwtValidator.init(.{
        .secret = secret,
        .algorithm = "HS256",
        .issuer = "issuer_xyz",
        .audience = "audience_other",
    });

    try testing.expectError(error.AudienceMismatch, validator.validate(allocator, token));
}

test "JwksCache: getJwk looks up populated keys" {
    const allocator = testing.allocator;

    var cache = try JwksCache.init(allocator, "https://example.com/.well-known/jwks.json");
    defer cache.deinit();

    // Valid RSA modulus/exponent so setKeys can eagerly build the EVP_PKEY.
    const n_b64 = "2SJJNHh5kweKQwpXL796HER09fDVdeKAn6VO9pI9JGpv_WCM4KUxfuPyoJUlMNKsNj5QQCuOvJ4lrNwNRr5wPK2wPDsYRZSwhhr3ocUNAFgXf9YeBxSRoax9WHjPSTK6ai-lPWykj_gTl0AbOcw9bgY1ZOlh6DEVu_uPUkUOo7NXLkd5kIxakCWaf4MAl0qAs4bNmnPM78Nn5PdoF8UJ-vbEZ2sYu_PYp3q-GsdIfCxLLV8F3Xj5lQLR6nfIoz1L8tHPuPSh08B_rFuDdDhtcfsW0fPF_CyYelTydwTyVD_CzZpM0vgTLr8Uuxd8f7rqEdSp3h0IzR0cNGp4jcKHHw";
    const e_b64 = "AQAB";

    var keys = try allocator.alloc(Jwk, 1);
    keys[0] = Jwk{
        .kty = try allocator.dupe(u8, "RSA"),
        .kid = try allocator.dupe(u8, "key_1"),
        .n = try allocator.dupe(u8, n_b64),
        .e = try allocator.dupe(u8, e_b64),
    };
    try cache.setKeys(keys, std.time.timestamp());

    // Retrieve valid key
    const retrieved = try cache.getJwk("key_1");
    defer retrieved.deinit(allocator);

    try testing.expectEqualStrings("RSA", retrieved.kty);
    try testing.expectEqualStrings("key_1", retrieved.kid);
    try testing.expectEqualStrings(n_b64, retrieved.n.?);
    try testing.expectEqualStrings(e_b64, retrieved.e.?);

    // Key not found triggers refresh, which fails on dummy URL (testing error behavior)
    try testing.expectError(error.HttpFetchFailed, cache.getJwk("key_2"));
}

test "JwtValidator: verify RS256 and PS256 tokens" {
    const allocator = testing.allocator;

    var cache = try JwksCache.init(allocator, "https://example.com/.well-known/jwks.json");
    defer cache.deinit();

    // Populate the JWK we generated
    var keys = try allocator.alloc(Jwk, 1);
    keys[0] = Jwk{
        .kty = try allocator.dupe(u8, "RSA"),
        .kid = try allocator.dupe(u8, "key1"),
        .n = try allocator.dupe(u8, "2SJJNHh5kweKQwpXL796HER09fDVdeKAn6VO9pI9JGpv_WCM4KUxfuPyoJUlMNKsNj5QQCuOvJ4lrNwNRr5wPK2wPDsYRZSwhhr3ocUNAFgXf9YeBxSRoax9WHjPSTK6ai-lPWykj_gTl0AbOcw9bgY1ZOlh6DEVu_uPUkUOo7NXLkd5kIxakCWaf4MAl0qAs4bNmnPM78Nn5PdoF8UJ-vbEZ2sYu_PYp3q-GsdIfCxLLV8F3Xj5lQLR6nfIoz1L8tHPuPSh08B_rFuDdDhtcfsW0fPF_CyYelTydwTyVD_CzZpM0vgTLr8Uuxd8f7rqEdSp3h0IzR0cNGp4jcKHHw"),
        .e = try allocator.dupe(u8, "AQAB"),
    };
    try cache.setKeys(keys, std.time.timestamp());

    const token_rs = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImtleTEifQ.eyJzdWIiOiJ1c2VyXzEyMzQ1IiwiaXNzIjoiaXNzdWVyX3h5eiIsImF1ZCI6ImF1ZGllbmNlX2FiYyIsImV4cCI6NDAwMDAwMDAwMH0.Rs_fn7LadvhYdkjEiowVbslQybN1DjW7tVzY4teRQzgqClPjcfyAvI30_QgnMOHfQAcy5dXITWw2pv4mnc9vFVIpmO3wLqIsmyHS_IZ563QS0s7ZMnsHECeTeQaXIFhz8Q1xZeKkJ5zXuTi8zTdMpOS_UTObd_RXKP5g8dZQXOaU5xEijixLaGAkxwST1aqWj0C6SjJNleGFgi_s3csUfyW41jBUV6qigt17tM7FzYt9kz-jjJArLiZEgGQLlf8w036UUPWphPBPJjBHc7qOhZLC_YVPeyYAXyRb0BwNSNGfHhzLMqxaYs0QtYTBrEgU0tRIkqYjYNICxyU9LXhCZg";

    const token_ps = "eyJhbGciOiJQUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImtleTEifQ.eyJzdWIiOiJ1c2VyXzEyMzQ1IiwiaXNzIjoiaXNzdWVyX3h5eiIsImF1ZCI6ImF1ZGllbmNlX2FiYyIsImV4cCI6NDAwMDAwMDAwMH0.zvwY0WtlGBc7s9XLsKoH9U126wGRUCHg_oxyHa9UfcBvxtaDp2Od8Yur2FE46ufa6am19TTowpq103t0BcxvghXH-YHbtqL3eJjCEk1g1ETlvfhDyfbwL9QmOKoTeRMnKj3DoyL9hVendps0ZqLWYIyVLkgSwu4T63Ru5tAuew0be-C185DHx-dna9aRBKTbd-oM5aef-_lJUB4ObatspVSB5z52T_fJI0K1wvKS8L3h0d0-lcjKoUOLVy4Bka4mV9NWWHy-EYUZmBheZ2b8kaKfqmYUKsK19tMgHZJ4tbZF861pHF_UVLU40iBDqLfhqP6_siDsr_wneU9URrS55Q";

    // 1. Verify RS256 token with RS256 validator
    {
        const validator = JwtValidator.init(.{
            .algorithm = "RS256",
            .issuer = "issuer_xyz",
            .audience = "audience_abc",
            .jwks_cache = &cache,
        });
        const sub = try validator.validate(allocator, token_rs);
        defer allocator.free(sub);
        try testing.expectEqualStrings("user_12345", sub);
    }

    // 2. Verify PS256 token with PS256 validator
    {
        const validator = JwtValidator.init(.{
            .algorithm = "PS256",
            .issuer = "issuer_xyz",
            .audience = "audience_abc",
            .jwks_cache = &cache,
        });
        const sub = try validator.validate(allocator, token_ps);
        defer allocator.free(sub);
        try testing.expectEqualStrings("user_12345", sub);
    }
}
