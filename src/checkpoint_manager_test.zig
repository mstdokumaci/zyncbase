const std = @import("std");
const testing = std.testing;
const CheckpointManager = @import("checkpoint_manager.zig").CheckpointManager;

// Unit tests for CheckpointManager
// These tests verify specific examples and edge cases

test "CheckpointManager: initialization" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{});
    defer manager.deinit();

    // Verify initial state
    const metrics = manager.getMetrics();
    try testing.expect(metrics.checkpoint_count == 0);
    try testing.expect(metrics.failed_checkpoint_count == 0);
    try testing.expect(metrics.last_checkpoint_time > 0); // Should be initialized to current time
}

test "CheckpointManager: shouldCheckpoint - size threshold" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{
        .wal_size_threshold = 1000,
        .time_threshold_sec = 3600, // 1 hour - won't trigger
    });
    defer manager.deinit();

    // Below threshold - should not checkpoint
    manager.wal_size.store(500, .release);
    try testing.expect(!manager.shouldCheckpoint());

    // At threshold - should checkpoint
    manager.wal_size.store(1000, .release);
    try testing.expect(manager.shouldCheckpoint());

    // Above threshold - should checkpoint
    manager.wal_size.store(2000, .release);
    try testing.expect(manager.shouldCheckpoint());
}

test "CheckpointManager: shouldCheckpoint - time threshold" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{
        .wal_size_threshold = 1000000, // 1MB - won't trigger
        .time_threshold_sec = 60, // 1 minute
    });
    defer manager.deinit();

    // Set WAL size below threshold
    manager.wal_size.store(100, .release);

    // Recent checkpoint - should not checkpoint
    manager.last_checkpoint.store(std.time.timestamp(), .release);
    try testing.expect(!manager.shouldCheckpoint());

    // Old checkpoint - should checkpoint
    manager.last_checkpoint.store(std.time.timestamp() - 120, .release); // 2 minutes ago
    try testing.expect(manager.shouldCheckpoint());
}

test "CheckpointManager: shouldCheckpoint - both thresholds" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{
        .wal_size_threshold = 1000,
        .time_threshold_sec = 60,
    });
    defer manager.deinit();

    // Neither threshold exceeded
    manager.wal_size.store(500, .release);
    manager.last_checkpoint.store(std.time.timestamp(), .release);
    try testing.expect(!manager.shouldCheckpoint());

    // Only size threshold exceeded
    manager.wal_size.store(2000, .release);
    manager.last_checkpoint.store(std.time.timestamp(), .release);
    try testing.expect(manager.shouldCheckpoint());

    // Only time threshold exceeded
    manager.wal_size.store(500, .release);
    manager.last_checkpoint.store(std.time.timestamp() - 120, .release);
    try testing.expect(manager.shouldCheckpoint());

    // Both thresholds exceeded
    manager.wal_size.store(2000, .release);
    manager.last_checkpoint.store(std.time.timestamp() - 120, .release);
    try testing.expect(manager.shouldCheckpoint());
}

test "CheckpointManager: performCheckpoint - passive mode" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{});
    defer manager.deinit();

    const result = try manager.performCheckpoint(.passive);

    try testing.expect(result.success);
    try testing.expect(result.mode == .passive);
    try testing.expect(result.duration_ms >= 0);
}

test "CheckpointManager: performCheckpoint - all modes" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{});
    defer manager.deinit();

    // Test each checkpoint mode
    const modes = [_]CheckpointManager.CheckpointMode{ .passive, .full, .restart, .truncate };

    for (modes) |mode| {
        const result = try manager.performCheckpoint(mode);
        try testing.expect(result.success);
        try testing.expect(result.mode == mode);
    }
}

test "CheckpointManager: performCheckpoint - metrics update" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{});
    defer manager.deinit();

    const metrics_before = manager.getMetrics();

    _ = try manager.performCheckpoint(.passive);

    const metrics_after = manager.getMetrics();

    // Verify checkpoint count increased
    try testing.expect(metrics_after.checkpoint_count == metrics_before.checkpoint_count + 1);

    // Verify timestamp was updated
    try testing.expect(metrics_after.last_checkpoint_time >= metrics_before.last_checkpoint_time);
}

