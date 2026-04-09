const std = @import("std");
const testing = std.testing;

const message_helpers = @import("message_handler_test_helpers.zig");
const AppTestContext = message_helpers.AppTestContext;
const createMockWebSocket = message_helpers.createMockWebSocket;
const routeWithArena = message_helpers.routeWithArena;

test "Connection - init and deinit" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-init", &.{});
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const state = sc.conn;

    try testing.expectEqual(ws.getConnId(), state.id);
    try testing.expectEqual(@as(?[]const u8, null), state.user_id);
    try testing.expectEqualStrings("default", state.namespace);
    try testing.expectEqual(@as(usize, 0), state.subscription_ids.items.len);
}

test "Connection - add subscription IDs" {
    const allocator = testing.allocator;
    var app: AppTestContext = undefined;
    try app.init(allocator, "conn-subs", &.{});
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const state = sc.conn;

    try state.subscription_ids.append(state.allocator, 100);
    try state.subscription_ids.append(state.allocator, 200);
    try state.subscription_ids.append(state.allocator, 300);

    try testing.expectEqual(@as(usize, 3), state.subscription_ids.items.len);
    try testing.expectEqual(@as(u64, 100), state.subscription_ids.items[0]);
    try testing.expectEqual(@as(u64, 200), state.subscription_ids.items[1]);
    try testing.expectEqual(@as(u64, 300), state.subscription_ids.items[2]);
}

// ─── Task 4.2: Array field validation tests ──────────────────────────────────

const msgpack_utils = @import("msgpack_utils.zig");
const schema_manager = @import("schema_manager.zig");
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
    var arr_buf = std.ArrayListUnmanaged(u8).empty;
    defer arr_buf.deinit(allocator);
    try msgpack_utils.encode(array_payload, arr_buf.writer(allocator));
    const arr_bytes = arr_buf.items;

    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // fixmap with 5 elements: type, id, namespace, path, value
    try buf.append(allocator, 0x85);

    // "type": "StoreSet"
    try msgpack_helpers.writeMsgPackStr(writer, "type");
    try msgpack_helpers.writeMsgPackStr(writer, "StoreSet");

    // "id": <uint64>
    try msgpack_helpers.writeMsgPackStr(writer, "id");
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
    try msgpack_helpers.writeMsgPackStr(writer, "namespace");
    try msgpack_helpers.writeMsgPackStr(writer, namespace);

    // "path": [table, doc_id]
    try msgpack_helpers.writeMsgPackStr(writer, "path");
    try buf.append(allocator, 0x92); // fixarray(2)
    try msgpack_helpers.writeMsgPackStr(writer, table);
    try msgpack_helpers.writeMsgPackStr(writer, doc_id);

    // "value": {field_name: <array_payload>}
    try msgpack_helpers.writeMsgPackStr(writer, "value");
    try buf.append(allocator, 0x81); // fixmap(1)
    try msgpack_helpers.writeMsgPackStr(writer, field_name);
    try buf.appendSlice(allocator, arr_bytes);

    return buf.toOwnedSlice(allocator);
}

/// Parse a response and extract the "type" and "code" fields.
fn parseResponse(allocator: std.mem.Allocator, response: []const u8) !struct { resp_type: []const u8, code: ?[]const u8 } {
    var reader: std.Io.Reader = .fixed(response);
    const parsed = try msgpack_utils.decode(allocator, &reader);
    defer parsed.free(allocator);

    const resp_type_val = msgpack_helpers.getMapValue(parsed, "type") orelse return error.MissingType;
    const resp_code_val = msgpack_helpers.getMapValue(parsed, "code");

    return .{
        .resp_type = try allocator.dupe(u8, resp_type_val.str.value()),
        .code = if (resp_code_val) |v| try allocator.dupe(u8, v.str.value()) else null,
    };
}

fn setupAppWithSchema(app: *AppTestContext, allocator: std.mem.Allocator, prefix: []const u8, schema: schema_manager.Schema) !void {
    try app.initWithSchema(allocator, prefix, schema);
}

