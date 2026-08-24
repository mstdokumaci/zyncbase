const std = @import("std");

const sqlite = @import("sqlite");

const schema_helpers = @import("schema/test_helpers.zig");
const ZyncBaseServer = @import("server.zig").ZyncBaseServer;

const testing = std.testing;

// For any initialized component, calling init() then deinit() should leave no memory leaks
// and allow re-initialization.
//
// This property test verifies that:
// 1. ZyncBaseServer can be initialized and deinitialized multiple times
// 2. No memory leaks occur during init/deinit cycles
// 3. Each init/deinit cycle is independent and doesn't affect subsequent cycles
test "server: initialization is idempotent" {
    // Use DebugAllocator to detect memory leaks
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
            @panic("Memory leak in init/deinit cycle");
        }
    }
    const allocator = gpa.allocator();

    var context = try schema_helpers.TestContext.init(allocator, "server-init");
    defer context.deinit();

    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "test_data_idempotence" });
    defer allocator.free(data_dir);

    // Create a valid test fixture in the test artifacts directory
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "schema.json" });
    defer allocator.free(schema_file_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_file_path,
        .data =
        \\{"version":"1.0.0","store":{"test":{"fields":{"val":{"type":"string"}}}}}
        ,
    });

    // Property: Multiple init/deinit cycles should not leak memory
    const num_cycles = 2;
    for (0..num_cycles) |_| {
        // Initialize server with unique data directory and custom schema path
        // The block scope ensures deinit runs before the next cycle re-creates
        // the data directory (deleteTree after the block).
        {
            const server = try ZyncBaseServer.initDetailed(std.testing.io, std.testing.environ, allocator, null, data_dir, schema_file_path, null);
            defer server.deinit();

            // Verify server is properly initialized
            try testing.expect(server.schema.tables.len > 0);
            const loaded_data_dir = server.config.data_dir;
            try testing.expectEqualStrings(data_dir, loaded_data_dir);

            // Verify shutdown flag is initialized to false
            try testing.expect(!server.shutdown_requested.load(.acquire));
        }

        // Clean up database file between cycles
        std.Io.Dir.cwd().deleteTree(std.testing.io, data_dir) catch {}; // zwanzig-disable-line: empty-catch-engine
    }

    // If we reach here without panicking, the property holds
    // GPA will verify no memory leaks in the defer block
}

test "server: fresh startup creates schema through migration execution and persists version" {
    const allocator = std.testing.allocator;

    var context = try schema_helpers.TestContext.init(allocator, "server-fresh-startup");
    defer context.deinit();

    const data_dir = try std.fs.path.join(allocator, &.{ context.test_dir, "fresh_data" });
    defer allocator.free(data_dir);

    // Schema with unique constraints: fresh DB must be built entirely by the
    // detector/executor path, installing tables AND managed indexes.
    const schema_file_path = try std.fs.path.join(allocator, &.{ context.test_dir, "schema-unique.json" });
    defer allocator.free(schema_file_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = schema_file_path,
        .data =
        \\{"version":"1.1.0","store":{"projects":{
        \\  "required":["slug"],
        \\  "fields":{"slug":{"type":"string"},"provider":{"type":"string"},"externalId":{"type":"string"}},
        \\  "unique":[["slug"],["provider","externalId"]]
        \\}}}
        ,
    });

    {
        const server = try ZyncBaseServer.initDetailed(std.testing.io, std.testing.environ, allocator, null, data_dir, schema_file_path, null);
        server.deinit();
    }

    // Inspect the resulting database file.
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/zyncbase.db", .{data_dir}, 0);
    defer allocator.free(db_path);
    var db = try sqlite.Db.init(.{ .mode = .{ .File = db_path }, .open_flags = .{ .write = true, .create = true } });
    defer db.deinit();

    // Tables exist.
    const table_count = try db.one(i64, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='projects'", .{}, .{});
    try testing.expectEqual(@as(?i64, 1), table_count);

    // Managed unique indexes exist with namespace_id as first column.
    {
        var stmt = try db.prepare("SELECT name FROM pragma_index_list('projects') WHERE \"unique\"=1 ORDER BY name");
        defer stmt.deinit();
        const Row = struct { name: []const u8 };
        var iter = try stmt.iteratorAlloc(Row, allocator, .{});
        var found_uidx = false;
        while (try iter.nextAlloc(allocator, .{})) |row| {
            defer allocator.free(row.name);
            if (std.mem.startsWith(u8, row.name, "uidx_projects_")) {
                found_uidx = true;
                const info_sql = try std.fmt.allocPrint(allocator, "SELECT name FROM pragma_index_info('{s}') ORDER BY seqno LIMIT 1", .{row.name});
                defer allocator.free(info_sql);
                const first_col = try db.oneDynamicAlloc([]const u8, allocator, info_sql, .{}, .{});
                try testing.expect(first_col != null);
                defer allocator.free(first_col.?);
                try testing.expectEqualStrings("namespace_id", first_col.?);
            }
        }
        try testing.expect(found_uidx);
    }

    // Schema version persisted through the executor's empty/non-empty plan path.
    const VersionRow = struct { version: []const u8 };
    {
        var stmt = try db.prepare("SELECT version FROM schema_meta LIMIT 1");
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(VersionRow, allocator, .{});
        const row = (try iter.nextAlloc(allocator, .{})) orelse return error.TestExpectedValue;
        defer allocator.free(row.version);
        try testing.expectEqualStrings("1.1.0", row.version);
    }
}
