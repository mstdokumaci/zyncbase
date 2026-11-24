const SubscriptionEngine = @import("engine.zig").SubscriptionEngine;

const MatchOp = SubscriptionEngine.MatchOp;

const slots = 128;

const Entry = struct {
    sub_id: u64 = 0,
    op: MatchOp = .set_op,
    msg: []const u8 = &.{},
    valid: bool = false,
};

/// Per-change cache of encoded fanout messages.
///
/// The message bytes depend only on the client-local subscription id and the
/// match operation, so connections that share a subscription id can share one
/// encoded buffer. The cache is direct-mapped by the key's low bits; a
/// collision only evicts an entry and forces a later re-encode. It never owns
/// the message bytes, which live in the change arena.
pub const MessageCache = struct {
    entries: [slots]Entry = [_]Entry{.{}} ** slots,
    last_sub_id: ?u64 = null,
    last_op: MatchOp = .set_op,
    last_msg: []const u8 = &.{},

    pub fn get(self: *MessageCache, sub_id: u64, op: MatchOp) ?[]const u8 {
        if (self.last_sub_id) |last_id| {
            if (last_id == sub_id and self.last_op == op) return self.last_msg;
        }
        const index = slotIndex(sub_id, op);
        const entry = self.entries[index];
        if (entry.valid and entry.sub_id == sub_id and entry.op == op) {
            self.last_sub_id = sub_id;
            self.last_op = op;
            self.last_msg = entry.msg;
            return entry.msg;
        }
        return null;
    }

    pub fn put(self: *MessageCache, sub_id: u64, op: MatchOp, msg: []const u8) void {
        self.entries[slotIndex(sub_id, op)] = .{
            .sub_id = sub_id,
            .op = op,
            .msg = msg,
            .valid = true,
        };
        self.last_sub_id = sub_id;
        self.last_op = op;
        self.last_msg = msg;
    }
};

fn slotIndex(sub_id: u64, op: MatchOp) usize {
    return @intCast(((sub_id *% 2) +% @intFromEnum(op)) & (slots - 1));
}
