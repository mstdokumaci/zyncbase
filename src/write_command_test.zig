const std = @import("std");
const testing = std.testing;
const msgpack = @import("msgpack_utils.zig");
const sth = @import("storage_engine_test_helpers.zig");
const write_command = @import("storage_engine/write_command.zig");

test "write_command: document payload validation unknown table and field" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("title", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var sm = try sth.createSchemaManager(allocator, &[_]sth.Table{table});
    defer sm.deinit();

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);
    try payload.mapPut("title", try msgpack.Payload.strToPayload("v", allocator));

    try testing.expectError(
        sth.StorageError.UnknownTable,
        write_command.buildDocumentWriteFromPayload(allocator, &sm, "missing", "id1", "ns", payload),
    );

    var bad_payload = msgpack.Payload.mapPayload(allocator);
    defer bad_payload.free(allocator);
    try bad_payload.mapPut("ghost", try msgpack.Payload.strToPayload("v", allocator));
    try testing.expectError(
        sth.StorageError.UnknownField,
        write_command.buildDocumentWriteFromPayload(allocator, &sm, "items", "id1", "ns", bad_payload),
    );
}

test "write_command: document payload validation immutable and mismatch" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("title", .text, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var sm = try sth.createSchemaManager(allocator, &[_]sth.Table{table});
    defer sm.deinit();

    var immutable_payload = msgpack.Payload.mapPayload(allocator);
    defer immutable_payload.free(allocator);
    try immutable_payload.mapPut("id", try msgpack.Payload.strToPayload("x", allocator));
    try testing.expectError(
        sth.StorageError.ImmutableField,
        write_command.buildDocumentWriteFromPayload(allocator, &sm, "items", "id1", "ns", immutable_payload),
    );

    var mismatch_payload = msgpack.Payload.mapPayload(allocator);
    defer mismatch_payload.free(allocator);
    try mismatch_payload.mapPut("title", msgpack.Payload.intToPayload(1));
    try testing.expectError(
        sth.StorageError.TypeMismatch,
        write_command.buildDocumentWriteFromPayload(allocator, &sm, "items", "id1", "ns", mismatch_payload),
    );
}

test "write_command: required field null not allowed" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{
        .{
            .name = "required_text",
            .sql_type = .text,
            .required = true,
            .indexed = false,
            .references = null,
            .on_delete = null,
        },
    };
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var sm = try sth.createSchemaManager(allocator, &[_]sth.Table{table});
    defer sm.deinit();

    var payload = msgpack.Payload.mapPayload(allocator);
    defer payload.free(allocator);
    try payload.mapPut("required_text", .nil);

    try testing.expectError(
        sth.StorageError.NullNotAllowed,
        write_command.buildDocumentWriteFromPayload(allocator, &sm, "items", "id1", "ns", payload),
    );
}

test "write_command: field payload validation and invalid payload" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("score", .integer, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var sm = try sth.createSchemaManager(allocator, &[_]sth.Table{table});
    defer sm.deinit();

    const ok = try write_command.buildFieldWriteFromPayload(
        allocator,
        &sm,
        "items",
        "id1",
        "ns",
        "score",
        msgpack.Payload.intToPayload(3),
    );
    var ok_mut = ok;
    ok_mut.deinit(allocator);

    const bad = try msgpack.Payload.strToPayload("bad", allocator);
    defer bad.free(allocator);
    try testing.expectError(
        sth.StorageError.TypeMismatch,
        write_command.buildFieldWriteFromPayload(
            allocator,
            &sm,
            "items",
            "id1",
            "ns",
            "score",
            bad,
        ),
    );

    try testing.expectError(
        error.InvalidPayload,
        write_command.buildDocumentWriteFromPayload(
            allocator,
            &sm,
            "items",
            "id1",
            "ns",
            msgpack.Payload.intToPayload(7),
        ),
    );
}
