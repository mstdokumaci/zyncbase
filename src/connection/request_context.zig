const std = @import("std");

const typed_doc_id = @import("../typed/doc_id.zig");
const typed = @import("../typed/types.zig");

const DocId = typed_doc_id.DocId;

pub const unset_namespace_id: i64 = -1;

/// Resolved namespace + user scope, shared by store and presence scoping.
pub const Scope = struct {
    namespace_id: i64,
    user_doc_id: DocId,
};

/// Verified per-connection facts needed to route and authorize one request.
/// The caller (message handler) snapshots these from `Connection` state;
/// store, presence, actions, and authorization consume it. Connection-owned
/// content, request-scoped lifetime.
pub const RequestContext = struct {
    conn_id: u64,
    user_doc_id: DocId,
    external_user_id: ?[]const u8 = null,
    session_claims: ?*const std.StringHashMapUnmanaged(typed.Value) = null,
    store_namespace: ?[]const u8 = null,
    store_namespace_id: i64 = unset_namespace_id,
    presence_namespace: ?[]const u8 = null,
    presence_namespace_id: i64 = unset_namespace_id,
};
