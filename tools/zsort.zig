// zlint-disable no-print

const std = @import("std");

pub const class_std_builtin: u2 = 0;
pub const class_third_party: u2 = 1;
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

pub fn classify(path: []const u8) u2 {
    if (std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin")) {
        return class_std_builtin;
    }
    if (std.mem.eql(u8, path, "root") or std.mem.eql(u8, path, "build_root") or
        std.mem.indexOfScalar(u8, path, '/') != null or
        std.mem.endsWith(u8, path, ".zig"))
    {
        return class_local;
    }
    return class_third_party;
}

fn skipStringOrComment(source: []const u8, pos: usize) usize {
    const ch = source[pos];
    if (ch == '"' or ch == '\'') {
        var i = pos + 1;
        while (i < source.len and source[i] != ch) : (i += 1) {
            if (source[i] == '\\') i += 1;
        }
        return @min(i + 1, source.len);
    }
    if (ch == '/' and pos + 1 < source.len) {
        if (source[pos + 1] == '/') {
            var i = pos + 2;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            return @min(i + 1, source.len);
        }
        if (source[pos + 1] == '*') {
            var i = pos + 2;
            while (i + 1 < source.len) : (i += 1) {
                if (source[i] == '*' and source[i + 1] == '/') {
                    i += 1;
                    break;
                }
            }
            return @min(i + 2, source.len);
        }
    }
    if (ch == '\\' and pos + 1 < source.len and source[pos + 1] == '\\') {
        var k = pos;
        while (k > 0 and source[k - 1] != '\n') : (k -= 1) {
            if (source[k - 1] != ' ' and source[k - 1] != '\t') break;
        }
        if (k == 0 or source[k - 1] == '\n') {
            var i = pos + 2;
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            return @min(i + 1, source.len);
        }
    }
    return pos;
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
    while (i < source.len) {
        const skip = skipStringOrComment(source, i);
        if (skip != i) {
            i = skip;
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
        i += 1;
    }
    return findLineEnd(source, pos);
}

pub fn extractPath(source: []const u8, needle: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, source, needle) orelse return null;
    var open = pos + needle.len;
    while (open < source.len and
        (source[open] == ' ' or source[open] == '\t' or source[open] == '\r' or source[open] == '\n')) : (open += 1)
    {}
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

fn endsWithSemicolon(trimmed: []const u8) bool {
    var t = trimmed;
    if (std.mem.indexOf(u8, t, "//")) |c| t = t[0..c];
    if (std.mem.indexOf(u8, t, "/*")) |c| t = t[0..c];
    t = std.mem.trimRight(u8, t, " \t\r\n");
    return t.len > 0 and t[t.len - 1] == ';';
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

        if (std.mem.indexOf(u8, trimmed, "@import") != null) return endsWithSemicolon(trimmed);
        if (std.mem.indexOf(u8, trimmed, "@cImport") != null) return endsWithSemicolon(trimmed);

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
        return endsWithSemicolon(trimmed);
    }

    if (std.mem.startsWith(u8, trimmed, "_ = @import")) return endsWithSemicolon(trimmed);

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

    while (i < source.len) {
        const skip = skipStringOrComment(source, i);
        if (skip != i) {
            i = skip;
            continue;
        }
        if (source[i] == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (source[i] == '}') {
            depth -|= 1;
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, source[i..], "@import(")) {
            if (depth > 0) {
                i += "@import(".len;
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
                i = line_end;
                continue;
            }
            const path = extractPath(source[found..], "@import(") orelse {
                i = line_end;
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
            var import_end = line_end;
            if (!endsWithSemicolon(line)) {
                var j = line_end;
                while (j < source.len) {
                    const j_skip = skipStringOrComment(source, j);
                    if (j_skip != j) {
                        j = j_skip;
                        continue;
                    }
                    if (source[j] == ';') {
                        import_end = j + 1;
                        break;
                    }
                    if (source[j] == '{' or source[j] == '}') break;
                    j += 1;
                }
                if (import_end == line_end) {
                    i = line_end;
                    continue;
                }
            }
            try imports.append(allocator, .{
                .start = line_start,
                .end = import_end,
                .path = path,
                .class = classify(path),
                .stray = found >= block_end,
                .comment_start = comment_start,
            });
            i = import_end;
            continue;
        }

        if (std.mem.startsWith(u8, source[i..], "@cImport(")) {
            if (depth > 0) {
                i += "@cImport(".len;
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
                .class = class_third_party,
                .stray = found >= block_end,
                .comment_start = comment_start,
            });
            i = block_end_cimport;
            continue;
        }

        i += 1;
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

fn banMessage(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch |err| {
        std.debug.print("zsort: failed to format ban message: {s}\n", .{@errorName(err)});
        return null;
    };
}

pub fn hasBannedPatterns(
    allocator: std.mem.Allocator,
    source: []const u8,
    banned_prefixes: []const []const u8,
) ?[]const u8 {
    var i: usize = 0;
    while (i < source.len) {
        const skip = skipStringOrComment(source, i);
        if (skip != i) {
            i = skip;
            continue;
        }
        if (std.mem.startsWith(u8, source[i..], "@import(")) {
            const found = i;
            const line_start = findLineStart(source, found);
            const line_end_excl = findLineEnd(source, found);
            const line = std.mem.trimLeft(u8, source[line_start..line_end_excl], " \t\r");

            if (!std.mem.startsWith(u8, line, "const ") and
                !std.mem.startsWith(u8, line, "pub const ") and
                !std.mem.startsWith(u8, line, "_ = @import"))
            {
                return banMessage(allocator, "inline @import in type expression", .{});
            }

            if (extractPath(source[found..], "@import(")) |path| {
                for (banned_prefixes) |prefix| {
                    if (std.mem.startsWith(u8, path, prefix)) {
                        return banMessage(allocator, "import path starts with banned prefix '{s}'", .{prefix});
                    }
                }
            }

            i = line_end_excl;
            continue;
        }
        i += 1;
    }

    return null;
}

fn detectNewline(source: []const u8) []const u8 {
    var crlf: usize = 0;
    var lf: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            lf += 1;
            if (i > 0 and source[i - 1] == '\r') crlf += 1;
        }
    }
    return if (crlf * 2 > lf) "\r\n" else "\n";
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

    const nl = detectNewline(source);

    var prev_class: ?u2 = null;
    for (all_imports.items) |imp| {
        if (prev_class != null and prev_class.? != imp.class) {
            try imports_buf.appendSlice(allocator, nl);
        }
        prev_class = imp.class;
        if (imp.comment_start) |cs| {
            try imports_buf.appendSlice(allocator, source[cs..imp.start]);
        }
        const text = source[imp.start..imp.end];
        const trimmed_import = std.mem.trim(u8, text, " \t\n\r");
        if (trimmed_import.len > 0) {
            try imports_buf.appendSlice(allocator, trimmed_import);
            try imports_buf.appendSlice(allocator, nl);
        }
    }

    if (extra_imports.items.len > 0) {
        if (imports_buf.items.len > 0 and imports_buf.items[imports_buf.items.len - 1] != '\n') {
            try imports_buf.appendSlice(allocator, nl);
        }
        if (all_imports.items.len > 0) {
            try imports_buf.appendSlice(allocator, nl);
        }
        for (extra_imports.items) |imp| {
            if (imp.comment_start) |cs| {
                try imports_buf.appendSlice(allocator, source[cs..imp.start]);
            }
            const text = source[imp.start..imp.end];
            const trimmed_import = std.mem.trim(u8, text, " \t\n\r");
            if (trimmed_import.len > 0) {
                try imports_buf.appendSlice(allocator, trimmed_import);
                try imports_buf.appendSlice(allocator, nl);
            }
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (preamble_lines.items) |line| {
        try buf.appendSlice(allocator, line);
    }
    if (preamble_lines.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
        try buf.appendSlice(allocator, nl);
    }

    try buf.appendSlice(allocator, imports_buf.items);

    if (trailing_comments.items.len > 0) {
        try buf.appendSlice(allocator, nl);
        for (trailing_comments.items) |line| {
            try buf.appendSlice(allocator, line);
        }
    }

    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '\n') {
        try buf.appendSlice(allocator, nl);
    }

    var deduped: std.ArrayListUnmanaged(u8) = .empty;
    errdefer deduped.deinit(allocator);
    var blank_run: usize = 0;
    var line_pos: usize = 0;
    while (line_pos < buf.items.len) {
        const le = findLineEnd(buf.items, line_pos);
        const line = buf.items[line_pos..le];
        const is_blank = std.mem.trim(u8, line, " \t\r\n").len == 0;
        blank_run = if (is_blank) blank_run + 1 else 0;
        if (blank_run < 2) try deduped.appendSlice(allocator, line);
        line_pos = le;
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

const excluded_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out" };

fn isExcludedPath(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        for (excluded_dirs) |dir_name| {
            if (std.mem.eql(u8, component, dir_name)) return true;
        }
    }
    return false;
}

pub fn walkDir(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    base_path: []const u8,
    files: *std.ArrayListUnmanaged([]const u8),
) !void {
    var iter = try dir.walk(allocator);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (isExcludedPath(entry.path)) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.path });
        try files.append(allocator, full_path);
    }
}

