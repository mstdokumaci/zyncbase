//! Writes from one connection must behave as if applied in send order, even
//! when the next write is classified before the previous one commits.
const std = @import("std");

const app_helpers = @import("app_test_helpers.zig");
const authorization_parse = @import("authorization/parse.zig");
const authorization_test_helpers = @import("authorization/test_helpers.zig");
const authorization_types = @import("authorization/types.zig");
const msgpack = @import("msgpack_utils.zig");
const sth = @import("storage_engine_test_helpers.zig");
const store_service = @import("store_service.zig");
const store_helpers = @import("store_test_helpers.zig");
const typed_doc_id = @import("typed/doc_id.zig");

const testing = std.testing;
const StoreService = store_service.StoreService;
const DocId = typed_doc_id.DocId;

const schema_json =
    \\{
    \\  "version": "1.0.0",
    \\  "store": {
    \\    "items": {
    \\      "required": ["name"],
    \\      "fields": {
    \\        "name": { "type": "string" },
    \\        "status": { "type": "string" }
    \\      }
    \\    }
    \\  }
    \\}
;

/// Long batch window so writes sent back-to-back share one uncommitted flush.
const batch_timeout_ms: u32 = 300;

const Fixture = struct {
    ctx: sth.EngineTestContext,
    auth_config: authorization_types.AuthConfig,
    service: StoreService,

    /// A null `auth_json` allows everything.
    fn init(self: *Fixture, allocator: std.mem.Allocator, prefix: []const u8, auth_json: ?[]const u8) !void {
        try self.ctx.initFromJsonWithPerformance(allocator, prefix, schema_json, .{ .batch_timeout = batch_timeout_ms }, .{
            .in_memory = true,
            .reader_pool_size = 1,
        });
        errdefer self.ctx.deinit();
        self.auth_config = if (auth_json) |json|
            try authorization_parse.initFromJson(allocator, json, &self.ctx.schema)
        else
            try authorization_test_helpers.permissiveTestConfig(allocator, &self.ctx.schema);
        self.service = StoreService.init(testing.io, allocator, &self.ctx.engine, &self.ctx.schema, &self.auth_config);
    }

    fn deinit(self: *Fixture) void {
        self.service.deinit();
        self.ctx.deinit();
        self.auth_config.deinit();
    }

    fn items(self: *Fixture) !sth.TableFixture {
        const metadata = self.ctx.schema.table("items") orelse return error.UnknownTable;
        return .{ .engine = &self.ctx.engine, .metadata = metadata };
    }

    /// Commit everything queued and drop the outcomes.
    fn settle(self: *Fixture) !void {
        try self.ctx.engine.flushPendingWrites();
        while (self.ctx.test_context.send_queue.?.popFrom(0)) |entry| entry.deinit();
        self.dropChanges();
    }

    /// Commit everything queued and check the outcomes in send order:
    /// null expects write_committed, otherwise the write_error code.
    fn expectOutcomes(self: *Fixture, expected: []const ?[]const u8) !void {
        const allocator = self.ctx.allocator;
        try self.ctx.engine.flushPendingWrites();
        const queue = &(self.ctx.test_context.send_queue orelse return error.MissingSendQueue);
        for (expected) |code| {
            const entry = queue.popFrom(0) orelse return error.MissingOutcome;
            defer entry.deinit();
            const parsed = try app_helpers.parseResponse(allocator, entry.data);
            defer if (parsed.code) |c| allocator.free(c);
            if (code) |want| {
                try testing.expectEqual(.write_error, parsed.resp_type);
                try testing.expectEqualStrings(want, parsed.code orelse return error.MissingCode);
            } else {
                try testing.expectEqual(.write_committed, parsed.resp_type);
            }
        }
        try testing.expect(queue.popFrom(0) == null);
        self.dropChanges();
    }

    fn dropChanges(self: *Fixture) void {
        while (self.ctx.test_context.change_queue.?.shards[0].popTimed(0)) |job| {
            var j = job;
            j.deinit(self.ctx.allocator);
        }
    }
};

fn writeCtx(msg_id: u64) StoreService.WriteContext {
    return .{
        .request = .{
            .conn_id = 1,
            .loop_id = 0,
            .user_doc_id = typed_doc_id.zero,
            .store_namespace = "public",
            .store_namespace_id = 1,
        },
        .msg_id = msg_id,
    };
}

