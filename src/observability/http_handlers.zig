const std = @import("std");

const CheckpointWorker = @import("../checkpoint_worker.zig").CheckpointWorker;
const c = @import("../uwebsockets_wrapper.zig").c;
const ServerMetrics = @import("metrics.zig").ServerMetrics;

pub const HttpContext = struct {
    ssl: bool,
    io: std.Io,
    metrics: *ServerMetrics,
    active_connection_count: *std.atomic.Value(usize),
    checkpoint_worker: *CheckpointWorker,
};

/// GET /health — lightweight liveness probe, unauthenticated.
/// Returns 200 with {"status":"ok"} if the event loop is responsive.
pub fn handleHealth(res: ?*c.uws_res_t, _: ?*c.uws_req_t, user_data: ?*anyopaque) callconv(.c) void {
    const res_nn = res orelse return;
    const ctx: *HttpContext = @ptrCast(@alignCast(user_data orelse return));
    const ssl: c_int = if (ctx.ssl) 1 else 0;

    const body = "{\"status\":\"ok\"}";
    c.uws_res_write_status(ssl, res_nn, "200 OK", "200 OK".len);
    c.uws_res_write_header(ssl, res_nn, "Content-Type", "Content-Type".len, "application/json", "application/json".len);
    c.uws_res_end(ssl, res_nn, body.ptr, body.len, 0);
}

/// GET /stats — server diagnostics.
/// Returns JSON with connection counts, message throughput, storage stats, uptime.
pub fn handleStats(res: ?*c.uws_res_t, _: ?*c.uws_req_t, user_data: ?*anyopaque) callconv(.c) void {
    const res_nn = res orelse return;
    const ctx: *HttpContext = @ptrCast(@alignCast(user_data orelse return));
    const ssl: c_int = if (ctx.ssl) 1 else 0;

    const metrics = ctx.metrics;
    const now = std.Io.Clock.real.now(ctx.io).toSeconds();
    const uptime = @max(0, now - metrics.started_at);
    const active = ctx.active_connection_count.load(.acquire);
    const ckpt = ctx.checkpoint_worker.getMetrics();

    // Fixed-size stack buffer — no allocation, no failure path.
    var buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&buf,
        \\{{"uptime_seconds":{d},"connections":{{"active":{d},"total":{d}}},"messages":{{"received_total":{d},"sent_total":{d}}},"errors":{{"sent_total":{d},"rate_limit_rejections_total":{d}}},"storage":{{"last_checkpoint_time":{d},"wal_size_bytes":{d},"checkpoint_count":{d},"failed_checkpoint_count":{d},"last_checkpoint_duration_ms":{d}}}}}
    , .{
        uptime,
        active,
        metrics.connections_total.load(.monotonic),
        metrics.messages_received_total.load(.monotonic),
        metrics.messages_sent_total.load(.monotonic),
        metrics.errors_sent_total.load(.monotonic),
        metrics.rate_limit_rejections_total.load(.monotonic),
        ckpt.last_checkpoint_time,
        ckpt.wal_size_bytes,
        ckpt.checkpoint_count,
        ckpt.failed_checkpoint_count,
        ckpt.last_checkpoint_duration_ms,
    }) catch {
        c.uws_res_write_status(ssl, res_nn, "500 Internal Server Error", "500 Internal Server Error".len);
        c.uws_res_end(ssl, res_nn, "metrics format error", "metrics format error".len, 0);
        return;
    };

    c.uws_res_write_status(ssl, res_nn, "200 OK", "200 OK".len);
    c.uws_res_write_header(ssl, res_nn, "Content-Type", "Content-Type".len, "application/json", "application/json".len);
    c.uws_res_write_header(ssl, res_nn, "Cache-Control", "Cache-Control".len, "no-store", "no-store".len);
    c.uws_res_end(ssl, res_nn, body.ptr, body.len, 0);
}
