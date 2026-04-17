const std = @import("std");
const testing = std.testing;
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
pub const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const schema_helpers = @import("schema_test_helpers.zig");
pub const TestContext = schema_helpers.TestContext;

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
        .items_type = if (sql_type == .array) .text else null,
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

pub fn getRowField(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) ?storage_engine.TypedValue {
    const idx = metadata.field_index_map.get(key) orelse return null;
    if (idx >= doc.values.len) return null;
    return doc.values[idx];
}

pub fn getFieldText(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) ![]const u8 {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .scalar or val.scalar != .text) return error.TypeMismatch;
    return val.scalar.text;
}

pub fn getFieldTextOrNull(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) ?[]const u8 {
    const val = getRowField(doc, metadata, key) orelse return null;
    if (val != .scalar or val.scalar != .text) return null;
    return val.scalar.text;
}

pub fn expectMissingField(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) !void {
    try testing.expect(getRowField(doc, metadata, key) == null);
}

pub fn expectFieldTextArray(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8, expected: []const []const u8) !void {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .array) return error.TypeMismatch;
    try testing.expectEqual(expected.len, val.array.len);
    for (expected, val.array) |exp, got| {
        if (got != .text) return error.TypeMismatch;
        try testing.expectEqualStrings(exp, got.text);
    }
}

pub fn expectFieldString(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8, expected: []const u8) !storage_engine.TypedValue {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    try testing.expect(val == .scalar and val.scalar == .text);
    try testing.expectEqualStrings(expected, val.scalar.text);
    return val;
}

pub fn expectFieldInt(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8, expected: i64) !i64 {
    const actual = try getFieldInt(doc, metadata, key);
    try testing.expectEqual(expected, actual);
    return actual;
}

pub fn getFieldInt(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) !i64 {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val == .scalar and val.scalar == .integer) return val.scalar.integer;
    return error.TypeMismatch;
}

pub fn expectFieldReal(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8, expected: f64) !f64 {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .scalar or val.scalar != .real) return error.TypeMismatch;
    const actual = val.scalar.real;
    try testing.expectApproxEqAbs(expected, actual, 0.00001);
    return actual;
}

pub fn expectFieldBool(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8, expected: bool) !bool {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    try testing.expect(val == .scalar and val.scalar == .boolean);
    try testing.expectEqual(expected, val.scalar.boolean);
    return val.scalar.boolean;
}

pub fn expectFieldArray(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8, expected_len: usize) !storage_engine.TypedValue {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    try testing.expect(val == .array);
    try testing.expectEqual(expected_len, val.array.len);
    return val;
}

// Map does not exist in TypedRow API, so test may need alternative verification or removal.
// pub fn expectFieldMap(doc: storage_engine.TypedRow, key: []const u8) !storage_engine.TypedValue {
// }
