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
};
