const std = @import("std");
const testing = std.testing;
const msgpack = @import("msgpack_utils.zig");
const storage_mod = @import("storage_engine.zig");
const helpers = @import("app_test_helpers.zig");
const protocol = @import("protocol.zig");
const schema_manager = @import("schema_manager.zig");
const store_service = @import("store_service.zig");
const StorageError = storage_mod.StorageError;

test "StoreService: set - full document replacement" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-test", &.{
        .{
            .name = "users",
            .fields = &.{ "name", "age", "tags" },
            .types = &.{ .text, .integer, .array },
        },
    });
    defer app.deinit();

    const service = &app.store_service;

    // 1. Success path: Valid document
    {
        var val = msgpack.Payload.mapPayload(allocator);
        defer val.free(allocator);
        try val.mapPut("name", try msgpack.Payload.strToPayload("Alice", allocator));
        try val.mapPut("age", msgpack.Payload.intToPayload(30));

        try service.set("users", "user-1", "public", 2, null, val);
        try app.storage_engine.flushPendingWrites();

        // Verify with storage engine
        var managed = try app.storage_engine.selectDocument(allocator, "users", "user-1", "public");
        defer managed.deinit();

        try testing.expect(managed.value != null);
        const doc = managed.value.?;
        const name_payload = try msgpack.Payload.strToPayload("name", allocator);
        defer name_payload.free(allocator);
        const name_val = doc.map.get(name_payload) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings("Alice", name_val.str.value());

        const age_payload = try msgpack.Payload.strToPayload("age", allocator);
        defer age_payload.free(allocator);
        const age_val = doc.map.get(age_payload) orelse return error.UnexpectedNull;
        try testing.expectEqual(@as(i64, 30), age_val.int);
    }

    // 5. Negative path: Unknown table
    {
        var val = msgpack.Payload.mapPayload(allocator);
        defer val.free(allocator);

        const result = service.set("invalid_table", "id", "ns", 2, null, val);
        try testing.expectError(StorageError.UnknownTable, result);
    }
}

test "StoreService: set - field level update" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-test-field", &.{
        .{
            .name = "items",
            .fields = &.{ "status", "meta" },
            .types = &.{ .text, .boolean },
        },
    });
    defer app.deinit();

    const service = &app.store_service;

    // 1. Success path: Update single field
    {
        const val = try msgpack.Payload.strToPayload("active", allocator);
        defer val.free(allocator);

        try service.set("items", "item-1", "public", 3, "status", val);
        try app.storage_engine.flushPendingWrites();

        // Verify
        var managed = try app.storage_engine.selectDocument(allocator, "items", "item-1", "public");
        defer managed.deinit();
        const doc = managed.value orelse return error.UnexpectedNull;
        const status_payload = try msgpack.Payload.strToPayload("status", allocator);
        defer status_payload.free(allocator);
        const status_val = doc.map.get(status_payload) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings("active", status_val.str.value());
    }
}

test "StoreService: remove" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-test-remove", &.{
        .{
            .name = "users",
            .fields = &.{ "name", "age" },
            .types = &.{ .text, .integer },
        },
    });
    defer app.deinit();

    const service = &app.store_service;

    // Setup: Create a document
    {
        var val = msgpack.Payload.mapPayload(allocator);
        defer val.free(allocator);
        try val.mapPut("name", try msgpack.Payload.strToPayload("Alice", allocator));
        try val.mapPut("age", msgpack.Payload.intToPayload(30));

        try service.set("users", "user-1", "public", 2, null, val);
        try app.storage_engine.flushPendingWrites();
    }

    // 1. Negative: Remove field (segments_len == 3) is forbidden
    {
        const result = service.remove("users", "user-1", "public", 3, "name");
        try testing.expectError(StorageError.InvalidPath, result);
    }

    // 2. Success: Remove document (segments_len == 2)
    {
        try service.remove("users", "user-1", "public", 2, null);
        try app.storage_engine.flushPendingWrites();

        var managed = try app.storage_engine.selectDocument(allocator, "users", "user-1", "public");
        defer managed.deinit();
        try testing.expect(managed.value == null);
    }

    // 3. Negative: Unknown table
    {
        const result = service.remove("invalid", "id", "ns", 2, null);
        try testing.expectError(StorageError.UnknownTable, result);
    }

    // 4. Negative: Field removal is forbidden even if field name is unknown
    {
        const result = service.remove("users", "user-1", "public", 3, "unknown_field");
        try testing.expectError(StorageError.InvalidPath, result);
    }
}

