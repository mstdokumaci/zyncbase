const std = @import("std");
const iterate = @import("iterate.zig");

fn countCallback(ctx: *CountCtx, _: []const u8, _: usize, _: usize) void {
    ctx.count += 1;
}

fn keyCallback(ctx: *CountCtx, key: []const u8, _: usize, _: usize) void {
    ctx.count += 1;
    ctx.last_key = key;
}

const CountCtx = struct {
    count: usize = 0,
    last_key: []const u8 = "",
};

test "forEachJsonField iterates all fields" {
    var ctx = CountCtx{};
    iterate.forEachJsonField(
        \\{"a":1,"b":2,"c":3}
    , CountCtx, &ctx, keyCallback);

    try std.testing.expectEqual(@as(usize, 3), ctx.count);
    try std.testing.expectEqualStrings("c", ctx.last_key);
}

test "forEachJsonField handles empty object" {
    var ctx = CountCtx{};
    iterate.forEachJsonField(
        \\{}
    , CountCtx, &ctx, countCallback);
    try std.testing.expectEqual(@as(usize, 0), ctx.count);
}

fn nestedCallback(ctx: *NestedCtx, key: []const u8, _: usize, _: usize) void {
    if (std.mem.eql(u8, key, "session")) {
        ctx.found_nested = true;
    }
}

const NestedCtx = struct {
    found_nested: bool = false,
};

test "forEachJsonField handles nested values" {
    var ctx = NestedCtx{};
    iterate.forEachJsonField(
        \\{"sub":"u1","session":{"id":42},"exp":1}
    , NestedCtx, &ctx, nestedCallback);
    try std.testing.expect(ctx.found_nested);
}

fn extractHandler(ctx: *ExtractCtx, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "sub")) {
        ctx.sub = value;
    } else if (std.mem.eql(u8, key, "exp")) {
        ctx.exp = std.fmt.parseInt(i64, value, 10) catch return;
    }
}

const ExtractCtx = struct {
    sub: []const u8 = "",
    exp: i64 = 0,
};

test "forEachJsonFieldExtract returns value slices" {
    var ctx = ExtractCtx{};
    iterate.forEachJsonFieldExtract(
        \\{"sub":"user1","exp":1234567890,"jti":"abc"}
    , ExtractCtx, &ctx, extractHandler);

    try std.testing.expectEqualStrings("\"user1\"", ctx.sub);
    try std.testing.expectEqual(@as(i64, 1234567890), ctx.exp);
}
