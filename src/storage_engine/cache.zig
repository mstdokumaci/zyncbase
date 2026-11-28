const std = @import("std");

const typed_doc_id = @import("../typed/doc_id.zig");
const lockedMap = @import("../memory/locked_map.zig").lockedMap;

const DocId = typed_doc_id.DocId;

pub const namespace_cache_type = lockedMap(u64, i64, std.Io.Mutex); // zwanzig-disable-line: identifier-style
pub const identity_cache_type = lockedMap(u64, DocId, std.Io.Mutex); // zwanzig-disable-line: identifier-style

pub const NamespaceCacheKey = u64;
pub const IdentityCacheKey = u64;

pub fn namespaceCacheKey(namespace: []const u8) NamespaceCacheKey {
    return std.hash.Wyhash.hash(0x9e3779b97f4a7c15, namespace);
}

pub fn identityCacheKey(identity_namespace_id: i64, external_user_id: []const u8) IdentityCacheKey {
    var hasher = std.hash.Wyhash.init(0xd1b54a32d192ed03);
    std.hash.autoHash(&hasher, identity_namespace_id);
    hasher.update("\x00");
    hasher.update(external_user_id);
    return hasher.final();
}