test "StoreSet: array field with non-literal element returns INVALID_ARRAY_ELEMENT" {
    const allocator = testing.allocator;

    // Manually build schema with array field
    const fields = try allocator.alloc(schema_manager.Field, 2);
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

    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "items"),
        .fields = fields,
    };

    const schema = schema_manager.Schema{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };
    defer schema_manager.freeSchema(allocator, schema);

    var app: AppTestContext = undefined;
    try setupAppWithSchema(&app, allocator, "mh-array-invalid", schema);
    defer app.deinit();

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
    const msg_info = try app.handler.extractMessageInfo(parsed);

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

    const response = try message_helpers.routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |c| allocator.free(c);

    try testing.expectEqualStrings("error", result.resp_type);
    try testing.expect(result.code != null);
    try testing.expectEqualStrings("INVALID_ARRAY_ELEMENT", result.code.?);

    // Verify no DB write occurred
    try app.storage_engine.flushPendingWrites();
    var managed = try app.storage_engine.selectDocument(allocator, "items", "doc1", "test_ns");
    defer managed.deinit();
    const stored = managed.value;
    try testing.expect(stored == null);
}

test "StoreSet: array field with valid literal array succeeds" {
    const allocator = testing.allocator;

    // Manually build schema with array field
    const fields = try allocator.alloc(schema_manager.Field, 2);
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

    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "items"),
        .fields = fields,
    };

    const schema = schema_manager.Schema{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };
    defer schema_manager.freeSchema(allocator, schema);

    var app: AppTestContext = undefined;
    try setupAppWithSchema(&app, allocator, "mh-array-valid", schema);
    defer app.deinit();

    // Build a valid array of integers
    const n = 3;
    const elems = try allocator.alloc(msgpack_utils.Payload, n);
    for (0..n) |i| elems[i] = .{ .uint = @as(u64, i) };
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
    const msg_info = try app.handler.extractMessageInfo(parsed);

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

    const response = try message_helpers.routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
    defer allocator.free(response);
    const result = try parseResponse(allocator, response);
    defer allocator.free(result.resp_type);
    defer if (result.code) |c| allocator.free(c);
    try testing.expectEqualStrings("ok", result.resp_type);
}

// ─── Task 7.9: Property 9 — Message handler rejects arrays with non-literal elements ──
// Feature: array-jsonb-storage, Property 9: Message handler rejects arrays with non-literal elements
test "StoreSet: message handler rejects arrays with non-literal elements" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xDEAD_C0DE);
    const rand = prng.random();

    // Manually build schema with array field
    const fields = try allocator.alloc(schema_manager.Field, 2);
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

    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "items"),
        .fields = fields,
    };

    const schema = schema_manager.Schema{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };
    defer schema_manager.freeSchema(allocator, schema);

    var app: AppTestContext = undefined;
    try setupAppWithSchema(&app, allocator, "mh-prop9", schema);
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

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
            "doc_id",
            "tags",
            invalid_array,
        );
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const msg_info = try app.handler.extractMessageInfo(parsed);
        const response = try message_helpers.routeWithArena(&app.handler, allocator, conn, msg_info, parsed);
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
            "doc_id",
            "tags",
            valid_array,
        );
        defer allocator.free(message);
        var mock_ws = createMockWebSocket();
        const mock_sc = try app.openScopedConnection(&mock_ws);
        defer mock_sc.deinit();
        const mock_conn = mock_sc.conn;

        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const msg_info = try app.handler.extractMessageInfo(parsed);
        const response = try message_helpers.routeWithArena(&app.handler, allocator, mock_conn, msg_info, parsed);
        defer allocator.free(response);
        const result = try parseResponse(allocator, response);
        defer allocator.free(result.resp_type);
        defer if (result.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", result.resp_type);
    }
}

// ─── Verification of Schema & Message Parsing Architecture Improvements ──────

