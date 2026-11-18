//! Runs developer `migration.sql` under a SQLite authorizer
//! (specs/implementation/schema-migrations.md#developer-sql-contract).
//!
//! The file may only read data and write the step's managed tables, its prev
//! tables, and `_zync_namespaces` (insert only). Because DDL is rejected, the
//! schema cannot change mid-file, so every statement can be prepared up front:
//! the pre-pass reports all violations and unresolved `zync_todo` markers
//! before anything runs.

const std = @import("std");

const sqlite = @import("sqlite");

const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const c = sqlite.c;

pub const namespaces_table = "_zync_namespaces";

pub const Access = struct {
    /// Managed tables of the step's target schema.
    writable: []const []const u8,
    /// `_zync_prev_<table>` tables of the step.
    prev: []const []const u8,
};

const Mode = enum {
    /// Record violations but allow preparation to continue.
    check,
    /// Deny violations (defense in depth after a clean pre-pass).
    enforce,
};

const Guard = struct {
    arena: Allocator,
    access: Access,
    mode: Mode,
    /// Violations of the statement currently being prepared.
    violations: std.ArrayListUnmanaged([]const u8) = .empty,
    todo: bool = false,
    /// Tables written by the file (case as declared in `access`).
    written: std.ArrayListUnmanaged([]const u8) = .empty,
    out_of_memory: bool = false,

    fn reset(self: *Guard) void {
        self.violations.clearRetainingCapacity();
        self.todo = false;
    }

    fn violation(self: *Guard, comptime fmt: []const u8, args: anytype) c_int {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch |err| {
            self.noteOutOfMemory(err);
            return c.SQLITE_DENY;
        };
        self.violations.append(self.arena, message) catch |err| self.noteOutOfMemory(err);
        return if (self.mode == .check) c.SQLITE_OK else c.SQLITE_DENY;
    }

    fn noteWrite(self: *Guard, table: []const u8) void {
        for (self.written.items) |name| {
            if (std.ascii.eqlIgnoreCase(name, table)) return;
        }
        const canonical_name = findName(self.access.writable, table) orelse findName(self.access.prev, table) orelse return;
        self.written.append(self.arena, canonical_name) catch |err| self.noteOutOfMemory(err);
    }

    /// Authorizer callbacks cannot return errors; the flag fails the run afterwards.
    fn noteOutOfMemory(self: *Guard, err: anyerror) void {
        std.log.err("migration authorizer: {}", .{err});
        self.out_of_memory = true;
    }
};

fn findName(names: []const []const u8, table: []const u8) ?[]const u8 {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, table)) return name;
    }
    return null;
}

fn span(ptr: [*c]const u8) []const u8 {
    return if (ptr != null) std.mem.span(ptr) else "";
}

fn authorize(
    user: ?*anyopaque,
    action: c_int,
    arg1: [*c]const u8,
    arg2: [*c]const u8,
    db_name: [*c]const u8,
    trigger: [*c]const u8,
) callconv(.c) c_int {
    _ = db_name;
    _ = trigger;
    const guard: *Guard = @ptrCast(@alignCast(user));
    switch (action) {
        c.SQLITE_SELECT, c.SQLITE_READ, c.SQLITE_RECURSIVE => return c.SQLITE_OK,
        c.SQLITE_FUNCTION => {
            const name = span(arg2);
            if (std.ascii.eqlIgnoreCase(name, "zync_todo")) {
                guard.todo = true;
                return if (guard.mode == .check) c.SQLITE_OK else c.SQLITE_DENY;
            }
            if (std.ascii.eqlIgnoreCase(name, "load_extension")) {
                return guard.violation("load_extension() is not allowed", .{});
            }
            return c.SQLITE_OK;
        },
        c.SQLITE_INSERT, c.SQLITE_UPDATE, c.SQLITE_DELETE => {
            const table = span(arg1);
            // Internal catalog writes accompany DDL, which is reported by its own action.
            if (std.ascii.startsWithIgnoreCase(table, "sqlite_")) {
                return if (guard.mode == .check) c.SQLITE_OK else c.SQLITE_DENY;
            }
            const writable = findName(guard.access.writable, table) != null or findName(guard.access.prev, table) != null;
            const namespace_insert = action == c.SQLITE_INSERT and std.ascii.eqlIgnoreCase(table, namespaces_table);
            if (writable) {
                guard.noteWrite(table);
                return c.SQLITE_OK;
            }
            if (namespace_insert) return c.SQLITE_OK;
            const verb = switch (action) {
                c.SQLITE_INSERT => "insert into",
                c.SQLITE_UPDATE => "update",
                else => "delete from",
            };
            return guard.violation("cannot {s} \"{s}\": migrations may only write the schema's tables and their _zync_prev_ copies", .{ verb, table });
        },
        c.SQLITE_PRAGMA => return guard.violation("PRAGMA {s} is not allowed", .{span(arg1)}),
        c.SQLITE_TRANSACTION, c.SQLITE_SAVEPOINT => return guard.violation("transaction control is not allowed; ZyncBase runs the migration in its own transaction", .{}),
        c.SQLITE_ATTACH, c.SQLITE_DETACH => return guard.violation("ATTACH and DETACH are not allowed", .{}),
        else => return guard.violation("{s} is not allowed; ZyncBase generates all DDL from schema.json", .{actionName(action)}),
    }
}

