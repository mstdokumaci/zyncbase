// Feature: schema-aware-storage
// Property tests 13–18 for typed SQL methods on StorageEngine.
const std = @import("std");
const testing = std.testing;
const sqlite = @import("sqlite");
const schema_parser = @import("schema_parser.zig");
const ddl_generator = @import("ddl_generator.zig");
const storage_engine = @import("storage_engine.zig");
const StorageEngine = storage_engine.StorageEngine;
const ColumnValue = storage_engine.ColumnValue;
const StorageError = storage_engine.StorageError;
const msgpack = @import("msgpack_utils.zig");

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn makeField(name: []const u8, sql_type: schema_parser.FieldType, required: bool) schema_parser.Field {
    return .{
        .name = name,
        .sql_type = sql_type,
        .required = required,
        .indexed = false,
        .references = null,
        .on_delete = null,
    };
}

/// Build a minimal Schema with one table containing the given fields.
fn makeSchema(allocator: std.mem.Allocator, table_name: []const u8, fields: []const schema_parser.Field) !schema_parser.Schema {
    const owned_fields = try allocator.dupe(schema_parser.Field, fields);
    for (owned_fields, 0..) |_, i| {
        owned_fields[i].name = try allocator.dupe(u8, fields[i].name);
    }
    const tables = try allocator.alloc(schema_parser.Table, 1);
    tables[0] = .{
        .name = try allocator.dupe(u8, table_name),
        .fields = owned_fields,
    };
    return schema_parser.Schema{
        .version = try allocator.dupe(u8, "1.0.0"),
        .tables = tables,
    };
}

fn freeSchema(allocator: std.mem.Allocator, schema: schema_parser.Schema) void {
    allocator.free(schema.version);
    for (schema.tables) |t| {
        allocator.free(t.name);
        for (t.fields) |f| allocator.free(f.name);
        allocator.free(t.fields);
    }
    allocator.free(schema.tables);
}

/// Create a StorageEngine in a temp dir and apply DDL for the given table.
fn setupEngine(allocator: std.mem.Allocator, test_dir: []const u8, table: schema_parser.Table) !*StorageEngine {
    const engine = try StorageEngine.init(allocator, test_dir);

    // Apply DDL for the table using the writer connection
    var gen = ddl_generator.DDLGenerator.init(allocator);
    const ddl = try gen.generateDDL(table);
    defer allocator.free(ddl);

    const ddl_z = try allocator.dupeZ(u8, ddl);
    defer allocator.free(ddl_z);
    try engine.writer_conn.execMulti(ddl_z, .{});

    return engine;
}

// ─── Property 13: Document set/get round-trip ────────────────────────────────

// Feature: schema-aware-storage, Property 13: Document set/get round-trip
// For any table/id/namespace/object triple (keys are valid column names), performing
// insertOrReplace followed by selectDocument SHALL return a map equal to the original
// object (plus system columns id, namespace_id, created_at, updated_at).
// Validates: Requirements 5.1, 5.3
test "storage_engine_typed: property 13 - document set/get round-trip" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
    const rand = prng.random();

    const scalar_values = [_][]const u8{ "hello", "world", "foo", "bar", "baz" };

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/typed_prop/p13_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        var fields_arr = [_]schema_parser.Field{
            makeField("title", .text, false),
            makeField("score", .integer, false),
        };
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        const engine = try setupEngine(allocator, test_dir, table);
        defer engine.deinit();

        const id = "doc-001";
        const ns = "ns-test";
        const title_idx = rand.intRangeAtMost(usize, 0, scalar_values.len - 1);
        const title_str = scalar_values[title_idx];
        const score_val: i64 = rand.intRangeAtMost(i64, 0, 9999);

        const title_payload = try msgpack.Payload.strToPayload(title_str, allocator);
        defer title_payload.free(allocator);

        const cols = [_]ColumnValue{
            .{ .name = "title", .value = title_payload },
            .{ .name = "score", .value = msgpack.Payload.intToPayload(score_val) },
        };

        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();

        const result = try engine.selectDocument("items", id, ns);
        try testing.expect(result != null);
        defer result.?.free(allocator);

        // Verify title and score are present
        const got_title = try result.?.mapGet("title");
        try testing.expect(got_title != null);
        try testing.expectEqualStrings(title_str, got_title.?.str.value());

        const got_score = try result.?.mapGet("score");
        try testing.expect(got_score != null);
        // Score may come back as int or uint depending on msgpack encoding
        const got_score_val: i64 = switch (got_score.?) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expectEqual(score_val, got_score_val);

        // System columns must be present
        try testing.expect((try result.?.mapGet("id")) != null);
        try testing.expect((try result.?.mapGet("namespace_id")) != null);
        try testing.expect((try result.?.mapGet("created_at")) != null);
        try testing.expect((try result.?.mapGet("updated_at")) != null);
    }
}

// ─── Property 14: Field set/get round-trip ───────────────────────────────────

