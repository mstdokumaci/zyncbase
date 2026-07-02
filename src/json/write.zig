const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |char| {
        switch (char) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try buf.appendSlice(allocator, "\\u00");
                const hex = "0123456789abcdef";
                try buf.append(allocator, hex[char >> 4]);
                try buf.append(allocator, hex[char & 0xf]);
            },
            else => try buf.append(allocator, char),
        }
    }
    try buf.append(allocator, '"');
}

pub const Writer = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    is_first: bool = true,

    fn maybeSeparator(self: *Writer) !void {
        if (!self.is_first) {
            try self.buf.append(self.allocator, ',');
        }
        self.is_first = false;
    }

    pub fn separator(self: *Writer) !void {
        try self.buf.append(self.allocator, ',');
        self.is_first = false;
    }

    pub fn writeRaw(self: Writer, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn field(self: *Writer, key: []const u8, value: []const u8) !void {
        try self.maybeSeparator();
        try writeJsonString(self.buf, self.allocator, key);
        try self.buf.append(self.allocator, ':');
        try writeJsonString(self.buf, self.allocator, value);
    }

    pub fn boolField(self: *Writer, key: []const u8, value: bool) !void {
        try self.maybeSeparator();
        try writeJsonString(self.buf, self.allocator, key);
        try self.buf.appendSlice(self.allocator, if (value) ":true" else ":false");
    }

    pub fn intField(self: *Writer, key: []const u8, value: anytype) !void {
        try self.maybeSeparator();
        try writeJsonString(self.buf, self.allocator, key);
        try self.buf.append(self.allocator, ':');
        try self.buf.writer(self.allocator).print("{d}", .{value});
    }

    pub fn nullField(self: *Writer, key: []const u8) !void {
        try self.maybeSeparator();
        try writeJsonString(self.buf, self.allocator, key);
        try self.buf.appendSlice(self.allocator, ":null");
    }

    pub fn rawField(self: *Writer, key: []const u8, json_bytes: []const u8) !void {
        try self.maybeSeparator();
        try writeJsonString(self.buf, self.allocator, key);
        try self.buf.append(self.allocator, ':');
        try self.buf.appendSlice(self.allocator, json_bytes);
    }

    pub fn beginObject(self: *Writer) !void {
        try self.buf.append(self.allocator, '{');
        self.is_first = true;
    }

    pub fn endObject(self: *Writer) !void {
        try self.buf.append(self.allocator, '}');
        self.is_first = false;
    }

    pub fn beginObjectField(self: *Writer, key: []const u8) !void {
        try self.maybeSeparator();
        try writeJsonString(self.buf, self.allocator, key);
        try self.buf.appendSlice(self.allocator, ":{");
        self.is_first = true;
    }

    pub fn beginArray(self: *Writer) !void {
        try self.buf.append(self.allocator, '[');
        self.is_first = true;
    }

    pub fn endArray(self: *Writer) !void {
        try self.buf.append(self.allocator, ']');
        self.is_first = false;
    }

    pub fn beginArrayField(self: *Writer, key: []const u8) !void {
        try self.maybeSeparator();
        try writeJsonString(self.buf, self.allocator, key);
        try self.buf.appendSlice(self.allocator, ":[");
        self.is_first = true;
    }
};
