const std = @import("std");

const schema_helpers = @import("schema/test_helpers.zig");
const schema_types = @import("schema/types.zig");
const sth = @import("storage_engine_test_helpers.zig");

const testing = std.testing;

// This property test verifies that the storage engine stays stable under
// concurrent insert/read/delete operations: no panics or crashes occur, and
// the engine keeps operating.
//
// The workers run a mix of insert/read/delete operations concurrently;
// operation errors are tolerated via the existing error handling so that a
// transient failure cannot crash a worker. The test passes if all threads
// complete and a final flush succeeds.

// ─── Tests ───────────────────────────────────────────────────────────────────

test "storage: stability no crashes on concurrent errors" {
    const allocator = std.heap.smp_allocator;

    var fields = [_]schema_types.Field{schema_helpers.makeField("val", .text)};
    const table = schema_helpers.makeTable("test", &fields);

    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "stability-concurrent", table);
    defer ctx.deinit();
    const storage = &ctx.engine;
    // Property: Server should not crash when multiple threads encounter errors simultaneously
    const num_threads = 5;
    var threads: [num_threads]std.Thread = undefined;
    const ThreadContext = struct {
        ctx: *sth.EngineTestContext,
        allocator: std.mem.Allocator,
        thread_id: usize,
    };
    const workerThread = struct {
        fn run(t_ctx: ThreadContext) void {
            var i: usize = 0;
            const ops = 40;
            const tbl_md = t_ctx.ctx.schema.table("test") orelse @panic("test table missing");
            while (i < ops) : (i += 1) {
                // Mix of operations that might fail
                const key: u128 = t_ctx.thread_id * 1_000 + i + 1;
                // Try to set a value
                t_ctx.ctx.insertText("test", key, 1, "val", "value") catch continue; // zwanzig-disable-line: swallowed-error
                // Try to get the value
                const record = sth.readDoc(t_ctx.allocator, &t_ctx.ctx.engine, tbl_md.index, key, 1) catch continue; // zwanzig-disable-line: swallowed-error
                defer if (record) |r| r.deinit(t_ctx.allocator);
                // Try to delete the value
                t_ctx.ctx.engine.enqueueWriteOp(.{ .delete = .{ .table_index = tbl_md.index, .id = key, .namespace_id = 1 } }) catch continue; // zwanzig-disable-line: swallowed-error
            }
        }
    }.run;
    // Spawn threads
    for (&threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThread, .{ThreadContext{
            .ctx = &ctx,
            .allocator = allocator,
            .thread_id = i,
        }});
    }
    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }
    // If we reach here, the server didn't crash - test passes
    try storage.flushPendingWrites();
}