fn actionName(action: c_int) []const u8 {
    return switch (action) {
        c.SQLITE_CREATE_INDEX, c.SQLITE_CREATE_TEMP_INDEX => "CREATE INDEX",
        c.SQLITE_CREATE_TABLE, c.SQLITE_CREATE_TEMP_TABLE => "CREATE TABLE",
        c.SQLITE_CREATE_TRIGGER, c.SQLITE_CREATE_TEMP_TRIGGER => "CREATE TRIGGER",
        c.SQLITE_CREATE_VIEW, c.SQLITE_CREATE_TEMP_VIEW => "CREATE VIEW",
        c.SQLITE_DROP_INDEX, c.SQLITE_DROP_TEMP_INDEX => "DROP INDEX",
        c.SQLITE_DROP_TABLE, c.SQLITE_DROP_TEMP_TABLE => "DROP TABLE",
        c.SQLITE_DROP_TRIGGER, c.SQLITE_DROP_TEMP_TRIGGER => "DROP TRIGGER",
        c.SQLITE_DROP_VIEW, c.SQLITE_DROP_TEMP_VIEW => "DROP VIEW",
        c.SQLITE_ALTER_TABLE => "ALTER TABLE",
        c.SQLITE_REINDEX => "REINDEX",
        c.SQLITE_ANALYZE => "ANALYZE",
        c.SQLITE_CREATE_VTABLE, c.SQLITE_DROP_VTABLE => "virtual table DDL",
        else => "this statement",
    };
}

pub const Source = struct {
    /// Shown in diagnostics, e.g. the migration folder name.
    label: []const u8,
    /// File name shown in diagnostics.
    file: []const u8 = "migration.sql",
    sql: []const u8,
};

const Statement = struct {
    /// Offset of the statement's first token in the file.
    start: usize,
    end: usize,
    stmt: *c.sqlite3_stmt,
};

/// Prepares every statement without running it. Returns the written tables,
/// or `error.MigrationSqlRejected` with every problem in `diag`.
pub fn check(arena: Allocator, db: *sqlite.Db, source: Source, access: Access, diag: *Diagnostics) ![]const []const u8 {
    var guard = Guard{ .arena = arena, .access = access, .mode = .check };
    _ = c.sqlite3_set_authorizer(db.db, authorize, &guard);
    defer _ = c.sqlite3_set_authorizer(db.db, null, null);

    var problems: usize = 0;
    var offset: usize = 0;
    while (true) {
        guard.reset();
        const next = prepareNext(db, source.sql, offset) catch {
            diag.add("{s}, {s} line {d}: {s}", .{ source.label, source.file, lineOf(source.sql, firstToken(source.sql, offset)), std.mem.span(c.sqlite3_errmsg(db.db)) });
            return error.MigrationSqlRejected;
        } orelse break;
        _ = c.sqlite3_finalize(next.stmt);
        offset = next.end;

        const line = lineOf(source.sql, next.start);
        for (guard.violations.items) |message| {
            diag.add("{s}, {s} line {d}: {s}", .{ source.label, source.file, line, message });
            problems += 1;
        }
        if (guard.todo) {
            problems += try reportTodos(arena, source, next.start, next.end, diag);
        }
    }
    if (guard.out_of_memory) return error.OutOfMemory;
    if (problems > 0) {
        diag.add("{s}: {d} problem(s) must be fixed before it can run.", .{ source.label, problems });
        return error.MigrationSqlRejected;
    }
    return guard.written.toOwnedSlice(arena);
}

/// Pre-checks, then runs every statement in order. Returns the written tables.
pub fn execute(arena: Allocator, db: *sqlite.Db, source: Source, access: Access, diag: *Diagnostics) ![]const []const u8 {
    const written = try check(arena, db, source, access, diag);

    var guard = Guard{ .arena = arena, .access = access, .mode = .enforce };
    _ = c.sqlite3_set_authorizer(db.db, authorize, &guard);
    defer _ = c.sqlite3_set_authorizer(db.db, null, null);

    var offset: usize = 0;
    while (true) {
        guard.reset();
        const next = prepareNext(db, source.sql, offset) catch {
            reportFailure(db, source, firstToken(source.sql, offset), diag);
            return error.MigrationSqlFailed;
        } orelse break;
        defer _ = c.sqlite3_finalize(next.stmt);
        offset = next.end;

        while (true) {
            const rc = c.sqlite3_step(next.stmt);
            if (rc == c.SQLITE_ROW) continue;
            if (rc == c.SQLITE_DONE) break;
            reportFailure(db, source, next.start, diag);
            return error.MigrationSqlFailed;
        }
    }
    return written;
}

