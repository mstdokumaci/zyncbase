const std = @import("std");
const testing = std.testing;
const schema_mod = @import("schema.zig");
const schema_helpers = @import("schema_test_helpers.zig");
const sql = @import("storage_engine/sql.zig");
const filter_sql = @import("storage_engine/filter_sql.zig");
const query_ast = @import("query_ast.zig");
const ColumnValue = @import("storage_engine.zig").ColumnValue;
const typed = @import("typed.zig");
const Value = typed.Value;
const msgpack = @import("msgpack_utils.zig");
const mh = @import("msgpack_test_helpers.zig");
const sqlite = @import("sqlite");

test "storage SQL builders quote identifiers" {
    const allocator = std.testing.allocator;
    const fields = [_]schema_mod.Field{schema_helpers.makeField("from", .text)};
    const table = schema_helpers.makeTable("select", &fields);
    var tables = [_]schema_mod.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("select") orelse return error.TestExpectedValue;

    const columns = [_]ColumnValue{
        .{ .index = schema_mod.first_user_field_index, .value = undefined },
    };

    const insert_sql = try sql.buildUpsertDocumentSql(allocator, table_metadata, &columns, null);
    defer allocator.free(insert_sql);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "INSERT INTO \"select\" (\"id\", \"namespace_id\", \"owner_id\", \"from\", \"created_at\", \"updated_at\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"from\" = excluded.\"from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, insert_sql, "\"select\".\"namespace_id\" = excluded.\"namespace_id\"") != null);
}

test "filter SQL render cleans up all allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, renderFilterSqlForAllocationTest, .{});
}

fn renderFilterSqlForAllocationTest(allocator: std.mem.Allocator) !void {
    const fields = [_]schema_mod.Field{schema_helpers.makeField("name", .text)};
    const table = schema_helpers.makeTable("people", &fields);
    var tables = [_]schema_mod.Table{table};
    var schema = try schema_helpers.initSchemaFromTables(allocator, "1.0.0", &tables);
    defer schema.deinit();
    const table_metadata = schema.table("people") orelse return error.TestExpectedValue;
    const name_index = table_metadata.fieldIndex("name") orelse return error.TestExpectedValue;

    const conds = try allocator.alloc(query_ast.Condition, 2);
    for (conds) |*cond| {
        cond.* = .{
            .field_index = 0,
            .op = .eq,
            .value = null,
            .field_type = .text,
            .items_type = null,
        };
    }
    var predicate = query_ast.FilterPredicate{ .conditions = conds };
    var predicate_owned = true;
    errdefer if (predicate_owned) predicate.deinit(allocator);

    const eq_text = try allocator.dupe(u8, "ada");
    conds[0] = .{
        .field_index = name_index,
        .op = .eq,
        .value = .{ .scalar = .{ .text = eq_text } },
        .field_type = .text,
        .items_type = null,
    };

    const prefix_text = try allocator.dupe(u8, "a_%");
    conds[1] = .{
        .field_index = name_index,
        .op = .startsWith,
        .value = .{ .scalar = .{ .text = prefix_text } },
        .field_type = .text,
        .items_type = null,
    };

    var rendered = (try filter_sql.renderAndClause(allocator, table_metadata, &predicate)) orelse return error.TestExpectedValue;
    defer rendered.deinit(allocator);
    defer predicate.deinit(allocator);
    predicate_owned = false;

    try std.testing.expect(rendered.sqlSlice() != null);
    const rendered_values = rendered.values orelse return error.TestExpectedValue;
    try std.testing.expectEqual(@as(usize, 2), rendered_values.len);
}

