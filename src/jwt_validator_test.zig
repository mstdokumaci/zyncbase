const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const jwt_validator = @import("jwt_validator.zig");
const JwtValidator = jwt_validator.JwtValidator;
const JwksCache = jwt_validator.JwksCache;
const Jwk = jwt_validator.Jwk;

fn encodeBase64Url(allocator: Allocator, input: []const u8) ![]u8 {
    const len = std.base64.url_safe_no_pad.Encoder.calcSize(input.len);
    const dest = try allocator.alloc(u8, len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(dest, input);
    return dest;
}

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
    const header_b64 = try encodeBase64Url(allocator, header_json);
    defer allocator.free(header_b64);

    // 2. Payload
    var payload_buf = std.ArrayListUnmanaged(u8).empty;
    defer payload_buf.deinit(allocator);
    var writer = payload_buf.writer(allocator);
    try writer.print("{{\"sub\":\"{s}\",\"exp\":{d}", .{ sub, exp });
    if (iss) |i| {
        try writer.print(",\"iss\":\"{s}\"", .{i});
    }
    if (aud) |a| {
        try writer.print(",\"aud\":\"{s}\"", .{a});
    }
    try writer.writeAll("}");
    const payload_b64 = try encodeBase64Url(allocator, payload_buf.items);
    defer allocator.free(payload_b64);

    // 3. MSG
    const msg = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(msg);

    // 4. Sign
    var sig_bytes: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&sig_bytes, msg, secret);
    const sig_b64 = try encodeBase64Url(allocator, &sig_bytes);
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

    // Populate keys manually to avoid network request
    var keys = try allocator.alloc(Jwk, 1);
    keys[0] = Jwk{
        .kty = try allocator.dupe(u8, "RSA"),
        .kid = try allocator.dupe(u8, "key_1"),
        .n = try allocator.dupe(u8, "modulus"),
        .e = try allocator.dupe(u8, "exponent"),
    };
    try cache.setKeys(keys, std.time.timestamp());

    // Retrieve valid key
    const retrieved = try cache.getJwk("key_1");
    defer retrieved.deinit(allocator);

    try testing.expectEqualStrings("RSA", retrieved.kty);
    try testing.expectEqualStrings("key_1", retrieved.kid);
    try testing.expectEqualStrings("modulus", retrieved.n.?);
    try testing.expectEqualStrings("exponent", retrieved.e.?);

    // Key not found triggers refresh, which fails on dummy URL (testing error behavior)
    try testing.expectError(error.HttpFetchFailed, cache.getJwk("key_2"));
}
