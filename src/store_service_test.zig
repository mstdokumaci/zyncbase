const std = @import("std");
const testing = std.testing;
const msgpack = @import("msgpack_utils.zig");
const storage_mod = @import("storage_engine.zig");
const store_helpers = @import("store_test_helpers.zig");
const helpers = @import("app_test_helpers.zig");
const sth = @import("storage_engine_test_helpers.zig");
const wire = @import("wire.zig");
const schema = @import("schema.zig");
const store_service = @import("store_service.zig");
const qth = @import("query_parser_test_helpers.zig");
const StorageError = storage_mod.StorageError;
const doc_id = @import("doc_id.zig");

fn writeCtx(namespace_id: i64) store_service.StoreService.WriteContext {
    return .{
        .namespace_id = namespace_id,
        .owner_doc_id = doc_id.zero,
    };
}

fn storePath(allocator: std.mem.Allocator, table_index: usize, id: doc_id.DocId, field_index: ?usize) !msgpack.Payload {
    const segments_len: usize = if (field_index != null) 3 else 2;
    const arr = try allocator.alloc(msgpack.Payload, segments_len);
    errdefer allocator.free(arr);

    arr[0] = msgpack.Payload.uintToPayload(table_index);
    const id_bytes = doc_id.toBytes(id);
    arr[1] = try msgpack.Payload.binToPayload(&id_bytes, allocator);
    if (field_index) |index| {
        arr[2] = msgpack.Payload.uintToPayload(index);
    }

    return .{ .arr = arr };
}

fn documentPath(allocator: std.mem.Allocator, table_index: usize, id: doc_id.DocId) !msgpack.Payload {
    return storePath(allocator, table_index, id, null);
}

fn fieldPath(allocator: std.mem.Allocator, table_index: usize, id: doc_id.DocId, field_index: usize) !msgpack.Payload {
    return storePath(allocator, table_index, id, field_index);
}

test "StoreService: set - full document replacement" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-test", &.{
        .{
            .name = "people",
            .fields = &.{ "name", "age", "tags" },
            .types = &.{ .text, .integer, .array },
        },
    });
    defer app.deinit();

    const service = &app.store_service;
    const people = try app.table("people");

    // 1. Success path: Valid document
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, people.metadata, .{
            .{ "name", "Alice" },
            .{ "age", @as(i64, 30) },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("people"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();

        // Verify with storage engine
        var doc = try people.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("name", "Alice");
        const age = try doc.getFieldInt("age");
        try testing.expectEqual(@as(i64, 30), age);
    }

    // 5. Negative path: Unknown table
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, people.metadata, .{});
        defer val.free(allocator);

        var path = try documentPath(allocator, 999, 1);
        defer path.free(allocator);

        const result = service.setPath(writeCtx(4), path, val);
        try testing.expectError(StorageError.UnknownTable, result);
    }
}

test "StoreService: set - field level update" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-test-field", &.{
        .{
            .name = "items",
            .fields = &.{ "status", "metadata__tags", "a__b__c" },
            .types = &.{ .text, .array, .text },
        },
    });
    defer app.deinit();

    const service = &app.store_service;
    const items = try app.table("items");

    // 1. Success path: Update single field
    {
        const val = try msgpack.Payload.strToPayload("active", allocator);
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("items"), 1, app.fieldIndex("items", "status"));
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();

        // Verify
        var doc = try items.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("status", "active");
    }

    {
        var tags = try allocator.alloc(msgpack.Payload, 2);
        tags[0] = try msgpack.Payload.strToPayload("a", allocator);
        tags[1] = try msgpack.Payload.strToPayload("b", allocator);
        const val = msgpack.Payload{ .arr = tags };
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("items"), 1, app.fieldIndex("items", "metadata__tags"));
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
    }

    {
        const val = try msgpack.Payload.strToPayload("deep-value", allocator);
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("items"), 1, app.fieldIndex("items", "a__b__c"));
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();

        var doc = try items.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("a__b__c", "deep-value");
    }
}

