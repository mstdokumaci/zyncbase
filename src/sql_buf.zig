const std = @import("std");
const Allocator = std.mem.Allocator;

/// Thin wrapper over `std.ArrayListUnmanaged(u8)` for building SQL/DDL strings.
/// Owns the buffer; call `deinit` or `toOwnedSlice` to release.
pub const SqlBuf = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init() SqlBuf {
        return .{};
    }

    pub fn deinit(self: *SqlBuf, allocator: Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn len(self: *const SqlBuf) usize {
        return self.buf.items.len;
    }

    pub fn items(self: *const SqlBuf) []const u8 {
        return self.buf.items;
    }

    /// Returns ownership of the accumulated bytes. Caller must free.
    pub fn toOwnedSlice(self: *SqlBuf, allocator: Allocator) ![]u8 {
        return self.buf.toOwnedSlice(allocator);
    }

    pub fn append(self: *SqlBuf, allocator: Allocator, byte: u8) !void {
        try self.buf.append(allocator, byte);
    }

    pub fn appendSlice(self: *SqlBuf, allocator: Allocator, slice: []const u8) !void {
        try self.buf.appendSlice(allocator, slice);
    }

    /// Appends `identifier` wrapped in double quotes: `"name"`.
    pub fn appendQuoted(self: *SqlBuf, allocator: Allocator, identifier: []const u8) !void {
        try self.buf.append(allocator, '"');
        try self.buf.appendSlice(allocator, identifier);
        try self.buf.append(allocator, '"');
    }

    /// Appends an index name of the form `"idx_<table>_<field>"`.
    pub fn appendIndexName(
        self: *SqlBuf,
        allocator: Allocator,
        table_name: []const u8,
        field_name: []const u8,
    ) !void {
        try self.buf.append(allocator, '"');
        try self.buf.appendSlice(allocator, "idx_");
        try self.buf.appendSlice(allocator, table_name);
        try self.buf.append(allocator, '_');
        try self.buf.appendSlice(allocator, field_name);
        try self.buf.append(allocator, '"');
    }

    /// Appends `separator` only when the buffer is non-empty.
    /// Useful for join-style accumulators where the first item has no leading sep.
    pub fn appendSep(self: *SqlBuf, allocator: Allocator, separator: []const u8) !void {
        if (self.buf.items.len > 0) try self.buf.appendSlice(allocator, separator);
    }
};
