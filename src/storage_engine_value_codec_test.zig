const std = @import("std");
const testing = std.testing;
const sqlite = @import("sqlite");
const sql = @import("storage_engine/sql.zig");
const values = @import("storage_engine/values.zig");
const value_codec = @import("storage_engine/value_codec.zig");
const TypedValue = values.TypedValue;
const schema_manager = @import("schema_manager.zig");
const msgpack = @import("msgpack_utils.zig");
const mh = @import("msgpack_test_helpers.zig");
const doc_id = @import("doc_id.zig");

test "TypedValue: payload -> json array -> payload roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Helper: TypedValue -> JSON string -> TypedValue -> msgpack -> Payload
    const roundtripJsonValue = struct {
        fn do(alloc: std.mem.Allocator, ft: schema_manager.FieldType, items_type: ?schema_manager.FieldType, tv: TypedValue) !msgpack.Payload {
            const json_str = try value_codec.jsonAlloc(alloc, tv);
            const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
            defer parsed.deinit();
            const roundtripped = try value_codec.fromJson(alloc, ft, items_type, parsed.value);
            var out_list = std.ArrayListUnmanaged(u8).empty;
            defer out_list.deinit(alloc);
            try value_codec.writeMsgPack(roundtripped, out_list.writer(alloc));
            var reader: std.Io.Reader = .fixed(out_list.items);
            return try msgpack.decode(alloc, &reader);
        }
    }.do;

    // 1. Integer array — sorted/deduped by fromPayload
    {
        var arr = [_]msgpack.Payload{ .{ .int = 3 }, .{ .int = 1 }, .{ .int = 2 } };
        const tv = try value_codec.fromPayload(allocator, .array, .integer, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .integer, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 3), result.arr.len);
        try testing.expectEqual(@as(u64, 1), result.arr[0].uint);
        try testing.expectEqual(@as(u64, 2), result.arr[1].uint);
        try testing.expectEqual(@as(u64, 3), result.arr[2].uint);
    }

    // 2. Real array
    {
        var arr = [_]msgpack.Payload{ .{ .float = 2.5 }, .{ .float = 1.1 } };
        const tv = try value_codec.fromPayload(allocator, .array, .real, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .real, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 2), result.arr.len);
        try testing.expectEqual(@as(f64, 1.1), result.arr[0].float);
        try testing.expectEqual(@as(f64, 2.5), result.arr[1].float);
    }

    // 3. Text array
    {
        const s1 = try mh.anyToPayload(allocator, "banana");
        const s2 = try mh.anyToPayload(allocator, "apple");
        var arr = [_]msgpack.Payload{ s1, s2 };
        const tv = try value_codec.fromPayload(allocator, .array, .text, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .text, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 2), result.arr.len);
        try testing.expectEqualStrings("apple", result.arr[0].str.value());
        try testing.expectEqualStrings("banana", result.arr[1].str.value());
    }

    // 4. Boolean array
    {
        var arr = [_]msgpack.Payload{ .{ .bool = true }, .{ .bool = false } };
        const tv = try value_codec.fromPayload(allocator, .array, .boolean, .{ .arr = arr[0..] });
        const result = try roundtripJsonValue(allocator, .array, .boolean, tv);

        try testing.expect(result == .arr);
        try testing.expectEqual(@as(usize, 2), result.arr.len);
        // Sorted: false < true
        try testing.expectEqual(false, result.arr[0].bool);
        try testing.expectEqual(true, result.arr[1].bool);
    }

    // 5. doc_id scalar — stringified as hex and parsed back
    {
        const original_id: u128 = 0x0123456789abcdef0123456789abcdef;
        const tv = TypedValue{ .scalar = .{ .doc_id = original_id } };
        const result = try roundtripJsonValue(allocator, .doc_id, null, tv);

        try testing.expect(result == .bin);
        const expected_bytes = doc_id.toBytes(original_id);
        try testing.expectEqualSlices(u8, &expected_bytes, result.bin.value());
    }
}

