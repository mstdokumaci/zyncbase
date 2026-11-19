const std = @import("std");

const schema_diff = @import("diff.zig");
const schema_parse = @import("parse.zig");
const schema_types = @import("types.zig");

const allocator = std.testing.allocator;
const Bucket = schema_diff.Bucket;
const FieldChangeKind = schema_diff.FieldChangeKind;
const TableAction = schema_diff.TableAction;
const TableChangeKind = schema_diff.TableChangeKind;

fn parse(json: []const u8) !schema_types.Schema {
    return schema_parse.initFromJson(allocator, json);
}

fn wrap(comptime version: []const u8, comptime tasks: []const u8) []const u8 {
    return "{\"version\":\"" ++ version ++ "\",\"store\":{\"users\":{\"fields\":{}},\"projects\":{\"fields\":{\"name\":{\"type\":\"string\"}}},\"tasks\":" ++ tasks ++ "}}";
}

fn tableOf(d: *const schema_diff.SchemaDiff, name: []const u8) ?*const schema_diff.TableDiff {
    for (d.tables) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn hasPhysicalChanges(d: *const schema_diff.SchemaDiff) bool {
    for (d.tables) |t| {
        if (t.action != .unchanged or t.indexes_changed) return true;
    }
    return false;
}

const base_tasks =
    \\{"fields":{
    \\  "title":{"type":"string","minLength":1,"maxLength":100},
    \\  "status":{"type":"string","enum":["open","done"]},
    \\  "priority":{"type":"integer","minimum":0,"maximum":10},
    \\  "tags":{"type":"array","items":"string"},
    \\  "project_id":{"type":"string","references":"projects"},
    \\  "flag":{"type":"boolean","indexed":true}
    \\},"required":["title"],"unique":[["title"]]}
;

const FieldCase = struct {
    name: []const u8,
    tasks: []const u8,
    field: []const u8,
    kind: FieldChangeKind,
    action: TableAction,
    bucket: Bucket,
};

const field_cases = [_]FieldCase{
    .{ .name = "add optional", .field = "notes", .kind = .added_optional, .action = .alter, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true},"notes":{"type":"string"}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "add optional reference", .field = "owner", .kind = .added_optional, .action = .alter, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true},"owner":{"type":"string","references":"users"}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "add required", .field = "slug", .kind = .added_required, .action = .rebuild, .bucket = .checked, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true},"slug":{"type":"string"}},"required":["title","slug"],"unique":[["title"]]}
    },
    .{ .name = "remove", .field = "flag", .kind = .removed, .action = .rebuild, .bucket = .migration_required, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "integer to number", .field = "priority", .kind = .type_changed, .action = .rebuild, .bucket = .migration_required, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"number","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "boolean to integer (same SQL type)", .field = "flag", .kind = .type_changed, .action = .rebuild, .bucket = .migration_required, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"integer","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "remove references", .field = "project_id", .kind = .type_changed, .action = .rebuild, .bucket = .migration_required, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "array items", .field = "tags", .kind = .items_changed, .action = .rebuild, .bucket = .migration_required, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"integer"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "required to optional", .field = "title", .kind = .became_optional, .action = .rebuild, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"unique":[["title"]]}
    },
    .{ .name = "optional to required", .field = "status", .kind = .became_required, .action = .rebuild, .bucket = .checked, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title","status"],"unique":[["title"]]}
    },
    .{ .name = "reference target", .field = "project_id", .kind = .reference_target_changed, .action = .rebuild, .bucket = .checked, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"users"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "onDelete", .field = "project_id", .kind = .on_delete_changed, .action = .rebuild, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects","onDelete":"cascade"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "indexed", .field = "flag", .kind = .indexed_changed, .action = .unchanged, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean"}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "enum narrowed", .field = "status", .kind = .constraint_tightened, .action = .unchanged, .bucket = .checked, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "enum widened", .field = "status", .kind = .constraint_loosened, .action = .unchanged, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done","archived"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "minLength raised", .field = "title", .kind = .constraint_tightened, .action = .unchanged, .bucket = .checked, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":2,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "maxLength removed", .field = "title", .kind = .constraint_loosened, .action = .unchanged, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "maximum lowered", .field = "priority", .kind = .constraint_tightened, .action = .unchanged, .bucket = .checked, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":5},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "pattern added", .field = "title", .kind = .constraint_tightened, .action = .unchanged, .bucket = .checked, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100,"pattern":"^[a-z]+$"},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true}},"required":["title"],"unique":[["title"]]}
    },
    .{ .name = "metadata", .field = "flag", .kind = .metadata_changed, .action = .unchanged, .bucket = .auto, .tasks =
    \\{"fields":{"title":{"type":"string","minLength":1,"maxLength":100},"status":{"type":"string","enum":["open","done"]},"priority":{"type":"integer","minimum":0,"maximum":10},"tags":{"type":"array","items":"string"},"project_id":{"type":"string","references":"projects"},"flag":{"type":"boolean","indexed":true,"metadata":{"label":"Flag"}}},"required":["title"],"unique":[["title"]]}
    },
};

