const std = @import("std");

const testing = std.testing;
const MessageHandler = @import("message_handler.zig").MessageHandler;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const msgpack = @import("msgpack_test_helpers.zig");
const routeWithArena = @import("message_handler_test_helpers.zig").routeWithArena;

const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const schema_helpers = @import("schema_test_helpers.zig");

fn makeField(name: []const u8, field_type: schema_parser.FieldType, required: bool) schema_parser.Field {
    return .{
        .name = name,
        .sql_type = field_type,
        .required = required,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

fn setupEngineWithSchema(allocator: std.mem.Allocator, memory_strategy: *MemoryStrategy, test_dir: []const u8, table_name: []const u8, out_schema: *?*schema_parser.Schema) !*StorageEngine {
    var fields_arr = try allocator.alloc(schema_parser.Field, 1);
    defer allocator.free(fields_arr);
    fields_arr[0] = makeField("val", .text, false);
    const table = schema_parser.Table{ .name = table_name, .fields = fields_arr };

    const schema_ptr = try allocator.create(schema_parser.Schema);
    errdefer allocator.destroy(schema_ptr);

    const tables = try allocator.alloc(schema_parser.Table, 1);
    errdefer allocator.free(tables); // zwanzig-disable-line: deinit-lifecycle

    tables[0] = try table.clone(allocator);
    errdefer schema_parser.freeTable(allocator, tables[0]);

    schema_ptr.* = .{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };
    errdefer allocator.free(schema_ptr.version);

    out_schema.* = schema_ptr;

    const engine = try StorageEngine.init(allocator, memory_strategy, test_dir, schema_ptr, .{});
    errdefer engine.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);
    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.execDDL(ddl_z);

    return engine;
}

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

    // Initialize components needed for message handler
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();

    var tracker: ViolationTracker = undefined;
    tracker.init(allocator, 10);
    defer tracker.deinit();

    // Create temporary directory for storage engine
    var context = try schema_helpers.TestContext.init(allocator, "buffer-dealloc");
    defer context.deinit();
    const test_dir = context.test_dir;

    var test_schema: ?*schema_parser.Schema = null;
    var storage_engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema);
    defer {
        storage_engine.deinit();
        if (test_schema) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    var subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();
    // Test 1: Single message processing
    {
        var handler = try MessageHandler.init(
            allocator,
            &memory_strategy,
            &tracker,
            storage_engine,
            subscription_manager,
            .{},
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
        const response = try routeWithArena(handler, allocator, 1, msg_info, parsed);
        defer allocator.free(response);

        // Response should be allocated
        try testing.expect(response.len > 0);
    }

    // Test 2: Multiple messages processed sequentially
    {
        var handler = try MessageHandler.init(
            allocator,
            &memory_strategy,
            &tracker,
            storage_engine,
            subscription_manager,
            .{},
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
            const response = try routeWithArena(handler, allocator, 1, msg_info, parsed);
            defer allocator.free(response);

            try testing.expect(response.len > 0);
        }
    }

    // Test 3: Large message buffers
    {
        var handler = try MessageHandler.init(
            allocator,
            &memory_strategy,
            &tracker,
            storage_engine,
            subscription_manager,
            .{},
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
        const response = try routeWithArena(handler, allocator, 1, msg_info, parsed);
        defer allocator.free(response);

        try testing.expect(response.len > 0);
    }

    // Test 4: Error cases also deallocate buffers
    {
        var handler = try MessageHandler.init(
            allocator,
            &memory_strategy,
            &tracker,
            storage_engine,
            subscription_manager,
            .{},
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
            &memory_strategy,
            &tracker,
            storage_engine,
            subscription_manager,
            .{},
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
            const response = try routeWithArena(handler, allocator, 1, msg_info, parsed);
            defer allocator.free(response);
        }
    }

    // Test 6: Mixed message types
    {
        var handler = try MessageHandler.init(
            allocator,
            &memory_strategy,
            &tracker,
            storage_engine,
            subscription_manager,
            .{},
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
            const response = try routeWithArena(handler, allocator, 1, msg_info, parsed);
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
            const response = try routeWithArena(handler, allocator, 1, msg_info, parsed);
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
    return try msgpack.createStoreSetMessage(allocator, msg_id, namespace, &.{ "test", path, "val" }, value);
}

fn createGetMessage(
    allocator: std.mem.Allocator,
    _msg_type: []const u8,
    msg_id: u64,
    namespace: []const u8,
    path: []const u8,
) ![]const u8 {
    _ = _msg_type;
    return try msgpack.createStoreGetMessage(allocator, msg_id, namespace, &.{ "test", path });
}

fn createInvalidMessage(allocator: std.mem.Allocator) ![]const u8 {
    // Message missing required "id" field
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    try buf.append(allocator, 0x82); // fixmap(2)
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

    // Initialize components
    var memory_strategy: MemoryStrategy = undefined;
    try memory_strategy.init(allocator);
    defer memory_strategy.deinit();

    var tracker: ViolationTracker = undefined;
    tracker.init(allocator, 10);
    defer tracker.deinit();

    var context = try schema_helpers.TestContext.init(allocator, "buffer-concurrent");
    defer context.deinit();
    const test_dir = context.test_dir;

    var test_schema_1: ?*schema_parser.Schema = null;
    var storage_engine = try setupEngineWithSchema(allocator, &memory_strategy, test_dir, "test", &test_schema_1);
    defer {
        storage_engine.deinit();
        if (test_schema_1) |s| {
            schema_parser.freeSchema(allocator, s.*);
            allocator.destroy(s);
        }
    }
    var subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();
    var handler = try MessageHandler.init(allocator, &memory_strategy, &tracker, storage_engine, subscription_manager, .{});
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
                ) catch unreachable; // zwanzig-disable-line: swallowed-error
                defer ctx.allocator.free(message);

                var reader: std.Io.Reader = .fixed(message);
                const parsed = msgpack.decode(ctx.allocator, &reader) catch unreachable; // zwanzig-disable-line: swallowed-error
                defer parsed.free(ctx.allocator);

                const msg_info = ctx.handler.extractMessageInfo(parsed) catch unreachable; // zwanzig-disable-line: swallowed-error
                const response = routeWithArena(ctx.handler, ctx.allocator, 1, msg_info, parsed) catch |err| {
                    if (err == error.InvalidOperation) continue;
                    unreachable;
                };
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
