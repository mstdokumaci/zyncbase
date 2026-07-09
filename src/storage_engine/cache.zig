const std = @import("std");
const Allocator = std.mem.Allocator;
const lockFreeCache = @import("../lock_free_cache.zig").lockFreeCache;
const query_ast = @import("../query_ast.zig");
const filter_eval = @import("../filter_eval.zig");
const schema = @import("../schema.zig");
const typed = @import("../typed.zig");

pub const MetadataCacheKey = struct {
    namespace_id: i64,
    table_index: usize,
    id: typed.DocId,
};

pub const metadata_cache_type = lockFreeCache(typed.Record, MetadataCacheKey);

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

pub fn getCacheKey(table_metadata: *const schema.Table, namespace_id: i64, id: typed.DocId) MetadataCacheKey {
    const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema.global_namespace_id;
    return MetadataCacheKey{
        .namespace_id = effective_namespace_id,
        .table_index = table_metadata.index,
        .id = id,
    };
}

pub const CacheHit = struct {
    record: *const typed.Record,
    handle: metadata_cache_type.Handle,
};

pub fn getCachedRecord(
    cache: *metadata_cache_type,
    cache_key: MetadataCacheKey,
    guard_predicate: ?*const query_ast.FilterPredicate,
) !?CacheHit {
    const handle = cache.get(cache_key) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    errdefer handle.release();
    if (guard_predicate) |predicate| {
        if (!try filter_eval.evaluatePredicate(predicate, handle.data())) {
            return null;
        }
    }
    return CacheHit{
        .record = handle.data(),
        .handle = handle,
    };
}