test "StoreService: array validation" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;

    // Use a schema with specific items types
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "collections": {
        \\      "fields": {
        \\        "tags": { "type": "array", "items": "string" },
        \\        "scores": { "type": "array", "items": "integer" }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    try app.initWithSchemaJSON(allocator, "store-service-array", schema_json);
    defer app.deinit();

    const service = &app.store_service;

    // 1. Success: Valid literal array of strings
    {
        var arr = try allocator.alloc(msgpack.Payload, 2);
        arr[0] = try msgpack.Payload.strToPayload("tag1", allocator);
        arr[1] = try msgpack.Payload.strToPayload("tag2", allocator);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        try service.set("collections", "id1", "public", 3, "tags", val);
    }

    // 2. Negative: Element type mismatch (integer in string array)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.intToPayload(123);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        const result = service.set("collections", "id1", "public", 3, "tags", val);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }

    // 3. Negative: Non-literal element (nested map)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.mapPayload(allocator);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        const result = service.set("collections", "id1", "public", 3, "tags", val);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }

    // 4. Success: Valid integers in scores array
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.intToPayload(42);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        try service.set("collections", "id1", "public", 3, "scores", val);
    }
}

test "StoreService: persistence and namespace isolation" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-isolation", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const service = &app.store_service;

    // 1. Basic Persistence
    {
        const val = try msgpack.Payload.strToPayload("value1", allocator);
        defer val.free(allocator);

        try service.set("test", "key1", "ns-a", 3, "val", val);
        try app.storage_engine.flushPendingWrites();

        var managed = try app.storage_engine.selectDocument(allocator, "test", "key1", "ns-a");
        defer managed.deinit();
        try testing.expect(managed.value != null);
        const val_key = try msgpack.Payload.strToPayload("val", allocator);
        defer val_key.free(allocator);
        const stored_doc = managed.value.?;
        const stored_val = stored_doc.map.get(val_key) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings("value1", stored_val.str.value());
    }

    // 2. Namespace Isolation
    {
        const val = try msgpack.Payload.strToPayload("value2", allocator);
        defer val.free(allocator);

        // Same table/id, different namespace
        try service.set("test", "key1", "ns-b", 3, "val", val);
        try app.storage_engine.flushPendingWrites();

        const val_key = try msgpack.Payload.strToPayload("val", allocator);
        defer val_key.free(allocator);

        // Verify ns-a still has value1
        var managed_a = try app.storage_engine.selectDocument(allocator, "test", "key1", "ns-a");
        defer managed_a.deinit();
        try testing.expect(managed_a.value != null);
        const doc_a = managed_a.value.?;
        const v_a = doc_a.map.get(val_key) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings("value1", v_a.str.value());

        // Verify ns-b has value2
        var managed_b = try app.storage_engine.selectDocument(allocator, "test", "key1", "ns-b");
        defer managed_b.deinit();
        try testing.expect(managed_b.value != null);
        const doc_b = managed_b.value.?;
        const v_b = doc_b.map.get(val_key) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings("value2", v_b.str.value());
    }

    // 3. Updates
    {
        const val = try msgpack.Payload.strToPayload("updated", allocator);
        defer val.free(allocator);

        try service.set("test", "key1", "ns-a", 3, "val", val);
        try app.storage_engine.flushPendingWrites();

        const val_key = try msgpack.Payload.strToPayload("val", allocator);
        defer val_key.free(allocator);

        var managed = try app.storage_engine.selectDocument(allocator, "test", "key1", "ns-a");
        defer managed.deinit();
        try testing.expect(managed.value != null);
        const doc = managed.value.?;
        const stored_val = doc.map.get(val_key) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings("updated", stored_val.str.value());
    }
}

