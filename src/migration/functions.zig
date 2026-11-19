//! `zync_*` SQL functions available to developer migration SQL. They exist
//! only on the migration connection for the duration of a run
//! (specs/implementation/schema-migrations.md#helper-functions).

const std = @import("std");

const sqlite = @import("sqlite");

const schema_system = @import("../schema/system.zig");
const schema_types = @import("../schema/types.zig");
const typed_codec = @import("../typed/codec.zig");
const typed_doc_id = @import("../typed/doc_id.zig");

const Allocator = std.mem.Allocator;
const c = sqlite.c;

/// State shared by the helper functions. Must outlive registration.
pub const Context = struct {
    io: std.Io,
    allocator: Allocator,
    /// Next value `zync_now()` returns; strictly increasing per call.
    next_now: i64,
    /// A stored timestamp left no representable value above it.
    exhausted: bool = false,
};

const Definition = struct {
    name: [:0]const u8,
    args: c_int,
    deterministic: bool,
    func: *const fn (?*c.sqlite3_context, c_int, [*c]?*c.sqlite3_value) callconv(.c) void,
};

const definitions = [_]Definition{
    .{ .name = "zync_todo", .args = 1, .deterministic = true, .func = zyncTodo },
    .{ .name = "zync_new_id", .args = 0, .deterministic = false, .func = zyncNewId },
    .{ .name = "zync_now", .args = 0, .deterministic = false, .func = zyncNow },
    .{ .name = "zync_array", .args = 2, .deterministic = true, .func = zyncArray },
};

/// Registers every helper on `db`. Pair with `unregister` on every path.
pub fn register(db: *sqlite.Db, context: *Context) !void {
    errdefer unregister(db);
    for (definitions) |def| {
        var flags: c_int = c.SQLITE_UTF8 | c.SQLITE_DIRECTONLY;
        if (def.deterministic) flags |= c.SQLITE_DETERMINISTIC;
        const rc = c.sqlite3_create_function_v2(db.db, def.name.ptr, def.args, flags, context, def.func, null, null, null);
        if (rc != c.SQLITE_OK) return error.SQLiteError;
    }
}

/// Removes every helper from `db`.
pub fn unregister(db: *sqlite.Db) void {
    for (definitions) |def| {
        const rc = c.sqlite3_create_function_v2(db.db, def.name.ptr, def.args, c.SQLITE_UTF8, null, null, null, null, null);
        if (rc != c.SQLITE_OK) std.log.warn("Failed to unregister {s}: {s}", .{ def.name, std.mem.span(c.sqlite3_errmsg(db.db)) });
    }
}

/// The first `zync_now()` value: above the wall clock and every existing
/// `created_at` in `tables`.
pub fn nowFloor(io: std.Io, db: *sqlite.Db, arena: Allocator, tables: []const []const u8) !i64 {
    var floor = std.Io.Clock.real.now(io).toMicroseconds();
    for (tables) |table| {
        // NULL (empty table) reads as -1 so it never raises the floor.
        const sql = try std.fmt.allocPrint(arena, "SELECT coalesce(max(\"created_at\"), -1) FROM \"{s}\"", .{table});
        const max = (try db.oneDynamic(i64, sql, .{}, .{})) orelse -1;
        const next = std.math.add(i64, max, 1) catch return error.TimestampRangeExhausted;
        floor = @max(floor, next);
    }
    return floor;
}

fn contextOf(ctx: ?*c.sqlite3_context) *Context {
    return @ptrCast(@alignCast(c.sqlite3_user_data(ctx)));
}

fn resultError(ctx: ?*c.sqlite3_context, message: []const u8) void {
    c.sqlite3_result_error(ctx, message.ptr, @intCast(message.len));
}

fn valueText(value: ?*c.sqlite3_value) []const u8 {
    const ptr = c.sqlite3_value_text(value);
    const len: usize = @intCast(c.sqlite3_value_bytes(value));
    return if (ptr != null) ptr[0..len] else "";
}

