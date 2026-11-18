//! Loads the target schema from configuration, shared by the server and the
//! migration CLI so both see exactly the same schema and identity.

const std = @import("std");

const canonical = @import("../schema/canonical.zig");
const schema_parse = @import("../schema/parse.zig");
const schema_system = @import("../schema/system.zig");
const schema_types = @import("../schema/types.zig");
const Config = @import("../config/state.zig").Config;

const Allocator = std.mem.Allocator;

pub const max_schema_bytes = 10 * 1024 * 1024;

pub const Loaded = struct {
    schema: schema_types.Schema,
    /// Minified source JSON and its hash: the applied-schema snapshot.
    identity: canonical.Identity,

    pub fn deinit(self: *Loaded, allocator: Allocator) void {
        self.schema.deinit();
        self.identity.deinit(allocator);
    }
};

/// Inline schema content, the schema file, or the implicit users-only schema
/// when the file is missing.
pub fn load(io: std.Io, allocator: Allocator, config: *const Config) !Loaded {
    var owned: ?[]u8 = null;
    defer if (owned) |text| allocator.free(text);

    const json_text: []const u8 = blk: {
        if (config.schema_content) |content| break :blk content;
        std.log.info("Loading schema from: {s}", .{config.schema_file});
        owned = std.Io.Dir.cwd().readFileAlloc(io, config.schema_file, allocator, .limited(max_schema_bytes)) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Schema file '{s}' not found, using implicit users-only schema", .{config.schema_file});
                break :blk schema_system.implicit_users_schema_json;
            }
            std.log.err("Failed to read schema file '{s}': {}", .{ config.schema_file, err });
            return err;
        };
        break :blk owned.?;
    };

    var schema = try schema_parse.initFromJson(allocator, json_text);
    errdefer schema.deinit();
    return .{ .schema = schema, .identity = try canonical.Identity.init(allocator, json_text) };
}
