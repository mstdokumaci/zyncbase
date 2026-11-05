const std = @import("std");

const ServerMetrics = @import("metrics.zig").ServerMetrics;

const testing = std.testing;

test "ServerMetrics increments are independent" {
    var m = ServerMetrics.init(1000);
    m.recordConnectionOpen();
    m.recordConnectionOpen();
    m.recordMessageReceived();
    m.recordMessagesSent(3);
    m.recordMessageSent();
    m.recordRateLimitRejection();
    m.recordErrorSent();
    try testing.expectEqual(@as(u64, 2), m.connections_total.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.messages_received_total.load(.monotonic));
    try testing.expectEqual(@as(u64, 4), m.messages_sent_total.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.rate_limit_rejections_total.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.errors_sent_total.load(.monotonic));
    try testing.expectEqual(@as(i64, 1000), m.started_at);
}
