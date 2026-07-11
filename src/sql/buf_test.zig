const std = @import("std");
const sql_buf = @import("buf.zig");
const SqlBuf = sql_buf.SqlBuf;
const SqlList = sql_buf.SqlList;

test "append and appendSlice accumulate bytes" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);
    try b.append(std.testing.allocator, 'A');
    try b.appendSlice(std.testing.allocator, "BC");
    try std.testing.expectEqualStrings("ABC", b.items());
    try std.testing.expectEqual(@as(usize, 3), b.len());
}

test "appendQuoted wraps identifier in double quotes" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);
    try b.appendQuoted(std.testing.allocator, "users");
    try std.testing.expectEqualStrings("\"users\"", b.items());
}

test "appendIndexName builds idx_table_field form" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);
    try b.appendIndexName(std.testing.allocator, "users", "email");
    try std.testing.expectEqualStrings("\"idx_users_email\"", b.items());
}

test "SqlList emits separator between items, not before first" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);

    var list = SqlList.init(&b, ", ");
    try list.maybeSep(std.testing.allocator);
    try b.appendSlice(std.testing.allocator, "a");
    try list.maybeSep(std.testing.allocator);
    try b.appendSlice(std.testing.allocator, "b");
    try list.maybeSep(std.testing.allocator);
    try b.appendSlice(std.testing.allocator, "c");

    try std.testing.expectEqualStrings("a, b, c", b.items());
}

test "SqlList.appendItemSlice auto-separates" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);

    var list = SqlList.init(&b, ", ");
    try list.appendItemSlice(std.testing.allocator, "a");
    try list.appendItemSlice(std.testing.allocator, "b");
    try list.appendItemSlice(std.testing.allocator, "c");

    try std.testing.expectEqualStrings("a, b, c", b.items());
}

test "SqlList.appendQuoted auto-separates" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);

    var list = SqlList.init(&b, ", ");
    try list.appendQuoted(std.testing.allocator, "foo");
    try list.appendQuoted(std.testing.allocator, "bar");
    try list.appendQuoted(std.testing.allocator, "baz");

    try std.testing.expectEqualStrings("\"foo\", \"bar\", \"baz\"", b.items());
}

test "nested SqlList instances have independent state" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);

    var outer = SqlList.init(&b, " AND ");
    try outer.maybeSep(std.testing.allocator);
    try b.appendSlice(std.testing.allocator, "(");
    {
        var inner = SqlList.init(&b, " OR ");
        try inner.appendItemSlice(std.testing.allocator, "x");
        try inner.appendItemSlice(std.testing.allocator, "y");
    }
    try b.appendSlice(std.testing.allocator, ")");
    try outer.maybeSep(std.testing.allocator);
    try b.appendSlice(std.testing.allocator, "z");

    try std.testing.expectEqualStrings("(x OR y) AND z", b.items());
}

test "SqlList: structural appends after list do not get separator" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);

    var list = SqlList.init(&b, ", ");
    try list.appendItemSlice(std.testing.allocator, "a");
    // suffix outside the list context — just append to buf directly
    try b.appendSlice(std.testing.allocator, ")");

    try std.testing.expectEqualStrings("a)", b.items());
}

test "toOwnedSlice transfers ownership" {
    var b = SqlBuf.init();
    try b.appendSlice(std.testing.allocator, "hello");
    const owned = try b.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("hello", owned);
    try std.testing.expectEqual(@as(usize, 0), b.len());
}
