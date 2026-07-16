const std = @import("std");
const schema_types = @import("types.zig");
const schema_parse = @import("parse.zig");
const schema_index = @import("index.zig");
const schema_mod_format = @import("format.zig");
const Schema = schema_types.Schema;
const StorageEngine = @import("../storage_engine.zig").StorageEngine;
const ddl_generator = @import("../sql/ddl.zig");
const migration_detector = @import("../migration_detector.zig");
const migration_executor = @import("../migration_executor.zig");
const MigrationExecutor = migration_executor.MigrationExecutor;
const MemoryStrategy = @import("../memory_strategy.zig").MemoryStrategy;
const send_queue_mod = @import("../send_queue.zig");
const send_queue_type = send_queue_mod.send_queue;
const ChangeQueue = @import("../change_queue.zig").ChangeQueue;

// ─── Low-level Field and Table builders ──────────────────────────────────────
// These hide name_quoted — tests should never need to know about SQL quoting.

fn initField(
    name: []const u8,
    name_quoted: []const u8,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
    required: bool,
    indexed: bool,
) schema_types.Field {
    return .{
        .name = name,
        .name_quoted = name_quoted,
        .declared_type = field_type,
        .storage_type = field_type,
        .items_type = if (field_type == .array) items_type orelse .text else null,
        .required = required,
        .indexed = indexed,
        .references = null,
        .on_delete = null,
    };
}

/// Comptime field builder — auto-computes name_quoted at compile time.
/// For runtime names, use makeFieldAlloc.
pub fn makeField(comptime name: []const u8, sql_type: schema_types.FieldType) schema_types.Field {
    return initField(name, "\"" ++ name ++ "\"", sql_type, null, false, false);
}

/// Comptime indexed field builder.
pub fn makeIndexedField(comptime name: []const u8, sql_type: schema_types.FieldType) schema_types.Field {
    return initField(name, "\"" ++ name ++ "\"", sql_type, null, false, true);
}

/// Comptime required field builder.
pub fn makeRequiredField(comptime name: []const u8, sql_type: schema_types.FieldType) schema_types.Field {
    return initField(name, "\"" ++ name ++ "\"", sql_type, null, true, false);
}

/// Comptime table builder — auto-computes name_quoted at compile time.
pub fn makeTable(comptime name: []const u8, fields: []const schema_types.Field) schema_types.Table {
    return .{
        .name = name,
        .name_quoted = "\"" ++ name ++ "\"",
        .fields = fields,
        .is_users_table = std.mem.eql(u8, name, "users"),
        .namespaced = !std.mem.eql(u8, name, "users"),
    };
}

pub fn isClientWritableFieldIndex(table: *const schema_types.Table, index: usize) bool {
    if (!table.canonical_fields) return index < table.fields.len;
    return index >= table.user_field_start and index < table.user_field_end;
}

/// Runtime field builder (for property tests with randomized names).
/// Caller must free: allocator.free(f.name); allocator.free(f.name_quoted);
pub fn makeFieldAlloc(allocator: std.mem.Allocator, name: []const u8, sql_type: schema_types.FieldType) !schema_types.Field {
    return initField(
        try allocator.dupe(u8, name),
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{name}),
        sql_type,
        null,
        false,
        false,
    );
}

/// Runtime table builder with auto-computed name_quoted.
/// Caller must free: allocator.free(t.name); allocator.free(t.name_quoted);
pub fn makeTableAlloc(allocator: std.mem.Allocator, name: []const u8, fields: []const schema_types.Field) !schema_types.Table {
    return .{
        .name = try allocator.dupe(u8, name),
        .name_quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{name}),
        .fields = fields,
        .is_users_table = std.mem.eql(u8, name, "users"),
        .namespaced = !std.mem.eql(u8, name, "users"),
    };
}

pub const TestFieldDef = struct {
    name: []const u8,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType = null,
};

pub fn makeRuntimeTable(allocator: std.mem.Allocator, name: []const u8, fields: []const TestFieldDef, table_index: usize) schema_types.Table {
    var declared_fields = allocator.alloc(schema_types.Field, fields.len) catch @panic("oom"); // zwanzig-disable-line: store-violations-engine
    for (fields, 0..) |field_def, built| {
        declared_fields[built] = initField(
            allocator.dupe(u8, field_def.name) catch @panic("oom"),
            std.fmt.allocPrint(allocator, "\"{s}\"", .{field_def.name}) catch @panic("oom"),
            field_def.field_type,
            field_def.items_type,
            false,
            false,
        );
    }

    var declared = schema_types.Table{
        .name = allocator.dupe(u8, name) catch @panic("oom"),
        .name_quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{name}) catch @panic("oom"),
        .fields = declared_fields,
        .is_users_table = std.mem.eql(u8, name, "users"),
        .namespaced = !std.mem.eql(u8, name, "users"),
    };
    defer declared.deinit(allocator);

    return schema_parse.buildRuntimeTable(allocator, declared, table_index) catch |err| @panic(@errorName(err));
}

pub fn makeSingleRuntimeTable(allocator: std.mem.Allocator, name: []const u8, fields: []const TestFieldDef) schema_types.Table {
    return makeRuntimeTable(allocator, name, fields, 0);
}

pub fn initSchemaFromTables(allocator: std.mem.Allocator, version: []const u8, tables: []const schema_types.Table) !Schema {
    return schema_parse.initFromTables(
        allocator,
        version,
        null,
        tables,
        &[_]schema_types.PresenceField{},
        &[_]schema_types.PresenceField{},
        &[_][]const u8{},
        &[_][]const u8{},
    );
}

