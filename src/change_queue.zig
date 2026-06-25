const std = @import("std");
const Allocator = std.mem.Allocator;
const spmcBlockingQueue = @import("queues/spmc_blocking_queue.zig").spmcBlockingQueue;
const typed = @import("typed.zig");
const Record = typed.Record;

pub const OwnedRecordChange = struct {
    table_index: usize,
    namespace_id: i64,
    doc_id: typed.DocId,
    operation: Operation,
    old_record: ?Record,
    new_record: ?Record,

    pub const Operation = enum { insert, update, delete };

    pub fn deinit(self: *OwnedRecordChange, allocator: Allocator) void {
        if (self.old_record) |r| r.deinit(allocator);
        if (self.new_record) |r| r.deinit(allocator);
    }
};

pub const ChangeJob = struct {
    change: OwnedRecordChange,
    allocator: Allocator,

    pub fn deinit(self: *ChangeJob) void {
        self.change.deinit(self.allocator);
    }
};

const shard_queue_type = spmcBlockingQueue(ChangeJob);

pub const ChangeQueue = struct {
    shards: []shard_queue_type,
    allocator: Allocator,

    pub fn init(allocator: Allocator, num_shards: usize) !ChangeQueue {
        const shards = try allocator.alloc(shard_queue_type, num_shards);
        for (shards) |*s| s.* = shard_queue_type.init(allocator);
        return .{
            .shards = shards,
            .allocator = allocator,
        };
    }

    pub fn push(self: *ChangeQueue, change: OwnedRecordChange, writer_allocator: Allocator) void {
        const shard = computeShard(change.namespace_id, change.table_index, change.doc_id, self.shards.len);
        self.shards[shard].push(.{
            .change = change,
            .allocator = writer_allocator,
        }) catch |err| {
            std.log.err("ChangeQueue push failed (shard {d}): {}", .{ shard, err });
            var mut = change;
            mut.deinit(writer_allocator);
        };
    }

    pub fn getShard(self: *ChangeQueue, index: usize) *shard_queue_type {
        return &self.shards[index];
    }

    pub fn shardCount(self: *const ChangeQueue) usize {
        return self.shards.len;
    }

    pub fn shutdown(self: *ChangeQueue) void {
        for (self.shards) |*s| s.shutdown();
    }

    pub fn deinit(self: *ChangeQueue) void {
        for (self.shards) |*s| s.deinit();
        self.allocator.free(self.shards);
    }
};

fn computeShard(namespace_id: i64, table_index: usize, doc_id: typed.DocId, num_shards: usize) usize {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&namespace_id));
    hasher.update(std.mem.asBytes(&table_index));
    hasher.update(std.mem.asBytes(&doc_id));
    return @intCast(hasher.final() % num_shards);
}
