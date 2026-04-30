const std = @import("std");
const Allocator = std.mem.Allocator;
const doc_id = @import("../doc_id.zig");
const msgpack = @import("../msgpack_utils.zig");
const schema = @import("../schema.zig");
const errors = @import("errors.zig");
const values = @import("values.zig");

const StorageError = errors.StorageError;
const ScalarValue = values.ScalarValue;
const TypedValue = values.TypedValue;

pub fn writeMsgPack(value: TypedValue, writer: anytype) !void {
    switch (value) {
        .nil => try msgpack.encode(.nil, writer),
        .scalar => |s| try writeScalarMsgPack(s, writer),
        .array => |arr| {
            try msgpack.encodeArrayHeader(writer, arr.len);
            for (arr) |item| {
                try writeScalarMsgPack(item, writer);
            }
        },
    }
}

fn writeScalarMsgPack(value: ScalarValue, writer: anytype) !void {
    switch (value) {
        .doc_id => |id| {
            const bytes = doc_id.toBytes(id);
            try msgpack.writeMsgPackBin(writer, &bytes);
        },
        .integer => |iv| {
            if (iv >= 0) {
                try msgpack.encode(msgpack.Payload{ .uint = @intCast(iv) }, writer);
            } else {
                try msgpack.encode(msgpack.Payload{ .int = iv }, writer);
            }
        },
        .real => |rv| try msgpack.encode(msgpack.Payload{ .float = rv }, writer),
        .text => |tv| try msgpack.writeMsgPackStr(writer, tv),
        .boolean => |bv| try msgpack.encode(msgpack.Payload{ .bool = bv }, writer),
    }
}

pub fn jsonAlloc(allocator: Allocator, value: TypedValue) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, JsonValue{ .value = value }, .{});
}

fn writeScalarJson(value: ScalarValue, stream: anytype) !void {
    switch (value) {
        .doc_id => |id| {
            var buf: [32]u8 = undefined;
            const hex = doc_id.hexSlice(id, &buf);
            try stream.write(hex);
        },
        .integer => |v| try stream.write(v),
        .real => |v| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return error.WriteFailed;
            if (std.mem.indexOfScalar(u8, s, '.') == null and
                std.mem.indexOfScalar(u8, s, 'e') == null and
                std.mem.indexOfScalar(u8, s, 'E') == null)
            {
                try stream.print("{s}.0", .{s});
            } else {
                try stream.print("{s}", .{s});
            }
        },
        .text => |s| try stream.write(s),
        .boolean => |b| try stream.write(b),
    }
}

pub fn validateValue(ft: schema.FieldType, value: msgpack.Payload) !void {
    const match = switch (ft) {
        .doc_id => value == .bin,
        .text => value == .str,
        .integer => value == .int or value == .uint,
        .real => value == .float or value == .uint or value == .int,
        .boolean => value == .bool,
        .array => value == .arr,
    };
    if (!match) return StorageError.TypeMismatch;
}

pub fn fromPayload(allocator: Allocator, ft: schema.FieldType, items_type: ?schema.FieldType, value: msgpack.Payload) !TypedValue {
    if (value == .nil) return .nil;
    return switch (ft) {
        .array => {
            const arr = value.arr;
            const items = try allocator.alloc(ScalarValue, arr.len);
            var i: usize = 0;
            errdefer {
                for (items[0..i]) |*item| item.deinit(allocator);
                allocator.free(items);
            }
            const it = items_type orelse return StorageError.TypeMismatch;
            while (i < arr.len) : (i += 1) {
                if (arr[i] == .nil) return StorageError.NullNotAllowed;
                items[i] = try scalarFromPayload(allocator, it, arr[i]);
            }
            var result = TypedValue{ .array = items };
            try result.sortedSet(allocator);
            return result;
        },
        else => .{ .scalar = try scalarFromPayload(allocator, ft, value) },
    };
}

pub fn fromJson(allocator: Allocator, ft: schema.FieldType, items_type: ?schema.FieldType, value: std.json.Value) !TypedValue {
    if (value == .null) return .nil;
    return switch (ft) {
        .array => {
            if (value != .array) return StorageError.TypeMismatch;
            const arr = value.array;
            const items = try allocator.alloc(ScalarValue, arr.items.len);
            var i: usize = 0;
            errdefer {
                for (items[0..i]) |*item| item.deinit(allocator);
                allocator.free(items);
            }
            const it = items_type orelse return StorageError.TypeMismatch;
            while (i < arr.items.len) : (i += 1) {
                if (arr.items[i] == .null) return StorageError.NullNotAllowed;
                items[i] = try scalarFromJson(allocator, it, arr.items[i]);
            }
            return TypedValue{ .array = items };
        },
        else => .{ .scalar = try scalarFromJson(allocator, ft, value) },
    };
}

fn scalarFromPayload(allocator: Allocator, ft: schema.FieldType, value: msgpack.Payload) !ScalarValue {
    return switch (ft) {
        .doc_id => switch (value) {
            .bin => |b| ScalarValue{ .doc_id = try doc_id.fromBytes(b.value()) },
            else => StorageError.TypeMismatch,
        },
        .text => switch (value) {
            .str => |s| ScalarValue{ .text = try allocator.dupe(u8, s.value()) },
            else => StorageError.TypeMismatch,
        },
        .integer => ScalarValue{ .integer = try payloadAsInt(value) },
        .real => ScalarValue{ .real = try payloadAsFloat(value) },
        .boolean => ScalarValue{ .boolean = try payloadAsBool(value) },
        else => StorageError.InvalidArrayElement,
    };
}

fn scalarFromJson(allocator: Allocator, ft: schema.FieldType, value: std.json.Value) !ScalarValue {
    return switch (ft) {
        .doc_id => switch (value) {
            .string => |s| ScalarValue{ .doc_id = doc_id.fromHex(s) catch return StorageError.TypeMismatch },
            else => StorageError.TypeMismatch,
        },
        .text => switch (value) {
            .string => |s| ScalarValue{ .text = try allocator.dupe(u8, s) },
            else => StorageError.TypeMismatch,
        },
        .integer => ScalarValue{ .integer = try jsonAsInt(value) },
        .real => ScalarValue{ .real = try jsonAsFloat(value) },
        .boolean => ScalarValue{ .boolean = try jsonAsBool(value) },
        else => StorageError.InvalidArrayElement,
    };
}

const JsonValue = struct {
    value: TypedValue,

    pub fn jsonStringify(self: @This(), stream: anytype) !void {
        switch (self.value) {
            .nil => try stream.write(null),
            .scalar => |s| try writeScalarJson(s, stream),
            .array => |items| {
                try stream.beginArray();
                for (items) |item| try writeScalarJson(item, stream);
                try stream.endArray();
            },
        }
    }
};

fn payloadAsInt(payload: msgpack.Payload) !i64 {
    return switch (payload) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => StorageError.TypeMismatch,
    };
}

fn payloadAsFloat(payload: msgpack.Payload) !f64 {
    return switch (payload) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .uint => |v| @floatFromInt(v),
        else => StorageError.TypeMismatch,
    };
}

fn payloadAsBool(payload: msgpack.Payload) !bool {
    return switch (payload) {
        .bool => |v| v,
        else => StorageError.TypeMismatch,
    };
}

fn jsonAsInt(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |v| v,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch StorageError.TypeMismatch,
        else => StorageError.TypeMismatch,
    };
}

fn jsonAsFloat(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch StorageError.TypeMismatch,
        else => StorageError.TypeMismatch,
    };
}

fn jsonAsBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => StorageError.TypeMismatch,
    };
}
