//! Schema identity: the applied-schema snapshot is the source schema JSON with
//! insignificant whitespace removed. Object key order and array order are kept
//! because table, field, and action order define wire indexes.

const std = @import("std");

const json_read = @import("../json/read.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

pub const hash_prefix = "sha256:";
pub const hash_text_len = hash_prefix.len + Sha256.digest_length * 2;

/// `"sha256:<64 lowercase hex>"`
pub const Hash = [hash_text_len]u8;

/// Re-serializes `json_text` compactly. Key order, array order, and values are
/// preserved; only whitespace and number/string spelling are normalized.
/// Caller owns the result.
pub fn minify(allocator: Allocator, json_text: []const u8) ![]u8 {
    var parsed = try json_read.parseValue(allocator, json_text);
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

/// Pretty-prints `json_text` with tab indentation (the repository's Biome
/// style) for generated migration files. Caller owns the result.
pub fn pretty(allocator: Allocator, json_text: []const u8) ![]u8 {
    var parsed = try json_read.parseValue(allocator, json_text);
    defer parsed.deinit();
    const text = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_tab });
    defer allocator.free(text);
    return std.mem.concat(allocator, u8, &.{ text, "\n" });
}

/// Hash of already-minified schema JSON.
pub fn hashMinified(minified: []const u8) Hash {
    return hashBytes(minified);
}

/// `"sha256:<hex>"` of arbitrary bytes (also used for migration SQL files).
pub fn hashBytes(minified: []const u8) Hash {
    // SAFETY: fully written by Sha256.hash before it is read.
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(minified, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hash_prefix.* ++ hex;
}

/// Minified schema JSON plus its identity hash.
pub const Identity = struct {
    json: []u8,
    hash: Hash,

    pub fn init(allocator: Allocator, json_text: []const u8) !Identity {
        const minified = try minify(allocator, json_text);
        return .{ .json = minified, .hash = hashMinified(minified) };
    }

    pub fn deinit(self: Identity, allocator: Allocator) void {
        allocator.free(self.json);
    }
};
