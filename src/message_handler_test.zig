const std = @import("std");
const testing = std.testing;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const ConnectionRegistry = @import("message_handler.zig").ConnectionRegistry;
const WebSocket = @import("uwebsockets_wrapper.zig").WebSocket;

test "Connection - init and deinit" {
    const allocator = testing.allocator;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    // Let pool handle memory free when ref_count goes to 0 by releasing it:
    defer state.release(allocator);

    try testing.expectEqual(@as(u64, 1), state.id);
    try testing.expectEqual(@as(?[]const u8, null), state.user_id);
    try testing.expectEqualStrings("default", state.namespace);
    try testing.expectEqual(@as(usize, 0), state.subscription_ids.items.len);
}

test "Connection - add subscription IDs" {
    const allocator = testing.allocator;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    defer state.release(allocator);

    try state.subscription_ids.append(state.allocator, 100);
    try state.subscription_ids.append(state.allocator, 200);
    try state.subscription_ids.append(state.allocator, 300);

    try testing.expectEqual(@as(usize, 3), state.subscription_ids.items.len);
    try testing.expectEqual(@as(u64, 100), state.subscription_ids.items[0]);
    try testing.expectEqual(@as(u64, 200), state.subscription_ids.items[1]);
    try testing.expectEqual(@as(u64, 300), state.subscription_ids.items[2]);
}

test "ConnectionRegistry - init and deinit" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 0), snap.count());
    }
}

test "ConnectionRegistry - add and get connection" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    try registry.add(1, state);

    const retrieved = try registry.acquireConnection(1);
    defer retrieved.release(allocator);
    try testing.expectEqual(@as(u64, 1), retrieved.id);
    try testing.expectEqualStrings("default", retrieved.namespace);
}

test "ConnectionRegistry - get non-existent connection" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const result = registry.acquireConnection(999);
    try testing.expectError(error.ConnectionNotFound, result);
}

test "ConnectionRegistry - remove connection" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state = try memory_strategy.createConnection(1, dummy_ws);
    try registry.add(1, state);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 1), snap.count());
    }

    registry.remove(1);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 0), snap.count());
    }
    const result = registry.acquireConnection(1);
    try testing.expectError(error.ConnectionNotFound, result);
}

test "ConnectionRegistry - clear all connections" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state1 = try memory_strategy.createConnection(1, dummy_ws);
    const state2 = try memory_strategy.createConnection(2, dummy_ws);
    const state3 = try memory_strategy.createConnection(3, dummy_ws);

    try registry.add(1, state1);
    try registry.add(2, state2);
    try registry.add(3, state3);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 3), snap.count());
    }

    registry.clear();

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 0), snap.count());
    }
}

test "ConnectionRegistry - multiple connections" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    // Add multiple connections
    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    for (1..11) |i| {
        const state = try memory_strategy.createConnection(i, dummy_ws);
        try registry.add(i, state);
    }

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 10), snap.count());
    }

    // Verify all connections can be retrieved
    for (1..11) |i| {
        const retrieved = try registry.acquireConnection(i);
        defer retrieved.release(allocator);
        try testing.expectEqual(@as(u64, i), retrieved.id);
    }
}

test "ConnectionRegistry - iterator" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    const state1 = try memory_strategy.createConnection(1, dummy_ws);
    const state2 = try memory_strategy.createConnection(2, dummy_ws);

    try registry.add(1, state1);
    try registry.add(2, state2);

    var count: usize = 0;
    var snap = try registry.snapshot();
    defer snap.deinit();
    var it = snap.iterator();
    while (it.next()) |_| {
        count += 1;
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "ConnectionRegistry - thread safety simulation" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var registry = ConnectionRegistry.init(&memory_strategy);
    defer registry.deinit();

    // Add connections
    const dummy_ws = WebSocket{ .ws = null, .ssl = false };
    for (1..6) |i| {
        const state = try memory_strategy.createConnection(i, dummy_ws);
        try registry.add(i, state);
    }

    // Simulate concurrent access by doing multiple operations
    for (1..6) |i| {
        const retrieved = try registry.acquireConnection(i);
        defer retrieved.release(allocator);
        try testing.expectEqual(@as(u64, i), retrieved.id);
    }

    // Remove some connections
    registry.remove(2);
    registry.remove(4);

    {
        var snap = try registry.snapshot();
        defer snap.deinit();
        try testing.expectEqual(@as(usize, 3), snap.count());
    }

    // Verify remaining connections
    {
        const r1 = try registry.acquireConnection(1);
        r1.release(allocator);
        const r3 = try registry.acquireConnection(3);
        r3.release(allocator);
        const r5 = try registry.acquireConnection(5);
        r5.release(allocator);
    }

    // Verify removed connections are gone
    try testing.expectError(error.ConnectionNotFound, registry.acquireConnection(2));
    try testing.expectError(error.ConnectionNotFound, registry.acquireConnection(4));
}

