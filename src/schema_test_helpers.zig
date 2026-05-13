const std = @import("std");
const schema = @import("schema.zig");
const Schema = schema.Schema;
const StorageEngine = @import("storage_engine.zig").StorageEngine;
const ddl_generator = @import("ddl_generator.zig");
const migration_detector = @import("migration_detector.zig");
const migration_executor = @import("migration_executor.zig");
const MigrationExecutor = migration_executor.MigrationExecutor;
const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;

// ─── Low-level Field and Table builders ──────────────────────────────────────
// These hide name_quoted — tests should never need to know about SQL quoting.

/// Comptime field builder — auto-computes name_quoted at compile time.
/// For runtime names, use makeFieldAlloc.
pub fn makeField(comptime name: []const u8, sql_type: schema.FieldType) schema.Field {
    return .{
        .name = name,
        .name_quoted = "\"" ++ name ++ "\"",
        .declared_type = sql_type,
        .storage_type = sql_type,
        .items_type = if (sql_type == .array) schema.FieldType.text else null,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

/// Comptime indexed field builder.
pub fn makeIndexedField(comptime name: []const u8, sql_type: schema.FieldType) schema.Field {
    var f = makeField(name, sql_type);
    f.indexed = true;
    return f;
}

/// Comptime required field builder.
pub fn makeRequiredField(comptime name: []const u8, sql_type: schema.FieldType) schema.Field {
    var f = makeField(name, sql_type);
    f.required = true;
    return f;
}

/// Comptime table builder — auto-computes name_quoted at compile time.
pub fn makeTable(comptime name: []const u8, fields: []const schema.Field) schema.Table {
    return .{
        .name = name,
        .name_quoted = "\"" ++ name ++ "\"",
        .fields = fields,
        .is_users_table = std.mem.eql(u8, name, "users"),
        .namespaced = !std.mem.eql(u8, name, "users"),
    };
}

pub fn isClientWritableFieldIndex(table: *const schema.Table, index: usize) bool {
    if (!table.canonical_fields) return index < table.fields.len;
    return index >= table.user_field_start and index < table.user_field_end;
}

/// Runtime field builder (for property tests with randomized names).
/// Caller must free: allocator.free(f.name); allocator.free(f.name_quoted);
pub fn makeFieldAlloc(allocator: std.mem.Allocator, name: []const u8, sql_type: schema.FieldType) !schema.Field {
    return .{
        .name = try allocator.dupe(u8, name),
        .name_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{name}),
        .declared_type = sql_type,
        .storage_type = sql_type,
        .items_type = if (sql_type == .array) schema.FieldType.text else null,
        .required = false,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

/// Runtime table builder with auto-computed name_quoted.
/// Caller must free: allocator.free(t.name); allocator.free(t.name_quoted);
pub fn makeTableAlloc(allocator: std.mem.Allocator, name: []const u8, fields: []const schema.Field) !schema.Table {
    return .{
        .name = try allocator.dupe(u8, name),
        .name_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{name}),
        .fields = fields,
        .is_users_table = std.mem.eql(u8, name, "users"),
        .namespaced = !std.mem.eql(u8, name, "users"),
    };
}

pub const TableDef = struct {
    name: []const u8,
    fields: []const []const u8,
    types: ?[]const schema.FieldType = null,
};

fn buildDeclaredTableFromDef(allocator: std.mem.Allocator, td: TableDef) !schema.Table {
    var fields = try allocator.alloc(schema.Field, td.fields.len);
    var field_count: usize = 0;
    errdefer {
        for (fields[0..field_count]) |field| field.deinit(allocator);
        allocator.free(fields);
    }

    for (td.fields, 0..) |fn_name, j| {
        const fname = try allocator.dupe(u8, fn_name);
        errdefer allocator.free(fname);
        const fname_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{fn_name});
        errdefer allocator.free(fname_quoted);
        fields[j] = .{
            .name = fname,
            .name_quoted = fname_quoted,
            .declared_type = if (td.types) |ts| ts[j] else .text,
            .storage_type = if (td.types) |ts| ts[j] else .text,
            .items_type = if (td.types) |ts| if (ts[j] == .array) schema.FieldType.text else null else null,
            .required = false,
            .indexed = false,
            .references = null,
            .on_delete = null,
        };
        field_count += 1;
    }

    const tname = try allocator.dupe(u8, td.name);
    errdefer allocator.free(tname);
    const tname_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{td.name});
    errdefer allocator.free(tname_quoted);

    return .{
        .name = tname,
        .name_quoted = tname_quoted,
        .fields = fields,
        .is_users_table = std.mem.eql(u8, td.name, "users"),
        .namespaced = !std.mem.eql(u8, td.name, "users"),
    };
}

