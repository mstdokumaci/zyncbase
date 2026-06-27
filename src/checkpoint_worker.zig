const std = @import("std");
const storage_mod = @import("storage_engine.zig");
const Allocator = std.mem.Allocator;
const managedThread = @import("threading/managed_thread.zig").managedThread;

/// CheckpointWorker manages SQLite WAL checkpointing to prevent unbounded WAL growth
/// and ensure predictable performance. It monitors WAL file size and age, triggering
/// checkpoints based on configurable thresholds.
pub const CheckpointWorker = struct {
    allocator: Allocator,
    storage_engine: *storage_mod.StorageEngine,
    config: Config,
    last_checkpoint: std.atomic.Value(i64),
    wal_size: std.atomic.Value(usize),
    checkpoint_count: std.atomic.Value(u64),
    failed_checkpoint_count: std.atomic.Value(u64),
    last_checkpoint_duration_ms: std.atomic.Value(u64),
    thread: managedThread(CheckpointWorker),

    /// Configuration for checkpoint behavior
    pub const Config = struct {
        /// WAL size threshold in bytes (default: 10MB)
        wal_size_threshold: usize = 10 * 1024 * 1024,
        /// Time threshold in seconds (default: 5 minutes)
        time_threshold_sec: u64 = 300,
        /// Default checkpoint mode
        checkpoint_mode: storage_mod.CheckpointMode = .passive,
        /// Background check interval in seconds (default: 10 seconds)
        check_interval_sec: u64 = 10,
        /// Maximum total attempts for transient checkpoint failures (default: 3)
        max_attempts: u32 = 3,
    };

    /// Result of a checkpoint operation
    pub const CheckpointResult = struct {
        mode: storage_mod.CheckpointMode,
        duration_ms: u64,
        wal_size_before: usize,
        wal_size_after: usize,
        success: bool,
    };

    /// Metrics for Prometheus export
    pub const CheckpointMetrics = struct {
        last_checkpoint_time: i64,
        last_checkpoint_duration_ms: u64,
        wal_size_bytes: usize,
        checkpoint_count: u64,
        failed_checkpoint_count: u64,

        pub fn toPrometheus(self: CheckpointMetrics, allocator: Allocator) ![]const u8 {
            return std.fmt.allocPrint(allocator,
                \\# HELP zyncbase_checkpoint_last_time_seconds Unix timestamp of last checkpoint
                \\# TYPE zyncbase_checkpoint_last_time_seconds gauge
                \\zyncbase_checkpoint_last_time_seconds {d}
                \\# HELP zyncbase_checkpoint_last_duration_ms Duration of last checkpoint in milliseconds
                \\# TYPE zyncbase_checkpoint_last_duration_ms gauge
                \\zyncbase_checkpoint_last_duration_ms {d}
                \\# HELP zyncbase_wal_size_bytes Current WAL file size in bytes
                \\# TYPE zyncbase_wal_size_bytes gauge
                \\zyncbase_wal_size_bytes {d}
                \\# HELP zyncbase_checkpoint_total Total number of successful checkpoints
                \\# TYPE zyncbase_checkpoint_total counter
                \\zyncbase_checkpoint_total {d}
                \\# HELP zyncbase_checkpoint_failed_total Total number of failed checkpoints
                \\# TYPE zyncbase_checkpoint_failed_total counter
                \\zyncbase_checkpoint_failed_total {d}
                \\
            , .{
                self.last_checkpoint_time,
                self.last_checkpoint_duration_ms,
                self.wal_size_bytes,
                self.checkpoint_count,
                self.failed_checkpoint_count,
            });
        }
    };

    /// Initialize a new CheckpointWorker
    pub fn init(self: *CheckpointWorker, allocator: Allocator, storage_engine: *storage_mod.StorageEngine, config: Config) !void {
        const now = std.time.timestamp();

        self.* = .{
            .allocator = allocator,
            .storage_engine = storage_engine,
            .config = config,
            .last_checkpoint = std.atomic.Value(i64).init(now),
            .wal_size = std.atomic.Value(usize).init(0),
            .checkpoint_count = std.atomic.Value(u64).init(0),
            .failed_checkpoint_count = std.atomic.Value(u64).init(0),
            .last_checkpoint_duration_ms = std.atomic.Value(u64).init(0),
            .thread = managedThread(CheckpointWorker).init(),
        };

        // Query initial WAL size
        const initial_wal_size = try storage_engine.getWalSize();
        self.wal_size.store(initial_wal_size, .release);
    }

    /// Clean up resources
    pub fn deinit(self: *CheckpointWorker) void {
        self.stop();
    }

    /// Get current metrics for monitoring
    pub fn getMetrics(self: *CheckpointWorker) CheckpointMetrics {
        return .{
            .last_checkpoint_time = self.last_checkpoint.load(.acquire),
            .last_checkpoint_duration_ms = self.last_checkpoint_duration_ms.load(.acquire),
            .wal_size_bytes = self.wal_size.load(.acquire),
            .checkpoint_count = self.checkpoint_count.load(.acquire),
            .failed_checkpoint_count = self.failed_checkpoint_count.load(.acquire),
        };
    }

    /// Determine if a checkpoint should be triggered based on thresholds
    pub fn shouldCheckpoint(self: *CheckpointWorker) bool {
        const now = std.time.timestamp();
        const last_checkpoint = self.last_checkpoint.load(.acquire);
        const current_wal_size = self.wal_size.load(.acquire);

        // Check WAL size threshold
        const size_exceeded = current_wal_size >= self.config.wal_size_threshold;

        // Check time threshold
        if (now <= last_checkpoint) return size_exceeded;
        const time_elapsed: u64 = @intCast(now - last_checkpoint);
        const time_exceeded = time_elapsed >= self.config.time_threshold_sec;

        // Checkpoint if either threshold exceeded
        return size_exceeded or time_exceeded;
    }

    /// Perform a checkpoint operation
    pub fn performCheckpoint(self: *CheckpointWorker, mode: storage_mod.CheckpointMode) !CheckpointResult {
        const start_time = std.time.milliTimestamp();
        const wal_size_before = self.wal_size.load(.acquire);

        // Execute checkpoint
        _ = self.storage_engine.executeCheckpoint(mode) catch |err| {
            // Increment failure counter
            _ = self.failed_checkpoint_count.fetchAdd(1, .acq_rel);

            // Log error
            std.log.err("Checkpoint failed with mode {s}: {}", .{ @tagName(mode), err });

            return CheckpointResult{
                .mode = mode,
                .duration_ms = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start_time)),
                .wal_size_before = wal_size_before,
                .wal_size_after = wal_size_before,
                .success = false,
            };
        };

        // Update metrics
        const end_time = std.time.milliTimestamp();
        const duration: u64 = @intCast(end_time - start_time);

        self.last_checkpoint.store(std.time.timestamp(), .release);
        _ = self.checkpoint_count.fetchAdd(1, .acq_rel);
        self.last_checkpoint_duration_ms.store(duration, .release);

        // Query new WAL size
        const new_wal_size = try self.storage_engine.getWalSize();
        self.wal_size.store(new_wal_size, .release);

        std.log.info("Checkpoint completed: mode={s}, duration={}ms, wal_before={}, wal_after={}", .{
            @tagName(mode),
            duration,
            wal_size_before,
            new_wal_size,
        });

        return CheckpointResult{
            .mode = mode,
            .duration_ms = duration,
            .wal_size_before = wal_size_before,
            .wal_size_after = new_wal_size,
            .success = true,
        };
    }

    /// Perform checkpoint with automatic escalation on failure
    pub fn performCheckpointWithEscalation(self: *CheckpointWorker) !CheckpointResult {
        const wal_size_before_initial = self.wal_size.load(.acquire);

        // Try with configured mode first, with retry on transient failures
        var result = self.performCheckpointWithRetry(self.config.checkpoint_mode, self.config.max_attempts) catch |err| {
            if (err != error.CheckpointFailed) return err;
            return CheckpointResult{
                .mode = self.config.checkpoint_mode,
                .duration_ms = 0,
                .wal_size_before = wal_size_before_initial,
                .wal_size_after = self.wal_size.load(.acquire),
                .success = false,
            };
        };

        // If passive mode didn't reduce WAL size significantly, escalate to full
        if (self.config.checkpoint_mode == .passive and result.success) {
            const reduction = if (result.wal_size_before > result.wal_size_after)
                result.wal_size_before - result.wal_size_after
            else
                0;

            // If WAL size reduced by less than 10%, escalate to full mode
            const reduction_percent = if (result.wal_size_before > 0)
                (reduction * 100) / result.wal_size_before
            else
                0;

            if (reduction_percent < 10) {
                std.log.warn("Passive checkpoint only reduced WAL by {}%, escalating to full mode", .{reduction_percent});
                result = self.performCheckpointWithRetry(.full, self.config.max_attempts) catch |err| {
                    if (err != error.CheckpointFailed) return err;
                    return CheckpointResult{
                        .mode = .full,
                        .duration_ms = 0,
                        .wal_size_before = result.wal_size_after,
                        .wal_size_after = self.wal_size.load(.acquire),
                        .success = false,
                    };
                };
            }
        }

        return result;
    }

    /// Handle checkpoint failure with retry logic
    pub fn performCheckpointWithRetry(self: *CheckpointWorker, mode: storage_mod.CheckpointMode, max_attempts: u32) !CheckpointResult {
        const attempts = if (max_attempts == 0) @as(u32, 1) else max_attempts;
        var attempt: u32 = 0;
        var backoff_ms: u64 = 100; // Start with 100ms

        while (attempt < attempts) : (attempt += 1) {
            const result = try self.performCheckpoint(mode);

            if (result.success) {
                if (attempt > 0) {
                    std.log.info("Checkpoint succeeded after {} retries", .{attempt});
                }
                return result;
            }

            // Exponential backoff
            if (attempt < attempts - 1) {
                std.log.warn("Checkpoint failed, retrying in {}ms (attempt {}/{})", .{ backoff_ms, attempt + 1, attempts });
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                backoff_ms *= 2; // Double the backoff time
            }
        }

        std.log.err("Checkpoint failed after {} attempts", .{attempts});
        return error.CheckpointFailed;
    }

    /// Background checkpoint loop for automatic checkpointing
    pub fn backgroundCheckpointLoop(self: *CheckpointWorker) void {
        std.log.info("Starting background checkpoint loop (interval: {}s)", .{self.config.check_interval_sec});

        self.thread.mutex.lock();
        defer self.thread.mutex.unlock();
        while (!self.thread.isRequested()) {
            // Wait for configured interval or shutdown signal
            self.thread.cond.timedWait(&self.thread.mutex, self.config.check_interval_sec * std.time.ns_per_s) catch |err| {
                if (err != error.Timeout) {
                    std.log.err("shutdown_cond.timedWait failed: {}", .{err});
                }
            };

            if (self.thread.isRequested()) break;

            // Check if checkpoint is needed
            if (self.shouldCheckpoint()) {
                const wal_size = self.wal_size.load(.acquire);
                const last_checkpoint = self.last_checkpoint.load(.acquire);
                const raw_time = std.time.timestamp() - last_checkpoint;
                const time_since_last = if (raw_time < 0) @as(i64, 0) else raw_time;

                std.log.info("Checkpoint triggered: wal_size={} bytes, time_since_last={}s", .{ wal_size, time_since_last });

                // Unlock for actual work
                self.thread.mutex.unlock();
                const result = self.performCheckpointWithEscalation() catch |err| {
                    std.log.err("Background checkpoint failed: {}", .{err});
                    self.thread.mutex.lock();
                    continue;
                };
                self.thread.mutex.lock();

                if (result.success) {
                    std.log.info("Background checkpoint completed successfully", .{});
                } else {
                    std.log.warn("Background checkpoint completed with issues", .{});
                }
            }
        }
        std.log.info("Background checkpoint loop stopped.", .{});
    }

    /// Stop the background checkpoint loop
    pub fn stop(self: *CheckpointWorker) void {
        self.thread.stop();
    }

    /// Start background checkpoint loop in a separate thread
    pub fn spawn(self: *CheckpointWorker) !void {
        try self.thread.spawn(backgroundCheckpointLoop, self);
    }
};
