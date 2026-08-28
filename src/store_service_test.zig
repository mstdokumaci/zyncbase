const std = @import("std");

const helpers = @import("app_test_helpers.zig");
const msgpack = @import("msgpack_utils.zig");
const query_ast = @import("query/ast.zig");
const query_parser = @import("query/parser.zig");
const qth = @import("query/test_helpers.zig");
const schema_system = @import("schema/system.zig");
const schema_types = @import("schema/types.zig");
const storage_mod = @import("storage_engine.zig");
const sth = @import("storage_engine_test_helpers.zig");
const store_service = @import("store_service.zig");
const store_helpers = @import("store_test_helpers.zig");
const typed_doc_id = @import("typed/doc_id.zig");
const typed = @import("typed/types.zig");

const testing = std.testing;
const StorageError = storage_mod.StorageError;

fn writeCtx(namespace_id: i64) store_service.StoreService.WriteContext {
    return .{
        .namespace_id = namespace_id,
        .namespace = "public",
        .owner_doc_id = typed_doc_id.zero,
        .session_user_id = typed_doc_id.zero,
    };
}

fn readCtx(namespace_id: i64) store_service.StoreService.ReadContext {
    return .{
        .conn_id = 1,
        .msg_id = 1,
        .session_user_id = typed_doc_id.zero,
        .session_external_id = null,
        .session_claims = null,
        .namespace = "public",
        .namespace_id = namespace_id,
        .allocator = std.heap.smp_allocator,
    };
}

fn storePath(allocator: std.mem.Allocator, table_index: usize, id: typed_doc_id.DocId) !msgpack.Payload {
    const arr = try allocator.alloc(msgpack.Payload, 2);
    errdefer allocator.free(arr);

    arr[0] = msgpack.Payload.uintToPayload(table_index);
    const id_bytes = typed_doc_id.toBytes(id);
    arr[1] = try msgpack.Payload.binToPayload(&id_bytes, allocator);

    return .{ .arr = arr };
}

fn documentPath(allocator: std.mem.Allocator, table_index: usize, id: typed_doc_id.DocId) !msgpack.Payload {
    return storePath(allocator, table_index, id);
}

