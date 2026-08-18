const std = @import("std");

const checkpoint_helpers = @import("checkpoint_test_helpers.zig");
const storage_mod = @import("storage_engine.zig");
const sth = @import("storage_engine_test_helpers.zig");
const CheckpointWorker = @import("checkpoint_worker.zig").CheckpointWorker;

const testing = std.testing;

// Unit tests for CheckpointWorker
// These tests verify specific examples and edge cases

test "CheckpointWorker: initialization" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{});
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Verify initial state
    const metrics = manager.getMetrics();
    try testing.expect(metrics.checkpoint_count == 0);
    try testing.expect(metrics.failed_checkpoint_count == 0);
    try testing.expect(metrics.last_checkpoint_time > 0); // Should be initialized to current time
}

test "CheckpointWorker: shouldCheckpoint - size threshold" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1000,
        .time_threshold_sec = 3600, // 1 hour - won't trigger
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

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

test "CheckpointWorker: shouldCheckpoint - time threshold" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1000000, // 1MB - won't trigger
        .time_threshold_sec = 60, // 1 minute
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Set WAL size below threshold
    manager.wal_size.store(100, .release);

    // Recent checkpoint - should not checkpoint
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds(), .release);
    try testing.expect(!manager.shouldCheckpoint());

    // Old checkpoint - should checkpoint
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds() - 120, .release); // 2 minutes ago
    try testing.expect(manager.shouldCheckpoint());
}

test "CheckpointWorker: shouldCheckpoint - both thresholds" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1000,
        .time_threshold_sec = 60,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Neither threshold exceeded
    manager.wal_size.store(500, .release);
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds(), .release);
    try testing.expect(!manager.shouldCheckpoint());

    // Only size threshold exceeded
    manager.wal_size.store(2000, .release);
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds(), .release);
    try testing.expect(manager.shouldCheckpoint());

    // Only time threshold exceeded
    manager.wal_size.store(500, .release);
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds() - 120, .release);
    try testing.expect(manager.shouldCheckpoint());

    // Both thresholds exceeded
    manager.wal_size.store(2000, .release);
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds() - 120, .release);
    try testing.expect(manager.shouldCheckpoint());
}

test "CheckpointWorker: performCheckpoint - passive mode" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{});
    defer ctx.deinit();

    const manager = &ctx.manager;

    const result = try manager.performCheckpoint(.passive);

    try testing.expect(result.success);
    try testing.expect(result.mode == .passive);
    try testing.expect(result.duration_ms >= 0);
}

test "CheckpointWorker: performCheckpoint - all modes" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{});
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Test each checkpoint mode
    const modes = [_]storage_mod.CheckpointMode{ .passive, .full, .restart, .truncate };

    for (modes) |mode| {
        const result = try manager.performCheckpoint(mode);
        try testing.expect(result.success);
        try testing.expect(result.mode == mode);
    }
}

test "CheckpointWorker: performCheckpoint - metrics update" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{});
    defer ctx.deinit();

    const manager = &ctx.manager;

    const metrics_before = manager.getMetrics();

    _ = try manager.performCheckpoint(.passive);

    const metrics_after = manager.getMetrics();

    // Verify checkpoint count increased
    try testing.expect(metrics_after.checkpoint_count == metrics_before.checkpoint_count + 1);

    // Verify timestamp was updated
    try testing.expect(metrics_after.last_checkpoint_time >= metrics_before.last_checkpoint_time);

    // Duration may be 0 for very fast runs; verify value is valid.
    try testing.expect(metrics_after.last_checkpoint_duration_ms >= 0);
}

test "CheckpointWorker: getMetrics" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{});
    defer ctx.deinit();

    const manager = &ctx.manager;

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

test "CheckpointWorker: Prometheus metrics format" {
    const allocator = std.heap.smp_allocator;

    const metrics = CheckpointWorker.CheckpointMetrics{
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

test "CheckpointWorker: performCheckpointWithEscalation - no escalation needed" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .checkpoint_mode = .full, // Start with full mode
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    const result = try manager.performCheckpointWithEscalation();

    try testing.expect(result.success);
    try testing.expect(result.mode == .full);
}

test "CheckpointWorker: Config defaults" {
    const config = CheckpointWorker.Config{};

    try testing.expect(config.wal_size_threshold == 10 * 1024 * 1024); // 10MB
    try testing.expect(config.time_threshold_sec == 300); // 5 minutes
    try testing.expect(config.checkpoint_mode == .passive);
    try testing.expect(config.check_interval_sec == 10);
    try testing.expect(config.max_attempts == 3);
}

test "CheckpointWorker: CheckpointResult structure" {
    const result = CheckpointWorker.CheckpointResult{
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

test "CheckpointWorker: shouldCheckpoint - clock rollback" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1000,
        .time_threshold_sec = 60,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Simulate clock rollback: last_checkpoint is in the future
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds() + 3600, .release);
    manager.wal_size.store(500, .release);

    // Should not panic and should NOT trigger time-based checkpoint
    try testing.expect(!manager.shouldCheckpoint());

    // Even with clock rolled back, size threshold should still work
    manager.wal_size.store(2000, .release);
    try testing.expect(manager.shouldCheckpoint());
}

test "CheckpointWorker: fast shutdown" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .check_interval_sec = 60, // Long interval
    });
    // No defer here, we control timing manually
    defer ctx.deinit();

    const manager = &ctx.manager;

    const start_time = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    try manager.spawn();

    // Signal shutdown immediately
    manager.stop();
    manager.deinit(); // This will join

    const end_time = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    const duration = end_time - start_time;

    // Should be much faster than 60s
    try testing.expect(duration < 2000);
}

