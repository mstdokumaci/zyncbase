const std = @import("std");
const Allocator = std.mem.Allocator;
const lockFreeCache = @import("../lock_free_cache.zig").lockFreeCache;
const typed = @import("../typed.zig");

pub const MetadataCacheKey = struct {
    namespace_id: i64,
    table_index: usize,
    id: typed.DocId,
};

pub const metadata_cache_type = lockFreeCache(typed.TypedRecord, MetadataCacheKey);

pub const NamespaceCacheKey = u64;
pub const IdentityCacheKey = u64;

pub const NamespaceCacheValue = struct {
    namespace_id: i64,

    pub fn deinit(_: NamespaceCacheValue, _: Allocator) void {}
};

pub const IdentityCacheValue = struct {
    user_doc_id: typed.DocId,

    pub fn deinit(_: IdentityCacheValue, _: Allocator) void {}
};

pub const namespace_cache_type = lockFreeCache(NamespaceCacheValue, NamespaceCacheKey);
pub const identity_cache_type = lockFreeCache(IdentityCacheValue, IdentityCacheKey);

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