test "StoreService: set - full document replacement" {
    const allocator = std.heap.smp_allocator;
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

test "StoreService: set - sparse field update" {
    const allocator = std.heap.smp_allocator;
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

    // 1. Update single field via sparse map
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
            .{ "status", "active" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("items"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();

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

        const map_val = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
            .{ "metadata__tags", val },
        });
        defer map_val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("items"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, map_val);
    }

    {
        const val = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
            .{ "a__b__c", "deep-value" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("items"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();

        var doc = try items.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("a__b__c", "deep-value");
    }
}

test "StoreService: setPath path validation" {
    const allocator = std.heap.smp_allocator;
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
        const arr = try allocator.alloc(msgpack.Payload, 3);
        arr[0] = msgpack.Payload.uintToPayload(app.tableIndex("items"));
        const id_bytes = typed_doc_id.toBytes(1);
        arr[1] = try msgpack.Payload.binToPayload(&id_bytes, allocator);
        arr[2] = msgpack.Payload.uintToPayload(999);
        const path = msgpack.Payload{ .arr = arr };
        defer path.free(allocator);

        try testing.expectError(StorageError.InvalidPath, service.setPath(writeCtx(1), path, value));
    }
}

test "StoreService: remove" {
    const allocator = std.heap.smp_allocator;
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
        const tbl_people = app.schema.table("people") orelse return error.UnknownTable;
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

    // 1. Negative: Depth-3 path is forbidden
    {
        const arr = try allocator.alloc(msgpack.Payload, 3);
        arr[0] = msgpack.Payload.uintToPayload(app.tableIndex("people"));
        const id_bytes = typed_doc_id.toBytes(1);
        arr[1] = try msgpack.Payload.binToPayload(&id_bytes, allocator);
        arr[2] = msgpack.Payload.uintToPayload(app.fieldIndex("people", "name"));
        const path = msgpack.Payload{ .arr = arr };
        defer path.free(allocator);

        const result = service.removePath(writeCtx(1), path);
        try testing.expectError(StorageError.InvalidPath, result);
    }

    // 2. Success: Remove document (depth-2)
    {
        var path = try documentPath(allocator, app.tableIndex("people"), 1);
        defer path.free(allocator);

        try service.removePath(writeCtx(1), path);
        try app.storage_engine.flushPendingWrites();

        const tbl_md = app.schema.table("people") orelse return error.UnknownTable;
        const record = try sth.readDoc(allocator, &app.storage_engine, tbl_md.index, 1, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record == null);
    }

    // 3. Negative: Unknown table
    {
        var path = try documentPath(allocator, 999, 1);
        defer path.free(allocator);

        const result = service.removePath(writeCtx(4), path);
        try testing.expectError(StorageError.UnknownTable, result);
    }
}

test "StoreService: array validation" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;

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

    // 1. Success: Valid literal array of strings via sparse map
    {
        var arr = try allocator.alloc(msgpack.Payload, 2);
        arr[0] = try msgpack.Payload.strToPayload("tag1", allocator);
        arr[1] = try msgpack.Payload.strToPayload("tag2", allocator);
        const tags_val = msgpack.Payload{ .arr = arr };
        defer tags_val.free(allocator);

        const collections = try app.table("collections");
        const val = try store_helpers.createDocumentMapPayload(allocator, collections.metadata, .{
            .{ "tags", tags_val },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("collections"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
    }

    // 2. Negative: Element type mismatch (integer in string array)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.intToPayload(123);
        const tags_val = msgpack.Payload{ .arr = arr };
        defer tags_val.free(allocator);

        const collections = try app.table("collections");
        const val = try store_helpers.createDocumentMapPayload(allocator, collections.metadata, .{
            .{ "tags", tags_val },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("collections"), 1);
        defer path.free(allocator);

        const result = app.store_service.setPath(writeCtx(1), path, val);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }

    // 3. Negative: Non-literal element (nested map)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.mapPayload(allocator);
        const tags_val = msgpack.Payload{ .arr = arr };
        defer tags_val.free(allocator);

        const collections = try app.table("collections");
        const val = try store_helpers.createDocumentMapPayload(allocator, collections.metadata, .{
            .{ "tags", tags_val },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("collections"), 1);
        defer path.free(allocator);

        const result = app.store_service.setPath(writeCtx(1), path, val);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }

    // 4. Success: Valid integers in scores array via sparse map
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.intToPayload(42);
        const scores_val = msgpack.Payload{ .arr = arr };
        defer scores_val.free(allocator);

        const collections = try app.table("collections");
        const val = try store_helpers.createDocumentMapPayload(allocator, collections.metadata, .{
            .{ "scores", scores_val },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("collections"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
    }
}

test "StoreService: persistence and namespace isolation" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "store-service-isolation", &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer app.deinit();

    const service = &app.store_service;
    const test_table = try app.table("test");

    // 1. Basic Persistence
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, test_table.metadata, .{
            .{ "val", "value1" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("test"), 1);
        defer path.free(allocator);

        try app.store_service.setPath(writeCtx(2), path, val);
        try app.storage_engine.flushPendingWrites();

        var stored_doc = try test_table.getOne(allocator, 1, 2);
        defer stored_doc.deinit();
        _ = try stored_doc.expectFieldString("val", "value1");
    }

    // 2. Duplicate ids do not cross namespace boundaries
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, test_table.metadata, .{
            .{ "val", "value2" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("test"), 1);
        defer path.free(allocator);

        try service.setPath(writeCtx(3), path, val);
        try app.storage_engine.flushPendingWrites();

        var doc_a = try test_table.getOne(allocator, 1, 2);
        defer doc_a.deinit();
        _ = try doc_a.expectFieldString("val", "value1");

        const record_b = try test_table.readDoc(allocator, 1, 4);
        defer if (record_b) |r| r.deinit(allocator);
        try testing.expect(record_b == null);
    }

    // 3. Updates
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, test_table.metadata, .{
            .{ "val", "updated" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("test"), 1);
        defer path.free(allocator);

        try app.store_service.setPath(writeCtx(2), path, val);
        try app.storage_engine.flushPendingWrites();

        var doc = try test_table.getOne(allocator, 1, 2);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "updated");
    }
}

test "StoreService: query - basic search" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-basic", &.{
        .{ .name = "people", .fields = &.{"name"} },
    });
    defer app.deinit();

    const ctx = readCtx(1);
    const table_index = app.tableIndex("people");

    // Build filter: { "conditions": [ ["id", 0, 1] ] }
    const tbl_md = app.schema.table("people") orelse return error.UnknownTable;
    const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
        .conditions = .{.{ "id", 0, @as(u128, 1) }},
    });
    defer filter_map.free(allocator);

    var read_req = try app.store_service.prepareQueryRead(ctx, table_index, filter_map, null);
    defer read_req.deinit(allocator);

    try testing.expectEqual(table_index, read_req.table_index);
    try testing.expectEqual(@as(i64, 1), read_req.namespace_id);
    try testing.expectEqual(@as(?u64, null), read_req.sub_id);
    // Filter conditions are parsed from the payload
    try testing.expect(read_req.filter.predicate.conditions != null);
}