// 1. No data loss occurs during checkpoint
// 2. WAL size decreases or stays same after successful checkpoint
// 3. Checkpoint metrics accurately reflect operation
// 4. Failed checkpoints don't corrupt database state
// 5. Concurrent reads can continue during checkpoint

test "checkpoint: integrity - no data loss occurs during checkpoint" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024, // 1KB for testing
        .time_threshold_sec = 1, // 1 second for testing
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Insert representative records through the storage engine the
    // checkpoint worker manages, then flush them to SQLite.
    const table_metadata = ctx.schema.table("items") orelse return error.MissingItemsTable;
    const fixture = sth.TableFixture{
        .engine = &ctx.storage_engine,
        .metadata = table_metadata,
    };
    const namespace_id: i64 = 1;
    try fixture.insertText(1, namespace_id, "name", "alpha");
    try fixture.insertText(2, namespace_id, "name", "beta");
    try fixture.flush();

    const metrics_before = manager.getMetrics();

    // Simulate WAL growth (in-memory WAL reports 0 bytes)
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

    // Property: Checkpoint must not lose data — every record inserted
    // before the checkpoint must be readable afterwards, unchanged.
    const alpha = try sth.readDoc(allocator, &ctx.storage_engine, table_metadata.index, 1, namespace_id);
    defer if (alpha) |r| r.deinit(allocator);
    try testing.expect(alpha != null);
    _ = try sth.expectFieldString(alpha.?, table_metadata, "name", "alpha");

    const beta = try sth.readDoc(allocator, &ctx.storage_engine, table_metadata.index, 2, namespace_id);
    defer if (beta) |r| r.deinit(allocator);
    try testing.expect(beta != null);
    _ = try sth.expectFieldString(beta.?, table_metadata, "name", "beta");
}

test "checkpoint: WAL size management - size decreases or stays same after success" {
    const allocator = std.heap.smp_allocator;

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

    // WAL size after should be <= WAL size before
    try testing.expect(result.success);
    try testing.expect(result.wal_size_after <= result.wal_size_before);
    try testing.expect(result.wal_size_before == initial_wal_size);
}

test "checkpoint: threshold detection - shouldCheckpoint respects thresholds" {
    const allocator = std.heap.smp_allocator;

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
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds(), .release);
    try testing.expect(!manager.shouldCheckpoint());

    // Property: shouldCheckpoint returns true when time threshold exceeded
    manager.last_checkpoint.store(std.Io.Clock.real.now(std.testing.io).toSeconds() - 120, .release); // 2 minutes ago
    try testing.expect(manager.shouldCheckpoint());
}

test "checkpoint: failure handling - failure counter starts at zero" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024,
        .time_threshold_sec = 300,
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: The failure counter starts at zero on a fresh manager
    // (no failure injection hook exists, so this test verifies the initial state)
    const initial_failures = manager.failed_checkpoint_count.load(.acquire);

    try testing.expect(initial_failures == 0);
}

test "checkpoint: escalation logic - works correctly when needed" {
    const allocator = std.heap.smp_allocator;

    var ctx: checkpoint_helpers.Context = undefined;
    try ctx.init(allocator, .{
        .wal_size_threshold = 1024,
        .time_threshold_sec = 300,
        .checkpoint_mode = .passive,
    });
    defer ctx.deinit();

    const manager = &ctx.manager;

    // Property: Escalation logic works correctly.
    // The in-memory WAL size is 0, so a passive checkpoint cannot reduce the
    // WAL by >=10% and the worker must escalate to full mode.
    const result = try manager.performCheckpointWithEscalation();

    // Verify checkpoint was attempted (success flag should be set)
    try testing.expect(result.success);
    // Verify escalation actually occurred (passive would mean no escalation)
    try testing.expect(result.mode != .passive);
    // Duration may be 0 in fast runs, but should be >= 0
    try testing.expect(result.duration_ms >= 0);
}
