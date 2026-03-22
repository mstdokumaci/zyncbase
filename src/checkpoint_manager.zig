const std = @import("std");
const storage_mod = @import("storage_engine.zig");
const Allocator = std.mem.Allocator;

/// CheckpointManager manages SQLite WAL checkpointing to prevent unbounded WAL growth
/// and ensure predictable performance. It monitors WAL file size and age, triggering
/// checkpoints based on configurable thresholds.
pub const CheckpointManager = struct {
    allocator: Allocator,
    storage: *StorageLayer,
    config: Config,
    last_checkpoint: std.atomic.Value(i64),
    wal_size: std.atomic.Value(usize),
    checkpoint_count: std.atomic.Value(u64),
    failed_checkpoint_count: std.atomic.Value(u64),
    last_checkpoint_duration_ms: std.atomic.Value(u64),
    background_thread: ?std.Thread,
    shutdown_requested: std.atomic.Value(bool),
    shutdown_cond: std.Thread.Condition,
    shutdown_mutex: std.Thread.Mutex,

    /// Configuration for checkpoint behavior
    pub const Config = struct {
        /// WAL size threshold in bytes (default: 10MB)
        wal_size_threshold: usize = 10 * 1024 * 1024,
        /// Time threshold in seconds (default: 5 minutes)
        time_threshold_sec: u64 = 300,
        /// Default checkpoint mode
        checkpoint_mode: CheckpointMode = .passive,
        /// Background check interval in seconds (default: 10 seconds)
        check_interval_sec: u64 = 10,
    };

    /// SQLite checkpoint modes
    pub const CheckpointMode = enum {
        /// Passive mode: checkpoint without blocking readers/writers
        passive,
        /// Full mode: wait for readers to finish, then checkpoint
        full,
        /// Restart mode: checkpoint and reset WAL
        restart,
        /// Truncate mode: checkpoint and truncate WAL to zero bytes
        truncate,

        pub fn toPragma(self: CheckpointMode) []const u8 {
            return switch (self) {
                .passive => "PRAGMA wal_checkpoint(PASSIVE)",
                .full => "PRAGMA wal_checkpoint(FULL)",
                .restart => "PRAGMA wal_checkpoint(RESTART)",
                .truncate => "PRAGMA wal_checkpoint(TRUNCATE)",
            };
        }
    };

    /// Result of a checkpoint operation
    pub const CheckpointResult = struct {
        mode: CheckpointMode,
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

    /// Placeholder for storage layer - will be implemented separately
    pub const StorageLayer = struct {
        allocator: Allocator,
        db_path: []const u8,
        storage_engine: ?*storage_mod.StorageEngine = null,

        pub fn init(allocator: Allocator, db_path: []const u8) !*StorageLayer {
            const storage = try allocator.create(StorageLayer);
            storage.* = .{
                .allocator = allocator,
                .db_path = db_path,
                .storage_engine = null,
            };
            return storage;
        }

        pub fn deinit(self: *StorageLayer) void {
            self.allocator.destroy(self);
        }

        /// Execute a SQL statement (placeholder)
        pub fn exec(self: *StorageLayer, sql: []const u8) !void {
            if (self.storage_engine) |engine| {
                // Parse the checkpoint mode from the SQL
                const mode = if (std.mem.indexOf(u8, sql, "PASSIVE") != null)
                    storage_mod.CheckpointMode.passive
                else if (std.mem.indexOf(u8, sql, "FULL") != null)
                    storage_mod.CheckpointMode.full
                else if (std.mem.indexOf(u8, sql, "RESTART") != null)
                    storage_mod.CheckpointMode.restart
                else if (std.mem.indexOf(u8, sql, "TRUNCATE") != null)
                    storage_mod.CheckpointMode.truncate
                else
                    storage_mod.CheckpointMode.passive;

                // Execute checkpoint through storage engine
                _ = try engine.executeCheckpoint(mode);
            }
            // If storage engine not set, this is a no-op (for tests)
        }

        /// Query WAL file size (placeholder)
        pub fn queryWalSize(self: *StorageLayer) !usize {
            if (self.storage_engine) |engine| {
                return try engine.getWalSize();
            }
            // Fallback for tests
            return 0;
        }
    };

    /// Initialize a new CheckpointManager
    pub fn init(allocator: Allocator, storage: *StorageLayer, config: Config) !*CheckpointManager {
        const manager = try allocator.create(CheckpointManager);
        const now = std.time.timestamp();

        manager.* = .{
            .allocator = allocator,
            .storage = storage,
            .config = config,
            .last_checkpoint = std.atomic.Value(i64).init(now),
            .wal_size = std.atomic.Value(usize).init(0),
            .checkpoint_count = std.atomic.Value(u64).init(0),
            .failed_checkpoint_count = std.atomic.Value(u64).init(0),
            .last_checkpoint_duration_ms = std.atomic.Value(u64).init(0),
            .background_thread = null,
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .shutdown_cond = .{},
            .shutdown_mutex = .{},
        };

        // Query initial WAL size
        const initial_wal_size = try storage.queryWalSize();
        manager.wal_size.store(initial_wal_size, .release);

        return manager;
    }

    /// Clean up resources
    pub fn deinit(self: *CheckpointManager) void {
        // If background thread is running, stop it and join
        if (self.background_thread) |thread| {
            self.stop();
            thread.join();
            self.background_thread = null;
        }
        self.allocator.destroy(self);
    }

    /// Get current metrics for monitoring
    pub fn getMetrics(self: *CheckpointManager) CheckpointMetrics {
        return .{
            .last_checkpoint_time = self.last_checkpoint.load(.acquire),
            .last_checkpoint_duration_ms = self.last_checkpoint_duration_ms.load(.acquire),
            .wal_size_bytes = self.wal_size.load(.acquire),
            .checkpoint_count = self.checkpoint_count.load(.acquire),
            .failed_checkpoint_count = self.failed_checkpoint_count.load(.acquire),
        };
    }

    /// Determine if a checkpoint should be triggered based on thresholds
    ///
    /// PRECONDITION: CheckpointManager is initialized
    /// POSTCONDITION: Returns true if checkpoint needed, false otherwise
    ///
    /// Checks two conditions:
    /// 1. WAL size exceeds configured threshold
    /// 2. Time since last checkpoint exceeds configured threshold
    ///
    /// Returns true if either condition is met.
    pub fn shouldCheckpoint(self: *CheckpointManager) bool {
        const now = std.time.timestamp();
        const last_checkpoint = self.last_checkpoint.load(.acquire);
        const current_wal_size = self.wal_size.load(.acquire);

        // Check WAL size threshold
        const size_exceeded = current_wal_size >= self.config.wal_size_threshold;

        // Check time threshold
        const time_elapsed = @as(u64, @intCast(now - last_checkpoint));
        const time_exceeded = time_elapsed >= self.config.time_threshold_sec;

        // Checkpoint if either threshold exceeded
        return size_exceeded or time_exceeded;
    }

    /// Perform a checkpoint operation
    ///
    /// PRECONDITION: Storage layer is initialized and database is in WAL mode
    /// POSTCONDITION: WAL checkpointed or error returned, metrics updated
    ///
    /// Executes a SQLite checkpoint using the specified mode. On success, updates
    /// metrics including checkpoint count, timestamp, and WAL size. On failure,
    /// increments failed checkpoint count.
    ///
    /// Returns CheckpointResult with timing and size information.
    pub fn performCheckpoint(self: *CheckpointManager, mode: CheckpointMode) !CheckpointResult {
        const start_time = std.time.milliTimestamp();
        const wal_size_before = self.wal_size.load(.acquire);

        // Build PRAGMA command based on mode
        const pragma = mode.toPragma();

        // Execute checkpoint
        self.storage.exec(pragma) catch |err| {
            // Increment failure counter
            _ = self.failed_checkpoint_count.fetchAdd(1, .acq_rel);

            // Log error
            std.log.err("Checkpoint failed with mode {s}: {}", .{ @tagName(mode), err });

            return CheckpointResult{
                .mode = mode,
                .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
                .wal_size_before = wal_size_before,
                .wal_size_after = wal_size_before,
                .success = false,
            };
        };

        // Update metrics
        const end_time = std.time.milliTimestamp();
        const duration = @as(u64, @intCast(end_time - start_time));

        self.last_checkpoint.store(std.time.timestamp(), .release);
        _ = self.checkpoint_count.fetchAdd(1, .acq_rel);
        self.last_checkpoint_duration_ms.store(duration, .release);

        // Query new WAL size
        const new_wal_size = try self.storage.queryWalSize();
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
    ///
    /// PRECONDITION: CheckpointManager is initialized
    /// POSTCONDITION: Checkpoint attempted with escalation if needed
    ///
    /// Attempts checkpoint with the configured mode. If passive mode fails to
    /// reduce WAL size, automatically escalates to full mode. Logs all failures
    /// and updates metrics accordingly.
    ///
    /// Returns CheckpointResult with final outcome.
    pub fn performCheckpointWithEscalation(self: *CheckpointManager) !CheckpointResult {
        // Try with configured mode first
        var result = try self.performCheckpoint(self.config.checkpoint_mode);

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
                result = try self.performCheckpoint(.full);
            }
        }

        return result;
    }

    /// Handle checkpoint failure with retry logic
    ///
    /// PRECONDITION: CheckpointManager is initialized
    /// POSTCONDITION: Checkpoint attempted with retries
    ///
    /// Attempts checkpoint with exponential backoff on failure. Logs all failures
    /// and provides detailed error information for debugging.
    pub fn performCheckpointWithRetry(self: *CheckpointManager, mode: CheckpointMode, max_retries: u32) !CheckpointResult {
        var retries: u32 = 0;
        var backoff_ms: u64 = 100; // Start with 100ms

        while (retries < max_retries) : (retries += 1) {
            const result = try self.performCheckpoint(mode);

            if (result.success) {
                if (retries > 0) {
                    std.log.info("Checkpoint succeeded after {} retries", .{retries});
                }
                return result;
            }

            // Exponential backoff
            if (retries < max_retries - 1) {
                std.log.warn("Checkpoint failed, retrying in {}ms (attempt {}/{})", .{ backoff_ms, retries + 1, max_retries });
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                backoff_ms *= 2; // Double the backoff time
            }
        }

        std.log.err("Checkpoint failed after {} retries", .{max_retries});
        return error.CheckpointFailed;
    }

    /// Background checkpoint loop for automatic checkpointing
    ///
    /// PRECONDITION: CheckpointManager is initialized
    /// POSTCONDITION: Runs indefinitely, checking and performing checkpoints
    ///
    /// This function should be run in a separate thread. It periodically checks
    /// if a checkpoint is needed based on configured thresholds and performs
    /// checkpoints automatically. Uses escalation logic to ensure WAL size
    /// stays under control.
    ///
    /// The loop runs every check_interval_sec seconds (default: 10 seconds).
    pub fn backgroundCheckpointLoop(self: *CheckpointManager) !void {
        std.log.info("Starting background checkpoint loop (interval: {}s)", .{self.config.check_interval_sec});

        self.shutdown_mutex.lock();
        defer self.shutdown_mutex.unlock();
        while (!self.shutdown_requested.load(.acquire)) {
            // Wait for configured interval or shutdown signal
            self.shutdown_cond.timedWait(&self.shutdown_mutex, self.config.check_interval_sec * std.time.ns_per_s) catch {}; // zwanzig-disable-line: swallowed-error empty-catch-engine

            if (self.shutdown_requested.load(.acquire)) break;

            // Check if checkpoint is needed
            if (self.shouldCheckpoint()) {
                const wal_size = self.wal_size.load(.acquire);
                const last_checkpoint = self.last_checkpoint.load(.acquire);
                const time_since_last = std.time.timestamp() - last_checkpoint;

                std.log.info("Checkpoint triggered: wal_size={} bytes, time_since_last={}s", .{ wal_size, time_since_last });

                // Unlock for actual work
                self.shutdown_mutex.unlock();
                const result = self.performCheckpointWithEscalation() catch |err| {
                    std.log.err("Background checkpoint failed: {}", .{err});
                    self.shutdown_mutex.lock();
                    continue;
                };
                self.shutdown_mutex.lock();

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
    pub fn stop(self: *CheckpointManager) void {
        self.shutdown_requested.store(true, .release);
        self.shutdown_mutex.lock();
        self.shutdown_cond.signal();
        self.shutdown_mutex.unlock();
    }

    /// Start background checkpoint loop in a separate thread
    ///
    /// PRECONDITION: CheckpointManager is initialized
    /// POSTCONDITION: Background thread started
    ///
    /// Spawns a new thread that runs the background checkpoint loop.
    /// Returns the thread handle for later joining if needed.
    pub fn startBackgroundLoop(self: *CheckpointManager) !void {
        const thread = try std.Thread.spawn(.{}, backgroundCheckpointLoop, .{self});
        self.background_thread = thread;
    }
};