// ─── Task 4.2: Array field validation tests ──────────────────────────────────

const MessageHandler = @import("message_handler.zig").MessageHandler;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const msgpack_utils = @import("msgpack_utils.zig");
const schema_parser = @import("schema_parser.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const msgpack_helpers = @import("msgpack_test_helpers.zig");

/// Build a StoreSet message where the value map contains a field with a msgpack array payload.
/// The array payload is encoded inline in the msgpack bytes.
fn buildStoreSetWithArrayField(
    allocator: std.mem.Allocator,
    id: u64,
    namespace: []const u8,
    table: []const u8,
    doc_id: []const u8,
    field_name: []const u8,
    array_payload: msgpack_utils.Payload,
) ![]u8 {
    // Encode the array payload to msgpack bytes
    var arr_buf: std.ArrayList(u8) = .{};
    defer arr_buf.deinit(allocator);
    try msgpack_utils.encode(array_payload, arr_buf.writer(allocator));
    const arr_bytes = arr_buf.items;

    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    // fixmap with 5 elements: type, id, namespace, path, value
    try buf.append(allocator, 0x85);

    // "type": "StoreSet"
    try msgpack_helpers.writeString(allocator, &buf, "type");
    try msgpack_helpers.writeString(allocator, &buf, "StoreSet");

    // "id": <uint64>
    try msgpack_helpers.writeString(allocator, &buf, "id");
    try buf.append(allocator, 0xcf);
    try buf.append(allocator, @intCast((id >> 56) & 0xFF));
    try buf.append(allocator, @intCast((id >> 48) & 0xFF));
    try buf.append(allocator, @intCast((id >> 40) & 0xFF));
    try buf.append(allocator, @intCast((id >> 32) & 0xFF));
    try buf.append(allocator, @intCast((id >> 24) & 0xFF));
    try buf.append(allocator, @intCast((id >> 16) & 0xFF));
    try buf.append(allocator, @intCast((id >> 8) & 0xFF));
    try buf.append(allocator, @intCast(id & 0xFF));

    // "namespace": <namespace>
    try msgpack_helpers.writeString(allocator, &buf, "namespace");
    try msgpack_helpers.writeString(allocator, &buf, namespace);

    // "path": [table, doc_id]
    try msgpack_helpers.writeString(allocator, &buf, "path");
    try buf.append(allocator, 0x92); // fixarray(2)
    try msgpack_helpers.writeString(allocator, &buf, table);
    try msgpack_helpers.writeString(allocator, &buf, doc_id);

    // "value": {field_name: <array_payload>}
    try msgpack_helpers.writeString(allocator, &buf, "value");
    try buf.append(allocator, 0x81); // fixmap(1)
    try msgpack_helpers.writeString(allocator, &buf, field_name);
    try buf.appendSlice(allocator, arr_bytes);

    return buf.toOwnedSlice(allocator);
}

/// Parse a response and extract the "type" and "code" fields.
fn parseResponse(allocator: std.mem.Allocator, response: []const u8) !struct { resp_type: []const u8, code: ?[]const u8 } {
    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack_utils.decode(allocator, &reader);
    defer parsed.free(allocator);

    var resp_type: ?[]const u8 = null;
    var code: ?[]const u8 = null;

    var it = parsed.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .str) continue;
        const key = entry.key_ptr.*.str.value();
        if (std.mem.eql(u8, key, "type")) {
            if (entry.value_ptr.* == .str) {
                resp_type = try allocator.dupe(u8, entry.value_ptr.*.str.value());
            }
        } else if (std.mem.eql(u8, key, "code")) {
            if (entry.value_ptr.* == .str) {
                code = try allocator.dupe(u8, entry.value_ptr.*.str.value());
            }
        }
    }

    return .{
        .resp_type = resp_type orelse return error.MissingType,
        .code = code,
    };
}

