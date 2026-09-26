const std = @import("std");

const helpers = @import("../app_test_helpers.zig");
const authorization_parse = @import("../authorization/parse.zig");
const msgpack = @import("../msgpack_utils.zig");
const schema_parse = @import("../schema/parse.zig");
const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");
const service_mod = @import("service.zig");
const MessageType = @import("../wire/message_type.zig").MessageType;

const testing = std.testing;
const AppTestContext = helpers.AppTestContext;
const ActionsService = service_mod.ActionsService;
const RegistryKey = service_mod.RegistryKey;
const SessionContext = service_mod.SessionContext;

fn connectionContext(conn: anytype) SessionContext {
    return .{
        .conn_id = conn.id,
        .user_doc_id = conn.user_doc_id,
        .external_user_id = conn.getExternalUserId() orelse "",
        .session_claims = conn.getSessionClaimsPtr(),
        .store_namespace = conn.getStoreNamespace(),
        .store_namespace_id = conn.namespace_id,
        .presence_namespace = conn.getPresenceNamespace(),
        .presence_namespace_id = conn.presence_namespace_id,
    };
}

const schema_json =
    \\{"version":"1.0.0","store":{},"actions":{
    \\  "checkout":{
    \\    "params":{"cart_id":{"type":"string"},"qty":{"type":"integer","minimum":0}},
    \\    "required":["cart_id"],
    \\    "returns":{"order_id":{"type":"string"}}
    \\  },
    \\  "ping":{"params":{"seq":{"type":"integer"}},"returns":null,"scope":"presence"}
    \\}}
;

const auth_json =
    \\{"namespaces":[{"pattern":"public","storeFilter":true,"presenceRead":true,"presenceWrite":true}],
    \\ "store":[],
    \\ "actions":[
    \\   {"action":"checkout","invoke":true,"register":{"$session.role":{"eq":"worker"}}},
    \\   {"action":"ping","invoke":true,"register":true}
    \\ ]}
;

const Pair = struct { index: usize, value: msgpack.Payload };

fn makePairs(allocator: std.mem.Allocator, pairs: []const Pair) !msgpack.Payload {
    const outer = try allocator.alloc(msgpack.Payload, pairs.len);
    var built: usize = 0;
    errdefer {
        for (outer[0..built]) |p| p.free(allocator);
        allocator.free(outer);
    }
    for (pairs, 0..) |p, i| {
        const inner = try allocator.alloc(msgpack.Payload, 2);
        inner[0] = msgpack.Payload.uintToPayload(p.index);
        inner[1] = p.value;
        outer[i] = .{ .arr = inner };
        built += 1;
    }
    return .{ .arr = outer };
}

fn makeClaims(allocator: std.mem.Allocator, role: []const u8) !std.StringHashMapUnmanaged(typed.Value) {
    var claims = std.StringHashMapUnmanaged(typed.Value){};
    try claims.put(allocator, "role", .{ .scalar = .{ .text = role } });
    return claims;
}

fn workerCtx(conn_id: u64, user_id: typed_doc_id.DocId, claims: ?*const std.StringHashMapUnmanaged(typed.Value)) SessionContext {
    return .{
        .conn_id = conn_id,
        .user_doc_id = user_id,
        .external_user_id = "worker",
        .session_claims = claims,
        .store_namespace = "public",
        .store_namespace_id = 1,
        .presence_namespace = "public",
        .presence_namespace_id = 2,
    };
}

fn callerCtx(conn_id: u64, user_id: typed_doc_id.DocId) SessionContext {
    return .{
        .conn_id = conn_id,
        .user_doc_id = user_id,
        .external_user_id = "caller",
        .store_namespace = "public",
        .store_namespace_id = 1,
    };
}

