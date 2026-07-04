const std = @import("std");
const read = @import("read.zig");

test "getString returns string and rejects non-string" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"name":"alice","age":30,"flag":true,"nothing":null}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqualStrings("alice", (try read.getString(obj, "name")).?);
    try std.testing.expectError(error.TypeMismatch, read.getString(obj, "age"));
    try std.testing.expect((try read.getString(obj, "missing")) == null);
    try std.testing.expect((try read.getString(obj, "nothing")) == null);
}

test "getInt returns integer and rejects non-integer" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"age":30,"name":"x","big":9999999999,"nothing":null}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqual(@as(i64, 30), (try read.getInt(obj, "age")).?);
    try std.testing.expectEqual(@as(i64, 9999999999), (try read.getInt(obj, "big")).?);
    try std.testing.expectError(error.TypeMismatch, read.getInt(obj, "name"));
    try std.testing.expect((try read.getInt(obj, "missing")) == null);
    try std.testing.expect((try read.getInt(obj, "nothing")) == null);
}

test "getBool returns bool and rejects non-bool" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"flag":true,"name":"x","nothing":null}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqual(true, (try read.getBool(obj, "flag")).?);
    try std.testing.expectError(error.TypeMismatch, read.getBool(obj, "name"));
    try std.testing.expect((try read.getBool(obj, "missing")) == null);
    try std.testing.expect((try read.getBool(obj, "nothing")) == null);
}

test "getObject returns object map" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"nested":{"a":1},"name":"x","nothing":null}
    );
    defer p.deinit();
    const obj = p.value.object;
    const nested = try read.getObject(obj, "nested");
    try std.testing.expect(nested != null);
    try std.testing.expectEqual(@as(i64, 1), (try read.getInt(nested.?, "a")).?);
    try std.testing.expectError(error.TypeMismatch, read.getObject(obj, "name"));
    try std.testing.expect((try read.getObject(obj, "missing")) == null);
    try std.testing.expect((try read.getObject(obj, "nothing")) == null);
}

test "getArray returns array" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"items":[1,2,3],"name":"x","nothing":null}
    );
    defer p.deinit();
    const obj = p.value.object;
    const arr = try read.getArray(obj, "items");
    try std.testing.expect(arr != null);
    try std.testing.expectEqual(@as(usize, 3), arr.?.items.len);
    try std.testing.expectError(error.TypeMismatch, read.getArray(obj, "name"));
    try std.testing.expect((try read.getArray(obj, "missing")) == null);
    try std.testing.expect((try read.getArray(obj, "nothing")) == null);
}

test "dupString dups and returns null for absent" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"name":"alice"}
    );
    defer p.deinit();
    const obj = p.value.object;
    const duped = try read.dupString(std.testing.allocator, obj, "name");
    try std.testing.expect(duped != null);
    defer std.testing.allocator.free(duped.?);
    try std.testing.expectEqualStrings("alice", duped.?);

    try std.testing.expect((try read.dupString(std.testing.allocator, obj, "missing")) == null);
}

test "setString sets optional field only when string present" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"secret":"abc","new_secret":"xyz","noop":42}
    );
    defer p.deinit();
    const obj = p.value.object;
    var field: ?[]const u8 = null;
    try read.setString(std.testing.allocator, &field, obj, "secret");
    defer if (field) |f| std.testing.allocator.free(f);
    try std.testing.expect(field != null);
    try std.testing.expectEqualStrings("abc", field.?);

    try read.setString(std.testing.allocator, &field, obj, "new_secret");
    try std.testing.expectEqualStrings("xyz", field.?);

    var untouched: ?[]const u8 = null;
    try std.testing.expectError(error.TypeMismatch, read.setString(std.testing.allocator, &untouched, obj, "noop"));
    try std.testing.expect(untouched == null);
}

test "replaceString frees old and dups new" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"host":"1.2.3.4","noop":42}
    );
    defer p.deinit();
    const obj = p.value.object;
    var field: []const u8 = try std.testing.allocator.dupe(u8, "0.0.0.0");
    try read.replaceString(std.testing.allocator, &field, obj, "host");
    defer std.testing.allocator.free(field);
    try std.testing.expectEqualStrings("1.2.3.4", field);

    var untouched: []const u8 = try std.testing.allocator.dupe(u8, "orig");
    defer std.testing.allocator.free(untouched);
    try read.replaceString(std.testing.allocator, &untouched, obj, "missing");
    try std.testing.expectEqualStrings("orig", untouched);

    var type_mismatch: []const u8 = try std.testing.allocator.dupe(u8, "keep");
    defer std.testing.allocator.free(type_mismatch);
    try std.testing.expectError(error.TypeMismatch, read.replaceString(std.testing.allocator, &type_mismatch, obj, "noop"));
    try std.testing.expectEqualStrings("keep", type_mismatch);
}

