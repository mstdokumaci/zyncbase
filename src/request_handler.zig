const std = @import("std");
const Allocator = std.mem.Allocator;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

/// RequestHandler manages the lifecycle of WebSocket requests and integrates
/// arena allocator reset for efficient memory management.
///
/// Each request uses the arena allocator for temporary allocations (parsing,
/// response building, temporary buffers) and resets it after completion to
/// free all temporary memory in bulk.
pub const RequestHandler = struct {
    memory_strategy: *MemoryStrategy,

    /// Initialize the request handler with a memory strategy
    pub fn init(memory_strategy: *MemoryStrategy) RequestHandler {
        return RequestHandler{
            .memory_strategy = memory_strategy,
        };
    }

    /// Request context holds temporary data for a single request
    pub const RequestContext = struct {
        arena_allocator: Allocator,
        message: []const u8,
        response_buffer: std.ArrayList(u8),

        pub fn init(arena_allocator: Allocator, message: []const u8) !RequestContext {
            return RequestContext{
                .arena_allocator = arena_allocator,
                .message = message,
                .response_buffer = std.ArrayList(u8){},
            };
        }
    };

    /// Response type for request handling
    pub const Response = struct {
        data: []const u8,
        status: ResponseStatus,

        pub const ResponseStatus = enum {
            success,
            @"error",
            unauthorized,
            invalid_request,
        };
    };

    /// Handle a WebSocket message request
    /// PRECONDITION: message is valid byte array
    /// POSTCONDITION: Response returned, arena allocator reset
    ///
    /// This function demonstrates the request lifecycle with arena allocator:
    /// 1. Use arena allocator for all temporary allocations
    /// 2. Process the request
    /// 3. Build response
    /// 4. Reset arena to free all temporary memory in bulk
    pub fn handleRequest(self: *RequestHandler, message: []const u8) !Response {
        // Get arena allocator for this request
        const arena_allocator = self.memory_strategy.arenaAllocator();

        // Ensure arena is reset after request completes (even on error)
        defer self.memory_strategy.resetArena();

        // Create request context with arena allocator
        var ctx = try RequestContext.init(arena_allocator, message);

        // Parse request using arena allocator (temporary allocation)
        const parsed_request = try self.parseRequest(&ctx);

        // Process request (may use arena for temporary data structures)
        const result = try self.processRequest(&ctx, parsed_request);

        // Build response using arena allocator (temporary allocation)
        const response_data = try self.buildResponse(&ctx, result);

        // Copy response data to long-lived memory before arena reset
        // Use general-purpose allocator for response that outlives the request
        const gpa = self.memory_strategy.generalAllocator();
        const response_copy = try gpa.dupe(u8, response_data);

        return Response{
            .data = response_copy,
            .status = .success,
        };
        // Arena is automatically reset here by defer
    }

    /// Parse request from raw message bytes
    /// Uses arena allocator for temporary parsing structures
    fn parseRequest(self: *RequestHandler, ctx: *RequestContext) !ParsedRequest {
        _ = self;

        // Allocate temporary parsing buffer using arena
        const parse_buffer = try ctx.arena_allocator.alloc(u8, ctx.message.len);

        // Copy message to parse buffer (temporary)
        @memcpy(parse_buffer, ctx.message);

        // Simple parsing to extract operation and path from JSON-like message
        // This is a simplified parser for demonstration purposes
        var operation: ParsedRequest.Operation = .read;
        var path: []const u8 = "default";

        // Look for "operation": "read|write|delete|subscribe"
        if (std.mem.indexOf(u8, parse_buffer, "\"operation\": \"read\"")) |_| {
            operation = .read;
        } else if (std.mem.indexOf(u8, parse_buffer, "\"operation\": \"write\"")) |_| {
            operation = .write;
        } else if (std.mem.indexOf(u8, parse_buffer, "\"operation\": \"delete\"")) |_| {
            operation = .delete;
        } else if (std.mem.indexOf(u8, parse_buffer, "\"operation\": \"subscribe\"")) |_| {
            operation = .subscribe;
        }

        // Look for "path": "..."
        if (std.mem.indexOf(u8, parse_buffer, "\"path\": \"")) |start_idx| {
            const path_start = start_idx + "\"path\": \"".len;
            if (std.mem.indexOfPos(u8, parse_buffer, path_start, "\"")) |end_idx| {
                path = parse_buffer[path_start..end_idx];
            }
        }

        return ParsedRequest{
            .operation = operation,
            .namespace = "default",
            .path = path,
        };
    }

    /// Process the parsed request
    /// May use arena allocator for temporary data structures
    fn processRequest(self: *RequestHandler, ctx: *RequestContext, request: ParsedRequest) !ProcessResult {
        _ = self;

        // Build response data based on operation and path using arena allocator
        var result_buffer = std.ArrayList(u8){};
        try result_buffer.appendSlice(ctx.arena_allocator, "{ \"operation\": \"");
        try result_buffer.appendSlice(ctx.arena_allocator, @tagName(request.operation));
        try result_buffer.appendSlice(ctx.arena_allocator, "\", \"path\": \"");
        try result_buffer.appendSlice(ctx.arena_allocator, request.path);
        try result_buffer.appendSlice(ctx.arena_allocator, "\", \"status\": \"completed\" }");

        return ProcessResult{
            .success = true,
            .data = result_buffer.items,
        };
    }

    /// Build response from process result
    /// Uses arena allocator for temporary response building
    fn buildResponse(self: *RequestHandler, ctx: *RequestContext, result: ProcessResult) ![]const u8 {
        _ = self;

        // Build response using arena allocator (temporary)
        try ctx.response_buffer.appendSlice(ctx.arena_allocator, "{ \"result\": ");
        try ctx.response_buffer.appendSlice(ctx.arena_allocator, result.data);
        try ctx.response_buffer.appendSlice(ctx.arena_allocator, " }");

        return ctx.response_buffer.items;
    }

    /// Parsed request structure
    const ParsedRequest = struct {
        operation: Operation,
        namespace: []const u8,
        path: []const u8,

        const Operation = enum {
            read,
            write,
            delete,
            subscribe,
        };
    };

    /// Process result structure
    const ProcessResult = struct {
        success: bool,
        data: []const u8,
    };
};