pub const TableDef = struct {
    name: []const u8,
    fields: []const []const u8,
    types: ?[]const schema_types.FieldType = null,
};

fn tableDefToTestFieldDefs(allocator: std.mem.Allocator, td: TableDef) ![]TestFieldDef {
    const types = td.types orelse &[_]schema_types.FieldType{};
    const fields = try allocator.alloc(TestFieldDef, td.fields.len);
    for (td.fields, 0..) |field_name, j| {
        const field_type: schema_types.FieldType = if (j < types.len) types[j] else .text;
        fields[j] = .{
            .name = field_name,
            .field_type = field_type,
        };
    }
    return fields;
}

pub fn createTestSchema(allocator: std.mem.Allocator, tables_def: []const TableDef) !Schema {
    const has_users = blk: {
        for (tables_def) |td| {
            if (std.mem.eql(u8, td.name, "users")) break :blk true;
        }
        break :blk false;
    };

    const runtime_len = tables_def.len + @intFromBool(!has_users);
    var runtime_tables = try allocator.alloc(schema_types.Table, runtime_len);
    var built_count: usize = 0;
    errdefer {
        for (runtime_tables[0..built_count]) |*t| t.deinit(allocator);
        allocator.free(runtime_tables);
    }

    if (has_users) {
        for (tables_def) |td| {
            if (std.mem.eql(u8, td.name, "users")) {
                const test_fields = try tableDefToTestFieldDefs(allocator, td);
                defer allocator.free(test_fields);
                runtime_tables[built_count] = makeRuntimeTable(allocator, "users", test_fields, built_count);
                built_count += 1;
                break;
            }
        }
    } else {
        runtime_tables[built_count] = makeRuntimeTable(allocator, "users", &[_]TestFieldDef{}, built_count);
        built_count += 1;
    }

    for (tables_def) |td| {
        if (std.mem.eql(u8, td.name, "users")) continue;
        const test_fields = try tableDefToTestFieldDefs(allocator, td);
        defer allocator.free(test_fields);
        runtime_tables[built_count] = makeRuntimeTable(allocator, td.name, test_fields, built_count);
        built_count += 1;
    }

    var result = Schema{
        .allocator = allocator,
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = runtime_tables,
        .presence_user_fields = &.{},
        .presence_shared_fields = &.{},
        .presence_user_fields_names = &.{},
        .presence_shared_fields_names = &.{},
    };
    errdefer result.deinit();

    try schema_index.buildTableIndex(allocator, &result);
    return result;
}

pub fn deinitTestSchema(_: std.mem.Allocator, schema_value: *Schema) void {
    schema_value.deinit();
}

pub fn writeSchemaToFile(allocator: std.mem.Allocator, schema_value: *const Schema, path: []const u8) !void {
    const json_text = try schema_mod_format.format(allocator, schema_value);
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
    send_node_pool: ?MemoryStrategy.IndexPool(send_queue_type.Node) = null,
    send_queue: ?send_queue_type = null,
    change_queue: ?ChangeQueue = null,

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
        if (self.send_queue) |*sq| {
            while (sq.pop()) |entry| {
                entry.deinit();
            }
            sq.deinit();
        }
        if (self.send_node_pool) |*pool| pool.deinit();
        if (self.change_queue) |*cq| cq.deinit();
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
    if (effective.reader_pool_size == 0) {
        effective.reader_pool_size = 1;
    }
    return effective;
}

pub fn setupTestEngine(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const MemoryStrategy, context: *TestContext, schema: *const Schema, options: StorageEngine.Options) !void {
    try setupTestEngineWithPerformance(engine, allocator, memory_strategy, context, schema, .{}, options);
}

pub fn setupTestEngineWithPerformance(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const MemoryStrategy, context: *TestContext, schema: *const Schema, performance_config: StorageEngine.PerformanceConfig, options: StorageEngine.Options) !void {
    const effective_options = normalizeTestStorageOptions(options);
    try engine.init(allocator, @constCast(memory_strategy), context.test_dir, schema, performance_config, effective_options, null, null);
    errdefer engine.deinit();

    var gen = ddl_generator.DDLGenerator.init(allocator);
    for (schema.tables) |table| {
        const ddl = try gen.generateDDL(table);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try engine.execSetupSQL(ddl_z);
    }

    // Detect and execute migrations
    const setup_conn = try engine.getSetupConn();
    var detector = migration_detector.MigrationDetector.init(allocator, setup_conn, schema);
    const plan = try detector.detectChanges(schema);
    defer detector.deinit(plan);

    if (plan.changes.len > 0) {
        var executor = MigrationExecutor.init(
            allocator,
            setup_conn,
            &gen,
            .{},
        );
        try executor.execute(plan, schema.version);
    }

    // SAFETY: Immediately initialized by init() call below.
    var node_pool: MemoryStrategy.IndexPool(send_queue_type.Node) = undefined;
    try node_pool.init(allocator, 256, null, null);
    context.send_node_pool = node_pool;
    errdefer {
        context.send_node_pool.?.deinit();
        context.send_node_pool = null;
    }

    context.send_queue = try send_queue_type.init(&context.send_node_pool.?);
    errdefer {
        context.send_queue.?.deinit();
        context.send_queue = null;
    }

    context.change_queue = try ChangeQueue.init(allocator, 1);
    errdefer context.change_queue.?.deinit();

    try engine.start(&context.send_queue.?, &context.change_queue.?, null);
}
