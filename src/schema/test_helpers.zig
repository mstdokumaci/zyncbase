const std = @import("std");

const sqlite = @import("sqlite");

const config_state = @import("../config/state.zig");
const send_queue_mod = @import("../connection/send_queue.zig");
const migration_startup = @import("../migration/startup.zig");
const canonical = @import("canonical.zig");
const schema_index = @import("index.zig");
const schema_parse = @import("parse.zig");
const schema_types = @import("types.zig");
const MemoryStrategy = @import("../memory/strategy.zig").MemoryStrategy;
const Diagnostics = @import("../migration/diagnostics.zig").Diagnostics;
const StorageEngine = @import("../storage_engine.zig").StorageEngine;
const ChangeQueue = @import("../subscription/change_queue.zig").ChangeQueue;

const send_queue_type = send_queue_mod.send_queue;
const Schema = schema_types.Schema;

/// Runs the production startup migration against `db`. Schemas built in code
/// get a test-only JSON identity (`schemaJsonForTest`).
pub fn runTestMigrations(allocator: std.mem.Allocator, db: *sqlite.Db, schema: *const Schema, schema_json: ?[]const u8) !void {
    const source = schema_json orelse try schemaJsonForTest(allocator, schema);
    defer if (schema_json == null) allocator.free(source);
    const identity = try canonical.Identity.init(allocator, source);
    defer identity.deinit(allocator);

    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    _ = migration_startup.run(std.testing.io, allocator, db, .{
        .schema = schema,
        .json = identity.json,
        .hash = identity.hash,
    }, .{}, &diag) catch |err| {
        std.log.err("Schema migration failed in test setup: {}", .{err});
        diag.logErrors();
        return err;
    };
}

// ─── Low-level Field and Table builders ──────────────────────────────────────
// These hide name_quoted — tests should never need to know about SQL quoting.

fn initField(
    name: []const u8,
    name_quoted: []const u8,
    field_type: schema_types.FieldType,
    items_type: ?schema_types.FieldType,
    required: bool,
    indexed: bool,
    constraints: ?schema_types.Constraints,
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
        .constraints = constraints,
    };
}

/// Comptime field builder — auto-computes name_quoted at compile time.
/// For runtime names, use makeFieldAlloc.
pub fn makeField(comptime name: []const u8, sql_type: schema_types.FieldType) schema_types.Field {
    return initField(name, "\"" ++ name ++ "\"", sql_type, null, false, false, null);
}

/// Comptime indexed field builder.
pub fn makeIndexedField(comptime name: []const u8, sql_type: schema_types.FieldType) schema_types.Field {
    return initField(name, "\"" ++ name ++ "\"", sql_type, null, false, true, null);
}

