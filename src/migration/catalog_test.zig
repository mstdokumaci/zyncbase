const std = @import("std");

const sqlite = @import("sqlite");

const schema_parse = @import("../schema/parse.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const schema_types = @import("../schema/types.zig");
const ddl = @import("../sql/ddl.zig");
const catalog = @import("catalog.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const allocator = std.testing.allocator;

const schema_json =
    \\{"version":"1.0.0","store":{
    \\  "parents":{"fields":{}},
    \\  "children":{"fields":{
    \\    "slug":{"type":"string"},
    \\    "parent_id":{"type":"string","references":"parents","onDelete":"cascade"}
    \\  },"required":["slug"],"unique":[["slug"]]}
    \\}}
;

const Fixture = struct {
    db: sqlite.Db,
    schema: schema_types.Schema,
    arena: std.heap.ArenaAllocator,
    diag: Diagnostics,

    fn init() !Fixture {
        var db = try sqlite.Db.init(.{ .mode = .Memory, .open_flags = .{ .write = true, .create = true } });
        errdefer db.deinit();
        var schema = try schema_parse.initFromJson(allocator, schema_json);
        errdefer schema.deinit();
        for (schema.tables) |table| {
            const sql = try schema_helpers.fullDDL(allocator, table);
            defer allocator.free(sql);
            // zwanzig-disable-next-line: sentinel-alloc
            const sql_z = try allocator.dupeZ(u8, sql);
            defer allocator.free(sql_z);
            try db.execMulti(sql_z, .{});
        }
        return .{ .db = db, .schema = schema, .arena = std.heap.ArenaAllocator.init(allocator), .diag = Diagnostics.init(allocator) };
    }

    fn deinit(self: *Fixture) void {
        self.diag.deinit();
        self.arena.deinit();
        self.schema.deinit();
        self.db.deinit();
    }

    fn check(self: *Fixture, table_name: []const u8) !catalog.Drift {
        self.diag.deinit();
        self.diag = Diagnostics.init(allocator);
        const table = self.schema.table(table_name) orelse return error.TestExpectedValue;
        return catalog.checkTable(self.arena.allocator(), &self.db, table, &self.diag);
    }

    fn exec(self: *Fixture, sql: []const u8) !void {
        try self.db.execDynamic(sql, .{}, .{});
    }

    /// Recreates `children` from `create_sql`, keeping the generated indexes.
    fn replaceChildren(self: *Fixture, create_sql: []const u8) !void {
        try self.exec("DROP TABLE children");
        try self.exec(create_sql);
        var gen = ddl.DDLGenerator.init(allocator);
        const table = self.schema.table("children") orelse return error.TestExpectedValue;
        var iter = ddl.ManagedIndexIterator.init(table);
        while (iter.next()) |managed_index| {
            const sql = try gen.generateIndexDDL(table.*, managed_index);
            defer allocator.free(sql);
            try self.exec(sql);
        }
    }
};

test "catalog: generated DDL matches its own layout" {
    var f = try Fixture.init();
    defer f.deinit();
    for (f.schema.tables) |table| {
        const drift = try f.check(table.name);
        try std.testing.expect(!drift.any());
    }
}

test "catalog: missing table and non-STRICT tables are structural drift" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.replaceChildren(
        \\CREATE TABLE children ("id" BLOB NOT NULL CHECK(length("id") = 16), "namespace_id" INTEGER NOT NULL,
        \\  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16), "slug" TEXT NOT NULL,
        \\  "parent_id" BLOB CHECK(length("parent_id") = 16), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
        \\  PRIMARY KEY ("id"), FOREIGN KEY ("parent_id") REFERENCES "parents"("id") ON DELETE CASCADE)
    );
    const drift = try f.check("children");
    try std.testing.expect(drift.not_strict and drift.isStructural());
    try std.testing.expect(!drift.columns and !drift.foreign_keys and !drift.indexes);

    try f.exec("DROP TABLE children");
    try std.testing.expect((try f.check("children")).missing);
}

test "catalog: column type, nullability, and extra columns are drift" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.exec("ALTER TABLE children ADD COLUMN extra TEXT");
    var drift = try f.check("children");
    try std.testing.expect(drift.columns);

    try f.replaceChildren(
        \\CREATE TABLE children ("id" BLOB NOT NULL CHECK(length("id") = 16), "namespace_id" INTEGER NOT NULL,
        \\  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16), "slug" TEXT,
        \\  "parent_id" BLOB CHECK(length("parent_id") = 16), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
        \\  PRIMARY KEY ("id"), FOREIGN KEY ("parent_id") REFERENCES "parents"("id") ON DELETE CASCADE) STRICT
    );
    drift = try f.check("children");
    try std.testing.expect(drift.columns and !drift.foreign_keys);

    try f.replaceChildren(
        \\CREATE TABLE children ("id" BLOB NOT NULL CHECK(length("id") = 16), "namespace_id" INTEGER NOT NULL,
        \\  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16), "slug" INTEGER NOT NULL,
        \\  "parent_id" BLOB CHECK(length("parent_id") = 16), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
        \\  PRIMARY KEY ("id"), FOREIGN KEY ("parent_id") REFERENCES "parents"("id") ON DELETE CASCADE) STRICT
    );
    drift = try f.check("children");
    try std.testing.expect(drift.columns);

    try f.replaceChildren(
        \\CREATE TABLE children ("id" BLOB NOT NULL CHECK(length("id") = 16), "namespace_id" INTEGER NOT NULL,
        \\  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16), "slug" TEXT NOT NULL,
        \\  "parent_id" BLOB CHECK(length("parent_id") = 16), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
        \\  PRIMARY KEY ("id"), FOREIGN KEY ("parent_id") REFERENCES "parents"("id") ON DELETE CASCADE) STRICT
    );
    try f.exec("ALTER TABLE children ADD COLUMN generated_slug TEXT GENERATED ALWAYS AS (\"slug\" || 'x') VIRTUAL");
    drift = try f.check("children");
    try std.testing.expect(drift.columns);
}

