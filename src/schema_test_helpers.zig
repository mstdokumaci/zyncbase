const std = @import("std");
const schema_parser = @import("schema_parser.zig");
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const ddl_generator = @import("ddl_generator.zig");

pub fn createTestSchema(allocator: std.mem.Allocator, tables_def: []const struct { name: []const u8, fields: []const []const u8 }) !*schema_parser.Schema {
    var tables = try allocator.alloc(schema_parser.Table, tables_def.len);
    errdefer allocator.free(tables);

    for (tables_def, 0..) |td, i| {
        var fields = try allocator.alloc(schema_parser.Field, td.fields.len);
        errdefer allocator.free(fields);
        for (td.fields, 0..) |fn_name, j| {
            fields[j] = .{
                .name = try allocator.dupe(u8, fn_name),
                .sql_type = .text,
                .required = false,
                .indexed = false,
                .references = null,
                .on_delete = null,
            };
        }
        tables[i] = .{
            .name = try allocator.dupe(u8, td.name),
            .fields = fields,
        };
    }

    const schema = try allocator.create(schema_parser.Schema);
    errdefer allocator.destroy(schema);
    schema.* = .{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };
    return schema;
}

pub fn freeTestSchema(allocator: std.mem.Allocator, schema: *schema_parser.Schema) void {
    schema_parser.freeSchema(allocator, schema.*);
    allocator.destroy(schema);
}

pub fn writeSchemaToFile(allocator: std.mem.Allocator, schema: *const schema_parser.Schema, path: []const u8) !void {
    var parser = schema_parser.SchemaParser.init(allocator);
    const json_text = try parser.print(schema.*);
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
        std.fs.cwd().deleteTree(self.test_dir) catch {};
        self.allocator.free(self.test_dir);
    }
};

pub fn setupTestEngine(allocator: std.mem.Allocator, context: *const TestContext, schema: *const schema_parser.Schema) !*StorageEngine {
    const engine = try StorageEngine.init(allocator, context.test_dir, schema);
    errdefer engine.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    for (schema.tables) |table| {
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try engine.execDDL(ddl_z);
    }

    return engine;
}

pub fn cleanupTestEngine(engine: *StorageEngine, context: *TestContext) void {
    engine.deinit();
    context.deinit();
}
