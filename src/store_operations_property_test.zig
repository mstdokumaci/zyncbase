const std = @import("std");
const testing = std.testing;
const message_handler = @import("message_handler.zig");
const MessageHandler = message_handler.MessageHandler;
const ViolationTracker = @import("violation_tracker.zig").ConnectionViolationTracker;
const RequestHandler = @import("request_handler.zig").RequestHandler;
const storage_mod = @import("storage_engine.zig");
const SubscriptionManager = @import("subscription_manager.zig").SubscriptionManager;
const LockFreeCache = @import("lock_free_cache.zig").LockFreeCache;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const schema_helpers = @import("schema_test_helpers.zig");
const msgpack = @import("msgpack_test_helpers.zig");



// **Property: StoreSet field extraction**
test "store: set field extraction" {
    const allocator = testing.allocator;

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);
    var context = try schema_helpers.TestContext.init(allocator, "store-set-field");
    defer context.deinit();

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Basic StoreSet message field extraction
    {
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test_ns", &.{ "test", "id1" }, "test_value");
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);

        // Should be able to route and process (which requires field extraction)
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // If we got a response, fields were extracted successfully
        try testing.expect(response.len > 0);
    }

    // Test 2: StoreSet with various field values
    {
        const test_cases = [_]struct {
            namespace: []const u8,
            path: []const []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = &.{ "test", "p1" }, .value = "v1" },
            .{ .namespace = "namespace_with_underscores", .path = &.{ "test", "long" }, .value = "complex value" },
            .{ .namespace = "a", .path = &.{ "test", "id2" }, .value = "" },
            .{ .namespace = "test", .path = &.{ "test", "key" }, .value = "value with spaces" },
        };

        for (test_cases, 0..) |tc, i| {
            const message = try msgpack.createStoreSetMessage(allocator, @intCast(i), tc.namespace, tc.path, tc.value);
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            try testing.expect(response.len > 0);
        }
    }

    // Test 3: StoreSet missing namespace should fail
    {
        // Manual msgpack map construction missing a field
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        // fixmap(4) - type, id, path, value (missing namespace)
        try buf.append(allocator, 0x84);
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreSet");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack.writeString(allocator, &buf, "path");
        // fixarray(2)
        try buf.append(allocator, 0x92);
        try msgpack.writeString(allocator, &buf, "test");
        try msgpack.writeString(allocator, &buf, "id1");
        try msgpack.writeString(allocator, &buf, "value");
        try msgpack.writeString(allocator, &buf, "val");

        const message = buf.items;
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 4: StoreSet missing path should fail
    {
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "test", "path" }, "val");
        defer allocator.free(message);
        // Corrupt it manually by removing a field or using a shorter map
        message[0] = 0x83; // Change fixmap(4) to fixmap(3) - effectively "missing" one field during parse if we only read 3

        // Actually, MessagePackParser.parse will just read 3 entries.
        // If we want to test "missing field", we should construct a map with only 3 specific fields.
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreSet");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack.writeString(allocator, &buf, "namespace");
        try msgpack.writeString(allocator, &buf, "test");
        // Missing "path" and "value"

        const msg_buf = buf.items;
        var fbs_reader: std.Io.Reader = .fixed(msg_buf);
        const parsed = try msgpack.decode(allocator, &fbs_reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 5: StoreSet missing value should fail
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreSet");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack.writeString(allocator, &buf, "namespace");
        try msgpack.writeString(allocator, &buf, "test");

        const msg_buf = buf.items;
        var fbs_reader: std.Io.Reader = .fixed(msg_buf);
        const parsed = try msgpack.decode(allocator, &fbs_reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }
}

