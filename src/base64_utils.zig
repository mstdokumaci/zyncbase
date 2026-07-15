const std = @import("std");

/// Decode URL-safe base64 (RFC 4648 section 5) without padding into an
/// allocator-owned slice. Tolerates optional trailing `=` padding.
pub fn urlDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const stripped = stripBase64Padding(input);
    const exact_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(stripped) catch return error.InvalidBase64;
    const dest = try allocator.alloc(u8, exact_len);
    errdefer allocator.free(dest);
    try std.base64.url_safe_no_pad.Decoder.decode(dest, stripped);
    return dest;
}

/// Encode into an allocator-owned URL-safe base64 (no padding) slice.
pub fn urlEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const len = std.base64.url_safe_no_pad.Encoder.calcSize(input.len);
    const dest = try allocator.alloc(u8, len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(dest, input);
    return dest;
}

pub fn stripBase64Padding(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == '=') {
        end -= 1;
    }
    return input[0..end];
}
