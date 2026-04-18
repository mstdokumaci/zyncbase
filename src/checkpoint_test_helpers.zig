const std = @import("std");
const CheckpointManager = @import("checkpoint_manager.zig").CheckpointManager;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const SchemaManager = @import("schema_manager.zig").SchemaManager;
const schema_helpers = @import("schema_test_helpers.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    memory_strategy: MemoryStrategy,
    schema_manager: SchemaManager,
    test_context: schema_helpers.TestContext,
    storage_engine: StorageEngine,
    manager: CheckpointManager,

    pub fn init(self: *Context, allocator: std.mem.Allocator, config: CheckpointManager.Config) !void {
        self.allocator = allocator;

        self.schema_manager = try schema_helpers.createTestSchemaManager(allocator, &.{
            .{
                .name = "items",
                .fields = &.{"name"},
            },
        });
        errdefer self.schema_manager.deinit();

        try self.memory_strategy.init(allocator);
        errdefer self.memory_strategy.deinit();

        self.test_context = try schema_helpers.TestContext.initInMemory(allocator);
        errdefer self.test_context.deinit();

        try schema_helpers.setupTestEngine(
            &self.storage_engine,
            allocator,
            &self.memory_strategy,
            &self.test_context,
            &self.schema_manager,
            .{ .in_memory = true },
        );
        errdefer self.storage_engine.deinit();

        try self.manager.init(allocator, &self.storage_engine, config);
        errdefer self.manager.deinit();
    }

    pub fn deinit(self: *Context) void {
        self.manager.deinit();
        self.storage_engine.deinit();
        self.test_context.deinit();
        self.schema_manager.deinit();
        self.memory_strategy.deinit();
    }
};