test "diff: every field change is classified with its bucket and table action" {
    var from = try parse(wrap("1.0.0", base_tasks));
    defer from.deinit();

    for (field_cases) |case| {
        const json = try std.mem.concat(allocator, u8, &.{
            "{\"version\":\"1.0.0\",\"store\":{\"users\":{\"fields\":{}},\"projects\":{\"fields\":{\"name\":{\"type\":\"string\"}}},\"tasks\":",
            case.tasks,
            "}}",
        });
        defer allocator.free(json);
        var to = parse(json) catch |err| {
            std.debug.print("case '{s}' failed to parse: {}\n", .{ case.name, err });
            return err;
        };
        defer to.deinit();

        var d = try schema_diff.diff(allocator, &from, &to);
        defer d.deinit();

        const tasks = tableOf(&d, "tasks") orelse return error.TestExpectedValue;
        var found = false;
        for (tasks.field_changes) |change| {
            if (change.kind == case.kind and std.mem.eql(u8, change.name, case.field)) found = true;
        }
        if (!found or tasks.action != case.action or tasks.bucket() != case.bucket) {
            std.debug.print("case '{s}': action={s} bucket={s} changes:\n", .{ case.name, @tagName(tasks.action), @tagName(tasks.bucket()) });
            for (tasks.field_changes) |change| std.debug.print("  {s} {s}\n", .{ change.name, @tagName(change.kind) });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqual(case.bucket, d.bucket());
        try std.testing.expect(tableOf(&d, "projects").?.isEmpty());
    }
}

test "diff: identical schemas produce no changes" {
    var a = try parse(wrap("1.0.0", base_tasks));
    defer a.deinit();
    var b = try parse(wrap("1.0.1", base_tasks));
    defer b.deinit();
    var d = try schema_diff.diff(allocator, &a, &b);
    defer d.deinit();
    for (d.tables) |*t| try std.testing.expect(t.isEmpty());
    try std.testing.expect(!hasPhysicalChanges(&d));
    try std.testing.expectEqual(Bucket.auto, d.bucket());
}

test "diff: table-level changes" {
    var from = try parse(wrap("1.0.0", base_tasks));
    defer from.deinit();

    {
        var to = try parse(
            \\{"version":"1.0.0","store":{"users":{"fields":{}},"projects":{"fields":{"name":{"type":"string"}}}}}
        );
        defer to.deinit();
        var d = try schema_diff.diff(allocator, &from, &to);
        defer d.deinit();
        const tasks = tableOf(&d, "tasks") orelse return error.TestExpectedValue;
        try std.testing.expectEqual(TableAction.remove, tasks.action);
        try std.testing.expectEqualSlices(TableChangeKind, &.{.removed}, tasks.table_changes);
        try std.testing.expectEqual(Bucket.migration_required, d.bucket());
    }
    {
        var to = try parse(
            \\{"version":"1.0.0","store":{"users":{"fields":{}},"projects":{"namespaced":false,"fields":{"name":{"type":"string"}}}}}
        );
        defer to.deinit();
        var smaller = try parse(
            \\{"version":"1.0.0","store":{"users":{"fields":{}},"projects":{"fields":{"name":{"type":"string"}}}}}
        );
        defer smaller.deinit();
        var d = try schema_diff.diff(allocator, &smaller, &to);
        defer d.deinit();
        const projects = tableOf(&d, "projects") orelse return error.TestExpectedValue;
        try std.testing.expectEqual(TableAction.rebuild, projects.action);
        try std.testing.expectEqualSlices(TableChangeKind, &.{.namespaced_changed}, projects.table_changes);
        try std.testing.expectEqual(Bucket.migration_required, d.bucket());
    }
    {
        var smaller = try parse(
            \\{"version":"1.0.0","store":{"users":{"fields":{}}}}
        );
        defer smaller.deinit();
        var d = try schema_diff.diff(allocator, &smaller, &from);
        defer d.deinit();
        try std.testing.expectEqual(TableAction.create, tableOf(&d, "tasks").?.action);
        try std.testing.expectEqual(TableAction.create, tableOf(&d, "projects").?.action);
        try std.testing.expectEqual(Bucket.auto, d.bucket());
    }
}

test "diff: unique constraints tighten when added or changed and loosen when removed or reordered" {
    const cases = [_]struct { from: []const u8, to: []const u8, kind: TableChangeKind }{
        .{ .from = "[]", .to = "[[\"a\"]]", .kind = .unique_tightened },
        .{ .from = "[[\"a\"]]", .to = "[[\"a\",\"b\"]]", .kind = .unique_tightened },
        .{ .from = "[[\"a\",\"b\"]]", .to = "[[\"b\",\"a\"]]", .kind = .unique_tightened },
        .{ .from = "[[\"a\"]]", .to = "[]", .kind = .unique_loosened },
        .{ .from = "[[\"a\"],[\"b\"]]", .to = "[[\"b\"],[\"a\"]]", .kind = .unique_loosened },
    };
    for (cases) |case| {
        const from_json = try std.fmt.allocPrint(allocator, "{{\"version\":\"1.0.0\",\"store\":{{\"t\":{{\"fields\":{{\"a\":{{\"type\":\"string\"}},\"b\":{{\"type\":\"string\"}}}},\"unique\":{s}}}}}}}", .{case.from});
        defer allocator.free(from_json);
        const to_json = try std.fmt.allocPrint(allocator, "{{\"version\":\"1.0.0\",\"store\":{{\"t\":{{\"fields\":{{\"a\":{{\"type\":\"string\"}},\"b\":{{\"type\":\"string\"}}}},\"unique\":{s}}}}}}}", .{case.to});
        defer allocator.free(to_json);
        var from = try parse(from_json);
        defer from.deinit();
        var to = try parse(to_json);
        defer to.deinit();
        var d = try schema_diff.diff(allocator, &from, &to);
        defer d.deinit();
        const t = tableOf(&d, "t") orelse return error.TestExpectedValue;
        try std.testing.expectEqualSlices(TableChangeKind, &.{case.kind}, t.table_changes);
        try std.testing.expect(t.indexes_changed);
        try std.testing.expectEqual(TableAction.unchanged, t.action);
    }
}

test "diff: field order changes are not physical changes" {
    var a = try parse(
        \\{"version":"1.0.0","store":{"t":{"fields":{"a":{"type":"string"},"b":{"type":"integer"}}}}}
    );
    defer a.deinit();
    var b = try parse(
        \\{"version":"1.0.0","store":{"t":{"fields":{"b":{"type":"integer"},"a":{"type":"string"}}}}}
    );
    defer b.deinit();
    var d = try schema_diff.diff(allocator, &a, &b);
    defer d.deinit();
    try std.testing.expect(!hasPhysicalChanges(&d));
    try std.testing.expect(tableOf(&d, "t").?.isEmpty());
}

test "diff: fresh database creates every table" {
    var to = try parse(wrap("1.0.0", base_tasks));
    defer to.deinit();
    var d = try schema_diff.diff(allocator, null, &to);
    defer d.deinit();
    try std.testing.expectEqual(to.tables.len, d.tables.len);
    for (d.tables) |t| try std.testing.expectEqual(TableAction.create, t.action);
    try std.testing.expectEqual(Bucket.auto, d.bucket());
}

test "diff: presence and action changes are snapshot-only" {
    var a = try parse(
        \\{"version":"1.0.0","store":{},"presence":{"user":{"cursor":{"type":"integer"}}}}
    );
    defer a.deinit();
    var b = try parse(
        \\{"version":"1.0.0","store":{},"presence":{"user":{"cursor":{"type":"number"}}},"actions":{"ping":{"params":{}}}}
    );
    defer b.deinit();
    var d = try schema_diff.diff(allocator, &a, &b);
    defer d.deinit();
    try std.testing.expect(!hasPhysicalChanges(&d));
    try std.testing.expectEqual(Bucket.auto, d.bucket());
}
