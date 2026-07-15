const std = @import("std");
const Allocator = std.mem.Allocator;
const typed_types = @import("../typed/types.zig");
const typed_codec = @import("../typed/codec.zig");
const schema_mod = @import("../schema.zig");
const msgpack = @import("../msgpack_utils.zig");

/// Accumulated in-memory state for one user or one namespace's shared record.
/// A dense array indexed by field position, mirroring `typed_types.Record` but with
/// optional slots (`null` = field not yet set). Allocated once when the record
/// is created, mutated in place via merge.
pub const PresenceRecord = struct {
    values: []?typed_types.Value,

    /// Allocate a new record with all-null slots.
    pub fn init(allocator: Allocator, field_count: usize) !PresenceRecord {
        const values = try allocator.alloc(?typed_types.Value, field_count);
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
        const cloned = try allocator.alloc(?typed_types.Value, self.values.len);
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
    /// `typed_codec.fromPayload`. Decodes all fields first into a temporary
    /// buffer, then applies them atomically to avoid partial mutation on error.
    pub fn mergeFromPayload(
        self: *PresenceRecord,
        allocator: Allocator,
        fields: []const schema_mod.PresenceField,
        patch: msgpack.Payload,
    ) !void {
        if (patch != .arr) return error.InvalidPayload;

        const TempUpdate = struct {
            idx: usize,
            value: typed_types.Value,
        };
        var temp_updates = std.ArrayListUnmanaged(TempUpdate).empty;
        defer {
            for (temp_updates.items) |*update| update.value.deinit(allocator);
            temp_updates.deinit(allocator);
        }

        for (patch.arr) |pair_payload| {
            if (pair_payload != .arr or pair_payload.arr.len != 2) return error.InvalidPayload;
            const f_idx = msgpack.extractPayloadUsize(pair_payload.arr[0]) orelse return error.InvalidPayload;
            if (f_idx >= fields.len) return error.InvalidFieldIndex;
            if (f_idx >= self.values.len) return error.InvalidFieldIndex;

            const field = fields[f_idx];
            const new_value = typed_codec.fromPayload(allocator, field.declared_type, null, pair_payload.arr[1]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.SchemaValidationFailed,
            };

            temp_updates.append(allocator, .{ .idx = f_idx, .value = new_value }) catch |err| {
                new_value.deinit(allocator);
                return err;
            };
        }

        for (temp_updates.items) |update| {
            if (self.values[update.idx]) |*old| old.deinit(allocator);
            self.values[update.idx] = update.value;
        }
        temp_updates.clearRetainingCapacity();
    }
};