test "StoreService: setPath path validation" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-path-validation", &.{
        .{ .name = "items", .fields = &.{"status"} },
    });
    defer app.deinit();

    const service = &app.store_service;
    const value = try msgpack.Payload.strToPayload("active", allocator);
    defer value.free(allocator);

    try testing.expectError(error.InvalidMessageFormat, service.setPath(writeCtx(1), .nil, value));

    {
        const arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.uintToPayload(app.tableIndex("items"));
        const path = msgpack.Payload{ .arr = arr };
        defer path.free(allocator);

        try testing.expectError(StorageError.InvalidPath, service.setPath(writeCtx(1), path, value));
    }

    {
        const arr = try allocator.alloc(msgpack.Payload, 2);
        arr[0] = msgpack.Payload.uintToPayload(app.tableIndex("items"));
        arr[1] = msgpack.Payload.uintToPayload(1);
        const path = msgpack.Payload{ .arr = arr };
        defer path.free(allocator);

        try testing.expectError(error.InvalidMessageFormat, service.setPath(writeCtx(1), path, value));
    }

    {
        var path = try fieldPath(allocator, app.tableIndex("items"), 1, 999);
        defer path.free(allocator);

        try testing.expectError(StorageError.UnknownField, service.setPath(writeCtx(1), path, value));
    }
}

test "StoreService: remove" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-test-remove", &.{
        .{
            .name = "people",
            .fields = &.{ "name", "age" },
            .types = &.{ .text, .integer },
        },
    });
    defer app.deinit();

    const service = &app.store_service;

    // Setup: Create a document
    {
        const tbl_people = app.schema_manager.getTable("people") orelse return error.UnknownTable;
        const val = try store_helpers.createDocumentMapPayload(allocator, tbl_people, .{
            .{ "name", "Alice" },
            .{ "age", @as(i64, 30) },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("people"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();
    }

    // 1. Negative: Remove field (segments_len == 3) is forbidden
    {
        const tbl_md = app.schema_manager.getTable("people") orelse return error.UnknownTable;
        var path = try fieldPath(allocator, tbl_md.index, 1, app.fieldIndex("people", "name"));
        defer path.free(allocator);

        const result = service.removePath(writeCtx(1), path);
        try testing.expectError(StorageError.InvalidPath, result);
    }

    // 2. Success: Remove document (segments_len == 2)
    {
        var path = try documentPath(allocator, app.tableIndex("people"), 1);
        defer path.free(allocator);

        try service.removePath(writeCtx(1), path);
        try app.storage_engine.flushPendingWrites();

        const tbl_md = app.schema_manager.getTable("people") orelse return error.UnknownTable;
        var managed = try app.storage_engine.selectDocument(allocator, tbl_md.index, 1, 1);
        defer managed.deinit();
        try testing.expect(managed.rows.len == 0);
    }

    // 3. Negative: Unknown table
    {
        var path = try documentPath(allocator, 999, 1);
        defer path.free(allocator);

        const result = service.removePath(writeCtx(4), path);
        try testing.expectError(StorageError.UnknownTable, result);
    }

    // 4. Negative: Field removal is forbidden even if field name is unknown
    {
        const tbl_md = app.schema_manager.getTable("people") orelse return error.UnknownTable;
        var path = try fieldPath(allocator, tbl_md.index, 1, app.fieldIndex("people", "name"));
        defer path.free(allocator);

        const result = service.removePath(writeCtx(1), path);
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

        var path = try fieldPath(allocator, app.tableIndex("collections"), 1, app.fieldIndex("collections", "tags"));
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
    }

    // 2. Negative: Element type mismatch (integer in string array)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.intToPayload(123);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("collections"), 1, app.fieldIndex("collections", "tags"));
        defer path.free(allocator);

        const result = app.store_service.setPath(writeCtx(1), path, val);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }

    // 3. Negative: Non-literal element (nested map)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.mapPayload(allocator);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("collections"), 1, app.fieldIndex("collections", "tags"));
        defer path.free(allocator);

        const result = app.store_service.setPath(writeCtx(1), path, val);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }

    // 4. Success: Valid integers in scores array
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.intToPayload(42);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("collections"), 1, app.fieldIndex("collections", "scores"));
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
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
    const test_table = try app.table("test");

    // 1. Basic Persistence
    {
        const val = try msgpack.Payload.strToPayload("value1", allocator);
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("test"), 1, app.fieldIndex("test", "val"));
        defer path.free(allocator);

        try app.store_service.setPath(writeCtx(2), path, val);
        try app.storage_engine.flushPendingWrites();

        var stored_doc = try test_table.getOne(allocator, 1, 2);
        defer stored_doc.deinit();
        _ = try stored_doc.expectFieldString("val", "value1");
    }

    // 2. Duplicate ids do not cross namespace boundaries
    {
        const val = try msgpack.Payload.strToPayload("value2", allocator);
        defer val.free(allocator);

        // Same table/id, different namespace
        var path = try fieldPath(allocator, app.tableIndex("test"), 1, app.fieldIndex("test", "val"));
        defer path.free(allocator);

        try service.setPath(writeCtx(3), path, val);
        try app.storage_engine.flushPendingWrites();

        // Verify ns-a still has value1
        var doc_a = try test_table.getOne(allocator, 1, 2);
        defer doc_a.deinit();
        _ = try doc_a.expectFieldString("val", "value1");

        // Verify ns-b did not get a second row with the same id.
        var managed_b = try test_table.selectDocument(allocator, 1, 4);
        defer managed_b.deinit();
        try testing.expectEqual(@as(usize, 0), managed_b.rows.len);
    }

    // 3. Updates
    {
        const val = try msgpack.Payload.strToPayload("updated", allocator);
        defer val.free(allocator);

        var path = try fieldPath(allocator, app.tableIndex("test"), 1, app.fieldIndex("test", "val"));
        defer path.free(allocator);

        try app.store_service.setPath(writeCtx(2), path, val);
        try app.storage_engine.flushPendingWrites();

        var doc = try test_table.getOne(allocator, 1, 2);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "updated");
    }
}

