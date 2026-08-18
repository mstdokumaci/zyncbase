const std = @import("std");

const typed = @import("../typed/types.zig");
const ticket_exchange = @import("ticket_exchange.zig");

const testing = std.testing;
const TicketExchange = ticket_exchange.TicketExchange;

const empty_claims: std.StringHashMapUnmanaged(typed.Value) = .{};
const empty_claims_mapping: std.StringHashMapUnmanaged([]const u8) = .{};

test "TicketExchange: generate and verify ticket" {
    const allocator = std.heap.smp_allocator;

    const exchange = try TicketExchange.init(
        testing.io,
        allocator,
        "test-ticket-signing-secret-key-32b",
        60,
        null,
        false,
        null,
        false,
        &empty_claims_mapping,
    );
    defer exchange.deinit();

    const subject = "user_alice";
    const ticket = try exchange.generateTicket(allocator, subject, false, &empty_claims);
    defer allocator.free(ticket);

    var verified_session = try exchange.verifyTicket(allocator, ticket);
    defer verified_session.deinit(allocator);

    try testing.expectEqualStrings(subject, verified_session.external_id);
    try testing.expect(!verified_session.is_anonymous);

    try testing.expectError(error.AuthFailed, exchange.verifyTicket(allocator, ticket));
}

test "TicketExchange: expired ticket verification fails" {
    const allocator = std.heap.smp_allocator;

    const exchange = try TicketExchange.init(
        testing.io,
        allocator,
        "test-ticket-signing-secret-key-32b",
        0, // ttl_seconds = 0
        null,
        false,
        null,
        false,
        &empty_claims_mapping,
    );
    defer exchange.deinit();

    const subject = "user_charlie";
    const ticket = try exchange.generateTicket(allocator, subject, false, &empty_claims);
    defer allocator.free(ticket);

    try testing.expectError(error.TokenExpired, exchange.verifyTicket(allocator, ticket));
}

test "TicketExchange: validate anonymous subject" {
    const allocator = std.heap.smp_allocator;

    // 1. Anonymous auth enabled
    const exchange_enabled = try TicketExchange.init(
        testing.io,
        allocator,
        "test-ticket-signing-secret-key-32b",
        60,
        null,
        true, // anonymous_enabled = true
        "anon:",
        false,
        &empty_claims_mapping,
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
        testing.io,
        allocator,
        "test-ticket-signing-secret-key-32b",
        60,
        null,
        false, // anonymous_enabled = false
        "anon:",
        false,
        &empty_claims_mapping,
    );
    defer exchange_disabled.deinit();

    try testing.expectError(error.AnonymousDisabled, exchange_disabled.validateAnonymousSubject("anon:0123456789abcdef0123456789abcdef"));
}
