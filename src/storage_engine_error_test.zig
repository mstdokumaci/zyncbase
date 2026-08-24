const std = @import("std");

const sqlite = @import("sqlite");

const schema_helpers = @import("schema/test_helpers.zig");
const schema_types = @import("schema/types.zig");
// ─── User-defined unique constraint enforcement ──────────────────────────────
const st_errors = @import("storage_engine/errors.zig");
const sth = @import("storage_engine_test_helpers.zig");
const typed_doc_id = @import("typed/doc_id.zig");
const tth = @import("typed/test_helpers.zig");

const testing = std.testing;
const StorageEngine = sth.StorageEngine;

// This property test verifies that database operations handle errors gracefully:
// 1. All database operation failures return descriptive errors
// 2. All database errors are logged with full details
// 3. No panics or crashes occur on database errors

test "storage: error handling invalid database path" {
    const allocator = std.heap.smp_allocator;

    // Try to create storage engine with invalid path
    var schema = try sth.createSchema(allocator, &.{
        schema_helpers.makeTable("_dummy", &.{schema_helpers.makeField("val", .text)}),
        schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)}),
    });
    defer schema.deinit();

    var ms: sth.MemoryStrategy = undefined;
    try ms.init();
    defer ms.deinit();

    var storage: StorageEngine = undefined;
    // /proc cannot be created into even as root, so this fails identically in CI,
    // Docker, and local development regardless of privileges.
    const result = storage.init(std.testing.io, allocator, &ms, "/proc/zyncbase-invalid/nonexistent/path", &schema, .{}, .{ .in_memory = false }, null, null);
    // Verify we get an error
    if (result) |_| {
        storage.deinit();
        return error.ExpectedError;
    } else |err| {
        switch (err) {
            error.FileNotFound, error.ReadOnlyFileSystem, error.AccessDenied, error.PermissionDenied, error.InvalidDataDir => {},
            else => return err,
        }
    }
}
test "storage: write/flush/read round-trip on file-backed engine" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-roundtrip", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    // Try to set a value
    {
        try ctx.insertText("data_table", 1, 1, "val", "value1");
    }
    try storage.flushPendingWrites();
    // Verify we can read it back
    {
        var doc = try tbl.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "value1");
    }
}
test "storage: error handling constraint violations" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-constraints", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    // Set a value
    {
        try ctx.insertText("data_table", 1, 1, "val", "value1");
    }
    try storage.flushPendingWrites();
    // Update the same key (this should work with UPSERT)
    {
        try ctx.insertText("data_table", 1, 1, "val", "value2");
    }
    try storage.flushPendingWrites();
    // Verify the value was updated
    {
        var doc = try tbl.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "value2");
    }
}
test "storage: error handling concurrent access safety" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-concurrent", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;

    {
        try ctx.insertText("data_table", 1, 1, "val", "value1");
    }
    try storage.flushPendingWrites();
    const ThreadContext = struct {
        storage: *StorageEngine,
        allocator: std.mem.Allocator,
    };
    const ThreadResult = struct {
        outcome: ?anyerror = null,
    };
    const runRead = struct {
        fn run(t_ctx: ThreadContext, table_index: usize, result: *ThreadResult) void {
            runErr(t_ctx, table_index) catch |err| { // zwanzig-disable-line: swallowed-error
                result.outcome = err;
            };
        }
        fn runErr(t_ctx: ThreadContext, table_index: usize) !void {
            const record = try sth.readDoc(t_ctx.allocator, t_ctx.storage, table_index, 1, 1);
            try testing.expect(record != null);
            defer if (record) |r| r.deinit(t_ctx.allocator);
        }
    }.run;
    var threads: [4]std.Thread = undefined;
    var results = [_]ThreadResult{.{}} ** 4;
    const tbl_md = ctx.schema.table("data_table") orelse return error.UnknownTable;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |t| t.join();
    for (&threads, &results) |*t, *result| {
        t.* = try std.Thread.spawn(.{}, runRead, .{ ThreadContext{ .storage = storage, .allocator = allocator }, tbl_md.index, result });
        spawned += 1;
    }
    for (threads) |t| t.join();
    for (results) |result| try testing.expect(result.outcome == null);
}
test "storage: write/flush/read round-trip with empty value" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-empty", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    try ctx.insertText("data_table", 1, 1, "val", "");
    try storage.flushPendingWrites();
    {
        var doc = try tbl.getOne(allocator, 1, 1);
        defer doc.deinit();
        _ = try doc.expectFieldString("val", "");
    }
}
test "storage: error handling large values" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-large", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    const large_value = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(large_value);
    @memset(large_value, 'A');
    {
        try ctx.insertText("data_table", 1, 1, "val", large_value);
    }
    try storage.flushPendingWrites();
    {
        const record = try tbl.readDoc(allocator, 1, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
}
test "storage: error handling delete non-existent key" {
    const allocator = std.heap.smp_allocator;
    const table = schema_helpers.makeTable("data_table", &.{schema_helpers.makeField("val", .text)});
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngineWithOptions(&ctx, allocator, "storage-error-delete", table, .{ .in_memory = false });
    defer ctx.deinit();
    const storage = &ctx.engine;
    const tbl = try ctx.table("data_table");

    try tbl.deleteDocument(999, 1);
    try storage.flushPendingWrites();
    {
        const record = try tbl.readDoc(allocator, 999, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record == null);
    }
}

test "storage: extended errcode classifies real unique collision as UniqueConstraintViolation" {
    var db = try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
    defer db.deinit();

    try db.execMulti(
        "CREATE TABLE projects (id BLOB NOT NULL, namespace_id INTEGER NOT NULL, slug TEXT, PRIMARY KEY(id));" ++
            "CREATE UNIQUE INDEX \"uidx_projects_0\" ON \"projects\"(\"namespace_id\", \"slug\")",
        .{},
    );

    try db.exec("INSERT INTO projects VALUES (zeroblob(16), 1, 'dup')", .{}, .{});

    // Step the duplicate insert through the raw C API so expected constraint
    // failures stay silent; then classify from the connection's error state.
    const dup_sql = "INSERT INTO projects VALUES (randomblob(16), 1, 'dup')";
    var stmt: ?*sqlite.c.sqlite3_stmt = null;
    try testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_prepare_v2(db.db, dup_sql.ptr, @intCast(dup_sql.len), &stmt, null));
    _ = sqlite.c.sqlite3_step(stmt);
    _ = sqlite.c.sqlite3_finalize(stmt);
    try testing.expectEqual(error.UniqueConstraintViolation, st_errors.classifyStepError(&db));

    // Foreign-key failures remain the generic ConstraintViolation.
    var fk_db = try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
    defer fk_db.deinit();
    _ = try fk_db.pragma(void, .{}, "foreign_keys", "on");
    try fk_db.execMulti(
        "CREATE TABLE parents (id BLOB NOT NULL PRIMARY KEY);" ++
            "CREATE TABLE children (id BLOB NOT NULL PRIMARY KEY, parent_id BLOB NOT NULL REFERENCES parents(id))",
        .{},
    );
    const orphan_sql = "INSERT INTO children VALUES (randomblob(16), randomblob(16))";
    var orphan_stmt: ?*sqlite.c.sqlite3_stmt = null;
    try testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_prepare_v2(fk_db.db, orphan_sql.ptr, @intCast(orphan_sql.len), &orphan_stmt, null));
    _ = sqlite.c.sqlite3_step(orphan_stmt);
    _ = sqlite.c.sqlite3_finalize(orphan_stmt);
    try testing.expectEqual(error.ConstraintViolation, st_errors.classifyStepError(&fk_db));
}