test "TypedValue: payload -> sqlite column -> payload roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Helper to evaluate to payload via msgpack
    const roundtripToPayload = struct {
        fn do(alloc: std.mem.Allocator, tv: TypedValue) !msgpack.Payload {
            var out_list = std.ArrayListUnmanaged(u8).empty;
            defer out_list.deinit(alloc);
            try value_codec.writeMsgPack(tv, out_list.writer(alloc));
            var reader: std.Io.Reader = .fixed(out_list.items);
            const decoded = try msgpack.decode(alloc, &reader);
            return decoded;
        }
    }.do;

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .Memory = {} },
        .open_flags = .{ .write = true },
        .threading_mode = .MultiThread,
    });
    defer db.deinit();

    try db.exec("CREATE TABLE test (id BLOB NOT NULL CHECK(length(id) = 16), int_val INTEGER, real_val REAL, text_val TEXT, bool_val INTEGER, arr_val TEXT, PRIMARY KEY (id))", .{}, .{});

    var insert_stmt_opt: ?*sqlite.c.sqlite3_stmt = null;
    const insert_sql = "INSERT INTO test (id, int_val, real_val, text_val, bool_val, arr_val) VALUES (?, ?, ?, ?, ?, ?)";
    try testing.expectEqual(@as(c_int, sqlite.c.SQLITE_OK), sqlite.c.sqlite3_prepare_v2(db.db, insert_sql, -1, &insert_stmt_opt, null));
    const insert_stmt = insert_stmt_opt orelse return error.TestUnexpectedResult;
    defer _ = sqlite.c.sqlite3_finalize(insert_stmt);

    const int_payload = msgpack.Payload{ .int = -42 };
    const real_payload = msgpack.Payload{ .float = 3.14 };
    const text_payload = try mh.anyToPayload(allocator, "hello sqlite");
    const bool_payload = msgpack.Payload{ .bool = true };
    var array_payload_items = [_]msgpack.Payload{ .{ .int = 10 }, .{ .int = 20 } };
    const arr_payload = msgpack.Payload{ .arr = array_payload_items[0..] };
    const doc_id_value: u128 = 0x00112233445566778899aabbccddeeff;

    // Convert to TypedValues
    const tv_int = try value_codec.fromPayload(allocator, .integer, null, int_payload);
    const tv_real = try value_codec.fromPayload(allocator, .real, null, real_payload);
    const tv_text = try value_codec.fromPayload(allocator, .text, null, text_payload);
    const tv_bool = try value_codec.fromPayload(allocator, .boolean, null, bool_payload);
    const tv_arr = try value_codec.fromPayload(allocator, .array, .integer, arr_payload);
    const tv_doc_id = TypedValue{ .scalar = .{ .doc_id = doc_id_value } };

    // Bind values
    try sql.bindTypedValue(tv_doc_id, &db, insert_stmt, 1, allocator);
    try sql.bindTypedValue(tv_int, &db, insert_stmt, 2, allocator);
    try sql.bindTypedValue(tv_real, &db, insert_stmt, 3, allocator);
    try sql.bindTypedValue(tv_text, &db, insert_stmt, 4, allocator);
    try sql.bindTypedValue(tv_bool, &db, insert_stmt, 5, allocator);
    try sql.bindTypedValue(tv_arr, &db, insert_stmt, 6, allocator);

    try testing.expectEqual(@as(c_int, sqlite.c.SQLITE_DONE), sqlite.c.sqlite3_step(insert_stmt));

    // Query values back
    var select_stmt_opt: ?*sqlite.c.sqlite3_stmt = null;
    const select_sql = "SELECT id, int_val, real_val, text_val, bool_val, arr_val FROM test LIMIT 1";
    try testing.expectEqual(@as(c_int, sqlite.c.SQLITE_OK), sqlite.c.sqlite3_prepare_v2(db.db, select_sql, -1, &select_stmt_opt, null));
    const select_stmt = select_stmt_opt orelse return error.TestUnexpectedResult;
    defer _ = sqlite.c.sqlite3_finalize(select_stmt);

    try testing.expectEqual(@as(c_int, sqlite.c.SQLITE_ROW), sqlite.c.sqlite3_step(select_stmt));

    // Reconstruct TypedValues from columns
    const doc_id_f = schema_manager.Field{ .name = "id", .sql_type = .doc_id, .items_type = null, .required = false, .indexed = false, .references = null, .on_delete = null };
    const read_tv_doc_id = try sql.typedValueFromColumn(allocator, select_stmt, 0, doc_id_f);
    const int_f = schema_manager.Field{ .name = "int_val", .sql_type = .integer, .items_type = null, .required = false, .indexed = false, .references = null, .on_delete = null };
    const read_tv_int = try sql.typedValueFromColumn(allocator, select_stmt, 1, int_f);
    const real_f = schema_manager.Field{ .name = "real_val", .sql_type = .real, .items_type = null, .required = false, .indexed = false, .references = null, .on_delete = null };
    const read_tv_real = try sql.typedValueFromColumn(allocator, select_stmt, 2, real_f);
    const text_f = schema_manager.Field{ .name = "text_val", .sql_type = .text, .items_type = null, .required = false, .indexed = false, .references = null, .on_delete = null };
    const read_tv_text = try sql.typedValueFromColumn(allocator, select_stmt, 3, text_f);
    const bool_f = schema_manager.Field{ .name = "bool_val", .sql_type = .boolean, .items_type = null, .required = false, .indexed = false, .references = null, .on_delete = null };
    const read_tv_bool = try sql.typedValueFromColumn(allocator, select_stmt, 4, bool_f);
    const arr_f = schema_manager.Field{ .name = "arr_val", .sql_type = .array, .items_type = .integer, .required = false, .indexed = false, .references = null, .on_delete = null };
    const read_tv_arr = try sql.typedValueFromColumn(allocator, select_stmt, 5, arr_f);

    // Convert roundtripped back to payloads
    const final_int_payload = try roundtripToPayload(allocator, read_tv_int);
    const final_real_payload = try roundtripToPayload(allocator, read_tv_real);
    const final_text_payload = try roundtripToPayload(allocator, read_tv_text);
    const final_bool_payload = try roundtripToPayload(allocator, read_tv_bool);
    const final_arr_payload = try roundtripToPayload(allocator, read_tv_arr);
    const final_doc_id_payload = try roundtripToPayload(allocator, read_tv_doc_id);

    // Equality Checks
    try testing.expectEqual(@as(i64, -42), final_int_payload.int);
    try testing.expectEqual(@as(f64, 3.14), final_real_payload.float);
    try testing.expectEqualStrings("hello sqlite", final_text_payload.str.value());
    try testing.expectEqual(true, final_bool_payload.bool);

    try testing.expect(final_arr_payload == .arr);
    try testing.expectEqual(@as(usize, 2), final_arr_payload.arr.len);
    try testing.expectEqual(@as(u64, 10), final_arr_payload.arr[0].uint); // decoded as uint
    try testing.expectEqual(@as(u64, 20), final_arr_payload.arr[1].uint);

    try testing.expect(final_doc_id_payload == .bin);
    const expected_doc_id_bytes = doc_id.toBytes(doc_id_value);
    try testing.expectEqualSlices(u8, &expected_doc_id_bytes, final_doc_id_payload.bin.value());
}