test "Value: payload -> sqlite column -> payload roundtrip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const roundtripToPayload = struct {
        fn do(alloc: std.mem.Allocator, tv: Value) !msgpack.Payload {
            var out_list = std.ArrayListUnmanaged(u8).empty;
            defer out_list.deinit(alloc);
            try typed.writeMsgPack(tv, out_list.writer(alloc));
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

    const tv_int = try typed.valueFromPayload(allocator, .integer, null, int_payload);
    const tv_real = try typed.valueFromPayload(allocator, .real, null, real_payload);
    const tv_text = try typed.valueFromPayload(allocator, .text, null, text_payload);
    const tv_bool = try typed.valueFromPayload(allocator, .boolean, null, bool_payload);
    const tv_arr = try typed.valueFromPayload(allocator, .array, .integer, arr_payload);
    const tv_doc_id = Value{ .scalar = .{ .doc_id = doc_id_value } };

    var json_buf = sql.JsonBuf.init(allocator);
    defer json_buf.deinit();

    try sql.bindValue(tv_doc_id, &db, insert_stmt, 1, &json_buf);
    try sql.bindValue(tv_int, &db, insert_stmt, 2, &json_buf);
    try sql.bindValue(tv_real, &db, insert_stmt, 3, &json_buf);
    try sql.bindValue(tv_text, &db, insert_stmt, 4, &json_buf);
    try sql.bindValue(tv_bool, &db, insert_stmt, 5, &json_buf);
    try sql.bindValue(tv_arr, &db, insert_stmt, 6, &json_buf);

    try testing.expectEqual(@as(c_int, sqlite.c.SQLITE_DONE), sqlite.c.sqlite3_step(insert_stmt));

    var select_stmt_opt: ?*sqlite.c.sqlite3_stmt = null;
    const select_sql = "SELECT id, int_val, real_val, text_val, bool_val, arr_val FROM test LIMIT 1";
    try testing.expectEqual(@as(c_int, sqlite.c.SQLITE_OK), sqlite.c.sqlite3_prepare_v2(db.db, select_sql, -1, &select_stmt_opt, null));
    const select_stmt = select_stmt_opt orelse return error.TestUnexpectedResult;
    defer _ = sqlite.c.sqlite3_finalize(select_stmt);

    try testing.expectEqual(@as(c_int, sqlite.c.SQLITE_ROW), sqlite.c.sqlite3_step(select_stmt));

    const doc_id_f = schema_helpers.makeField("id", .doc_id);
    const read_tv_doc_id = try sql.typedValueFromColumn(allocator, select_stmt, 0, doc_id_f);
    const int_f = schema_helpers.makeField("int_val", .integer);
    const read_tv_int = try sql.typedValueFromColumn(allocator, select_stmt, 1, int_f);
    const real_f = schema_helpers.makeField("real_val", .real);
    const read_tv_real = try sql.typedValueFromColumn(allocator, select_stmt, 2, real_f);
    const text_f = schema_helpers.makeField("text_val", .text);
    const read_tv_text = try sql.typedValueFromColumn(allocator, select_stmt, 3, text_f);
    const bool_f = schema_helpers.makeField("bool_val", .boolean);
    const read_tv_bool = try sql.typedValueFromColumn(allocator, select_stmt, 4, bool_f);
    var arr_f = schema_helpers.makeField("arr_val", .array);
    arr_f.items_type = .integer;
    const read_tv_arr = try sql.typedValueFromColumn(allocator, select_stmt, 5, arr_f);

    const final_int_payload = try roundtripToPayload(allocator, read_tv_int);
    const final_real_payload = try roundtripToPayload(allocator, read_tv_real);
    const final_text_payload = try roundtripToPayload(allocator, read_tv_text);
    const final_bool_payload = try roundtripToPayload(allocator, read_tv_bool);
    const final_arr_payload = try roundtripToPayload(allocator, read_tv_arr);
    const final_doc_id_payload = try roundtripToPayload(allocator, read_tv_doc_id);

    try testing.expectEqual(@as(i64, -42), final_int_payload.int);
    try testing.expectEqual(@as(f64, 3.14), final_real_payload.float);
    try testing.expectEqualStrings("hello sqlite", final_text_payload.str.value());
    try testing.expectEqual(true, final_bool_payload.bool);

    try testing.expect(final_arr_payload == .arr);
    try testing.expectEqual(@as(usize, 2), final_arr_payload.arr.len);
    try testing.expectEqual(@as(u64, 10), final_arr_payload.arr[0].uint);
    try testing.expectEqual(@as(u64, 20), final_arr_payload.arr[1].uint);

    try testing.expect(final_doc_id_payload == .bin);
    const expected_doc_id_bytes = typed.docIdToBytes(doc_id_value);
    try testing.expectEqualSlices(u8, &expected_doc_id_bytes, final_doc_id_payload.bin.value());
}