fn docPath(allocator: std.mem.Allocator, table_index: usize, id: DocId) !msgpack.Payload {
    const arr = try allocator.alloc(msgpack.Payload, 2);
    errdefer allocator.free(arr);
    arr[0] = msgpack.Payload.uintToPayload(table_index);
    const id_bytes = typed_doc_id.toBytes(id);
    arr[1] = try msgpack.Payload.binToPayload(&id_bytes, allocator);
    return .{ .arr = arr };
}

/// Write an unrelated document and commit it, so the writer's batch window
/// restarts now and the next writes land in one uncommitted flush.
fn openBatchWindow(allocator: std.mem.Allocator, fx: *Fixture, items: sth.TableFixture) !void {
    const path = try docPath(allocator, items.metadata.index, 999);
    defer path.free(allocator);
    const value = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{.{ "name", "window" }});
    defer value.free(allocator);
    try fx.service.setPath(writeCtx(100), path, value, null);
    try fx.settle();
}

test "store race: full set after a queued remove recreates the document" {
    const allocator = std.heap.smp_allocator;
    var fx: Fixture = undefined;
    try fx.init(allocator, "store-race-remove-then-set", null);
    defer fx.deinit();
    const items = try fx.items();
    const id: DocId = 1;

    const path = try docPath(allocator, items.metadata.index, id);
    defer path.free(allocator);
    const first = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{ .{ "name", "first" }, .{ "status", "a" } });
    defer first.free(allocator);
    try fx.service.setPath(writeCtx(1), path, first, null);
    try fx.settle();

    try openBatchWindow(allocator, &fx, items);
    const second = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{ .{ "name", "second" }, .{ "status", "b" } });
    defer second.free(allocator);
    try fx.service.removePath(writeCtx(2), path, null);
    try fx.service.setPath(writeCtx(3), path, second, null);
    try fx.expectOutcomes(&.{ null, null });

    var doc = try items.getOne(allocator, id, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("name", "second");
}

test "store race: partial set after a queued create updates the document" {
    const allocator = std.heap.smp_allocator;
    var fx: Fixture = undefined;
    try fx.init(allocator, "store-race-create-then-partial-set", null);
    defer fx.deinit();
    const items = try fx.items();
    const id: DocId = 2;

    const path = try docPath(allocator, items.metadata.index, id);
    defer path.free(allocator);
    const create = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{ .{ "name", "created" }, .{ "status", "a" } });
    defer create.free(allocator);
    const partial = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{.{ "status", "b" }});
    defer partial.free(allocator);

    try openBatchWindow(allocator, &fx, items);
    try fx.service.setPath(writeCtx(1), path, create, null);
    try fx.service.setPath(writeCtx(2), path, partial, null);
    try fx.expectOutcomes(&.{ null, null });

    var doc = try items.getOne(allocator, id, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("name", "created");
    _ = try doc.expectFieldString("status", "b");
}

test "store race: a set the write rule forbids creating fails only on a missing row" {
    const allocator = std.heap.smp_allocator;
    // The candidate check sees only the incoming value; the update guard sees the stored row.
    const auth_json =
        \\{
        \\  "namespaces": [
        \\    { "pattern": "public", "storeFilter": true, "presenceRead": true, "presenceWrite": true }
        \\  ],
        \\  "store": [
        \\    { "collection": "items", "read": true, "write": { "$doc.status": { "eq": "open" } } }
        \\  ]
        \\}
    ;
    var fx: Fixture = undefined;
    try fx.init(allocator, "store-race-create-denial", auth_json);
    defer fx.deinit();
    const items = try fx.items();

    const existing = try docPath(allocator, items.metadata.index, 1);
    defer existing.free(allocator);
    const missing = try docPath(allocator, items.metadata.index, 2);
    defer missing.free(allocator);
    const seed = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{ .{ "name", "seed" }, .{ "status", "open" } });
    defer seed.free(allocator);
    const rename = try store_helpers.createDocumentMapPayload(allocator, items.metadata, .{.{ "name", "renamed" }});
    defer rename.free(allocator);

    try fx.service.setPath(writeCtx(1), existing, seed, null);
    try fx.expectOutcomes(&.{null});

    try fx.service.setPath(writeCtx(2), existing, rename, null);
    try fx.service.setPath(writeCtx(3), missing, rename, null);
    try fx.expectOutcomes(&.{ null, "PERMISSION_DENIED" });

    var doc = try items.getOne(allocator, 1, 1);
    defer doc.deinit();
    _ = try doc.expectFieldString("name", "renamed");
    const absent = try items.readDoc(allocator, 2, 1);
    defer if (absent) |r| r.deinit(allocator);
    try testing.expect(absent == null);
}
