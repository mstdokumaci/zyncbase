const std = @import("std");
const testing = std.testing;
const doc_id = @import("doc_id.zig");

test "doc_id: byte and hex roundtrips" {

    // toBytes/fromBytes roundtrip
    {
        const ids = [_]doc_id.DocId{ 0, 1, 0x0123456789abcdef0123456789abcdef, std.math.maxInt(u128) };
        for (ids) |id| {
            const bytes = doc_id.toBytes(id);
            const roundtripped = try doc_id.fromBytes(&bytes);
            try testing.expectEqual(id, roundtripped);
        }
    }

    // fromBytes error: wrong length
    {
        const short = [_]u8{0} ** 8;
        try testing.expectError(error.InvalidLength, doc_id.fromBytes(&short));
        const long = [_]u8{0} ** 20;
        try testing.expectError(error.InvalidLength, doc_id.fromBytes(&long));
    }

    // hexSlice/fromHex roundtrip
    {
        const id: doc_id.DocId = 0xdeadbeefcafe123400000000000000ff;
        var buf: [32]u8 = undefined;
        const hex = doc_id.hexSlice(id, &buf);
        try testing.expectEqual(@as(usize, 32), hex.len);
        const roundtripped = try doc_id.fromHex(hex);
        try testing.expectEqual(id, roundtripped);
    }

    // fromHex error: wrong length
    {
        const short = [_]u8{'a'} ** 16;
        try testing.expectError(error.InvalidLength, doc_id.fromHex(&short));
    }

    // fromHex error: invalid chars
    {
        const bad = "zz000000000000000000000000000000";
        try testing.expectError(error.InvalidHex, doc_id.fromHex(bad));
    }
}

test "doc_id: generateUuidV7 invariants" {
    const first = doc_id.generateUuidV7();

    // Family tag (bit 127) is set
    {
        const family_tag: u128 = @as(u128, 1) << 127;
        try testing.expect(first & family_tag != 0);
    }

    // Timestamp (bits 121..74) is within ~10s of now
    {
        const ts: u64 = @intCast((first >> 74) & 0xffffffffffff);
        const now_ms: u64 = @intCast(@max(std.time.milliTimestamp(), 0));
        try testing.expect(ts <= now_ms + 10_000);
        try testing.expect(ts >= now_ms - 10_000);
    }

    // Uniqueness: two calls produce different values
    {
        const second = doc_id.generateUuidV7();
        try testing.expect(second != first);
    }

    // Byte roundtrip preserves the packed representation
    {
        const bytes = doc_id.toBytes(first);
        const roundtripped = try doc_id.fromBytes(&bytes);
        try testing.expectEqual(first, roundtripped);
    }
}