test "catalog: missing or different foreign keys are drift" {
    var f = try Fixture.init();
    defer f.deinit();

    try f.replaceChildren(
        \\CREATE TABLE children ("id" BLOB NOT NULL CHECK(length("id") = 16), "namespace_id" INTEGER NOT NULL,
        \\  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16), "slug" TEXT NOT NULL,
        \\  "parent_id" BLOB CHECK(length("parent_id") = 16), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
        \\  PRIMARY KEY ("id"), FOREIGN KEY ("parent_id") REFERENCES "parents"("id") ON DELETE RESTRICT) STRICT
    );
    var drift = try f.check("children");
    try std.testing.expect(drift.foreign_keys and !drift.columns);

    try f.replaceChildren(
        \\CREATE TABLE children ("id" BLOB NOT NULL CHECK(length("id") = 16), "namespace_id" INTEGER NOT NULL,
        \\  "owner_id" BLOB NOT NULL CHECK(length("owner_id") = 16), "slug" TEXT NOT NULL,
        \\  "parent_id" BLOB CHECK(length("parent_id") = 16), "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL,
        \\  PRIMARY KEY ("id")) STRICT
    );
    drift = try f.check("children");
    try std.testing.expect(drift.foreign_keys);
}

test "catalog: missing, wrong, partial, and obsolete managed indexes are index drift only" {
    const mutations = [_][]const u8{
        "DROP INDEX \"uidx__children__constraint__0\"",
        "DROP INDEX \"uidx__children__constraint__0\"; CREATE INDEX \"uidx__children__constraint__0\" ON children(namespace_id, slug)",
        "DROP INDEX \"idx__children__field__parent_id\"; CREATE INDEX \"idx__children__field__parent_id\" ON children(parent_id) WHERE parent_id IS NOT NULL",
        "DROP INDEX \"uidx__children__constraint__0\"; CREATE UNIQUE INDEX \"uidx__children__constraint__0\" ON children(slug, namespace_id)",
        "DROP INDEX \"idx__children__field__parent_id\"; CREATE INDEX \"idx__children__field__parent_id\" ON children(parent_id COLLATE NOCASE)",
        "CREATE INDEX \"idx__children__field__gone\" ON children(slug)",
    };
    for (mutations) |sql| {
        var f = try Fixture.init();
        defer f.deinit();
        // zwanzig-disable-next-line: sentinel-alloc
        const sql_z = try allocator.dupeZ(u8, sql);
        defer allocator.free(sql_z);
        try f.db.execMulti(sql_z, .{});
        const drift = try f.check("children");
        try std.testing.expect(drift.indexes);
        try std.testing.expect(!drift.isStructural());
    }

    var f = try Fixture.init();
    defer f.deinit();
    try f.exec("CREATE INDEX manual_operator_index ON children(slug)");
    try std.testing.expect(!(try f.check("children")).any());
}

test "catalog: reserved managed index names are scoped per table" {
    try std.testing.expect(catalog.isReservedManagedIndexName("idx__tasks__namespace", "tasks"));
    try std.testing.expect(catalog.isReservedManagedIndexName("uidx__tasks__constraint__0", "tasks"));
    try std.testing.expect(catalog.isReservedManagedIndexName("IDX__TASKS__NAMESPACE", "tasks"));
    try std.testing.expect(catalog.isReservedManagedIndexName("idx__TASKS__namespace", "tasks"));
    try std.testing.expect(!catalog.isReservedManagedIndexName("idx__tasks_archive__namespace", "tasks"));
    try std.testing.expect(!catalog.isReservedManagedIndexName("idx__tasks", "tasks"));
    try std.testing.expect(!catalog.isReservedManagedIndexName("manual_index", "tasks"));
}

test "catalog: shared columns include system columns and users external_id" {
    var schema = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"users":{"fields":{"a":{"type":"string"},"b":{"type":"string"}}}}}
    );
    defer schema.deinit();
    var other = try schema_parse.initFromJson(allocator,
        \\{"version":"1.0.0","store":{"users":{"fields":{"b":{"type":"string"},"c":{"type":"string"}}}}}
    );
    defer other.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const from = schema.table("users") orelse return error.TestExpectedValue;
    const to = other.table("users") orelse return error.TestExpectedValue;
    const names = try catalog.sharedColumnNames(arena.allocator(), from, to);
    const expected = [_][]const u8{ "id", "namespace_id", "owner_id", "external_id", "b", "created_at", "updated_at" };
    try std.testing.expectEqual(expected.len, names.len);
    for (expected, names) |e, n| try std.testing.expectEqualStrings(e, n);
}
