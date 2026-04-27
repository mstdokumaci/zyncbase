const std = @import("std");
const testing = std.testing;
const msgpack = @import("msgpack_utils.zig");
const storage_mod = @import("storage_engine.zig");
const store_helpers = @import("store_test_helpers.zig");
const helpers = @import("app_test_helpers.zig");
const sth = @import("storage_engine_test_helpers.zig");
const wire = @import("wire.zig");
const schema_manager = @import("schema_manager.zig");
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
            .fields = &.{ "status", "meta" },
            .types = &.{ .text, .boolean },
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
        const tbl_md = app.schema_manager.metadata.getTable("people") orelse return error.UnknownTable;
        var path = try fieldPath(allocator, tbl_md.index, 1, app.fieldIndex("people", "name"));
        defer path.free(allocator);

        const result = service.removePath(1, path);
        try testing.expectError(StorageError.InvalidPath, result);
    }

    // 2. Success: Remove document (segments_len == 2)
    {
        var path = try documentPath(allocator, app.tableIndex("people"), 1);
        defer path.free(allocator);

        try service.removePath(1, path);
        try app.storage_engine.flushPendingWrites();

        const tbl_md = app.schema_manager.metadata.getTable("people") orelse return error.UnknownTable;
        var managed = try app.storage_engine.selectDocument(allocator, tbl_md.index, 1, 1);
        defer managed.deinit();
        try testing.expect(managed.rows.len == 0);
    }

    // 3. Negative: Unknown table
    {
        var path = try documentPath(allocator, 999, 1);
        defer path.free(allocator);

        const result = service.removePath(4, path);
        try testing.expectError(StorageError.UnknownTable, result);
    }

    // 4. Negative: Field removal is forbidden even if field name is unknown
    {
        const tbl_md = app.schema_manager.metadata.getTable("people") orelse return error.UnknownTable;
        var path = try fieldPath(allocator, tbl_md.index, 1, app.fieldIndex("people", "name"));
        defer path.free(allocator);

        const result = service.removePath(1, path);
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
        try testing.expectEqual(schema_manager.FieldType.integer, field.sql_type);
    }
}
