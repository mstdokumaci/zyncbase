// zlint-disable no-print

const std = @import("std");

pub const class_std_builtin: u2 = 0;
pub const class_vendor: u2 = 1;
pub const class_local: u2 = 2;

pub const Import = struct {
    start: usize,
    end: usize,
    path: []const u8,
    class: u2,
    stray: bool = false,
    comment_start: ?usize = null,

    fn lessThan(ctx: void, a: Import, b: Import) bool {
        _ = ctx;
        if (a.class != b.class) return a.class < b.class;
        const cmp = std.mem.order(u8, a.path, b.path);
        if (cmp != .eq) return cmp == .lt;
        const a_len = a.end - a.start;
        const b_len = b.end - b.start;
        if (a_len != b_len) return a_len < b_len;
        return a.start < b.start;
    }
};

// Corresponding dependency declarations are in build.zig.
const vendor_modules = [_][]const u8{ "sqlite", "msgpack", "httpx" };

pub fn classify(path: []const u8) u2 {
    if (std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin")) {
        return class_std_builtin;
    }
    for (vendor_modules) |mod| {
        if (std.mem.eql(u8, path, mod)) return class_vendor;
    }
    return class_local;
}

fn findLineStart(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) : (i -= 1) {
        if (source[i - 1] == '\n') return i;
    }
    return 0;
}

fn findLineEnd(source: []const u8, pos: usize) usize {
    var i = pos;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') return i + 1;
    }
    return source.len;
}

pub fn findCImportEnd(source: []const u8, pos: usize) usize {
    var i = pos;
    var depth: usize = 0;
    var started = false;
    while (i < source.len) : (i += 1) {
        if (source[i] == '"') {
            i += 1;
            while (i < source.len and source[i] != '"') : (i += 1) {
                if (source[i] == '\\') i += 1;
            }
            continue;
        }
        if (source[i] == '\'') {
            i += 1;
            while (i < source.len and source[i] != '\'') : (i += 1) {
                if (source[i] == '\\') i += 1;
            }
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len) : (i += 1) {
                if (source[i] == '*' and source[i + 1] == '/') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        if (source[i] == '{') {
            started = true;
            depth += 1;
        } else if (source[i] == '}') {
            if (!started) break;
            depth -= 1;
            if (depth == 0) {
                while (i + 1 < source.len and source[i + 1] != '\n') : (i += 1) {}
                if (i + 1 < source.len and source[i + 1] == '\n') i += 1;
                return i + 1;
            }
        }
    }
    return findLineEnd(source, pos);
}

pub fn extractPath(source: []const u8, needle: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, source, needle) orelse return null;
    const open = pos + needle.len;
    if (open >= source.len) return null;
    const close = std.mem.indexOfScalar(u8, source[open..], ')') orelse return null;
    const inner = source[open .. open + close];
    if (inner.len == 0) return null;
    if (inner[0] == '"') {
        const e = std.mem.indexOfScalar(u8, inner[1..], '"') orelse return null;
        return inner[1 .. 1 + e];
    }
    return null;
}

pub fn isTopLevelImportLine(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t\n\r");
    if (trimmed.len == 0) return true;
    if (std.mem.startsWith(u8, trimmed, "//")) return true;

    if (std.mem.startsWith(u8, trimmed, "const ") or
        std.mem.startsWith(u8, trimmed, "pub const "))
    {
        if (std.mem.indexOf(u8, trimmed, "= struct") != null) return false;
        if (std.mem.indexOf(u8, trimmed, "= enum") != null) return false;
        if (std.mem.indexOf(u8, trimmed, "= union") != null) return false;
        if (std.mem.indexOf(u8, trimmed, "= opaque") != null) return false;

        if (std.mem.indexOf(u8, trimmed, "@import") != null) return true;
        if (std.mem.indexOf(u8, trimmed, "@cImport") != null) return true;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
        const before_eq = trimmed[0..eq];
        if (std.mem.indexOfScalar(u8, before_eq, ':') != null) return false;
        const rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \t;\n\r");
        if (rhs.len == 0 or (!std.ascii.isAlphabetic(rhs[0]) and rhs[0] != '_')) return false;
        var has_dot = false;
        for (rhs) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_') return false;
            if (c == '.') has_dot = true;
        }
        if (!has_dot) return false;
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "_ = @import")) return true;

    return false;
}

