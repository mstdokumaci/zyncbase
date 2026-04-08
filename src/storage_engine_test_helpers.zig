const std = @import("std");
const msgpack = @import("msgpack_utils.zig");
const Allocator = std.mem.Allocator;
const storage_engine = @import("storage_engine.zig");
pub const StorageEngine = storage_engine.StorageEngine;
pub const ColumnValue = storage_engine.ColumnValue;
pub const StorageError = storage_engine.StorageError;
pub const schema_manager = @import("schema_manager.zig");
pub const SchemaManager = schema_manager.SchemaManager;
pub const Schema = schema_manager.Schema;
pub const Table = schema_manager.Table;
pub const Field = schema_manager.Field;
pub const FieldType = schema_manager.FieldType;
pub const TableMetadata = schema_manager.TableMetadata;
pub const ddl_generator = @import("ddl_generator.zig");
pub const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const schema_helpers = @import("schema_test_helpers.zig");
pub const TestContext = schema_helpers.TestContext;

/// EngineTestContext owns all resources for a storage engine test.
pub const EngineTestContext = struct {
    allocator: Allocator,
    engine: StorageEngine,
    sm: SchemaManager,
    memory_strategy: MemoryStrategy,
    test_context: TestContext,

    pub fn init(self: *EngineTestContext, allocator: Allocator, prefix: []const u8, table: Table) !void {
        try self.initWithOptions(allocator, prefix, &[_]Table{table}, .{ .in_memory = true });
    }

    pub fn initWithOptions(self: *EngineTestContext, allocator: Allocator, prefix: []const u8, tables: []const Table, options: StorageEngine.Options) !void {
        self.allocator = allocator;
        self.test_context = try TestContext.init(allocator, prefix);
        errdefer self.test_context.deinit();

        try self.memory_strategy.init(allocator);
        errdefer self.memory_strategy.deinit();

        self.sm = try createSchemaManager(allocator, tables);
        errdefer self.sm.deinit();

        try self.engine.init(allocator, &self.memory_strategy, self.test_context.test_dir, &self.sm, .{}, options, null, null);
        errdefer self.engine.deinit();

        // Synchronously execute DDL for all tables
        var gen = ddl_generator.DDLGenerator.init(allocator);
        for (self.sm.schema.tables) |t| {
            const ddl = try gen.generateDDL(t);
            defer allocator.free(ddl);
            const ddl_z = try allocator.dupeZ(u8, ddl);
            defer allocator.free(ddl_z);
            try self.engine.execSetupSQL(ddl_z);
        }
        try self.engine.start();
    }

    pub fn deinit(self: *EngineTestContext) void {
        self.deinitInternal(true);
    }

    pub fn deinitNoCleanup(self: *EngineTestContext) void {
        self.deinitInternal(false);
    }

    fn deinitInternal(self: *EngineTestContext, cleanup: bool) void {
        self.engine.deinit();
        self.sm.deinit();
        self.memory_strategy.deinit();
        if (cleanup) {
            self.test_context.deinit();
        } else {
            self.allocator.free(self.test_context.test_dir);
        }
    }
};

