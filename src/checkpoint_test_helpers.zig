const std = @import("std");
const CheckpointWorker = @import("checkpoint_worker.zig").CheckpointWorker;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const Schema = @import("schema.zig").Schema;
const schema_helpers = @import("schema_test_helpers.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    memory_strategy: MemoryStrategy,
    schema: Schema,
    test_context: schema_helpers.TestContext,
    storage_engine: StorageEngine,
    manager: CheckpointWorker,

    pub fn init(self: *Context, allocator: std.mem.Allocator, config: CheckpointWorker.Config) !void {
        self.allocator = allocator;

        self.schema = try schema_helpers.createTestSchema(allocator, &.{
            .{
                .name = "items",
                .fields = &.{"name"},
            },
        });
        errdefer self.schema.deinit();

        try self.memory_strategy.init(allocator);
        errdefer _ = self.memory_strategy.deinit();

        self.test_context = try schema_helpers.TestContext.initInMemory(allocator);
        errdefer self.test_context.deinit();

        try schema_helpers.setupTestEngine(
            &self.storage_engine,
            allocator,
            &self.memory_strategy,
            &self.test_context,
            &self.schema,
            .{ .in_memory = true, .reader_pool_size = 1 },
        );
        errdefer self.storage_engine.deinit();

        try self.manager.init(allocator, &self.storage_engine, config);
        errdefer self.manager.deinit();
    }

    pub fn deinit(self: *Context) void {
        self.manager.deinit();
        self.storage_engine.deinit();
        self.test_context.deinit();
        self.schema.deinit();
        std.testing.expect(self.memory_strategy.deinit() == .ok) catch @panic("leak");
    }
};