test "store: engine set integration" {
    const allocator = testing.allocator;

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);
    var context = try schema_helpers.TestContext.init(allocator, "store-engine-set");
    defer context.deinit();

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreSet should call storage engine and persist data
    {
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "test", "key1" }, "value1");
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Wait for write to complete
        try engine.flushPendingWrites();

        // Verify data was stored by retrieving it
        const stored_doc = try engine.selectDocument("test", "key1", "test");
        defer if (stored_doc) |d| d.free(allocator);
        try testing.expect(stored_doc != null);

        // Value is stored in the document fields
        const v_payload = try msgpack.Payload.strToPayload("val", allocator);
        defer v_payload.free(allocator);
        const val_field = stored_doc.?.map.get(v_payload);
        try testing.expect(val_field != null);
        try testing.expectEqualStrings("value1", val_field.?.str.value());
    }

    // Test 2: Multiple StoreSet calls should all persist
    {
        const test_data = [_]struct {
            namespace: []const u8,
            path: []const []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = &.{ "test", "k1" }, .value = "v1" },
            .{ .namespace = "ns1", .path = &.{ "test", "k2" }, .value = "v2" },
            .{ .namespace = "ns2", .path = &.{ "test", "k1" }, .value = "v3" },
        };

        for (test_data, 0..) |td, i| {
            const message = try msgpack.createStoreSetMessage(allocator, @intCast(i + 10), td.namespace, td.path, td.value);
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);
        }

        // Wait for writes to complete
        try engine.flushPendingWrites();

        // Verify all data was stored
        for (test_data) |td| {
            const table = td.path[0];
            const id = td.path[1];
            const stored_doc = try engine.selectDocument(table, id, td.namespace);
            defer if (stored_doc) |d| d.free(allocator);
            try testing.expect(stored_doc != null);

            const k_payload = try msgpack.Payload.strToPayload("val", allocator);
            defer k_payload.free(allocator);
            const val_field = stored_doc.?.map.get(k_payload);
            try testing.expect(val_field != null);
            try testing.expectEqualStrings(td.value, val_field.?.str.value());
        }
    }

    {
        const namespace = "update_test";
        const path = &.{ "test", "update_key" };
        // Set initial value
        const message1 = try msgpack.createStoreSetMessage(allocator, 1, namespace, path, "initial");
        defer allocator.free(message1);

        var reader1_any: std.Io.Reader = .fixed(message1);
        const parsed1 = try msgpack.decode(allocator, &reader1_any);
        defer parsed1.free(allocator);
        const info1 = try handler.extractMessageInfo(parsed1);
        const response1 = try handler.routeMessage(1, info1, parsed1);
        defer allocator.free(response1);

        std.Thread.sleep(100 * std.time.ns_per_ms);

        // Update value
        const message2 = try msgpack.createStoreSetMessage(allocator, 2, namespace, path, "updated");
        defer allocator.free(message2);

        var reader2_any: std.Io.Reader = .fixed(message2);
        const parsed2 = try msgpack.decode(allocator, &reader2_any);
        defer parsed2.free(allocator);
        const info2 = try handler.extractMessageInfo(parsed2);
        const response2 = try handler.routeMessage(1, info2, parsed2);
        defer allocator.free(response2);

        try engine.flushPendingWrites();

        // Verify value was updated
        const stored_doc = try engine.selectDocument("test", "update_key", namespace);
        defer if (stored_doc) |d| d.free(allocator);
        try testing.expect(stored_doc != null);

        const v_payload = try msgpack.Payload.strToPayload("val", allocator);
        defer v_payload.free(allocator);
        const val_field = stored_doc.?.map.get(v_payload);
        try testing.expect(val_field != null);
        try testing.expectEqualStrings("updated", val_field.?.str.value());
    }
}