test "StoreService: query - orderBy and limit" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-sort", &.{
        .{ .name = "tasks", .fields = &.{"title"} },
    });
    defer app.deinit();

    const ctx = readCtx(1);
    const table_index = app.tableIndex("tasks");

    // Filter: orderBy created_at DESC, limit 2
    const tbl_md = app.schema.table("tasks") orelse return error.UnknownTable;
    const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
        .orderBy = .{.{ "created_at", 1 }}, // DESC
        .limit = 2,
    });
    defer filter_map.free(allocator);

    var read_req = try app.store_service.prepareQueryRead(ctx, table_index, filter_map, null);
    defer read_req.deinit(allocator);

    try testing.expectEqual(@as(?u32, 2), read_req.filter.limit);
    // created_at DESC followed by hidden id ASC tie-breaker.
    const created_at_index = tbl_md.fieldIndex("created_at") orelse return error.UnknownField;
    try testing.expectEqual(created_at_index, read_req.filter.order_by[0].field_index);
    try testing.expectEqual(true, read_req.filter.order_by[0].desc);
}

test "StoreService: query - negative cases" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-neg", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();
    const service = &app.store_service;
    const ctx = readCtx(1);

    // 1. Unknown table
    {
        const tbl_md = app.schema.table("data") orelse return error.UnknownTable;
        const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{});
        defer filter_map.free(allocator);
        const err = service.prepareQueryRead(ctx, 999, filter_map, null);
        try testing.expectError(error.UnknownTable, err);
    }

    // 2. Unknown field in filter conditions
    {
        const tbl_md = app.schema.table("data") orelse return error.UnknownTable;
        const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
            .conditions = .{.{ @as(usize, 999), 0, "val" }},
        });
        defer filter_map.free(allocator);
        const err = service.prepareQueryRead(ctx, app.tableIndex("data"), filter_map, null);
        try testing.expectError(error.UnknownField, err);
    }
}

test "StoreService: queryMore - pagination" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "service-query-cursor", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    const ctx = readCtx(1);
    const table_index = app.tableIndex("data");
    const sub_id: u64 = 42;

    // Build a subscription filter with limit 2
    const tbl_md = app.schema.table("data") orelse return error.UnknownTable;
    const filter_map = try qth.createQueryFilterPayload(allocator, tbl_md, .{
        .limit = 2,
    });
    defer filter_map.free(allocator);

    // Prepare an initial subscribe read request to get a properly parsed filter
    var initial_req = try app.store_service.prepareQueryRead(ctx, table_index, filter_map, sub_id);
    defer initial_req.deinit(allocator);

    // Encode a synthetic cursor for the load-more request.
    // Canonical default order is [id ASC], so the single value must be a doc_id.
    const descriptors = [_]query_ast.SortDescriptor{
        .{ .field_index = schema_system.id_field_index, .desc = false },
    };
    const cursor_values = [_]typed.Value{
        .{ .scalar = .{ .doc_id = typed_doc_id.zero } },
    };
    const cursor_token = try query_parser.encodeCursorToken(allocator, table_index, &descriptors, &cursor_values);
    defer allocator.free(cursor_token);

    // Prepare a load-more read request using the initial filter and cursor
    var load_more_req = try app.store_service.prepareLoadMoreRead(
        ctx,
        table_index,
        1, // namespace_id
        initial_req.filter,
        sub_id,
        cursor_token,
    );
    defer load_more_req.deinit(allocator);

    try testing.expectEqual(sub_id, load_more_req.sub_id.?);
    try testing.expect(load_more_req.filter.after != null);
}

