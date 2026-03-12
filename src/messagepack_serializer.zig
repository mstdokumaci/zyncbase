const std = @import("std");
const Allocator = std.mem.Allocator;

/// Simple MessagePack serializer for server responses
pub const MessagePackSerializer = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) MessagePackSerializer {
        return .{
            .buf = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MessagePackSerializer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *MessagePackSerializer) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    pub fn writeNil(self: *MessagePackSerializer) !void {
        try self.buf.append(self.allocator, 0xc0);
    }

    pub fn writeBool(self: *MessagePackSerializer, value: bool) !void {
        try self.buf.append(self.allocator, if (value) 0xc3 else 0xc2);
    }

    pub fn writeInt(self: *MessagePackSerializer, value: i64) !void {
        if (value >= -32 and value <= 127) {
            try self.buf.append(self.allocator, @bitCast(@as(i8, @intCast(value))));
        } else if (value >= 0) {
            if (value <= 255) {
                try self.buf.append(self.allocator, 0xcc);
                try self.buf.append(self.allocator, @intCast(value));
            } else if (value <= 65535) {
                try self.buf.append(self.allocator, 0xcd);
                try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(value))));
            } else if (value <= 4294967295) {
                try self.buf.append(self.allocator, 0xce);
                try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(value))));
            } else {
                try self.buf.append(self.allocator, 0xcf);
                try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, @intCast(value))));
            }
        } else if (value >= -128) {
            try self.buf.append(self.allocator, 0xd0);
            try self.buf.append(self.allocator, @bitCast(@as(i8, @intCast(value))));
        } else if (value >= -32768) {
            try self.buf.append(self.allocator, 0xd1);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(i16, @intCast(value))));
        } else if (value >= -2147483648) {
            try self.buf.append(self.allocator, 0xd2);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(i32, @intCast(value))));
        } else {
            try self.buf.append(self.allocator, 0xd3);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(i64, value)));
        }
    }

    pub fn writeUint(self: *MessagePackSerializer, value: u64) !void {
        if (value <= 127) {
            try self.buf.append(self.allocator, @intCast(value));
        } else if (value <= 255) {
            try self.buf.append(self.allocator, 0xcc);
            try self.buf.append(self.allocator, @intCast(value));
        } else if (value <= 65535) {
            try self.buf.append(self.allocator, 0xcd);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(value))));
        } else if (value <= 4294967295) {
            try self.buf.append(self.allocator, 0xce);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(value))));
        } else {
            try self.buf.append(self.allocator, 0xcf);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, value)));
        }
    }

    pub fn writeString(self: *MessagePackSerializer, value: []const u8) !void {
        const len = value.len;
        if (len <= 31) {
            try self.buf.append(self.allocator, @intCast(0xa0 | len));
        } else if (len <= 255) {
            try self.buf.append(self.allocator, 0xd9);
            try self.buf.append(self.allocator, @intCast(len));
        } else if (len <= 65535) {
            try self.buf.append(self.allocator, 0xda);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(len))));
        } else {
            try self.buf.append(self.allocator, 0xdb);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(len))));
        }
        try self.buf.appendSlice(self.allocator, value);
    }

    pub fn writeMapHeader(self: *MessagePackSerializer, size: usize) !void {
        if (size <= 15) {
            try self.buf.append(self.allocator, @intCast(0x80 | size));
        } else if (size <= 65535) {
            try self.buf.append(self.allocator, 0xde);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(size))));
        } else {
            try self.buf.append(self.allocator, 0xdf);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(size))));
        }
    }

    pub fn writeFloat(self: *MessagePackSerializer, value: f64) !void {
        try self.buf.append(self.allocator, 0xcb);
        try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, @bitCast(value))));
    }

    pub fn writeBinary(self: *MessagePackSerializer, value: []const u8) !void {
        const len = value.len;
        if (len <= 255) {
            try self.buf.append(self.allocator, 0xc4);
            try self.buf.append(self.allocator, @intCast(len));
        } else if (len <= 65535) {
            try self.buf.append(self.allocator, 0xc5);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(len))));
        } else {
            try self.buf.append(self.allocator, 0xc6);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(len))));
        }
        try self.buf.appendSlice(self.allocator, value);
    }

    pub fn writeArrayHeader(self: *MessagePackSerializer, size: usize) !void {
        if (size <= 15) {
            try self.buf.append(self.allocator, @intCast(0x90 | size));
        } else if (size <= 65535) {
            try self.buf.append(self.allocator, 0xdc);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(size))));
        } else {
            try self.buf.append(self.allocator, 0xdd);
            try self.buf.appendSlice(self.allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(size))));
        }
    }
};
