// zlint-disable no-print

const std = @import("std");

const CLASS_STD_BUILTIN: u2 = 0;
const CLASS_VENDOR: u2 = 1;
const CLASS_LOCAL: u2 = 2;

const Import = struct {
    start: usize,
    end: usize,
    path: []const u8,
    class: u2,

    fn lessThan(ctx: void, a: Import, b: Import) bool {
        _ = ctx;
        if (a.class != b.class) return a.class < b.class;
        const cmp = std.mem.order(u8, a.path, b.path);
        if (cmp != .eq) return cmp == .lt;
        return (a.end - a.start) < (b.end - b.start);
    }
};

fn classify(path: []const u8) u2 {
    if (std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin")) {
        return CLASS_STD_BUILTIN;
    }
    if (std.mem.eql(u8, path, "sqlite") or
        std.mem.eql(u8, path, "msgpack") or
        std.mem.eql(u8, path, "httpx"))
    {
        return CLASS_VENDOR;
    }
    return CLASS_LOCAL;
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

fn findCImportEnd(source: []const u8, pos: usize) usize {
    var i = pos;
    var depth: usize = 0;
    var started = false;
    while (i < source.len) : (i += 1) {
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

fn extractPath(source: []const u8, needle: []const u8) ?[]const u8 {
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

fn isTopLevelImportLine(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
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
        const rhs = trimmed[eq + 1 ..];
        return std.mem.indexOfScalar(u8, rhs, '.') != null;
    }

    if (std.mem.startsWith(u8, trimmed, "_ = @import")) return true;

    return false;
}

fn findImportBlockEnd(source: []const u8) usize {
    var pos: usize = 0;
    while (pos < source.len) {
        const line_end = findLineEnd(source, pos);
        const line = source[pos..line_end];
        if (!isTopLevelImportLine(line)) return pos;
        pos = line_end;
    }
    return pos;
}

fn hasBannedPatterns(source: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, "@import(")) |found| {
        const line_start = findLineStart(source, found);
        const line_end_excl = findLineEnd(source, found);
        const line = std.mem.trimLeft(u8, source[line_start..line_end_excl], " \t\r");

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

    if (std.mem.indexOf(u8, source, "usingnamespace") != null) {
        return "usingnamespace detected";
    }

    return null;
}

fn collectImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    block_end: usize,
) !std.ArrayListUnmanaged(Import) {
    var imports: std.ArrayListUnmanaged(Import) = .empty;
    errdefer imports.deinit(allocator);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, "@import(")) |found| {
        if (found >= block_end) break;
        const line_start = findLineStart(source, found);
        const line_end = findLineEnd(source, found);
        const path = extractPath(source[found..], "@import(") orelse {
            pos = line_end;
            continue;
        };
        try imports.append(allocator, .{
            .start = line_start,
            .end = line_end,
            .path = path,
            .class = classify(path),
        });
        pos = line_end;
    }

    pos = 0;
    while (std.mem.indexOfPos(u8, source, pos, "@cImport(")) |found| {
        if (found >= block_end) break;
        const line_start = findLineStart(source, found);
        const block_end_cimport = findCImportEnd(source, found);
        try imports.append(allocator, .{
            .start = line_start,
            .end = block_end_cimport,
            .path = "<cimport>",
            .class = CLASS_VENDOR,
        });
        pos = block_end_cimport;
    }

    std.sort.pdq(Import, imports.items, {}, Import.lessThan);
    return imports;
}

fn buildSortedImportText(
    allocator: std.mem.Allocator,
    source: []const u8,
    sorted_imports: []const Import,
    block_end: usize,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var prev_class: ?u2 = null;
    for (sorted_imports) |imp| {
        if (prev_class != null and prev_class.? != imp.class) {
            try buf.append(allocator, '\n');
        }
        prev_class = imp.class;
        const text = source[imp.start..imp.end];
        const trimmed = std.mem.trimRight(u8, text, " \t\n\r");
        if (trimmed.len > 0) {
            try buf.appendSlice(allocator, trimmed);
            try buf.append(allocator, '\n');
        }
    }

    var derived_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer derived_lines.deinit(allocator);

    var pos: usize = 0;
    while (pos < block_end) {
        const le = findLineEnd(source, pos);
        const line = source[pos..le];
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
            pos = le;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "pub const ")) {
            if (std.mem.indexOf(u8, trimmed, "@import(") == null and
                std.mem.indexOf(u8, trimmed, "@cImport(") == null)
            {
                try derived_lines.append(allocator, line);
            }
        }
        pos = le;
    }

    if (derived_lines.items.len > 0) {
        try buf.append(allocator, '\n');
        for (derived_lines.items) |line| {
            try buf.appendSlice(allocator, line);
        }
    }

    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '\n') {
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("Usage: zimport_sort [check|fix] <dir|file>\n", .{});
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
    }

    if (files.items.len == 0) return;

    var changed_count: usize = 0;
    var error_count: usize = 0;
    var banned_count: usize = 0;

    for (files.items) |file_path| {
        const source = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Error reading {s}: {s}\n", .{ file_path, @errorName(err) });
            error_count += 1;
            continue;
        };

        const block_end = findImportBlockEnd(source);
        var result = try collectImports(allocator, source, block_end);
        defer result.deinit(allocator);

        if (result.items.len == 0) continue;

        if (hasBannedPatterns(source)) |msg| {
            std.debug.print("{s}: banned: {s}\n", .{ file_path, msg });
            banned_count += 1;
        }

        const new_imports = buildSortedImportText(allocator, source, result.items, block_end) catch |err| {
            std.debug.print("Error building sorted imports for {s}: {s}\n", .{ file_path, @errorName(err) });
            error_count += 1;
            continue;
        };
        defer allocator.free(new_imports);

        const original_block = source[0..block_end];
        if (std.mem.eql(u8, original_block, new_imports)) continue;

        changed_count += 1;

        if (mode == .fix) {
            const full_new = std.mem.concat(allocator, u8, &.{ new_imports, source[block_end..] }) catch |err| {
                std.debug.print("Error allocating for {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
            defer allocator.free(full_new);

            const file = std.fs.cwd().createFile(file_path, .{ .truncate = true }) catch |err| {
                std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
            defer file.close();
            file.writeAll(full_new) catch |err| {
                std.debug.print("Error writing {s}: {s}\n", .{ file_path, @errorName(err) });
                error_count += 1;
                continue;
            };
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
        stdout_w2.interface.print("\nFixed {} files, {} errors\n", .{ changed_count, error_count }) catch {};
        if (changed_count > 0) std.process.exit(1);
    }
}
