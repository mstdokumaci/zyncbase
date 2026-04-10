const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const ddl_generator = @import("ddl_generator.zig");
const schema_parser = @import("schema_parser.zig");

pub const TableDef = struct {
    name: []const u8,
    fields: []const []const u8,
    types: ?[]const schema_manager.FieldType = null,
};

pub fn createTestSchema(allocator: std.mem.Allocator, tables_def: []const TableDef) !schema_manager.Schema {
    var tables = try allocator.alloc(schema_manager.Table, tables_def.len);
    errdefer {
        for (tables) |*t| allocator.free(t.name);
        allocator.free(tables);
    }

    for (tables_def, 0..) |td, i| {
        var fields = try allocator.alloc(schema_manager.Field, td.fields.len);
        errdefer allocator.free(fields);
        for (td.fields, 0..) |fn_name, j| {
            fields[j] = .{
                .name = try allocator.dupe(u8, fn_name),
                .sql_type = if (td.types) |ts| ts[j] else .text,
                .required = false,
                .indexed = false,
                .references = null,
                .on_delete = null,
            };
        }
        tables[i] = .{ .name = try allocator.dupe(u8, td.name), .fields = fields };
    }

    return schema_manager.Schema{ .version = try allocator.dupe(u8, "1.0.0"), .tables = tables };
}

pub fn createTestSchemaManager(allocator: std.mem.Allocator, tables_def: []const TableDef) !SchemaManager {
    const schema = try createTestSchema(allocator, tables_def);
    errdefer schema_manager.freeSchema(allocator, schema);

    const metadata = try schema_manager.SchemaMetadata.init(allocator, &schema);
    errdefer {
        var m = metadata;
        m.deinit();
    }

    return schema_manager.SchemaManager{
        .allocator = allocator,
        .schema = schema,
        .metadata = metadata,
    };
}

pub fn deinitTestSchema(allocator: std.mem.Allocator, schema: schema_manager.Schema) void {
    schema_manager.freeSchema(allocator, schema);
}

pub fn writeSchemaToFile(allocator: std.mem.Allocator, schema: schema_manager.Schema, path: []const u8) !void {
    var parser = schema_parser.SchemaParser.init(allocator);
    const json_text = try parser.print(schema);
    defer allocator.free(json_text);

    // Ensure directory exists
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(json_text);
}

pub const TestContext = struct {
    allocator: std.mem.Allocator,
    test_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8) !TestContext {
        // Generate a unique directory name using timestamp and random bits
        var random_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        const timestamp = std.time.milliTimestamp();
        const dir_name = try std.fmt.allocPrint(allocator, "test-artifacts/{s}-{d}-{x}", .{
            prefix,
            timestamp,
            std.mem.readInt(u64, &random_bytes, .little),
        });
        errdefer allocator.free(dir_name);

        // Ensure the directory itself exists
        std.fs.cwd().makePath(dir_name) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return TestContext{
            .allocator = allocator,
            .test_dir = dir_name,
        };
    }

    pub fn deinit(self: *TestContext) void {
        std.fs.cwd().deleteTree(self.test_dir) catch |err| {
            // Log failure to delete test artifacts directory
            std.log.warn("failed to delete test artifacts directory {s}: {}", .{ self.test_dir, err });
        };
        self.allocator.free(self.test_dir);
    }
};

pub fn setupTestEngine(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const @import("memory_strategy.zig").MemoryStrategy, context: *const TestContext, sm: *const SchemaManager, options: StorageEngine.Options) !void {
    try engine.init(allocator, @constCast(memory_strategy), context.test_dir, sm, .{}, options, null, null);
    errdefer engine.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    for (sm.schema.tables) |table| {
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try engine.execSetupSQL(ddl_z);
    }
    try engine.start();
}

pub fn cleanupTestEngine(engine: *StorageEngine, context: *TestContext) void {
    engine.deinit();
    context.deinit();
}