test "MessageHandler - resolveFieldName via StoreSet (single and multi-segment)" {
    const allocator = testing.allocator;

    // Create a schema with a flattened multi-segment field
    const fields = try allocator.alloc(schema_manager.Field, 2);
    fields[0] = .{
        .name = try allocator.dupe(u8, "metadata__tags"),
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

    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "items"),
        .fields = fields,
    };

    const schema = schema_manager.Schema{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };
    defer schema_manager.freeSchema(allocator, schema);

    var app: AppTestContext = undefined;
    try setupAppWithSchema(&app, allocator, "mh-resolve-field", schema);
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Test single segment (name)
    {
        const val_payload = try msgpack_utils.Payload.strToPayload("test", allocator);
        defer val_payload.free(allocator);
        const msg = try buildStoreSetWithFieldPath(allocator, 1, "items", "doc1", &.{"name"}, val_payload);
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try message_helpers.routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        defer if (res.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", res.resp_type);
    }

    // 2. Test multi-segment (metadata.tags)
    {
        const tags = try allocator.alloc(msgpack_utils.Payload, 2);
        tags[0] = try msgpack_utils.Payload.strToPayload("a", allocator);
        tags[1] = try msgpack_utils.Payload.strToPayload("b", allocator);
        defer {
            tags[0].free(allocator);
            tags[1].free(allocator);
            allocator.free(tags);
        }
        const msg = try buildStoreSetWithFieldPath(allocator, 2, "items", "doc1", &.{ "metadata", "tags" }, .{ .arr = tags });
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try message_helpers.routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        defer if (res.code) |c| allocator.free(c);
        try testing.expectEqualStrings("ok", res.resp_type);
    }

    // 3. Test nested array validation for multi-segment path
    {
        // Invalid element (map) in field metadata.tags
        const inner_arr = try allocator.alloc(msgpack_utils.Payload, 1);
        inner_arr[0] = msgpack_utils.Payload.mapPayload(allocator);
        defer {
            inner_arr[0].free(allocator);
            allocator.free(inner_arr);
        }
        const msg = try buildStoreSetWithFieldPath(allocator, 3, "items", "doc1", &.{ "metadata", "tags" }, .{ .arr = inner_arr });
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);
        const response = try message_helpers.routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response);
        const res = try parseResponse(allocator, response);
        defer allocator.free(res.resp_type);
        defer if (res.code) |c| allocator.free(c);
        try testing.expectEqualStrings("error", res.resp_type);
        try testing.expectEqualStrings("INVALID_ARRAY_ELEMENT", res.code.?);
    }
}

test "MessageHandler - deep nested schema round-trip (3+ levels)" {
    const allocator = testing.allocator;

    // a.b.c -> a__b__c
    const fields = try allocator.alloc(schema_manager.Field, 1);
    fields[0] = .{
        .name = try allocator.dupe(u8, "a__b__c"),
        .sql_type = .text,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };

    const tables = try allocator.alloc(schema_manager.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, "deep"),
        .fields = fields,
    };

    const schema = schema_manager.Schema{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };
    defer schema_manager.freeSchema(allocator, schema);

    var app: AppTestContext = undefined;
    try setupAppWithSchema(&app, allocator, "mh-deep-nested", schema);
    defer app.deinit();

    var ws = createMockWebSocket();
    const sc = try app.openScopedConnection(&ws);
    defer sc.deinit();
    const conn = sc.conn;

    // 1. Set deep field: ["deep", "id1", "a", "b", "c"]
    {
        const val_payload = try msgpack_utils.Payload.strToPayload("value", allocator);
        defer val_payload.free(allocator);
        const msg = try buildStoreSetWithFieldPath(allocator, 1, "deep", "id1", &.{ "a", "b", "c" }, val_payload);
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response_copy = try routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response_copy);

        // Verify Set response is "ok"
        var resp_reader: std.Io.Reader = .fixed(response_copy);
        const resp_parsed = try msgpack_utils.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);
        const resp_type = msgpack_helpers.getMapValue(resp_parsed, "type") orelse return error.MissingType;
        try testing.expectEqualStrings("ok", resp_type.str.value());
    }

    // Flush pending writes so the document is persisted before reading
    try app.storage_engine.flushPendingWrites();

    // 2. Get document and verify unflattening: Expect { "a": { "b": { "c": "value" } } }
    {
        const msg = try buildStoreQuery(allocator, 2, "deep");
        defer allocator.free(msg);
        var reader: std.Io.Reader = .fixed(msg);
        const parsed = try msgpack_utils.decode(allocator, &reader);
        defer parsed.free(allocator);

        const response_copy = try routeWithArena(&app.handler, allocator, conn, try app.handler.extractMessageInfo(parsed), parsed);
        defer allocator.free(response_copy);

        // Parse actual value
        var resp_reader: std.Io.Reader = .fixed(response_copy);
        const resp_parsed = try msgpack_utils.decode(allocator, &resp_reader);
        defer resp_parsed.free(allocator);
        const value = msgpack_helpers.getMapValue(resp_parsed, "value") orelse return error.MissingValue;

        // For StoreQueryResponse, the value is an array of records
        try testing.expect(value == .arr);
        try testing.expectEqual(@as(usize, 1), value.arr.len);
        const doc = value.arr[0];

        // Verify structure: doc.map["a__b__c"] == "value" (stay flat architecture)
        const abc = msgpack_helpers.getMapValue(doc, "a__b__c") orelse return error.ValueMismatch;
        try testing.expectEqualStrings("value", abc.str.value());
    }
}

