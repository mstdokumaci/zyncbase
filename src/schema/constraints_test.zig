const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const constraints = @import("constraints.zig");
const types = @import("types.zig");

test "constraints: validateEmail" {
    // Valid emails
    try std.testing.expect(constraints.validateEmail("user@example.com"));
    try std.testing.expect(constraints.validateEmail("user.name+tag@sub.domain.org"));
    try std.testing.expect(constraints.validateEmail("a@b.cd"));

    // Invalid emails
    try std.testing.expect(!constraints.validateEmail(""));
    try std.testing.expect(!constraints.validateEmail("noatmark"));
    try std.testing.expect(!constraints.validateEmail("@nodomain.com"));
    try std.testing.expect(!constraints.validateEmail("nolocal@"));
    try std.testing.expect(!constraints.validateEmail("user@nodot"));
    try std.testing.expect(!constraints.validateEmail("user@.leadingdot.com"));
    try std.testing.expect(!constraints.validateEmail("user@trailingdot.com."));
    try std.testing.expect(!constraints.validateEmail("user@double..dot.com"));
    try std.testing.expect(!constraints.validateEmail("user with space@domain.com"));
    try std.testing.expect(!constraints.validateEmail("user@domain with space.com"));
    try std.testing.expect(!constraints.validateEmail("user@@domain.com"));
}

test "constraints: validateUuid" {
    // Valid UUIDs
    try std.testing.expect(constraints.validateUuid("123e4567-e89b-12d3-a456-426614174000"));
    try std.testing.expect(constraints.validateUuid("00000000-0000-0000-0000-000000000000"));
    try std.testing.expect(constraints.validateUuid("ABCDEF01-2345-6789-ABCD-EF0123456789"));

    // Invalid UUIDs
    try std.testing.expect(!constraints.validateUuid(""));
    try std.testing.expect(!constraints.validateUuid("123e4567-e89b-12d3-a456")); // too short
    try std.testing.expect(!constraints.validateUuid("123e4567-e89b-12d3-a456-4266141740001")); // too long
    try std.testing.expect(!constraints.validateUuid("123e4567e89b12d3a456426614174000")); // missing hyphens
    try std.testing.expect(!constraints.validateUuid("123e4567-e89b-12d3-a456-42661417400g")); // non-hex character 'g'
    try std.testing.expect(!constraints.validateUuid("123e4567-e89b-12d3-a456-42661417400Z")); // non-hex character 'Z'
}

test "constraints: validateUri" {
    // Valid URIs
    try std.testing.expect(constraints.validateUri("https://example.com/path"));
    try std.testing.expect(constraints.validateUri("http://localhost:8080"));
    try std.testing.expect(constraints.validateUri("mailto:user@example.com"));
    try std.testing.expect(constraints.validateUri("custom+app.v1-proto://action?k=v"));
    try std.testing.expect(constraints.validateUri("urn:isbn:0-486-27557-4"));

    // Invalid URIs
    try std.testing.expect(!constraints.validateUri(""));
    try std.testing.expect(!constraints.validateUri("ab")); // too short
    try std.testing.expect(!constraints.validateUri("://missing-scheme.com"));
    try std.testing.expect(!constraints.validateUri("123scheme://invalid-start"));
    try std.testing.expect(!constraints.validateUri("http:")); // empty rest
    try std.testing.expect(!constraints.validateUri("http://with spaces/in/uri"));
}

test "constraints: pattern compilation and matching" {
    const allocator = std.testing.allocator;

    const regex = try constraints.compilePattern(allocator, "^[A-Z]{3}-[0-9]{3}$");
    defer constraints.freePattern(allocator, regex);

    try std.testing.expect(try constraints.matchPattern(regex, allocator, "ABC-123"));
    try std.testing.expect(!try constraints.matchPattern(regex, allocator, "abc-123"));
    try std.testing.expect(!try constraints.matchPattern(regex, allocator, "ABCD-123"));
    try std.testing.expect(!try constraints.matchPattern(regex, allocator, "ABC-12"));

    // Invalid regex
    try std.testing.expectError(error.InvalidRegex, constraints.compilePattern(allocator, "[invalid regex"));
}

test "constraints: string length and UTF-8 codepoints" {
    const allocator = std.testing.allocator;

    const c = types.Constraints{
        .min_length = 3,
        .max_length = 5,
    };

    // ASCII bounds
    {
        const payload_ok = try msgpack.Payload.strToPayload("abcd", allocator);
        defer payload_ok.free(allocator);
        try constraints.validate(c, .text, payload_ok, allocator);
    }
    {
        const payload_too_short = try msgpack.Payload.strToPayload("ab", allocator);
        defer payload_too_short.free(allocator);
        try std.testing.expectError(error.LengthViolation, constraints.validate(c, .text, payload_too_short, allocator));
    }
    {
        const payload_too_long = try msgpack.Payload.strToPayload("abcdef", allocator);
        defer payload_too_long.free(allocator);
        try std.testing.expectError(error.LengthViolation, constraints.validate(c, .text, payload_too_long, allocator));
    }

    // Multi-byte UTF-8 codepoint counting: "café" is 4 codepoints (5 bytes: c a f \xc3\xa9)
    {
        const exact_4 = types.Constraints{
            .min_length = 4,
            .max_length = 4,
        };
        const payload_utf8 = try msgpack.Payload.strToPayload("café", allocator);
        defer payload_utf8.free(allocator);
        try constraints.validate(exact_4, .text, payload_utf8, allocator);
    }
}