test "StoreService: query - basic search" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-basic", &.{
        .{ .name = "people", .fields = &.{"name"} },
    });
    defer app.deinit();
    const people = try app.table("people");

    // Seed data
    try people.insertText(1, 1, "name", "Alice");
    try people.insertText(2, 1, "name", "Bob");
    try people.flush();

    // Build filter: { "conditions": [ ["id", 0, 1] ] }
    const tbl_md = app.schema_manager.getTable("people") orelse return error.UnknownTable;
    const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
        .conditions = .{.{ "id", 0, @as(u128, 1) }},
    });
    defer filter_map.free(allocator);

    var qr = try app.store_service.queryCollection(allocator, 1, msgpack.Payload.uintToPayload(app.tableIndex("people")), filter_map);
    defer qr.deinit(allocator);

    if (qr.results.rows.len == 0) return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 1), qr.results.rows.len);
    const doc = qr.results.rows[0];
    _ = try sth.expectFieldString(doc, people.metadata, "name", "Alice");
}

test "StoreService: query - orderBy and limit" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-sort", &.{
        .{ .name = "tasks", .fields = &.{"title"} },
    });
    defer app.deinit();
    const service = &app.store_service;

    const tasks = [_][]const u8{ "Task A", "Task B", "Task C" };
    for (tasks, 0..) |t, i| {
        try app.insertText("tasks", i + 1, 1, "title", t);
    }
    try app.storage_engine.flushPendingWrites();

    // Filter: orderBy created_at DESC, limit 2
    const tbl_md = app.schema_manager.getTable("tasks") orelse return error.UnknownTable;
    const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
        .orderBy = .{ "created_at", 1 }, // DESC
        .limit = 2,
    });
    defer filter_map.free(allocator);

    var qr = try service.queryCollection(allocator, 1, msgpack.Payload.uintToPayload(app.tableIndex("tasks")), filter_map);
    defer qr.deinit(allocator);

    if (qr.results.rows.len == 0) return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 2), qr.results.rows.len);
    try testing.expect(qr.results.next_cursor != null);
}

