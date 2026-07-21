const std = @import("std");
const query_ast = @import("ast.zig");
const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const msgpack_utils = @import("../msgpack_utils.zig");
const mth = @import("../msgpack_test_helpers.zig");
const QueryFilter = query_ast.QueryFilter;
const Condition = query_ast.Condition;
const OrClause = query_ast.OrClause;
const FieldType = schema_types.FieldType;
const Payload = msgpack_utils.Payload;

/// Creates a QueryFilter with a default order_by = "id" ASC.
/// Caller owns the memory and must call deinit(allocator).
pub fn makeDefaultFilter(allocator: std.mem.Allocator) !QueryFilter {
    return makeFilter(allocator, 0, false, .doc_id, null);
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

    filter.predicate.conditions = heap_conds;
    _ = try filter.predicate.normalize(allocator);
    return filter;
}

/// Creates a QueryFilter with AND conditions and OR clauses.
/// `or_clauses` is a slice of clauses; each clause is OR'd internally,
/// and the clauses are AND'd together (and with the AND conditions).
/// Caller owns the memory and must call deinit(allocator).
pub fn makeFilterWithOrClauses(
    allocator: std.mem.Allocator,
    and_conds: []const Condition,
    or_clauses: []const []const Condition,
) !QueryFilter {
    var filter = try makeDefaultFilter(allocator);
    errdefer filter.deinit(allocator);

    if (and_conds.len > 0) {
        const heap_conds = try allocator.alloc(Condition, and_conds.len);
        var count: usize = 0;
        errdefer {
            for (heap_conds[0..count]) |*c| c.deinit(allocator);
            allocator.free(heap_conds);
        }
        for (and_conds) |c| {
            heap_conds[count] = try c.clone(allocator);
            count += 1;
        }
        filter.predicate.conditions = heap_conds;
    }

    if (or_clauses.len > 0) {
        const heap_clauses = try allocator.alloc(OrClause, or_clauses.len);
        var clause_count: usize = 0;
        errdefer {
            for (heap_clauses[0..clause_count]) |clause| {
                for (clause) |*c| c.deinit(allocator);
                allocator.free(clause);
            }
            allocator.free(heap_clauses);
        }
        for (or_clauses) |clause_src| {
            const heap_clause = try allocator.alloc(Condition, clause_src.len);
            var cond_count: usize = 0;
            errdefer {
                for (heap_clause[0..cond_count]) |*c| c.deinit(allocator);
                allocator.free(heap_clause);
            }
            for (clause_src) |c| {
                heap_clause[cond_count] = try c.clone(allocator);
                cond_count += 1;
            }
            heap_clauses[clause_count] = heap_clause;
            clause_count += 1;
        }
        filter.predicate.or_clauses = heap_clauses;
    }

    _ = try filter.predicate.normalize(allocator);
    return filter;
}

/// Generates a MsgPack Payload representing a QueryFilter.
/// This matches the protocol format defined in ADR-025.
/// tbl_md is used to resolve field names to indices if strings are provided in params.
pub fn createQueryFilterPayload(
    allocator: std.mem.Allocator,
    tbl_md: *const schema_types.Table,
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
                    else => tbl_md.fieldIndex(raw_field) orelse return error.UnknownField,
                };

                var cond_arr = try allocator.alloc(Payload, cond_info.fields.len);
                errdefer allocator.free(cond_arr);
                cond_arr[0] = Payload.uintToPayload(f_idx);
                cond_arr[1] = Payload.uintToPayload(@intCast(cond_src[1]));
                if (cond_info.fields.len > 2) {
                    if (f_idx < tbl_md.fields.len) {
                        cond_arr[2] = try anyToFieldPayload(allocator, tbl_md.fields[f_idx].storage_type, cond_src[2]);
                    } else {
                        cond_arr[2] = try mth.anyToPayload(allocator, cond_src[2]);
                    }
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
                else => tbl_md.fieldIndex(raw_field) orelse return error.UnknownField,
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

fn anyToFieldPayload(allocator: std.mem.Allocator, field_type: FieldType, value: anytype) !Payload {
    if (field_type == .doc_id) {
        switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => {
                const bytes = typed_doc_id.toBytes(@intCast(value));
                return Payload.binToPayload(&bytes, allocator);
            },
            else => {},
        }
    }
    return mth.anyToPayload(allocator, value);
}
