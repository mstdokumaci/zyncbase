const std = @import("std");
const Allocator = std.mem.Allocator;
const doc_id = @import("../doc_id.zig");
const lockFreeCache = @import("../lock_free_cache.zig").lockFreeCache;

pub const DocId = doc_id.DocId;

pub const MetadataCacheKey = struct {
    namespace_id: i64,
    table_index: usize,
    id: DocId,
};

pub const typed_cache_type = lockFreeCache(TypedRow, MetadataCacheKey);

/// A schema field index + typed value pair for storage inserts/updates.
pub const ColumnValue = struct {
    index: usize,
    value: TypedValue,
};

/// A managed result that might be backed by a cache handle.
/// Every result is exposed as a slice of TypedRows.
/// Caller MUST call deinit() to release any potential cache handles and memory.
pub const ManagedResult = struct {
    rows: []TypedRow,
    next_cursor: ?TypedCursor = null,
    handle: ?typed_cache_type.Handle = null,
    allocator: ?Allocator = null,

    pub fn deinit(self: *ManagedResult) void {
        if (self.handle) |h| {
            h.release();
        } else if (self.allocator) |alloc| {
            for (self.rows) |r| r.deinit(alloc);
            alloc.free(self.rows);
            if (self.next_cursor) |*nc| nc.deinit(alloc);
        }
    }
};

pub const TypedRow = struct {
    values: []TypedValue,

    pub fn deinit(self: TypedRow, allocator: Allocator) void {
        for (self.values) |value| value.deinit(allocator);
        allocator.free(self.values);
    }

    pub fn clone(self: TypedRow, allocator: Allocator) !TypedRow {
        const cloned = try allocator.alloc(TypedValue, self.values.len);
        var i: usize = 0;
        errdefer {
            for (cloned[0..i]) |value| value.deinit(allocator);
            allocator.free(cloned);
        }
        while (i < self.values.len) : (i += 1) {
            cloned[i] = try self.values[i].clone(allocator);
        }
        return .{ .values = cloned };
    }
};

pub const TypedCursor = struct {
    sort_value: TypedValue,
    id: DocId,

    pub fn deinit(self: *TypedCursor, allocator: Allocator) void {
        self.sort_value.deinit(allocator);
    }

    pub fn clone(self: TypedCursor, allocator: Allocator) !TypedCursor {
        return .{
            .sort_value = try self.sort_value.clone(allocator),
            .id = self.id,
        };
    }
};

/// A simple scalar value for storage elements that don't support recursion or nil.
pub const ScalarValue = union(enum) {
    doc_id: DocId,
    integer: i64,
    real: f64,
    text: []const u8, // Owned
    boolean: bool,

    pub fn clone(self: ScalarValue, allocator: Allocator) !ScalarValue {
        return switch (self) {
            .text => |s| .{ .text = try allocator.dupe(u8, s) },
            else => self,
        };
    }

    pub fn deinit(self: ScalarValue, allocator: Allocator) void {
        switch (self) {
            .text => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn lessThan(self: ScalarValue, other: ScalarValue) bool {
        return self.order(other) == .lt;
    }

    pub fn order(self: ScalarValue, other: ScalarValue) std.math.Order {
        if (@as(std.meta.Tag(ScalarValue), self) != @as(std.meta.Tag(ScalarValue), other)) {
            return std.math.order(@intFromEnum(self), @intFromEnum(other));
        }
        return switch (self) {
            .doc_id => doc_id.order(self.doc_id, other.doc_id),
            .integer => std.math.order(self.integer, other.integer),
            .real => std.math.order(self.real, other.real),
            .text => std.mem.order(u8, self.text, other.text),
            .boolean => std.math.order(@intFromBool(self.boolean), @intFromBool(other.boolean)),
        };
    }
};

/// A typed value for asynchronous storage binding.
pub const TypedValue = union(enum) {
    scalar: ScalarValue,
    array: []ScalarValue, // Owned slice of ScalarValues (no nesting, no nil)
    nil: void,

    pub fn clone(self: TypedValue, allocator: Allocator) !TypedValue {
        return switch (self) {
            .scalar => |s| .{ .scalar = try s.clone(allocator) },
            .nil => .nil,
            .array => |items| blk: {
                const cloned = try allocator.alloc(ScalarValue, items.len);
                var i: usize = 0;
                errdefer {
                    for (cloned[0..i]) |*item| item.deinit(allocator);
                    allocator.free(cloned);
                }
                while (i < items.len) : (i += 1) {
                    cloned[i] = try items[i].clone(allocator);
                }
                break :blk .{ .array = cloned };
            },
        };
    }

    pub fn sortedSet(self: *TypedValue, allocator: Allocator) !void {
        const arr = switch (self.*) {
            .array => |a| a,
            else => return,
        };
        if (arr.len <= 1) return;

        std.sort.pdq(ScalarValue, arr, {}, scalarValueLessThan);

        var write: usize = 1;
        for (1..arr.len) |read| {
            if (ScalarValue.order(arr[write - 1], arr[read]) != .eq) {
                if (write != read) {
                    arr[write] = arr[read];
                }
                write += 1;
            } else {
                arr[read].deinit(allocator);
            }
        }

        if (write < arr.len) {
            for (arr[write..]) |*item| {
                item.* = .{ .integer = 0 };
            }
            self.* = .{ .array = try allocator.realloc(arr, write) };
        }
    }

    pub fn deinit(self: TypedValue, allocator: Allocator) void {
        switch (self) {
            .scalar => |s| s.deinit(allocator),
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .nil => {},
        }
    }
};

fn scalarValueLessThan(_: void, a: ScalarValue, b: ScalarValue) bool {
    return a.lessThan(b);
}
