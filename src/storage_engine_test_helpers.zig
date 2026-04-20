const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const storage_engine = @import("storage_engine.zig");
const tth = @import("typed_test_helpers.zig");
const Helpers = @This();
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
pub const query_parser = @import("query_parser.zig");
pub const TestContext = schema_helpers.TestContext;

pub const NamedColumn = struct {
    field: []const u8,
    value: storage_engine.TypedValue,
};

pub const TableFixture = struct {
    engine: *StorageEngine,
    metadata: *const TableMetadata,

    pub fn fieldIndex(self: TableFixture, field: []const u8) !usize {
        return self.metadata.field_index_map.get(field) orelse StorageError.UnknownField;
    }

    pub fn insertNamed(
        self: TableFixture,
        id: []const u8,
        namespace: []const u8,
        columns: anytype,
    ) !void {
        try insertNamedWithMetadata(self.engine, self.metadata, id, namespace, columns);
    }

    pub fn insertField(
        self: TableFixture,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: storage_engine.TypedValue,
    ) !void {
        try insertNamedWithMetadata(self.engine, self.metadata, id, namespace, .{named(field, value)});
    }

    pub fn insertText(
        self: TableFixture,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: []const u8,
    ) !void {
        try self.insertField(id, namespace, field, tth.valText(value));
    }

    pub fn insertInt(
        self: TableFixture,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: i64,
    ) !void {
        try self.insertField(id, namespace, field, tth.valInt(value));
    }

    pub fn flush(self: TableFixture) !void {
        try self.engine.flushPendingWrites();
    }

    pub fn selectDocument(
        self: TableFixture,
        allocator: Allocator,
        id: []const u8,
        namespace: []const u8,
    ) !storage_engine.ManagedResult {
        return self.engine.selectDocument(allocator, self.metadata.index, id, namespace);
    }

    pub fn selectQuery(
        self: TableFixture,
        allocator: Allocator,
        namespace: []const u8,
        filter: query_parser.QueryFilter,
    ) !storage_engine.ManagedResult {
        return self.engine.selectQuery(allocator, self.metadata.index, namespace, filter);
    }

    pub fn countRows(
        self: TableFixture,
        namespace: []const u8,
    ) !usize {
        return self.engine.countRows(self.metadata.index, namespace);
    }

    pub fn deleteDocument(
        self: TableFixture,
        id: []const u8,
        namespace: []const u8,
    ) !void {
        return self.engine.deleteDocument(self.metadata.index, id, namespace);
    }

    pub fn getOne(
        self: TableFixture,
        allocator: Allocator,
        id: []const u8,
        namespace: []const u8,
    ) !ManagedDocument {
        var managed = try self.selectDocument(allocator, id, namespace);
        if (managed.rows.len == 0) {
            managed.deinit();
            return error.NotFound;
        }
        return .{ .fixture = self, .managed = managed };
    }
};