test "store: set success response format" {
    const allocator = testing.allocator;

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);
    var context = try schema_helpers.TestContext.init(allocator, "store-set-resp");
    defer context.deinit();

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Successful StoreSet should return success response
    {
        const message = try msgpack.createStoreSetMessage(allocator, 1, "test", &.{ "test", "key" }, "val");
        defer allocator.free(message);
        var reader_msg: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader_msg);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should indicate success
        var reader_resp: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &reader_resp);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var found_ok = false;
        var found_id = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "type")) {
                try testing.expectEqualStrings("ok", entry.value_ptr.*.str.value());
                found_ok = true;
            } else if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) {
                try testing.expectEqual(@as(u64, 1), entry.value_ptr.*.uint);
                found_id = true;
            }
        }
        try testing.expect(found_ok and found_id);
    }

    // Test 2: Multiple successful StoreSet operations
    {
        for (0..10) |i| {
            var id_buf: [32]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "key{}", .{i});
            const path = [_][]const u8{ "test", id };

            const val_str = try std.fmt.allocPrint(allocator, "val{}", .{i});
            defer allocator.free(val_str);

            const msg = try msgpack.createStoreSetMessage(allocator, i, "test", &path, val_str);
            defer allocator.free(msg);

            var reader_msg: std.Io.Reader = .fixed(msg);
            const parsed = try msgpack.decode(allocator, &reader_msg);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            try engine.flushPendingWrites();
            // Each should return success
            var reader_resp: std.Io.Reader = .fixed(response);
            const resp_parsed = try msgpack.decode(allocator, &reader_resp);
            defer resp_parsed.free(allocator);
            try testing.expect(resp_parsed == .map);
            var found_ok = false;
            var it = resp_parsed.map.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "type")) {
                    try testing.expectEqualStrings("ok", entry.value_ptr.*.str.value());
                    found_ok = true;
                }
            }
            try testing.expect(found_ok);
        }
    }

    // Test 3: Success response format should be consistent
    {
        const message = try msgpack.createStoreSetMessage(allocator, 999, "ns", &.{ "test", "p" }, "v");
        defer allocator.free(message);
        var reader_msg: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader_msg);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should have expected format
        var reader_resp: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &reader_resp);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var found_type = false;
        var found_id = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "type")) found_type = true;
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) found_id = true;
        }
        try testing.expect(found_type and found_id);
    }
}

test "store: get field extraction" {
    const allocator = testing.allocator;

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);
    var context = try schema_helpers.TestContext.init(allocator, "store-get-field");
    defer context.deinit();

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: Basic StoreGet message field extraction
    {
        const message = try msgpack.createStoreGetMessage(allocator, 1, "test_ns", &.{ "test", "id1" });
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);

        // Should be able to route and process (which requires field extraction)
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // If we got a response, fields were extracted successfully
        try testing.expect(response.len > 0);
    }

    // Test 2: StoreGet with various field values
    {
        const test_cases = [_]struct {
            namespace: []const u8,
            path: []const []const u8,
        }{
            .{ .namespace = "ns1", .path = &.{ "test", "p1" } },
            .{ .namespace = "namespace_with_underscores", .path = &.{ "test", "nested" } },
            .{ .namespace = "a", .path = &.{ "test", "id2" } },
            .{ .namespace = "test", .path = &.{ "test", "key" } },
        };

        for (test_cases, 0..) |tc, i| {
            const message = try msgpack.createStoreGetMessage(allocator, @intCast(i), tc.namespace, tc.path);
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            try testing.expect(response.len > 0);
        }
    }

    // Test 3: StoreGet missing namespace should fail
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreGet");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack.writeString(allocator, &buf, "path");
        try msgpack.writeString(allocator, &buf, "/test");

        const message = buf.items;
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }

    // Test 4: StoreGet missing path should fail
    {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(allocator);
        try buf.append(allocator, 0x83); // fixmap(3)
        try msgpack.writeString(allocator, &buf, "type");
        try msgpack.writeString(allocator, &buf, "StoreGet");
        try msgpack.writeString(allocator, &buf, "id");
        try buf.append(allocator, 0x01);
        try msgpack.writeString(allocator, &buf, "namespace");
        try msgpack.writeString(allocator, &buf, "test");

        const message = buf.items;
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const result = handler.routeMessage(1, msg_info, parsed);

        try testing.expectError(error.MissingRequiredFields, result);
    }
}