/// Helper to create a Field with standard defaults.
pub fn makeField(name: []const u8, sql_type: FieldType, required: bool) Field {
    return .{
        .name = name,
        .sql_type = sql_type,
        .required = required,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

/// Helper to create an indexed Field.
pub fn makeIndexedField(name: []const u8, sql_type: FieldType, required: bool) Field {
    var f = makeField(name, sql_type, required);
    f.indexed = true;
    return f;
}

/// Helper to create a reference Field.
pub fn makeRefField(name: []const u8, references: []const u8, on_delete: schema_manager.OnDelete) Field {
    var f = makeField(name, .text, false);
    f.references = references;
    f.on_delete = on_delete;
    return f;
}

/// Internal helper that replaces the old SchemaManager.initWithSchema logic.
/// Takes a slice of Table values, clones them, builds SchemaMetadata.
pub fn createSchemaManager(allocator: Allocator, tables: []const Table) !SchemaManager {
    // Clone tables so SchemaManager can own them independently of the caller's stack
    const cloned_tables = try allocator.alloc(Table, tables.len);
    var i: usize = 0;
    errdefer {
        for (cloned_tables[0..i]) |t| schema_manager.freeTable(allocator, t);
        allocator.free(cloned_tables);
    }
    for (tables) |t| {
        cloned_tables[i] = try t.clone(allocator);
        i += 1;
    }

    const schema = Schema{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = cloned_tables,
    };
    errdefer schema_manager.freeSchema(allocator, schema);

    const metadata = try schema_manager.SchemaMetadata.init(allocator, &schema);
    errdefer {
        var m = metadata;
        m.deinit();
    }

    return SchemaManager{
        .allocator = allocator,
        .schema = schema,
        .metadata = metadata,
    };
}

/// Creates a SchemaManager with a single dummy table.
pub fn createDummySchemaManager(allocator: Allocator) !SchemaManager {
    const fields = try allocator.alloc(Field, 1);
    fields[0] = makeField("val", .text, false);

    var tables = try allocator.alloc(Table, 1);
    tables[0] = .{ .name = "_dummy", .fields = fields };
    // Note: createSchemaManager will clone the tables and fields.
    const sm = try createSchemaManager(allocator, tables);

    // Clean up our temporary structures
    allocator.free(fields);
    allocator.free(tables);

    return sm;
}

/// Setup a storage engine with a single table.
pub fn setupEngine(ctx: *EngineTestContext, allocator: Allocator, prefix: []const u8, table: Table) !void {
    try setupEngineWithOptions(ctx, allocator, prefix, table, .{ .in_memory = true });
}

/// Setup a storage engine with a single table and specific options.
pub fn setupEngineWithOptions(ctx: *EngineTestContext, allocator: Allocator, prefix: []const u8, table: Table, options: StorageEngine.Options) !void {
    try ctx.initWithOptions(allocator, prefix, &[_]Table{table}, options);
}

/// Setup a storage engine with multiple tables.
pub fn setupEngineMultiTable(ctx: *EngineTestContext, allocator: Allocator, prefix: []const u8, tables: []const Table) !void {
    try setupEngineMultiTableWithOptions(ctx, allocator, prefix, tables, .{ .in_memory = true });
}

/// Setup a storage engine with a single table in an existing directory.
pub fn setupEngineWithDir(ctx: *EngineTestContext, allocator: Allocator, test_dir: []const u8, table: Table, options: StorageEngine.Options) !void {
    var tables = [_]Table{table};
    try setupEngineMultiTableWithDir(ctx, allocator, test_dir, &tables, options);
}

/// Setup a storage engine with multiple tables and specific options.
pub fn setupEngineMultiTableWithOptions(ctx: *EngineTestContext, allocator: Allocator, prefix: []const u8, tables: []const Table, options: StorageEngine.Options) !void {
    try ctx.initWithOptions(allocator, prefix, tables, options);
}

/// Setup a storage engine with multiple tables in an existing directory.
pub fn setupEngineMultiTableWithDir(ctx: *EngineTestContext, allocator: Allocator, test_dir: []const u8, tables: []const Table, options: StorageEngine.Options) !void {
    const tc = TestContext{
        .allocator = allocator,
        .test_dir = try allocator.dupe(u8, test_dir),
    };
    try setupEngineMultiTableWithTestContext(ctx, allocator, tc, tables, options);
}

fn setupEngineMultiTableWithTestContext(ctx: *EngineTestContext, allocator: Allocator, tc: TestContext, tables: []const Table, options: StorageEngine.Options) !void {
    ctx.allocator = allocator;
    ctx.test_context = tc;
    errdefer ctx.test_context.deinit();

    try ctx.memory_strategy.init(allocator);
    errdefer ctx.memory_strategy.deinit();

    ctx.sm = try createSchemaManager(allocator, tables);
    errdefer ctx.sm.deinit();

    try ctx.engine.init(allocator, &ctx.memory_strategy, ctx.test_context.test_dir, &ctx.sm, .{}, options, null, null);
    errdefer ctx.engine.deinit();

    // Synchronously execute DDL for all tables
    var gen = ddl_generator.DDLGenerator.init(allocator);
    for (ctx.sm.schema.tables) |t| {
        const ddl = try gen.generateDDL(t);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try ctx.engine.execSetupSQL(ddl_z);
    }
    try ctx.engine.start();
}

pub fn makePayloadStr(s: []const u8, allocator: std.mem.Allocator) !msgpack.Payload {
    return try msgpack.Payload.strToPayload(s, allocator);
}