test "actions service: pickWorker round-robins across registered workers" {
    const allocator = std.testing.allocator;

    var schema = try schema_parse.initFromJson(allocator, schema_json);
    defer schema.deinit();
    var config = try authorization_parse.initFromJson(allocator, auth_json, &schema);
    defer config.deinit();

    var service = ActionsService.init(allocator, std.testing.io, &schema, &config);
    defer service.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);
    var claims = try makeClaims(allocator, "worker");
    defer claims.deinit(allocator);

    try service.register(workerCtx(10, user_id, &claims), &.{0});
    try service.register(workerCtx(11, user_id, &claims), &.{0});

    const key = RegistryKey{ .scope = .store, .namespace_id = 1, .action_id = 0 };
    try testing.expectEqual(@as(?u64, 10), service.pickWorker(key));
    try testing.expectEqual(@as(?u64, 11), service.pickWorker(key));
    try testing.expectEqual(@as(?u64, 10), service.pickWorker(key));

    // Unregistering a worker removes it from the rotation.
    service.unregister(10, null);
    try testing.expectEqual(@as(usize, 1), service.workerCount(key));
    try testing.expectEqual(@as(?u64, 11), service.pickWorker(key));
    try testing.expectEqual(@as(?u64, 11), service.pickWorker(key));
}

test "actions service: round-robin registration and sync pending bookkeeping" {
    const allocator = std.testing.allocator;

    var schema = try schema_parse.initFromJson(allocator, schema_json);
    defer schema.deinit();
    var config = try authorization_parse.initFromJson(allocator, auth_json, &schema);
    defer config.deinit();

    var service = ActionsService.init(allocator, std.testing.io, &schema, &config);
    defer service.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);

    var claims = try makeClaims(allocator, "worker");
    defer claims.deinit(allocator);

    try service.register(workerCtx(10, user_id, &claims), &.{0});
    try service.register(workerCtx(11, user_id, &claims), &.{0});

    const key = RegistryKey{ .scope = .store, .namespace_id = 1, .action_id = 0 };
    try testing.expectEqual(@as(usize, 2), service.workerCount(key));

    const caller = callerCtx(20, user_id);
    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
    });
    defer params.free(allocator);

    try testing.expectEqual(service_mod.CallOutcome.pending, try service.call(caller, 7, 0, &params, null));
    try testing.expectEqual(@as(usize, 1), service.pendingCount(20));

    // Foreign worker reply is discarded.
    service.resolveReply(11, 1, true, &params);
    try testing.expectEqual(@as(usize, 1), service.pendingCount(20));

    // Owning worker reply with a valid returns payload settles the call.
    var returns = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("order-1", allocator) },
    });
    defer returns.free(allocator);
    service.resolveReply(10, 1, true, &returns);
    try testing.expectEqual(@as(usize, 0), service.pendingCount(20));

    // Expired deadlines are swept.
    try testing.expectEqual(service_mod.CallOutcome.pending, try service.call(caller, 8, 0, &params, null));
    try testing.expectEqual(@as(usize, 1), service.pendingCount(20));
    service.sweepDeadlinesAt(std.math.maxInt(i96));
    try testing.expectEqual(@as(usize, 0), service.pendingCount(20));

    // Worker disconnect removes registrations and fails its in-flight calls.
    try testing.expectEqual(service_mod.CallOutcome.pending, try service.call(caller, 9, 0, &params, null));
    service.removeAllForConnection(10);
    try testing.expectEqual(@as(usize, 1), service.workerCount(key));
    try testing.expectEqual(@as(usize, 0), service.pendingCount(20));
}

test "actions service: rate-limited sync calls are not forwarded" {
    const allocator = std.heap.smp_allocator;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "actions-pending-limit", schema_json);
    defer app.deinit();

    const worker = try app.setupMockConnection();
    defer worker.deinit();
    const caller = try app.setupMockConnection();
    defer caller.deinit();

    var capture: [1]u8 = undefined;
    var recorder = helpers.SendRecorder.init(&capture);
    worker.conn.ws.test_send_observer = helpers.sendRecorderObserver;
    worker.conn.ws.test_send_observer_ctx = &recorder;
    recorder.reset();

    try app.actions_service.register(connectionContext(worker.conn), &.{0});
    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
    });
    defer params.free(allocator);

    var accepted: usize = 0;
    while (true) {
        _ = app.actions_service.call(connectionContext(caller.conn), accepted + 1, 0, &params, null) catch |err| {
            if (err != error.RateLimited) return err;
            break;
        };
        accepted += 1;
    }

    try testing.expect(accepted > 0);
    try testing.expectEqual(accepted, app.actions_service.pendingCount(caller.conn.id));
    try testing.expectEqual(@as(u64, @intCast(accepted)), recorder.send_count.load(.monotonic));
}

