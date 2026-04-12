const std = @import("std");
const Allocator = std.mem.Allocator;
const msgpack = @import("../msgpack_utils.zig");
const schema_manager = @import("../schema_manager.zig");
const types = @import("types.zig");
const StorageError = types.StorageError;

pub const WriteValue = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8, // Owned
    boolean: bool,
    array_json: []const u8, // Owned JSON string
    nil: void,

    pub fn deinit(self: WriteValue, allocator: Allocator) void {
        switch (self) {
            .text => |s| allocator.free(s),
            .array_json => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn fromPayload(allocator: Allocator, ft: schema_manager.FieldType, payload: msgpack.Payload) !WriteValue {
        if (payload == .nil) return .nil;
        return switch (ft) {
            .text => switch (payload) {
                .str => |s| .{ .text = try allocator.dupe(u8, s.value()) },
                else => types.StorageError.TypeMismatch,
            },
            .integer => .{ .integer = try payloadAsInt(payload) },
            .real => .{ .real = try payloadAsFloat(payload) },
            .boolean => .{ .boolean = try payloadAsBool(payload) },
            .array => .{ .array_json = try msgpack.payloadToJson(payload, allocator) },
        };
    }
};

pub const WriteColumn = struct {
    name: []const u8, // Owned
    field_type: schema_manager.FieldType,
    value: WriteValue,

    pub fn deinit(self: WriteColumn, allocator: Allocator) void {
        if (self.name.ptr != "".ptr) allocator.free(self.name);
        self.value.deinit(allocator);
    }
};

pub const DocumentWrite = struct {
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    columns: []WriteColumn,
    const empty_columns: []WriteColumn = &.{};

    pub const empty: DocumentWrite = .{
        .table = "",
        .id = "",
        .namespace = "",
        .columns = empty_columns,
    };

    pub fn takeOwnership(self: *DocumentWrite) DocumentWrite {
        const out = self.*;
        self.* = .empty;
        return out;
    }

    pub fn deinit(self: *DocumentWrite, allocator: Allocator) void {
        if (self.table.ptr != "".ptr) allocator.free(self.table);
        if (self.id.ptr != "".ptr) allocator.free(self.id);
        if (self.namespace.ptr != "".ptr) allocator.free(self.namespace);
        for (self.columns) |col| col.deinit(allocator);
        if (self.columns.ptr != empty_columns.ptr) allocator.free(self.columns);
        self.* = .empty;
    }
};

pub const FieldWrite = struct {
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    field: []const u8, // Owned
    field_type: schema_manager.FieldType,
    value: WriteValue,

    pub const empty: FieldWrite = .{
        .table = "",
        .id = "",
        .namespace = "",
        .field = "",
        .field_type = .text,
        .value = .nil,
    };

    pub fn takeOwnership(self: *FieldWrite) FieldWrite {
        const out = self.*;
        self.* = .empty;
        return out;
    }

    pub fn deinit(self: *FieldWrite, allocator: Allocator) void {
        if (self.table.ptr != "".ptr) allocator.free(self.table);
        if (self.id.ptr != "".ptr) allocator.free(self.id);
        if (self.namespace.ptr != "".ptr) allocator.free(self.namespace);
        if (self.field.ptr != "".ptr) allocator.free(self.field);
        self.value.deinit(allocator);
        self.* = .empty;
    }
};

pub fn buildDocumentWriteFromPayload(
    allocator: Allocator,
    sm: *const schema_manager.SchemaManager,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    payload: msgpack.Payload,
) !DocumentWrite {
    if (payload != .map) return error.InvalidPayload;
    const table_metadata = sm.getTable(table) orelse return StorageError.UnknownTable;

    var write = DocumentWrite.empty;
    errdefer write.deinit(allocator);

    write.table = try allocator.dupe(u8, table);
    write.id = try allocator.dupe(u8, id);
    write.namespace = try allocator.dupe(u8, namespace);

    var columns = std.ArrayListUnmanaged(WriteColumn).empty;
    defer columns.deinit(allocator);
    errdefer {
        for (columns.items) |col| col.deinit(allocator);
    }

    var it = payload.map.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* != .str) continue;
        const field_name = entry.key_ptr.*.str.value();
        const field = table_metadata.getField(field_name) orelse {
            if (isBuiltInField(field_name)) return StorageError.ImmutableField;
            return StorageError.UnknownField;
        };
        if (field.required and entry.value_ptr.* == .nil) return StorageError.NullNotAllowed;
        if (field.sql_type == .array) {
            msgpack.ensureLiteralArray(entry.value_ptr.*) catch |err| switch (err) {
                error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
                else => |e| return e,
            };
        }
        const value = try WriteValue.fromPayload(allocator, field.sql_type, entry.value_ptr.*);
        try columns.append(allocator, .{
            .name = try allocator.dupe(u8, field_name),
            .field_type = field.sql_type,
            .value = value,
        });
    }

    write.columns = try columns.toOwnedSlice(allocator);
    return write;
}

pub fn buildFieldWriteFromPayload(
    allocator: Allocator,
    sm: *const schema_manager.SchemaManager,
    table: []const u8,
    id: []const u8,
    namespace: []const u8,
    field_name: []const u8,
    payload: msgpack.Payload,
) !FieldWrite {
    const table_metadata = sm.getTable(table) orelse return StorageError.UnknownTable;
    const field = table_metadata.getField(field_name) orelse {
        if (isBuiltInField(field_name)) return StorageError.ImmutableField;
        return StorageError.UnknownField;
    };
    if (field.required and payload == .nil) return StorageError.NullNotAllowed;
    if (field.sql_type == .array) {
        msgpack.ensureLiteralArray(payload) catch |err| switch (err) {
            error.NotAnArray, error.NonLiteralElement => return StorageError.InvalidArrayElement,
            else => |e| return e,
        };
    }

    var write = FieldWrite.empty;
    errdefer write.deinit(allocator);
    write.table = try allocator.dupe(u8, table);
    write.id = try allocator.dupe(u8, id);
    write.namespace = try allocator.dupe(u8, namespace);
    write.field = try allocator.dupe(u8, field_name);
    write.field_type = field.sql_type;
    write.value = try WriteValue.fromPayload(allocator, field.sql_type, payload);
    return write;
}

fn isBuiltInField(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "namespace_id") or
        std.mem.eql(u8, name, "created_at") or
        std.mem.eql(u8, name, "updated_at");
}

fn payloadAsInt(payload: msgpack.Payload) !i64 {
    return switch (payload) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => types.StorageError.TypeMismatch,
    };
}

fn payloadAsFloat(payload: msgpack.Payload) !f64 {
    return switch (payload) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .uint => |v| @floatFromInt(v),
        else => types.StorageError.TypeMismatch,
    };
}

fn payloadAsBool(payload: msgpack.Payload) !bool {
    return switch (payload) {
        .bool => |v| v,
        else => types.StorageError.TypeMismatch,
    };
}
