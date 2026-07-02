const std = @import("std");
const write_mod = @import("write.zig");

test "writeJsonString escapes special characters" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try write_mod.writeJsonString(&buf, std.testing.allocator, "hello \"world\"");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\"", buf.items);
}

test "writeJsonString escapes backslash and newline" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try write_mod.writeJsonString(&buf, std.testing.allocator, "a\\b\nc");
    try std.testing.expectEqualStrings("\"a\\\\b\\nc\"", buf.items);
}

test "writeJsonString escapes backspace and form feed" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try write_mod.writeJsonString(&buf, std.testing.allocator, "a\x08b\x0cc");
    try std.testing.expectEqualStrings("\"a\\bb\\fc\"", buf.items);
}

test "writeJsonString escapes null and other control chars" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try write_mod.writeJsonString(&buf, std.testing.allocator, "\x00\x01\x1f");
    try std.testing.expectEqualStrings("\"\\u0000\\u0001\\u001f\"", buf.items);
}

test "writeJsonString passes through high bytes" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try write_mod.writeJsonString(&buf, std.testing.allocator, "\xc3\xa9"); // é in UTF-8
    try std.testing.expectEqualStrings("\"\xc3\xa9\"", buf.items);
}

test "Writer builds array field" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    var w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.beginArrayField("items");
    try w.writeRaw("\"a\"");
    try w.separator();
    try w.writeRaw("\"b\"");
    try w.endArray();
    try w.endObject();

    try std.testing.expectEqualStrings("{\"items\":[\"a\",\"b\"]}", buf.items);
}

test "Writer rawField and nullField" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    var w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.rawField("data", "{\"x\":1}");
    try w.nullField("nothing");
    try w.endObject();

    try std.testing.expectEqualStrings("{\"data\":{\"x\":1},\"nothing\":null}", buf.items);
}

test "Writer intField" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    var w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.intField("count", @as(i64, 42));
    try w.endObject();

    try std.testing.expectEqualStrings("{\"count\":42}", buf.items);
}

test "Writer complex nested JSON has correct commas" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    var w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.field("version", "1.0.0");
    try w.beginObjectField("store");
    try w.beginObjectField("posts");
    try w.boolField("namespaced", false);
    try w.beginArrayField("required");
    try w.writeRaw("\"profile.name\"");
    try w.separator();
    try w.writeRaw("\"title\"");
    try w.endArray();
    try w.beginObjectField("fields");
    try w.beginObjectField("profile");
    try w.field("type", "object");
    try w.beginObjectField("fields");
    try w.field("name", "string");
    try w.field("age", "integer");
    try w.endObject();
    try w.endObject();
    try w.field("title", "string");
    try w.endObject();
    try w.endObject();
    try w.endObject();
    try w.endObject();

    const expected =
        \\{"version":"1.0.0","store":{"posts":{"namespaced":false,"required":["profile.name","title"],"fields":{"profile":{"type":"object","fields":{"name":"string","age":"integer"}},"title":"string"}}}}
    ;
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "Writer conditional fields produce correct commas" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    var w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.field("sub", "user_1");
    try w.intField("exp", @as(i64, 1234));
    const iss: ?[]const u8 = "issuer";
    if (iss) |i| {
        try w.field("iss", i);
    }
    const aud: ?[]const u8 = null;
    if (aud) |a| {
        try w.field("aud", a);
    }
    try w.nullField("jti");
    try w.endObject();

    try std.testing.expectEqualStrings(
        \\{"sub":"user_1","exp":1234,"iss":"issuer","jti":null}
    , buf.items);
}

test "Writer empty object and array" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    var w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.beginObjectField("empty_obj");
    try w.endObject();
    try w.beginArrayField("empty_arr");
    try w.endArray();
    try w.endObject();

    try std.testing.expectEqualStrings("{\"empty_obj\":{},\"empty_arr\":[]}", buf.items);
}
