const std = @import("std");
const Allocator = std.mem.Allocator;

const escape_table = blk: {
    var table: [256]?[]const u8 = undefined;
    for (&table, 0..) |*entry, i| {
        const char: u8 = @intCast(i);
        entry.* = switch (char) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
    }
    break :blk table;
};

pub const Writer = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    is_first: bool = true,

    fn separator(self: *Writer) !void {
        if (!self.is_first) {
            try self.buf.append(self.allocator, ',');
        }
        self.is_first = false;
    }

    pub fn writeEscapedString(self: *Writer, value: []const u8) !void {
        try self.buf.append(self.allocator, '"');
        for (value) |char| {
            if (escape_table[char]) |esc| {
                try self.buf.appendSlice(self.allocator, esc);
            } else if (char < 0x20) {
                try self.buf.appendSlice(self.allocator, "\\u00");
                const hex = "0123456789abcdef";
                try self.buf.append(self.allocator, hex[char >> 4]);
                try self.buf.append(self.allocator, hex[char & 0xf]);
            } else {
                try self.buf.append(self.allocator, char);
            }
        }
        try self.buf.append(self.allocator, '"');
    }

    pub fn stringValue(self: *Writer, value: []const u8) !void {
        try self.separator();
        try self.writeEscapedString(value);
    }

    pub fn boolValue(self: *Writer, value: bool) !void {
        try self.separator();
        try self.buf.appendSlice(self.allocator, if (value) "true" else "false");
    }

    pub fn intValue(self: *Writer, value: anytype) !void {
        try self.separator();
        try self.buf.writer(self.allocator).print("{d}", .{value});
    }

    pub fn floatValue(self: *Writer, value: anytype) !void {
        try self.separator();
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.WriteFailed;
        if (std.mem.indexOfAny(u8, s, ".eE") == null) {
            try self.buf.appendSlice(self.allocator, s);
            try self.buf.appendSlice(self.allocator, ".0");
        } else {
            try self.buf.appendSlice(self.allocator, s);
        }
    }

    pub fn field(self: *Writer, key: []const u8, value: []const u8) !void {
        try self.separator();
        try self.writeEscapedString(key);
        try self.buf.append(self.allocator, ':');
        try self.writeEscapedString(value);
    }

    pub fn boolField(self: *Writer, key: []const u8, value: bool) !void {
        try self.separator();
        try self.writeEscapedString(key);
        try self.buf.appendSlice(self.allocator, if (value) ":true" else ":false");
    }

    pub fn intField(self: *Writer, key: []const u8, value: anytype) !void {
        try self.separator();
        try self.writeEscapedString(key);
        try self.buf.append(self.allocator, ':');
        try self.buf.writer(self.allocator).print("{d}", .{value});
    }

    pub fn rawField(self: *Writer, key: []const u8, json_bytes: []const u8) !void {
        try self.separator();
        try self.writeEscapedString(key);
        try self.buf.append(self.allocator, ':');
        try self.buf.appendSlice(self.allocator, json_bytes);
    }

    pub fn beginObjectField(self: *Writer, key: []const u8) !void {
        try self.separator();
        try self.writeEscapedString(key);
        try self.buf.appendSlice(self.allocator, ":{");
        self.is_first = true;
    }

    pub fn beginArrayField(self: *Writer, key: []const u8) !void {
        try self.separator();
        try self.writeEscapedString(key);
        try self.buf.appendSlice(self.allocator, ":[");
        self.is_first = true;
    }

    pub fn beginObject(self: *Writer) !void {
        try self.buf.append(self.allocator, '{');
        self.is_first = true;
    }

    pub fn endObject(self: *Writer) !void {
        try self.buf.append(self.allocator, '}');
        self.is_first = false;
    }

    pub fn beginArray(self: *Writer) !void {
        try self.buf.append(self.allocator, '[');
        self.is_first = true;
    }

    pub fn endArray(self: *Writer) !void {
        try self.buf.append(self.allocator, ']');
        self.is_first = false;
    }
};
