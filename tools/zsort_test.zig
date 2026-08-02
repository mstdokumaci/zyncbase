const std = @import("std");
const zsort = @import("zsort.zig");

test "classify: std/builtin" {
    try std.testing.expectEqual(zsort.class_std_builtin, zsort.classify("std"));
    try std.testing.expectEqual(zsort.class_std_builtin, zsort.classify("builtin"));
    try std.testing.expectEqual(zsort.class_std_builtin, zsort.classify("@zig"));
}

test "classify: third-party modules" {
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("sqlite"));
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("msgpack"));
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("httpx"));
    try std.testing.expectEqual(zsort.class_third_party, zsort.classify("foo"));
}

test "classify: local" {
    try std.testing.expectEqual(zsort.class_local, zsort.classify("foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("subdir/foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("./foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("../foo.zig"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("root"));
    try std.testing.expectEqual(zsort.class_local, zsort.classify("build_root"));
}

test "extractPath: normal" {
    try std.testing.expectEqualStrings("bar", zsort.extractPath("@import(\"bar\")", "@import(").?);
}

test "extractPath: null on malformed" {
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.extractPath("@import(bar)", "@import("));
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.extractPath("noimport", "@import("));
}

test "isTopLevelImportLine: basic import" {
    try std.testing.expect(zsort.isTopLevelImportLine("const std = @import(\"std\");\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("pub const foo = @import(\"foo\");\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("_ = @import(\"bar\");\n"));
}

test "isTopLevelImportLine: semicolon terminated alias" {
    try std.testing.expect(zsort.isTopLevelImportLine("const Payload = msgpack.Payload;\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const Debug = std.debug;\n"));
}

test "isTopLevelImportLine: not import lines" {
    try std.testing.expect(!zsort.isTopLevelImportLine("const S = struct {\n"));
    try std.testing.expect(!zsort.isTopLevelImportLine("const E = enum {\n"));
    try std.testing.expect(!zsort.isTopLevelImportLine("pub fn main() !void {\n"));
}

test "isTopLevelImportLine: comments and empty lines" {
    try std.testing.expect(zsort.isTopLevelImportLine("// some comment\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("  \t\n"));
}

test "findImportBlockEnd: ends at first non-import" {
    const source =
        \\const std = @import("std");
        \\
        \\const Foo = struct {
    ;
    try std.testing.expectEqual("const std = @import(\"std\");\n\n".len, zsort.findImportBlockEnd(source));
}

test "findCImportEnd: basic block" {
    const source =
        \\const c = @cImport({
        \\    int x = 1;
        \\});
        \\
        \\const rest = 42;
    ;
    const cimport_pos = std.mem.indexOf(u8, source, "@cImport(") orelse return error.TestFailed;
    const end = zsort.findCImportEnd(source, cimport_pos);
    try std.testing.expect(end > cimport_pos);
    try std.testing.expect(std.mem.indexOf(u8, source[end..], "const rest") != null);
}

test "findCImportEnd: braces in strings ignored" {
    const source =
        \\const c = @cImport({
        \\    printf("{ hello }");
        \\});
        \\
        \\const rest = 42;
    ;
    const cimport_pos = std.mem.indexOf(u8, source, "@cImport(") orelse return error.TestFailed;
    const end = zsort.findCImportEnd(source, cimport_pos);
    try std.testing.expect(end > cimport_pos);
    try std.testing.expect(std.mem.indexOf(u8, source[end..], "const rest") != null);
}

test "hasBannedPatterns: no problems" {
    const source =
        \\const std = @import("std");
        \\const foo = @import("foo");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(source));
}

test "hasBannedPatterns: ./ prefix detected" {
    const source = "const foo = @import(\"./bar\");\n";
    try std.testing.expect(zsort.hasBannedPatterns(source) != null);
}

test "hasBannedPatterns: commented-out @import ignored" {
    const source =
        \\ // const foo = @import("bar");
        \\const std = @import("std");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(source));
}

test "hasBannedPatterns: usingnamespace detected" {
    const source =
        \\const std = @import("std");
        \\usingnamespace @import("foo");
    ;
    try std.testing.expect(zsort.hasBannedPatterns(source) != null);
}

test "hasBannedPatterns: commented-out usingnamespace ignored" {
    const source =
        \\const std = @import("std");
        \\// usingnamespace @import("foo");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(source));
}

test "buildSortedImportText: basic sort" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\const foo = @import("foo");
        \\
        \\const rest = 1;
    ;
    const block_end = zsort.findImportBlockEnd(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);

    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, block_end);
    defer std.testing.allocator.free(result);

    const pos_std = std.mem.indexOf(u8, result, "std") orelse return error.TestUnexpectedResult;
    const pos_bar = std.mem.indexOf(u8, result, "bar") orelse return error.TestUnexpectedResult;
    const pos_foo = std.mem.indexOf(u8, result, "foo") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pos_std < pos_bar);
    try std.testing.expect(pos_bar < pos_foo);
}

test "buildSortedImportText: idempotent fix twice" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
    ;
    const block_end1 = zsort.findImportBlockEnd(source);
    var imports1 = try collectImportsForTest(source, block_end1);
    defer imports1.deinit(std.testing.allocator);
    const pass1 = try zsort.buildSortedImportText(std.testing.allocator, source, imports1.items, block_end1);
    defer std.testing.allocator.free(pass1);

    var full1: std.ArrayListUnmanaged(u8) = .empty;
    defer full1.deinit(std.testing.allocator);
    try full1.appendSlice(std.testing.allocator, pass1);
    try full1.appendSlice(std.testing.allocator, source[block_end1..]);

    const block_end2 = zsort.findImportBlockEnd(full1.items);
    var imports2 = try collectImportsForTest(full1.items, block_end2);
    defer imports2.deinit(std.testing.allocator);
    const pass2 = try zsort.buildSortedImportText(std.testing.allocator, full1.items, imports2.items, block_end2);
    defer std.testing.allocator.free(pass2);

    try std.testing.expectEqualStrings(pass1, pass2);
}

test "buildSortedImportText: comments separating groups" {
    const source =
        \\const std = @import("std");
        \\
        \\// Third-party imports
        \\const sqlite = @import("sqlite");
        \\
        \\const rest = 1;
    ;
    const block_end = zsort.findImportBlockEnd(source);
    var imports = try collectImportsForTest(source, block_end);
    defer imports.deinit(std.testing.allocator);

    const result = try zsort.buildSortedImportText(std.testing.allocator, source, imports.items, block_end);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "// Third-party imports") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "std") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sqlite") != null);
}

fn collectImportsForTest(source: []const u8, block_end: usize) !std.ArrayListUnmanaged(zsort.Import) {
    return zsort.collectImports(std.testing.allocator, source, block_end);
}