test "store: engine get integration" {
    const allocator = testing.allocator;

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);
    var context = try schema_helpers.TestContext.init(allocator, "store-engine-get");
    defer context.deinit();

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreGet should call storage engine get
    {
        // First store a value
        const val_payload = try msgpack.Payload.strToPayload("value1", allocator);
        defer val_payload.free(allocator);
        const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = val_payload }};
        try engine.insertOrReplace("test", "key1", "test", &cols);
        try engine.flushPendingWrites();

        // Now get it via message handler
        const message = try msgpack.createStoreGetMessage(allocator, 1, "test", &.{ "test", "key1" });
        defer allocator.free(message);
        var reader_set: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader_set);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should contain the value (proving storage engine was called)
        var fbs_reader: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &fbs_reader);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var val: ?[]const u8 = null;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), "value")) {
                if (entry.value_ptr.* == .str) {
                    val = entry.value_ptr.*.str.value();
                } else if (entry.value_ptr.* == .map) {
                    var doc_it = entry.value_ptr.*.map.iterator();
                    while (doc_it.next()) |doc_entry| {
                        if (doc_entry.key_ptr.* == .str and std.mem.eql(u8, doc_entry.key_ptr.*.str.value(), "val")) {
                            if (doc_entry.value_ptr.* == .str) {
                                val = doc_entry.value_ptr.*.str.value();
                            }
                        }
                    }
                }
            }
        }
        try testing.expect(val != null);
        try testing.expectEqualStrings("value1", val.?);
    }

    // Test 2: StoreGet for multiple keys
    {
        // Store multiple values
        const test_data = [_]struct {
            namespace: []const u8,
            path: []const []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = &.{ "test", "k1" }, .value = "v1" },
            .{ .namespace = "ns1", .path = &.{ "test", "k2" }, .value = "v2" },
            .{ .namespace = "ns2", .path = &.{ "test", "k1" }, .value = "v3" },
        };

        for (test_data) |td| {
            const val_payload = try msgpack.Payload.strToPayload(td.value, allocator);
            defer val_payload.free(allocator);
            const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = val_payload }};
            try engine.insertOrReplace("test", td.path[1], td.namespace, &cols);
        }
        try engine.flushPendingWrites();

        // Get each value via message handler
        for (test_data, 0..) |td, i| {
            const message = try msgpack.createStoreGetMessage(allocator, @intCast(i + 10), td.namespace, td.path);
            defer allocator.free(message);

            var reader: std.Io.Reader = .fixed(message);
            const parsed = try msgpack.decode(allocator, &reader);
            defer parsed.free(allocator);

            const msg_info = try handler.extractMessageInfo(parsed);
            const response = try handler.routeMessage(1, msg_info, parsed);
            defer allocator.free(response);

            // Response should contain the expected value
            var resp_reader: std.Io.Reader = .fixed(response);
            const resp_parsed = try msgpack.decode(allocator, &resp_reader);
            defer resp_parsed.free(allocator);
            try testing.expect(resp_parsed == .map);
            var val: ?[]const u8 = null;
            var it = resp_parsed.map.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), "value")) {
                    if (entry.value_ptr.* == .str) {
                        val = entry.value_ptr.*.str.value();
                    } else if (entry.value_ptr.* == .map) {
                        var doc_it = entry.value_ptr.*.map.iterator();
                        while (doc_it.next()) |doc_entry| {
                            if (doc_entry.key_ptr.* == .str and std.mem.eql(u8, doc_entry.key_ptr.*.str.value(), "val")) {
                                if (doc_entry.value_ptr.* == .str) {
                                    val = doc_entry.value_ptr.*.str.value();
                                }
                            }
                        }
                    }
                }
            }
            try testing.expect(val != null);
            try testing.expectEqualStrings(td.value, val.?);
        }
    }

    // Test 3: StoreGet for nonexistent key should call storage engine
    {
        const message = try msgpack.createStoreGetMessage(allocator, 1, "test", &.{ "test", "nonexistent" });
        defer allocator.free(message);
        var reader: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Should get a NOT_FOUND response
        var fbs_reader: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &fbs_reader);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var found_not_found = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "code")) {
                try testing.expectEqualStrings("NOT_FOUND", entry.value_ptr.*.str.value());
                found_not_found = true;
            }
        }
        try testing.expect(found_not_found);
    }
}

