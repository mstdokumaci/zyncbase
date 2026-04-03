const std = @import("std");
const testing = std.testing;
const helpers = @import("message_handler_test_helpers.zig");
const msgpack = @import("msgpack_test_helpers.zig");
const query_parser = @import("query_parser.zig");
const ColumnValue = @import("storage_engine.zig").ColumnValue;
const Payload = @import("msgpack_utils.zig").Payload;

test "WriteCoordinator: basic coordinateSet" {
    const allocator = testing.allocator;
    var app = try helpers.AppTestContext.init(allocator, "wc-basic", &.{
        .{ .name = "test", .fields = &.{"status"} },
    });
    defer app.deinit();

    const wc = app.write_coordinator;
    const namespace = "ns1";
    const table = "test";
    const doc_id = "doc1";

    // Use an arena for request-scoped operations to hit the real-world pattern
    var arena_alloc = std.heap.ArenaAllocator.init(allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    // 1. Initial insert
    {
        const val = try msgpack.Payload.strToPayload("active", arena);
        const fields = [_]ColumnValue{
            .{ .name = "status", .value = val },
        };
        try wc.coordinateSet(arena, namespace, table, doc_id, &fields);
        try app.storage_engine.flushPendingWrites();

        // Verify storage
        var managed = try app.storage_engine.selectDocument(allocator, table, doc_id, namespace);
        defer managed.deinit();
        try testing.expect(managed.value != null);
    }
}

test "WriteCoordinator: regression - leave notification on update" {
    const allocator = testing.allocator;
    var app = try helpers.AppTestContext.init(allocator, "wc-regression", &.{
        .{ .name = "test", .fields = &.{"status"} },
    });
    defer app.deinit();

    const wc = app.write_coordinator;
    const sub_engine = app.subscription_engine;
    const namespace = "ns1";
    const table = "test";
    const doc_id = "doc1";

    // 1. Create a subscription for status == "active"
    var ws = helpers.createMockWebSocket();
    try app.manager.onOpen(&ws);
    defer app.manager.onClose(&ws, 1000, "normal");

    // Use an arena for all test setup payloads
    var setup_arena_alloc = std.heap.ArenaAllocator.init(allocator);
    defer setup_arena_alloc.deinit();
    const setup_arena = setup_arena_alloc.allocator();

    // Construct filter payload: { "conditions": [ ["status", 0, "active"] ] }
    var filter_payload = Payload.mapPayload(setup_arena);

    var cond_arr = try setup_arena.alloc(Payload, 1);
    var cond_tuple = try setup_arena.alloc(Payload, 3);
    cond_tuple[0] = try Payload.strToPayload("status", setup_arena);
    cond_tuple[1] = Payload.uintToPayload(0); // .eq
    cond_tuple[2] = try Payload.strToPayload("active", setup_arena);

    cond_arr[0] = Payload{ .arr = cond_tuple };
    try filter_payload.mapPut("conditions", Payload{ .arr = cond_arr });

    // Note: parseQueryFilter clones the payload, so we can use setup_arena
    const filter = try query_parser.parseQueryFilter(allocator, app.schema_manager, table, filter_payload);
    defer filter.deinit(allocator);

    _ = try sub_engine.subscribe(namespace, table, filter, ws.getConnId(), 101);

    // 2. Initial write: status = "active"
    {
        var arena_alloc = std.heap.ArenaAllocator.init(allocator);
        defer arena_alloc.deinit();
        const arena = arena_alloc.allocator();

        const val = try msgpack.Payload.strToPayload("active", arena);
        const fields = [_]ColumnValue{
            .{ .name = "status", .value = val },
        };
        try wc.coordinateSet(arena, namespace, table, doc_id, &fields);
        // Should have received an "Enter" (StoreDelta)
    }

    // 3. Update write: status = "inactive"
    {
        var arena_alloc = std.heap.ArenaAllocator.init(allocator);
        defer arena_alloc.deinit();
        const arena = arena_alloc.allocator();

        const val = try msgpack.Payload.strToPayload("inactive", arena);
        const fields = [_]ColumnValue{
            .{ .name = "status", .value = val },
        };

        try wc.coordinateSet(arena, namespace, table, doc_id, &fields);
    }
}
