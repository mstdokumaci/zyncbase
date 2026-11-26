const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const qth = @import("../query/test_helpers.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const storage_mod = @import("../storage_engine.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const SendQueueType = @import("../connection/send_queue.zig").SendQueue;
const MessageType = @import("../wire/message_type.zig").MessageType;
const ChangeQueue = @import("change_queue.zig").ChangeQueue;
const SubscriptionEngine = @import("engine.zig").SubscriptionEngine;
const SubscriptionWorkerPool = @import("worker_pool.zig").SubscriptionWorkerPool;

const testing = std.testing;

const conn_id: u64 = 9;
const namespace_id: i64 = 1;
const upserts_per_round = 64;
const batch_entries = 2;
/// Round r uses request ids r*100+1 ..= r*100+64 for upserts and r*100+99 for
/// its explicit batch. Every write stores its request id in `val` and writes
/// distinct documents, so each delta names the write it came from.
const batch_slot = 99;

const items_table = schema_helpers.makeTable("items", &.{schema_helpers.makeField("val", .integer)});

const Fixture = struct {
    ctx: sth.EngineTestContext,
    subscriptions: SubscriptionEngine,
    change_queue: *ChangeQueue,
    send_queue: *SendQueueType,
    table_index: usize,
    val_index: usize,

    /// `self` must not move after init; the queue pointers point into it.
    fn init(self: *Fixture, allocator: std.mem.Allocator, prefix: []const u8) !void {
        try self.ctx.init(allocator, prefix, items_table);
        errdefer self.ctx.deinit();
        self.change_queue = if (self.ctx.test_context.change_queue) |*queue| queue else return error.TestExpectedValue;
        self.send_queue = if (self.ctx.test_context.send_queue) |*queue| queue else return error.TestExpectedValue;
        self.subscriptions = SubscriptionEngine.init(testing.io, allocator);
        const table = try self.ctx.tableMetadata("items");
        self.table_index = table.index;
        self.val_index = table.fieldIndex("val") orelse return error.TestExpectedValue;
        // Before any write is enqueued; the enqueue lock publishes it to the writer.
        self.ctx.engine.write_worker.subscription_count = &self.subscriptions.active_count;
    }

    fn deinit(self: *Fixture) void {
        self.ctx.deinit();
        self.subscriptions.deinit();
    }

    fn valColumns(self: *const Fixture, request_id: u64) [1]sth.ColumnValue {
        return .{.{ .index = self.val_index, .value = .{ .scalar = .{ .integer = @intCast(request_id) } } }};
    }

    fn enqueueUpsert(self: *Fixture, request_id: u64) !void {
        const columns = self.valColumns(request_id);
        try sth.enqueueUpsert(&self.ctx.engine, self.table_index, @intCast(request_id), namespace_id, typed_doc_id.zero, &columns, null, .{ .conn_id = conn_id, .loop_id = 0, .msg_id = request_id });
    }

    fn enqueueBatch(self: *Fixture, request_id: u64) !void {
        const allocator = self.ctx.engine.allocator;
        const entries = try allocator.alloc(storage_mod.WriteOp, batch_entries);
        var built: usize = 0;
        errdefer {
            for (entries[0..built]) |entry| entry.deinit(allocator);
            allocator.free(entries);
        }
        for (entries, 0..) |*entry, i| {
            const columns = try allocator.dupe(sth.ColumnValue, &self.valColumns(request_id));
            entry.* = .{ .upsert = .{
                .table_index = self.table_index,
                .id = @intCast(request_id * 1000 + i),
                .namespace_id = namespace_id,
                .owner_doc_id = typed_doc_id.zero,
                .columns = columns,
                .timestamp = std.Io.Clock.real.now(testing.io).toMicroseconds(),
            } };
            built += 1;
        }
        try self.ctx.engine.enqueueWriteOp(.{ .batch = .{
            .entries = entries,
            .ack = .{ .conn_id = conn_id, .loop_id = 0, .msg_id = request_id },
        } });
    }

    fn writeRound(self: *Fixture, round: u64) !void {
        for (1..upserts_per_round + 1) |i| try self.enqueueUpsert(round * 100 + i);
        try self.enqueueBatch(round * 100 + batch_slot);
        try self.ctx.engine.flushPendingWrites();
    }
};

fn integer(payload: msgpack.Payload) !u64 {
    return switch (payload) {
        .uint => |v| v,
        .int => |v| @intCast(v),
        else => error.TestUnexpectedResult,
    };
}

fn countDelta(
    allocator: std.mem.Allocator,
    data: []const u8,
    fixture: *const Fixture,
    deltas: *std.AutoHashMapUnmanaged(u64, u32),
) !void {
    var reader: std.Io.Reader = .fixed(data);
    const message = try msgpack.decode(allocator, &reader);
    defer message.free(allocator);
    const delta = switch (message) {
        .arr => |items| items,
        else => return error.TestUnexpectedResult,
    };
    const record_id = try integer(delta[4].arr[fixture.val_index]);
    const gop = try deltas.getOrPut(allocator, record_id);
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

/// Pops the queue and checks that every write's deltas precede its outcome.
/// Returns the number of outcomes seen.
fn expectDeltasBeforeOutcomes(allocator: std.mem.Allocator, fixture: *Fixture, subscribed: bool) !usize {
    var deltas = std.AutoHashMapUnmanaged(u64, u32).empty;
    defer deltas.deinit(allocator);
    var outcomes: usize = 0;
    while (fixture.send_queue.popFrom(0)) |entry| {
        defer entry.deinit();
        if (entry.items) |items| {
            for (items) |delivery| {
                try testing.expectEqual(conn_id, delivery.conn_id);
                try countDelta(allocator, delivery.data, fixture, &deltas);
            }
            continue;
        }
        try testing.expectEqual(conn_id, entry.conn_id);
        var reader: std.Io.Reader = .fixed(entry.data);
        const message = try msgpack.decode(allocator, &reader);
        defer message.free(allocator);
        switch (message) {
            // [StoreDelta, subId, op, table, record]
            .arr => {
                try countDelta(allocator, entry.data, fixture, &deltas);
            },
            .map => {
                const message_type = (try message.mapGet("type")) orelse return error.TestUnexpectedResult;
                try testing.expectEqual(@intFromEnum(MessageType.write_committed), try integer(message_type));
                const request_id = try integer((try message.mapGet("id")) orelse return error.TestUnexpectedResult);
                const expected: u32 = if (!subscribed) 0 else if (request_id % 100 == batch_slot) batch_entries else 1;
                try testing.expectEqual(expected, deltas.get(request_id) orelse 0);
                outcomes += 1;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    return outcomes;
}

test "outcome ordering: a write's deltas reach its connection before its outcome" {
    const allocator = std.heap.smp_allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "outcome_ordering");
    defer fixture.deinit();

    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    try fixture.subscriptions.subscribe(namespace_id, fixture.table_index, filter, conn_id, 1, 0);

    // Four workers on one shard process a transaction's jobs in parallel, so
    // any of them can drop the last fence reference.
    var pool = try SubscriptionWorkerPool.init(
        allocator,
        4,
        fixture.change_queue,
        &fixture.subscriptions,
        &fixture.ctx.memory_strategy,
        &fixture.ctx.schema,
        fixture.send_queue,
        null,
        null,
    );
    defer pool.deinit();
    defer pool.stop();
    try pool.start();

    const rounds = 100;
    for (0..rounds) |round| try fixture.writeRound(round);
    // Drains every job, so every fence has published.
    pool.stop();

    try testing.expectEqual(@as(usize, rounds * (upserts_per_round + 1)), try expectDeltasBeforeOutcomes(allocator, &fixture, true));
}

test "outcome ordering: without subscribers outcomes do not wait for workers" {
    const allocator = std.heap.smp_allocator;
    var fixture: Fixture = undefined;
    try fixture.init(allocator, "outcome_no_subscribers");
    defer fixture.deinit();

    // No worker pool: a fence would never publish.
    try fixture.writeRound(0);
    try testing.expectEqual(@as(usize, upserts_per_round + 1), try expectDeltasBeforeOutcomes(allocator, &fixture, false));
}
