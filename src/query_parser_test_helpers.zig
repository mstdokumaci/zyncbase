const std = @import("std");
const query_parser = @import("query_parser.zig");
const schema_manager = @import("schema_manager.zig");
const types = @import("storage_engine/types.zig");
const QueryFilter = query_parser.QueryFilter;
const Condition = query_parser.Condition;
const FieldType = schema_manager.FieldType;
const TypedValue = types.TypedValue;

pub const NamedCondition = struct {
    field: []const u8,
    op: query_parser.Operator,
    value: ?TypedValue,
    field_type: FieldType,
    items_type: ?FieldType,
};

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

fn resolveNamedCondition(
    allocator: std.mem.Allocator,
    table_metadata: *const schema_manager.TableMetadata,
    named: NamedCondition,
) !Condition {
    const field_index = table_metadata.field_index_map.get(named.field) orelse return error.UnknownField;
    return .{
        .field_index = field_index,
        .op = named.op,
        .value = if (named.value) |v| try v.clone(allocator) else null,
        .field_type = named.field_type,
        .items_type = named.items_type,
    };
}

pub fn makeFilterWithNamedConditions(
    allocator: std.mem.Allocator,
    table_metadata: *const schema_manager.TableMetadata,
    conds: []const NamedCondition,
) !QueryFilter {
    var filter = try makeDefaultFilter(allocator);
    errdefer filter.deinit(allocator);

    const heap_conds = try allocator.alloc(Condition, conds.len);
    var count: usize = 0;
    errdefer {
        for (heap_conds[0..count]) |*c| c.deinit(allocator);
        allocator.free(heap_conds);
    }

    for (conds) |c| {
        heap_conds[count] = try resolveNamedCondition(allocator, table_metadata, c);
        count += 1;
    }

    filter.conditions = heap_conds;
    return filter;
}
