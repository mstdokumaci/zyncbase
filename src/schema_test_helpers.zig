const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const SchemaManager = schema_manager.SchemaManager;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const ddl_generator = @import("ddl_generator.zig");
const schema_parser = @import("schema_parser.zig");
const migration_detector = @import("migration_detector.zig");
const migration_executor = @import("migration_executor.zig");
const MigrationExecutor = migration_executor.MigrationExecutor;

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
            const fname = try allocator.dupe(u8, fn_name);
            errdefer allocator.free(fname);
            const fname_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{fn_name});
            errdefer allocator.free(fname_quoted);
            fields[j] = .{
                .name = fname,
                .name_quoted = fname_quoted,
                .sql_type = if (td.types) |ts| ts[j] else .text,
                .items_type = if (td.types) |ts| if (ts[j] == .array) schema_manager.FieldType.text else null else null,
                .required = false,
                .indexed = false,
                .references = null,
                .on_delete = null,
            };
        }
        const tname = try allocator.dupe(u8, td.name);
        errdefer allocator.free(tname);
        const tname_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{td.name});
        errdefer allocator.free(tname_quoted);
        tables[i] = .{
            .name = tname,
            .name_quoted = tname_quoted,
            .fields = fields,
        };
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

    pub fn initInMemory(allocator: std.mem.Allocator) !TestContext {
        return .{
            .allocator = allocator,
            .test_dir = try allocator.dupe(u8, ""),
        };
    }

    pub fn deinit(self: *TestContext) void {
        if (self.test_dir.len > 0) {
            std.fs.cwd().deleteTree(self.test_dir) catch |err| {
                // Log failure to delete test artifacts directory
                std.log.warn("failed to delete test artifacts directory {s}: {}", .{ self.test_dir, err });
            };
        }
        self.allocator.free(self.test_dir);
    }
};

pub fn normalizeTestStorageOptions(options: StorageEngine.Options) StorageEngine.Options {
    var effective = options;
    if (effective.in_memory and effective.reader_pool_size == 0) {
        effective.reader_pool_size = 1;
    }
    return effective;
}

pub fn setupTestEngine(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const @import("memory_strategy.zig").MemoryStrategy, context: *const TestContext, sm: *const SchemaManager, options: StorageEngine.Options) !void {
    const effective_options = normalizeTestStorageOptions(options);
    try engine.init(allocator, @constCast(memory_strategy), context.test_dir, sm, .{}, effective_options, null, null);
    errdefer engine.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    for (sm.schema.tables) |table| {
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try engine.execSetupSQL(ddl_z);
    }

    // Detect and execute migrations
    const setup_conn = try engine.getSetupConn();
    var detector = migration_detector.MigrationDetector.init(allocator, setup_conn);
    const plan = try detector.detectChanges(sm.schema);
    defer detector.deinit(plan);

    if (plan.changes.len > 0) {
        var executor = MigrationExecutor.init(
            allocator,
            setup_conn,
            &gen,
            .{},
        );
        try executor.execute(plan, sm.schema);
    }

    try engine.start();
}