fn buildImplicitUsersTable(allocator: std.mem.Allocator) !schema.Table {
    const fields = try allocator.alloc(schema.Field, 0);
    errdefer allocator.free(fields);
    const name = try allocator.dupe(u8, "users");
    errdefer allocator.free(name);
    const name_quoted = try allocator.dupe(u8, "\"users\"");
    errdefer allocator.free(name_quoted);

    return .{
        .name = name,
        .name_quoted = name_quoted,
        .fields = fields,
        .is_users_table = true,
        .namespaced = false,
    };
}

pub fn createTestSchema(allocator: std.mem.Allocator, tables_def: []const TableDef) !Schema {
    const has_users = blk: {
        for (tables_def) |td| {
            if (std.mem.eql(u8, td.name, "users")) break :blk true;
        }
        break :blk false;
    };

    const declared_len = tables_def.len + @intFromBool(!has_users);
    var declared = try allocator.alloc(schema.Table, declared_len);
    var decl_count: usize = 0;
    defer {
        for (declared[0..decl_count]) |*t| t.deinit(allocator);
        allocator.free(declared);
    }

    if (has_users) {
        for (tables_def) |td| {
            if (std.mem.eql(u8, td.name, "users")) {
                declared[decl_count] = try buildDeclaredTableFromDef(allocator, td);
                decl_count += 1;
                break;
            }
        }
    } else {
        declared[decl_count] = try buildImplicitUsersTable(allocator);
        decl_count += 1;
    }

    for (tables_def) |td| {
        if (std.mem.eql(u8, td.name, "users")) continue;
        declared[decl_count] = try buildDeclaredTableFromDef(allocator, td);
        decl_count += 1;
    }

    // Build runtime tables
    var runtime_tables = try allocator.alloc(schema.Table, decl_count);
    var built_count: usize = 0;
    errdefer {
        for (runtime_tables[0..built_count]) |*t| t.deinit(allocator);
        allocator.free(runtime_tables);
    }

    for (declared, 0..) |dt, idx| {
        runtime_tables[built_count] = try schema.buildRuntimeTable(allocator, dt, idx);
        built_count += 1;
    }

    var result = Schema{
        .allocator = allocator,
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = runtime_tables,
    };
    errdefer result.deinit();

    try schema.buildTableIndex(allocator, &result);
    return result;
}

pub fn createTestSchemaManager(allocator: std.mem.Allocator, tables_def: []const TableDef) !Schema {
    return createTestSchema(allocator, tables_def);
}

pub fn deinitTestSchema(_: std.mem.Allocator, schema_value: *Schema) void {
    schema_value.deinit();
}

pub fn writeSchemaToFile(allocator: std.mem.Allocator, schema_value: *const Schema, path: []const u8) !void {
    const json_text = try schema.format(allocator, schema_value);
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

pub fn setupTestEngine(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const MemoryStrategy, context: *const TestContext, sm: *const Schema, options: StorageEngine.Options) !void {
    try setupTestEngineWithPerformance(engine, allocator, memory_strategy, context, sm, .{}, options);
}

pub fn setupTestEngineWithPerformance(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const MemoryStrategy, context: *const TestContext, sm: *const Schema, performance_config: StorageEngine.PerformanceConfig, options: StorageEngine.Options) !void {
    const effective_options = normalizeTestStorageOptions(options);
    try engine.init(allocator, @constCast(memory_strategy), context.test_dir, sm, performance_config, effective_options, null, null);
    errdefer engine.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    for (sm.tables) |table| {
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try engine.execSetupSQL(ddl_z);
    }

    // Detect and execute migrations
    const setup_conn = try engine.getSetupConn();
    var detector = migration_detector.MigrationDetector.init(allocator, setup_conn, sm);
    const plan = try detector.detectChanges(sm);
    defer detector.deinit(plan);

    if (plan.changes.len > 0) {
        var executor = MigrationExecutor.init(
            allocator,
            setup_conn,
            &gen,
            .{},
        );
        try executor.execute(plan, sm.version);
    }

    try engine.start();
}