test "store: get value response format" {
    const allocator = testing.allocator;

    var tracker = ViolationTracker.init(allocator, 10);
    defer tracker.deinit();

    var memory_strategy = try MemoryStrategy.init();
    defer memory_strategy.deinit();

    var request_handler = RequestHandler.init(&memory_strategy);
    var context = try schema_helpers.TestContext.init(allocator, "store-get-resp");
    defer context.deinit();

    const schema = try schema_helpers.createTestSchema(allocator, &.{
        .{ .name = "data_table", .fields = &.{"val"} },
        .{ .name = "test", .fields = &.{"val"} },
    });
    defer schema_helpers.freeTestSchema(allocator, schema);

    const engine = try schema_helpers.setupTestEngine(allocator, &context, schema);
    defer engine.deinit();

    const subscription_manager = try SubscriptionManager.init(allocator);
    defer subscription_manager.deinit();

    const cache = try LockFreeCache.init(allocator);
    defer cache.deinit();

    const handler = try MessageHandler.init(
        allocator,
        &tracker,
        &request_handler,
        engine,
        subscription_manager,
        cache,
    );
    defer handler.deinit();

    // Test 1: StoreGet should return value in response
    {
        // Store a value
        const val_payload = try msgpack.Payload.strToPayload("test_value_123", allocator);
        defer val_payload.free(allocator);
        const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = val_payload }};
        try engine.insertOrReplace("data_table", "key1", "test", &cols);
        try engine.flushPendingWrites();

        // Get it
        try engine.flushPendingWrites();
        const message = try msgpack.createStoreGetMessage(allocator, 1, "test", &.{ "data_table", "key1" });
        defer allocator.free(message);
        var reader_msg: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader_msg);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should contain the value
        var reader_get_resp: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &reader_get_resp);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var found_type = false;
        var found_id = false;
        var val: ?[]const u8 = null;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "type")) {
                try testing.expectEqualStrings("ok", entry.value_ptr.*.str.value());
                found_type = true;
            } else if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) {
                try testing.expectEqual(@as(u64, 1), entry.value_ptr.*.uint);
                found_id = true;
            } else if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "value")) {
                if (entry.value_ptr.* == .str) {
                    val = entry.value_ptr.*.str.value();
                } else if (entry.value_ptr.* == .map) {
                    var doc_it = entry.value_ptr.*.map.iterator();
                    while (doc_it.next()) |doc_entry| {
                        if (doc_entry.key_ptr.* == .str and std.mem.eql(u8, doc_entry.key_ptr.*.str.value(), "val")) {
                            if (doc_entry.value_ptr.* == .str) {
                                val = doc_entry.value_ptr.*.str.value();
                            }
                        }
                    }
                }
            }
        }
        try testing.expect(found_type and found_id);
        try testing.expect(val != null);
        try testing.expectEqualStrings("test_value_123", val.?);
    }

    // Test 2: Multiple StoreGet operations should return correct values
    {
        // Store multiple values
        const test_data = [_]struct {
            namespace: []const u8,
            path: []const []const u8,
            value: []const u8,
        }{
            .{ .namespace = "ns1", .path = &.{ "test", "k1" }, .value = "value_one" },
            .{ .namespace = "ns1", .path = &.{ "test", "k2" }, .value = "value_two" },
            .{ .namespace = "ns2", .path = &.{ "test", "k1" }, .value = "value_three" },
        };

        for (test_data, 0..) |td, i| {
            const val_payload = try msgpack.Payload.strToPayload(td.value, allocator);
            defer val_payload.free(allocator);

            const set_msg = try msgpack.createStoreSetMessage(allocator, @intCast(i), td.namespace, td.path, td.value);
            defer allocator.free(set_msg);

            var reader_set: std.Io.Reader = .fixed(set_msg);
            const parsed_set = try msgpack.decode(allocator, &reader_set);
            defer parsed_set.free(allocator);

            const set_info = try handler.extractMessageInfo(parsed_set);
            const set_resp = try handler.routeMessage(1, set_info, parsed_set);
            defer allocator.free(set_resp);

            try engine.flushPendingWrites();

            const get_msg = try msgpack.createStoreGetMessage(allocator, @intCast(i + 100), td.namespace, td.path);
            defer allocator.free(get_msg);

            var reader_get: std.Io.Reader = .fixed(get_msg);
            const parsed_get = try msgpack.decode(allocator, &reader_get);
            defer parsed_get.free(allocator);

            const get_info = try handler.extractMessageInfo(parsed_get);
            const get_resp = try handler.routeMessage(1, get_info, parsed_get);
            defer allocator.free(get_resp);

            var reader_resp: std.Io.Reader = .fixed(get_resp);
            const resp_parsed = try msgpack.decode(allocator, &reader_resp);
            defer resp_parsed.free(allocator);

            try testing.expect(resp_parsed == .map);
            var val: ?[]const u8 = null;
            var it = resp_parsed.map.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "value")) {
                    if (entry.value_ptr.* == .str) {
                        val = entry.value_ptr.*.str.value();
                    } else if (entry.value_ptr.* == .map) {
                        var doc_it = entry.value_ptr.*.map.iterator();
                        while (doc_it.next()) |doc_entry| {
                            if (doc_entry.key_ptr.* == .str and std.mem.eql(u8, doc_entry.key_ptr.*.str.value(), "val")) {
                                if (doc_entry.value_ptr.* == .str) {
                                    val = doc_entry.value_ptr.*.str.value();
                                }
                            }
                        }
                    }
                }
            }
            try testing.expect(val != null);
            try testing.expectEqualStrings(td.value, val.?);
        }
    }

    // Test 3: StoreGet for nonexistent key should return not found response
    {
        const message = try msgpack.createStoreGetMessage(allocator, 999, "test", &.{ "test", "does_not_exist" });
        defer allocator.free(message);
        var reader_msg_get: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader_msg_get);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should indicate not found
        var reader_resp_get: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &reader_resp_get);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var is_error = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "type")) {
                if (std.mem.eql(u8, entry.value_ptr.*.str.value(), "error")) is_error = true;
            }
        }
        try testing.expect(is_error);
    }

    // Test 4: Response format should be consistent
    {
        // Store a value
        const val_payload = try msgpack.Payload.strToPayload("format_value", allocator);
        defer val_payload.free(allocator);
        const cols = [_]storage_mod.ColumnValue{.{ .name = "val", .value = val_payload }};
        try engine.insertOrReplace("test", "key", "format_test", &cols);
        try engine.flushPendingWrites();

        const message = try msgpack.createStoreGetMessage(allocator, 777, "format_test", &.{ "test", "key" });
        defer allocator.free(message);
        var reader_msg_final: std.Io.Reader = .fixed(message);
        const parsed = try msgpack.decode(allocator, &reader_msg_final);
        defer parsed.free(allocator);

        const msg_info = try handler.extractMessageInfo(parsed);
        const response = try handler.routeMessage(1, msg_info, parsed);
        defer allocator.free(response);

        // Response should have expected format
        var reader_resp_final: std.Io.Reader = .fixed(response);
        const resp_parsed = try msgpack.decode(allocator, &reader_resp_final);
        defer resp_parsed.free(allocator);
        try testing.expect(resp_parsed == .map);
        var found_type = false;
        var found_id = false;
        var found_value = false;
        var it = resp_parsed.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "type")) found_type = true;
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "id")) found_id = true;
            if (std.mem.eql(u8, entry.key_ptr.*.str.value(), "value")) found_value = true;
        }
        try testing.expect(found_type and found_id and found_value);
    }
}