pub fn collectImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    block_end: usize,
) !std.ArrayListUnmanaged(Import) {
    var imports: std.ArrayListUnmanaged(Import) = .empty;
    errdefer imports.deinit(allocator);

    var i: usize = 0;
    var depth: usize = 0;

    while (i < source.len) : (i += 1) {
        if (source[i] == '"') {
            i += 1;
            while (i < source.len and source[i] != '"') : (i += 1) {
                if (source[i] == '\\') i += 1;
            }
            continue;
        }
        if (source[i] == '\'') {
            i += 1;
            while (i < source.len and source[i] != '\'') : (i += 1) {
                if (source[i] == '\\') i += 1;
            }
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len) : (i += 1) {
                if (source[i] == '*' and source[i + 1] == '/') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        if (source[i] == '{') depth += 1;
        if (source[i] == '}') depth -|= 1;

        if (std.mem.startsWith(u8, source[i..], "@import(")) {
            if (depth > 0) {
                i += "@import(".len - 1;
                continue;
            }
            const found = i;
            const line_start = findLineStart(source, found);
            const line_end = findLineEnd(source, found);
            const line = std.mem.trimLeft(u8, source[line_start..line_end], " \t\r");
            if (!std.mem.startsWith(u8, line, "const ") and
                !std.mem.startsWith(u8, line, "pub const ") and
                !std.mem.startsWith(u8, line, "_ = @import"))
            {
                i = line_end - 1;
                continue;
            }
            const path = extractPath(source[found..], "@import(") orelse {
                i = line_end - 1;
                continue;
            };
            var comment_start: ?usize = null;
            if (line_start > 0) {
                var back = line_start - 1;
                while (true) {
                    const prev_start = findLineStart(source, back);
                    const prev_end = findLineEnd(source, prev_start);
                    const prev_trimmed = std.mem.trimLeft(u8, source[prev_start..prev_end], " \t\r");
                    if (prev_trimmed.len == 0 or std.mem.startsWith(u8, prev_trimmed, "//")) {
                        comment_start = prev_start;
                        if (prev_start == 0) {
                            comment_start = null;
                            break;
                        }
                        back = prev_start - 1;
                    } else {
                        break;
                    }
                }
            }
            try imports.append(allocator, .{
                .start = line_start,
                .end = line_end,
                .path = path,
                .class = classify(path),
                .stray = found >= block_end,
                .comment_start = comment_start,
            });
            i = line_end - 1;
            continue;
        }

        if (std.mem.startsWith(u8, source[i..], "@cImport(")) {
            if (depth > 0) {
                i += "@cImport(".len - 1;
                continue;
            }
            const found = i;
            const line_start = findLineStart(source, found);
            const block_end_cimport = findCImportEnd(source, found);
            var comment_start: ?usize = null;
            if (line_start > 0) {
                var back = line_start - 1;
                while (true) {
                    const prev_start = findLineStart(source, back);
                    const prev_end = findLineEnd(source, prev_start);
                    const prev_trimmed = std.mem.trimLeft(u8, source[prev_start..prev_end], " \t\r");
                    if (prev_trimmed.len == 0 or std.mem.startsWith(u8, prev_trimmed, "//")) {
                        comment_start = prev_start;
                        if (prev_start == 0) {
                            comment_start = null;
                            break;
                        }
                        back = prev_start - 1;
                    } else {
                        break;
                    }
                }
            }
            try imports.append(allocator, .{
                .start = line_start,
                .end = block_end_cimport,
                .path = "<cimport>",
                .class = class_vendor,
                .stray = found >= block_end,
                .comment_start = comment_start,
            });
            i = block_end_cimport - 1;
            continue;
        }
    }

    std.sort.pdq(Import, imports.items, {}, Import.lessThan);
    return imports;
}

pub fn findImportBlockEnd(source: []const u8) usize {
    var pos: usize = 0;
    while (pos < source.len) {
        const line_end = findLineEnd(source, pos);
        const line = source[pos..line_end];
        if (std.mem.indexOf(u8, line, "@cImport(")) |cimport_pos| {
            pos = findCImportEnd(source, pos + cimport_pos);
            continue;
        }
        if (!isTopLevelImportLine(line)) return pos;
        pos = line_end;
    }
    return pos;
}

pub fn hasBannedPatterns(source: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, "@import(")) |found| {
        const line_start = findLineStart(source, found);
        const line_end_excl = findLineEnd(source, found);
        const line = std.mem.trimLeft(u8, source[line_start..line_end_excl], " \t\r");

        if (std.mem.startsWith(u8, line, "//")) {
            pos = line_end_excl;
            continue;
        }

        if (!std.mem.startsWith(u8, line, "const ") and
            !std.mem.startsWith(u8, line, "pub const ") and
            !std.mem.startsWith(u8, line, "_ = @import"))
        {
            return "inline @import in type expression";
        }

        const inner = source[found + "@import(".len ..];
        if (inner.len > 0 and inner[0] == '"') {
            const path_end = std.mem.indexOfScalar(u8, inner[1..], '"') orelse {
                pos = line_end_excl;
                continue;
            };
            const path = inner[1 .. 1 + path_end];
            if (std.mem.startsWith(u8, path, "./")) return "./ prefix on import path";
            if (std.mem.startsWith(u8, path, "src/")) return "absolute import path";
        }

        pos = line_end_excl;
    }

    var line_pos: usize = 0;
    while (line_pos < source.len) {
        const le = findLineEnd(source, line_pos);
        const l = std.mem.trimLeft(u8, source[line_pos..le], " \t\r");
        if (!std.mem.startsWith(u8, l, "//") and std.mem.indexOf(u8, l, "usingnamespace") != null) {
            return "usingnamespace detected";
        }
        line_pos = le;
    }

    return null;
}