fn hasSkipComment(source: []const u8) bool {
    var pos: usize = 0;
    while (pos < source.len) {
        const le = findLineEnd(source, pos);
        const trimmed = std.mem.trimLeft(u8, source[pos..le], " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//") and std.mem.indexOf(u8, trimmed, "zsort: skip") != null) {
            return true;
        }
        pos = le;
    }
    return false;
}

pub const ProcessResult = struct {
    new_text: []const u8,
    new_block: []const u8,
    block_end: usize,
    changed: bool,
    banned: bool,
    banned_msg: ?[]const u8,
    stray_count: usize,
};

pub fn processSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    banned_prefixes: []const []const u8,
) !ProcessResult {
    if (hasSkipComment(source)) {
        return .{
            .new_text = source,
            .new_block = source,
            .block_end = 0,
            .changed = false,
            .banned = false,
            .banned_msg = null,
            .stray_count = 0,
        };
    }

    const block_end = findImportBlockEnd(source);
    var imports = try collectImports(allocator, source, block_end);
    defer imports.deinit(allocator);

    const banned_msg = hasBannedPatterns(allocator, source, banned_prefixes);

    if (imports.items.len == 0) {
        return .{
            .new_text = source,
            .new_block = source,
            .block_end = block_end,
            .changed = false,
            .banned = banned_msg != null,
            .banned_msg = banned_msg,
            .stray_count = 0,
        };
    }

    var stray_imports = std.ArrayListUnmanaged(Import).empty;
    defer stray_imports.deinit(allocator);
    for (imports.items) |imp| {
        if (imp.stray) {
            try stray_imports.append(allocator, imp);
        }
    }

    var rest = source[block_end..];
    var rest_owned: ?[]const u8 = null;
    if (stray_imports.items.len > 0) {
        std.sort.pdq(Import, stray_imports.items, {}, struct {
            fn lt(_: void, a: Import, b: Import) bool {
                return a.start < b.start;
            }
        }.lt);
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        var pos: usize = block_end;
        for (stray_imports.items) |imp| {
            const raw_start = if (imp.comment_start) |cs| cs else imp.start;
            const removal_start = @max(raw_start, pos);
            if (imp.end <= pos) continue;
            try buf.appendSlice(allocator, source[pos..removal_start]);
            pos = imp.end;
        }
        try buf.appendSlice(allocator, source[pos..]);
        const owned = try buf.toOwnedSlice(allocator);
        rest_owned = owned;
        rest = owned;
    }

    const new_imports = try buildSortedImportText(allocator, source, imports.items, block_end);

    const original_block = source[0..block_end];
    const changed = !std.mem.eql(u8, original_block, new_imports) or stray_imports.items.len > 0;

    const full_new = try std.mem.concat(allocator, u8, &.{ new_imports, rest });
    if (rest_owned) |owned| allocator.free(owned);

    return .{
        .new_text = full_new,
        .new_block = new_imports,
        .block_end = block_end,
        .changed = changed,
        .banned = banned_msg != null,
        .banned_msg = banned_msg,
        .stray_count = stray_imports.items.len,
    };
}

