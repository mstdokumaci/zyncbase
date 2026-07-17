const std = @import("std");
const Allocator = std.mem.Allocator;
const ChangeQueue = @import("change_queue.zig").ChangeQueue;
const ChangeJob = @import("change_queue.zig").ChangeJob;
const OwnedRecordChange = @import("change_queue.zig").OwnedRecordChange;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const RecordChange = @import("subscription_engine.zig").RecordChange;
const MatchOp = SubscriptionEngine.MatchOp;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const ArenaHandle = @import("memory_strategy.zig").ArenaHandle;
const send_queue_type = @import("connection/send_queue.zig").send_queue;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const typed = @import("typed/types.zig");
const wire_encode = @import("wire/encode.zig");
const schema_types = @import("schema/types.zig");
const schema_system = @import("schema/system.zig");
const managedThread = @import("threading/managed_thread.zig").managedThread;
const workerPool = @import("threading/worker_pool.zig").workerPool;
const Notifier = @import("threading/notifier.zig").Notifier;

pub const SubscriptionWorkerPool = struct {
    pool: workerPool(SubscriptionWorker),
    change_queue: *ChangeQueue,
    subscription_engine: *SubscriptionEngine,
    memory_strategy: *MemoryStrategy,
    schema: *const schema_types.Schema,
    send_queue: *send_queue_type,
    notifier: Notifier,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        num_workers: usize,
        change_queue: *ChangeQueue,
        subscription_engine: *SubscriptionEngine,
        memory_strategy: *MemoryStrategy,
        schema: *const schema_types.Schema,
        send_queue: *send_queue_type,
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) !SubscriptionWorkerPool {
        var pool = try workerPool(SubscriptionWorker).init(allocator, num_workers);
        errdefer pool.deinit();

        for (pool.workers, 0..) |*w, i| {
            w.* = SubscriptionWorker.init(
                i,
                change_queue,
                subscription_engine,
                memory_strategy,
                schema,
                send_queue,
                notifier_fn,
                notifier_ctx,
            );
        }

        return .{
            .pool = pool,
            .change_queue = change_queue,
            .subscription_engine = subscription_engine,
            .memory_strategy = memory_strategy,
            .schema = schema,
            .send_queue = send_queue,
            .notifier = Notifier.init(notifier_fn, notifier_ctx),
            .allocator = allocator,
        };
    }

    pub fn start(self: *SubscriptionWorkerPool) !void {
        try self.pool.start();
    }

    pub fn stop(self: *SubscriptionWorkerPool) void {
        self.change_queue.shutdown();
        self.pool.stop();
    }

    pub fn deinit(self: *SubscriptionWorkerPool) void {
        self.pool.deinit();
    }
};

