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
    engine: *StorageEngine,
    sm: *SchemaManager,
    memory_strategy: *MemoryStrategy,
    test_context: TestContext,

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
        self.allocator.destroy(self.memory_strategy);
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
pub fn createSchemaManager(allocator: Allocator, tables: []const Table) !*SchemaManager {
    const sm = try allocator.create(SchemaManager);
    errdefer allocator.destroy(sm);

    // Clone tables so SchemaManager can own them independently of the caller's stack
    var cloned_tables = try allocator.alloc(Table, tables.len);
    errdefer {
        allocator.free(cloned_tables);
    }
    for (tables, 0..) |t, i| {
        cloned_tables[i] = try t.clone(allocator);
    }

    const schema = Schema{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = cloned_tables,
    };

    const metadata = try schema_manager.SchemaMetadata.init(allocator, &schema);
    errdefer {
        var m = metadata;
        m.deinit();
        schema_manager.freeSchema(allocator, schema);
    }

    sm.* = .{
        .allocator = allocator,
        .schema = schema,
        .metadata = metadata,
    };
    return sm;
}

/// Creates a SchemaManager with a single dummy table.
pub fn createDummySchemaManager(allocator: Allocator) !*SchemaManager {
    const fields = try allocator.alloc(Field, 1);
    fields[0] = makeField("val", .text, false);

    var tables = try allocator.alloc(Table, 1);
    tables[0] = .{ .name = "_dummy", .fields = fields };
    // Note: createSchemaManager will clone the tables and fields.
    // However, our manually allocated 'fields' and 'tables' arrays here will leak if we don't handle them.
    // Actually, createSchemaManager will clone EVERYTHING.
    const sm = try createSchemaManager(allocator, tables);

    // Clean up our temporary structures
    allocator.free(fields);
    allocator.free(tables);

    return sm;
}

/// Setup a storage engine with a single table.
pub fn setupEngine(allocator: Allocator, prefix: []const u8, table: Table) !EngineTestContext {
    return setupEngineWithOptions(allocator, prefix, table, .{ .in_memory = true });
}

/// Setup a storage engine with a single table and specific options.
pub fn setupEngineWithOptions(allocator: Allocator, prefix: []const u8, table: Table, options: StorageEngine.Options) !EngineTestContext {
    var tables = [_]Table{table};
    return setupEngineMultiTableWithOptions(allocator, prefix, &tables, options);
}

/// Setup a storage engine with multiple tables.
pub fn setupEngineMultiTable(allocator: Allocator, prefix: []const u8, tables: []const Table) !EngineTestContext {
    return setupEngineMultiTableWithOptions(allocator, prefix, tables, .{ .in_memory = true });
}

/// Setup a storage engine with a single table in an existing directory.
pub fn setupEngineWithDir(allocator: Allocator, test_dir: []const u8, table: Table, options: StorageEngine.Options) !EngineTestContext {
    var tables = [_]Table{table};
    return setupEngineMultiTableWithDir(allocator, test_dir, &tables, options);
}

/// Setup a storage engine with multiple tables and specific options.
pub fn setupEngineMultiTableWithOptions(allocator: Allocator, prefix: []const u8, tables: []const Table, options: StorageEngine.Options) !EngineTestContext {
    const tc = try TestContext.init(allocator, prefix);
    return setupEngineMultiTableWithTestContext(allocator, tc, tables, options);
}

/// Setup a storage engine with multiple tables in an existing directory.
pub fn setupEngineMultiTableWithDir(allocator: Allocator, test_dir: []const u8, tables: []const Table, options: StorageEngine.Options) !EngineTestContext {
    const tc = TestContext{
        .allocator = allocator,
        .test_dir = try allocator.dupe(u8, test_dir),
    };
    return setupEngineMultiTableWithTestContext(allocator, tc, tables, options);
}

fn setupEngineMultiTableWithTestContext(allocator: Allocator, tc: TestContext, tables: []const Table, options: StorageEngine.Options) !EngineTestContext {
    errdefer {
        var local_tc = tc;
        local_tc.deinit();
    }

    const ms = try allocator.create(MemoryStrategy);
    errdefer allocator.destroy(ms);
    try ms.init(allocator);
    errdefer ms.deinit();

    const sm = try createSchemaManager(allocator, tables);
    errdefer sm.deinit();

    const engine = try StorageEngine.init(allocator, ms, tc.test_dir, sm, .{}, options);
    errdefer engine.deinit();

    // Synchronously execute DDL for all tables
    var gen = ddl_generator.DDLGenerator.init(allocator);
    for (sm.schema.tables) |t| {
        const ddl = try gen.generateDDL(t);
        defer allocator.free(ddl);
        const ddl_z = try allocator.dupeZ(u8, ddl);
        defer allocator.free(ddl_z);
        try engine.execDDL(ddl_z);
    }

    return EngineTestContext{
        .allocator = allocator,
        .engine = engine,
        .sm = sm,
        .memory_strategy = ms,
        .test_context = tc,
    };
}

pub fn makePayloadStr(s: []const u8, allocator: std.mem.Allocator) !msgpack.Payload {
    return try msgpack.Payload.strToPayload(s, allocator);
}
