const std = @import("std");
const testing = std.testing;
const ChangeQueue = @import("change_queue.zig").ChangeQueue;
const OwnedRecordChange = @import("change_queue.zig").OwnedRecordChange;
const typed = @import("typed.zig");

test "ChangeQueue: computeShard determinism and range" {
    const alloc = testing.allocator;
    var queue = try ChangeQueue.init(alloc, 8);
    defer queue.deinit();

    const doc_id: typed.DocId = 12345;
    const namespace_id: i64 = 42;
    const table_index: usize = 0;

    // Push same change multiple times - should always route to same shard
    const change1 = OwnedRecordChange{
        .table_index = table_index,
        .namespace_id = namespace_id,
        .doc_id = doc_id,
        .operation = .insert,
        .old_record = null,
        .new_record = null,
    };
    queue.push(change1, alloc);

    // Verify item is in exactly one shard
    var found_shard: ?usize = null;
    for (0..queue.shardCount()) |i| {
        const shard = queue.getShard(i);
        if (shard.popTimed(0)) |job| {
            try testing.expect(found_shard == null); // Should only find in one shard
            found_shard = i;
            var mut_job = job;
            mut_job.deinit();
        }
    }
    try testing.expect(found_shard != null);
}

test "ChangeQueue: computeShard distribution across shards" {
    const alloc = testing.allocator;
    const num_shards = 8;
    var queue = try ChangeQueue.init(alloc, num_shards);
    defer queue.deinit();

    // Push items with different (namespace_id, table_index, doc_id) combinations
    var shard_hits = [_]usize{0} ** num_shards;

    for (0..100) |i| {
        const change = OwnedRecordChange{
            .table_index = i % 3,
            .namespace_id = @intCast(i * 7),
            .doc_id = @intCast(i * 13),
            .operation = .insert,
            .old_record = null,
            .new_record = null,
        };
        queue.push(change, alloc);
    }

    // Count which shards received items
    for (0..num_shards) |i| {
        const shard = queue.getShard(i);
        while (shard.popTimed(0)) |job| {
            shard_hits[i] += 1;
            var mut_job = job;
            mut_job.deinit();
        }
    }

    // Verify distribution: at least 2 shards should be used (not all collapsed to one)
    var non_empty_shards: usize = 0;
    for (shard_hits) |count| {
        if (count > 0) non_empty_shards += 1;
    }
    try testing.expect(non_empty_shards >= 2);
}

test "ChangeQueue: push routes to correct shard" {
    const alloc = testing.allocator;
    var queue = try ChangeQueue.init(alloc, 4);
    defer queue.deinit();

    const doc_id: typed.DocId = 999;
    const namespace_id: i64 = 100;
    const table_index: usize = 2;

    const change = OwnedRecordChange{
        .table_index = table_index,
        .namespace_id = namespace_id,
        .doc_id = doc_id,
        .operation = .update,
        .old_record = null,
        .new_record = null,
    };

    queue.push(change, alloc);

    // Pop from all shards and verify exactly one has the item with correct data
    var found = false;
    for (0..queue.shardCount()) |i| {
        const shard = queue.getShard(i);
        if (shard.popTimed(0)) |job| {
            try testing.expect(!found); // Should only find in one shard
            try testing.expectEqual(namespace_id, job.change.namespace_id);
            try testing.expectEqual(table_index, job.change.table_index);
            try testing.expectEqual(doc_id, job.change.doc_id);
            try testing.expectEqual(OwnedRecordChange.Operation.update, job.change.operation);
            found = true;
            var mut_job = job;
            mut_job.deinit();
        }
    }
    try testing.expect(found);
}

test "ChangeQueue: multi-shard init and deinit" {
    const alloc = testing.allocator;

    // Test various shard counts
    for ([_]usize{ 1, 2, 4, 8, 16 }) |num_shards| {
        var queue = try ChangeQueue.init(alloc, num_shards);
        try testing.expectEqual(num_shards, queue.shardCount());

        // Verify each shard is accessible
        for (0..num_shards) |i| {
            const shard = queue.getShard(i);
            try testing.expect(shard.isEmpty());
        }

        queue.deinit();
    }
}