pub fn buildSortedImportText(
    allocator: std.mem.Allocator,
    source: []const u8,
    sorted_imports: []const Import,
    block_end: usize,
) ![]const u8 {
    var extra_imports: std.ArrayListUnmanaged(Import) = .empty;
    defer extra_imports.deinit(allocator);

    var preamble_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer preamble_lines.deinit(allocator);

    var trailing_comments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer trailing_comments.deinit(allocator);

    var trailing_comment_start: ?usize = null;

    var seen_content: bool = false;
    var pos: usize = 0;
    while (pos < block_end) {
        const le = findLineEnd(source, pos);
        const line = source[pos..le];
        const trimmed = std.mem.trimLeft(u8, line, " \t\n\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            if (!seen_content) {
                try preamble_lines.append(allocator, line);
            } else {
                if (trailing_comment_start == null) trailing_comment_start = pos;
                try trailing_comments.append(allocator, line);
            }
            pos = le;
            continue;
        }
        seen_content = true;
        if (std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "pub const ")) {
            if (std.mem.indexOf(u8, trimmed, "@import(") == null and
                std.mem.indexOf(u8, trimmed, "@cImport(") == null)
            {
                const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                };
                const rhs_raw = trimmed[eq + 1 ..];
                const rhs = std.mem.trim(u8, rhs_raw, " \t;\n\r");
                if (rhs.len == 0 or (!std.ascii.isAlphabetic(rhs[0]) and rhs[0] != '_')) {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                }
                var valid_rhs = true;
                for (rhs) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_') {
                        valid_rhs = false;
                        break;
                    }
                }
                if (!valid_rhs) {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                }
                const dot = std.mem.indexOfScalar(u8, rhs, '.') orelse {
                    pos = le;
                    trailing_comment_start = null;
                    trailing_comments.clearRetainingCapacity();
                    continue;
                };
                const module_name = rhs[0..dot];
                const attached_comment_start = trailing_comment_start;
                trailing_comment_start = null;
                trailing_comments.clearRetainingCapacity();
                try extra_imports.append(allocator, .{
                    .start = pos,
                    .end = le,
                    .path = rhs,
                    .class = classify(module_name),
                    .stray = false,
                    .comment_start = attached_comment_start,
                });
            } else {
                trailing_comment_start = null;
                trailing_comments.clearRetainingCapacity();
            }
        } else {
            trailing_comment_start = null;
            trailing_comments.clearRetainingCapacity();
        }
        pos = le;
    }

    var all_imports: std.ArrayListUnmanaged(Import) = .empty;
    defer all_imports.deinit(allocator);
    try all_imports.appendSlice(allocator, sorted_imports);

    var imports_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer imports_buf.deinit(allocator);

    var prev_class: ?u2 = null;
    for (all_imports.items) |imp| {
        if (prev_class != null and prev_class.? != imp.class) {
            try imports_buf.append(allocator, '\n');
        }
        prev_class = imp.class;
        if (imp.comment_start) |cs| {
            try imports_buf.appendSlice(allocator, source[cs..imp.start]);
        }
        const text = source[imp.start..imp.end];
        const trimmed_import = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed_import.len > 0) {
            try imports_buf.appendSlice(allocator, trimmed_import);
            try imports_buf.append(allocator, '\n');
        }
    }

    if (extra_imports.items.len > 0) {
        if (imports_buf.items.len > 0 and imports_buf.items[imports_buf.items.len - 1] != '\n') {
            try imports_buf.append(allocator, '\n');
        }
        if (all_imports.items.len > 0) {
            try imports_buf.append(allocator, '\n');
        }
        for (extra_imports.items) |imp| {
            if (imp.comment_start) |cs| {
                try imports_buf.appendSlice(allocator, source[cs..imp.start]);
            }
            const text = source[imp.start..imp.end];
            const trimmed_import = std.mem.trim(u8, text, " \t\n\r");
            if (trimmed_import.len > 0) {
                try imports_buf.appendSlice(allocator, trimmed_import);
                try imports_buf.append(allocator, '\n');
            }
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (preamble_lines.items) |line| {
        try buf.appendSlice(allocator, line);
    }
    if (preamble_lines.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
        try buf.append(allocator, '\n');
    }

    try buf.appendSlice(allocator, imports_buf.items);

    if (trailing_comments.items.len > 0) {
        try buf.append(allocator, '\n');
        for (trailing_comments.items) |line| {
            try buf.appendSlice(allocator, line);
        }
    }

    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '\n') {
        try buf.append(allocator, '\n');
    }

    var deduped: std.ArrayListUnmanaged(u8) = .empty;
    errdefer deduped.deinit(allocator);
    for (buf.items, 0..) |ch, i| {
        if (ch == '\n' and i >= 2 and buf.items[i - 1] == '\n' and buf.items[i - 2] == '\n') continue;
        try deduped.append(allocator, ch);
    }
    buf.deinit(allocator);

    return deduped.toOwnedSlice(allocator);
}

