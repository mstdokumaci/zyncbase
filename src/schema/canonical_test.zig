const std = @import("std");

const canonical = @import("canonical.zig");
const schema_parse = @import("parse.zig");
const schema_types = @import("types.zig");

const Identity = canonical.Identity;

const pretty_schema =
    \\{
    \\  "version": "1.2.0",
    \\  "store": {
    \\    "tasks": {
    \\      "fields": {
    \\        "title": { "type": "string", "minLength": 1 },
    \\        "score": { "type": "number", "minimum": 0.5 },
    \\        "big": { "type": "integer", "maximum": 9007199254740991 },
    \\        "profile": { "type": "object", "fields": { "name": { "type": "string" } } }
    \\      },
    \\      "required": ["title"],
    \\      "unique": [["profile.name", "title"]]
    \\    }
    \\  }
    \\}
;

test "canonical: whitespace does not change identity" {
    const allocator = std.testing.allocator;
    const a = try Identity.init(allocator, pretty_schema);
    defer a.deinit(allocator);

    const compact =
        \\{"version":"1.2.0","store":{"tasks":{"fields":{"title":{"type":"string","minLength":1},"score":{"type":"number","minimum":0.5},"big":{"type":"integer","maximum":9007199254740991},"profile":{"type":"object","fields":{"name":{"type":"string"}}}},"required":["title"],"unique":[["profile.name","title"]]}}}
    ;
    const b = try Identity.init(allocator, compact);
    defer b.deinit(allocator);

    try std.testing.expectEqualStrings(a.json, b.json);
    try std.testing.expectEqualSlices(u8, &a.hash, &b.hash);
}

test "canonical: key order and array order are significant" {
    const allocator = std.testing.allocator;
    const base = try Identity.init(allocator,
        \\{"version":"1.0.0","store":{"t":{"fields":{"a":{"type":"string"},"b":{"type":"string"}},"unique":[["a","b"]]}}}
    );
    defer base.deinit(allocator);

    const reordered_fields = try Identity.init(allocator,
        \\{"version":"1.0.0","store":{"t":{"fields":{"b":{"type":"string"},"a":{"type":"string"}},"unique":[["a","b"]]}}}
    );
    defer reordered_fields.deinit(allocator);
    const reordered_unique = try Identity.init(allocator,
        \\{"version":"1.0.0","store":{"t":{"fields":{"a":{"type":"string"},"b":{"type":"string"}},"unique":[["b","a"]]}}}
    );
    defer reordered_unique.deinit(allocator);

    try std.testing.expect(!std.mem.eql(u8, &base.hash, &reordered_fields.hash));
    try std.testing.expect(!std.mem.eql(u8, &base.hash, &reordered_unique.hash));
}

test "canonical: minify is idempotent and pretty round-trips" {
    const allocator = std.testing.allocator;
    const once = try canonical.minify(allocator, pretty_schema);
    defer allocator.free(once);
    const twice = try canonical.minify(allocator, once);
    defer allocator.free(twice);
    try std.testing.expectEqualStrings(once, twice);

    const pretty = try canonical.pretty(allocator, once);
    defer allocator.free(pretty);
    try std.testing.expect(std.mem.indexOf(u8, pretty, "\n\t\"store\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, pretty, "}\n"));
    const back = try canonical.minify(allocator, pretty);
    defer allocator.free(back);
    try std.testing.expectEqualStrings(once, back);
}

test "canonical: minified schema parses to the same schema" {
    const allocator = std.testing.allocator;
    var original = try schema_parse.initFromJson(allocator, pretty_schema);
    defer original.deinit();
    const minified = try canonical.minify(allocator, pretty_schema);
    defer allocator.free(minified);
    var reparsed = try schema_parse.initFromJson(allocator, minified);
    defer reparsed.deinit();

    try std.testing.expectEqualStrings(original.version, reparsed.version);
    try std.testing.expectEqual(original.tables.len, reparsed.tables.len);
    for (original.tables, reparsed.tables) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqual(a.fields.len, b.fields.len);
        for (a.fields, b.fields) |fa, fb| {
            try std.testing.expectEqualStrings(fa.name, fb.name);
            try std.testing.expectEqual(fa.storage_type, fb.storage_type);
            try std.testing.expectEqual(fa.required, fb.required);
            try expectSameConstraints(fa.constraints, fb.constraints);
        }
        try std.testing.expectEqual(a.unique_constraints.len, b.unique_constraints.len);
        for (a.unique_constraints, b.unique_constraints) |ua, ub| {
            try std.testing.expectEqualSlices(usize, ua.field_indexes, ub.field_indexes);
        }
    }
}

fn expectSameConstraints(a: ?schema_types.Constraints, b: ?schema_types.Constraints) !void {
    if (a == null or b == null) return std.testing.expectEqual(a == null, b == null);
    try std.testing.expectEqual(a.?.min_length, b.?.min_length);
    try std.testing.expectEqual(a.?.max_length, b.?.max_length);
    try std.testing.expectEqual(a.?.minimum, b.?.minimum);
    try std.testing.expectEqual(a.?.maximum, b.?.maximum);
}

test "canonical: hash format is sha256 with lowercase hex" {
    const hash = canonical.hashMinified("{}");
    try std.testing.expect(std.mem.startsWith(u8, &hash, "sha256:"));
    try std.testing.expectEqual(@as(usize, 71), hash.len);
    for (hash["sha256:".len..]) |c| {
        try std.testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    }
    // SHA-256("{}")
    try std.testing.expectEqualStrings(
        "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
        &hash,
    );
}

test "canonical: every checked-in schema survives minify and reparse" {
    const allocator = std.testing.allocator;
    const paths = [_][]const u8{
        "tests/e2e/schema-actions.json",
        "tests/e2e/schema-combo-stress.json",
        "tests/e2e/schema-conditional.json",
        "tests/e2e/schema-filters.json",
        "tests/e2e/schema-persistence.json",
        "tests/e2e/schema-presence.json",
        "tests/e2e/schema-sync.json",
        "examples/cordon-off/schema.json",
        "examples/quorum/schema.json",
    };
    for (paths) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
        defer allocator.free(text);
        var original = try schema_parse.initFromJson(allocator, text);
        defer original.deinit();

        const identity = try Identity.init(allocator, text);
        defer identity.deinit(allocator);
        var reparsed = try schema_parse.initFromJson(allocator, identity.json);
        defer reparsed.deinit();

        try std.testing.expectEqual(original.tables.len, reparsed.tables.len);
        try std.testing.expectEqual(original.actions.len, reparsed.actions.len);
        try std.testing.expectEqual(original.presence_user_fields.len, reparsed.presence_user_fields.len);
        for (original.tables, reparsed.tables) |a, b| {
            try std.testing.expectEqualStrings(a.name, b.name);
            try std.testing.expectEqual(a.fields.len, b.fields.len);
        }

        const again = try Identity.init(allocator, identity.json);
        defer again.deinit(allocator);
        try std.testing.expectEqualSlices(u8, &identity.hash, &again.hash);
    }
}
