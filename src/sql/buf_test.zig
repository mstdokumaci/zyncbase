const std = @import("std");

const sql_buf = @import("buf.zig");

const SqlBuf = sql_buf.SqlBuf;
const SqlList = sql_buf.SqlList;

test "append and appendSlice accumulate bytes" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);
    try b.append(std.heap.smp_allocator, 'A');
    try b.appendSlice(std.heap.smp_allocator, "BC");
    try std.testing.expectEqualStrings("ABC", b.items());
    try std.testing.expectEqual(@as(usize, 3), b.len());
}

test "appendQuoted wraps identifier in double quotes" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);
    try b.appendQuoted(std.heap.smp_allocator, "users");
    try std.testing.expectEqualStrings("\"users\"", b.items());
}

test "appendIndexName builds idx_table_field form" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);
    try b.appendIndexName(std.heap.smp_allocator, "users", "email");
    try std.testing.expectEqualStrings("\"idx_users_email\"", b.items());
}

test "SqlList emits separator between items, not before first" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);

    var list = SqlList.init(&b, ", ");
    try list.maybeSep(std.heap.smp_allocator);
    try b.appendSlice(std.heap.smp_allocator, "a");
    try list.maybeSep(std.heap.smp_allocator);
    try b.appendSlice(std.heap.smp_allocator, "b");
    try list.maybeSep(std.heap.smp_allocator);
    try b.appendSlice(std.heap.smp_allocator, "c");

    try std.testing.expectEqualStrings("a, b, c", b.items());
}

test "SqlList.appendItemSlice auto-separates" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);

    var list = SqlList.init(&b, ", ");
    try list.appendItemSlice(std.heap.smp_allocator, "a");
    try list.appendItemSlice(std.heap.smp_allocator, "b");
    try list.appendItemSlice(std.heap.smp_allocator, "c");

    try std.testing.expectEqualStrings("a, b, c", b.items());
}

test "SqlList.appendQuoted auto-separates" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);

    var list = SqlList.init(&b, ", ");
    try list.appendQuoted(std.heap.smp_allocator, "foo");
    try list.appendQuoted(std.heap.smp_allocator, "bar");
    try list.appendQuoted(std.heap.smp_allocator, "baz");

    try std.testing.expectEqualStrings("\"foo\", \"bar\", \"baz\"", b.items());
}

test "nested SqlList instances have independent state" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);

    var outer = SqlList.init(&b, " AND ");
    try outer.maybeSep(std.heap.smp_allocator);
    try b.appendSlice(std.heap.smp_allocator, "(");
    {
        var inner = SqlList.init(&b, " OR ");
        try inner.appendItemSlice(std.heap.smp_allocator, "x");
        try inner.appendItemSlice(std.heap.smp_allocator, "y");
    }
    try b.appendSlice(std.heap.smp_allocator, ")");
    try outer.maybeSep(std.heap.smp_allocator);
    try b.appendSlice(std.heap.smp_allocator, "z");

    try std.testing.expectEqualStrings("(x OR y) AND z", b.items());
}

test "SqlList: structural appends after list do not get separator" {
    var b = SqlBuf.init();
    defer b.deinit(std.heap.smp_allocator);

    var list = SqlList.init(&b, ", ");
    try list.appendItemSlice(std.heap.smp_allocator, "a");
    // suffix outside the list context — just append to buf directly
    try b.appendSlice(std.heap.smp_allocator, ")");

    try std.testing.expectEqualStrings("a)", b.items());
}

test "toOwnedSlice transfers ownership" {
    var b = SqlBuf.init();
    try b.appendSlice(std.heap.smp_allocator, "hello");
    const owned = try b.toOwnedSlice(std.heap.smp_allocator);
    defer std.heap.smp_allocator.free(owned);
    try std.testing.expectEqualStrings("hello", owned);
    try std.testing.expectEqual(@as(usize, 0), b.len());
}