fn showDiff(file_path: []const u8, old: []const u8, new: []const u8) void {
    var obuf: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_w = stdout_file.writer(&obuf);

    stdout_w.interface.print("  --- {s}\n", .{file_path}) catch return;
    var old_lines = std.mem.splitScalar(u8, old, '\n');
    while (old_lines.next()) |line| {
        stdout_w.interface.print("  - {s}\n", .{line}) catch return;
    }
    var new_lines = std.mem.splitScalar(u8, new, '\n');
    while (new_lines.next()) |line| {
        stdout_w.interface.print("  + {s}\n", .{line}) catch return;
    }
    stdout_w.interface.writeAll("\n") catch return;
    stdout_w.interface.flush() catch return;
}

fn walkDir(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    base_path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
) !void {
    var iter = try dir.walk(allocator);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.path });
        try files.append(allocator, full_path);
    }
}

fn hasSkipComment(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "// zsort: skip") != null;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("Usage: zsort [check|fix] <dir|file>\n", .{});
        std.process.exit(1);
    }

    const mode_str = args[1];
    const target = args[2];

    const mode: enum { check, fix } = if (std.mem.eql(u8, mode_str, "fix"))
        .fix
    else if (std.mem.eql(u8, mode_str, "check"))
        .check
    else {
        std.debug.print("Invalid mode. Use 'check' or 'fix'.\n", .{});
        std.process.exit(1);
    };

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    const stat = std.fs.cwd().statFile(target) catch |err| {
        std.debug.print("Cannot access '{s}': {s}\n", .{ target, @errorName(err) });
        std.process.exit(1);
    };

    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(target, .{ .iterate = true });
        defer dir.close();
        try walkDir(allocator, dir, target, &files);
    } else if (stat.kind == .file) {
        try files.append(allocator, target);
    } else {
        std.debug.print("'{s}' is not a supported file or directory\n", .{target});
        std.process.exit(1);
    }

    if (files.items.len == 0) {
        std.debug.print("No .zig files found in '{s}'\n", .{target});
        std.process.exit(1);
    }

    var changed_count: usize = 0;
    var error_count: usize = 0;
    var banned_count: usize = 0;

    for (files.items) |file_path| {
        var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const source = std.fs.cwd().readFileAlloc(fa, file_path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Error reading {s}: {s}\n", .{ file_path, @errorName(err) });
            error_count += 1;
            continue;
        };

        if (hasSkipComment(source)) continue;

        const block_end = findImportBlockEnd(source);
        const result = try collectImports(fa, source, block_end);

        if (result.items.len == 0) continue;

        if (hasBannedPatterns(source)) |msg| {
            std.debug.print("{s}: banned: {s}\n", .{ file_path, msg });
            banned_count += 1;
        }

        var stray_imports = std.ArrayListUnmanaged(Import).empty;
        for (result.items) |imp| {
            if (imp.stray) {
                try stray_imports.append(fa, imp);
            }
        }
        var rest = source[block_end..];
        var filtered_rest_owned: ?[]u8 = null;
        if (stray_imports.items.len > 0) {
            std.sort.pdq(Import, stray_imports.items, {}, struct {
                fn lt(_: void, a: Import, b: Import) bool {
                    return a.start < b.start;
                }
            }.lt);
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            var pos: usize = block_end;
            for (stray_imports.items) |imp| {
                try buf.appendSlice(fa, source[pos..imp.start]);
                pos = imp.end;
            }
            try buf.appendSlice(fa, source[pos..]);
            filtered_rest_owned = try buf.toOwnedSlice(fa);
            rest = filtered_rest_owned.?;
        }

        const new_imports = buildSortedImportText(fa, source, result.items, block_end) catch |err| {
            std.debug.print("Error building sorted imports for {s}: {s}\n", .{ file_path, @errorName(err) });
            error_count += 1;
            continue;
        };

        const original_block = source[0..block_end];
        if (std.mem.eql(u8, original_block, new_imports) and stray_imports.items.len == 0) continue;

        changed_count += 1;

        if (mode == .fix) {
            const full_new = std.mem.concat(fa, u8, &.{ new_imports, rest }) catch |err| {
                std.debug.print("Error allocating for {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };

            var af_buf: [4096]u8 = undefined;
            var af = std.fs.cwd().atomicFile(file_path, .{ .write_buffer = &af_buf }) catch |err| {
                std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
            defer af.deinit();
            af.file_writer.interface.writeAll(full_new) catch |err| {
                std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
            try af.finish();
            std.debug.print("Fixed: {s}\n", .{file_path});
        } else {
            showDiff(file_path, original_block, new_imports);
        }
    }

    if (mode == .check) {
        if (changed_count > 0 or error_count > 0 or banned_count > 0) {
            std.debug.print("{} needs fixing, {} errors, {} banned\n", .{ changed_count, error_count, banned_count });
            std.process.exit(1);
        }
    } else {
        var obuf2: [256]u8 = undefined;
        const stdout_file2 = std.fs.File.stdout();
        var stdout_w2 = stdout_file2.writer(&obuf2);
        stdout_w2.interface.print("\nFixed {} files, {} errors, {} banned\n", .{ changed_count, error_count, banned_count }) catch return;
        stdout_w2.interface.flush() catch return;
        if (changed_count > 0 or banned_count > 0) std.process.exit(1);
    }
}