// ponytail: static fixture slices must outlive buildRuntimeTable's clone.
const unique_project_fields = [_]schema_types.Field{
    schema_helpers.makeField("slug", .text),
    schema_helpers.makeField("provider", .text),
    schema_helpers.makeField("external_id", .text),
};
const unique_project_constraints = [_]schema_types.UniqueConstraint{
    .{ .field_indexes = &.{0} },
    .{ .field_indexes = &.{ 1, 2 } },
};

fn uniqueProjectsTable() schema_types.Table {
    var table = schema_helpers.makeTable("projects", &unique_project_fields);
    table.unique_constraints = &unique_project_constraints;
    return table;
}

// ponytail: static fixture slices must outlive buildRuntimeTable's clone.
const global_code_fields = [_]schema_types.Field{schema_helpers.makeField("code", .text)};
const global_code_constraints = [_]schema_types.UniqueConstraint{.{ .field_indexes = &.{0} }};

fn globalCodesTable() schema_types.Table {
    var table = schema_helpers.makeTable("global_codes", &global_code_fields);
    table.namespaced = false;
    table.unique_constraints = &global_code_constraints;
    return table;
}

const member_fields = [_]schema_types.Field{
    schema_helpers.makeField("handle", .text),
    schema_helpers.makeField("region", .text),
    schema_helpers.makeField("ext", .text),
};
const member_constraints = [_]schema_types.UniqueConstraint{
    .{ .field_indexes = &.{0} },
    .{ .field_indexes = &.{ 1, 2 } },
};

