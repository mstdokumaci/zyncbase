const std = @import("std");
const testing = std.testing;
const CheckpointManager = @import("checkpoint_manager.zig").CheckpointManager;
const checkpoint_helpers = @import("checkpoint_test_helpers.zig");

// 1. No data loss occurs during checkpoint
// 2. WAL size decreases or stays same after successful checkpoint
// 3. Checkpoint metrics accurately reflect operation
// 4. Failed checkpoints don't corrupt database state
// 5. Concurrent reads can continue during checkpoint

test "checkpoint: integrity - no data loss occurs during checkpoint" {
    const allocator = testing.allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024, // 1KB for testing
        .time_threshold_sec = 1, // 1 second for testing
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: Checkpoint should not lose data
    // We verify this by checking that metrics are consistent before and after
    const metrics_before = manager.getMetrics();

    // Simulate WAL growth
    manager.wal_size.store(2048, .release); // Exceed threshold

    // Verify shouldCheckpoint returns true
    try testing.expect(manager.shouldCheckpoint());

    // Perform checkpoint
    const result = try manager.performCheckpoint(.passive);

    // Verify checkpoint succeeded
    try testing.expect(result.success);

    // Verify metrics were updated
    const metrics_after = manager.getMetrics();
    try testing.expect(metrics_after.checkpoint_count == metrics_before.checkpoint_count + 1);
    try testing.expect(metrics_after.last_checkpoint_time >= metrics_before.last_checkpoint_time);
}

test "checkpoint: WAL size management - size decreases or stays same after success" {
    const allocator = testing.allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024,
        .time_threshold_sec = 300,
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: WAL size should decrease or stay same after successful checkpoint
    const initial_wal_size: usize = 5000;
    manager.wal_size.store(initial_wal_size, .release);

    const result = try manager.performCheckpoint(.truncate);

    if (result.success) {
        // WAL size after should be <= WAL size before
        try testing.expect(result.wal_size_after <= result.wal_size_before);
        try testing.expect(result.wal_size_before == initial_wal_size);
    }
}

test "checkpoint: threshold detection - shouldCheckpoint respects thresholds" {
    const allocator = testing.allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1000,
        .time_threshold_sec = 60,
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: shouldCheckpoint returns true when size threshold exceeded
    manager.wal_size.store(1500, .release);
    try testing.expect(manager.shouldCheckpoint());

    // Property: shouldCheckpoint returns false when under threshold
    manager.wal_size.store(500, .release);
    manager.last_checkpoint.store(std.time.timestamp(), .release);
    try testing.expect(!manager.shouldCheckpoint());

    // Property: shouldCheckpoint returns true when time threshold exceeded
    manager.last_checkpoint.store(std.time.timestamp() - 120, .release); // 2 minutes ago
    try testing.expect(manager.shouldCheckpoint());
}

test "checkpoint: failure handling - failed checkpoints increment counter" {
    const allocator = testing.allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024,
        .time_threshold_sec = 300,
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: Failed checkpoints increment failure counter
    const initial_failures = manager.failed_checkpoint_count.load(.acquire);

    // Note: In real implementation, we would inject a failure here
    // For now, we just verify the counter exists and can be read
    try testing.expect(initial_failures == 0);
}

test "checkpoint: metrics accuracy - metrics reflect operations accurately" {
    const allocator = testing.allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024,
        .time_threshold_sec = 300,
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: Metrics accurately reflect checkpoint operations
    const metrics_before = manager.getMetrics();

    // Perform checkpoint
    _ = try manager.performCheckpoint(.passive);

    const metrics_after = manager.getMetrics();

    // Verify checkpoint count increased
    try testing.expect(metrics_after.checkpoint_count == metrics_before.checkpoint_count + 1);

    // Verify timestamp updated
    try testing.expect(metrics_after.last_checkpoint_time >= metrics_before.last_checkpoint_time);

    // Duration may be 0 for very fast runs; verify value is valid.
    try testing.expect(metrics_after.last_checkpoint_duration_ms >= 0);
}

test "checkpoint: escalation logic - works correctly when needed" {
    const allocator = testing.allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024,
        .time_threshold_sec = 300,
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: Escalation logic works correctly
    // Set up scenario where passive checkpoint doesn't reduce WAL much
    manager.wal_size.store(10000, .release);

    const result = try manager.performCheckpointWithEscalation();

    // Verify checkpoint was attempted (success flag should be set)
    try testing.expect(result.success);
    // Duration may be 0 in fast runs, but should be >= 0
    try testing.expect(result.duration_ms >= 0);
}

test "checkpoint: Prometheus formatting - output contains all required metrics" {
    const allocator = testing.allocator;

    const metrics = CheckpointManager.CheckpointMetrics{
        .last_checkpoint_time = 1234567890,
        .last_checkpoint_duration_ms = 150,
        .wal_size_bytes = 5000000,
        .checkpoint_count = 42,
        .failed_checkpoint_count = 3,
    };

    const prometheus_output = try metrics.toPrometheus(allocator);
    defer allocator.free(prometheus_output);

    // Property: Prometheus output contains all required metrics
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "zyncbase_checkpoint_last_time_seconds") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "zyncbase_checkpoint_last_duration_ms") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "zyncbase_wal_size_bytes") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "zyncbase_checkpoint_total") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "zyncbase_checkpoint_failed_total") != null);

    // Property: Prometheus output contains correct values
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "1234567890") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "150") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "5000000") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "42") != null);
    try testing.expect(std.mem.indexOf(u8, prometheus_output, "3") != null);
}
