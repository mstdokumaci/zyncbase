const std = @import("std");

/// Skips a JSON string starting at `json[*pos]` (the opening `"`). Advances
/// `pos` past the closing `"`. Returns null on malformed input.
pub fn skipString(json: []const u8, pos: *usize) ?void {
    if (pos.* >= json.len or json[pos.*] != '"') return null;
    pos.* += 1;
    while (pos.* < json.len and json[pos.*] != '"') {
        if (json[pos.*] == '\\') pos.* += 1;
        pos.* += 1;
    }
    if (pos.* >= json.len) return null;
    pos.* += 1;
}

/// Skips a balanced bracket-delimited JSON value (`{...}` or `[...]`) starting
/// at `json[*pos]` (the opening bracket). Advances `pos` past the closing
/// bracket. Strings inside are skipped over so brackets within strings do not
/// affect depth counting. Returns null on malformed/unbalanced input.
pub fn skipBalanced(json: []const u8, pos: *usize, open: u8, close: u8) ?void {
    if (pos.* >= json.len or json[pos.*] != open) return null;
    var depth: usize = 1;
    pos.* += 1;
    while (pos.* < json.len and depth > 0) {
        const c = json[pos.*];
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
        } else if (c == '"') {
            skipString(json, pos) orelse return null;
            continue;
        }
        pos.* += 1;
    }
    if (depth != 0) return null;
}

/// Skips a JSON literal keyword (`true`, `false`, `null`) starting at
/// `json[*pos]`. Returns null if the bytes do not match `literal`.
pub fn skipLiteral(json: []const u8, pos: *usize, literal: []const u8) ?void {
    if (pos.* + literal.len > json.len) return null;
    if (!std.mem.eql(u8, json[pos.*..][0..literal.len], literal)) return null;
    pos.* += literal.len;
}

/// Skips a JSON number starting at `json[*pos]`. Consumes digits, `-`, `+`,
/// `.`, `e`, `E`. Returns null if no number is present.
pub fn skipNumber(json: []const u8, pos: *usize) ?void {
    if (pos.* >= json.len) return null;
    const c = json[pos.*];
    if (c != '-' and (c < '0' or c > '9')) return null;
    const start = pos.*;
    var has_digit = false;
    while (pos.* < json.len) {
        const ch = json[pos.*];
        if (ch >= '0' and ch <= '9') {
            has_digit = true;
            pos.* += 1;
        } else if (ch == '.' or ch == '-' or ch == '+' or ch == 'e' or ch == 'E') {
            pos.* += 1;
        } else {
            break;
        }
    }
    if (!has_digit) {
        pos.* = start;
        return null;
    }
}

/// Skips an arbitrary JSON value at `json[*pos]`, advancing `pos` past it.
/// Returns null on malformed input. Recognizes objects, arrays, strings,
/// numbers, and the literals `true`, `false`, `null`.
pub fn skipValue(json: []const u8, pos: *usize) ?void {
    if (pos.* >= json.len) return null;
    switch (json[pos.*]) {
        '"' => return skipString(json, pos),
        '{' => return skipBalanced(json, pos, '{', '}'),
        '[' => return skipBalanced(json, pos, '[', ']'),
        't' => return skipLiteral(json, pos, "true"),
        'f' => return skipLiteral(json, pos, "false"),
        'n' => return skipLiteral(json, pos, "null"),
        '-', '0'...'9' => return skipNumber(json, pos),
        else => return null,
    }
}
