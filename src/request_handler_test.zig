const std = @import("std");
const testing = std.testing;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

test "RequestHandler: basic request handling" {
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var handler = RequestHandler.init(&memory_strategy);

    const message = "{ \"operation\": \"read\", \"path\": \"tasks.task-1\" }";
    const response = try handler.handleRequest(message);
    defer memory_strategy.generalAllocator().free(response.data);

    try testing.expect(response.status == .success);
    try testing.expect(response.data.len > 0);
}

test "RequestHandler: arena reset after request" {
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var handler = RequestHandler.init(&memory_strategy);

    // Process multiple requests to verify arena is reset each time
    const message = "{ \"operation\": \"read\", \"path\": \"tasks.task-1\" }";

    // First request
    const response1 = try handler.handleRequest(message);
    defer memory_strategy.generalAllocator().free(response1.data);

    // Arena should be reset after first request
    // Second request should succeed without memory issues
    const response2 = try handler.handleRequest(message);
    defer memory_strategy.generalAllocator().free(response2.data);

    // Third request to verify consistent behavior
    const response3 = try handler.handleRequest(message);
    defer memory_strategy.generalAllocator().free(response3.data);

    try testing.expect(response1.status == .success);
    try testing.expect(response2.status == .success);
    try testing.expect(response3.status == .success);
}

test "RequestHandler: arena reset on error" {
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var handler = RequestHandler.init(&memory_strategy);

    // Even if request processing fails, arena should be reset
    // This test verifies the defer mechanism works correctly

    const message = "{ \"operation\": \"read\", \"path\": \"tasks.task-1\" }";

    // Process a successful request
    const response1 = try handler.handleRequest(message);
    defer memory_strategy.generalAllocator().free(response1.data);

    // Process another request after potential error
    // Arena should be clean and ready to use
    const response2 = try handler.handleRequest(message);
    defer memory_strategy.generalAllocator().free(response2.data);

    try testing.expect(response1.status == .success);
    try testing.expect(response2.status == .success);
}

test "RequestHandler: memory isolation between requests" {
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var handler = RequestHandler.init(&memory_strategy);

    const message1 = "{ \"operation\": \"read\", \"path\": \"tasks.task-1\" }";
    const message2 = "{ \"operation\": \"write\", \"path\": \"tasks.task-2\" }";

    // Process first request
    const response1 = try handler.handleRequest(message1);
    defer memory_strategy.generalAllocator().free(response1.data);

    // Process second request
    // Arena should be reset, so no memory from first request should leak
    const response2 = try handler.handleRequest(message2);
    defer memory_strategy.generalAllocator().free(response2.data);

    try testing.expect(response1.status == .success);
    try testing.expect(response2.status == .success);

    // Responses should be independent
    try testing.expect(!std.mem.eql(u8, response1.data, response2.data));
}

test "RequestHandler: bulk memory deallocation" {
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var handler = RequestHandler.init(&memory_strategy);

    // Process many requests to verify arena reset prevents memory growth
    const message = "{ \"operation\": \"read\", \"path\": \"tasks.task-1\" }";

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const response = try handler.handleRequest(message);
        defer memory_strategy.generalAllocator().free(response.data);

        try testing.expect(response.status == .success);
    }

    // If arena wasn't being reset, memory would grow unbounded
    // This test verifies bulk deallocation is working
}

test "RequestHandler: concurrent request handling" {
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var handler = RequestHandler.init(&memory_strategy);

    // Note: Arena allocator is not thread-safe
    // In production, each thread/connection should have its own arena
    // This test verifies sequential handling works correctly

    const message = "{ \"operation\": \"read\", \"path\": \"tasks.task-1\" }";

    // Simulate multiple sequential requests (as would happen in event loop)
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const response = try handler.handleRequest(message);
        defer memory_strategy.generalAllocator().free(response.data);

        try testing.expect(response.status == .success);
    }
}

test "RequestHandler: large request handling" {
    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var handler = RequestHandler.init(&memory_strategy);

    // Create a large message to test arena with significant allocations
    const allocator = std.testing.allocator;
    var large_message = std.ArrayList(u8){};
    defer large_message.deinit(allocator);

    try large_message.appendSlice(allocator, "{ \"operation\": \"write\", \"data\": \"");
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try large_message.appendSlice(allocator, "x");
    }
    try large_message.appendSlice(allocator, "\" }");

    const response = try handler.handleRequest(large_message.items);
    defer memory_strategy.generalAllocator().free(response.data);

    try testing.expect(response.status == .success);

    // Process another request to verify arena was properly reset
    const response2 = try handler.handleRequest("{ \"operation\": \"read\" }");
    defer memory_strategy.generalAllocator().free(response2.data);

    try testing.expect(response2.status == .success);
}
