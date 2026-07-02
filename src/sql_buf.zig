const std = @import("std");
const Allocator = std.mem.Allocator;

/// Thin wrapper over `std.ArrayListUnmanaged(u8)` for building SQL/DDL strings.
/// Owns the buffer; call `deinit` or `toOwnedSlice` to release.
///
/// List mode: call `beginList(sep)` to enter a separator-aware context.
/// While in list mode, `appendItemSlice`, `appendQuoted` and `appendIndexName`
/// emit the separator automatically before each item. For multi-part items,
/// call `maybeSep` once then use plain `appendSlice` for each part.
/// Call `endList` to exit.
pub const SqlBuf = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    list_sep: []const u8 = "",
    in_list: bool = false,
    list_first: bool = true,

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

    // ── List mode ────────────────────────────────────────────────────────────

    /// Enter list mode. While active, `maybeSep` emits `sep` before every item
    /// except the first. `appendQuoted` and `appendIndexName` call it automatically.
    pub fn beginList(self: *SqlBuf, sep: []const u8) void {
        self.in_list = true;
        self.list_first = true;
        self.list_sep = sep;
    }

    /// Exit list mode.
    pub fn endList(self: *SqlBuf) void {
        self.in_list = false;
    }

    /// Emit the list separator if in list mode and not the first item.
    /// Call this once at the start of each multi-part list item.
    /// `appendItemSlice`, `appendQuoted` and `appendIndexName` call this automatically.
    pub fn maybeSep(self: *SqlBuf, allocator: Allocator) !void {
        if (!self.in_list) return;
        if (!self.list_first) try self.buf.appendSlice(allocator, self.list_sep);
        self.list_first = false;
    }

    // ── Raw append (structural characters, never list items) ─────────────────

    /// Append a single byte. Never emits a separator — use for structural
    /// punctuation like `(`, `)`, spaces, operators.
    pub fn append(self: *SqlBuf, allocator: Allocator, byte: u8) !void {
        try self.buf.append(allocator, byte);
    }

    /// Append a raw slice. Does not emit a separator automatically — call
    /// `maybeSep` first when this call starts a new list item.
    pub fn appendSlice(self: *SqlBuf, allocator: Allocator, slice: []const u8) !void {
        try self.buf.appendSlice(allocator, slice);
    }

    /// Returns a writer backed by the internal buffer, for use with `std.fmt.format`.
    pub fn writer(self: *SqlBuf, allocator: Allocator) std.ArrayListUnmanaged(u8).Writer {
        return self.buf.writer(allocator);
    }

    // ── Item append (always a complete list item, auto-separator) ────────────

    /// Appends a single-slice item, emitting the list separator automatically.
    /// Use when the entire list item is one pre-built slice (e.g. a quoted column name).
    /// For multi-part items, call `maybeSep` once then use `appendSlice` for each part.
    pub fn appendItemSlice(self: *SqlBuf, allocator: Allocator, slice: []const u8) !void {
        try self.maybeSep(allocator);
        try self.buf.appendSlice(allocator, slice);
    }

    /// Appends `identifier` wrapped in double quotes: `"name"`.
    /// Automatically emits the list separator when in list mode.
    pub fn appendQuoted(self: *SqlBuf, allocator: Allocator, identifier: []const u8) !void {
        try self.maybeSep(allocator);
        try self.buf.ensureUnusedCapacity(allocator, identifier.len + 2);
        self.buf.appendAssumeCapacity('"');
        self.buf.appendSliceAssumeCapacity(identifier);
        self.buf.appendAssumeCapacity('"');
    }

    /// Appends an index name of the form `"idx_<table>_<field>"`.
    /// Automatically emits the list separator when in list mode.
    pub fn appendIndexName(
        self: *SqlBuf,
        allocator: Allocator,
        table_name: []const u8,
        field_name: []const u8,
    ) !void {
        try self.maybeSep(allocator);
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