/// Placeholder for an unresolved decision. The pre-pass rejects any use, so
/// this only runs if that check is bypassed.
fn zyncTodo(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc;
    const prefix = "zync_todo: ";
    var buf: [512]u8 = undefined;
    const text = valueText(argv[0]);
    const shown = text[0..@min(text.len, buf.len - prefix.len)];
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..shown.len], shown);
    resultError(ctx, buf[0 .. prefix.len + shown.len]);
}

fn zyncNewId(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc;
    _ = argv;
    const context = contextOf(ctx);
    const id = typed_doc_id.generateUuidV7(context.io) catch {
        resultError(ctx, "zync_new_id: random source unavailable");
        return;
    };
    const bytes = typed_doc_id.toBytes(id);
    c.sqlite3_result_blob(ctx, &bytes, bytes.len, c.sqliteTransientAsDestructor());
}

fn zyncNow(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc;
    _ = argv;
    const context = contextOf(ctx);
    if (context.exhausted) {
        resultError(ctx, "zync_now: no timestamp above the stored values is available");
        return;
    }
    // A long-running migration can outlive the floor taken at registration.
    const wall = std.Io.Clock.real.now(context.io).toMicroseconds();
    if (wall > context.next_now) context.next_now = wall;
    if (context.next_now > schema_system.max_safe_timestamp_us) {
        resultError(ctx, "zync_now: timestamp exceeds the JavaScript-safe range");
        return;
    }
    c.sqlite3_result_int64(ctx, context.next_now);
    context.next_now += 1;
}

const items_types = std.StaticStringMap(schema_types.FieldType).initComptime(.{
    .{ "string", .text },
    .{ "integer", .integer },
    .{ "number", .real },
    .{ "boolean", .boolean },
});

/// `zync_array(json, items)`: canonical array JSON (validated, sorted,
/// de-duplicated) exactly as the runtime write path encodes it.
fn zyncArray(ctx: ?*c.sqlite3_context, argc: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    _ = argc;
    const context = contextOf(ctx);

    switch (c.sqlite3_value_type(argv[0])) {
        c.SQLITE_NULL => {
            c.sqlite3_result_null(ctx);
            return;
        },
        c.SQLITE_TEXT => {},
        c.SQLITE_BLOB => {
            resultError(ctx, "zync_array: pass JSON text; wrap stored arrays with json(<column>)");
            return;
        },
        else => {
            resultError(ctx, "zync_array: expected a JSON array, e.g. json_array(...)");
            return;
        },
    }
    const items_type = items_types.get(valueText(argv[1])) orelse {
        resultError(ctx, "zync_array: items must be 'string', 'integer', 'number', or 'boolean'");
        return;
    };

    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, valueText(argv[0]), .{}) catch {
        resultError(ctx, "zync_array: argument is not valid JSON");
        return;
    };
    if (parsed != .array) {
        resultError(ctx, "zync_array: expected a JSON array");
        return;
    }
    const value = typed_codec.fromJson(arena, .array, items_type, parsed) catch |err| {
        const message = switch (err) {
            error.NullNotAllowed => "zync_array: arrays cannot contain null",
            error.TypeMismatch => "zync_array: an element does not match the items type",
            error.InvalidArrayElement => "zync_array: elements must be scalars",
            else => "zync_array: cannot build the array",
        };
        resultError(ctx, message);
        return;
    };

    var out = std.ArrayListUnmanaged(u8).empty;
    typed_codec.writeJsonToBuf(&out, arena, value) catch |err| switch (err) {
        error.OutOfMemory => c.sqlite3_result_error_nomem(ctx),
        else => resultError(ctx, @errorName(err)),
    };
    c.sqlite3_result_text(ctx, out.items.ptr, @intCast(out.items.len), c.sqliteTransientAsDestructor());
}
