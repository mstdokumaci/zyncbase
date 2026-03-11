const std = @import("std");
const Allocator = std.mem.Allocator;

/// MessagePack parser with configurable security limits to prevent DoS attacks
pub const MessagePackParser = struct {
    allocator: Allocator,
    max_depth: usize,
    max_size: usize,
    max_string_length: usize,
    max_array_length: usize,
    max_map_size: usize,
    violation_threshold: u32,

    /// Configuration for MessagePack parser limits
    pub const Config = struct {
        max_depth: usize = 32,
        max_size: usize = 10 * 1024 * 1024, // 10 MB
        max_string_length: usize = 1024 * 1024, // 1 MB
        max_array_length: usize = 100_000,
        max_map_size: usize = 100_000,
        violation_threshold: u32 = 3, // Close connection after 3 violations
    };

    /// Errors that can occur during MessagePack parsing
    pub const ParseError = error{
        MaxDepthExceeded,
        MaxSizeExceeded,
        MaxStringLengthExceeded,
        MaxArrayLengthExceeded,
        MaxMapSizeExceeded,
        InvalidFormat,
        UnexpectedEOF,
        OutOfMemory,
    };

    /// Initialize a new MessagePack parser with the given configuration
    pub fn init(allocator: Allocator, config: Config) !*MessagePackParser {
        const parser = try allocator.create(MessagePackParser);
        parser.* = MessagePackParser{
            .allocator = allocator,
            .max_depth = config.max_depth,
            .max_size = config.max_size,
            .max_string_length = config.max_string_length,
            .max_array_length = config.max_array_length,
            .max_map_size = config.max_map_size,
            .violation_threshold = config.violation_threshold,
        };
        return parser;
    }

    /// Clean up parser resources
    pub fn deinit(self: *MessagePackParser) void {
        self.allocator.destroy(self);
    }

    /// MessagePack value types
    pub const Value = union(enum) {
        nil,
        boolean: bool,
        integer: i64,
        unsigned: u64,
        float: f64,
        string: []const u8,
        binary: []const u8,
        array: []Value,
        map: []MapEntry,

        pub const MapEntry = struct {
            key: Value,
            value: Value,
        };
    };

    /// Stack state for iterative parsing
    const StackState = struct {
        value_ptr: *Value,
        container_type: enum { array, map_key, map_value },
        remaining: usize,
        index: usize,
        map_entries: ?[]Value.MapEntry = null,
    };

    /// Parse MessagePack data iteratively (not recursively) to prevent stack overflow
    /// PRECONDITION: data is valid byte array
    /// POSTCONDITION: Returns parsed Value or error
    pub fn parse(self: *MessagePackParser, data: []const u8) ParseError!Value {
        if (data.len == 0) {
            return error.UnexpectedEOF;
        }

        // Check size limit
        if (data.len > self.max_size) {
            return error.MaxSizeExceeded;
        }

        var pos: usize = 0;
        var stack = std.ArrayListUnmanaged(StackState){};
        defer {
            for (stack.items) |state| {
                if (state.map_entries) |entries| {
                    // This is only called if we error out midway
                    for (entries) |entry| {
                        self.freeValue(entry.key);
                        self.freeValue(entry.value);
                    }
                    self.allocator.free(entries);
                }
            }
            stack.deinit(self.allocator);
        }

        // Initial root value
        var root_value: Value = .nil;
        var current_value_ptr: *Value = &root_value;

        // Iterative parsing loop
        while (true) {
            // Check depth limit
            if (stack.items.len > self.max_depth) {
                self.freeValue(root_value);
                return error.MaxDepthExceeded;
            }

            // Parse the next primitive or container header
            const next_value = self.parseNextValue(data, &pos) catch |err| {
                self.freeValue(root_value);
                return err;
            };

            // Assign value to current pointer
            current_value_ptr.* = next_value;

            // Handle containers (Array/Map) by pushing to stack
            switch (next_value) {
                .array => |arr| {
                    if (arr.len > 0) {
                        stack.append(self.allocator, .{
                            .value_ptr = current_value_ptr,
                            .container_type = .array,
                            .remaining = arr.len,
                            .index = 0,
                        }) catch |err| {
                            self.freeValue(root_value);
                            return err;
                        };
                        current_value_ptr = &arr[0];
                        continue;
                    }
                },
                .map => |entries| {
                    if (entries.len > 0) {
                        stack.append(self.allocator, .{
                            .value_ptr = current_value_ptr,
                            .container_type = .map_key,
                            .remaining = entries.len,
                            .index = 0,
                        }) catch |err| {
                            self.freeValue(root_value);
                            return err;
                        };
                        current_value_ptr = &entries[0].key;
                        continue;
                    }
                },
                else => {},
            }

            // After a non-container or empty container, pop from stack or move to next element
            while (stack.items.len > 0) {
                var top = &stack.items[stack.items.len - 1];
                switch (top.container_type) {
                    .array => {
                        top.index += 1;
                        if (top.index < top.remaining) {
                            current_value_ptr = &top.value_ptr.array[top.index];
                            break; // Continue parsing next element in array
                        }
                    },
                    .map_key => {
                        // Just finished a key, now parse the value
                        top.container_type = .map_value;
                        current_value_ptr = &top.value_ptr.map[top.index].value;
                        break; // Continue parsing value for this key
                    },
                    .map_value => {
                        // Finished both key and value
                        top.index += 1;
                        if (top.index < top.remaining) {
                            top.container_type = .map_key;
                            current_value_ptr = &top.value_ptr.map[top.index].key;
                            break; // Continue parsing next key in map
                        }
                    },
                }
                _ = stack.pop();
            } else {
                // Stack empty, parsing finished
                break;
            }
        }

        return root_value;
    }

    fn parseNextValue(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!Value {
        if (pos.* >= data.len) return error.UnexpectedEOF;
        const byte = data[pos.*];
        pos.* += 1;

        // Positive fixint (0x00 - 0x7f)
        if (byte <= 0x7f) return Value{ .unsigned = byte };

        // Negative fixint (0xe0 - 0xff)
        if (byte >= 0xe0) return Value{ .integer = @as(i8, @bitCast(byte)) };

        // fixmap (0x80 - 0x8f)
        if (byte >= 0x80 and byte <= 0x8f) {
            const size = byte & 0x0f;
            return try self.initMap(size);
        }

        // fixarray (0x90 - 0x9f)
        if (byte >= 0x90 and byte <= 0x9f) {
            const size = byte & 0x0f;
            return try self.initArray(size);
        }

        // fixstr (0xa0 - 0xbf)
        if (byte >= 0xa0 and byte <= 0xbf) {
            const length = byte & 0x1f;
            return try self.parseString(data, pos, length);
        }

        return switch (byte) {
            0xc0 => Value.nil,
            0xc2 => Value{ .boolean = false },
            0xc3 => Value{ .boolean = true },

            // Integers
            0xcc => Value{ .unsigned = try self.readU8(data, pos) },
            0xcd => Value{ .unsigned = try self.readU16(data, pos) },
            0xce => Value{ .unsigned = try self.readU32(data, pos) },
            0xcf => Value{ .unsigned = try self.readU64(data, pos) },
            0xd0 => Value{ .integer = try self.readI8(data, pos) },
            0xd1 => Value{ .integer = try self.readI16(data, pos) },
            0xd2 => Value{ .integer = try self.readI32(data, pos) },
            0xd3 => Value{ .integer = try self.readI64(data, pos) },

            // Floats
            0xca => Value{ .float = @as(f64, try self.readF32(data, pos)) },
            0xcb => Value{ .float = try self.readF64(data, pos) },

            // Strings
            0xd9 => blk: {
                const length = try self.readU8(data, pos);
                break :blk try self.parseString(data, pos, length);
            },
            0xda => blk: {
                const length = try self.readU16(data, pos);
                break :blk try self.parseString(data, pos, length);
            },
            0xdb => blk: {
                const length = try self.readU32(data, pos);
                break :blk try self.parseString(data, pos, @intCast(length));
            },

            // Binary
            0xc4 => blk: {
                const length = try self.readU8(data, pos);
                break :blk try self.parseBinary(data, pos, length);
            },
            0xc5 => blk: {
                const length = try self.readU16(data, pos);
                break :blk try self.parseBinary(data, pos, length);
            },
            0xc6 => blk: {
                const length = try self.readU32(data, pos);
                break :blk try self.parseBinary(data, pos, @intCast(length));
            },

            // Arrays
            0xdc => blk: {
                const size = try self.readU16(data, pos);
                break :blk try self.initArray(size);
            },
            0xdd => blk: {
                const size = try self.readU32(data, pos);
                break :blk try self.initArray(@intCast(size));
            },

            // Maps
            0xde => blk: {
                const size = try self.readU16(data, pos);
                break :blk try self.initMap(size);
            },
            0xdf => blk: {
                const size = try self.readU32(data, pos);
                break :blk try self.initMap(@intCast(size));
            },

            else => error.InvalidFormat,
        };
    }

    fn initArray(self: *MessagePackParser, size: usize) ParseError!Value {
        if (size > self.max_array_length) return error.MaxArrayLengthExceeded;
        const array = try self.allocator.alloc(Value, size);
        @memset(array, .nil);
        return Value{ .array = array };
    }

    fn initMap(self: *MessagePackParser, size: usize) ParseError!Value {
        if (size > self.max_map_size) return error.MaxMapSizeExceeded;
        const map = try self.allocator.alloc(Value.MapEntry, size);
        for (map) |*entry| {
            entry.key = .nil;
            entry.value = .nil;
        }
        return Value{ .map = map };
    }

    // Helper functions for reading primitive types
    fn readU8(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!u8 {
        _ = self;
        if (pos.* >= data.len) return error.UnexpectedEOF;
        const value = data[pos.*];
        pos.* += 1;
        return value;
    }

    fn readU16(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!u16 {
        _ = self;
        if (pos.* + 2 > data.len) return error.UnexpectedEOF;
        const value = std.mem.readInt(u16, data[pos.*..][0..2], .big);
        pos.* += 2;
        return value;
    }

    fn readU32(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!u32 {
        _ = self;
        if (pos.* + 4 > data.len) return error.UnexpectedEOF;
        const value = std.mem.readInt(u32, data[pos.*..][0..4], .big);
        pos.* += 4;
        return value;
    }

    fn readU64(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!u64 {
        _ = self;
        if (pos.* + 8 > data.len) return error.UnexpectedEOF;
        const value = std.mem.readInt(u64, data[pos.*..][0..8], .big);
        pos.* += 8;
        return value;
    }

    fn readI8(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!i8 {
        _ = self;
        if (pos.* >= data.len) return error.UnexpectedEOF;
        const value = @as(i8, @bitCast(data[pos.*]));
        pos.* += 1;
        return value;
    }

    fn readI16(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!i16 {
        _ = self;
        if (pos.* + 2 > data.len) return error.UnexpectedEOF;
        const value = std.mem.readInt(i16, data[pos.*..][0..2], .big);
        pos.* += 2;
        return value;
    }

    fn readI32(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!i32 {
        _ = self;
        if (pos.* + 4 > data.len) return error.UnexpectedEOF;
        const value = std.mem.readInt(i32, data[pos.*..][0..4], .big);
        pos.* += 4;
        return value;
    }

    fn readI64(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!i64 {
        _ = self;
        if (pos.* + 8 > data.len) return error.UnexpectedEOF;
        const value = std.mem.readInt(i64, data[pos.*..][0..8], .big);
        pos.* += 8;
        return value;
    }

    fn readF32(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!f32 {
        _ = self;
        if (pos.* + 4 > data.len) return error.UnexpectedEOF;
        const bits = std.mem.readInt(u32, data[pos.*..][0..4], .big);
        pos.* += 4;
        return @bitCast(bits);
    }

    fn readF64(self: *MessagePackParser, data: []const u8, pos: *usize) ParseError!f64 {
        _ = self;
        if (pos.* + 8 > data.len) return error.UnexpectedEOF;
        const bits = std.mem.readInt(u64, data[pos.*..][0..8], .big);
        pos.* += 8;
        return @bitCast(bits);
    }

    fn parseString(self: *MessagePackParser, data: []const u8, pos: *usize, length: usize) ParseError!Value {
        if (pos.* + length > data.len) {
            return error.UnexpectedEOF;
        }

        // Check string length limit
        if (length > self.max_string_length) {
            return error.MaxStringLengthExceeded;
        }

        const str = data[pos.* .. pos.* + length];
        pos.* += length;
        return Value{ .string = str };
    }

    fn parseBinary(self: *MessagePackParser, data: []const u8, pos: *usize, length: usize) ParseError!Value {
        _ = self;
        if (pos.* + length > data.len) {
            return error.UnexpectedEOF;
        }

        const bin = data[pos.* .. pos.* + length];
        pos.* += length;
        return Value{ .binary = bin };
    }

    /// Free memory allocated for a parsed value
    pub fn freeValue(self: *MessagePackParser, value: Value) void {
        switch (value) {
            .array => |arr| {
                for (arr) |item| {
                    self.freeValue(item);
                }
                self.allocator.free(arr);
            },
            .map => |m| {
                for (m) |entry| {
                    self.freeValue(entry.key);
                    self.freeValue(entry.value);
                }
                self.allocator.free(m);
            },
            else => {},
        }
    }

    /// Connection violation tracker for repeated limit violations
    pub const ConnectionViolationTracker = struct {
        violations: std.AutoHashMap(u64, u32),
        allocator: Allocator,
        threshold: u32,
        mutex: std.Thread.Mutex,

        pub fn init(allocator: Allocator, threshold: u32) ConnectionViolationTracker {
            return ConnectionViolationTracker{
                .violations = std.AutoHashMap(u64, u32).init(allocator),
                .allocator = allocator,
                .threshold = threshold,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *ConnectionViolationTracker) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.violations.deinit();
        }

        /// Record a violation for a connection. Returns true if connection should be closed.
        pub fn recordViolation(self: *ConnectionViolationTracker, connection_id: u64) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const result = try self.violations.getOrPut(connection_id);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
            return result.value_ptr.* >= self.threshold;
        }

        /// Clear violations for a connection (e.g., after successful parse)
        pub fn clearViolations(self: *ConnectionViolationTracker, connection_id: u64) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.violations.remove(connection_id);
        }

        /// Get violation count for a connection
        pub fn getViolationCount(self: *ConnectionViolationTracker, connection_id: u64) u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.violations.get(connection_id) orelse 0;
        }
    };
};
