const std = @import("std");
const Allocator = std.mem.Allocator;
const schema_types = @import("../schema/types.zig");
const query_ast = @import("../query/ast.zig");
const typed = @import("../typed/types.zig");
const spmcBlockingQueue = @import("../queues/spmc_blocking_queue.zig").spmcBlockingQueue;

const Record = typed.Record;

pub const ReadKind = enum { query, subscribe, load_more };

pub const ReadRequest = struct {
    conn_id: u64,
    msg_id: u64,
    kind: ReadKind,
    table_index: usize,
    namespace_id: i64,
    filter: query_ast.QueryFilter,
    auth_predicate: ?query_ast.FilterPredicate,
    sub_id: ?u64 = null,
    allocator: Allocator,

    pub fn deinit(self: *ReadRequest, _: Allocator) void {
        self.filter.deinit(self.allocator);
        if (self.auth_predicate) |*p| p.deinit(self.allocator);
    }
};

pub const ReadResponse = struct {
    conn_id: u64,
    msg_id: u64,
    table: *const schema_types.Table,
    records: []Record,
    next_cursor_str: ?[]const u8,
    sub_id: ?u64 = null,
    err: ?anyerror = null,

    pub fn deinit(self: *ReadResponse, alloc: Allocator) void {
        for (self.records) |r| r.deinit(alloc);
        alloc.free(self.records);
        if (self.next_cursor_str) |s| alloc.free(s);
    }
};

pub const read_request_queue = spmcBlockingQueue(ReadRequest);
