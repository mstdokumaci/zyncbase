const std = @import("std");
const json_access = @import("json_access.zig");

const Parsed = std.json.Parsed(std.json.Value);

fn parseObj(allocator: std.mem.Allocator, src: []const u8) !Parsed {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, src, .{});
    if (parsed.value != .object) {
        parsed.deinit();
        return error.NotAnObject;
    }
    return parsed;
}

test "getString returns string and rejects non-string" {
    var p = try parseObj(std.testing.allocator,
        \\{"name":"alice","age":30,"flag":true}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqualStrings("alice", json_access.getString(obj, "name").?);
    try std.testing.expect(json_access.getString(obj, "age") == null);
    try std.testing.expect(json_access.getString(obj, "missing") == null);
}

test "getInt returns integer and rejects non-integer" {
    var p = try parseObj(std.testing.allocator,
        \\{"age":30,"name":"x","big":9999999999}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqual(@as(i64, 30), json_access.getInt(obj, "age").?);
    try std.testing.expectEqual(@as(i64, 9999999999), json_access.getInt(obj, "big").?);
    try std.testing.expect(json_access.getInt(obj, "name") == null);
    try std.testing.expect(json_access.getInt(obj, "missing") == null);
}

test "getBool returns bool and rejects non-bool" {
    var p = try parseObj(std.testing.allocator,
        \\{"flag":true,"name":"x"}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqual(true, json_access.getBool(obj, "flag").?);
    try std.testing.expect(json_access.getBool(obj, "name") == null);
    try std.testing.expect(json_access.getBool(obj, "missing") == null);
}

test "getObject returns object map" {
    var p = try parseObj(std.testing.allocator,
        \\{"nested":{"a":1},"name":"x"}
    );
    defer p.deinit();
    const obj = p.value.object;
    const nested = json_access.getObject(obj, "nested");
    try std.testing.expect(nested != null);
    try std.testing.expectEqual(@as(i64, 1), json_access.getInt(nested.?, "a").?);
    try std.testing.expect(json_access.getObject(obj, "name") == null);
    try std.testing.expect(json_access.getObject(obj, "missing") == null);
}

test "getArray returns array" {
    var p = try parseObj(std.testing.allocator,
        \\{"items":[1,2,3],"name":"x"}
    );
    defer p.deinit();
    const obj = p.value.object;
    const arr = json_access.getArray(obj, "items");
    try std.testing.expect(arr != null);
    try std.testing.expectEqual(@as(usize, 3), arr.?.items.len);
    try std.testing.expect(json_access.getArray(obj, "name") == null);
}

test "dupString dups and returns null for absent" {
    var p = try parseObj(std.testing.allocator,
        \\{"name":"alice"}
    );
    defer p.deinit();
    const obj = p.value.object;
    const duped = try json_access.dupString(std.testing.allocator, obj, "name");
    try std.testing.expect(duped != null);
    defer std.testing.allocator.free(duped.?);
    try std.testing.expectEqualStrings("alice", duped.?);

    try std.testing.expect((try json_access.dupString(std.testing.allocator, obj, "missing")) == null);
}

test "setString sets optional field only when string present" {
    var p = try parseObj(std.testing.allocator,
        \\{"secret":"abc","noop":42}
    );
    defer p.deinit();
    const obj = p.value.object;
    var field: ?[]const u8 = null;
    try json_access.setString(std.testing.allocator, &field, obj, "secret");
    defer if (field) |f| std.testing.allocator.free(f);
    try std.testing.expect(field != null);
    try std.testing.expectEqualStrings("abc", field.?);

    var untouched: ?[]const u8 = null;
    try json_access.setString(std.testing.allocator, &untouched, obj, "noop");
    try std.testing.expect(untouched == null);
}

test "replaceString frees old and dups new" {
    var p = try parseObj(std.testing.allocator,
        \\{"host":"1.2.3.4"}
    );
    defer p.deinit();
    const obj = p.value.object;
    var field: []const u8 = try std.testing.allocator.dupe(u8, "0.0.0.0");
    try json_access.replaceString(std.testing.allocator, &field, obj, "host");
    defer std.testing.allocator.free(field);
    try std.testing.expectEqualStrings("1.2.3.4", field);

    var untouched: []const u8 = try std.testing.allocator.dupe(u8, "orig");
    defer std.testing.allocator.free(untouched);
    try json_access.replaceString(std.testing.allocator, &untouched, obj, "missing");
    try std.testing.expectEqualStrings("orig", untouched);
}

test "getEnum resolves string to enum tag" {
    const Level = enum { debug, info, warn, @"error" };
    const map = std.StaticStringMap(Level).initComptime(.{
        .{ "debug", .debug },
        .{ "info", .info },
        .{ "warn", .warn },
        .{ "error", .@"error" },
    });
    var p = try parseObj(std.testing.allocator,
        \\{"level":"warn","other":"nope"}
    );
    defer p.deinit();
    const obj = p.value.object;
    try std.testing.expectEqual(Level.warn, json_access.getEnum(Level, obj, "level", map).?);
    try std.testing.expect(json_access.getEnum(Level, obj, "other", map) == null);
    try std.testing.expect(json_access.getEnum(Level, obj, "missing", map) == null);
}