test "StoreService: query - basic search" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-basic", &.{
        .{ .name = "users", .fields = &.{"name"} },
    });
    defer app.deinit();

    // Seed data
    const cols_1 = [_]storage_mod.ColumnValue{.{ .name = "name", .value = .{ .text = "Alice" }, .field_type = .text }};
    try app.storage_engine.insertOrReplace("users", "user-1", "ns", &cols_1);

    const cols_2 = [_]storage_mod.ColumnValue{.{ .name = "name", .value = .{ .text = "Bob" }, .field_type = .text }};
    try app.storage_engine.insertOrReplace("users", "user-2", "ns", &cols_2);
    try app.storage_engine.flushPendingWrites();

    // Build filter: { "conditions": [ ["id", 0, "user-1"] ] }
    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);

    var conds_arr = try allocator.alloc(msgpack.Payload, 1);
    var cond_arr = try allocator.alloc(msgpack.Payload, 3);
    cond_arr[0] = try msgpack.Payload.strToPayload("id", allocator);
    cond_arr[1] = msgpack.Payload.uintToPayload(0); // eq
    cond_arr[2] = try msgpack.Payload.strToPayload("user-1", allocator);
    conds_arr[0] = msgpack.Payload{ .arr = cond_arr };
    try filter_map.mapPut("conditions", msgpack.Payload{ .arr = conds_arr });

    var qr = try app.store_service.query(allocator, "users", "ns", filter_map);
    defer qr.deinit(allocator);

    const results_p = qr.results.value orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), results_p.arr.len);
    const doc = results_p.arr[0];
    const name_val = (try doc.mapGet("name")) orelse return error.TestExpectedValue;
    try testing.expectEqualStrings("Alice", name_val.str.value());
}

test "StoreService: query - orderBy and limit" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-sort", &.{
        .{ .name = "tasks", .fields = &.{"title"} },
    });
    defer app.deinit();

    const tasks = [_][]const u8{ "Task A", "Task B", "Task C" };
    for (tasks, 0..) |t, i| {
        const cols = [_]storage_mod.ColumnValue{.{ .name = "title", .value = .{ .text = t }, .field_type = .text }};
        const id = try std.fmt.allocPrint(allocator, "task-{}", .{i});
        defer allocator.free(id);
        try app.storage_engine.insertOrReplace("tasks", id, "ns", &cols);
    }
    try app.storage_engine.flushPendingWrites();

    // Filter: orderBy created_at DESC, limit 2
    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);

    var order_tuple = try allocator.alloc(msgpack.Payload, 2);
    order_tuple[0] = try msgpack.Payload.strToPayload("created_at", allocator);
    order_tuple[1] = msgpack.Payload.uintToPayload(1); // DESC
    try filter_map.mapPut("orderBy", msgpack.Payload{ .arr = order_tuple });
    try filter_map.mapPut("limit", msgpack.Payload.uintToPayload(2));

    var qr = try app.store_service.query(allocator, "tasks", "ns", filter_map);
    defer qr.deinit(allocator);

    const results_p = qr.results.value orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 2), results_p.arr.len);
    try testing.expect(qr.results.next_cursor_arr != null);
}

test "StoreService: query - negative cases" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-neg", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);

    // 1. Unknown collection
    {
        const err = app.store_service.query(allocator, "nonexistent", "ns", filter_map);
        try testing.expectError(StorageError.UnknownTable, err);
    }

    // 2. Unknown field
    {
        var conds_arr = try allocator.alloc(msgpack.Payload, 1);
        var cond_arr = try allocator.alloc(msgpack.Payload, 3);
        cond_arr[0] = try msgpack.Payload.strToPayload("ghost_field", allocator);
        cond_arr[1] = msgpack.Payload.uintToPayload(0);
        cond_arr[2] = try msgpack.Payload.strToPayload("val", allocator);
        conds_arr[0] = msgpack.Payload{ .arr = cond_arr };
        try filter_map.mapPut("conditions", msgpack.Payload{ .arr = conds_arr });

        const err = app.store_service.query(allocator, "data", "ns", filter_map);
        try testing.expectError(StorageError.UnknownField, err);
    }
}

