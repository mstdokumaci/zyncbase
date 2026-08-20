/// Canonical registry of every top-level wire message type ID (wire-protocol.md).
/// Direction is documented but not part of the encoding; routing uses explicit
/// enum cases, never arithmetic on the high nibble. Never reuse or renumber an
/// assigned ID. All values stay <= 0x7f so MessagePack encodes them as a
/// one-byte positive fixint.
pub const MessageType = enum(u8) {
    // Protocol and session (0x0x)
    ok = 0x00, // S->C successful correlated response
    @"error" = 0x01, // S->C failed correlated or uncorrelated response
    connected = 0x02, // S->C connection/session bootstrap
    schema_sync = 0x03, // S->C schema dictionary bootstrap
    auth_refresh = 0x04, // C->S refresh connection authentication
    server_disconnect = 0x05, // S->C structured disconnect reason

    // Store (0x1x)
    store_set_namespace = 0x10, // C->S establish store scope
    store_set = 0x11, // C->S set a document or field
    store_remove = 0x12, // C->S remove a document or field
    store_batch = 0x13, // C->S apply a write batch
    store_query = 0x14, // C->S execute a one-shot query
    store_subscribe = 0x15, // C->S start a live query
    store_unsubscribe = 0x16, // C->S stop a live query
    store_load_more = 0x17, // C->S page an active query
    store_delta = 0x18, // S->C push committed subscription changes
    write_committed = 0x19, // S->C confirm a tracked write
    write_error = 0x1a, // S->C fail a tracked write

    // Presence (0x2x)
    presence_set_namespace = 0x20, // C->S establish presence scope
    presence_set = 0x21, // C->S update user presence
    presence_set_shared = 0x22, // C->S update shared presence state
    presence_subscribe = 0x23, // C->S subscribe to user presence
    presence_unsubscribe = 0x24, // C->S unsubscribe from user presence
    presence_subscribe_shared = 0x25, // C->S subscribe to shared state
    presence_unsubscribe_shared = 0x26, // C->S unsubscribe from shared state
    presence_remove = 0x27, // C->S remove user presence
    presence_broadcast = 0x28, // S->C push user presence changes
    shared_state_broadcast = 0x29, // S->C push shared state changes
};

comptime {
    for (@typeInfo(MessageType).@"enum".fields) |f| {
        if (f.value > 0x7f) {
            @compileError("MessageType '" ++ f.name ++ "' exceeds 0x7f and would lose one-byte positive fixint encoding");
        }
    }
}
