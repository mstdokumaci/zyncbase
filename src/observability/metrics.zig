const std = @import("std");

pub const ServerMetrics = struct {
    /// Unix timestamp (seconds) when the server started accepting connections.
    started_at: i64,

    // ── Connection counters ───────────────────────────────────────────
    /// Lifetime total of accepted WebSocket connections.
    connections_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // ── Message counters ─────────────────────────────────────────────
    /// Total inbound WebSocket messages processed (including pings and
    /// rejected text frames).
    messages_received_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Total outbound messages accepted for delivery. A concatenated frame
    /// counts each message it carries.
    messages_sent_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // ── Error / rejection counters ───────────────────────────────────
    /// Messages rejected by the rate limiter.
    rate_limit_rejections_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Error responses sent (wire errors).
    errors_sent_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(started_at: i64) ServerMetrics {
        return .{
            .started_at = started_at,
        };
    }

    pub fn recordConnectionOpen(self: *ServerMetrics) void {
        _ = self.connections_total.fetchAdd(1, .monotonic);
    }

    pub fn recordMessageReceived(self: *ServerMetrics) void {
        _ = self.messages_received_total.fetchAdd(1, .monotonic);
    }

    pub fn recordMessagesSent(self: *ServerMetrics, count: u64) void {
        _ = self.messages_sent_total.fetchAdd(count, .monotonic);
    }

    pub fn recordMessageSent(self: *ServerMetrics) void {
        self.recordMessagesSent(1);
    }

    pub fn recordRateLimitRejection(self: *ServerMetrics) void {
        _ = self.rate_limit_rejections_total.fetchAdd(1, .monotonic);
    }

    pub fn recordErrorSent(self: *ServerMetrics) void {
        _ = self.errors_sent_total.fetchAdd(1, .monotonic);
    }
};