test "actions service: late worker reply times out instead of succeeding" {
    const allocator = std.heap.smp_allocator;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "actions-late-reply", schema_json);
    defer app.deinit();

    const worker = try app.setupMockConnection();
    defer worker.deinit();
    const caller = try app.setupMockConnection();
    defer caller.deinit();

    var capture: [512]u8 = undefined;
    var recorder = helpers.SendRecorder.init(&capture);
    caller.conn.ws.test_send_observer = helpers.sendRecorderObserver;
    caller.conn.ws.test_send_observer_ctx = &recorder;
    recorder.reset();

    try app.actions_service.register(connectionContext(worker.conn), &.{0});
    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
    });
    defer params.free(allocator);

    try testing.expectEqual(service_mod.CallOutcome.pending, try app.actions_service.call(connectionContext(caller.conn), 7, 0, &params, null));
    var pending_it = app.actions_service.pending.iterator();
    const pending_entry = pending_it.next() orelse return error.TestExpectedValue;
    pending_entry.value_ptr.deadline_ns = std.math.minInt(i96);

    app.actions_service.resolveReply(worker.conn.id, pending_entry.key_ptr.*, true, &params);

    try testing.expectEqual(@as(usize, 0), app.actions_service.pendingCount(caller.conn.id));
    const response = try helpers.parseResponse(allocator, recorder.bytes());
    defer if (response.code) |code| allocator.free(code);
    try testing.expectEqual(MessageType.@"error", response.resp_type);
    try testing.expectEqualStrings("ACTION_TIMEOUT", response.code.?);
}

test "actions service: validates params and requires ready bound scope" {
    const allocator = std.testing.allocator;

    var schema = try schema_parse.initFromJson(allocator, schema_json);
    defer schema.deinit();
    var config = try authorization_parse.initFromJson(allocator, auth_json, &schema);
    defer config.deinit();

    var service = ActionsService.init(allocator, std.testing.io, &schema, &config);
    defer service.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);
    const caller = callerCtx(20, user_id);

    // No worker registered → fail fast.
    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
    });
    defer params.free(allocator);
    try testing.expectError(error.NoActionWorker, service.call(caller, 1, 0, &params, null));

    var claims = try makeClaims(allocator, "worker");
    defer claims.deinit(allocator);
    try service.register(workerCtx(10, user_id, &claims), &.{0});

    // Required param missing.
    var empty = try makePairs(allocator, &.{});
    defer empty.free(allocator);
    try testing.expectError(error.SchemaValidationFailed, service.call(caller, 1, 0, &empty, null));

    // Type mismatch.
    var bad_type = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
        .{ .index = 1, .value = try msgpack.Payload.strToPayload("nope", allocator) },
    });
    defer bad_type.free(allocator);
    try testing.expectError(error.TypeMismatch, service.call(caller, 1, 0, &bad_type, null));

    // Constraint violation.
    var bad_range = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
        .{ .index = 1, .value = .{ .int = -1 } },
    });
    defer bad_range.free(allocator);
    try testing.expectError(error.RangeViolation, service.call(caller, 1, 0, &bad_range, null));

    // Out-of-range field index.
    var bad_index = try makePairs(allocator, &.{
        .{ .index = 9, .value = try msgpack.Payload.strToPayload("x", allocator) },
    });
    defer bad_index.free(allocator);
    try testing.expectError(error.SchemaValidationFailed, service.call(caller, 1, 0, &bad_index, null));

    // Unknown action id.
    try testing.expectError(error.UnknownAction, service.call(caller, 1, 99, &params, null));

    // Bound scope not ready.
    var offline = caller;
    offline.store_namespace = null;
    try testing.expectError(error.SessionNotReady, service.call(offline, 1, 0, &params, null));
}

