const std = @import("std");

const zsort = @import("zsort.zig");

test "classify: std/builtin" {
    try std.testing.expectEqual(zsort.class_std_builtin, zsort.classify("std"));
    try std.testing.expectEqual(zsort.class_std_builtin, zsort.classify("builtin"));
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
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }));
}

test "hasBannedPatterns: ./ prefix detected" {
    const source = "const foo = @import(\"./bar\");\n";
    const msg = zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "./") != null);
}

test "hasBannedPatterns: ./ prefix ignored when not listed" {
    const source = "const foo = @import(\"./bar\");\n";
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, source, &.{"src/"}));
}

test "hasBannedPatterns: src/ prefix detected only when listed" {
    const src_source = "const foo = @import(\"src/bar.zig\");\n";
    const msg = zsort.hasBannedPatterns(std.testing.allocator, src_source, &.{ "./", "src/" }) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "src/") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, src_source, &.{"./"}));
}

test "hasBannedPatterns: multiple prefixes, unmatched prefix no flag" {
    const source =
        \\const std = @import("std");
        \\const foo = @import("bar.zig");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "lib/", "app/" }));
}

test "hasBannedPatterns: commented-out @import ignored" {
    const source =
        \\ // const foo = @import("bar");
        \\const std = @import("std");
    ;
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, source, &.{ "./", "src/" }));
}

test "hasBannedPatterns: inline @import detected even without prefixes" {
    const source = "fn foo() @import(\"bar\").Type {\n}\n";
    const msg = zsort.hasBannedPatterns(std.testing.allocator, source, &.{}) orelse return error.TestFailed;
    defer std.testing.allocator.free(msg);
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

test "hasBannedPatterns: self-scan clean" {
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, @embedFile("zsort.zig"), &.{ "./", "src/" }));
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, @embedFile("zsort_test.zig"), &.{ "./", "src/" }));
}

test "hasBannedPatterns: backslash-prefixed lines ignored" {
    const source = "\\\\const x = @import(\"a\");\nconst std = @import(\"std\");\n";
    try std.testing.expectEqual(@as(?[]const u8, null), zsort.hasBannedPatterns(std.testing.allocator, source, &.{}));
}

test "collectImports: braces in multiline-string line don't affect depth" {
    const source = "\\\\const a = struct {\nconst real = @import(\"real.zig\");\n";
    var imports = try zsort.collectImports(std.testing.allocator, source, 0);
    defer imports.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);
    try std.testing.expectEqualStrings("real.zig", imports.items[0].path);
}

test "isTopLevelImportLine: unterminated lines are not import lines" {
    try std.testing.expect(!zsort.isTopLevelImportLine("const Allocator = std.mem\n"));
    try std.testing.expect(!zsort.isTopLevelImportLine("const x = @import(\"a\")\n"));
    try std.testing.expect(zsort.isTopLevelImportLine("const x = @import(\"a\"); // comment\n"));
}

test "findImportBlockEnd: stops before unterminated alias line" {
    const source =
        \\const std = @import("std");
        \\
        \\const Allocator = std.mem
        \\    .Allocator;
    ;
    try std.testing.expectEqual("const std = @import(\"std\");\n\n".len, zsort.findImportBlockEnd(source));
}

test "processSource: hoists multiline stray import intact" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
        \\
        \\const late = @import(
        \\    "late.zig"
        \\);
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.new_text, "late.zig"));
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "late.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.new_text, "late.zig").? < std.mem.indexOf(u8, result.new_text, "pub fn main").?);
}

test "processSource: skip comment leaves file untouched" {
    const source =
        \\// zsort: skip
        \\const bar = @import("bar");
    ;
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    try std.testing.expect(!result.changed);
    try std.testing.expectEqualStrings(source, result.new_text);
}

test "processSource: idempotent" {
    const source =
        \\const bar = @import("bar");
        \\const std = @import("std");
        \\
        \\pub fn main() !void {}
        \\const zz = @import("zz.zig");
    ;
    const r1 = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(r1.new_text);
    defer std.testing.allocator.free(r1.new_block);
    const r2 = try zsort.processSource(std.testing.allocator, r1.new_text, &.{});
    defer std.testing.allocator.free(r2.new_text);
    defer std.testing.allocator.free(r2.new_block);
    try std.testing.expect(!r2.changed);
    try std.testing.expectEqualStrings(r1.new_text, r2.new_text);
}

test "processSource: preserves CRLF line endings" {
    const source = "const bar = @import(\"bar\");\r\nconst std = @import(\"std\");\r\n\r\npub fn main() !void {}\r\n";
    const result = try zsort.processSource(std.testing.allocator, source, &.{});
    defer std.testing.allocator.free(result.new_text);
    defer std.testing.allocator.free(result.new_block);
    try std.testing.expect(result.changed);
    var prev: u8 = 0;
    for (result.new_text) |ch| {
        if (ch == '\n') try std.testing.expectEqual(@as(u8, '\r'), prev);
        prev = ch;
    }
}

test "walkDir: excludes cache and vcs directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".git");
    try tmp.dir.makePath(".zig-cache");
    try tmp.dir.makePath("zig-cache");
    try tmp.dir.makePath("zig-out");
    try tmp.dir.makePath("sub");
    try tmp.dir.writeFile(.{ .sub_path = "main.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "sub/lib.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = ".git/a.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = ".zig-cache/b.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "zig-cache/c.zig", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "zig-out/d.zig", .data = "" });
    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (found.items) |f| std.testing.allocator.free(f);
        found.deinit(std.testing.allocator);
    }
    try zsort.walkDir(std.testing.allocator, tmp.dir, "tmp", &found);
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    for (found.items) |f| {
        try std.testing.expect(std.mem.endsWith(u8, f, "main.zig") or std.mem.endsWith(u8, f, "sub/lib.zig"));
    }
}

test "parseArgs: check mode with prefixes" {
    const args = [_][]const u8{ "zsort", "check", "src", "--ban-prefix", "./", "--ban-prefix", "src/" };
    var parsed = try zsort.parseArgs(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.mode == .check);
    try std.testing.expectEqualStrings("src", parsed.target);
    try std.testing.expectEqual(@as(usize, 2), parsed.banned_prefixes.items.len);
    try std.testing.expectEqualStrings("./", parsed.banned_prefixes.items[0]);
    try std.testing.expectEqualStrings("src/", parsed.banned_prefixes.items[1]);
}

test "parseArgs: fix mode" {
    const args = [_][]const u8{ "zsort", "fix", "tools" };
    var parsed = try zsort.parseArgs(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.mode == .fix);
    try std.testing.expectEqualStrings("tools", parsed.target);
    try std.testing.expectEqual(@as(usize, 0), parsed.banned_prefixes.items.len);
}

test "parseArgs: errors" {
    try std.testing.expectError(error.Usage, zsort.parseArgs(std.testing.allocator, &.{"zsort"}));
    try std.testing.expectError(error.Usage, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check" }));
    try std.testing.expectError(error.InvalidMode, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "fixx", "src" }));
    try std.testing.expectError(error.MissingBanValue, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "--ban-prefix" }));
    try std.testing.expectError(error.UnexpectedArg, zsort.parseArgs(std.testing.allocator, &.{ "zsort", "check", "src", "extra" }));
}