fn buildStoreSetWithFieldPath(
    allocator: std.mem.Allocator,
    id: u64,
    table: []const u8,
    doc_id: []const u8,
    field_segments: []const []const u8,
    val: msgpack_utils.Payload,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    // fixmap(5)
    try buf.append(allocator, 0x85);

    try msgpack_helpers.writeMsgPackStr(writer, "type");
    try msgpack_helpers.writeMsgPackStr(writer, "StoreSet");

    try msgpack_helpers.writeMsgPackStr(writer, "id");
    // encode id as uint64
    try buf.append(allocator, 0xcf);
    for (0..8) |i| try buf.append(allocator, @intCast((id >> @intCast((7 - i) * 8)) & 0xFF));

    try msgpack_helpers.writeMsgPackStr(writer, "namespace");
    try msgpack_helpers.writeMsgPackStr(writer, "default");

    try msgpack_helpers.writeMsgPackStr(writer, "path");
    // array length is 2 + field_segments.len
    const path_len = 2 + field_segments.len;
    if (path_len < 16) {
        try buf.append(allocator, @intCast(0x90 | path_len));
    } else {
        try buf.append(allocator, 0xdc);
        try buf.append(allocator, @intCast((path_len >> 8) & 0xFF));
        try buf.append(allocator, @intCast(path_len & 0xFF));
    }
    try msgpack_helpers.writeMsgPackStr(writer, table);
    try msgpack_helpers.writeMsgPackStr(writer, doc_id);
    for (field_segments) |seg| try msgpack_helpers.writeMsgPackStr(writer, seg);

    try msgpack_helpers.writeMsgPackStr(writer, "value");
    try msgpack_utils.encode(val, buf.writer(allocator));

    return buf.toOwnedSlice(allocator);
}

fn buildStoreQuery(allocator: std.mem.Allocator, id: u64, table: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try buf.append(allocator, 0x85); // fixmap(5)
    try msgpack_helpers.writeMsgPackStr(writer, "type");
    try msgpack_helpers.writeMsgPackStr(writer, "StoreQuery");
    try msgpack_helpers.writeMsgPackStr(writer, "id");
    try buf.append(allocator, 0xcf);
    for (0..8) |i| try buf.append(allocator, @intCast((id >> @intCast((7 - i) * 8)) & 0xFF));
    try msgpack_helpers.writeMsgPackStr(writer, "namespace");
    try msgpack_helpers.writeMsgPackStr(writer, "default");
    try msgpack_helpers.writeMsgPackStr(writer, "collection");
    try msgpack_helpers.writeMsgPackStr(writer, table);
    try msgpack_helpers.writeMsgPackStr(writer, "filter");
    try buf.append(allocator, 0x80); // empty map {}
    return buf.toOwnedSlice(allocator);
}
