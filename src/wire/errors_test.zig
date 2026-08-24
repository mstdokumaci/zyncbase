const std = @import("std");

const msgpack = @import("../msgpack_utils.zig");
const wire_errors = @import("errors.zig");

const testing = std.testing;

test "getWireError: returns non-empty comptime-encoded keys" {
    const err1 = wire_errors.getWireError(error.UnknownTable);
    try testing.expect(err1.code.len > 0);
    const err2 = wire_errors.getWireError(error.UnknownField);
    try testing.expect(err2.code.len > 0);
    try testing.expect(err1.code.len != err2.code.len or !std.mem.eql(u8, err1.code, err2.code));
}

test "getWireError: returns non-empty comptime-encoded messages" {
    const err1 = wire_errors.getWireError(error.UnknownTable);
    try testing.expect(err1.message.len > 0);
    const err2 = wire_errors.getWireError(error.UnknownField);
    try testing.expect(err2.message.len > 0);
}

test "getWireError: query parser errors keep distinct human messages" {
    const check = struct {
        fn run(comptime err: anyerror, comptime expected: []const u8) !void {
            const allocator = std.heap.smp_allocator;
            const wire_err = wire_errors.getWireError(err);
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

test "getWireError: unique constraint violation maps to its public code" {
    const check = struct {
        fn run(comptime err: anyerror, comptime expected_code: []const u8, comptime expected_message: []const u8) !void {
            const allocator = std.heap.smp_allocator;
            const wire_err = wire_errors.getWireError(err);

            var code_reader: std.Io.Reader = .fixed(wire_err.code);
            const decoded_code = try msgpack.decode(allocator, &code_reader);
            defer decoded_code.free(allocator);
            try testing.expectEqualStrings(expected_code, decoded_code.str.value());

            var msg_reader: std.Io.Reader = .fixed(wire_err.message);
            const decoded_msg = try msgpack.decode(allocator, &msg_reader);
            defer decoded_msg.free(allocator);
            try testing.expectEqualStrings(expected_message, decoded_msg.str.value());
        }
    }.run;

    try check(error.UniqueConstraintViolation, "UNIQUE_CONSTRAINT_VIOLATED", "Unique constraint violated");
    // Generic constraint violations keep the existing public code.
    try check(error.ConstraintViolation, "SCHEMA_VALIDATION_FAILED", "Schema constraint violation");
}
