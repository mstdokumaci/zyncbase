const msgpack = @import("../msgpack_utils.zig");
const Payload = msgpack.Payload;

pub const Envelope = struct {
    type: []const u8,
    id: u64,
};

pub const StorePathRequest = struct {
    path: Payload = .nil,
    value: ?Payload = null,
};

pub const StoreCollectionRequest = struct {
    table_index: Payload = .nil,
};

pub const StoreSetNamespaceRequest = struct {
    namespace: []const u8,
};

pub const StoreUnsubscribeRequest = struct {
    subId: u64,
};

pub const StoreLoadMoreRequest = struct {
    subId: u64,
    nextCursor: []const u8,
};
