const std = @import("std");
const testing = std.testing;
const msgpack = @import("msgpack_utils.zig");
const storage_mod = @import("storage_engine/types.zig");
const helpers = @import("app_test_helpers.zig");
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

    // 2. Success path: Including built-in fields
    {
        var val = msgpack.Payload.mapPayload(allocator);
        defer val.free(allocator);
        try val.mapPut("name", try msgpack.Payload.strToPayload("Bob", allocator));
        try val.mapPut("id", try msgpack.Payload.strToPayload("user-2", allocator));
        try val.mapPut("created_at", msgpack.Payload.uintToPayload(123456789));

        try service.set("users", "user-2", "public", 2, null, val);
        try app.storage_engine.flushPendingWrites();

        var managed = try app.storage_engine.selectDocument(allocator, "users", "user-2", "public");
        defer managed.deinit();
        try testing.expect(managed.value != null);
    }

    // 3. Negative path: Unknown field
    {
        var val = msgpack.Payload.mapPayload(allocator);
        defer val.free(allocator);
        try val.mapPut("unknown_field", try msgpack.Payload.strToPayload("oops", allocator));

        const result = service.set("users", "user-3", "public", 2, null, val);
        try testing.expectError(StorageError.UnknownField, result);
    }

    // 4. Negative path: Invalid payload type (not a map)
    {
        const val = try msgpack.Payload.strToPayload("not-a-map", allocator);
        defer val.free(allocator);

        const result = service.set("users", "user-4", "public", 2, null, val);
        try testing.expectError(error.InvalidPayload, result);
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

    // 2. Negative path: Unknown field
    {
        const val = try msgpack.Payload.strToPayload("oops", allocator);
        defer val.free(allocator);

        const result = service.set("items", "item-1", "public", 3, "unknown_field", val);
        try testing.expectError(StorageError.UnknownField, result);
    }

    // 3. Negative path: Invalid path (segments_len not 2 or 3)
    {
        const val = try msgpack.Payload.strToPayload("oops", allocator);
        defer val.free(allocator);

        const result = service.set("items", "item-1", "public", 4, null, val);
        try testing.expectError(StorageError.InvalidPath, result);
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

    // 1. Success: Remove specific field (segments_len == 3)
    {
        try service.remove("users", "user-1", "public", 3, "name");
        try app.storage_engine.flushPendingWrites();

        var managed = try app.storage_engine.selectDocument(allocator, "users", "user-1", "public");
        defer managed.deinit();
        const doc = managed.value orelse return error.UnexpectedNull;
        const name_payload = try msgpack.Payload.strToPayload("name", allocator);
        defer name_payload.free(allocator);
        const name_val = doc.map.get(name_payload) orelse return error.UnexpectedNull;
        try testing.expect(name_val == .nil);
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
}

test "StoreService: array validation" {
    const allocator = testing.allocator;
    var app: helpers.AppTestContext = undefined;

    try app.init(allocator, "store-service-array", &.{
        .{
            .name = "collections",
            .fields = &.{"tags"},
            .types = &.{.array},
        },
    });
    defer app.deinit();

    const service = &app.store_service;

    // 1. Success: Valid literal array (segments_len == 3)
    {
        var arr = try allocator.alloc(msgpack.Payload, 2);
        arr[0] = try msgpack.Payload.strToPayload("tag1", allocator);
        arr[1] = try msgpack.Payload.strToPayload("tag2", allocator);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        try service.set("collections", "id1", "public", 3, "tags", val);
    }

    // 2. Negative: Non-literal element (nested map)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = msgpack.Payload.mapPayload(allocator);
        const val = msgpack.Payload{ .arr = arr };
        defer val.free(allocator);

        const result = service.set("collections", "id1", "public", 3, "tags", val);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }

    // 3. Success: Valid array in full document (segments_len == 2)
    {
        var arr = try allocator.alloc(msgpack.Payload, 1);
        arr[0] = try msgpack.Payload.strToPayload("tag-new", allocator);
        const arr_val = msgpack.Payload{ .arr = arr };

        var map = msgpack.Payload.mapPayload(allocator);
        defer map.free(allocator);
        try map.mapPut("tags", arr_val);

        try service.set("collections", "id1", "public", 2, null, map);
    }

    // 4. Negative: Nested array in full document
    {
        var inner_arr = try allocator.alloc(msgpack.Payload, 1);
        inner_arr[0] = try msgpack.Payload.strToPayload("deep", allocator);

        var outer_arr = try allocator.alloc(msgpack.Payload, 1);
        outer_arr[0] = msgpack.Payload{ .arr = inner_arr };
        const arr_val = msgpack.Payload{ .arr = outer_arr };

        var map = msgpack.Payload.mapPayload(allocator);
        defer map.free(allocator);
        try map.mapPut("tags", arr_val);

        const result = service.set("collections", "id1", "public", 2, null, map);
        try testing.expectError(StorageError.InvalidArrayElement, result);
    }
}