pub const ManagedDocument = struct {
    fixture: TableFixture,
    managed: storage_engine.ManagedResult,

    pub fn deinit(self: *ManagedDocument) void {
        self.managed.deinit();
    }

    pub fn getFieldText(self: *const ManagedDocument, key: []const u8) ![]const u8 {
        return Helpers.getFieldText(self.managed.rows[0], self.fixture.metadata, key);
    }

    pub fn getFieldTextOrNull(self: *const ManagedDocument, key: []const u8) ?[]const u8 {
        return Helpers.getFieldTextOrNull(self.managed.rows[0], self.fixture.metadata, key);
    }

    pub fn getFieldInt(self: *const ManagedDocument, key: []const u8) !i64 {
        return Helpers.getFieldInt(self.managed.rows[0], self.fixture.metadata, key);
    }

    pub fn expectMissingField(self: *const ManagedDocument, key: []const u8) !void {
        try Helpers.expectMissingField(self.managed.rows[0], self.fixture.metadata, key);
    }

    pub fn expectFieldTextArray(self: *const ManagedDocument, key: []const u8, expected: []const []const u8) !void {
        try Helpers.expectFieldTextArray(self.managed.rows[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldString(self: *const ManagedDocument, key: []const u8, expected: []const u8) !storage_engine.TypedValue {
        return Helpers.expectFieldString(self.managed.rows[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldInt(self: *const ManagedDocument, key: []const u8, expected: i64) !i64 {
        return Helpers.expectFieldInt(self.managed.rows[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldReal(self: *const ManagedDocument, key: []const u8, expected: f64) !f64 {
        return Helpers.expectFieldReal(self.managed.rows[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldBool(self: *const ManagedDocument, key: []const u8, expected: bool) !bool {
        return Helpers.expectFieldBool(self.managed.rows[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldArray(self: *const ManagedDocument, key: []const u8, expected_len: usize) !storage_engine.TypedValue {
        return Helpers.expectFieldArray(self.managed.rows[0], self.fixture.metadata, key, expected_len);
    }
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

    pub fn init(self: *EngineTestContext, allocator: Allocator, prefix: []const u8, table_def: Table) !void {
        try self.initWithOptions(allocator, prefix, &[_]Table{table_def}, .{ .in_memory = true });
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

    pub fn tableMetadata(self: *const EngineTestContext, table_name: []const u8) !*const TableMetadata {
        return self.sm.getTable(table_name) orelse StorageError.UnknownTable;
    }

    pub fn table(self: *EngineTestContext, table_name: []const u8) !TableFixture {
        return .{
            .engine = &self.engine,
            .metadata = try self.tableMetadata(table_name),
        };
    }

    pub fn insertNamed(
        self: *EngineTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        columns: anytype,
    ) !void {
        const table_metadata = try self.tableMetadata(table_name);
        try insertNamedWithMetadata(&self.engine, table_metadata, id, namespace, columns);
    }

    pub fn insertField(
        self: *EngineTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: storage_engine.TypedValue,
    ) !void {
        try self.insertNamed(table_name, id, namespace, .{named(field, value)});
    }

    pub fn insertText(
        self: *EngineTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: []const u8,
    ) !void {
        try self.insertField(table_name, id, namespace, field, tth.valText(value));
    }

    pub fn insertInt(
        self: *EngineTestContext,
        table_name: []const u8,
        id: []const u8,
        namespace: []const u8,
        field: []const u8,
        value: i64,
    ) !void {
        try self.insertField(table_name, id, namespace, field, tth.valInt(value));
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
    const sm = try createSchemaManager(allocator, tables);

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

pub fn named(field: []const u8, value: storage_engine.TypedValue) NamedColumn {
    return .{ .field = field, .value = value };
}

fn fillNamedColumns(
    table_metadata: *const TableMetadata,
    resolved: []ColumnValue,
    columns: anytype,
) !void {
    inline for (columns, 0..) |column, i| {
        const index = table_metadata.field_index_map.get(column.field) orelse return StorageError.UnknownField;
        resolved[i] = .{ .index = index, .value = column.value };
    }
}

fn insertNamedWithMetadata(
    engine: *StorageEngine,
    table_metadata: *const TableMetadata,
    id: []const u8,
    namespace: []const u8,
    columns: anytype,
) !void {
    var resolved: [columns.len]storage_engine.ColumnValue = undefined;
    try fillNamedColumns(table_metadata, &resolved, columns);
    try engine.insertOrReplace(table_metadata.index, id, namespace, &resolved);
}

// ─── Row field accessors (module-level, for callers with raw TypedRow + metadata) ───

fn getRowField(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) ?storage_engine.TypedValue {
    const idx = metadata.field_index_map.get(key) orelse return null;
    if (idx >= doc.values.len) return null;
    return doc.values[idx];
}

pub fn getFieldTextOrNull(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) ?[]const u8 {
    const val = getRowField(doc, metadata, key) orelse return null;
    if (val != .scalar or val.scalar != .text) return null;
    return val.scalar.text;
}

pub fn getFieldInt(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) !i64 {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val == .scalar and val.scalar == .integer) return val.scalar.integer;
    return error.TypeMismatch;
}

pub fn getFieldText(doc: storage_engine.TypedRow, metadata: *const TableMetadata, key: []const u8) ![]const u8 {
    const val = getRowField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .scalar or val.scalar != .text) return error.TypeMismatch;
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

pub fn makeRowChangeNamed(
    allocator: std.mem.Allocator,
    sm: *const SchemaManager,
    table_name: []const u8,
    namespace: []const u8,
    op: @import("change_buffer.zig").OwnedRowChange.Operation,
    old_row: ?storage_engine.TypedRow,
    new_row: ?storage_engine.TypedRow,
) !@import("change_buffer.zig").OwnedRowChange {
    const metadata = sm.getTable(table_name) orelse return error.UnknownTable;
    return .{
        .namespace = try allocator.dupe(u8, namespace),
        .table_index = metadata.index,
        .operation = op,
        .old_row = old_row,
        .new_row = new_row,
    };
}