test "actions service: register requires authorization and ready scope" {
    const allocator = std.testing.allocator;

    var schema = try schema_parse.initFromJson(allocator, schema_json);
    defer schema.deinit();
    var config = try authorization_parse.initFromJson(allocator, auth_json, &schema);
    defer config.deinit();

    var service = ActionsService.init(allocator, std.testing.io, &schema, &config);
    defer service.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);

    // register rule needs the worker claim.
    try testing.expectError(error.PermissionDenied, service.register(workerCtx(10, user_id, null), &.{0}));

    // Presence-scoped action requires the presence scope.
    var no_presence = workerCtx(10, user_id, null);
    no_presence.presence_namespace = null;
    try testing.expectError(error.SessionNotReady, service.register(no_presence, &.{1}));

    // Unknown action id.
    try testing.expectError(error.UnknownAction, service.register(workerCtx(10, user_id, null), &.{42}));
}

test "actions service: scope invalidation and auth refresh revocation" {
    const allocator = std.testing.allocator;

    var schema = try schema_parse.initFromJson(allocator, schema_json);
    defer schema.deinit();
    var config = try authorization_parse.initFromJson(allocator, auth_json, &schema);
    defer config.deinit();

    var service = ActionsService.init(allocator, std.testing.io, &schema, &config);
    defer service.deinit();

    const user_id = try typed_doc_id.generateUuidV7(std.testing.io);
    var claims = try makeClaims(allocator, "worker");
    defer claims.deinit(allocator);

    const worker = workerCtx(10, user_id, &claims);
    try service.register(worker, &.{0});

    const caller = callerCtx(20, user_id);
    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
    });
    defer params.free(allocator);

    const key = RegistryKey{ .scope = .store, .namespace_id = 1, .action_id = 0 };

    // Namespace change on the caller's bound scope drops registrations and pending calls.
    try testing.expectEqual(service_mod.CallOutcome.pending, try service.call(caller, 1, 0, &params, null));
    service.invalidateScope(20, .store);
    try testing.expectEqual(@as(usize, 0), service.pendingCount(20));
    // Worker registrations are untouched by the caller's scope change.
    try testing.expectEqual(@as(usize, 1), service.workerCount(key));

    // A failed re-authorization revokes registrations and in-flight calls.
    try testing.expectEqual(service_mod.CallOutcome.pending, try service.call(caller, 2, 0, &params, null));
    var demoted = try makeClaims(allocator, "member");
    defer demoted.deinit(allocator);
    service.reauthorizeRegistrations(workerCtx(10, user_id, &demoted));
    try testing.expectEqual(@as(usize, 0), service.workerCount(key));
    try testing.expectEqual(@as(usize, 0), service.pendingCount(20));
}

test "actions service: worker error tuples and return validation settle callers" {
    const allocator = std.heap.smp_allocator;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "actions-worker-error", schema_json);
    defer app.deinit();

    const worker = try app.setupMockConnection();
    defer worker.deinit();
    const caller = try app.setupMockConnection();
    defer caller.deinit();

    var capture: [512]u8 = undefined;
    var recorder = helpers.SendRecorder.init(&capture);
    caller.conn.ws.test_send_observer = helpers.sendRecorderObserver;
    caller.conn.ws.test_send_observer_ctx = &recorder;
    recorder.reset();

    try app.actions_service.register(connectionContext(worker.conn), &.{0});
    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
    });
    defer params.free(allocator);

    // Worker error tuple: flat [code, message] forwarded verbatim to the caller.
    try testing.expectEqual(service_mod.CallOutcome.pending, try app.actions_service.call(connectionContext(caller.conn), 1, 0, &params, null));

    const err_items = try allocator.alloc(msgpack.Payload, 2);
    err_items[0] = try msgpack.Payload.strToPayload("INSUFFICIENT_FUNDS", allocator);
    err_items[1] = try msgpack.Payload.strToPayload("too poor", allocator);
    var err_tuple = msgpack.Payload{ .arr = err_items };
    defer err_tuple.free(allocator);

    app.actions_service.resolveReply(worker.conn.id, 1, false, &err_tuple);
    try testing.expectEqual(@as(usize, 0), app.actions_service.pendingCount(caller.conn.id));
    const error_response = try helpers.parseResponse(allocator, recorder.bytes());
    defer if (error_response.code) |code| allocator.free(code);
    try testing.expectEqual(MessageType.@"error", error_response.resp_type);
    try testing.expectEqualStrings("INSUFFICIENT_FUNDS", error_response.code.?);

    // Missing required return field fails validation and drains.
    recorder.reset();
    try testing.expectEqual(service_mod.CallOutcome.pending, try app.actions_service.call(connectionContext(caller.conn), 2, 0, &params, null));

    var empty_returns = msgpack.Payload{ .arr = &.{} };
    app.actions_service.resolveReply(worker.conn.id, 2, true, &empty_returns);
    try testing.expectEqual(@as(usize, 0), app.actions_service.pendingCount(caller.conn.id));
    const validation_response = try helpers.parseResponse(allocator, recorder.bytes());
    defer if (validation_response.code) |code| allocator.free(code);
    try testing.expectEqual(MessageType.@"error", validation_response.resp_type);
    try testing.expectEqualStrings("SCHEMA_VALIDATION_FAILED", validation_response.code.?);
}

