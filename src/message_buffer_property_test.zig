const std = @import("std");
const testing = std.testing;
const message_helpers = @import("message_handler_test_helpers.zig");
const AppTestContext = message_helpers.AppTestContext;
const createMockWebSocket = message_helpers.createMockWebSocket;
const routeWithArena = message_helpers.routeWithArena;
const msgpack = @import("msgpack_test_helpers.zig");

test "buffer: message deallocation after processing" {
    // This property test verifies that for any processed message,
    // the message buffer is deallocated after processing completes.

    // Use a tracking allocator to detect leaks
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.debug("Memory leak detected in message buffer deallocation test!", .{});
            @panic("Memory leak in Property 32 test");
        }
    }
    const allocator = gpa.allocator();

    var app: AppTestContext = undefined;
    try app.init(allocator, "buffer-basic", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    // Test 1: Single message processing
    {
        var ws = createMockWebSocket();
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        // Create a simple MessagePack message
        const message = try createTestMessage(allocator, 1, "test_ns", "p1", "value");
        defer allocator.free(message);

        // Parse the message
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        // Extract message info
        const msg_info = try app.handler.extractMessageInfo(parsed);
        try testing.expectEqualStrings("StoreSet", msg_info.type);

        // Route the message
        const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
        defer allocator.free(response);

        // Response should be a success response
        try testing.expect(response.len > 0);
    }

    // Test 2: Error cases also deallocate buffers
    {
        // Create invalid message (missing required fields)
        const invalid_message = try createInvalidMessage(allocator);
        defer allocator.free(invalid_message);

        var reader: std.Io.Reader = .fixed(invalid_message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        // This should fail but not leak memory (parsed.free is called)
        const result = app.handler.extractMessageInfo(parsed);
        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 3: Stress test with many messages
    {
        var ws = createMockWebSocket();
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        const iterations = 1000;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            const message = try createTestMessage(
                allocator,
                @as(u64, iter),
                "test_ns",
                "p1",
                "value",
            );
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try app.handler.extractMessageInfo(parsed);
            const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
            defer allocator.free(response);
        }
    }

    // Test 4: Mixed message types
    {
        var ws = createMockWebSocket();
        const sc = try app.openScopedConnection(&ws);
        defer sc.deinit();
        const conn = sc.conn;

        // StoreSet
        {
            const message = try createTestMessage(allocator, 1, "test_ns", "p2", "value1");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try app.handler.extractMessageInfo(parsed);
            const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
            defer allocator.free(response);
        }

        // StoreQuery
        {
            const message = try createQueryMessage(allocator, 2, "test_ns", "test");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try app.handler.extractMessageInfo(parsed);
            const response = try routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
            defer allocator.free(response);
        }
    }
}

// Helper function to create a test MessagePack message
fn createTestMessage(
    allocator: std.mem.Allocator,
    msg_id: u64,
    namespace: []const u8,
    path: []const u8,
    value: []const u8,
) ![]const u8 {
    return try msgpack.createStoreSetMessage(allocator, msg_id, namespace, &.{ "test", path, "val" }, value);
}

fn createQueryMessage(
    allocator: std.mem.Allocator,
    msg_id: u64,
    namespace: []const u8,
    table: []const u8,
) ![]const u8 {
    var filter = msgpack.Payload.mapPayload(allocator);
    defer filter.free(allocator);
    return try msgpack.createStoreQueryMessage(allocator, msg_id, namespace, table, filter);
}

fn createInvalidMessage(allocator: std.mem.Allocator) ![]const u8 {
    // Message missing required "id" field
    var buf: std.ArrayList(u8) = .{};
    try buf.appendSlice(allocator, "\x82"); // fixmap(2)
    try msgpack.writeString(allocator, &buf, "type");
    try msgpack.writeString(allocator, &buf, "StoreSet");
    try msgpack.writeString(allocator, &buf, "namespace");
    try msgpack.writeString(allocator, &buf, "test");
    return buf.toOwnedSlice(allocator);
}

test "buffer: concurrent message deallocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.debug("Memory leak in Property 32 concurrent test", .{});
            @panic("Memory leak in Property 32 concurrent test");
        }
    }
    const allocator = gpa.allocator();

    var app: AppTestContext = undefined;
    try app.init(allocator, "buffer-concurrent", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const ThreadContext = struct {
        app: *AppTestContext,
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: *ThreadContext) void {
            runInternal(ctx) catch |err| {
                std.debug.print("Message buffer stress test worker failed: {any}\n", .{err});
                @panic("Stress test worker error");
            };
        }

        fn runInternal(ctx: *ThreadContext) !void {
            var ws = createMockWebSocket();
            const sc = try ctx.app.openScopedConnection(&ws);
            defer sc.deinit();
            const conn = sc.conn;

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const message = try createTestMessage(
                    ctx.app.allocator,
                    @as(u64, i),
                    "test_ns",
                    "p1",
                    "value",
                );
                defer ctx.app.allocator.free(message);

                var reader: std.Io.Reader = .fixed(message);
                const parsed = try msgpack.decode(ctx.app.allocator, &reader);
                defer parsed.free(ctx.app.allocator);

                const msg_info = try ctx.app.handler.extractMessageInfo(parsed);
                const response = routeWithArena(&ctx.app.handler, ctx.app.allocator, conn, msg_info, parsed) catch |err| {
                    if (err == error.InvalidOperation) continue;
                    return err;
                };
                defer ctx.app.allocator.free(response);
            }
        }
    }.run;

    // Spawn multiple threads
    var contexts: [4]ThreadContext = undefined;
    var threads: [4]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{
            .app = &app,
            .iterations = 50,
        };
        threads[idx] = try std.Thread.spawn(.{}, worker, .{ctx});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }
}