test "getEnum resolves string to enum tag" {
    const Level = enum { debug, info, warn, @"error" };
    const map = std.StaticStringMap(Level).initComptime(.{
        .{ "debug", .debug },
        .{ "info", .info },
        .{ "warn", .warn },
        .{ "error", .@"error" },
    });
    var p = try read.parseValue(std.testing.allocator,
        \\{"level":"warn","other":"nope"}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqual(Level.warn, (try read.getEnum(Level, obj, "level", map)).?);
    try std.testing.expect((try read.getEnum(Level, obj, "other", map)) == null);
    try std.testing.expect((try read.getEnum(Level, obj, "missing", map)) == null);
}

test "setBool assigns when present, no-op when missing or null" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"on":true,"off":false,"noop":"yes","nothing":null}
    );
    defer p.deinit();
    const obj = p.value.object;

    var field: bool = false;
    try read.setBool(&field, obj, "on");
    try std.testing.expectEqual(true, field);

    try read.setBool(&field, obj, "off");
    try std.testing.expectEqual(false, field);

    var untouched: bool = true;
    try read.setBool(&untouched, obj, "missing");
    try std.testing.expectEqual(true, untouched);

    try read.setBool(&untouched, obj, "nothing");
    try std.testing.expectEqual(true, untouched);

    var type_mismatch: bool = false;
    try std.testing.expectError(error.TypeMismatch, read.setBool(&type_mismatch, obj, "noop"));
    try std.testing.expectEqual(false, type_mismatch);
}

test "setInt assigns with intCast, no-op when missing or null" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"port":8080,"big":9999999999,"noop":"x","nothing":null}
    );
    defer p.deinit();
    const obj = p.value.object;

    var u16_field: u16 = 0;
    try read.setInt(u16, &u16_field, obj, "port");
    try std.testing.expectEqual(@as(u16, 8080), u16_field);

    var u32_field: u32 = 0;
    try read.setInt(u32, &u32_field, obj, "port");
    try std.testing.expectEqual(@as(u32, 8080), u32_field);

    var usize_field: usize = 0;
    try read.setInt(usize, &usize_field, obj, "port");
    try std.testing.expectEqual(@as(usize, 8080), usize_field);

    var untouched: u32 = 42;
    try read.setInt(u32, &untouched, obj, "missing");
    try std.testing.expectEqual(@as(u32, 42), untouched);

    try read.setInt(u32, &untouched, obj, "nothing");
    try std.testing.expectEqual(@as(u32, 42), untouched);

    var type_mismatch: u32 = 0;
    try std.testing.expectError(error.TypeMismatch, read.setInt(u32, &type_mismatch, obj, "noop"));
    try std.testing.expectEqual(@as(u32, 0), type_mismatch);
}

test "null value treated same as absent in setString and replaceString" {
    var p = try read.parseValue(std.testing.allocator,
        \\{"key":"value","empty":null}
    );
    defer p.deinit();
    const obj = p.value.object;

    var opt_field: ?[]const u8 = null;
    try read.setString(std.testing.allocator, &opt_field, obj, "key");
    defer if (opt_field) |f| std.testing.allocator.free(f);
    try std.testing.expectEqualStrings("value", opt_field.?);

    var opt_field2: ?[]const u8 = null;
    try read.setString(std.testing.allocator, &opt_field2, obj, "empty");
    try std.testing.expect(opt_field2 == null);

    var field: []const u8 = try std.testing.allocator.dupe(u8, "original");
    defer std.testing.allocator.free(field);
    try read.replaceString(std.testing.allocator, &field, obj, "empty");
    try std.testing.expectEqualStrings("original", field);
}

test "skipString simple" {
    const s = "\"hello\" rest";
    var pos: usize = 0;
    _ = read.skipString(s, &pos);
    try std.testing.expectEqual(@as(usize, 7), pos);
}

test "skipString with escapes" {
    const s = "\"a\\\"b\" rest";
    var pos: usize = 0;
    _ = read.skipString(s, &pos);
    try std.testing.expectEqual(@as(usize, 6), pos);
}

