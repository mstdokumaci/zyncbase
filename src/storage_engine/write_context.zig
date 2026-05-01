const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite");
const schema = @import("../schema.zig");
const storage_values = @import("values.zig");
const ChangeBuffer = @import("../change_buffer.zig").ChangeBuffer;
const StatementCache = @import("sql.zig").StatementCache;
const WriteQueue = @import("write_queue.zig").WriteQueue;
const PerformanceConfig = @import("../config_loader.zig").Config.PerformanceConfig;

pub const WriteContext = struct {
    allocator: Allocator,
    conn: sqlite.Db,
    stmt_cache: StatementCache,
    transaction_active: std.atomic.Value(bool),
    version: std.atomic.Value(u64),
    work_cond: std.Thread.Condition,
    mutex: std.Thread.Mutex,
    flush_cond: std.Thread.Condition,
    pending_count: std.atomic.Value(usize),
    change_buffer: ChangeBuffer,
    notifier_ptr: ?*const fn (ctx: ?*anyopaque) void,
    notifier_ctx: ?*anyopaque,
    metadata_cache: *storage_values.typed_cache_type,
    schema: *const schema.Schema,
    shutdown_requested: std.atomic.Value(bool),
    is_ready: std.atomic.Value(bool),
    queue: WriteQueue,
    performance_config: PerformanceConfig,
    db_path: [:0]const u8,
    in_memory: bool,

    pub fn beginOp(self: *WriteContext) void {
        _ = self.pending_count.fetchAdd(1, .release);
    }

    pub fn endOp(self: *WriteContext, count: usize) void {
        _ = self.pending_count.fetchSub(count, .release);
    }

    pub fn pendingOpCount(self: *const WriteContext) usize {
        return self.pending_count.load(.acquire);
    }

    pub fn bumpVersion(self: *WriteContext) void {
        _ = self.version.fetchAdd(1, .acq_rel);
    }

    pub fn snapshotVersion(self: *const WriteContext) u64 {
        return self.version.load(.acquire);
    }

    pub fn markTransactionActive(self: *WriteContext) void {
        self.transaction_active.store(true, .release);
    }

    pub fn markTransactionInactive(self: *WriteContext) void {
        self.transaction_active.store(false, .release);
    }

    pub fn isTransactionActive(self: *const WriteContext) bool {
        return self.transaction_active.load(.acquire);
    }

    pub fn notifyChanges(self: *WriteContext) void {
        if (self.notifier_ptr) |n| {
            n(self.notifier_ctx);
        }
    }

    pub fn wakeFlushWaiters(self: *WriteContext) void {
        self.mutex.lock();
        self.flush_cond.broadcast();
        self.mutex.unlock();
    }

    pub fn deinit(self: *WriteContext, gpa: Allocator) void {
        self.stmt_cache.deinit(gpa);
        self.conn.deinit();
        gpa.free(self.db_path);
        self.queue.deinit();
        self.change_buffer.deinit();
    }
};
