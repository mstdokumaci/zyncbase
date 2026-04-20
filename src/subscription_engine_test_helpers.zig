const schema_manager = @import("schema_manager.zig");
const query_parser = @import("query_parser.zig");
const types = @import("storage_engine/types.zig");
const subscription_engine = @import("subscription_engine.zig");
const SubscriptionEngine = subscription_engine.SubscriptionEngine;
const RowChange = subscription_engine.RowChange;

pub fn subscribeNamed(
    engine: *SubscriptionEngine,
    sm: *const schema_manager.SchemaManager,
    namespace: []const u8,
    table_name: []const u8,
    filter: query_parser.QueryFilter,
    conn_id: u64,
    sub_id: u64,
) !bool {
    const tbl_md = sm.getTable(table_name) orelse return error.UnknownTable;
    return try engine.subscribe(namespace, tbl_md.index, filter, conn_id, sub_id);
}

pub fn makeRowChangeNamed(
    sm: *const schema_manager.SchemaManager,
    namespace: []const u8,
    table_name: []const u8,
    op: RowChange.Operation,
    new_row: ?types.TypedRow,
    old_row: ?types.TypedRow,
) !RowChange {
    const tbl_md = sm.getTable(table_name) orelse return error.UnknownTable;
    return .{
        .namespace = namespace,
        .table_index = tbl_md.index,
        .operation = op,
        .new_row = new_row,
        .old_row = old_row,
    };
}