test "actions service: validatePayload enforces required, arrays, and nil" {
    const allocator = std.testing.allocator;

    const fields = [_]schema_types.ActionField{
        .{ .name = "cart_id", .declared_type = .text, .required = true },
        .{ .name = "tags", .declared_type = .array, .items_type = .text },
    };

    var ok = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
    });
    defer ok.free(allocator);
    try service_mod.validatePayload(allocator, &fields, &ok);

    var required_nil = try makePairs(allocator, &.{.{ .index = 0, .value = .nil }});
    defer required_nil.free(allocator);
    try testing.expectError(error.SchemaValidationFailed, service_mod.validatePayload(allocator, &fields, &required_nil));

    var bad_item = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("cart-1", allocator) },
        .{ .index = 1, .value = .{ .arr = blk: {
            const items = try allocator.alloc(msgpack.Payload, 1);
            items[0] = .{ .uint = 5 };
            break :blk items;
        } } },
    });
    defer bad_item.free(allocator);
    try testing.expectError(error.TypeMismatch, service_mod.validatePayload(allocator, &fields, &bad_item));
}

const async_schema_json =
    \\{"version":"1.0.0","store":{},"actions":{
    \\  "fire":{"params":{"n":{"type":"integer"}},"required":["n"],"returns":null}
    \\}}
;

test "actions service: async forwards stage until flush and concatenate in order" {
    const allocator = std.heap.smp_allocator;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "actions-async-stage", async_schema_json);
    defer app.deinit();

    const worker = try app.setupMockConnection();
    defer worker.deinit();
    const caller = try app.setupMockConnection();
    defer caller.deinit();

    var capture: [512]u8 = undefined;
    var recorder = helpers.SendRecorder.init(&capture);
    worker.conn.ws.test_send_observer = helpers.sendRecorderObserver;
    worker.conn.ws.test_send_observer_ctx = &recorder;
    recorder.reset();

    try app.actions_service.register(connectionContext(worker.conn), &.{0});

    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = msgpack.Payload.uintToPayload(5) },
    });
    defer params.free(allocator);

    const caller_ctx = connectionContext(caller.conn);
    for (0..3) |i| {
        try testing.expectEqual(
            service_mod.CallOutcome.accepted,
            try app.actions_service.call(caller_ctx, @intCast(i + 1), 0, &params, null),
        );
    }

    // Nothing is on the wire until the event-loop flush.
    try testing.expectEqual(@as(u64, 0), recorder.send_count.load(.monotonic));

    app.actions_service.flushOutbox();
    try testing.expectEqual(@as(u64, 1), recorder.send_count.load(.monotonic));

    // One frame carries three complete forwards in exec-id order.
    var reader: std.Io.Reader = .fixed(recorder.bytes());
    for (1..4) |exec_id| {
        const msg = try msgpack.decode(allocator, &reader);
        defer msg.free(allocator);
        try testing.expectEqual(@as(usize, 5), msg.arr.len);
        try testing.expectEqual(@as(u64, 0x31), msg.arr[0].uint);
        try testing.expectEqual(@as(u64, exec_id), msg.arr[1].uint);
        try testing.expectEqual(@as(u64, 0), msg.arr[3].uint);
    }

    // Flushing again is a no-op.
    app.actions_service.flushOutbox();
    try testing.expectEqual(@as(u64, 1), recorder.send_count.load(.monotonic));
}

