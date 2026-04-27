const std = @import("std");
const testing = std.testing;
const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const routeWithArena = helpers.routeWithArena;
const msgpack = @import("msgpack_test_helpers.zig");
const store_helpers = @import("store_test_helpers.zig");
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
        const sc = try app.setupMockConnection();
        defer sc.deinit();
        const conn = sc.conn;

        // Create a simple MessagePack message
        const tbl = try app.tableMetadata("test");
        const field_idx = tbl.getFieldIndex("val") orelse return error.UnknownField;
        const message = try store_helpers.createStoreSetFieldMessage(allocator, 1, 1, tbl.index, 1, field_idx, "value");
        defer allocator.free(message);

        // Parse the message
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = try routeWithArena(&app.handler, allocator, conn, parsed);
        defer allocator.free(response);

        // Response should be a success response
        try testing.expect(response.len > 0);
    }

    // Test 2: Error cases also deallocate buffers
    {
        const sc = try app.setupMockConnection();
        defer sc.deinit();
        const conn = sc.conn;

        // Create invalid message (missing required fields)
        const invalid_message = try store_helpers.createInvalidStoreSetMessageMissingId(allocator, 1);
        defer allocator.free(invalid_message);

        var reader: std.Io.Reader = .fixed(invalid_message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response = routeWithArena(&app.handler, allocator, conn, parsed);
        try testing.expectError(error.MissingRequiredFields, response);
    }

    // Test 3: Stress test with many messages
    {
        const sc = try app.setupMockConnection();
        defer sc.deinit();
        const conn = sc.conn;

        const iterations = 1000;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            const tbl = try app.tableMetadata("test");
            const field_idx = tbl.getFieldIndex("val") orelse return error.UnknownField;
            const message = try store_helpers.createStoreSetFieldMessage(
                allocator,
                @as(u64, iter),
                1,
                tbl.index,
                1,
                field_idx,
                "value",
            );
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const response = try routeWithArena(&app.handler, allocator, conn, parsed);
            defer allocator.free(response);
        }
    }

    // Test 4: Mixed message types
    {
        const sc = try app.setupMockConnection();
        defer sc.deinit();
        const conn = sc.conn;

        // StoreSet
        {
            const tbl = try app.tableMetadata("test");
            const field_idx = tbl.getFieldIndex("val") orelse return error.UnknownField;
            const message = try store_helpers.createStoreSetFieldMessage(allocator, 1, 1, tbl.index, 2, field_idx, "value1");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const response = try routeWithArena(&app.handler, allocator, conn, parsed);
            defer allocator.free(response);
        }

        // StoreQuery
        {
            const tbl = try app.tableMetadata("test");
            const msg = try store_helpers.createStoreQueryMessageWithEmptyFilter(allocator, 2, 1, tbl.index);
            defer allocator.free(msg);

            var reader: std.Io.Reader = .fixed(msg);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const response = try routeWithArena(&app.handler, allocator, conn, parsed);
            defer allocator.free(response);
        }
    }
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
            const sc = try ctx.app.setupMockConnection();
            defer sc.deinit();
            const conn = sc.conn;

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const tbl = try ctx.app.tableMetadata("test");
                const field_idx = tbl.getFieldIndex("val") orelse return error.UnknownField;
                const message = try store_helpers.createStoreSetFieldMessage(
                    ctx.app.allocator,
                    @as(u64, i),
                    1,
                    tbl.index,
                    1,
                    field_idx,
                    "value",
                );
                defer ctx.app.allocator.free(message);

                var reader: std.Io.Reader = .fixed(message);
                const parsed = try msgpack.decode(ctx.app.allocator, &reader);
                defer parsed.free(ctx.app.allocator);

                const response = routeWithArena(&ctx.app.handler, ctx.app.allocator, conn, parsed) catch |err| {
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
