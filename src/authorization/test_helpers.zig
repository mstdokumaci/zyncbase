const std = @import("std");
const authorization_parse = @import("parse.zig");
const authorization_defaults = @import("defaults.zig");
const authorization_types = @import("types.zig");
const schema_types = @import("../schema/types.zig");
const schema_helpers = @import("../schema/test_helpers.zig");

pub const AuthConfig = authorization_types.AuthConfig;

pub fn initTestConfig(allocator: std.mem.Allocator, json: []const u8) !AuthConfig {
    var schema = try makeAuthTestSchema(allocator);
    defer schema.deinit();
    return authorization_parse.initFromJson(allocator, json, &schema);
}

pub fn implicitTestConfig(allocator: std.mem.Allocator) !AuthConfig {
    var schema = try makeAuthTestSchema(allocator);
    defer schema.deinit();
    return authorization_defaults.implicitConfig(allocator, &schema);
}

fn makeAuthTestSchema(allocator: std.mem.Allocator) !schema_types.Schema {
    const text_types = [_]schema_types.FieldType{.text};
    return schema_helpers.createTestSchema(allocator, &[_]schema_helpers.TableDef{
        .{
            .name = "posts",
            .fields = &[_][]const u8{"visibility"},
            .types = &text_types,
        },
        .{
            .name = "test",
            .fields = &[_][]const u8{"visibility"},
            .types = &text_types,
        },
    });
}