test "StoreService: query - negative cases" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-neg", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();
    const service = &app.store_service;

    // 1. Unknown collection
    {
        const tbl_md = app.schema_manager.getTable("data") orelse return error.UnknownTable;
        const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{});
        defer filter_map.free(allocator);
        const err = service.queryCollection(allocator, 1, msgpack.Payload.uintToPayload(999), filter_map);
        try testing.expectError(StorageError.UnknownTable, err);
    }

    // 2. Unknown field
    {
        const tbl_md = app.schema_manager.getTable("data") orelse return error.UnknownTable;
        const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
            .conditions = .{.{ @as(usize, 999), 0, "val" }}, // Explicitly use an invalid field index
        });
        defer filter_map.free(allocator);

        const err = service.queryCollection(allocator, 1, msgpack.Payload.uintToPayload(app.tableIndex("data")), filter_map);
        try testing.expectError(StorageError.UnknownField, err);
    }
}

test "StoreService: queryMore - pagination" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-cursor", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();
    const data_table = try app.table("data");
    const service = &app.store_service;

    // Seed 5 items
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const str = try std.fmt.allocPrint(allocator, "item-{}", .{i});
        defer allocator.free(str);
        const id = try std.fmt.allocPrint(allocator, "id-{}", .{i});
        defer allocator.free(id);
        try data_table.insertText(i + 1, 1, "val", str);
    }
    try data_table.flush();

    // 1. Initial query: limit 2
    const tbl_md = app.schema_manager.getTable("data") orelse return error.UnknownTable;
    const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
        .limit = 2,
    });
    defer filter_map.free(allocator);

    var qr = try service.queryCollection(allocator, 1, msgpack.Payload.uintToPayload(app.tableIndex("data")), filter_map);
    defer qr.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), qr.results.rows.len);
    try testing.expect(qr.results.next_cursor != null);

    // Save the cursor token (encoded)
    const cursor_val = qr.results.next_cursor orelse return error.TestExpectedValue;
    const encoded_cursor = try wire.encodeCursor(allocator, cursor_val);
    defer allocator.free(encoded_cursor);

    // 2. Query with cursor: fetch next 2
    var next_page = try service.queryMore(allocator, app.tableIndex("data"), 1, &qr.filter, encoded_cursor);
    defer next_page.deinit();

    if (next_page.results.rows.len == 0) return error.TestExpectedValue;
    try testing.expectEqual(@as(usize, 2), next_page.results.rows.len);

    // Verify results are different (pagination worked)
    if (qr.results.rows.len == 0) return error.TestExpectedValue;
    const first_doc = qr.results.rows[0];
    const first_page_id = try sth.getFieldDocId(first_doc, data_table.metadata, "id");

    const second_doc = next_page.results.rows[0];
    const second_page_id = try sth.getFieldDocId(second_doc, data_table.metadata, "id");

    try testing.expect(first_page_id != second_page_id);
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
        try testing.expectError(StorageError.ImmutableField, store_service.validateFieldWrite(tbl_md, tbl_md.getFieldIndex("id") orelse unreachable, val));
        try testing.expectError(StorageError.ImmutableField, store_service.validateFieldWrite(tbl_md, tbl_md.getFieldIndex("created_at") orelse unreachable, val));
    }

    // 2. Unknown field
    {
        const val = try msgpack.Payload.strToPayload("oops", allocator);
        defer val.free(allocator);
        try testing.expectError(StorageError.UnknownField, store_service.validateFieldWrite(tbl_md, 999, val));
    }

    // 3. Type mismatch
    {
        // Expected integer, got string
        const val = try msgpack.Payload.strToPayload("not-an-int", allocator);
        defer val.free(allocator);
        try testing.expectError(error.TypeMismatch, store_service.validateFieldWrite(tbl_md, tbl_md.getFieldIndex("age") orelse unreachable, val));
    }

    // 4. Success case
    {
        const val = msgpack.Payload.intToPayload(25);
        const field = try store_service.validateFieldWrite(tbl_md, tbl_md.getFieldIndex("age") orelse unreachable, val);
        try testing.expectEqualStrings("age", field.name);
        try testing.expectEqual(schema.FieldType.integer, field.storage_type);
    }
}

// ── Batch helpers ──────────────────────────────────────────────────────

