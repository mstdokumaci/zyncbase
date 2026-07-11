const std = @import("std");
const Allocator = std.mem.Allocator;

/// Thin wrapper over `std.ArrayListUnmanaged(u8)` for building SQL/DDL strings.
/// Owns the buffer; call `deinit` or `toOwnedSlice` to release.
///
/// For comma-separated lists, use `SqlList.init(&buf, sep)` to get a
/// stack-allocated cursor that tracks separator state independently.
/// Multiple nested `SqlList` instances can coexist safely.
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

    /// Append a single byte. Use for structural punctuation like `(`, `)`, spaces.
    pub fn append(self: *SqlBuf, allocator: Allocator, byte: u8) !void {
        try self.buf.append(allocator, byte);
    }

    /// Append a raw slice. Use for structural fragments or multi-part item continuations.
    pub fn appendSlice(self: *SqlBuf, allocator: Allocator, slice: []const u8) !void {
        try self.buf.appendSlice(allocator, slice);
    }

    /// Returns a writer backed by the internal buffer, for use with `std.fmt.format`.
    pub fn writer(self: *SqlBuf, allocator: Allocator) std.ArrayListUnmanaged(u8).Writer {
        return self.buf.writer(allocator);
    }

    /// Appends `identifier` wrapped in double quotes: `"name"`.
    pub fn appendQuoted(self: *SqlBuf, allocator: Allocator, identifier: []const u8) !void {
        try self.buf.ensureUnusedCapacity(allocator, identifier.len + 2);
        self.buf.appendAssumeCapacity('"');
        self.buf.appendSliceAssumeCapacity(identifier);
        self.buf.appendAssumeCapacity('"');
    }

    /// Appends an index name of the form `"idx_<table>_<field>"`.
    pub fn appendIndexName(
        self: *SqlBuf,
        allocator: Allocator,
        table_name: []const u8,
        field_name: []const u8,
    ) !void {
        const extra_len = 7 + table_name.len + field_name.len;
        try self.buf.ensureUnusedCapacity(allocator, extra_len);
        self.buf.appendAssumeCapacity('"');
        self.buf.appendSliceAssumeCapacity("idx_");
        self.buf.appendSliceAssumeCapacity(table_name);
        self.buf.appendAssumeCapacity('_');
        self.buf.appendSliceAssumeCapacity(field_name);
        self.buf.appendAssumeCapacity('"');
    }
};

/// Stack-allocated separator-aware cursor into a `SqlBuf`.
/// Create one per list context with `SqlList.init(&buf, sep)`.
/// Multiple nested `SqlList` instances are safe — each carries its own state.
///
/// Methods that emit a complete single item (`appendItemSlice`, `appendQuoted`,
/// `appendIndexName`) call `maybeSep` automatically. For multi-part items, call
/// `maybeSep` once at the start, then use `buf.appendSlice` for each part.
pub const SqlList = struct {
    buf: *SqlBuf,
    sep: []const u8,
    is_first: bool = true,

    pub fn init(buf: *SqlBuf, sep: []const u8) SqlList {
        return .{ .buf = buf, .sep = sep };
    }

    /// Emit the separator if not the first item. Call once per multi-part item.
    pub fn maybeSep(self: *SqlList, allocator: Allocator) !void {
        if (!self.is_first) try self.buf.appendSlice(allocator, self.sep);
        self.is_first = false;
    }

    /// Append a single-slice item, emitting the separator automatically.
    pub fn appendItemSlice(self: *SqlList, allocator: Allocator, slice: []const u8) !void {
        try self.maybeSep(allocator);
        try self.buf.appendSlice(allocator, slice);
    }

    /// Appends `identifier` wrapped in double quotes, with automatic separator.
    pub fn appendQuoted(self: *SqlList, allocator: Allocator, identifier: []const u8) !void {
        try self.maybeSep(allocator);
        try self.buf.appendQuoted(allocator, identifier);
    }

    /// Appends an index name of the form `"idx_<table>_<field>"`, with automatic separator.
    pub fn appendIndexName(
        self: *SqlList,
        allocator: Allocator,
        table_name: []const u8,
        field_name: []const u8,
    ) !void {
        try self.maybeSep(allocator);
        try self.buf.appendIndexName(allocator, table_name, field_name);
    }
};