test "constraints: numeric range validation" {
    const allocator = std.testing.allocator;

    const c_real = types.Constraints{
        .minimum = .{ .real = 10.0 },
        .maximum = .{ .real = 20.0 },
    };

    // Real payload
    try constraints.validate(c_real, .real, msgpack.Payload{ .float = 10.0 }, allocator);
    try constraints.validate(c_real, .real, msgpack.Payload{ .float = 20.0 }, allocator);
    try constraints.validate(c_real, .real, msgpack.Payload{ .float = 15.5 }, allocator);
    try std.testing.expectError(error.RangeViolation, constraints.validate(c_real, .real, msgpack.Payload{ .float = 9.99 }, allocator));
    try std.testing.expectError(error.RangeViolation, constraints.validate(c_real, .real, msgpack.Payload{ .float = 20.01 }, allocator));

    // Integer bounds with exact i64 precision
    const c_integer = types.Constraints{
        .minimum = .{ .integer = 10 },
        .maximum = .{ .integer = 20 },
    };

    try constraints.validate(c_integer, .integer, msgpack.Payload.intToPayload(10), allocator);
    try constraints.validate(c_integer, .integer, msgpack.Payload.intToPayload(20), allocator);
    try constraints.validate(c_integer, .integer, msgpack.Payload.intToPayload(15), allocator);
    try std.testing.expectError(error.RangeViolation, constraints.validate(c_integer, .integer, msgpack.Payload.intToPayload(9), allocator));
    try std.testing.expectError(error.RangeViolation, constraints.validate(c_integer, .integer, msgpack.Payload.intToPayload(21), allocator));

    // Large 64-bit integer bounds beyond 2^53
    const c_big = types.Constraints{
        .minimum = .{ .integer = 9007199254740993 },
        .maximum = .{ .integer = 9223372036854775806 },
    };
    try constraints.validate(c_big, .integer, msgpack.Payload.intToPayload(9007199254740993), allocator);
    try constraints.validate(c_big, .integer, msgpack.Payload.intToPayload(9223372036854775806), allocator);
    try std.testing.expectError(error.RangeViolation, constraints.validate(c_big, .integer, msgpack.Payload.intToPayload(9007199254740992), allocator));
}

test "constraints: enum validation" {
    const allocator = std.testing.allocator;

    // String enum
    {
        const c = types.Constraints{
            .enum_values = &.{
                .{ .text = "active" },
                .{ .text = "idle" },
                .{ .text = "away" },
            },
        };
        const active = try msgpack.Payload.strToPayload("active", allocator);
        defer active.free(allocator);
        try constraints.validate(c, .text, active, allocator);

        const invalid = try msgpack.Payload.strToPayload("unknown", allocator);
        defer invalid.free(allocator);
        try std.testing.expectError(error.EnumViolation, constraints.validate(c, .text, invalid, allocator));
    }

    // Integer enum
    {
        const c = types.Constraints{
            .enum_values = &.{
                .{ .integer = 100 },
                .{ .integer = 200 },
            },
        };
        try constraints.validate(c, .integer, msgpack.Payload.intToPayload(100), allocator);
        try std.testing.expectError(error.EnumViolation, constraints.validate(c, .integer, msgpack.Payload.intToPayload(300), allocator));
    }

    // Real enum
    {
        const c = types.Constraints{
            .enum_values = &.{
                .{ .real = 1.5 },
                .{ .real = 2.5 },
            },
        };
        try constraints.validate(c, .real, msgpack.Payload{ .float = 1.5 }, allocator);
        try std.testing.expectError(error.EnumViolation, constraints.validate(c, .real, msgpack.Payload{ .float = 3.5 }, allocator));
    }
}

test "constraints: format validation via validate" {
    const allocator = std.testing.allocator;

    const email_c = types.Constraints{ .format = .email };
    {
        const valid_email = try msgpack.Payload.strToPayload("user@example.com", allocator);
        defer valid_email.free(allocator);
        try constraints.validate(email_c, .text, valid_email, allocator);

        const invalid_email = try msgpack.Payload.strToPayload("not-an-email", allocator);
        defer invalid_email.free(allocator);
        try std.testing.expectError(error.FormatViolation, constraints.validate(email_c, .text, invalid_email, allocator));
    }

    const uuid_c = types.Constraints{ .format = .uuid };
    {
        const valid_uuid = try msgpack.Payload.strToPayload("123e4567-e89b-12d3-a456-426614174000", allocator);
        defer valid_uuid.free(allocator);
        try constraints.validate(uuid_c, .text, valid_uuid, allocator);

        const invalid_uuid = try msgpack.Payload.strToPayload("invalid-uuid", allocator);
        defer invalid_uuid.free(allocator);
        try std.testing.expectError(error.FormatViolation, constraints.validate(uuid_c, .text, invalid_uuid, allocator));
    }
}

test "constraints: pattern rejects embedded NUL bytes" {
    const allocator = std.testing.allocator;

    // Pattern with embedded NUL byte is rejected at compile time
    try std.testing.expectError(error.InvalidRegex, constraints.compilePattern(allocator, "^[a-z]+\x00extra$"));

    const regex = try constraints.compilePattern(allocator, "^[a-z]+$");
    defer constraints.freePattern(allocator, regex);

    // Normal matching
    try std.testing.expect(try constraints.matchPattern(regex, allocator, "abc"));

    // Embedded NUL byte is rejected safely
    const with_nul = "abc\x00extra";
    try std.testing.expect(!try constraints.matchPattern(regex, allocator, with_nul));
}