fn setupHandlerWithArraySchema(
    allocator: std.mem.Allocator,
    memory_strategy: *MemoryStrategy,
    context: *schema_helpers.TestContext,
) !struct {
    handler: *MessageHandler,
    engine: *StorageEngine,
    schema: *schema_parser.Schema,
    violation_tracker: *ViolationTracker,
    subscription_manager: *SubscriptionManager,
} {
    // Build a schema with one array field and one text field
    const tables_def = [_]struct { name: []const u8, fields: []const []const u8 }{
        .{ .name = "items", .fields = &.{ "tags", "name" } },
    };
    _ = tables_def;

    // Manually build schema with array field
    const fields = try allocator.alloc(schema_parser.Field, 2);
    fields[0] = .{
        .name = try allocator.dupe(u8, "tags"),
        .sql_type = .array,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
    fields[1] = .{
        .name = try allocator.dupe(u8, "name"),
        .sql_type = .text,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };

    const tables = try allocator.alloc(schema_parser.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "items"),
        .fields = fields,
    };

    const schema = try allocator.create(schema_parser.Schema);
    schema.* = .{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };

    const engine = try schema_helpers.setupTestEngine(allocator, memory_strategy, context, schema);

    const violation_tracker = try allocator.create(ViolationTracker);
    violation_tracker.* = ViolationTracker.init(allocator, 10);

    const subscription_manager = try SubscriptionManager.init(allocator);

    const handler = try MessageHandler.init(
        allocator,
        memory_strategy,
        violation_tracker,
        engine,
        subscription_manager,
    );

    return .{
        .handler = handler,
        .engine = engine,
        .schema = schema,
        .violation_tracker = violation_tracker,
        .subscription_manager = subscription_manager,
    };
}

