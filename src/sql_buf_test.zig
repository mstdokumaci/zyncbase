const std = @import("std");
const sql_buf = @import("sql_buf.zig");
const SqlBuf = sql_buf.SqlBuf;

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

test "appendSep skips on empty buffer and emits on non-empty" {
    var b = SqlBuf.init();
    defer b.deinit(std.testing.allocator);
    try b.appendSep(std.testing.allocator, ", ");
    try std.testing.expectEqualStrings("", b.items());

    try b.appendSlice(std.testing.allocator, "a");
    try b.appendSep(std.testing.allocator, ", ");
    try b.appendSlice(std.testing.allocator, "b");
    try std.testing.expectEqualStrings("a, b", b.items());
}

test "toOwnedSlice transfers ownership" {
    var b = SqlBuf.init();
    try b.appendSlice(std.testing.allocator, "hello");
    const owned = try b.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("hello", owned);
    try std.testing.expectEqual(@as(usize, 0), b.len());
}
