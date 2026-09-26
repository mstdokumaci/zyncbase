const builtin = @import("builtin");
const std = @import("std");

const helpers = @import("../app_test_helpers.zig");
const msgpack = @import("../msgpack_utils.zig");
const wire_encode = @import("../wire/encode.zig");
const service_mod = @import("service.zig");

const testing = std.testing;
const AppTestContext = helpers.AppTestContext;
const SessionContext = service_mod.SessionContext;

const schema_json =
    \\{"version":"1.0.0","store":{},"actions":{
    \\  "ingest":{
    \\    "params":{"seq":{"type":"integer"},"value":{"type":"integer"}},
    \\    "required":["seq"],
    \\    "returns":null
    \\  }
    \\}}
;

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

// Measures the staged async forward path with one registered worker, shaped as
// event-loop iterations: `burst_size` calls arrive, then flushOutbox() delivers
// one concatenated frame per worker. Stages:
//   A: call() × burst_size — authorization, schema validation, exec-id
//      allocation, forward encoding, and staging into the outbox.
//   B: flushOutbox() — one send per worker per burst.
//   C: encodeActionForward() alone — attribution reference for A.
// Pre-batching baseline for the same 1-worker path: call=347 ns/call,
// frames/call=1.0 (ReleaseFast).
test "ActionsService: async forward dispatch throughput (1 worker)" {
    const allocator = std.heap.smp_allocator;
    var app: AppTestContext = undefined;
    try app.initWithSchemaJSON(allocator, "actions-forward-perf", schema_json);
    defer app.deinit();

    const worker = try app.setupMockConnection();
    defer worker.deinit();
    const caller = try app.setupMockConnection();
    defer caller.deinit();

    var capture: [256]u8 = undefined;
    var recorder = helpers.SendRecorder.init(&capture);
    worker.conn.ws.test_send_observer = helpers.sendRecorderObserver;
    worker.conn.ws.test_send_observer_ctx = &recorder;
    recorder.reset();

    try app.actions_service.register(connectionContext(worker.conn), &.{0});

    var params = try makePairs(allocator, &.{
        .{ .index = 0, .value = msgpack.Payload.uintToPayload(7) },
        .{ .index = 1, .value = msgpack.Payload.uintToPayload(42) },
    });
    defer params.free(allocator);

    const caller_ctx = connectionContext(caller.conn);

    const is_debug = builtin.mode == .Debug;
    const is_tsan = builtin.sanitize_thread;
    const burst_size: usize = 64;
    const burst_count: usize = if (is_tsan) 32 else if (is_debug) 320 else 1_600;
    const total_calls = burst_count * burst_size;

    for (0..5) |b| {
        for (0..burst_size) |i| {
            try testing.expectEqual(
                service_mod.CallOutcome.accepted,
                try app.actions_service.call(caller_ctx, @intCast(b * burst_size + i), 0, &params, null),
            );
        }
        app.actions_service.flushOutbox();
    }
    recorder.reset();

    var total_call_ns: u64 = 0;
    var total_flush_ns: u64 = 0;
    for (0..burst_count) |b| {
        const call_start_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        for (0..burst_size) |i| {
            _ = try app.actions_service.call(caller_ctx, @intCast(b * burst_size + i), 0, &params, null);
        }
        const flush_start_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        app.actions_service.flushOutbox();
        const flush_end_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
        total_call_ns += @intCast(flush_start_ns - call_start_ns);
        total_flush_ns += @intCast(flush_end_ns - flush_start_ns);
    }

    // One concatenated frame per burst replaces one frame per call.
    const frames = recorder.send_count.load(.monotonic);
    try testing.expectEqual(@as(u64, @intCast(burst_count)), frames);

    const user_id = caller.conn.user_doc_id;
    const encode_start_ns = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    for (0..total_calls) |i| {
        const bytes = try wire_encode.encodeActionForward(allocator, @intCast(i + 1), user_id, 0, &params);
        allocator.free(bytes);
    }
    const encode_ns: u64 = @intCast(std.Io.Clock.awake.now(testing.io).toNanoseconds() - encode_start_ns);

    const inv_calls = 1.0 / @as(f64, @floatFromInt(total_calls));
    const inv_bursts = 1.0 / @as(f64, @floatFromInt(burst_count));
    const avg_call_ns = @as(f64, @floatFromInt(total_call_ns)) * inv_calls;
    const avg_flush_ns = @as(f64, @floatFromInt(total_flush_ns)) * inv_bursts;
    const avg_encode_ns = @as(f64, @floatFromInt(encode_ns)) * inv_calls;
    const frames_per_call = @as(f64, @floatFromInt(frames)) * inv_calls;
    const calls_per_second = @as(f64, @floatFromInt(total_calls)) /
        (@as(f64, @floatFromInt(total_call_ns + total_flush_ns)) / 1e9);

    std.debug.print(
        "Actions async forward (1 worker, {d}x{d} calls): call(A)={d:.0} ns/call flush(B)={d:.0} ns/burst encode(C)={d:.0} ns/call frames/call={d:.4} calls/s={d:.0}\n",
        .{
            burst_count,
            burst_size,
            avg_call_ns,
            avg_flush_ns,
            avg_encode_ns,
            frames_per_call,
            calls_per_second,
        },
    );

    const target_call_ns: f64 = if (is_tsan) 100_000 else if (is_debug) 7_000 else 1_500;
    try testing.expect(avg_call_ns < target_call_ns);
}