test "skipString unterminated returns null" {
    const s = "\"unterminated";
    var pos: usize = 0;
    try std.testing.expect(read.skipString(s, &pos) == null);
}

test "skipBalanced object" {
    const s = "{\"a\":1,\"b\":{\"c\":2}} rest";
    var pos: usize = 0;
    _ = read.skipBalanced(s, &pos, '{', '}');
    try std.testing.expectEqual(@as(usize, 19), pos);
}

test "skipBalanced array" {
    const s = "[1,2,[3,4]] rest";
    var pos: usize = 0;
    _ = read.skipBalanced(s, &pos, '[', ']');
    try std.testing.expectEqual(@as(usize, 11), pos);
}

test "skipBalanced ignores brackets in strings" {
    const s = "{\"key\":\"val{ue\"} rest";
    var pos: usize = 0;
    _ = read.skipBalanced(s, &pos, '{', '}');
    try std.testing.expectEqual(@as(usize, 16), pos);
}

test "skipBalanced unterminated returns null" {
    const s = "{ \"a\": 1 ";
    var pos: usize = 0;
    try std.testing.expect(read.skipBalanced(s, &pos, '{', '}') == null);
}

test "skipLiteral true false null" {
    const cases = [_]struct { src: []const u8, lit: []const u8, expect: usize }{
        .{ .src = "true rest", .lit = "true", .expect = 4 },
        .{ .src = "false rest", .lit = "false", .expect = 5 },
        .{ .src = "null rest", .lit = "null", .expect = 4 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        _ = read.skipLiteral(c.src, &pos, c.lit);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skipLiteral mismatch returns null" {
    const s = "true";
    var pos: usize = 0;
    try std.testing.expect(read.skipLiteral(s, &pos, "null") == null);
    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "skipNumber integer and float" {
    const cases = [_]struct { src: []const u8, expect: usize }{
        .{ .src = "123 rest", .expect = 3 },
        .{ .src = "-456 rest", .expect = 4 },
        .{ .src = "3.14 rest", .expect = 4 },
        .{ .src = "1e10 rest", .expect = 4 },
        .{ .src = "-2.5e-3 rest", .expect = 7 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        _ = read.skipNumber(c.src, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skipNumber non-number returns null" {
    const cases = [_][]const u8{
        "abc",
        "-",
        "-e",
        "-e+",
    };
    for (cases) |c| {
        var pos: usize = 0;
        try std.testing.expect(read.skipNumber(c, &pos) == null);
        try std.testing.expectEqual(@as(usize, 0), pos);
    }
}

test "skipValue dispatches by first byte" {
    const cases = [_]struct { src: []const u8, expect: usize }{
        .{ .src = "\"str\" rest", .expect = 5 },
        .{ .src = "{\"a\":1} rest", .expect = 7 },
        .{ .src = "[1,2] rest", .expect = 5 },
        .{ .src = "true rest", .expect = 4 },
        .{ .src = "false rest", .expect = 5 },
        .{ .src = "null rest", .expect = 4 },
        .{ .src = "123 rest", .expect = 3 },
        .{ .src = "-1.5 rest", .expect = 4 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        _ = read.skipValue(c.src, &pos);
        try std.testing.expectEqual(c.expect, pos);
    }
}

test "skipValue unknown byte returns null" {
    const s = "x";
    var pos: usize = 0;
    try std.testing.expect(read.skipValue(s, &pos) == null);
}

test "skipValue nested object with array and string" {
    const s = "{\"a\":[1,\"b]\"],\"c\":true} rest";
    var pos: usize = 0;
    _ = read.skipValue(s, &pos);
    try std.testing.expectEqual(@as(usize, 23), pos);
}

test "extractJsonString reads without escapes" {
    const s = "\"hello\"";
    var pos: usize = 0;
    const result = read.extractJsonString(s, &pos) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("hello", result);
    try std.testing.expectEqual(@as(usize, 7), pos);
}

test "extractJsonInt reads positive and negative" {
    const cases = [_]struct { src: []const u8, expect: i64 }{
        .{ .src = "42", .expect = 42 },
        .{ .src = "-7", .expect = -7 },
        .{ .src = "0", .expect = 0 },
    };
    for (cases) |c| {
        var pos: usize = 0;
        try std.testing.expectEqual(c.expect, read.extractJsonInt(c.src, &pos).?);
    }
}
