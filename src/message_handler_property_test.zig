const std = @import("std");
const testing = std.testing;

const helpers = @import("app_test_helpers.zig");
const AppTestContext = helpers.AppTestContext;
const routeWithArena = helpers.routeWithArena;
const msgpack = @import("msgpack_test_helpers.zig");
const store_helpers = @import("store_test_helpers.zig");
const storage_engine = @import("storage_engine.zig");

const table_defs = [_]helpers.TableDef{
    .{ .name = "items", .fields = &.{ "value", "tags" } },
};

fn routeBytes(app: *AppTestContext, conn: anytype, allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return try routeWithArena(&app.handler, allocator, conn, message);
}

fn decodeResponse(allocator: std.mem.Allocator, response: []const u8) !msgpack.Payload {
    var reader: std.Io.Reader = .fixed(response);
    return try msgpack.decode(allocator, &reader);
}

fn expectResponseType(allocator: std.mem.Allocator, response: []const u8, expected: []const u8) !void {
    const parsed = try decodeResponse(allocator, response);
    defer parsed.free(allocator);

    const value = (try msgpack.getMapValue(parsed, "type")) orelse return error.TestExpectedError;
    try testing.expectEqualStrings(expected, value.str.value());
}

fn expectResponseId(allocator: std.mem.Allocator, response: []const u8, expected: u64) !void {
    const parsed = try decodeResponse(allocator, response);
    defer parsed.free(allocator);

    const value = (try msgpack.getMapValue(parsed, "id")) orelse return error.TestExpectedError;
    try testing.expect(value == .uint);
    try testing.expectEqual(expected, value.uint);
}

fn expectErrorCode(allocator: std.mem.Allocator, response: []const u8, expected: []const u8) !void {
    const parsed = try decodeResponse(allocator, response);
    defer parsed.free(allocator);

    const resp_type = (try msgpack.getMapValue(parsed, "type")) orelse return error.TestExpectedError;
    try testing.expectEqualStrings("error", resp_type.str.value());

    const code = (try msgpack.getMapValue(parsed, "code")) orelse return error.TestExpectedError;
    try testing.expectEqualStrings(expected, code.str.value());
}

test "message: representative frames route at protocol boundary" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-route", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const table = try app.tableMetadata("items");
    const field_index = table.getFieldIndex("value") orelse return error.UnknownField;

    {
        const message = try store_helpers.createStoreSetFieldMessage(allocator, 11, 1, table.index, 1, field_index, "value-a");
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);

        try expectResponseType(allocator, response, "ok");
        try expectResponseId(allocator, response, 11);
    }

    {
        const message = try store_helpers.createStoreQueryMessageWithEmptyFilter(allocator, 12, 1, table.index);
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);

        try expectResponseType(allocator, response, "ok");
        try expectResponseId(allocator, response, 12);
    }

    {
        const message = try store_helpers.createCustomMessage(allocator, 13, "UnknownType", 1, table.index, &.{});
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);

        try expectErrorCode(allocator, response, "INTERNAL_ERROR");
        try expectResponseId(allocator, response, 13);
    }
}

test "message: response id is preserved across routed requests" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-correlation", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const table = try app.tableMetadata("items");
    const field_index = table.getFieldIndex("value") orelse return error.UnknownField;

    {
        const message = try store_helpers.createStoreSetFieldMessage(allocator, 101, 1, table.index, 1, field_index, "value-b");
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);
        try expectResponseId(allocator, response, 101);
    }

    {
        const message = try store_helpers.createStoreQueryMessageWithEmptyFilter(allocator, 202, 1, table.index);
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);
        try expectResponseId(allocator, response, 202);
    }

    {
        const message = try store_helpers.createCustomMessage(allocator, 303, "InvalidType", 1, table.index, &.{});
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);
        try expectResponseId(allocator, response, 303);
    }
}

test "message: invalid envelopes fail before store dispatch" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-invalid-envelope", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();

    const missing_id = try store_helpers.createInvalidStoreSetMessageMissingId(allocator, 1);
    defer allocator.free(missing_id);

    try testing.expectError(error.MissingRequiredFields, routeWithArena(&app.handler, allocator, sc.conn, missing_id));
}

test "message: repeated routed requests release per-message allocations" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-lifetime", &table_defs);
    defer app.deinit();

    const sc = try app.setupMockConnection();
    defer sc.deinit();
    const table = try app.tableMetadata("items");
    const field_index = table.getFieldIndex("value") orelse return error.UnknownField;

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const msg_id: u64 = @intCast(i + 1);
        const doc_id: storage_engine.DocId = @intCast(i + 1);
        const message = try store_helpers.createStoreSetFieldMessage(allocator, msg_id, 1, table.index, doc_id, field_index, "value-c");
        defer allocator.free(message);

        const response = try routeBytes(&app, sc.conn, allocator, message);
        defer allocator.free(response);

        try expectResponseType(allocator, response, "ok");
        try expectResponseId(allocator, response, msg_id);
    }
}

test "message: concurrent routed requests release response allocations" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "handler-property-concurrent-lifetime", &table_defs);
    defer app.deinit();

    const table = try app.tableMetadata("items");
    const field_index = table.getFieldIndex("value") orelse return error.UnknownField;

    const ThreadContext = struct {
        app: *AppTestContext,
        table_index: usize,
        field_index: usize,
        thread_index: usize,
        iterations: usize,
        failure: ?anyerror = null,

        fn run(ctx: *@This()) void {
            runInternal(ctx) catch |err| {
                std.log.err("message routing property failed: {}", .{err});
                ctx.failure = err;
            };
        }

        fn runInternal(ctx: *@This()) !void {
            const thread_allocator = ctx.app.allocator;
            const sc = try ctx.app.setupMockConnection();
            defer sc.deinit();

            var i: usize = 0;
            while (i < ctx.iterations) : (i += 1) {
                const raw_id = ctx.thread_index * 1000 + i + 1;
                const msg_id: u64 = @intCast(raw_id);
                const doc_id: storage_engine.DocId = @intCast(raw_id);

                const message = try store_helpers.createStoreSetFieldMessage(
                    thread_allocator,
                    msg_id,
                    1,
                    ctx.table_index,
                    doc_id,
                    ctx.field_index,
                    "value-d",
                );
                defer thread_allocator.free(message);

                const response = try routeBytes(ctx.app, sc.conn, thread_allocator, message);
                defer thread_allocator.free(response);

                try expectResponseType(thread_allocator, response, "ok");
                try expectResponseId(thread_allocator, response, msg_id);
            }
        }
    };

    var contexts: [4]ThreadContext = undefined;
    var threads: [4]std.Thread = undefined;

    for (&contexts, 0..) |*ctx, idx| {
        ctx.* = .{
            .app = &app,
            .table_index = table.index,
            .field_index = field_index,
            .thread_index = idx,
            .iterations = 8,
        };
        threads[idx] = try std.Thread.spawn(.{}, ThreadContext.run, .{ctx});
    }

    for (threads) |thread| {
        thread.join();
    }

    for (contexts) |ctx| {
        if (ctx.failure) |err| return err;
    }
}
