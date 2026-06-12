const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("../typed.zig");
const schema_mod = @import("../schema.zig");
const msgpack = @import("../msgpack_utils.zig");

/// Accumulated in-memory state for one user or one namespace's shared record.
/// A dense array indexed by field position, mirroring `typed.Record` but with
/// optional slots (`null` = field not yet set). Allocated once when the record
/// is created, mutated in place via merge.
pub const PresenceRecord = struct {
    values: []?typed.Value,

    /// Allocate a new record with all-null slots.
    pub fn init(allocator: Allocator, field_count: usize) !PresenceRecord {
        const values = try allocator.alloc(?typed.Value, field_count);
        @memset(values, null);
        return .{ .values = values };
    }

    pub fn deinit(self: *PresenceRecord, allocator: Allocator) void {
        for (self.values) |*slot| {
            if (slot.*) |value| value.deinit(allocator);
        }
        allocator.free(self.values);
        self.values = &.{};
    }

    /// Deep-clone the record for snapshot/broadcast use.
    pub fn clone(self: *const PresenceRecord, allocator: Allocator) !PresenceRecord {
        const cloned = try allocator.alloc(?typed.Value, self.values.len);
        var i: usize = 0;
        errdefer {
            for (cloned[0..i]) |*slot| {
                if (slot.*) |value| value.deinit(allocator);
            }
            allocator.free(cloned);
        }
        for (self.values) |slot| {
            cloned[i] = if (slot) |value| try value.clone(allocator) else null;
            i += 1;
        }
        return .{ .values = cloned };
    }

    /// Iterate only the sparse entries in the wire Payload patch.
    /// Validates field index bounds and value types against the schema via
    /// `typed.valueFromPayload`. Patches the dense record in place.
    pub fn mergeFromPayload(
        self: *PresenceRecord,
        allocator: Allocator,
        fields: []const schema_mod.PresenceField,
        patch: msgpack.Payload,
    ) !void {
        if (patch != .map) return error.InvalidPayload;
        var it = patch.map.iterator();
        while (it.next()) |entry| {
            const f_idx = msgpack.extractPayloadUint(entry.key_ptr.*) orelse return error.InvalidFieldIndex;
            if (f_idx >= fields.len) return error.InvalidFieldIndex;
            if (f_idx >= self.values.len) return error.InvalidFieldIndex;

            const field = fields[f_idx];
            const new_value = typed.valueFromPayload(allocator, field.declared_type, null, entry.value_ptr.*) catch return error.SchemaValidationFailed;

            if (self.values[f_idx]) |*old| old.deinit(allocator);
            self.values[f_idx] = new_value;
        }
    }
};