pub const SubscriptionWorker = struct {
    thread: managedThread(SubscriptionWorker),
    id: usize,
    change_queue: *ChangeQueue,
    subscription_engine: *SubscriptionEngine,
    memory_strategy: *MemoryStrategy,
    schema: *const schema_types.Schema,
    send_queue: *send_queue_type,
    notifier: Notifier,

    pub fn init(
        id: usize,
        change_queue: *ChangeQueue,
        subscription_engine: *SubscriptionEngine,
        memory_strategy: *MemoryStrategy,
        schema: *const schema_types.Schema,
        send_queue: *send_queue_type,
        notifier_fn: ?*const fn (?*anyopaque) void,
        notifier_ctx: ?*anyopaque,
    ) SubscriptionWorker {
        return .{
            .thread = managedThread(SubscriptionWorker).init(),
            .id = id,
            .change_queue = change_queue,
            .subscription_engine = subscription_engine,
            .memory_strategy = memory_strategy,
            .schema = schema,
            .send_queue = send_queue,
            .notifier = Notifier.init(notifier_fn, notifier_ctx),
        };
    }

    pub fn spawn(self: *SubscriptionWorker) !void {
        try self.thread.spawn(workerLoop, self);
    }

    pub fn stop(self: *SubscriptionWorker) void {
        self.thread.stop();
    }

    fn workerLoop(self: *SubscriptionWorker) void {
        const shard_idx = self.id % self.change_queue.shardCount();
        const shard = self.change_queue.getShard(shard_idx);

        while (!self.thread.isRequested()) {
            const job = shard.pop() orelse break;
            self.processChange(job);
        }

        while (shard.popTimed(0)) |job| {
            self.processChange(job);
        }
    }

    fn processChange(self: *SubscriptionWorker, job: ChangeJob) void {
        var job_mut = job;
        defer job_mut.deinit(job_mut.allocator);

        const change = job_mut.change;
        const table_metadata = self.schema.tableByIndex(change.table_index) orelse {
            std.log.err("SubscriptionWorker skipping delta for unknown table index {d}", .{change.table_index});
            return;
        };

        const record_change = RecordChange{
            .namespace_id = change.namespace_id,
            .table_index = change.table_index,
            .operation = @enumFromInt(@intFromEnum(change.operation)),
            .new_record = change.new_record,
            .old_record = change.old_record,
        };

        const id_val = if (change.new_record orelse change.old_record) |record|
            if (record.values.len > schema_system.id_field_index) record.values[schema_system.id_field_index] else null
        else
            null;

        if (id_val == null) {
            std.log.err("SubscriptionWorker skipping delta for namespace {d}, table {d} because record has no id", .{ change.namespace_id, change.table_index });
            return;
        }

        const id_val_actual = id_val.?;

        const handle = self.memory_strategy.acquireArenaDeferred() catch |err| {
            std.log.err("SubscriptionWorker acquireArenaDeferred failed: {}", .{err});
            return;
        };
        const alloc = handle.allocator();

        const matches = self.subscription_engine.handleRecordChange(record_change, alloc) catch |err| {
            std.log.err("SubscriptionWorker handleRecordChange failed: {}", .{err});
            handle.release();
            return;
        };

        if (matches.len == 0) {
            handle.release();
            return;
        }

        var set_suffix: ?[]const u8 = null;
        var remove_suffix: ?[]const u8 = null;
        if (!encodeDeltaSuffixes(matches, change, table_metadata, id_val_actual, alloc, &set_suffix, &remove_suffix)) {
            handle.release();
            return;
        }

        dispatchDeltasToMatches(self, matches, set_suffix, remove_suffix, handle);
    }

    pub fn dispatchDeltasToMatches(
        self: *SubscriptionWorker,
        matches: []const SubscriptionEngine.Match,
        set_suffix: ?[]const u8,
        remove_suffix: ?[]const u8,
        handle: ArenaHandle,
    ) void {
        const alloc = handle.allocator();
        var out = std.ArrayListUnmanaged(u8).empty;
        var pushed_any = false;

        for (matches) |match| {
            out.clearRetainingCapacity();
            const writer = out.writer(alloc);

            out.appendSlice(alloc, &wire_encode.store_delta_header) catch |err| {
                std.log.err("SubscriptionWorker failed to write header: {}", .{err});
                continue;
            };

            msgpack.encode(Payload.uintToPayload(match.subscription_id), writer) catch |err| {
                std.log.err("SubscriptionWorker failed to encode subId {}: {}", .{ match.subscription_id, err });
                continue;
            };

            const suffix = switch (match.op) {
                MatchOp.set_op => set_suffix orelse continue,
                MatchOp.remove => remove_suffix orelse continue,
            };

            out.appendSlice(alloc, suffix) catch |err| {
                std.log.err("SubscriptionWorker failed to append suffix: {}", .{err});
                continue;
            };

            const owned_msg = alloc.dupe(u8, out.items) catch |err| {
                std.log.err("SubscriptionWorker failed to dupe encoded delta: {}", .{err});
                continue;
            };

            // Reserve a ref for this entry BEFORE pushing so the consumer can never
            // observe the refcount dropping to zero before the entry is visible.
            handle.retain();
            self.send_queue.push(.{ .conn_id = match.connection_id, .data = owned_msg, .arena = handle }) catch |err| {
                std.log.err("SubscriptionWorker failed to push to SendQueue: {}", .{err});
                handle.release();
                continue;
            };
            pushed_any = true;
        }

        if (pushed_any) {
            self.notifier.notify();
        }

        // Drop the producer hold. If the consumer has already drained every entry,
        // this releases the arena now; otherwise the consumer's final pop does.
        handle.release();
    }
};

fn encodeDeltaSuffixes(
    matches: []const SubscriptionEngine.Match,
    change: OwnedRecordChange,
    table_metadata: *const schema_types.Table,
    id_val_actual: typed.Value,
    alloc: std.mem.Allocator,
    set_suffix: *?[]const u8,
    remove_suffix: *?[]const u8,
) bool {
    for (matches) |match| {
        if (set_suffix.* == null and match.op == MatchOp.set_op) {
            const new_record = change.new_record orelse {
                std.log.err("SubscriptionWorker skipping set delta for namespace {d}, table {d} because new_record is missing", .{ change.namespace_id, change.table_index });
                return false;
            };
            set_suffix.* = wire_encode.encodeSetDeltaSuffix(
                alloc,
                table_metadata.index,
                id_val_actual,
                new_record,
                table_metadata,
            ) catch |err| {
                std.log.err("SubscriptionWorker failed to encode set suffix for namespace {d}, table {d}: {}", .{ change.namespace_id, change.table_index, err });
                return false;
            };
        }
        if (remove_suffix.* == null and match.op == MatchOp.remove) {
            remove_suffix.* = wire_encode.encodeDeleteDeltaSuffix(
                alloc,
                table_metadata.index,
                id_val_actual,
            ) catch |err| {
                std.log.err("SubscriptionWorker failed to encode remove suffix for namespace {d}, table {d}: {}", .{ change.namespace_id, change.table_index, err });
                return false;
            };
        }
        if (set_suffix.* != null and remove_suffix.* != null) break;
    }
    return true;
}
