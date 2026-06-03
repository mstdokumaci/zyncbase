const std = @import("std");
const testing = std.testing;
const TicketExchange = @import("ticket_exchange.zig").TicketExchange;

test "TicketExchange: generate and verify single-use ticket" {
    const allocator = testing.allocator;

    const exchange = try TicketExchange.init(
        allocator,
        "test-ticket-signing-secret-key-32b",
        60,
        true, // single_use = true
        null,
        false,
        null,
        false,
    );
    defer exchange.deinit();

    const subject = "user_alice";
    const ticket = try exchange.generateTicket(allocator, subject, false);
    defer allocator.free(ticket);

    // First verification should succeed
    const verified_sub = try exchange.verifyTicket(allocator, ticket);
    defer allocator.free(verified_sub);

    try testing.expectEqualStrings(subject, verified_sub);

    // Second verification of the same single-use ticket should fail
    try testing.expectError(error.AuthFailed, exchange.verifyTicket(allocator, ticket));
}

test "TicketExchange: generate and verify multi-use ticket" {
    const allocator = testing.allocator;

    const exchange = try TicketExchange.init(
        allocator,
        "test-ticket-signing-secret-key-32b",
        60,
        false, // single_use = false
        null,
        false,
        null,
        false,
    );
    defer exchange.deinit();

    const subject = "user_bob";
    const ticket = try exchange.generateTicket(allocator, subject, false);
    defer allocator.free(ticket);

    // First verification
    const verified_sub = try exchange.verifyTicket(allocator, ticket);
    defer allocator.free(verified_sub);
    try testing.expectEqualStrings(subject, verified_sub);

    // Second verification should also succeed since single_use = false
    const verified_sub_2 = try exchange.verifyTicket(allocator, ticket);
    defer allocator.free(verified_sub_2);
    try testing.expectEqualStrings(subject, verified_sub_2);
}

test "TicketExchange: expired ticket verification fails" {
    const allocator = testing.allocator;

    const exchange = try TicketExchange.init(
        allocator,
        "test-ticket-signing-secret-key-32b",
        0, // ttl_seconds = 0
        true,
        null,
        false,
        null,
        false,
    );
    defer exchange.deinit();

    const subject = "user_charlie";
    const ticket = try exchange.generateTicket(allocator, subject, false);
    defer allocator.free(ticket);

    // Sleep for 1.1s to guarantee expiration
    std.Thread.sleep(1100 * std.time.ns_per_ms);

    try testing.expectError(error.TokenExpired, exchange.verifyTicket(allocator, ticket));
}

test "TicketExchange: validate anonymous subject" {
    const allocator = testing.allocator;

    // 1. Anonymous auth enabled
    const exchange_enabled = try TicketExchange.init(
        allocator,
        "test-ticket-signing-secret-key-32b",
        60,
        true,
        null,
        true, // anonymous_enabled = true
        "anon:",
        false,
    );
    defer exchange_enabled.deinit();

    // Valid anonymous subject
    try exchange_enabled.validateAnonymousSubject("anon:0123456789abcdef0123456789abcdef");

    // Invalid anonymous subjects
    try testing.expectError(error.InvalidAnonymousSubject, exchange_enabled.validateAnonymousSubject("anon:0123456789abcdef0123456789abcdeG")); // non-hex character 'G'
    try testing.expectError(error.InvalidAnonymousSubject, exchange_enabled.validateAnonymousSubject("anon:012345")); // too short
    try testing.expectError(error.InvalidAnonymousSubject, exchange_enabled.validateAnonymousSubject("user:0123456789abcdef0123456789abcdef")); // wrong prefix

    // 2. Anonymous auth disabled
    const exchange_disabled = try TicketExchange.init(
        allocator,
        "test-ticket-signing-secret-key-32b",
        60,
        true,
        null,
        false, // anonymous_enabled = false
        "anon:",
        false,
    );
    defer exchange_disabled.deinit();

    try testing.expectError(error.AnonymousDisabled, exchange_disabled.validateAnonymousSubject("anon:0123456789abcdef0123456789abcdef"));
}
