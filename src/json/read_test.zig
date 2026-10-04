const std = @import("std");

const read = @import("read.zig");

test "getString returns string and rejects non-string" {
    var p = try read.parseValue(std.heap.smp_allocator,
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
    var p = try read.parseValue(std.heap.smp_allocator,
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
    var p = try read.parseValue(std.heap.smp_allocator,
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
    var p = try read.parseValue(std.heap.smp_allocator,
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
    var p = try read.parseValue(std.heap.smp_allocator,
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

test "setString sets optional field only when string present" {
    var p = try read.parseValue(std.heap.smp_allocator,
        \\{"secret":"abc","new_secret":"xyz","noop":42}
    );
    defer p.deinit();
    const obj = p.value.object;
    var field: ?[]const u8 = null;
    try read.setString(std.heap.smp_allocator, &field, obj, "secret");
    defer if (field) |f| std.heap.smp_allocator.free(f);
    try std.testing.expect(field != null);
    try std.testing.expectEqualStrings("abc", field.?);

    try read.setString(std.heap.smp_allocator, &field, obj, "new_secret");
    try std.testing.expectEqualStrings("xyz", field.?);

    var untouched: ?[]const u8 = null;
    try std.testing.expectError(error.TypeMismatch, read.setString(std.heap.smp_allocator, &untouched, obj, "noop"));
    try std.testing.expect(untouched == null);
}

test "replaceString frees old and dups new" {
    var p = try read.parseValue(std.heap.smp_allocator,
        \\{"host":"1.2.3.4","noop":42}
    );
    defer p.deinit();
    const obj = p.value.object;
    var field: []const u8 = try std.heap.smp_allocator.dupe(u8, "0.0.0.0");
    try read.replaceString(std.heap.smp_allocator, &field, obj, "host");
    defer std.heap.smp_allocator.free(field);
    try std.testing.expectEqualStrings("1.2.3.4", field);

    var untouched: []const u8 = try std.heap.smp_allocator.dupe(u8, "orig");
    defer std.heap.smp_allocator.free(untouched);
    try read.replaceString(std.heap.smp_allocator, &untouched, obj, "missing");
    try std.testing.expectEqualStrings("orig", untouched);

    var type_mismatch: []const u8 = try std.heap.smp_allocator.dupe(u8, "keep");
    defer std.heap.smp_allocator.free(type_mismatch);
    try std.testing.expectError(error.TypeMismatch, read.replaceString(std.heap.smp_allocator, &type_mismatch, obj, "noop"));
    try std.testing.expectEqualStrings("keep", type_mismatch);
}

test "setBool assigns when present, no-op when missing or null" {
    var p = try read.parseValue(std.heap.smp_allocator,
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
    var p = try read.parseValue(std.heap.smp_allocator,
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
    var p = try read.parseValue(std.heap.smp_allocator,
        \\{"key":"value","empty":null}
    );
    defer p.deinit();
    const obj = p.value.object;

    var opt_field: ?[]const u8 = null;
    try read.setString(std.heap.smp_allocator, &opt_field, obj, "key");
    defer if (opt_field) |f| std.heap.smp_allocator.free(f);
    try std.testing.expectEqualStrings("value", opt_field.?);

    var opt_field2: ?[]const u8 = null;
    try read.setString(std.heap.smp_allocator, &opt_field2, obj, "empty");
    try std.testing.expect(opt_field2 == null);

    var field: []const u8 = try std.heap.smp_allocator.dupe(u8, "original");
    defer std.heap.smp_allocator.free(field);
    try read.replaceString(std.heap.smp_allocator, &field, obj, "empty");
    try std.testing.expectEqualStrings("original", field);
}