fn reportFailure(db: *sqlite.Db, source: Source, offset: usize, diag: *Diagnostics) void {
    diag.add("{s}, {s} line {d}: {s}", .{ source.label, source.file, lineOf(source.sql, offset), std.mem.span(c.sqlite3_errmsg(db.db)) });
}

/// Prepares the statement starting at `offset`. Null when only whitespace
/// and comments remain.
fn prepareNext(db: *sqlite.Db, sql: []const u8, offset: usize) !?Statement {
    var current = offset;
    while (current < sql.len) {
        const start = firstToken(sql, current);
        if (start >= sql.len) return null;
        const remaining = sql[current..];
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        const rc = c.sqlite3_prepare_v2(db.db, remaining.ptr, @intCast(remaining.len), &stmt, &tail);
        if (rc != c.SQLITE_OK) return error.PrepareFailed;
        const consumed = @intFromPtr(tail) - @intFromPtr(remaining.ptr);
        const end = current + consumed;
        if (stmt) |s| return .{ .start = start, .end = end, .stmt = s };
        // A lone `;` or comment: keep scanning.
        if (end == current) return null;
        current = end;
    }
    return null;
}

/// Skips whitespace and SQL comments.
fn firstToken(sql: []const u8, offset: usize) usize {
    var i = offset;
    while (i < sql.len) {
        if (std.ascii.isWhitespace(sql[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, sql[i..], "--")) {
            i = std.mem.indexOfScalarPos(u8, sql, i, '\n') orelse sql.len;
        } else if (std.mem.startsWith(u8, sql[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, sql, i + 2, "*/")) |close| close + 2 else sql.len;
        } else {
            break;
        }
    }
    return i;
}

fn lineOf(sql: []const u8, offset: usize) usize {
    return std.mem.count(u8, sql[0..@min(offset, sql.len)], "\n") + 1;
}

/// Reports each `zync_todo(...)` call in `sql[start..end]`, skipping strings
/// and comments. Returns how many were found.
fn reportTodos(arena: Allocator, source: Source, start: usize, end: usize, diag: *Diagnostics) !usize {
    const sql = source.sql;
    var found: usize = 0;
    var i = start;
    while (i < end) {
        const ch = sql[i];
        if (ch == '\'' or ch == '"') {
            i = skipQuoted(sql, i, end, ch);
        } else if (std.mem.startsWith(u8, sql[i..end], "--") or std.mem.startsWith(u8, sql[i..end], "/*")) {
            i = firstToken(sql, i);
        } else if (isIdentifierStart(ch) and (i == 0 or !isIdentifierChar(sql[i - 1]))) {
            var j = i;
            while (j < end and isIdentifierChar(sql[j])) j += 1;
            if (std.ascii.eqlIgnoreCase(sql[i..j], "zync_todo")) {
                var k = j;
                while (k < end and std.ascii.isWhitespace(sql[k])) k += 1;
                if (k < end and sql[k] == '(') {
                    const message = try todoMessage(arena, sql, k + 1, end);
                    diag.add("{s}, {s} line {d}: unresolved decision: {s}", .{ source.label, source.file, lineOf(sql, i), message });
                    found += 1;
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    if (found == 0) {
        // The authorizer saw a call the text scan could not attribute.
        diag.add("{s}, {s} line {d}: unresolved decision: zync_todo(...)", .{ source.label, source.file, lineOf(sql, start) });
        found = 1;
    }
    return found;
}

fn todoMessage(arena: Allocator, sql: []const u8, open: usize, end: usize) ![]const u8 {
    var i = open;
    while (i < end and std.ascii.isWhitespace(sql[i])) i += 1;
    if (i >= end or sql[i] != '\'') return "(see zync_todo call)";
    var out = std.ArrayListUnmanaged(u8).empty;
    i += 1;
    while (i < end) : (i += 1) {
        if (sql[i] == '\'') {
            if (i + 1 < end and sql[i + 1] == '\'') {
                try out.append(arena, '\'');
                i += 1;
                continue;
            }
            break;
        }
        try out.append(arena, sql[i]);
    }
    return out.toOwnedSlice(arena);
}

fn skipQuoted(sql: []const u8, start: usize, end: usize, quote: u8) usize {
    var i = start + 1;
    while (i < end) : (i += 1) {
        if (sql[i] == quote) {
            if (i + 1 < end and sql[i + 1] == quote) {
                i += 1;
                continue;
            }
            return i + 1;
        }
    }
    return end;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}
