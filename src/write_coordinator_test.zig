const std = @import("std");
const testing = std.testing;
const msgpack = @import("msgpack_utils.zig");
const Payload = msgpack.Payload;
const storage_engine = @import("storage_engine.zig");
const ColumnValue = storage_engine.ColumnValue;
const WriteCoordinator = @import("write_coordinator.zig").WriteCoordinator;

test "WriteCoordinator: mergeRow logic" {
    const allocator = testing.allocator;

    // We need a dummy WriteCoordinator pointer since mergeRow expects *self
    // even if it doesn't use it yet (it might in the future for schema context).
    var wc: WriteCoordinator = undefined;

    var arena_alloc = std.heap.ArenaAllocator.init(allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    // 1. Initial state (old row)
    var old_row = Payload.mapPayload(arena);
    try old_row.mapPut("f1", try Payload.strToPayload("v1", arena));

    // 2. Partial update to f2 and override f1
    const val_f1_new = try Payload.strToPayload("v1_new", arena);
    const val_f2 = try Payload.strToPayload("v2", arena);
    const fields = [_]ColumnValue{
        .{ .name = "f1", .value = val_f1_new },
        .{ .name = "f2", .value = val_f2 },
    };

    const merged = try wc.mergeRow(arena, old_row, &fields);

    try testing.expect(merged == .map);
    try testing.expectEqual(@as(usize, 2), merged.map.count());

    // Helper to check map content
    const checkMap = struct {
        fn get(map: anytype, key: []const u8) ?Payload {
            var it = map.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* == .str and std.mem.eql(u8, entry.key_ptr.*.str.value(), key)) {
                    return entry.value_ptr.*;
                }
            }
            return null;
        }
    }.get;

    const f1_val = checkMap(merged.map, "f1");
    try testing.expect(f1_val != null);
    try testing.expectEqualStrings("v1_new", f1_val.?.str.value());

    const f2_val = checkMap(merged.map, "f2");
    try testing.expect(f2_val != null);
    try testing.expectEqualStrings("v2", f2_val.?.str.value());
}

test "WriteCoordinator: mergeRow with null old_row" {
    const allocator = testing.allocator;
    var wc: WriteCoordinator = undefined;

    var arena_alloc = std.heap.ArenaAllocator.init(allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const val = try Payload.strToPayload("v1", arena);
    const fields = [_]ColumnValue{
        .{ .name = "f1", .value = val },
    };

    const merged = try wc.mergeRow(arena, null, &fields);

    try testing.expect(merged == .map);
    try testing.expectEqual(@as(usize, 1), merged.map.count());
}