/// Build a msgpack batch "set" tuple: ["s", path, value]
fn batchSetTuple(
    allocator: std.mem.Allocator,
    table_index: usize,
    id: doc_id.DocId,
    value: msgpack.Payload,
) !msgpack.Payload {
    const path = try documentPath(allocator, table_index, id);
    errdefer path.free(allocator);

    const s_str = try msgpack.Payload.strToPayload("s", allocator);
    errdefer s_str.free(allocator);

    const cloned_value = try value.deepClone(allocator);
    errdefer cloned_value.free(allocator);

    const arr = try allocator.alloc(msgpack.Payload, 3);
    arr[0] = s_str;
    arr[1] = path;
    arr[2] = cloned_value;
    return .{ .arr = arr };
}

/// Build a msgpack batch "remove" tuple: ["r", path]
fn batchRemoveTuple(
    allocator: std.mem.Allocator,
    table_index: usize,
    id: doc_id.DocId,
) !msgpack.Payload {
    const path = try documentPath(allocator, table_index, id);
    errdefer path.free(allocator);

    const r_str = try msgpack.Payload.strToPayload("r", allocator);
    errdefer r_str.free(allocator);

    const arr = try allocator.alloc(msgpack.Payload, 2);
    arr[0] = r_str;
    arr[1] = path;
    return .{ .arr = arr };
}

test "StoreService: batchWrite - multi-set inserts documents atomically" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-multi-set", &.{
        .{
            .name = "people",
            .fields = &.{ "name", "age" },
            .types = &.{ .text, .integer },
        },
    });
    defer app.deinit();

    const service = &app.store_service;
    const people = try app.table("people");

    const val1 = try store_helpers.createDocumentMapPayload(allocator, people.metadata, .{
        .{ "name", "Alice" },
        .{ "age", @as(i64, 30) },
    });
    defer val1.free(allocator);

    const val2 = try store_helpers.createDocumentMapPayload(allocator, people.metadata, .{
        .{ "name", "Bob" },
        .{ "age", @as(i64, 25) },
    });
    defer val2.free(allocator);

    const t1 = try batchSetTuple(allocator, app.tableIndex("people"), 1, val1);
    defer t1.free(allocator);
    const t2 = try batchSetTuple(allocator, app.tableIndex("people"), 2, val2);
    defer t2.free(allocator);

    const ops_arr = try allocator.alloc(msgpack.Payload, 2);
    defer allocator.free(ops_arr);
    ops_arr[0] = t1;
    ops_arr[1] = t2;
    const ops_payload = msgpack.Payload{ .arr = ops_arr };

    try service.batchWrite(writeCtx(1), ops_payload);
    try app.storage_engine.flushPendingWrites();

    // Verify both documents exist
    var doc1 = try people.getOne(allocator, 1, 1);
    defer doc1.deinit();
    _ = try doc1.expectFieldString("name", "Alice");
    try testing.expectEqual(@as(i64, 30), try doc1.getFieldInt("age"));

    var doc2 = try people.getOne(allocator, 2, 1);
    defer doc2.deinit();
    _ = try doc2.expectFieldString("name", "Bob");
    try testing.expectEqual(@as(i64, 25), try doc2.getFieldInt("age"));
}

test "StoreService: batchWrite - mixed set and remove" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-mixed", &.{
        .{
            .name = "items",
            .fields = &.{"status"},
            .types = &.{.text},
        },
    });
    defer app.deinit();

    const service = &app.store_service;
    const items = try app.table("items");

    // Seed a document to be deleted later
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
            .{ "status", "old" },
        });
        defer val.free(allocator);
        var path = try documentPath(allocator, app.tableIndex("items"), 1);
        defer path.free(allocator);
        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();
    }

    // Batch: remove doc 1, insert doc 2
    const val_new = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
        .{ "status", "fresh" },
    });
    defer val_new.free(allocator);

    const rm = try batchRemoveTuple(allocator, app.tableIndex("items"), 1);
    defer rm.free(allocator);
    const set_op = try batchSetTuple(allocator, app.tableIndex("items"), 2, val_new);
    defer set_op.free(allocator);

    const ops_arr = try allocator.alloc(msgpack.Payload, 2);
    defer allocator.free(ops_arr);
    ops_arr[0] = rm;
    ops_arr[1] = set_op;
    const ops_payload = msgpack.Payload{ .arr = ops_arr };

    try service.batchWrite(writeCtx(1), ops_payload);
    try app.storage_engine.flushPendingWrites();

    // Doc 1 should be gone
    var managed = try items.selectDocument(allocator, 1, 1);
    defer managed.deinit();
    try testing.expectEqual(@as(usize, 0), managed.rows.len);

    // Doc 2 should exist
    var doc2 = try items.getOne(allocator, 2, 1);
    defer doc2.deinit();
    _ = try doc2.expectFieldString("status", "fresh");
}