test "StoreService: validateFieldWrite tests" {
    const allocator = std.heap.smp_allocator;
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
    const tbl_md = service.schema.table("users") orelse return error.TestExpectedValue;

    // 1. Immutable fields
    {
        const val = try msgpack.Payload.strToPayload("oops", allocator);
        defer val.free(allocator);
        try testing.expectError(StorageError.ImmutableField, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("id") orelse unreachable, val));
        try testing.expectError(StorageError.ImmutableField, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("created_at") orelse unreachable, val));
    }

    // 2. Unknown field
    {
        const val = try msgpack.Payload.strToPayload("oops", allocator);
        defer val.free(allocator);
        try testing.expectError(StorageError.UnknownField, store_service.validateFieldWrite(allocator, tbl_md, 999, val));
    }

    // 3. Type mismatch
    {
        // Expected integer, got string
        const val = try msgpack.Payload.strToPayload("not-an-int", allocator);
        defer val.free(allocator);
        try testing.expectError(error.TypeMismatch, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("age") orelse unreachable, val));
    }

    // 4. Success case
    {
        const val = msgpack.Payload.intToPayload(25);
        const field = try store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("age") orelse unreachable, val);
        try testing.expectEqualStrings("age", field.name);
        try testing.expectEqual(schema_types.FieldType.integer, field.storage_type);
    }
}

test "StoreService: validateFieldWrite with constraints" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;

    const schema_json =
        \\{
        \\  "version":"1.0.0",
        \\  "store":{
        \\    "users":{
        \\      "fields":{
        \\        "status":{"type":"string","enum":["active","idle","away"]},
        \\        "code":{"type":"string","pattern":"^[A-Z]{3}-[0-9]{3}$"},
        \\        "email":{"type":"string","format":"email"},
        \\        "username":{"type":"string","minLength":3,"maxLength":10},
        \\        "age":{"type":"integer","minimum":18,"maximum":120}
        \\      }
        \\    }
        \\  }
        \\}
    ;

    try app.initWithSchemaJSON(allocator, "store-validate-constraints", schema_json);
    defer app.deinit();

    const service = &app.store_service;
    const tbl_md = service.schema.table("users") orelse return error.TestExpectedValue;

    // Status: enum check
    {
        const valid_val = try msgpack.Payload.strToPayload("active", allocator);
        defer valid_val.free(allocator);
        _ = try store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("status") orelse unreachable, valid_val);

        const invalid_val = try msgpack.Payload.strToPayload("banned", allocator);
        defer invalid_val.free(allocator);
        try testing.expectError(error.EnumViolation, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("status") orelse unreachable, invalid_val));
    }

    // Code: pattern check
    {
        const valid_val = try msgpack.Payload.strToPayload("ABC-123", allocator);
        defer valid_val.free(allocator);
        _ = try store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("code") orelse unreachable, valid_val);

        const invalid_val = try msgpack.Payload.strToPayload("abc-123", allocator);
        defer invalid_val.free(allocator);
        try testing.expectError(error.PatternViolation, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("code") orelse unreachable, invalid_val));
    }

    // Email: format check
    {
        const valid_val = try msgpack.Payload.strToPayload("alice@example.com", allocator);
        defer valid_val.free(allocator);
        _ = try store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("email") orelse unreachable, valid_val);

        const invalid_val = try msgpack.Payload.strToPayload("not-an-email", allocator);
        defer invalid_val.free(allocator);
        try testing.expectError(error.FormatViolation, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("email") orelse unreachable, invalid_val));
    }

    // Username: minLength & maxLength check
    {
        const too_short = try msgpack.Payload.strToPayload("ab", allocator);
        defer too_short.free(allocator);
        try testing.expectError(error.LengthViolation, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("username") orelse unreachable, too_short));

        const valid_val = try msgpack.Payload.strToPayload("alice", allocator);
        defer valid_val.free(allocator);
        _ = try store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("username") orelse unreachable, valid_val);

        const too_long = try msgpack.Payload.strToPayload("this_is_too_long_username", allocator);
        defer too_long.free(allocator);
        try testing.expectError(error.LengthViolation, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("username") orelse unreachable, too_long));
    }

    // Age: minimum & maximum check
    {
        const too_young = msgpack.Payload.intToPayload(17);
        try testing.expectError(error.RangeViolation, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("age") orelse unreachable, too_young));

        const valid_val = msgpack.Payload.intToPayload(25);
        _ = try store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("age") orelse unreachable, valid_val);

        const too_old = msgpack.Payload.intToPayload(121);
        try testing.expectError(error.RangeViolation, store_service.validateFieldWrite(allocator, tbl_md, tbl_md.fieldIndex("age") orelse unreachable, too_old));
    }
}

