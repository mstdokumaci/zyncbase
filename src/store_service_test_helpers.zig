const std = @import("std");
const store_service = @import("store_service.zig");
const StoreService = store_service.StoreService;
const msgpack = @import("msgpack_utils.zig");
const query_parser = @import("query_parser.zig");

pub fn setNamed(
    service: *StoreService,
    table_name: []const u8,
    doc_id: []const u8,
    namespace: []const u8,
    field_name: ?[]const u8,
    value: msgpack.Payload,
) !void {
    const tbl_md = service.schema_manager.getTable(table_name) orelse return error.UnknownTable;
    const field_index = if (field_name) |name|
        tbl_md.getFieldIndex(name) orelse return error.UnknownField
    else
        null;
    const segments_len: usize = if (field_name != null) 3 else 2;
    try service.set(tbl_md.index, doc_id, namespace, segments_len, field_index, value);
}

pub fn createDocPayload(
    allocator: std.mem.Allocator,
    service: *StoreService,
    table_name: []const u8,
    fields: anytype,
) !msgpack.Payload {
    const tbl_md = service.schema_manager.getTable(table_name) orelse return error.UnknownTable;
    return @import("msgpack_test_helpers.zig").createDocumentMapPayload(allocator, tbl_md, fields);
}

pub fn createQueryPayload(
    allocator: std.mem.Allocator,
    service: *StoreService,
    table_name: []const u8,
    params: anytype,
) !msgpack.Payload {
    const tbl_md = service.schema_manager.getTable(table_name) orelse return error.UnknownTable;
    return @import("msgpack_test_helpers.zig").createQueryFilterPayload(allocator, service.schema_manager, tbl_md.index, params);
}

pub fn removeNamed(
    service: *StoreService,
    table_name: []const u8,
    doc_id: []const u8,
    namespace: []const u8,
) !void {
    const tbl_md = service.schema_manager.getTable(table_name) orelse return error.UnknownTable;
    try service.remove(tbl_md.index, doc_id, namespace, 2);
}

pub fn queryNamed(
    service: *StoreService,
    allocator: std.mem.Allocator,
    table_name: []const u8,
    namespace: []const u8,
    payload: msgpack.Payload,
) !store_service.QueryResult {
    const tbl_md = service.schema_manager.getTable(table_name) orelse return error.UnknownTable;
    return try service.query(allocator, tbl_md.index, namespace, payload);
}

pub fn queryWithCursorNamed(
    service: *StoreService,
    allocator: std.mem.Allocator,
    table_name: []const u8,
    namespace: []const u8,
    filter: *query_parser.QueryFilter,
    cursor: query_parser.Cursor,
) !@import("storage_engine.zig").ManagedResult {
    const tbl_md = service.schema_manager.getTable(table_name) orelse return error.UnknownTable;
    return try service.queryWithCursor(allocator, tbl_md.index, namespace, filter, cursor);
}