fn membersTable() schema_types.Table {
    var table = schema_helpers.makeTable("members", &member_fields);
    table.unique_constraints = &member_constraints;
    return table;
}

test "storage: same unique key in one namespace fails across namespace succeeds" {
    const allocator = std.heap.smp_allocator;
    var ctx: sth.EngineTestContext = undefined;
    try ctx.initWithOptions(allocator, "unique-namespace-scoping", &.{uniqueProjectsTable()}, .{ .in_memory = true });
    defer ctx.deinit();

    const id_a: typed_doc_id.DocId = 1;
    const id_b: typed_doc_id.DocId = 2;

    try ctx.insertText("projects", id_a, 1, "slug", "alpha");
    try ctx.engine.flushPendingWrites();

    // Same slug, same namespace → write aborts; row absent.
    try ctx.insertText("projects", id_b, 1, "slug", "alpha");
    try ctx.engine.flushPendingWrites();
    {
        const record = try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("projects"), id_b, 1);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record == null);
    }

    // Same slug, different namespace → both rows coexist.
    try ctx.insertText("projects", id_b, 2, "slug", "alpha");
    try ctx.engine.flushPendingWrites();
    {
        const record = try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("projects"), id_b, 2);
        defer if (record) |r| r.deinit(allocator);
        try testing.expect(record != null);
    }
}

test "storage: compound key rejects only complete tuple matches" {
    const allocator = std.heap.smp_allocator;
    var ctx: sth.EngineTestContext = undefined;
    try ctx.initWithOptions(allocator, "unique-compound-tuple", &.{uniqueProjectsTable()}, .{ .in_memory = true });
    defer ctx.deinit();

    const id_a: typed_doc_id.DocId = 1;
    const id_b: typed_doc_id.DocId = 2;
    const id_c: typed_doc_id.DocId = 3;

    try ctx.insertNamed("projects", id_a, 1, .{
        sth.named("provider", tth.valText("github")),
        sth.named("external_id", tth.valText("42")),
    });
    try ctx.engine.flushPendingWrites();

    // Same provider, different external_id → allowed.
    try ctx.insertNamed("projects", id_b, 1, .{
        sth.named("provider", tth.valText("github")),
        sth.named("external_id", tth.valText("43")),
    });
    try ctx.engine.flushPendingWrites();
    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("projects"), id_b, 1)) != null);

    // Complete tuple match → rejected.
    try ctx.insertNamed("projects", id_c, 1, .{
        sth.named("provider", tth.valText("github")),
        sth.named("external_id", tth.valText("42")),
    });
    try ctx.engine.flushPendingWrites();
    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("projects"), id_c, 1)) == null);
}

test "storage: non-namespaced unique key is globally enforced" {
    const allocator = std.heap.smp_allocator;
    const table = globalCodesTable();

    var ctx: sth.EngineTestContext = undefined;
    try ctx.initWithOptions(allocator, "unique-global-table", &.{table}, .{ .in_memory = true });
    defer ctx.deinit();

    const id_a: typed_doc_id.DocId = 1;
    const id_b: typed_doc_id.DocId = 2;

    try ctx.insertText("global_codes", id_a, 7, "code", "one"); // namespace ignored for global tables
    try ctx.engine.flushPendingWrites();

    // Different requested namespace still maps to global namespace 0 → duplicate fails.
    try ctx.insertText("global_codes", id_b, 9, "code", "one");
    try ctx.engine.flushPendingWrites();
    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("global_codes"), id_b, 7)) == null);
}