// Feature: schema-aware-storage, Property 14: Field set/get round-trip
// For any table/id/namespace/field/scalar tuple, performing updateField followed by
// selectField SHALL return the original scalar; all other columns unchanged.
// Validates: Requirements 5.2, 5.4
test "storage_engine_typed: property 14 - field set/get round-trip" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xCAFE_BABE);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/typed_prop/p14_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        var fields_arr = [_]schema_parser.Field{
            makeField("title", .text, false),
            makeField("score", .integer, false),
        };
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        const engine = try setupEngine(allocator, test_dir, table);
        defer engine.deinit();

        const id = "doc-001";
        const ns = "ns-test";

        // Insert initial document
        const initial_title = try msgpack.Payload.strToPayload("initial", allocator);
        defer initial_title.free(allocator);
        const initial_cols = [_]ColumnValue{
            .{ .name = "title", .value = initial_title },
            .{ .name = "score", .value = msgpack.Payload.intToPayload(0) },
        };
        try engine.insertOrReplace("items", id, ns, &initial_cols);
        try engine.flushPendingWrites();

        // Update score field
        const new_score: i64 = rand.intRangeAtMost(i64, 1, 9999);
        try engine.updateField("items", id, ns, "score", msgpack.Payload.intToPayload(new_score));
        try engine.flushPendingWrites();

        // selectField should return the new score
        const got = try engine.selectField("items", id, ns, "score");
        try testing.expect(got != null);
        defer got.?.free(allocator);
        const got_score_val: i64 = switch (got.?) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expectEqual(new_score, got_score_val);

        // title should be unchanged
        const doc = try engine.selectDocument("items", id, ns);
        try testing.expect(doc != null);
        defer doc.?.free(allocator);
        const got_title = try doc.?.mapGet("title");
        try testing.expect(got_title != null);
        try testing.expectEqualStrings("initial", got_title.?.str.value());
    }
}

// ─── Property 15: Collection get is namespace-scoped ─────────────────────────

// Feature: schema-aware-storage, Property 15: Collection get is namespace-scoped
// For any namespace ns and set of documents inserted under ns, selectCollection for ns
// SHALL return exactly those documents and SHALL NOT return documents from another namespace.
// Validates: Requirements 5.5
test "storage_engine_typed: property 15 - collection get is namespace-scoped" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xBEEF_CAFE);
    const rand = prng.random();

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/typed_prop/p15_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        const engine = try setupEngine(allocator, test_dir, table);
        defer engine.deinit();

        const ns_a = "ns-alpha";
        const ns_b = "ns-beta";
        const count_a = rand.intRangeAtMost(usize, 1, 5);
        const count_b = rand.intRangeAtMost(usize, 1, 5);

        // Insert count_a docs under ns_a
        var i: usize = 0;
        while (i < count_a) : (i += 1) {
            const id = try std.fmt.allocPrint(allocator, "a-{}", .{i});
            defer allocator.free(id);
            const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(@intCast(i)) }};
            try engine.insertOrReplace("items", id, ns_a, &cols);
        }

        // Insert count_b docs under ns_b
        i = 0;
        while (i < count_b) : (i += 1) {
            const id = try std.fmt.allocPrint(allocator, "b-{}", .{i});
            defer allocator.free(id);
            const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(@intCast(i + 100)) }};
            try engine.insertOrReplace("items", id, ns_b, &cols);
        }

        try engine.flushPendingWrites();

        // selectCollection for ns_a should return exactly count_a docs
        const coll_a = try engine.selectCollection("items", ns_a);
        defer coll_a.free(allocator);
        try testing.expectEqual(count_a, coll_a.arr.len);

        // selectCollection for ns_b should return exactly count_b docs
        const coll_b = try engine.selectCollection("items", ns_b);
        defer coll_b.free(allocator);
        try testing.expectEqual(count_b, coll_b.arr.len);
    }
}

// ─── Property 16: Remove then get returns null ────────────────────────────────

// Feature: schema-aware-storage, Property 16: Remove then get returns null
// For any table/id/namespace triple, after insertOrReplace followed by deleteDocument,
// selectDocument SHALL return null.
// Validates: Requirements 5.6
test "storage_engine_typed: property 16 - remove then get returns null" {
    const allocator = testing.allocator;

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/typed_prop/p16_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        const engine = try setupEngine(allocator, test_dir, table);
        defer engine.deinit();

        const id = "doc-001";
        const ns = "ns-test";

        const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(42) }};
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();

        // Verify it exists
        const before = try engine.selectDocument("items", id, ns);
        try testing.expect(before != null);
        before.?.free(allocator);

        // Delete it
        try engine.deleteDocument("items", id, ns);
        try engine.flushPendingWrites();

        // Should be null now
        const after = try engine.selectDocument("items", id, ns);
        try testing.expect(after == null);
    }
}

// ─── Property 17: Schema validation rejects unknown tables and fields ─────────