pub const CliMode = enum { check, fix };

pub const Args = struct {
    mode: CliMode,
    target: []const u8,
    banned_prefixes: std.ArrayListUnmanaged([]const u8),

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.banned_prefixes.deinit(allocator);
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Args {
    if (args.len < 3) return error.Usage;

    const mode: CliMode = if (std.mem.eql(u8, args[1], "fix"))
        .fix
    else if (std.mem.eql(u8, args[1], "check"))
        .check
    else
        return error.InvalidMode;

    var banned_prefixes: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer banned_prefixes.deinit(allocator);

    var target: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ban-prefix")) {
            if (i + 1 >= args.len) return error.MissingBanValue;
            i += 1;
            try banned_prefixes.append(allocator, args[i]);
        } else if (target == null) {
            target = args[i];
        } else {
            return error.UnexpectedArg;
        }
    }

    if (target == null) return error.Usage;

    return .{
        .mode = mode,
        .target = target.?,
        .banned_prefixes = banned_prefixes,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    var parsed = parseArgs(allocator, args) catch |err| switch (err) {
        error.Usage => {
            std.debug.print("Usage: zsort [check|fix] <dir|file> [--ban-prefix <prefix>]...\n", .{});
            std.process.exit(1);
        },
        error.InvalidMode => {
            std.debug.print("Invalid mode. Use 'check' or 'fix'.\n", .{});
            std.process.exit(1);
        },
        error.MissingBanValue => {
            std.debug.print("Missing value for --ban-prefix\n", .{});
            std.process.exit(1);
        },
        error.UnexpectedArg => {
            std.debug.print("Unexpected argument\n", .{});
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer parsed.deinit(allocator);

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    const stat = std.fs.cwd().statFile(parsed.target) catch |err| {
        std.debug.print("Cannot access '{s}': {s}\n", .{ parsed.target, @errorName(err) });
        std.process.exit(1);
    };

    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(parsed.target, .{ .iterate = true });
        defer dir.close();
        try walkDir(allocator, dir, parsed.target, &files);
    } else if (stat.kind == .file) {
        try files.append(allocator, parsed.target);
    } else {
        std.debug.print("'{s}' is not a supported file or directory\n", .{parsed.target});
        std.process.exit(1);
    }

    if (files.items.len == 0) {
        std.debug.print("No .zig files found in '{s}'\n", .{parsed.target});
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

        const result = processSource(fa, source, parsed.banned_prefixes.items) catch |err| {
            std.debug.print("Error processing {s}: {s}\n", .{ file_path, @errorName(err) });
            error_count += 1;
            continue;
        };

        if (result.banned_msg) |msg| {
            std.debug.print("{s}: banned: {s}\n", .{ file_path, msg });
            banned_count += 1;
        }

        if (!result.changed) continue;

        changed_count += 1;

        if (parsed.mode == .fix) {
            var af_buf: [4096]u8 = undefined;
            var af = std.fs.cwd().atomicFile(file_path, .{ .write_buffer = &af_buf }) catch |err| {
                std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
            defer af.deinit();
            af.file_writer.interface.writeAll(result.new_text) catch |err| {
                std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
            af.finish() catch |err| {
                std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
            std.debug.print("Fixed: {s}\n", .{file_path});
        } else {
            if (result.stray_count > 0) {
                showDiff(file_path, source, result.new_text);
            } else {
                showDiff(file_path, source[0..result.block_end], result.new_block);
            }
        }
    }

    if (parsed.mode == .check) {
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