test "storage: update into another row's key fails and leaves both rows unchanged" {
    const allocator = std.heap.smp_allocator;
    var ctx: sth.EngineTestContext = undefined;
    try ctx.initWithOptions(allocator, "unique-update-collision", &.{uniqueProjectsTable()}, .{ .in_memory = true });
    defer ctx.deinit();

    const id_a: typed_doc_id.DocId = 1;
    const id_b: typed_doc_id.DocId = 2;
    const tbl = try ctx.table("projects");

    try ctx.insertText("projects", id_a, 1, "slug", "first");
    try ctx.insertText("projects", id_b, 1, "slug", "second");
    try ctx.engine.flushPendingWrites();

    // Update b into a's key → whole batch rolls back.
    try sth.enqueueUpdate(&ctx.engine, ctx.tableIndex("projects"), id_b, 1, &.{
        .{ .index = try tbl.fieldIndex("slug"), .value = tth.valText("first") },
    }, null, null, null);
    try ctx.engine.flushPendingWrites();

    var doc_a = try tbl.getOne(allocator, id_a, 1);
    defer doc_a.deinit();
    _ = try doc_a.expectFieldString("slug", "first");
    var doc_b = try tbl.getOne(allocator, id_b, 1);
    defer doc_b.deinit();
    _ = try doc_b.expectFieldString("slug", "second");
}

test "storage: multiple null constrained values succeed" {
    const allocator = std.heap.smp_allocator;

    // Single optional field + compound with an optional component.
    const table = membersTable();

    var ctx: sth.EngineTestContext = undefined;
    try ctx.initWithOptions(allocator, "unique-null-semantics", &.{table}, .{ .in_memory = true });
    defer ctx.deinit();

    const id_a: typed_doc_id.DocId = 1;
    const id_b: typed_doc_id.DocId = 2;
    const id_c: typed_doc_id.DocId = 3;

    // Omitted single-field value stores NULL twice without conflict.
    try ctx.insertNamed("members", id_a, 1, .{});
    try ctx.insertNamed("members", id_b, 1, .{});
    try ctx.engine.flushPendingWrites();
    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("members"), id_a, 1)) != null);
    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("members"), id_b, 1)) != null);

    // Compound with one NULL component never collides.
    try ctx.insertNamed("members", id_c, 1, .{
        sth.named("region", tth.valText("eu")),
        sth.named("ext", tth.valNil()),
    });
    try ctx.engine.flushPendingWrites();

    const id_d: typed_doc_id.DocId = 4;
    try ctx.insertNamed("members", id_d, 1, .{
        sth.named("region", tth.valText("eu")),
        sth.named("ext", tth.valNil()),
    });
    try ctx.engine.flushPendingWrites();
    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("members"), id_d, 1)) != null);
}

test "storage: failed atomic batch leaves no partial writes" {
    const allocator = std.heap.smp_allocator;
    var ctx: sth.EngineTestContext = undefined;
    try ctx.initWithOptions(allocator, "unique-atomic-batch", &.{uniqueProjectsTable()}, .{ .in_memory = true });
    defer ctx.deinit();

    const id_ok: typed_doc_id.DocId = 1;
    const id_dup: typed_doc_id.DocId = 2;

    // Both ops enter the same batch; the second violates uniqueness so the
    // transaction must roll back both writes.
    try ctx.insertText("projects", id_ok, 1, "slug", "batch-ok");
    try ctx.insertText("projects", id_dup, 1, "slug", "batch-ok");
    try ctx.engine.flushPendingWrites();

    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("projects"), id_ok, 1)) == null);
    try testing.expect((try sth.readDoc(allocator, &ctx.engine, ctx.tableIndex("projects"), id_dup, 1)) == null);
}