/// Comptime required field builder.
pub fn makeRequiredField(comptime name: []const u8, sql_type: schema_types.FieldType) schema_types.Field {
    return initField(name, "\"" ++ name ++ "\"", sql_type, null, true, false, null);
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
        null,
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
    constraints: ?schema_types.Constraints = null,
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
            if (field_def.constraints) |c| c.clone(allocator) catch @panic("oom") else null,
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
        &[_]schema_types.Action{},
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

pub const TestContext = struct {
    allocator: std.mem.Allocator,
    test_dir: []const u8,
    send_queue: ?send_queue_type = null,
    change_queue: ?ChangeQueue = null,

    pub fn init(allocator: std.mem.Allocator, prefix: []const u8) !TestContext {
        // Generate a unique directory name using timestamp and random bits
        var random_bytes: [8]u8 = undefined;
        try std.testing.io.randomSecure(&random_bytes);

        const timestamp = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
        const dir_name = try std.fmt.allocPrint(allocator, "test-artifacts/{s}-{d}-{x}", .{
            prefix,
            timestamp,
            std.mem.readInt(u64, &random_bytes, .little),
        });
        errdefer allocator.free(dir_name);

        // Ensure the directory itself exists
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir_name);

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
            self.send_queue = null;
        }
        if (self.change_queue) |*cq| cq.deinit();
        if (self.test_dir.len > 0) {
            std.Io.Dir.cwd().deleteTree(std.testing.io, self.test_dir) catch |err| {
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

/// Test-only schema JSON for schemas built in code, which have no source
/// text. Production always stores the source JSON. The output is
/// deterministic and changes whenever a persisted attribute changes; it is
/// only parsed back if a test restarts on the same database with a
/// different schema, in which case it must follow the real grammar.
pub fn schemaJsonForTest(allocator: std.mem.Allocator, schema: *const Schema) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var w: std.json.Stringify = .{ .writer = &out.writer };

    try w.beginObject();
    try w.objectField("version");
    try w.write(schema.version);
    try w.objectField("store");
    try w.beginObject();
    for (schema.tables) |*table| {
        try w.objectField(table.name);
        try w.beginObject();
        try w.objectField("namespaced");
        try w.write(table.namespaced);
        try w.objectField("fields");
        try w.beginObject();
        for (table.userFields()) |field| {
            try w.objectField(field.name);
            try writeTestField(&w, field);
        }
        try w.endObject();
        try w.objectField("required");
        try w.beginArray();
        for (table.userFields()) |field| {
            if (field.required) try w.write(field.name);
        }
        try w.endArray();
        try w.objectField("unique");
        try w.beginArray();
        for (table.unique_constraints) |constraint| {
            try w.beginArray();
            for (constraint.field_indexes) |i| try w.write(table.userFields()[i].name);
            try w.endArray();
        }
        try w.endArray();
        try w.endObject();
    }
    try w.endObject();
    try w.objectField("presence");
    try w.beginObject();
    try w.objectField("user");
    try writeTestPresence(&w, schema.presence_user_fields);
    try w.objectField("shared");
    try writeTestPresence(&w, schema.presence_shared_fields);
    try w.endObject();
    try w.endObject();
    return out.toOwnedSlice();
}

fn writeTestField(w: *std.json.Stringify, field: schema_types.Field) !void {
    try w.beginObject();
    try w.objectField("type");
    try w.write(field.declared_type.schemaName());
    if (field.storage_type != field.declared_type and field.references == null) {
        try w.objectField("storage");
        try w.write(@tagName(field.storage_type));
    }
    if (field.items_type) |items| {
        try w.objectField("items");
        try w.write(items.schemaName());
    }
    if (field.indexed) {
        try w.objectField("indexed");
        try w.write(true);
    }
    if (field.references) |ref| {
        const on_delete: schema_types.OnDelete = field.on_delete orelse .restrict;
        try w.objectField("references");
        try w.write(ref);
        try w.objectField("onDelete");
        try w.write(on_delete.schemaName());
    }
    if (field.constraints) |constraints| {
        if (constraints.enum_values) |values| {
            try w.objectField("enum");
            try w.beginArray();
            for (values) |value| switch (value) {
                .text => |t| try w.write(t),
                .integer => |i| try w.write(i),
                .real => |r| try w.write(r),
            };
            try w.endArray();
        }
        if (constraints.pattern_source) |pattern| {
            try w.objectField("pattern");
            try w.write(pattern);
        }
        if (constraints.format) |format| {
            try w.objectField("format");
            try w.write(format.schemaName());
        }
        if (constraints.min_length) |v| {
            try w.objectField("minLength");
            try w.write(v);
        }
        if (constraints.max_length) |v| {
            try w.objectField("maxLength");
            try w.write(v);
        }
        if (constraints.minimum) |b| {
            try w.objectField("minimum");
            try writeTestBound(w, b);
        }
        if (constraints.maximum) |b| {
            try w.objectField("maximum");
            try writeTestBound(w, b);
        }
    }
    try w.endObject();
}

fn writeTestBound(w: *std.json.Stringify, bound: schema_types.Constraints.Bound) !void {
    switch (bound) {
        .integer => |i| try w.write(i),
        .real => |r| try w.write(r),
    }
}

fn writeTestPresence(w: *std.json.Stringify, fields: []const schema_types.PresenceField) !void {
    try w.beginObject();
    for (fields) |field| {
        try w.objectField(field.name);
        try w.beginObject();
        try w.objectField("type");
        try w.write(field.declared_type.schemaName());
        try w.endObject();
    }
    try w.endObject();
}

pub fn setupTestEngine(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const MemoryStrategy, context: *TestContext, schema: *const Schema, options: StorageEngine.Options) !void {
    try setupTestEngineWithPerformance(engine, allocator, memory_strategy, context, schema, .{}, options);
}

pub fn setupTestEngineWithPerformance(engine: *StorageEngine, allocator: std.mem.Allocator, memory_strategy: *const MemoryStrategy, context: *TestContext, schema: *const Schema, performance_config: config_state.Config.PerformanceConfig, options: StorageEngine.Options) !void {
    try setupTestEngineWithJson(engine, allocator, memory_strategy, context, schema, null, performance_config, options);
}

/// Like production startup: the migration run is the sole DDL owner.
/// `schema_json` is the source text when the schema was parsed from JSON.
pub fn setupTestEngineWithJson(
    engine: *StorageEngine,
    allocator: std.mem.Allocator,
    memory_strategy: *const MemoryStrategy,
    context: *TestContext,
    schema: *const Schema,
    schema_json: ?[]const u8,
    performance_config: config_state.Config.PerformanceConfig,
    options: StorageEngine.Options,
) !void {
    const effective_options = normalizeTestStorageOptions(options);
    try engine.init(std.testing.io, allocator, @constCast(memory_strategy), context.test_dir, schema, performance_config, effective_options, null, null);
    errdefer engine.deinit();

    try runTestMigrations(allocator, try engine.getSetupConn(), schema, schema_json);

    context.send_queue = try send_queue_type.init(allocator);
    errdefer {
        context.send_queue.?.deinit();
        context.send_queue = null;
    }

    context.change_queue = try ChangeQueue.init(std.testing.io, allocator, 1);
    errdefer context.change_queue.?.deinit();

    try engine.start(&context.send_queue.?, &context.change_queue.?, null);
}
