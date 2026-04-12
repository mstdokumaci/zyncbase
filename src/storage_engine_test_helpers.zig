const std = @import("std");
const msgpack = @import("msgpack_utils.zig");
const Allocator = std.mem.Allocator;
const storage_engine = @import("storage_engine.zig");
const write_command = @import("storage_engine/write_command.zig");
pub const StorageEngine = storage_engine.StorageEngine;
pub const StorageError = storage_engine.StorageError;
pub const schema_manager = @import("schema_manager.zig");
pub const SchemaManager = schema_manager.SchemaManager;
pub const Schema = schema_manager.Schema;
pub const Table = schema_manager.Table;
pub const Field = schema_manager.Field;
pub const FieldType = schema_manager.FieldType;
pub const TableMetadata = schema_manager.TableMetadata;
pub const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const schema_helpers = @import("schema_test_helpers.zig");
pub const TestContext = schema_helpers.TestContext;

pub const WriteValueInput = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8,
    boolean: bool,
    array_json: []const u8,
    nil: void,
};

pub const WriteColumnInput = struct {
    name: []const u8,
    field_type: FieldType,
    value: WriteValueInput,
};

fn createTestContext(allocator: Allocator, prefix: []const u8, options: StorageEngine.Options) !TestContext {
    if (options.in_memory) {
        return TestContext.initInMemory(allocator);
    }
    return TestContext.init(allocator, prefix);
}

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
        const effective_options = schema_helpers.normalizeTestStorageOptions(options);
        self.allocator = allocator;
        self.test_context = try createTestContext(allocator, prefix, effective_options);
        errdefer self.test_context.deinit();

        try self.memory_strategy.init(allocator);
        errdefer self.memory_strategy.deinit();

        self.sm = try createSchemaManager(allocator, tables);
        errdefer self.sm.deinit();

        try schema_helpers.setupTestEngine(&self.engine, allocator, &self.memory_strategy, &self.test_context, &self.sm, effective_options);
        errdefer self.engine.deinit();
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

/// Setup a storage engine with a single table in an existing directory.
pub fn setupEngineWithDir(ctx: *EngineTestContext, allocator: Allocator, test_dir: []const u8, table: Table, options: StorageEngine.Options) !void {
    var tables = [_]Table{table};
    try setupEngineMultiTableWithDir(ctx, allocator, test_dir, &tables, options);
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
    const effective_options = schema_helpers.normalizeTestStorageOptions(options);
    ctx.allocator = allocator;
    ctx.test_context = tc;
    errdefer ctx.test_context.deinit();

    try ctx.memory_strategy.init(allocator);
    errdefer ctx.memory_strategy.deinit();

    ctx.sm = try createSchemaManager(allocator, tables);
    errdefer ctx.sm.deinit();

    try schema_helpers.setupTestEngine(&ctx.engine, allocator, &ctx.memory_strategy, &ctx.test_context, &ctx.sm, effective_options);
    errdefer ctx.engine.deinit();
}

pub fn makePayloadStr(s: []const u8, allocator: std.mem.Allocator) !msgpack.Payload {
    return try msgpack.Payload.strToPayload(s, allocator);
}

fn cloneWriteValue(allocator: Allocator, input: WriteValueInput) !write_command.WriteValue {
    return switch (input) {
        .integer => |v| .{ .integer = v },
        .real => |v| .{ .real = v },
        .text => |v| .{ .text = try allocator.dupe(u8, v) },
        .boolean => |v| .{ .boolean = v },
        .array_json => |v| .{ .array_json = try allocator.dupe(u8, v) },
        .nil => .nil,
    };
}

pub fn enqueueDocumentWrite(
    engine: *StorageEngine,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    columns: []const WriteColumnInput,
) !void {
    var write = write_command.DocumentWrite.empty;
    errdefer write.deinit(engine.allocator);

    write.table = try engine.allocator.dupe(u8, table);
    write.id = try engine.allocator.dupe(u8, id);
    write.namespace = try engine.allocator.dupe(u8, namespace);
    write.columns = try engine.allocator.alloc(write_command.WriteColumn, columns.len);

    for (write.columns) |*col| {
        col.* = .{ .name = "", .field_type = .text, .value = .nil };
    }
    for (columns, 0..) |in_col, i| {
        write.columns[i] = .{
            .name = try engine.allocator.dupe(u8, in_col.name),
            .field_type = in_col.field_type,
            .value = try cloneWriteValue(engine.allocator, in_col.value),
        };
    }

    try engine.takeDocumentWrite(&write);
}

pub fn enqueueFieldWrite(
    engine: *StorageEngine,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    field_name: []const u8,
    field_type: FieldType,
    value: WriteValueInput,
) !void {
    var write = write_command.FieldWrite{
        .table = try engine.allocator.dupe(u8, table),
        .id = try engine.allocator.dupe(u8, id),
        .namespace = try engine.allocator.dupe(u8, namespace),
        .field = try engine.allocator.dupe(u8, field_name),
        .field_type = field_type,
        .value = try cloneWriteValue(engine.allocator, value),
    };
    errdefer write.deinit(engine.allocator);

    try engine.takeFieldWrite(&write);
}
