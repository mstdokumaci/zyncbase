const std = @import("std");

const lockFreeCache = @import("../memory/lock_free_cache.zig").lockFreeCache;
const lockedMap = @import("../memory/locked_map.zig").lockedMap;
const schema_system = @import("../schema/system.zig");
const schema_types = @import("../schema/types.zig");
const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");

const DocId = typed_doc_id.DocId;

pub const DocumentCacheKey = struct {
    namespace_id: i64,
    table_index: usize,
    id: typed_doc_id.DocId,
};

pub const document_cache_type = lockFreeCache(typed.Record, DocumentCacheKey);

pub const namespace_cache_type = lockedMap(u64, i64, std.Thread.Mutex); // zwanzig-disable-line: identifier-style
pub const identity_cache_type = lockedMap(u64, DocId, std.Thread.Mutex); // zwanzig-disable-line: identifier-style

pub const pk_set_type = lockedMap(DocId, void, std.Thread.RwLock); // zwanzig-disable-line: identifier-style

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

pub fn getCacheKey(table_metadata: *const schema_types.Table, namespace_id: i64, id: typed_doc_id.DocId) DocumentCacheKey {
    const effective_namespace_id = if (table_metadata.namespaced) namespace_id else schema_system.global_namespace_id;
    return DocumentCacheKey{
        .namespace_id = effective_namespace_id,
        .table_index = table_metadata.index,
        .id = id,
    };
}

pub const CacheHit = struct {
    record: *typed.Record,
    handle: document_cache_type.Handle,
};

pub const GetCacheResult = union(enum) {
    miss,
    hit: CacheHit,
};

pub fn getCachedRecord(
    cache: *document_cache_type,
    cache_key: DocumentCacheKey,
) GetCacheResult {
    const handle = cache.get(cache_key) catch return .miss;
    return .{
        .hit = .{
            .record = handle.data(),
            .handle = handle,
        },
    };
}