test "CheckpointManager: CheckpointMode.toPragma" {
    try testing.expectEqualStrings("PRAGMA wal_checkpoint(PASSIVE)", CheckpointManager.CheckpointMode.passive.toPragma());
    try testing.expectEqualStrings("PRAGMA wal_checkpoint(FULL)", CheckpointManager.CheckpointMode.full.toPragma());
    try testing.expectEqualStrings("PRAGMA wal_checkpoint(RESTART)", CheckpointManager.CheckpointMode.restart.toPragma());
    try testing.expectEqualStrings("PRAGMA wal_checkpoint(TRUNCATE)", CheckpointManager.CheckpointMode.truncate.toPragma());
}

test "CheckpointManager: getMetrics" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{});
    defer manager.deinit();

    // Set some values
    manager.wal_size.store(5000, .release);
    manager.checkpoint_count.store(10, .release);
    manager.failed_checkpoint_count.store(2, .release);
    manager.last_checkpoint_duration_ms.store(150, .release);

    const metrics = manager.getMetrics();

    try testing.expect(metrics.wal_size_bytes == 5000);
    try testing.expect(metrics.checkpoint_count == 10);
    try testing.expect(metrics.failed_checkpoint_count == 2);
    try testing.expect(metrics.last_checkpoint_duration_ms == 150);
}

test "CheckpointManager: Prometheus metrics format" {
    const allocator = testing.allocator;

    const metrics = CheckpointManager.CheckpointMetrics{
        .last_checkpoint_time = 1234567890,
        .last_checkpoint_duration_ms = 150,
        .wal_size_bytes = 5000000,
        .checkpoint_count = 42,
        .failed_checkpoint_count = 3,
    };

    const output = try metrics.toPrometheus(allocator);
    defer allocator.free(output);

    // Verify format contains metric names
    try testing.expect(std.mem.indexOf(u8, output, "zyncbase_checkpoint_last_time_seconds") != null);
    try testing.expect(std.mem.indexOf(u8, output, "zyncbase_checkpoint_last_duration_ms") != null);
    try testing.expect(std.mem.indexOf(u8, output, "zyncbase_wal_size_bytes") != null);
    try testing.expect(std.mem.indexOf(u8, output, "zyncbase_checkpoint_total") != null);
    try testing.expect(std.mem.indexOf(u8, output, "zyncbase_checkpoint_failed_total") != null);

    // Verify format contains HELP and TYPE directives
    try testing.expect(std.mem.indexOf(u8, output, "# HELP") != null);
    try testing.expect(std.mem.indexOf(u8, output, "# TYPE") != null);

    // Verify values are present
    try testing.expect(std.mem.indexOf(u8, output, "1234567890") != null);
    try testing.expect(std.mem.indexOf(u8, output, "150") != null);
    try testing.expect(std.mem.indexOf(u8, output, "5000000") != null);
    try testing.expect(std.mem.indexOf(u8, output, "42") != null);
    try testing.expect(std.mem.indexOf(u8, output, "3") != null);
}

test "CheckpointManager: performCheckpointWithEscalation - no escalation needed" {
    const allocator = testing.allocator;

    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{
        .checkpoint_mode = .full, // Start with full mode
    });
    defer manager.deinit();

    const result = try manager.performCheckpointWithEscalation();

    try testing.expect(result.success);
    try testing.expect(result.mode == .full);
}

test "CheckpointManager: Config defaults" {
    const config = CheckpointManager.Config{};

    try testing.expect(config.wal_size_threshold == 10 * 1024 * 1024); // 10MB
    try testing.expect(config.time_threshold_sec == 300); // 5 minutes
    try testing.expect(config.checkpoint_mode == .passive);
    try testing.expect(config.check_interval_sec == 10);
}

test "CheckpointManager: CheckpointResult structure" {
    const result = CheckpointManager.CheckpointResult{
        .mode = .passive,
        .duration_ms = 100,
        .wal_size_before = 5000,
        .wal_size_after = 1000,
        .success = true,
    };

    try testing.expect(result.mode == .passive);
    try testing.expect(result.duration_ms == 100);
    try testing.expect(result.wal_size_before == 5000);
    try testing.expect(result.wal_size_after == 1000);
    try testing.expect(result.success);
}

test "CheckpointManager: fast shutdown" {
    const allocator = testing.allocator;
    var storage = try CheckpointManager.StorageLayer.init(allocator, ":memory:");
    defer storage.deinit();

    var manager = try CheckpointManager.init(allocator, storage, .{
        .check_interval_sec = 60, // Long interval
    });
    // No defer here, we control it manually

    const start_time = std.time.milliTimestamp();
    try manager.startBackgroundLoop();

    // Signal shutdown immediately
    manager.stop();
    manager.deinit(); // This will join and destroy the manager

    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;

    // Should be much faster than 60s
    try testing.expect(duration < 2000);
}
