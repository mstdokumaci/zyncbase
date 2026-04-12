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

test "write_command: field payload validation unknown immutable and required" {
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

    try testing.expectError(
        sth.StorageError.UnknownField,
        write_command.buildFieldWriteFromPayload(
            allocator,
            &sm,
            "items",
            "id1",
            "ns",
            "ghost",
            msgpack.Payload.intToPayload(1),
        ),
    );

    try testing.expectError(
        sth.StorageError.ImmutableField,
        write_command.buildFieldWriteFromPayload(
            allocator,
            &sm,
            "items",
            "id1",
            "ns",
            "id",
            msgpack.Payload.intToPayload(1),
        ),
    );

    try testing.expectError(
        sth.StorageError.NullNotAllowed,
        write_command.buildFieldWriteFromPayload(
            allocator,
            &sm,
            "items",
            "id1",
            "ns",
            "required_text",
            .nil,
        ),
    );
}

test "write_command: array payload validation and conversion" {
    const allocator = testing.allocator;

    var fields_arr = [_]sth.Field{sth.makeField("tags", .array, false)};
    const table = sth.Table{ .name = "items", .fields = &fields_arr };
    var sm = try sth.createSchemaManager(allocator, &[_]sth.Table{table});
    defer sm.deinit();

    // Document-write array validation: reject non-literal array elements.
    var doc_payload = msgpack.Payload.mapPayload(allocator);
    defer doc_payload.free(allocator);
    const doc_arr = try allocator.alloc(msgpack.Payload, 1);
    doc_arr[0] = msgpack.Payload.mapPayload(allocator);
    try doc_payload.mapPut("tags", .{ .arr = doc_arr });
    try testing.expectError(
        sth.StorageError.InvalidArrayElement,
        write_command.buildDocumentWriteFromPayload(allocator, &sm, "items", "id1", "ns", doc_payload),
    );

    // Field-write array validation: reject non-literal array elements.
    const bad_field_arr = try allocator.alloc(msgpack.Payload, 1);
    bad_field_arr[0] = msgpack.Payload.mapPayload(allocator);
    const bad_field_payload = msgpack.Payload{ .arr = bad_field_arr };
    defer bad_field_payload.free(allocator);
    try testing.expectError(
        sth.StorageError.InvalidArrayElement,
        write_command.buildFieldWriteFromPayload(
            allocator,
            &sm,
            "items",
            "id1",
            "ns",
            "tags",
            bad_field_payload,
        ),
    );

    // Positive case: literal arrays are converted to JSON-backed write values.
    const ok_payload = try msgpack.jsonToPayload("[1,2,3]", allocator);
    defer ok_payload.free(allocator);
    var ok = try write_command.buildFieldWriteFromPayload(
        allocator,
        &sm,
        "items",
        "id1",
        "ns",
        "tags",
        ok_payload,
    );
    defer ok.deinit(allocator);

    try testing.expect(ok.field_type == .array);
    switch (ok.value) {
        .array_json => |json| {
            try testing.expect(std.mem.startsWith(u8, json, "["));
            try testing.expect(std.mem.endsWith(u8, json, "]"));
        },
        else => return error.UnexpectedType,
    }
}
