const std = @import("std");
const query_parser = @import("query_parser.zig");
const schema_manager = @import("schema_manager.zig");
const msgpack_utils = @import("msgpack_utils.zig");
const mth = @import("msgpack_test_helpers.zig");
const QueryFilter = query_parser.QueryFilter;
const Condition = query_parser.Condition;
const FieldType = schema_manager.FieldType;
const Payload = msgpack_utils.Payload;

/// Creates a QueryFilter with a default order_by = "id" ASC.
/// Caller owns the memory and must call deinit(allocator).
pub fn makeDefaultFilter(allocator: std.mem.Allocator) !QueryFilter {
    return makeFilter(allocator, 0, false, .text, null);
}

/// Creates a QueryFilter with a custom order_by field index.
/// Caller owns the memory and must call deinit(allocator).
pub fn makeFilter(
    allocator: std.mem.Allocator,
    order_by_field_index: usize,
    desc: bool,
    field_type: FieldType,
    items_type: ?FieldType,
) !QueryFilter {
    _ = allocator;
    return QueryFilter{
        .order_by = .{
            .field_index = order_by_field_index,
            .desc = desc,
            .field_type = field_type,
            .items_type = items_type,
        },
    };
}

/// Creates a QueryFilter with the given conditions and a default order_by = "id" ASC.
/// This helper handles heap allocation for both the order_by field and the conditions slice/elements,
/// ensuring that QueryFilter.deinit(allocator) can safely clean up all resources.
pub fn makeFilterWithConditions(allocator: std.mem.Allocator, conds: []const Condition) !QueryFilter {
    var filter = try makeDefaultFilter(allocator);
    errdefer filter.deinit(allocator);

    const heap_conds = try allocator.alloc(Condition, conds.len);
    var count: usize = 0;
    errdefer {
        for (heap_conds[0..count]) |*c| c.deinit(allocator);
        allocator.free(heap_conds);
    }

    for (conds) |c| {
        heap_conds[count] = try c.clone(allocator);
        count += 1;
    }

    filter.conditions = heap_conds;
    return filter;
}

/// Generates a MsgPack Payload representing a QueryFilter.
/// This matches the protocol format defined in ADR-025.
/// tbl_md is used to resolve field names to indices if strings are provided in params.
pub fn createQueryFilterPayload(
    allocator: std.mem.Allocator,
    tbl_md: *const schema_manager.TableMetadata,
    params: anytype,
) !Payload {
    var filter_map = msgpack_utils.Payload.mapPayload(allocator);
    errdefer filter_map.free(allocator);

    const ParamType = @TypeOf(params);
    const param_fields = @typeInfo(ParamType).@"struct".fields;

    inline for (param_fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "conditions") or std.mem.eql(u8, f.name, "or_conditions")) {
            const conditions = @field(params, f.name);
            var count: usize = 0;
            inline for (conditions) |_| count += 1;

            var conds_arr = try allocator.alloc(Payload, count);
            errdefer allocator.free(conds_arr);

            inline for (conditions, 0..) |cond_src, ci| {
                const cond_info = @typeInfo(@TypeOf(cond_src)).@"struct";
                const raw_field = cond_src[0];
                const f_idx = switch (@typeInfo(@TypeOf(raw_field))) {
                    .int, .comptime_int => @as(usize, @intCast(raw_field)),
                    else => tbl_md.getFieldIndex(raw_field) orelse return error.UnknownField,
                };

                var cond_arr = try allocator.alloc(Payload, cond_info.fields.len);
                errdefer allocator.free(cond_arr);
                cond_arr[0] = Payload.uintToPayload(f_idx);
                cond_arr[1] = Payload.uintToPayload(@intCast(cond_src[1]));
                if (cond_info.fields.len > 2) {
                    cond_arr[2] = try mth.anyToPayload(allocator, cond_src[2]);
                }
                conds_arr[ci] = Payload{ .arr = cond_arr };
            }
            const key = if (comptime std.mem.eql(u8, f.name, "or_conditions")) "orConditions" else "conditions";
            try filter_map.mapPut(key, Payload{ .arr = conds_arr });
        } else if (comptime std.mem.eql(u8, f.name, "orderBy")) {
            const order_by = @field(params, f.name);
            const raw_field = order_by[0];
            const f_idx = switch (@typeInfo(@TypeOf(raw_field))) {
                .int, .comptime_int => @as(usize, @intCast(raw_field)),
                else => tbl_md.getFieldIndex(raw_field) orelse return error.UnknownField,
            };

            var order_arr = try allocator.alloc(Payload, 2);
            errdefer allocator.free(order_arr);
            order_arr[0] = Payload.uintToPayload(f_idx);
            order_arr[1] = Payload.uintToPayload(@intCast(order_by[1]));
            try filter_map.mapPut("orderBy", Payload{ .arr = order_arr });
        } else if (comptime std.mem.eql(u8, f.name, "limit")) {
            const limit = @field(params, f.name);
            try filter_map.mapPut("limit", Payload.uintToPayload(@intCast(limit)));
        } else if (comptime std.mem.eql(u8, f.name, "cursor")) {
            const cursor = @field(params, f.name);
            if (@TypeOf(cursor) == Payload) {
                try filter_map.mapPut("after", try cursor.deepClone(allocator));
            } else {
                try filter_map.mapPut("after", try mth.anyToPayload(allocator, cursor));
            }
        }
    }

    return filter_map;
}