test "StoreService: queryWithCursor - pagination" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-cursor", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    // Seed 5 items
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const str = try std.fmt.allocPrint(allocator, "item-{}", .{i});
        defer allocator.free(str);
        const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = .{ .text = str }, .field_type = .text }};
        const id = try std.fmt.allocPrint(allocator, "id-{}", .{i});
        defer allocator.free(id);
        try app.storage_engine.insertOrReplace("data", id, "ns", &cols);
    }
    try app.storage_engine.flushPendingWrites();

    // 1. Initial query: limit 2
    var filter_map = msgpack.Payload.mapPayload(allocator);
    defer filter_map.free(allocator);
    try filter_map.mapPut("limit", msgpack.Payload.uintToPayload(2));

    var qr = try app.store_service.query(allocator, "data", "ns", filter_map);
    defer qr.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), qr.results.value.?.arr.len);
    try testing.expect(qr.results.next_cursor_arr != null);

    // Save the cursor token (encoded)
    const encoded_cursor = try protocol.encodeCursor(allocator, qr.results.next_cursor_arr.?);
    defer allocator.free(encoded_cursor);

    // Decode it back to a domain object (simulating what MessageHandler does)
    const cursor = try protocol.decodeCursor(allocator, encoded_cursor);

    // 2. Query with cursor: fetch next 2
    var next_results = try app.store_service.queryWithCursor(allocator, "data", "ns", &qr.filter, cursor);
    defer next_results.deinit();

    const next_results_p = next_results.value orelse return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 2), next_results_p.arr.len);

    // Verify results are different (pagination worked)
    const first_results = qr.results.value orelse return error.TestExpectedValue;
    const first_doc = first_results.arr[0];
    const first_id_payload = (try first_doc.mapGet("id")) orelse return error.TestExpectedValue;
    const first_page_id = first_id_payload.str.value();

    const second_results = next_results.value orelse return error.TestExpectedValue;
    const second_doc = second_results.arr[0];
    const second_id_payload = (try second_doc.mapGet("id")) orelse return error.TestExpectedValue;
    const second_page_id = second_id_payload.str.value();

    try testing.expect(!std.mem.eql(u8, first_page_id, second_page_id));
}

test "StoreService: validateFieldWrite tests" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-validate", &.{
        .{
            .name = "users",
            .fields = &.{ "name", "age", "active", "tags" },
            .types = &.{ .text, .integer, .boolean, .array },
        },
    });
    defer app.deinit();

    const service = &app.store_service;
    const tbl_md = service.schema_manager.getTable("users") orelse return error.TestExpectedValue;

    // 1. Immutable fields
    {
        const val = try msgpack.Payload.strToPayload("oops", allocator);
        defer val.free(allocator);
        try testing.expectError(StorageError.ImmutableField, store_service.validateFieldWrite(tbl_md, "id", val));
        try testing.expectError(StorageError.ImmutableField, store_service.validateFieldWrite(tbl_md, "created_at", val));
    }

    // 2. Unknown field
    {
        const val = try msgpack.Payload.strToPayload("oops", allocator);
        defer val.free(allocator);
        try testing.expectError(StorageError.UnknownField, store_service.validateFieldWrite(tbl_md, "ghost", val));
    }

    // 3. Type mismatch
    {
        // Expected integer, got string
        const val = try msgpack.Payload.strToPayload("not-an-int", allocator);
        defer val.free(allocator);
        try testing.expectError(error.TypeMismatch, store_service.validateFieldWrite(tbl_md, "age", val));
    }

    // 4. Success case
    {
        const val = msgpack.Payload.intToPayload(25);
        const field = try store_service.validateFieldWrite(tbl_md, "age", val);
        try testing.expectEqualStrings("age", field.name);
        try testing.expectEqual(schema_manager.FieldType.integer, field.sql_type);
    }
}
