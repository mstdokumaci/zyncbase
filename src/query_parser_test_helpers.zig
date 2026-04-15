const std = @import("std");
const query_parser = @import("query_parser.zig");
const QueryFilter = query_parser.QueryFilter;
const Condition = query_parser.Condition;
const FieldType = @import("schema_manager.zig").FieldType;

/// Creates a QueryFilter with a default order_by = "id" ASC.
/// Caller owns the memory and must call deinit(allocator).
pub fn makeDefaultFilter(allocator: std.mem.Allocator) !QueryFilter {
    return makeFilter(allocator, "id", false, .text, null);
}

/// Creates a QueryFilter with a custom order_by field.
/// Caller owns the memory and must call deinit(allocator).
pub fn makeFilter(
    allocator: std.mem.Allocator,
    order_by: []const u8,
    desc: bool,
    field_type: FieldType,
    items_type: ?FieldType,
) !QueryFilter {
    return QueryFilter{
        .order_by = .{
            .field = try allocator.dupe(u8, order_by),
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
    errdefer allocator.free(heap_conds); // Note: elements not initialized yet

    for (conds, 0..) |c, i| {
        heap_conds[i] = try c.clone(allocator);
    }
    filter.conditions = heap_conds;
    return filter;
}
