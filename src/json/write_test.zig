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

test "Writer builds simple object" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.field("name", "alice");
    try w.separator();
    try w.boolField("active", true);
    try w.endObject();

    try std.testing.expectEqualStrings("{\"name\":\"alice\",\"active\":true}", buf.items);
}

test "Writer builds nested object" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.beginObjectField("session");
    try w.field("id", "123");
    try w.endObject();
    try w.endObject();

    try std.testing.expectEqualStrings("{\"session\":{\"id\":\"123\"}}", buf.items);
}

test "Writer builds array field" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

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
    const w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.rawField("data", "{\"x\":1}");
    try w.separator();
    try w.nullField("nothing");
    try w.endObject();

    try std.testing.expectEqualStrings("{\"data\":{\"x\":1},\"nothing\":null}", buf.items);
}

test "Writer intField" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const w = write_mod.Writer{ .buf = &buf, .allocator = std.testing.allocator };

    try w.beginObject();
    try w.intField("count", @as(i64, 42));
    try w.endObject();

    try std.testing.expectEqualStrings("{\"count\":42}", buf.items);
}
