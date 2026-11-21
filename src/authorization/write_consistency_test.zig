const std = @import("std");

const msgpack = @import("msgpack");

const qth = @import("../query/test_helpers.zig");
const schema_helpers = @import("../schema/test_helpers.zig");
const sth = @import("../storage_engine_test_helpers.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const authorization_parse = @import("parse.zig");
const authorization_store = @import("store.zig");

const testing = std.testing;

// A create is judged in memory against the candidate row; an update or
// delete is judged in SQL against the stored row. For the same NULL field,
// both must reach the same verdict, or a creator can make a row it can never
// change again.
test "store write rules judge NULL fields the same on create and on update" {
    const allocator = std.heap.smp_allocator;

    var fields_arr = [_]sth.Field{
        schema_helpers.makeField("title", .text),
        schema_helpers.makeField("status", .text),
        schema_helpers.makeField("priority", .integer),
    };
    var ctx: sth.EngineTestContext = undefined;
    try sth.setupEngine(&ctx, allocator, "auth-null-consistency", schema_helpers.makeTable("tasks", &fields_arr));
    defer ctx.deinit();

    const tasks = try ctx.tableMetadata("tasks");
    const title_index = tasks.fieldIndex("title") orelse return error.UnknownField;
    const status_index = tasks.fieldIndex("status") orelse return error.UnknownField;
    const priority_index = tasks.fieldIndex("priority") orelse return error.UnknownField;

    // The stored row: status and priority are NULL.
    try ctx.insertText("tasks", 1, 1, "title", "t");
    try ctx.engine.flushPendingWrites();

    // The create that made it: status and priority explicitly null.
    var create_items = try allocator.alloc(msgpack.Payload, 6);
    create_items[0] = msgpack.Payload.uintToPayload(title_index);
    create_items[1] = try msgpack.Payload.strToPayload("t", allocator);
    create_items[2] = msgpack.Payload.uintToPayload(status_index);
    create_items[3] = .nil;
    create_items[4] = msgpack.Payload.uintToPayload(priority_index);
    create_items[5] = .nil;
    var create_payload = msgpack.Payload{ .arr = create_items };
    defer create_payload.free(allocator);

    // A create that omits both fields entirely; absence resolves as NULL too.
    var absent_items = try allocator.alloc(msgpack.Payload, 2);
    absent_items[0] = msgpack.Payload.uintToPayload(title_index);
    absent_items[1] = try msgpack.Payload.strToPayload("t", allocator);
    var absent_payload = msgpack.Payload{ .arr = absent_items };
    defer absent_payload.free(allocator);

    const create_payloads = [_]*const msgpack.Payload{ &create_payload, &absent_payload };

    var update_items = try allocator.alloc(msgpack.Payload, 2);
    update_items[0] = msgpack.Payload.uintToPayload(title_index);
    update_items[1] = try msgpack.Payload.strToPayload("t2", allocator);
    var update_payload = msgpack.Payload{ .arr = update_items };
    defer update_payload.free(allocator);

    const rules = [_][]const u8{
        \\{"$doc.status":{"eq":"open"}}
        ,
        \\{"$doc.status":{"ne":"archived"}}
        ,
        \\{"$doc.priority":{"gt":5}}
        ,
        \\{"$doc.priority":{"gte":5}}
        ,
        \\{"$doc.priority":{"lt":5}}
        ,
        \\{"$doc.priority":{"lte":5}}
        ,
        \\{"$doc.status":{"in":["open"]}}
        ,
        \\{"$doc.status":{"in":[]}}
        ,
        \\{"$doc.status":{"notIn":["archived"]}}
        ,
        \\{"$doc.status":{"notIn":[]}}
        ,
        \\{"$doc.status":{"startsWith":"a"}}
        ,
        \\{"$doc.status":"isNull"}
        ,
        \\{"$doc.status":"isNotNull"}
        ,
    };

    var mismatches: usize = 0;
    for (create_payloads) |create_value| {
        for (rules) |rule| {
            const json = try std.fmt.allocPrint(allocator,
                \\{{"namespaces":[{{"pattern":"public","storeFilter":true,"presenceRead":true,"presenceWrite":true}}],
                \\ "store":[{{"collection":"tasks","read":true,"write":{s}}}]}}
            , .{rule});
            defer allocator.free(json);
            var config = try authorization_parse.initFromJson(allocator, json, &ctx.schema);
            defer config.deinit();

            const input: authorization_store.StoreWriteInput = .{
                .config = &config,
                .table = tasks,
                .session_user_id = try typed_doc_id.generateUuidV7(std.testing.io),
                .namespace = "public",
                .doc_id = 1,
                .is_create = true,
            };

            var create_input = input;
            create_input.value = create_value;
            const create_allowed = try allowsCreate(allocator, create_input);

            var update_input = input;
            update_input.value = &update_payload;
            update_input.is_create = false;
            const update_allowed = try allowsUpdate(allocator, &ctx, tasks.index, update_input);

            if (std.mem.eql(u8, rule, "{\"$doc.status\":{\"notIn\":[]}}")) {
                try testing.expect(create_allowed);
                try testing.expect(update_allowed);
            } else if (std.mem.eql(u8, rule, "{\"$doc.status\":{\"in\":[]}}")) {
                try testing.expect(!create_allowed);
                try testing.expect(!update_allowed);
            }

            if (create_allowed != update_allowed) {
                mismatches += 1;
                std.debug.print("rule {s}: create allowed: {}, update allowed: {}\n", .{ rule, create_allowed, update_allowed });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), mismatches);
}

fn allowsCreate(allocator: std.mem.Allocator, input: authorization_store.StoreWriteInput) !bool {
    var guard = authorization_store.authorizeStoreWrite(allocator, input) catch |err| switch (err) {
        error.AccessDenied => return false,
        else => return err,
    };
    if (guard) |*g| g.deinit(allocator);
    return true;
}

/// An update applies when its guard, rendered to SQL, matches the stored row.
fn allowsUpdate(
    allocator: std.mem.Allocator,
    ctx: *sth.EngineTestContext,
    table_index: usize,
    input: authorization_store.StoreWriteInput,
) !bool {
    const guard = authorization_store.authorizeStoreWrite(allocator, input) catch |err| switch (err) {
        error.AccessDenied => return false,
        else => return err,
    };
    var filter = try qth.makeDefaultFilter(allocator);
    defer filter.deinit(allocator);
    if (guard) |g| filter.predicate = g;

    const rows = try sth.queryDocs(allocator, &ctx.engine, table_index, 1, &filter);
    defer rows.deinit(allocator);
    return rows.records.len == 1;
}
