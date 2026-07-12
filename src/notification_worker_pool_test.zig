const std = @import("std");
const testing = std.testing;
const NotificationWorkerPool = @import("notification_worker_pool.zig").NotificationWorkerPool;
const ChangeQueue = @import("change_queue.zig").ChangeQueue;
const OwnedRecordChange = @import("change_queue.zig").OwnedRecordChange;
const SubscriptionEngine = @import("subscription_engine.zig").SubscriptionEngine;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const send_queue_type = @import("send_queue.zig").send_queue;
const typed = @import("typed.zig");
const sth = @import("storage_engine_test_helpers.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const qth = @import("query_parser_test_helpers.zig");
const tth = @import("typed_test_helpers.zig");
const query_ast = @import("query_ast.zig");

const TestContext = struct {
    allocator: std.mem.Allocator,
    memory_strategy: MemoryStrategy,
    change_queue: ChangeQueue,
    subscription_engine: SubscriptionEngine,
    send_queue: send_queue_type,
    schema: sth.Schema,
    notifier_called: std.atomic.Value(u32),

    fn init(self: *TestContext, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        // SAFETY: Immediately initialized by init() call below.
        self.memory_strategy = undefined;
        try self.memory_strategy.init(allocator);
        self.change_queue = try ChangeQueue.init(allocator, 1);
        self.subscription_engine = SubscriptionEngine.init(allocator);
        self.send_queue = try send_queue_type.init(allocator);
        self.schema = try sth.createSchema(allocator, &.{
            schema_helpers.makeTable("items", &.{
                schema_helpers.makeField("status", .text),
            }),
        });
        self.notifier_called = std.atomic.Value(u32).init(0);
    }

    fn deinit(self: *TestContext) void {
        self.schema.deinit();
        self.send_queue.deinit();
        self.subscription_engine.deinit();
        self.change_queue.deinit();
        std.debug.assert(self.memory_strategy.deinit() == .ok);
    }

    fn notifierFn(ctx: ?*anyopaque) void {
        const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
        _ = counter.fetchAdd(1, .monotonic);
    }
};

fn makeRecordWithId(allocator: std.mem.Allocator, id: typed.DocId, status: []const u8) !typed.Record {
    var record = try tth.recordFromValues(allocator, &.{tth.valText(status)});
    // Set the id field at index 0
    record.values[0].deinit(allocator);
    record.values[0] = .{ .scalar = .{ .doc_id = id } };
    return record;
}

test "NotificationWorkerPool: matching change is processed and pushed to send_queue" {
    const allocator = testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.init(allocator);
    defer ctx.deinit();

    // Subscribe to items where status = "active"
    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    const table = ctx.schema.table("items") orelse return error.TestExpectedValue;
    const sub_id: u64 = 100;
    const conn_id: u64 = 1;
    _ = try ctx.subscription_engine.subscribe(conn_id, table.index, filter, conn_id, sub_id);

    var pool = try NotificationWorkerPool.init(
        allocator,
        1,
        &ctx.change_queue,
        &ctx.subscription_engine,
        &ctx.memory_strategy,
        &ctx.schema,
        &ctx.send_queue,
        TestContext.notifierFn,
        &ctx.notifier_called,
    );
    defer pool.deinit();
    defer pool.stop();

    try pool.start();

    // Push a matching change (status = "active")
    const doc_id: typed.DocId = 42;
    const new_record = try makeRecordWithId(allocator, doc_id, "active");

    const change = OwnedRecordChange{
        .table_index = table.index,
        .namespace_id = 1,
        .doc_id = doc_id,
        .operation = .insert,
        .old_record = null,
        .new_record = new_record,
    };
    ctx.change_queue.push(change, allocator);

    // Wait for processing
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue received the delta
    try testing.expect(ctx.send_queue.hasItems());

    // Verify notifier was called
    try testing.expect(ctx.notifier_called.load(.monotonic) > 0);

    // Drain and free the send_queue entry
    if (ctx.send_queue.pop()) |entry| {
        ctx.memory_strategy.generalAllocator().free(entry.data);
    }
}

test "NotificationWorkerPool: non-matching change does not push to send_queue" {
    const allocator = testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.init(allocator);
    defer ctx.deinit();

    // Subscribe to items where status = "active"
    var filter = try qth.makeFilterWithConditions(allocator, &[_]query_ast.Condition{
        .{ .field_index = 3, .op = .eq, .value = tth.valText("active"), .field_type = .text, .items_type = null },
    });
    defer filter.deinit(allocator);

    const table = ctx.schema.table("items") orelse return error.TestExpectedValue;
    _ = try ctx.subscription_engine.subscribe(1, table.index, filter, 1, 100);

    var pool = try NotificationWorkerPool.init(
        allocator,
        1,
        &ctx.change_queue,
        &ctx.subscription_engine,
        &ctx.memory_strategy,
        &ctx.schema,
        &ctx.send_queue,
        TestContext.notifierFn,
        &ctx.notifier_called,
    );
    defer pool.deinit();
    defer pool.stop();

    try pool.start();

    // Push a non-matching change (status = "inactive")
    const doc_id: typed.DocId = 43;
    const new_record = try makeRecordWithId(allocator, doc_id, "inactive");

    const change = OwnedRecordChange{
        .table_index = table.index,
        .namespace_id = 1,
        .doc_id = doc_id,
        .operation = .insert,
        .old_record = null,
        .new_record = new_record,
    };
    ctx.change_queue.push(change, allocator);

    // Wait for processing
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify send_queue is empty (no match)
    try testing.expect(!ctx.send_queue.hasItems());

    // Verify notifier was NOT called
    try testing.expectEqual(@as(u32, 0), ctx.notifier_called.load(.monotonic));
}