test "StoreSet: array field with non-literal element returns INVALID_ARRAY_ELEMENT" {
    const allocator = testing.allocator;

    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();

    var context = try schema_helpers.TestContext.init(allocator, "mh-array-invalid");
    defer context.deinit();

    var setup = try setupHandlerWithArraySchema(allocator, &memory_strategy, &context);
    defer {
        setup.handler.deinit();
        setup.engine.deinit();
        schema_parser.freeSchema(allocator, setup.schema.*);
        allocator.destroy(setup.schema);
        setup.violation_tracker.deinit();
        allocator.destroy(setup.violation_tracker);
        setup.subscription_manager.deinit();
    }
    // Build an array payload with a nested map (non-literal element)
    var nested_map = msgpack_utils.Payload.mapPayload(allocator);
    defer nested_map.free(allocator);
    try nested_map.mapPut("key", try msgpack_utils.Payload.strToPayload("val", allocator));
    const inner_arr = try allocator.alloc(msgpack_utils.Payload, 1);
    inner_arr[0] = nested_map;
    // Transfer ownership: nested_map is now owned by the array
    nested_map = .nil; // prevent double-free in defer above
    const invalid_array = msgpack_utils.Payload{ .arr = inner_arr };
    defer invalid_array.free(allocator);
    const message = try buildStoreSetWithArrayField(
        allocator,
        42,
        "test_ns",
        "items",
        "doc1",
        "tags",
        invalid_array,
    );
    defer allocator.free(message);
    var reader: std.Io.Reader = .fixed(message);
    const parsed = try msgpack_utils.decode(allocator, &reader);
    defer parsed.free(allocator);
    const msg_info = try setup.handler.extractMessageInfo(parsed);
    var ws = WebSocket{ .ws = null, .ssl = false };
    try setup.handler.handleOpen(&ws);
    defer setup.handler.handleClose(&ws, 1000, "") catch {}; // zwanzig-disable-line: empty-catch-engine
    const conn_id = ws.getConnId();
    const response = try setup.handler.routeMessage(conn_id, msg_info, parsed);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |c| allocator.free(c);
    try testing.expectEqualStrings("error", result.resp_type);
    try testing.expect(result.code != null);
    try testing.expectEqualStrings("INVALID_ARRAY_ELEMENT", result.code.?);
    // Verify no DB write occurred
    try setup.engine.flushPendingWrites();
    const stored = try setup.engine.selectDocument("items", "doc1", "test_ns");
    try testing.expect(stored == null);
}
test "StoreSet: array field with valid literal array succeeds" {
    const allocator = testing.allocator;
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    var context = try schema_helpers.TestContext.init(allocator, "mh-array-valid");
    defer context.deinit();
    var setup = try setupHandlerWithArraySchema(allocator, &memory_strategy, &context);
    defer {
        setup.handler.deinit();
        setup.engine.deinit();
        schema_parser.freeSchema(allocator, setup.schema.*);
        allocator.destroy(setup.schema);
        setup.violation_tracker.deinit();
        allocator.destroy(setup.violation_tracker);
        setup.subscription_manager.deinit();
    }
    // Build a valid literal array: ["hello", 42, true]
    const elems = try allocator.alloc(msgpack_utils.Payload, 3);
    elems[0] = try msgpack_utils.Payload.strToPayload("hello", allocator);
    elems[1] = msgpack_utils.Payload.intToPayload(42);
    elems[2] = .{ .bool = true };
    const valid_array = msgpack_utils.Payload{ .arr = elems };
    defer valid_array.free(allocator);
    const message = try buildStoreSetWithArrayField(
        allocator,
        99,
        "test_ns",
        "items",
        "doc2",
        "tags",
        valid_array,
    );
    defer allocator.free(message);
    var reader: std.Io.Reader = .fixed(message);
    const parsed = try msgpack_utils.decode(allocator, &reader);
    defer parsed.free(allocator);
    const msg_info = try setup.handler.extractMessageInfo(parsed);
    var ws = WebSocket{ .ws = null, .ssl = false };
    try setup.handler.handleOpen(&ws);
    defer setup.handler.handleClose(&ws, 1000, "") catch {}; // zwanzig-disable-line: empty-catch-engine
    const conn_id = ws.getConnId();
    const response = try setup.handler.routeMessage(conn_id, msg_info, parsed);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |c| allocator.free(c);
    try testing.expectEqualStrings("ok", result.resp_type);
}
// ─── Task 7.9: Property 9 — Message handler rejects arrays with non-literal elements ──
// Feature: array-jsonb-storage, Property 9: Message handler rejects arrays with non-literal elements
test "StoreSet: property 9 - message handler rejects arrays with non-literal elements" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xDEAD_C0DE);
    const rand = prng.random();
    var memory_strategy = try MemoryStrategy.init(allocator);
    defer memory_strategy.deinit();
    var context = try schema_helpers.TestContext.init(allocator, "mh-prop9");
    defer context.deinit();
    var setup = try setupHandlerWithArraySchema(allocator, &memory_strategy, &context);
    defer {
        setup.handler.deinit();
        setup.engine.deinit();
        schema_parser.freeSchema(allocator, setup.schema.*);
        allocator.destroy(setup.schema);
        setup.violation_tracker.deinit();
        allocator.destroy(setup.violation_tracker);
        setup.subscription_manager.deinit();
    }
    var ws = WebSocket{ .ws = null, .ssl = false };
    try setup.handler.handleOpen(&ws);
    defer setup.handler.handleClose(&ws, 1000, "") catch {};
    const conn_id = ws.getConnId();
    // (a) Invalid arrays → INVALID_ARRAY_ELEMENT
    var invalid_iter: usize = 0;
    while (invalid_iter < 20) : (invalid_iter += 1) {
        // Build array with a nested map (non-literal)
        var nested_map = msgpack_utils.Payload.mapPayload(allocator);
        const inner_arr = try allocator.alloc(msgpack_utils.Payload, 1);
        inner_arr[0] = nested_map;
        nested_map = .nil; // ownership transferred
        const invalid_array = msgpack_utils.Payload{ .arr = inner_arr };
        defer invalid_array.free(allocator);
        const doc_id = try std.fmt.allocPrint(allocator, "inv_{d}", .{invalid_iter});
        defer allocator.free(doc_id);
        const msg_id: u64 = @intCast(1000 + invalid_iter);
        const message = try buildStoreSetWithArrayField(
            allocator,
            msg_id,
            "test_ns",
            "items",
            doc_id,
            "tags",
            invalid_array,
        );
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const msg_info = try setup.handler.extractMessageInfo(parsed);
        const response = try setup.handler.routeMessage(conn_id, msg_info, parsed);
        defer allocator.free(response);
        const result = try parseResponse(allocator, response);
        defer allocator.free(result.resp_type);
        defer if (result.code) |c| allocator.free(c);
        try testing.expectEqualStrings("error", result.resp_type);
        try testing.expect(result.code != null);
        try testing.expectEqualStrings("INVALID_ARRAY_ELEMENT", result.code.?);
    }
    // (b) Valid literal arrays → success
    var valid_iter: usize = 0;
    while (valid_iter < 20) : (valid_iter += 1) {
        const n = rand.intRangeAtMost(usize, 0, 4);
        const elems = try allocator.alloc(msgpack_utils.Payload, n);
        for (0..n) |i| {
            elems[i] = .{ .int = rand.int(i64) };
        }
        const valid_array = msgpack_utils.Payload{ .arr = elems };
        defer valid_array.free(allocator);
        const doc_id = try std.fmt.allocPrint(allocator, "val_{d}", .{valid_iter});
        defer allocator.free(doc_id);
        const msg_id: u64 = @intCast(2000 + valid_iter);
        const message = try buildStoreSetWithArrayField(
            allocator,
            msg_id,
            "test_ns",
            "items",
            doc_id,
            "tags",
            valid_array,
        );
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const msg_info = try setup.handler.extractMessageInfo(parsed);
        const response = try setup.handler.routeMessage(conn_id, msg_info, parsed);
        defer allocator.free(response);
        const result = try parseResponse(allocator, response);
        defer allocator.free(result.resp_type);
        defer if (result.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", result.resp_type);
    }
}
