const std = @import("std");

const testing = std.testing;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const msgpack_lib = @import("msgpack");
const msgpack_utils = @import("msgpack_utils.zig");
const msgpack_helpers = @import("msgpack_test_helpers.zig");
const msgpack = struct {
    pub const Payload = msgpack_lib.Payload;
    pub const decode = msgpack_utils.decodePayload;
};

test "Property 32: Message buffer deallocation" {
    // **Property 32: Message buffer deallocation**
    // **Validates: Requirements 17.7**
    //
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

    // Initialize components needed for message handler
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    // Create temporary directory for storage engine
    const test_dir = "test-artifact/message_buffer/dealloc";
    std.fs.cwd().makePath(test_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage_engine = try StorageEngine.init(allocator, test_dir);
    defer storage_engine.deinit();

    var subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    // Test 1: Single message processing
    {
        var handler = try MessageHandler.init(
            allocator,
            &tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        defer handler.deinit();

        // Create a simple MessagePack message
        const message = try createTestMessage(allocator, "StoreSet", 1, "test_ns", "/path", "value");
        defer allocator.free(message);

        // Parse the message
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        // Extract message info
        const msg_info = try handler.extractMessageInfo(parsed);
        try testing.expectEqualStrings("StoreSet", msg_info.type);
        try testing.expectEqual(@as(u64, 1), msg_info.id);

        // Route message (this allocates response buffer)
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should be allocated
        try testing.expect(response.len > 0);
    }

    // Test 2: Multiple messages processed sequentially
    {
        var handler = try MessageHandler.init(
            allocator,
            &tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        defer handler.deinit();

        const num_messages = 100;
        var i: u64 = 0;
        while (i < num_messages) : (i += 1) {
            const message = try createTestMessage(allocator, "StoreSet", i, "test_ns", "/path", "value");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            try testing.expect(response.len > 0);
        }
    }

    // Test 3: Large message buffers
    {
        var handler = try MessageHandler.init(
            allocator,
            &tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        defer handler.deinit();

        // Create a large value
        const large_value = try allocator.alloc(u8, 10000);
        defer allocator.free(large_value);
        @memset(large_value, 'X');

        const message = try createTestMessage(allocator, "StoreSet", 1, "test_ns", "/path", large_value);
        defer allocator.free(message);

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        try testing.expect(response.len > 0);
    }

    // Test 4: Error cases also deallocate buffers
    {
        var handler = try MessageHandler.init(
            allocator,
            &tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        defer handler.deinit();

        // Create invalid message (missing required fields)
        const invalid_message = try createInvalidMessage(allocator);
        defer allocator.free(invalid_message);

        var reader: std.Io.Reader = .fixed(invalid_message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        // This should fail but not leak memory
        const result = handler.extractMessageInfo(parsed);
        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 5: Stress test with many messages
    {
        var handler = try MessageHandler.init(
            allocator,
            &tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        defer handler.deinit();

        const iterations = 1000;
        var iter: usize = 0;
        while (iter < iterations) : (iter += 1) {
            const message = try createTestMessage(
                allocator,
                "StoreSet",
                @as(u64, iter),
                "test_ns",
                "/path",
                "value",
            );
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);
        }
    }

    // Test 6: Mixed message types
    {
        var handler = try MessageHandler.init(
            allocator,
            &tracker,
            &request_handler,
            storage_engine,
            subscription_manager,
            cache,
        );
        defer handler.deinit();

        // StoreSet
        {
            const message = try createTestMessage(allocator, "StoreSet", 1, "test_ns", "/key1", "value1");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);
        }

        // StoreGet
        {
            const message = try createGetMessage(allocator, "StoreGet", 2, "test_ns", "/key1");
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);
        }
    }
}

// Helper function to create a test MessagePack message
fn createTestMessage(
    allocator: std.mem.Allocator,
    msg_type: []const u8,
    msg_id: u64,
    namespace: []const u8,
    path: []const u8,
    value: []const u8,
) ![]const u8 {
    _ = msg_type;
    return try msgpack_helpers.createStoreSetMessage(allocator, msg_id, namespace, path, value);
}

fn createGetMessage(
    allocator: std.mem.Allocator,
    _msg_type: []const u8,
    msg_id: u64,
    namespace: []const u8,
    path: []const u8,
) ![]const u8 {
    _ = _msg_type;
    return try msgpack_helpers.createStoreGetMessage(allocator, msg_id, namespace, path);
}

fn createInvalidMessage(allocator: std.mem.Allocator) ![]const u8 {
    // Message missing required "id" field
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try buf.append(allocator, 0x82); // fixmap(2)
    try msgpack_helpers.writeString(allocator, &buf, "type");
    try msgpack_helpers.writeString(allocator, &buf, "StoreSet");
    try msgpack_helpers.writeString(allocator, &buf, "namespace");
    try msgpack_helpers.writeString(allocator, &buf, "test");
    return buf.toOwnedSlice(allocator);
}

test "Property 32: Message buffer deallocation - concurrent processing" {
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

    // Initialize components
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);

    const test_dir = "test-artifact/message_buffer/concurrent";
    std.fs.cwd().makePath(test_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var storage_engine = try StorageEngine.init(allocator, test_dir);
    defer storage_engine.deinit();

    var subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    var cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    var handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        storage_engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    const ThreadContext = struct {
        handler: *MessageHandler,
        allocator: std.mem.Allocator,
        iterations: usize,
    };

    const worker = struct {
        fn run(ctx: *ThreadContext) void {
            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const message = createTestMessage(
                    ctx.allocator,
                    "StoreSet",
                    @as(u64, i),
                    "test_ns",
                    "/path",
                    "value",
                ) catch unreachable;
                defer ctx.allocator.free(message);

                var reader: std.Io.Reader = .fixed(message);
                const parsed = msgpack.decode(ctx.allocator, &reader) catch unreachable;
                defer parsed.free(ctx.allocator);

                const msg_info = ctx.handler.extractMessageInfo(parsed) catch unreachable;
                const response = ctx.handler.routeMessage(1, msg_info, parsed) catch unreachable;
                defer ctx.allocator.free(response);
            }
        }
    }.run;

    // Spawn multiple threads
    var contexts: [4]ThreadContext = undefined;
    var threads: [4]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{
            .handler = handler,
            .allocator = allocator,
            .iterations = 50,
        };
        threads[idx] = try std.Thread.spawn(.{}, worker, .{ctx});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }
}