// ── Batch helpers ──────────────────────────────────────────────────────

/// Build a msgpack batch "set" tuple: ["s", path, value]
fn batchSetTuple(
    allocator: std.mem.Allocator,
    table_index: usize,
    id: typed_doc_id.DocId,
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

fn batchTextSetTuple(
    allocator: std.mem.Allocator,
    table: *const schema_types.Table,
    id: typed_doc_id.DocId,
    field: []const u8,
    value: []const u8,
) !msgpack.Payload {
    const document = try store_helpers.createDocumentMapPayload(allocator, table, .{.{ field, value }});
    defer document.free(allocator);
    return batchSetTuple(allocator, table.index, id, document);
}

/// Build a msgpack batch "remove" tuple: ["r", path]
fn batchRemoveTuple(
    allocator: std.mem.Allocator,
    table_index: usize,
    id: typed_doc_id.DocId,
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
    const allocator = std.heap.smp_allocator;
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
    const allocator = std.heap.smp_allocator;
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
    const record = try items.readDoc(allocator, 1, 1);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record == null);

    // Doc 2 should exist
    var doc2 = try items.getOne(allocator, 2, 1);
    defer doc2.deinit();
    _ = try doc2.expectFieldString("status", "fresh");
}

test "StoreService: batchWrite coalesces transaction changes to first-old and last-new endpoints" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-change-coalescing", &.{.{
        .name = "items",
        .fields = &.{"status"},
        .types = &.{.text},
    }});
    defer app.deinit();

    const service = &app.store_service;
    const items = try app.table("items");
    const status_index = items.metadata.fieldIndex("status") orelse return error.TestExpectedValue;

    for ([_]struct { id: typed_doc_id.DocId, status: []const u8 }{
        .{ .id = 1, .status = "seed-1" },
        .{ .id = 3, .status = "seed-3" },
        .{ .id = 4, .status = "seed-4" },
    }) |seed| {
        const value = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{.{ "status", seed.status }});
        defer value.free(allocator);
        var path = try documentPath(allocator, items.metadata.index, seed.id);
        defer path.free(allocator);
        try service.setPath(writeCtx(1), path, value);
    }
    try app.storage_engine.flushPendingWrites();
    for (app.test_context.change_queue.?.shards) |*shard| {
        while (shard.popTimed(0)) |job| {
            var owned = job;
            owned.deinit(app.storage_engine.allocator);
        }
    }

    const ops = try allocator.alloc(msgpack.Payload, 11);
    var initialized_ops: usize = 0;
    defer {
        for (ops[0..initialized_ops]) |op| op.free(allocator);
        allocator.free(ops);
    }
    for (ops, 0..) |*op, index| {
        op.* = switch (index) {
            0 => try batchTextSetTuple(allocator, items.metadata, 1, "status", "middle-1"),
            1 => try batchTextSetTuple(allocator, items.metadata, 2, "status", "middle-2"),
            2 => try batchTextSetTuple(allocator, items.metadata, 3, "status", "middle-3"),
            3 => try batchRemoveTuple(allocator, items.metadata.index, 4),
            4 => try batchTextSetTuple(allocator, items.metadata, 5, "status", "middle-5"),
            5 => try batchTextSetTuple(allocator, items.metadata, 6, "status", "final-6"),
            6 => try batchTextSetTuple(allocator, items.metadata, 1, "status", "final-1"),
            7 => try batchTextSetTuple(allocator, items.metadata, 2, "status", "final-2"),
            8 => try batchRemoveTuple(allocator, items.metadata.index, 3),
            9 => try batchTextSetTuple(allocator, items.metadata, 4, "status", "final-4"),
            10 => try batchRemoveTuple(allocator, items.metadata.index, 5),
            else => unreachable,
        };
        initialized_ops += 1;
    }

    try service.batchWrite(writeCtx(1), .{ .arr = ops });
    try app.storage_engine.flushPendingWrites();

    var seen = [_]bool{false} ** 7;
    var change_count: usize = 0;
    for (app.test_context.change_queue.?.shards) |*shard| {
        while (shard.popTimed(0)) |job| {
            var owned = job;
            defer owned.deinit(app.storage_engine.allocator);
            const change = owned.change;
            const id: usize = @intCast(change.doc_id);
            try testing.expect(id > 0 and id < seen.len);
            try testing.expect(!seen[id]);
            seen[id] = true;
            change_count += 1;

            switch (id) {
                1 => {
                    try testing.expectEqual(.update, change.operation);
                    try testing.expectEqualStrings("seed-1", change.old_record.?.values[status_index].scalar.text);
                    try testing.expectEqualStrings("final-1", change.new_record.?.values[status_index].scalar.text);
                },
                2 => {
                    try testing.expectEqual(.insert, change.operation);
                    try testing.expect(change.old_record == null);
                    try testing.expectEqualStrings("final-2", change.new_record.?.values[status_index].scalar.text);
                },
                3 => {
                    try testing.expectEqual(.delete, change.operation);
                    try testing.expectEqualStrings("seed-3", change.old_record.?.values[status_index].scalar.text);
                    try testing.expect(change.new_record == null);
                },
                4 => {
                    try testing.expectEqual(.update, change.operation);
                    try testing.expectEqualStrings("seed-4", change.old_record.?.values[status_index].scalar.text);
                    try testing.expectEqualStrings("final-4", change.new_record.?.values[status_index].scalar.text);
                },
                6 => {
                    try testing.expectEqual(.insert, change.operation);
                    try testing.expect(change.old_record == null);
                    try testing.expectEqualStrings("final-6", change.new_record.?.values[status_index].scalar.text);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }
    try testing.expectEqual(@as(usize, 5), change_count);
    try testing.expect(seen[1] and seen[2] and seen[3] and seen[4] and !seen[5] and seen[6]);

    for ([_]struct { id: typed_doc_id.DocId, status: []const u8 }{
        .{ .id = 1, .status = "final-1" },
        .{ .id = 2, .status = "final-2" },
        .{ .id = 4, .status = "final-4" },
        .{ .id = 6, .status = "final-6" },
    }) |expected| {
        var document = try items.getOne(allocator, expected.id, 1);
        defer document.deinit();
        _ = try document.expectFieldString("status", expected.status);
    }
    try testing.expect((try items.readDoc(allocator, 3, 1)) == null);
    try testing.expect((try items.readDoc(allocator, 5, 1)) == null);
    try testing.expect(app.storage_engine.documentExists(items.metadata.index, 4));
    try testing.expect(!app.storage_engine.documentExists(items.metadata.index, 5));
}

test "StoreService: batchWrite - empty ops is a no-op" {
    const allocator = std.heap.smp_allocator;
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
    const allocator = std.heap.smp_allocator;
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

test "StoreService: batchWrite - cleans a valid prefix when a later entry is malformed" {
    const allocator = std.testing.allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-valid-prefix-cleanup", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    const table = try app.table("data");
    const value = try store_helpers.createDocumentMapPayload(allocator, table.metadata, .{
        .{ "val", "not-written" },
    });
    defer value.free(allocator);
    const valid = try batchSetTuple(allocator, app.tableIndex("data"), 1, value);
    defer valid.free(allocator);

    const ops = try allocator.alloc(msgpack.Payload, 2);
    defer allocator.free(ops);
    ops[0] = valid;
    ops[1] = .nil;

    try testing.expectError(error.InvalidMessageFormat, app.store_service.batchWrite(writeCtx(1), .{ .arr = ops }));
    try app.storage_engine.flushPendingWrites();
    const record = try table.readDoc(allocator, 1, 1);
    defer if (record) |owned| owned.deinit(allocator);
    try testing.expect(record == null);
}

test "StoreService: batchWrite - rejects set with missing value" {
    const allocator = std.heap.smp_allocator;
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
    const allocator = std.heap.smp_allocator;
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
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "batch-not-array", &.{
        .{ .name = "data", .fields = &.{"val"} },
    });
    defer app.deinit();

    try testing.expectError(error.InvalidMessageFormat, app.store_service.batchWrite(writeCtx(1), .nil));
}

test "StoreService: batchWrite - rejects batch exceeding 500 ops" {
    const allocator = std.heap.smp_allocator;
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

test "StoreService: resolveStoreScope uses global users table by default" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    try app.init(allocator, "scope-global-users", &.{
        .{ .name = "items", .fields = &.{"name"} },
    });
    defer app.deinit();

    const scope_a = try app.resolveStoreScopeForTest("alpha", "client-a");
    const scope_b = try app.resolveStoreScopeForTest("beta", "client-a");
    const scope_c = try app.resolveStoreScopeForTest("alpha", "client-b");

    try testing.expect(scope_a.namespace_id != scope_b.namespace_id);
    try testing.expectEqual(scope_a.user_doc_id, scope_b.user_doc_id);
    try testing.expect(scope_a.user_doc_id != scope_c.user_doc_id);

    const users = try app.tableMetadata("users");
    const record = try sth.readDoc(allocator, &app.storage_engine, users.index, scope_a.user_doc_id, schema_system.global_namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
}

test "StoreService: resolveStoreScope isolates user ids when users is namespaced" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "users": { "namespaced": true, "fields": {} },
        \\    "items": { "fields": { "name": { "type": "string" } } }
        \\  }
        \\}
    ;
    try app.initWithSchemaJSON(allocator, "scope-namespaced-users", schema_json);
    defer app.deinit();

    const scope_a1 = try app.resolveStoreScopeForTest("alpha", "client-a");
    const scope_a2 = try app.resolveStoreScopeForTest("alpha", "client-a");
    const scope_b = try app.resolveStoreScopeForTest("beta", "client-a");

    try testing.expectEqual(scope_a1.namespace_id, scope_a2.namespace_id);
    try testing.expectEqual(scope_a1.user_doc_id, scope_a2.user_doc_id);
    try testing.expect(scope_a1.namespace_id != scope_b.namespace_id);
    try testing.expect(scope_a1.user_doc_id != scope_b.user_doc_id);

    const users = try app.tableMetadata("users");
    const record = try sth.readDoc(allocator, &app.storage_engine, users.index, scope_b.user_doc_id, scope_b.namespace_id);
    defer if (record) |r| r.deinit(allocator);
    try testing.expect(record != null);
}

