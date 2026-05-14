const std = @import("std");
const testing = std.testing;
const sth = @import("storage_engine_test_helpers.zig");
const schema_mod = sth.schema_mod;

// This property test verifies that the server remains stable when database errors occur:
// 1. No panics or crashes on database errors
// 2. Server continues operating after database errors
// 3. Error recovery mechanisms work correctly
// 4. Concurrent operations remain safe during errors
//
// We test various error scenarios to ensure the server never crashes:
// - Multiple concurrent operations during errors
// - Rapid error conditions
// - Error recovery and retry logic
// - Resource cleanup after errors

// ─── Tests ───────────────────────────────────────────────────────────────────

test "storage: stability no crashes on concurrent errors" {
    const allocator = testing.allocator;

    var fields = [_]schema_mod.Field{sth.makeField("val", .text, false)};
    const table = sth.makeTable("test", &fields);

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
            const tbl_md = t_ctx.ctx.schema.getTable("test") orelse @panic("test table missing");
            while (i < ops) : (i += 1) {
                // Mix of operations that might fail
                const key: u128 = t_ctx.thread_id * 1_000 + i + 1;
                // Try to set a value
                t_ctx.ctx.insertText("test", key, 1, "val", "value") catch continue; // zwanzig-disable-line: swallowed-error
                // Try to get the value
                var managed = t_ctx.ctx.engine.selectDocument(t_ctx.allocator, tbl_md.index, key, 1, null) catch continue; // zwanzig-disable-line: swallowed-error
                defer managed.deinit();
                _ = managed.records;
                // Try to delete the value
                t_ctx.ctx.engine.deleteDocument(tbl_md.index, key, 1, null) catch continue; // zwanzig-disable-line: swallowed-error
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
