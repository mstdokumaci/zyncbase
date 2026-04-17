const std = @import("std");
const schema_manager = @import("schema_manager.zig");
const types = @import("storage_engine/types.zig");
const TypedValue = types.TypedValue;
const TypedRow = types.TypedRow;
const ScalarValue = types.ScalarValue;

pub fn valText(t: []const u8) TypedValue {
    return .{ .scalar = .{ .text = t } };
}

pub fn valTextOwned(allocator: std.mem.Allocator, t: []const u8) !TypedValue {
    return .{ .scalar = .{ .text = try allocator.dupe(u8, t) } };
}

pub fn valInt(i: i64) TypedValue {
    return .{ .scalar = .{ .integer = i } };
}

pub fn valReal(r: f64) TypedValue {
    return .{ .scalar = .{ .real = r } };
}

pub fn valBool(b: bool) TypedValue {
    return .{ .scalar = .{ .boolean = b } };
}

pub fn valNil() TypedValue {
    return .nil;
}

pub fn valArray(allocator: std.mem.Allocator, scalars: []const ScalarValue) !TypedValue {
    const cloned = try allocator.alloc(ScalarValue, scalars.len);
    for (scalars, 0..) |s, i| {
        cloned[i] = switch (s) {
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            else => s,
        };
    }
    var result: TypedValue = .{ .array = cloned };
    try result.sortedSet(allocator);
    return result;
}

fn fieldTypeForValue(value: TypedValue) schema_manager.FieldType {
    return switch (value) {
        .nil => .text,
        .scalar => |scalar| switch (scalar) {
            .integer => .integer,
            .real => .real,
            .text => .text,
            .boolean => .boolean,
        },
        .array => .array,
    };
}

pub const OwnedRow = struct {
    table: schema_manager.Table,
    metadata: *schema_manager.TableMetadata,
    row: TypedRow,

    pub fn deinit(self: *OwnedRow, allocator: std.mem.Allocator) void {
        self.row.deinit(allocator);
        self.metadata.deinit(allocator);
        allocator.destroy(self.metadata);
        allocator.free(self.table.fields);
    }
};

pub fn row(allocator: std.mem.Allocator, fields: anytype) !OwnedRow {
    const T = @TypeOf(fields);
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("row fields must be a struct");

    var non_system_count: usize = 0;
    inline for (info.@"struct".fields) |f| {
        if (comptime !schema_manager.isSystemColumn(f.name)) non_system_count += 1;
    }

    const schema_fields = try allocator.alloc(schema_manager.Field, non_system_count);
    errdefer allocator.free(schema_fields);

    var write_idx: usize = 0;
    inline for (info.@"struct".fields) |f| {
        if (comptime !schema_manager.isSystemColumn(f.name)) {
            const val = @field(fields, f.name);
            const ft = fieldTypeForValue(val);
            schema_fields[write_idx] = .{
                .name = f.name,
                .sql_type = ft,
                .items_type = if (ft == .array) .text else null,
                .required = false,
                .indexed = false,
                .references = null,
                .on_delete = null,
            };
            write_idx += 1;
        }
    }

    const table = schema_manager.Table{
        .name = "_typed_test",
        .fields = schema_fields,
    };

    const metadata = try allocator.create(schema_manager.TableMetadata);
    errdefer allocator.destroy(metadata);
    metadata.* = try schema_manager.TableMetadata.init(allocator, &table);
    errdefer metadata.deinit(allocator);

    const values = try allocator.alloc(TypedValue, metadata.fields.len);
    errdefer allocator.free(values);

    for (values, 0..) |*value, i| {
        const field = metadata.fields[i];
        if (field.sql_type == .integer) {
            value.* = .{ .scalar = .{ .integer = 0 } };
        } else {
            value.* = .nil;
        }
    }

    inline for (info.@"struct".fields) |f| {
        const val = @field(fields, f.name);
        const idx = metadata.field_index_map.get(f.name) orelse @panic("unknown typed test field");
        values[idx] = try val.clone(allocator);
    }

    return .{
        .table = table,
        .metadata = metadata,
        .row = .{
            .table_metadata = metadata,
            .values = values,
        },
    };
}
