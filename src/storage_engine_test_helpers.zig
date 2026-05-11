const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const storage_engine = @import("storage_engine.zig");
const typed = @import("typed.zig");
const tth = @import("typed_test_helpers.zig");
const Helpers = @This();
pub const StorageEngine = storage_engine.StorageEngine;
pub const ColumnValue = storage_engine.ColumnValue;
pub const StorageError = storage_engine.StorageError;
pub const schema = @import("schema.zig");
pub const Schema = schema.Schema;
pub const Table = schema.Table;
pub const Field = schema.Field;
pub const FieldType = schema.FieldType;
pub const TableMetadata = schema.Table;
pub const MemoryStrategy = @import("memory_strategy.zig").MemoryStrategy;
const schema_helpers = @import("schema_test_helpers.zig");
pub const query_ast = @import("query_ast.zig");
pub const TestContext = schema_helpers.TestContext;

pub const NamedColumn = struct {
    field: []const u8,
    value: typed.Value,
};

pub const TableFixture = struct {
    engine: *StorageEngine,
    metadata: *const TableMetadata,

    pub fn fieldIndex(self: TableFixture, field: []const u8) !usize {
        return self.metadata.fieldIndex(field) orelse StorageError.UnknownField;
    }

    pub fn insertNamed(
        self: TableFixture,
        id: typed.DocId,
        namespace_id: i64,
        columns: anytype,
    ) !void {
        try insertNamedWithMetadata(self.engine, self.metadata, id, namespace_id, columns);
    }

    pub fn insertField(
        self: TableFixture,
        id: typed.DocId,
        namespace_id: i64,
        field: []const u8,
        value: typed.Value,
    ) !void {
        try insertNamedWithMetadata(self.engine, self.metadata, id, namespace_id, .{named(field, value)});
    }

    pub fn insertText(
        self: TableFixture,
        id: typed.DocId,
        namespace_id: i64,
        field: []const u8,
        value: []const u8,
    ) !void {
        try self.insertField(id, namespace_id, field, tth.valText(value));
    }

    pub fn insertInt(
        self: TableFixture,
        id: typed.DocId,
        namespace_id: i64,
        field: []const u8,
        value: i64,
    ) !void {
        try self.insertField(id, namespace_id, field, tth.valInt(value));
    }

    pub fn flush(self: TableFixture) !void {
        try self.engine.flushPendingWrites();
    }

    pub fn selectDocument(
        self: TableFixture,
        allocator: Allocator,
        id: typed.DocId,
        namespace_id: i64,
    ) !storage_engine.ManagedResult {
        return self.engine.selectDocument(allocator, self.metadata.index, id, namespace_id, null);
    }

    pub fn selectQuery(
        self: TableFixture,
        allocator: Allocator,
        namespace_id: i64,
        filter: *const query_ast.QueryFilter,
    ) !storage_engine.ManagedResult {
        const res = try self.engine.selectQuery(allocator, self.metadata.index, namespace_id, filter, null);
        if (res.next_cursor_str) |s| allocator.free(s);
        return res.result;
    }

    pub fn deleteDocument(
        self: TableFixture,
        id: typed.DocId,
        namespace_id: i64,
    ) !void {
        return self.engine.deleteDocument(self.metadata.index, id, namespace_id, null);
    }

    pub fn getOne(
        self: TableFixture,
        allocator: Allocator,
        id: typed.DocId,
        namespace_id: i64,
    ) !ManagedDocument {
        var managed = try self.selectDocument(allocator, id, namespace_id);
        if (managed.records.len == 0) {
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
        return Helpers.getFieldText(self.managed.records[0], self.fixture.metadata, key);
    }

    pub fn getFieldTextOrNull(self: *const ManagedDocument, key: []const u8) ?[]const u8 {
        return Helpers.getFieldTextOrNull(self.managed.records[0], self.fixture.metadata, key);
    }

    pub fn getFieldDocIdOrNull(self: *const ManagedDocument, key: []const u8) ?typed.DocId {
        return Helpers.getFieldDocIdOrNull(self.managed.records[0], self.fixture.metadata, key);
    }

    pub fn getFieldInt(self: *const ManagedDocument, key: []const u8) !i64 {
        return Helpers.getFieldInt(self.managed.records[0], self.fixture.metadata, key);
    }

    pub fn expectMissingField(self: *const ManagedDocument, key: []const u8) !void {
        try Helpers.expectMissingField(self.managed.records[0], self.fixture.metadata, key);
    }

    pub fn expectFieldTextArray(self: *const ManagedDocument, key: []const u8, expected: []const []const u8) !void {
        try Helpers.expectFieldTextArray(self.managed.records[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldString(self: *const ManagedDocument, key: []const u8, expected: []const u8) !typed.Value {
        return Helpers.expectFieldString(self.managed.records[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldDocId(self: *const ManagedDocument, key: []const u8, expected: typed.DocId) !typed.DocId {
        return Helpers.expectFieldDocId(self.managed.records[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldInt(self: *const ManagedDocument, key: []const u8, expected: i64) !i64 {
        return Helpers.expectFieldInt(self.managed.records[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldReal(self: *const ManagedDocument, key: []const u8, expected: f64) !f64 {
        return Helpers.expectFieldReal(self.managed.records[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldBool(self: *const ManagedDocument, key: []const u8, expected: bool) !bool {
        return Helpers.expectFieldBool(self.managed.records[0], self.fixture.metadata, key, expected);
    }

    pub fn expectFieldArray(self: *const ManagedDocument, key: []const u8, expected_len: usize) !typed.Value {
        return Helpers.expectFieldArray(self.managed.records[0], self.fixture.metadata, key, expected_len);
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
    sm: Schema,
    memory_strategy: MemoryStrategy,
    test_context: TestContext,

    pub fn init(self: *EngineTestContext, allocator: Allocator, prefix: []const u8, table_def: Table) !void {
        try self.initWithOptions(allocator, prefix, &[_]Table{table_def}, .{ .in_memory = true });
    }

    pub fn initWithOptions(self: *EngineTestContext, allocator: Allocator, prefix: []const u8, tables: []const Table, options: StorageEngine.Options) !void {
        try self.initWithPerformance(allocator, prefix, tables, .{}, options);
    }

    pub fn initWithPerformance(self: *EngineTestContext, allocator: Allocator, prefix: []const u8, tables: []const Table, performance_config: StorageEngine.PerformanceConfig, options: StorageEngine.Options) !void {
        const effective_options = schema_helpers.normalizeTestStorageOptions(options);
        self.allocator = allocator;
        self.test_context = try createTestContext(allocator, prefix, effective_options);
        errdefer self.test_context.deinit();

        try self.memory_strategy.init(allocator);
        errdefer self.memory_strategy.deinit();

        self.sm = try createSchema(allocator, tables);
        errdefer self.sm.deinit();

        try schema_helpers.setupTestEngineWithPerformance(&self.engine, allocator, &self.memory_strategy, &self.test_context, &self.sm, performance_config, effective_options);
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

    pub fn tableIndex(self: *const EngineTestContext, table_name: []const u8) usize {
        const md = self.sm.getTable(table_name) orelse std.debug.panic("test schema missing table '{s}'", .{table_name});
        return md.index;
    }

    pub fn fieldIndex(self: *const EngineTestContext, table_name: []const u8, field_name: []const u8) usize {
        const tbl = self.sm.getTable(table_name) orelse std.debug.panic("test schema missing table '{s}'", .{table_name});
        return tbl.getFieldIndex(field_name) orelse std.debug.panic("test schema table '{s}' missing field '{s}'", .{ table_name, field_name });
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
        id: typed.DocId,
        namespace_id: i64,
        columns: anytype,
    ) !void {
        const table_metadata = try self.tableMetadata(table_name);
        try insertNamedWithMetadata(&self.engine, table_metadata, id, namespace_id, columns);
    }

    pub fn insertField(
        self: *EngineTestContext,
        table_name: []const u8,
        id: typed.DocId,
        namespace_id: i64,
        field: []const u8,
        value: typed.Value,
    ) !void {
        try self.insertNamed(table_name, id, namespace_id, .{named(field, value)});
    }

    pub fn insertText(
        self: *EngineTestContext,
        table_name: []const u8,
        id: typed.DocId,
        namespace_id: i64,
        field: []const u8,
        value: []const u8,
    ) !void {
        try self.insertField(table_name, id, namespace_id, field, tth.valText(value));
    }

    pub fn insertInt(
        self: *EngineTestContext,
        table_name: []const u8,
        id: typed.DocId,
        namespace_id: i64,
        field: []const u8,
        value: i64,
    ) !void {
        try self.insertField(table_name, id, namespace_id, field, tth.valInt(value));
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
/// Delegates to schema_helpers.makeField, adding the required parameter.
pub fn makeField(comptime name: []const u8, sql_type: FieldType, required: bool) Field {
    var f = schema_helpers.makeField(name, sql_type);
    f.required = required;
    return f;
}

/// Helper to create an indexed Field.
pub fn makeIndexedField(comptime name: []const u8, sql_type: FieldType, required: bool) Field {
    var f = makeField(name, sql_type, required);
    f.indexed = true;
    return f;
}

/// Helper to create a Table with auto-computed name_quoted.
pub fn makeTable(comptime name: []const u8, fields: []const Field) Table {
    return schema_helpers.makeTable(name, fields);
}

/// Runtime table builder (for property tests with randomized names).
/// Caller must free: allocator.free(t.name); allocator.free(t.name_quoted);
pub fn makeTableAlloc(allocator: Allocator, name: []const u8, fields: []const Field) !Table {
    return schema_helpers.makeTableAlloc(allocator, name, fields);
}

/// Creates a canonical runtime schema from declared test tables.
pub fn createSchema(allocator: Allocator, tables: []const Table) !Schema {
    var runtime_tables = try allocator.alloc(Table, tables.len);
    var built_count: usize = 0;
    errdefer {
        for (runtime_tables[0..built_count]) |*t| t.deinit(allocator);
        allocator.free(runtime_tables);
    }

    for (tables, 0..) |declared, idx| {
        runtime_tables[built_count] = try schema.buildRuntimeTable(allocator, declared, idx);
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

/// Creates a schema with a single dummy table.
pub fn createDummySchema(allocator: Allocator) !Schema {
    const fields = try allocator.alloc(Field, 1);
    fields[0] = makeField("val", .text, false);

    var tables = try allocator.alloc(Table, 1);
    tables[0] = makeTable("_dummy", fields);
    const sm = try createSchema(allocator, tables);

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

pub fn setupEngineWithPerformance(ctx: *EngineTestContext, allocator: Allocator, prefix: []const u8, table: Table, performance_config: StorageEngine.PerformanceConfig, options: StorageEngine.Options) !void {
    try ctx.initWithPerformance(allocator, prefix, &[_]Table{table}, performance_config, options);
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

    ctx.sm = try createSchema(allocator, tables);
    errdefer ctx.sm.deinit();

    try schema_helpers.setupTestEngine(&ctx.engine, allocator, &ctx.memory_strategy, &ctx.test_context, &ctx.sm, effective_options);
    errdefer ctx.engine.deinit();
}

pub fn named(field: []const u8, value: typed.Value) NamedColumn {
    return .{ .field = field, .value = value };
}

fn fillNamedColumns(
    table_metadata: *const TableMetadata,
    resolved: []ColumnValue,
    columns: anytype,
) !void {
    inline for (columns, 0..) |column, i| {
        const index = table_metadata.fieldIndex(column.field) orelse return StorageError.UnknownField;
        resolved[i] = .{ .index = index, .value = column.value };
    }
}

fn insertNamedWithMetadata(
    engine: *StorageEngine,
    table_metadata: *const TableMetadata,
    id: typed.DocId,
    namespace_id: i64,
    columns: anytype,
) !void {
    var resolved: [columns.len]storage_engine.ColumnValue = undefined;
    try fillNamedColumns(table_metadata, &resolved, columns);
    try engine.insertOrReplace(table_metadata.index, id, namespace_id, typed.zeroDocId, &resolved, null);
}

// ─── Record field accessors (module-level, for callers with raw Record + metadata) ───

fn getRecordField(doc: typed.Record, metadata: *const TableMetadata, key: []const u8) ?typed.Value {
    const idx = metadata.fieldIndex(key) orelse return null;
    if (idx >= doc.values.len) return null;
    return doc.values[idx];
}

pub fn getFieldTextOrNull(doc: typed.Record, metadata: *const TableMetadata, key: []const u8) ?[]const u8 {
    const val = getRecordField(doc, metadata, key) orelse return null;
    if (val != .scalar or val.scalar != .text) return null;
    return val.scalar.text;
}

pub fn getFieldDocIdOrNull(doc: typed.Record, metadata: *const TableMetadata, key: []const u8) ?typed.DocId {
    const val = getRecordField(doc, metadata, key) orelse return null;
    if (val != .scalar or val.scalar != .doc_id) return null;
    return val.scalar.doc_id;
}

pub fn getFieldInt(doc: typed.Record, metadata: *const TableMetadata, key: []const u8) !i64 {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val == .scalar and val.scalar == .integer) return val.scalar.integer;
    return error.TypeMismatch;
}

pub fn getFieldText(doc: typed.Record, metadata: *const TableMetadata, key: []const u8) ![]const u8 {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .scalar or val.scalar != .text) return error.TypeMismatch;
    return val.scalar.text;
}

pub fn getFieldDocId(doc: typed.Record, metadata: *const TableMetadata, key: []const u8) !typed.DocId {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .scalar or val.scalar != .doc_id) return error.TypeMismatch;
    return val.scalar.doc_id;
}

pub fn expectMissingField(doc: typed.Record, metadata: *const TableMetadata, key: []const u8) !void {
    try testing.expect(getRecordField(doc, metadata, key) == null);
}

pub fn expectFieldTextArray(doc: typed.Record, metadata: *const TableMetadata, key: []const u8, expected: []const []const u8) !void {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .array) return error.TypeMismatch;
    try testing.expectEqual(expected.len, val.array.len);
    for (expected, val.array) |exp, got| {
        if (got != .text) return error.TypeMismatch;
        try testing.expectEqualStrings(exp, got.text);
    }
}

pub fn expectFieldString(doc: typed.Record, metadata: *const TableMetadata, key: []const u8, expected: []const u8) !typed.Value {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .scalar or val.scalar != .text) return error.TypeMismatch;
    try testing.expectEqualStrings(expected, val.scalar.text);
    return val;
}

pub fn expectFieldDocId(doc: typed.Record, metadata: *const TableMetadata, key: []const u8, expected: typed.DocId) !typed.DocId {
    const actual = try getFieldDocId(doc, metadata, key);
    try testing.expectEqual(expected, actual);
    return actual;
}

pub fn expectFieldInt(doc: typed.Record, metadata: *const TableMetadata, key: []const u8, expected: i64) !i64 {
    const actual = try getFieldInt(doc, metadata, key);
    try testing.expectEqual(expected, actual);
    return actual;
}

pub fn expectFieldReal(doc: typed.Record, metadata: *const TableMetadata, key: []const u8, expected: f64) !f64 {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    if (val != .scalar or val.scalar != .real) return error.TypeMismatch;
    const actual = val.scalar.real;
    try testing.expectApproxEqAbs(expected, actual, 0.00001);
    return actual;
}

pub fn expectFieldBool(doc: typed.Record, metadata: *const TableMetadata, key: []const u8, expected: bool) !bool {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    try testing.expect(val == .scalar and val.scalar == .boolean);
    try testing.expectEqual(expected, val.scalar.boolean);
    return val.scalar.boolean;
}

pub fn expectFieldArray(doc: typed.Record, metadata: *const TableMetadata, key: []const u8, expected_len: usize) !typed.Value {
    const val = getRecordField(doc, metadata, key) orelse return error.FieldNotFound;
    try testing.expect(val == .array);
    try testing.expectEqual(expected_len, val.array.len);
    return val;
}