const mixed_schema_json =
    \\{"version":"1.0.0","store":{},"actions":{
    \\  "fire":{"params":{"n":{"type":"integer"}},"required":["n"],"returns":null},
    \\  "compute":{"params":{"n":{"type":"integer"}},"required":["n"],"returns":{"r":{"type":"integer"}}}
    \\}}
;

test "actions service: sync forward flushes staged async forwards first" {
    const allocator = std.heap.smp_allocator;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "actions-sync-flush", mixed_schema_json);
    defer app.deinit();

    const worker = try app.setupMockConnection();
    defer worker.deinit();
    const caller = try app.setupMockConnection();
    defer caller.deinit();

    var capture: [512]u8 = undefined;
    var recorder = helpers.SendRecorder.init(&capture);
    worker.conn.ws.test_send_observer = helpers.sendRecorderObserver;
    worker.conn.ws.test_send_observer_ctx = &recorder;
    recorder.reset();

    try app.actions_service.register(connectionContext(worker.conn), &.{ 0, 1 });

    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = msgpack.Payload.uintToPayload(1) },
    });
    defer params.free(allocator);

    const caller_ctx = connectionContext(caller.conn);
    try testing.expectEqual(service_mod.CallOutcome.accepted, try app.actions_service.call(caller_ctx, 1, 0, &params, null));
    try testing.expectEqual(service_mod.CallOutcome.accepted, try app.actions_service.call(caller_ctx, 2, 0, &params, null));
    try testing.expectEqual(@as(u64, 0), recorder.send_count.load(.monotonic));

    // The sync call flushes the two staged forwards, then sends its own.
    try testing.expectEqual(service_mod.CallOutcome.pending, try app.actions_service.call(caller_ctx, 3, 1, &params, null));
    try testing.expectEqual(@as(u64, 2), recorder.send_count.load(.monotonic));

    var reader: std.Io.Reader = .fixed(recorder.bytes());
    const expected_action_ids = [_]u64{ 0, 0, 1 };
    for (expected_action_ids, 1..) |action_id, exec_id| {
        const msg = try msgpack.decode(allocator, &reader);
        defer msg.free(allocator);
        try testing.expectEqual(@as(usize, 5), msg.arr.len);
        try testing.expectEqual(@as(u64, 0x31), msg.arr[0].uint);
        try testing.expectEqual(@as(u64, exec_id), msg.arr[1].uint);
        try testing.expectEqual(action_id, msg.arr[3].uint);
    }
}

const big_schema_json =
    \\{"version":"1.0.0","store":{},"actions":{
    \\  "push":{"params":{"data":{"type":"string"}},"required":["data"],"returns":null}
    \\}}
;

test "actions service: oversized staging buffers release capacity after flush" {
    const allocator = std.heap.smp_allocator;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "actions-staging-capacity", big_schema_json);
    defer app.deinit();

    const worker = try app.setupMockConnection();
    defer worker.deinit();
    const caller = try app.setupMockConnection();
    defer caller.deinit();

    try app.actions_service.register(connectionContext(worker.conn), &.{0});
    const caller_ctx = connectionContext(caller.conn);

    // 96 KiB exceeds the 64 KiB retain threshold, so the buffer is released
    // after the flush instead of pinning capacity for the connection lifetime.
    const big = try allocator.alloc(u8, 96 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');
    var big_params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload(big, allocator) },
    });
    defer big_params.free(allocator);

    try testing.expectEqual(service_mod.CallOutcome.accepted, try app.actions_service.call(caller_ctx, 1, 0, &big_params, null));
    const staged = app.actions_service.outbox.getPtr(worker.conn.id).?; // zwanzig-disable-line: optional-unwrap
    try testing.expect(staged.bytes.capacity >= 96 * 1024);
    app.actions_service.flushOutbox();
    try testing.expectEqual(@as(usize, 0), staged.bytes.capacity);

    // Small bursts keep their buffer for the next iteration.
    var small_params = try makePairs(allocator, &.{
        .{ .index = 0, .value = try msgpack.Payload.strToPayload("tiny", allocator) },
    });
    defer small_params.free(allocator);
    try testing.expectEqual(service_mod.CallOutcome.accepted, try app.actions_service.call(caller_ctx, 2, 0, &small_params, null));
    app.actions_service.flushOutbox();
    try testing.expect(staged.bytes.capacity > 0);
}