// Feature: schema-aware-storage, Property 17: Schema validation rejects unknown tables and fields
// For any storage operation referencing a table or field not in the loaded schema,
// the StorageEngine SHALL return a SCHEMA_VALIDATION_FAILED error before any SQL is executed.
// Validates: Requirements 5.7, 5.8, 5.9
test "storage_engine_typed: property 17 - schema validation rejects unknown tables and fields" {
    const allocator = testing.allocator;

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/typed_prop/p17_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        var fields_arr = [_]schema_parser.Field{makeField("title", .text, false)};
        const schema = try makeSchema(allocator, "items", &fields_arr);
        defer freeSchema(allocator, schema);

        var fields_arr2 = [_]schema_parser.Field{makeField("title", .text, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr2 };

        const engine = try setupEngine(allocator, test_dir, table);
        defer engine.deinit();
        engine.schema = &schema;

        // Unknown table → UnknownTable
        const cols = [_]ColumnValue{.{ .name = "title", .value = msgpack.Payload.intToPayload(1) }};
        const err1 = engine.insertOrReplace("nonexistent_table", "id1", "ns", &cols);
        try testing.expectError(StorageError.UnknownTable, err1);

        // Unknown field → UnknownField
        const bad_cols = [_]ColumnValue{.{ .name = "nonexistent_field", .value = msgpack.Payload.intToPayload(1) }};
        const err2 = engine.insertOrReplace("items", "id1", "ns", &bad_cols);
        try testing.expectError(StorageError.UnknownField, err2);

        // Unknown field in updateField → UnknownField
        const err3 = engine.updateField("items", "id1", "ns", "nonexistent_field", msgpack.Payload.intToPayload(1));
        try testing.expectError(StorageError.UnknownField, err3);

        // Unknown table in selectDocument → UnknownTable
        const err4 = engine.selectDocument("nonexistent_table", "id1", "ns");
        try testing.expectError(StorageError.UnknownTable, err4);

        // Unknown table in selectCollection → UnknownTable
        const err5 = engine.selectCollection("nonexistent_table", "ns");
        try testing.expectError(StorageError.UnknownTable, err5);

        // Unknown table in deleteDocument → UnknownTable
        const err6 = engine.deleteDocument("nonexistent_table", "id1", "ns");
        try testing.expectError(StorageError.UnknownTable, err6);
    }
}

// ─── Property 18: updated_at is always refreshed on write ────────────────────

// Feature: schema-aware-storage, Property 18: updated_at is always refreshed on write
// For any row, after any insertOrReplace or updateField operation, updated_at SHALL be
// >= the Unix timestamp recorded immediately before the operation, and created_at SHALL
// remain unchanged on subsequent updates.
// Validates: Requirements 5.10, 5.11
test "storage_engine_typed: property 18 - updated_at is always refreshed on write" {
    const allocator = testing.allocator;

    var iter: usize = 0;
    while (iter < 100) : (iter += 1) {
        const test_dir = try std.fmt.allocPrint(allocator, "test-artifacts/typed_prop/p18_{}", .{iter});
        defer allocator.free(test_dir);
        defer std.fs.cwd().deleteTree(test_dir) catch {};

        var fields_arr = [_]schema_parser.Field{makeField("val", .integer, false)};
        const table = schema_parser.Table{ .name = "items", .fields = &fields_arr };

        const engine = try setupEngine(allocator, test_dir, table);
        defer engine.deinit();

        const id = "doc-001";
        const ns = "ns-test";

        const t_before_insert = std.time.timestamp();
        const cols = [_]ColumnValue{.{ .name = "val", .value = msgpack.Payload.intToPayload(1) }};
        try engine.insertOrReplace("items", id, ns, &cols);
        try engine.flushPendingWrites();

        const doc1 = try engine.selectDocument("items", id, ns);
        try testing.expect(doc1 != null);
        defer doc1.?.free(allocator);

        const created_at_1_payload = (try doc1.?.mapGet("created_at")).?;
        const updated_at_1_payload = (try doc1.?.mapGet("updated_at")).?;
        const created_at_1: i64 = switch (created_at_1_payload) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        const updated_at_1: i64 = switch (updated_at_1_payload) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        try testing.expect(updated_at_1 >= t_before_insert);
        try testing.expect(created_at_1 >= t_before_insert);

        // Small sleep to ensure timestamp can advance
        std.Thread.sleep(10 * std.time.ns_per_ms);

        // Update the field
        const t_before_update = std.time.timestamp();
        try engine.updateField("items", id, ns, "val", msgpack.Payload.intToPayload(2));
        try engine.flushPendingWrites();

        const doc2 = try engine.selectDocument("items", id, ns);
        try testing.expect(doc2 != null);
        defer doc2.?.free(allocator);

        const created_at_2_payload = (try doc2.?.mapGet("created_at")).?;
        const updated_at_2_payload = (try doc2.?.mapGet("updated_at")).?;
        const created_at_2: i64 = switch (created_at_2_payload) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };
        const updated_at_2: i64 = switch (updated_at_2_payload) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => return error.UnexpectedType,
        };

        // updated_at must be >= t_before_update
        try testing.expect(updated_at_2 >= t_before_update);
        // created_at must be unchanged
        try testing.expectEqual(created_at_1, created_at_2);
    }
}