test "StoreService: create requires all required fields but update does not" {
    const allocator = std.heap.smp_allocator;
    var app: helpers.AppTestContext = undefined;
    const schema_json =
        \\{
        \\  "version": "1.0.0",
        \\  "store": {
        \\    "items": {
        \\      "required": ["name", "status"],
        \\      "fields": {
        \\        "name": { "type": "string" },
        \\        "status": { "type": "string" },
        \\        "description": { "type": "string" }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    try app.initWithSchemaJSON(allocator, "store-service-required-fields", schema_json);
    defer app.deinit();

    const service = &app.store_service;
    const items = try app.table("items");
    const doc_id: typed_doc_id.DocId = 1;

    // 1. Create without required field 'status' should fail
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
            .{ "name", "Test Item" },
            .{ "description", "Some description" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("items"), doc_id);
        defer path.free(allocator);

        const result = service.setPath(writeCtx(1), path, val);
        try testing.expectError(StorageError.MissingRequiredField, result);
    }

    // 2. Create with all required fields should succeed
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
            .{ "name", "Test Item" },
            .{ "status", "active" },
            .{ "description", "Some description" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("items"), doc_id);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();

        // Verify the document was created
        var doc = try items.getOne(allocator, 1, doc_id);
        defer doc.deinit();
        _ = try doc.expectFieldString("name", "Test Item");
        _ = try doc.expectFieldString("status", "active");
        _ = try doc.expectFieldString("description", "Some description");
    }

    // 3. Full document update without required field should succeed
    // because it's an update, not a create
    {
        const val = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{
            .{ "status", "archived" },
            .{ "description", "Updated description" },
        });
        defer val.free(allocator);

        var path = try documentPath(allocator, app.tableIndex("items"), doc_id);
        defer path.free(allocator);

        try service.setPath(writeCtx(1), path, val);
        try app.storage_engine.flushPendingWrites();

        // Verify the update succeeded
        var doc = try items.getOne(allocator, 1, doc_id);
        defer doc.deinit();
        _ = try doc.expectFieldString("status", "archived");
        _ = try doc.expectFieldString("description", "Updated description");
    }
}
