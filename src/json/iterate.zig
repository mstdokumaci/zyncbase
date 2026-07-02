const read = @import("read.zig");

/// Iterates over JSON object fields without full parsing.
/// Calls `callback(ctx, key, value_start, value_end)` for each field.
/// `json` must start with `{` and end with `}` (or beyond).
pub fn forEachJsonField(
    json: []const u8,
    comptime Ctx: type,
    ctx: *Ctx,
    comptime callback: fn (*Ctx, []const u8, usize, usize) void,
) void {
    var pos: usize = 0;
    read.skipWhitespace(json, &pos);
    if (pos >= json.len or json[pos] != '{') return;
    pos += 1;

    while (pos < json.len) {
        read.skipWhitespace(json, &pos);
        if (pos >= json.len) return;
        if (json[pos] == '}') break;
        if (json[pos] == ',') {
            pos += 1;
            continue;
        }

        const key = read.extractJsonKey(json, &pos) orelse return;
        read.skipWhitespace(json, &pos);
        if (pos >= json.len or json[pos] != ':') return;
        pos += 1;
        read.skipWhitespace(json, &pos);

        const value_start = pos;
        read.skipValue(json, &pos) orelse return;
        const value_end = pos;

        callback(ctx, key, value_start, value_end);
    }
}

/// Iterates and extracts known fields by calling a handler per field.
/// The handler receives the raw JSON value slice for each matched key.
pub fn forEachJsonFieldExtract(
    json_bytes: []const u8,
    comptime Ctx: type,
    ctx: *Ctx,
    comptime handler: fn (*Ctx, []const u8, []const u8) void,
) void {
    const Wrapper = struct {
        inner_ctx: *Ctx,
        full_json: []const u8,
        handler_fn: *const fn (*Ctx, []const u8, []const u8) void,

        fn callback(c: *@This(), key: []const u8, value_start: usize, value_end: usize) void {
            c.handler_fn(c.inner_ctx, key, c.full_json[value_start..value_end]);
        }
    };

    var wrapper = Wrapper{
        .inner_ctx = ctx,
        .full_json = json_bytes,
        .handler_fn = handler,
    };
    forEachJsonField(json_bytes, Wrapper, &wrapper, Wrapper.callback);
}