test "StoreService: batchWrite - empty ops is a no-op" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-empty", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    const empty_arr = try allocator.alloc(msgpack.Payload, 0);
    defer allocator.free(empty_arr);
    const ops_payload = msgpack.Payload{ .arr = empty_arr };

    // Should succeed silently
    try app.store_service.batchWrite(writeCtx(1), ops_payload);
}

test "StoreService: batchWrite - rejects invalid kind" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-bad-kind", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    // Build a tuple with unknown kind "x"
    const x_str = try msgpack.Payload.strToPayload("x", allocator);
    defer x_str.free(allocator);
    var path = try documentPath(allocator, app.tableIndex("data"), 1);
    defer path.free(allocator);

    const tuple_arr = try allocator.alloc(msgpack.Payload, 2);
    defer allocator.free(tuple_arr);
    tuple_arr[0] = x_str;
    tuple_arr[1] = path;
    const tuple = msgpack.Payload{ .arr = tuple_arr };

    const ops_arr = try allocator.alloc(msgpack.Payload, 1);
    defer allocator.free(ops_arr);
    ops_arr[0] = tuple;
    const ops_payload = msgpack.Payload{ .arr = ops_arr };

    try testing.expectError(error.InvalidMessageFormat, app.store_service.batchWrite(writeCtx(1), ops_payload));
}

test "StoreService: batchWrite - rejects set with missing value" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-missing-val", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    // Build a "set" tuple with only 2 elements (missing the value)
    const s_str = try msgpack.Payload.strToPayload("s", allocator);
    defer s_str.free(allocator);
    var path = try documentPath(allocator, app.tableIndex("data"), 1);
    defer path.free(allocator);

    const tuple_arr = try allocator.alloc(msgpack.Payload, 2);
    defer allocator.free(tuple_arr);
    tuple_arr[0] = s_str;
    tuple_arr[1] = path;
    const tuple = msgpack.Payload{ .arr = tuple_arr };

    const ops_arr = try allocator.alloc(msgpack.Payload, 1);
    defer allocator.free(ops_arr);
    ops_arr[0] = tuple;
    const ops_payload = msgpack.Payload{ .arr = ops_arr };

    try testing.expectError(error.MissingRequiredFields, app.store_service.batchWrite(writeCtx(1), ops_payload));
}

test "StoreService: batchWrite - rejects unknown table" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-unknown-tbl", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    const val = try store_helpers.createDocumentMapPayload(allocator, (try app.table("data")).metadata, .{
        .{ "val", "test" },
    });
    defer val.free(allocator);

    const t = try batchSetTuple(allocator, 999, 1, val);
    defer t.free(allocator);

    const ops_arr = try allocator.alloc(msgpack.Payload, 1);
    defer allocator.free(ops_arr);
    ops_arr[0] = t;
    const ops_payload = msgpack.Payload{ .arr = ops_arr };

    try testing.expectError(StorageError.UnknownTable, app.store_service.batchWrite(writeCtx(1), ops_payload));
}

test "StoreService: batchWrite - rejects non-array payload" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-not-array", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    try testing.expectError(error.InvalidMessageFormat, app.store_service.batchWrite(writeCtx(1), .nil));
}

test "StoreService: batchWrite - rejects batch exceeding 500 ops" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-too-large", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    // Allocate 501 nil entries — the length check happens before parsing
    const ops_arr = try allocator.alloc(msgpack.Payload, 501);
    defer allocator.free(ops_arr);
    @memset(ops_arr, .nil);
    const ops_payload = msgpack.Payload{ .arr = ops_arr };

    try testing.expectError(error.BatchTooLarge, app.store_service.batchWrite(writeCtx(1), ops_payload));
}
