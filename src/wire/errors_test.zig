const std = @import("std");
const testing = std.testing;
const wire = @import("../wire.zig");
const msgpack = @import("../msgpack_utils.zig");

test "getWireError: returns non-empty comptime-encoded keys" {
    const err1 = wire.getWireError(error.UnknownTable);
    try testing.expect(err1.code.len > 0);
    const err2 = wire.getWireError(error.UnknownField);
    try testing.expect(err2.code.len > 0);
    try testing.expect(err1.code.len != err2.code.len or !std.mem.eql(u8, err1.code, err2.code));
}

test "getWireError: returns non-empty comptime-encoded messages" {
    const err1 = wire.getWireError(error.UnknownTable);
    try testing.expect(err1.message.len > 0);
    const err2 = wire.getWireError(error.UnknownField);
    try testing.expect(err2.message.len > 0);
}

test "getWireError: query parser errors keep distinct human messages" {
    const allocator = testing.allocator;
    const check = struct {
        fn run(comptime err: anyerror, comptime expected: []const u8) !void {
            const wire_err = wire.getWireError(err);
            var reader: std.Io.Reader = .fixed(wire_err.message);
            const decoded = try msgpack.decode(allocator, &reader);
            defer decoded.free(allocator);
            try testing.expectEqualStrings(expected, decoded.str.value());
        }
    }.run;

    try check(error.MissingOperand, "Query operator is missing an operand");
    try check(error.UnexpectedOperand, "Query operator does not accept an operand");
    try check(error.InvalidInOperand, "IN and NOT IN require an array operand");
    try check(error.NullOperandUnsupported, "Null is not allowed as a query operand");
    try check(error.UnsupportedOperatorForFieldType, "Query operator is not supported for this field type");
    try check(error.InvalidCursorSortValue, "Cursor sort value does not match the active sort field");
}
