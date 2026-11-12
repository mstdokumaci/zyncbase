#!/usr/bin/env node
"use strict";
const fs = require("fs"), path = require("path");
const rootIdx = process.argv.indexOf("--root");
const SRC = path.resolve(rootIdx !== -1 && process.argv[rootIdx + 1]
    ? process.argv[rootIdx + 1]
    : path.join(__dirname, "..", "src"));
const EXTERNAL = new Set(["std", "builtin", "sqlite", "msgpack", "httpx"]);
const INCLUDE_TESTS = process.argv.includes("--include-tests");
// Boundary-aware test-path classification on canonical paths ("src/foo_test.zig"):
// *_test.zig suffix, test_all.zig, *test_helper(s).zig, *test_runner.zig.
// Does NOT match ordinary production names such as "latest.zig".
const TEST_RE = /(?:^|\/)(?:[^/]+_test\.zig|test_all\.zig|(?:[^/]+[-_])?test[-_](?:helper|runner)[^/]*\.zig)$/;

if (process.argv.includes("--selftest")) {
    const cases = [
        ["src/logging_test.zig", true],
        ["src/test_all.zig", true],
        ["src/app_test_helpers.zig", true],
        ["src/schema/test_helpers.zig", true],
        ["src/timed_test_runner.zig", true],
        ["src/latest.zig", false],
        ["src/contest_helpers.zig", false],
        ["src/latest_runner.zig", false],
        ["src/main.zig", false],
        ["src/server.zig", false],
    ];
    for (const [p, expected] of cases) {
        const actual = TEST_RE.test(p);
        if (actual !== expected) {
            console.error(`FAIL: TEST_RE("${p}") = ${actual}, expected ${expected}`);
            process.exit(1);
        }
    }

    // End-to-end fixture: exercises generic receivers, duck typing,
    // method scope tracking, enum(u8), and test-only references.
    const os = require("os");
    const assert = require("assert");
    const { execFileSync } = require("child_process");
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "unused-pub-"));
    const src = path.join(tmp, "src");
    fs.mkdirSync(src, {recursive: true});
    const write = (name, body) => fs.writeFileSync(path.join(src, name), body);

    write("queue.zig", `pub fn mpscQueue(comptime T: type) type {
    return struct {
        pub fn push(self: @This(), item: T) !void {
            _ = self;
            _ = item.owner();
        }

        pub fn pop(self: @This()) ?T {
            _ = self;
            return null;
        }
    };
}
`);
    write("send_queue.zig", `const mpscQueue = @import("queue.zig").mpscQueue;

pub const Entry = struct {
    id: u32,

    pub fn owner(self: Entry) u32 {
        _ = self;
        return 0;
    }

    pub fn unusedAfterOwner(self: Entry) u32 {
        _ = self;
        return 1;
    }
};

pub const send_queue = mpscQueue(Entry);
`);
    write("types.zig", `pub const FieldType = enum {
    text,

    pub fn toSqlType(self: FieldType) []const u8 {
        _ = self;
        return "TEXT";
    }

    pub fn unusedAfterToSql(self: FieldType) []const u8 {
        _ = self;
        return "TEXT";
    }
};

pub const Backed = enum(u8) {
    a,

    pub fn unusedBacked(self: Backed) u8 {
        _ = self;
        return 0;
    }
};

pub const A = struct {
    pub fn reset(self: A) void {
        _ = self;
    }
};

pub const test_only_const: u8 = 1;

pub fn callbackHandler() void {}

pub fn inlineOnly() void {}

pub fn deadTopLevel() void {}
`);
    write("ddl.zig", `const types = @import("types.zig");

const cb = types.callbackHandler;

const B = struct {
    fn reset(self: B) void {
        _ = self;
    }
};

fn callB(b: B) void {
    b.reset();
}

fn useA(a: types.A) void {
    _ = a;
}

fn sqlType(field: anytype) []const u8 {
    return field.toSqlType();
}
`);
    write("inline_use.zig", `_ = @import("types.zig");

fn callInline() void {
    @import("types.zig").inlineOnly();
}
`);
    write("missing_import.zig", `pub const missing = @import("missing.zig").missing;
`);
    write("user.zig", `const send_queue = @import("send_queue.zig").send_queue;
const types = @import("types.zig");

fn useQueue(q: *send_queue) void {
    q.push(.{ .id = 1 }) catch {};
    _ = q.pop();
}

fn useEnum(value: types.Backed) u8 {
    _ = value;
    return 0;
}
`);
    write("only_tests_test.zig", `const types = @import("types.zig");

test "test-only const" {
    _ = types.test_only_const;
}
`);

    let out = "";
    let crashed = false;
    try {
        out = execFileSync(process.execPath, [__filename, "--root", src], {encoding: "utf8"});
    } catch (e) {
        crashed = true;
        console.error("FAIL: fixture detector crashed");
        console.error(String(e.stdout || ""));
        console.error(String(e.stderr || ""));
    } finally {
        fs.rmSync(tmp, {recursive: true, force: true});
    }
    if (crashed) process.exit(1);

    const section = (prefix) => {
        const found = [];
        let current = "";
        for (const line of out.split("\n")) {
            if (/^[A-Z][A-Z0-9 /-]+ \(\d+\)$/.test(line)) { current = line; continue; }
            if (/^=+$/.test(line)) { current = ""; continue; }
            if (current.startsWith(prefix) && line.trim()) found.push(line);
        }
        return found;
    };
    const noRef = section("NO REFERENCE FOUND");
    const possible = section("POSSIBLY USED - WEAK NAME MATCH");
    const testOnly = section("ONLY REFERENCED FROM TESTS");

    assert.ok(noRef.some(l => l.includes("deadTopLevel")), "deadTopLevel should be no-ref");
    assert.ok(noRef.some(l => l.includes("unusedAfterToSql") && l.includes("parent=FieldType")), "unusedAfterToSql should keep FieldType parent");
    assert.ok(noRef.some(l => l.includes("unusedBacked") && l.includes("parent=Backed")), "enum(u8) method should keep Backed parent");
    assert.ok(noRef.some(l => l.includes("unusedAfterOwner") && l.includes("parent=Entry")), "method after method should keep Entry parent");
    assert.ok(!noRef.some(l => l.includes("toSqlType")), "toSqlType should not be no-ref");
    assert.ok(possible.some(l => l.includes("toSqlType") && l.includes("types.zig")), "toSqlType should be weak evidence from an unqualified call");
    assert.ok(!noRef.some(l => l.includes("callbackHandler")), "callbackHandler should be used via a function pointer");
    assert.ok(!possible.some(l => l.includes("callbackHandler")), "callbackHandler should be used via a function pointer");
    assert.ok(!noRef.some(l => l.includes("inlineOnly")), "inlineOnly should be used via an inline import");
    assert.ok(!possible.some(l => l.includes("inlineOnly")), "inlineOnly should be used via an inline import");
    assert.ok(possible.some(l => l.includes(" reset") && l.includes("parent=A")), "A.reset should not be strong-matched by B.reset");
    assert.ok(possible.some(l => l.includes(" owner") && l.includes("send_queue.zig")), "owner should be possibly used");
    assert.ok(possible.some(l => l.includes(" push") && l.includes("queue.zig")), "push should be possibly used");
    assert.ok(possible.some(l => l.includes(" pop") && l.includes("queue.zig")), "pop should be possibly used");
    assert.ok(testOnly.some(l => l.includes("test_only_const")), "test_only_const should be test-only");

    console.log("selftest: path classifications + fixture report OK");
    process.exit(0);
}

function log(m) { process.stderr.write(m + "\n"); }

// ---- COLLECT FILES ----
function canonical(fp) { let r = path.relative(SRC, fp).split(path.sep).join("/"); return "src/" + r; }
const all = [];
(function walk(d) {
    for (const e of fs.readdirSync(d, {withFileTypes:true})) {
        if (e.isDirectory()) { walk(path.join(d, e.name)); continue; }
        if (!e.name.endsWith(".zig")) continue;
        const abs = path.join(d, e.name);
        all.push({ path: canonical(abs), abspath: abs, text: fs.readFileSync(abs, "utf-8") });
    }
})(SRC);

const declFiles = all.filter(f => INCLUDE_TESTS || !TEST_RE.test(f.path));
log(`Files: ${declFiles.length} scanned, ${all.length - declFiles.length} test files skipped`);

// ---- STRIP COMMENTS (preserve strings for imports) ----
// Block comments become spaces rather than disappearing, so line numbers stay valid.
function nocomment(t) {
    return t
        .replace(/\/\/[^\n]*/g, "")
        .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
}

// ---- IMPORT GRAPH ----
const imports = new Map(), bindings = new Map(), reexports = new Map(), aliases = new Map();
for (const f of all) {
    imports.set(f.path, new Set()); bindings.set(f.path, new Map());
    reexports.set(f.path, new Map()); aliases.set(f.path, new Map());
}

const impRe = /const\s+(\w+)\s*=\s*@import\("(.+?)"\)(?:\.(\w+))?\s*;/g;
const anyImportRe = /@import\("([^"]+)"\)/g;

for (const f of all) {
    const lines = nocomment(f.text).split("\n");
    for (let i = 0; i < lines.length; i++) {
        const ln = lines[i];
        if (!ln.includes("@import") && !ln.startsWith("pub const")) continue;

        // Record every local @import, including `_ = @import(...)` and
        // expression-position imports. The const-form loop below only adds
        // bindings/aliases on top of these edges.
        if (ln.includes("@import")) {
            anyImportRe.lastIndex = 0;
            let im;
            while ((im = anyImportRe.exec(ln)) !== null) {
                if (EXTERNAL.has(im[1])) continue;
                const sf = canonical(path.resolve(path.dirname(f.abspath), im[1]));
                if (!imports.has(sf)) continue;
                imports.get(f.path).add(sf);
            }
        }

        impRe.lastIndex = 0;
        let m;
        while ((m = impRe.exec(ln)) !== null) {
            if (EXTERNAL.has(m[2])) continue;
            const sf = canonical(path.resolve(path.dirname(f.abspath), m[2]));
            if (!imports.has(sf)) continue;
            imports.get(f.path).add(sf);
            if (m[3]) {
                bindings.get(f.path).set(m[1], { sf, si: m[3] });
                if (ln.trimStart().startsWith("pub ")) reexports.get(f.path).set(m[1], { sf, si: m[3] });
            } else {
                aliases.get(f.path).set(m[1], sf);
                for (let j = i+1; j < Math.min(i+3, lines.length); j++) {
                    const nl = lines[j].trim();
                    if (!nl || nl.startsWith("//")) continue;
                    if (!nl.startsWith("const ")) break;
                    const am = nl.match(/^const\s+(\w+)\s*=\s*(\w+)\.(\w+)\s*;/);
                    if (am) {
                        const mt = aliases.get(f.path).get(am[2]);
                        if (mt) {
                            bindings.get(f.path).set(am[1], { sf: mt, si: am[3] });
                            if (nl.startsWith("pub ")) reexports.get(f.path).set(am[1], { sf: mt, si: am[3] });
                        }
                        break;
                    }
                    break;
                }
            }
        }
    }
}

// reachableBy (with transitive re-export propagation)
const reachable = new Map();
for (const f of all) reachable.set(f.path, new Set());
for (const f of all) for (const imp of imports.get(f.path)) reachable.get(imp).add(f.path);
let changed = true;
while (changed) {
    changed = false;
    for (const f of all) {
        for (const [,r] of reexports.get(f.path)) {
            for (const imp of reachable.get(f.path)) {
                if (!reachable.get(r.sf).has(imp)) {
                    reachable.get(r.sf).add(imp);
                    changed = true;
                }
            }
        }
    }
}

let ecount = 0; for (const [,s] of imports) ecount += s.size;
log(`Import edges: ${ecount}`);

// ---- PRODUCTION REACHABILITY ----
// A file is production only if main.zig can reach it. Test-only production
// files still get their declarations scanned, but their references count as test.
function forwardReach(start) {
    const seen = new Set([start]), q = [start];
    while (q.length) {
        for (const n of imports.get(q.pop()) || []) {
            if (!seen.has(n)) { seen.add(n); q.push(n); }
        }
    }
    return seen;
}
const hasMain = all.some(f => f.path === "src/main.zig");
const mainReach = hasMain ? forwardReach("src/main.zig") : null;
log(`Reachable from main.zig: ${mainReach ? mainReach.size : "n/a"}`);

// ---- NOSTRINGS (for declaration parsing) ----
// Zig multiline strings are line-prefixed with \\; remove them first so the
// normal string regex cannot swallow code across lines.
function nostrings(t) { return t.replace(/^[ \t]*\\\\.*$/gm, "").replace(/'(?:[^'\\\n]|\\.)*'/g, "''").replace(/"(?:[^"\\\n]|\\.)*"/g, '""'); }

// ---- PUB DECL EXTRACTION ----
const containerRe = /(?:pub\s+)?const\s+(\w+)\s*=\s*(?:packed\s+|extern\s+)?(struct|enum(?:\([^)]*\))?|union(?:\(enum\))?)\s*(\{)/;
const pubRe = /pub\s+(fn|const|var|struct|enum(?:\([^)]*\))?|union(?:\(enum\))?)\s+(\w+)/g;

log("Extracting decls...");
const decls = [];
let dc = 0;
for (const f of declFiles) {
    dc++;
    if (dc % 20 === 0) log(`  ${dc}/${declFiles.length}`);

    const text = nostrings(nocomment(f.text));
    const lines = text.split("\n");
    const scope = [];
    let depth = 0;

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        // Count braces on this line
        let opens = 0, closes = 0;
        for (const c of line) { if (c === "{") opens++; else if (c === "}") closes++; }

        // Pop containers only when their own brace level closes. A function
        // closing inside a struct must not pop the struct.
        const depthBefore = depth;
        depth += opens - closes;
        if (depth < 0) depth = 0;
        while (scope.length > 0 && depth <= scope[scope.length - 1].depth) scope.pop();

        // Container check: detect multi-line struct/enum/union
        const cm = line.trim().match(containerRe);
        const willPushScope = cm && opens > closes;

        // pub declarations at CURRENT scope depth (before pushing new scope)
        pubRe.lastIndex = 0;
        let pm;
        while ((pm = pubRe.exec(line)) !== null) {
            const name = pm[2];
            if (scope.length === 0 && name === "main" && pm[1] === "fn") continue;
            if (scope.length === 0 && name === "std_options") continue;
            if (name === "Self") continue;

            decls.push({
                file: f.path, line: i+1, name, kind: pm[1],
                parent: scope.length > 0 ? scope[scope.length-1].name : null,
                isReexport: line.includes("@import") || reexports.get(f.path).has(name),
            });
        }

        // Push new scope, remembering the depth it belongs to.
        if (willPushScope) scope.push({ kind: cm[2], name: cm[1], depth: depthBefore });
    }
}
log(`  Decls: ${decls.length} (${decls.filter(d=>!d.parent).length} top-level, ${decls.filter(d=>d.parent).length} nested)`);

// ---- MAP file path -> full file obj ----
const fileByPath = new Map(all.map(f => [f.path, f]));
const fileType = new Map(all.map(f => [f.path,
    mainReach ? (mainReach.has(f.path) ? "prod" : "test") : (TEST_RE.test(f.path) ? "test" : "prod")]));

// ---- STRIPPED TEXT CACHE (precomputed per-file, reused for self+ref checks) ----
const strippedCache = new Map();
function getStripped(f) {
    if (!strippedCache.has(f.path)) strippedCache.set(f.path, nostrings(nocomment(f.text)));
    return strippedCache.get(f.path);
}

// ---- METHOD-CALL INDEX ----
// Zig reaches methods through inferred types, generic instantiations, and
// duck typing, so the caller need not name the declaring module or parent.
// Count `.name(` everywhere; it is a weaker signal than a qualified reference.
const methodCalls = new Map();
for (const f of all) {
    const bucket = fileType.get(f.path) === "prod" ? "prod" : "test";
    for (const m of getStripped(f).matchAll(/\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) {
        let entry = methodCalls.get(m[1]);
        if (!entry) { entry = { prod: new Set(), test: new Set() }; methodCalls.set(m[1], entry); }
        entry[bucket].add(f.path);
    }
}
log(`  Method-call names: ${methodCalls.size}`);

// ---- REFERENCE VERIFICATION ----
log("Verifying refs...");
const unused = [], possiblyUsed = [], testOnly = [], reexported = [];

function isIdentChar(c) {
    return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95 || c === 36;
}

function hasWord(text, word) {
    let idx = text.indexOf(word);
    while (idx !== -1) {
        const before = idx > 0 ? text.charCodeAt(idx - 1) : 0;
        const after = idx + word.length < text.length ? text.charCodeAt(idx + word.length) : 0;
        if (!isIdentChar(before) && !isIdentChar(after)) return true;
        idx = text.indexOf(word, idx + word.length);
    }
    return false;
}

function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

function hasMemberAccess(text, name) {
    return new RegExp("\\.\\s*" + escapeRegex(name) + "\\b").test(text);
}

function isBareAt(text, idx, word) {
    const before = idx > 0 ? text.charCodeAt(idx - 1) : 0;
    const after = idx + word.length < text.length ? text.charCodeAt(idx + word.length) : 0;
    return !isIdentChar(before) && !isIdentChar(after) && before !== 46; // 46 = '.'
}

function hasBareWord(text, word) {
    let idx = text.indexOf(word);
    while (idx !== -1) {
        if (isBareAt(text, idx, word)) return true;
        idx = text.indexOf(word, idx + word.length);
    }
    return false;
}

function hasBareWordOutsideLines(text, word, skipLines) {
    let idx = text.indexOf(word);
    while (idx !== -1) {
        if (isBareAt(text, idx, word)) {
            const lineIdx = (text.substring(0, idx).match(/\n/g) || []).length;
            if (!skipLines.includes(lineIdx + 1)) return true;
        }
        idx = text.indexOf(word, idx + word.length);
    }
    return false;
}

function isCallAt(text, idx, word) {
    const before = idx > 0 ? text.charCodeAt(idx - 1) : 0;
    if (isIdentChar(before)) return false;
    let j = idx + word.length;
    while (j < text.length && (text[j] === " " || text[j] === "\t")) j++;
    return text[j] === "(";
}

function hasCall(text, word) {
    let idx = text.indexOf(word);
    while (idx !== -1) {
        if (isCallAt(text, idx, word)) return true;
        idx = text.indexOf(word, idx + word.length);
    }
    return false;
}

function hasCallOutsideLines(text, word, skipLines) {
    let idx = text.indexOf(word);
    while (idx !== -1) {
        if (isCallAt(text, idx, word)) {
            const lineIdx = (text.substring(0, idx).match(/\n/g) || []).length;
            if (!skipLines.includes(lineIdx + 1)) return true;
        }
        idx = text.indexOf(word, idx + word.length);
    }
    return false;
}

function hasMemberAccessOutsideLines(text, name, skipLines) {
    const re = new RegExp("\\.\\s*" + escapeRegex(name) + "\\b", "g");
    let m;
    while ((m = re.exec(text)) !== null) {
        const lineIdx = (text.substring(0, m.index).match(/\n/g) || []).length;
        if (!skipLines.includes(lineIdx + 1)) return true;
    }
    return false;
}

let vc = 0;
for (const d of decls) {
    vc++;
    if (vc % 100 === 0) log(`  ${vc}/${decls.length}`);

    if (d.isReexport) { reexported.push({ decl: d, sites: null }); continue; }

    const legal = new Set([d.file, ...(reachable.get(d.file) || [])]);
    const prodRefs = new Set(), testRefs = new Set();
    const prodWeak = new Set(), testWeak = new Set();
    const selfText = getStripped(fileByPath.get(d.file));

    for (const fp of legal) {
        const f = fileByPath.get(fp);
        if (!f) continue;

        const isSelf = fp === d.file;
        const fText = isSelf ? selfText : getStripped(f);
        const isProd = fileType.get(fp) === "prod";
        const strong = isProd ? prodRefs : testRefs;
        const weak = isProd ? prodWeak : testWeak;

        if (d.kind === "fn") {
            if (d.parent) {
                const qn = d.parent + "." + d.name;
                const strongHit = isSelf
                    ? (hasWordOutsideLines(selfText, qn, [d.line]) || hasCallOutsideLines(selfText, d.name, [d.line]))
                    : hasWord(fText, qn);
                if (strongHit) strong.add(fp);
                const weakHit = isSelf
                    ? (hasMemberAccessOutsideLines(selfText, d.name, [d.line]) ||
                        hasBareWordOutsideLines(selfText, d.name, [d.line]))
                    : hasMemberAccess(fText, d.name);
                if (weakHit) weak.add(fp);
            } else {
                const strongHit = isSelf
                    ? (hasBareWordOutsideLines(selfText, d.name, [d.line]) || hasCallOutsideLines(selfText, d.name, [d.line]))
                    : (hasBareWord(fText, d.name) || hasCall(fText, d.name) || hasMemberAccess(fText, d.name));
                if (strongHit) strong.add(fp);
                if (isSelf && hasMemberAccessOutsideLines(selfText, d.name, [d.line])) weak.add(fp);
            }
        } else if (d.parent) {
            const qn = d.parent + "." + d.name;
            if (isSelf) {
                if (hasWordOutsideLines(selfText, qn, [d.line]) ||
                    (hasWord(selfText, d.parent) && hasWordOutsideLines(selfText, d.name, [d.line]))) strong.add(fp);
            } else if (hasWord(fText, qn) ||
                    (hasWord(fText, d.parent) && hasMemberAccess(fText, d.name))) strong.add(fp);
        } else if (isSelf) {
            if (hasWordOutsideLines(selfText, d.name, [d.line])) strong.add(fp);
        } else if (hasWord(fText, d.name)) {
            strong.add(fp);
        }
    }

    const methodSites = d.kind === "fn" ? methodCalls.get(d.name) : null;
    if (methodSites) {
        for (const fp of methodSites.prod) prodWeak.add(fp);
        for (const fp of methodSites.test) testWeak.add(fp);
    }

    if (prodRefs.size > 0) {
        // directly used in production
    } else if (prodWeak.size > 0) {
        possiblyUsed.push({ decl: d, sites: prodWeak });
    } else if (testRefs.size > 0) {
        testOnly.push({ decl: d, sites: testRefs });
    } else if (testWeak.size > 0) {
        testOnly.push({ decl: d, sites: testWeak });
    } else {
        unused.push({ decl: d, sites: null });
    }
}

function hasWordOutsideLines(text, word, skipLines) {
    let idx = text.indexOf(word);
    while (idx !== -1) {
        const before = idx > 0 ? text.charCodeAt(idx - 1) : 0;
        const after = idx + word.length < text.length ? text.charCodeAt(idx + word.length) : 0;
        if (!isIdentChar(before) && !isIdentChar(after)) {
            const lineIdx = (text.substring(0, idx).match(/\n/g) || []).length;
            if (!skipLines.includes(lineIdx + 1)) return true;
        }
        idx = text.indexOf(word, idx + word.length);
    }
    return false;
}

log(`  Done.`);

// ---- OUTPUT ----
function byDecl(a, b) {
    return a.decl.file.localeCompare(b.decl.file) || a.decl.line - b.decl.line;
}

function refText(set) {
    if (!set || set.size === 0) return "";
    const list = [...set].sort();
    const shown = list.slice(0, 8);
    return ` [${shown.join(", ")}${list.length > 8 ? ` (+${list.length - 8})` : ""}]`;
}

function printFinding(entry, extra = "") {
    const d = entry.decl;
    const parent = d.parent ? ` parent=${d.parent}` : "";
    console.log(`  ${d.file}:${d.line}  pub ${d.kind} ${d.name}${parent}${refText(entry.sites)}${extra}`);
}

console.log("\n" + "=".repeat(80));
console.log("UNUSED-PUB DETECTOR");
console.log("=".repeat(80));

console.log(`\nNO REFERENCE FOUND (${unused.length})\n`);
for (const e of unused.sort(byDecl)) printFinding(e);

console.log(`\nPOSSIBLY USED - WEAK NAME MATCH (${possiblyUsed.length})\n`);
for (const e of possiblyUsed.sort(byDecl)) printFinding(e);

console.log(`\nONLY REFERENCED FROM TESTS (${testOnly.length})\n`);
for (const e of testOnly.sort(byDecl)) printFinding(e);

console.log(`\nRE-EXPORTED (${reexported.length})\n`);
for (const e of reexported.sort(byDecl)) {
    const b = bindings.get(e.decl.file)?.get(e.decl.name);
    printFinding(e, b ? ` → ${b.sf}:${b.si}` : "");
}

if (mainReach) {
    const unreachable = all.filter(f => !TEST_RE.test(f.path) && !mainReach.has(f.path));
    console.log(`\nFILES NOT REACHABLE FROM MAIN.ZIG (${unreachable.length})\n`);
    for (const f of unreachable.sort((a, b) => a.path.localeCompare(b.path))) console.log(`  ${f.path}`);
}

const usedCount = decls.length - unused.length - possiblyUsed.length - testOnly.length - reexported.length;
console.log("\n" + "=".repeat(80));
console.log(`Total: ${decls.length} | Prod-used: ${usedCount} | No-ref: ${unused.length} | Possibly-used: ${possiblyUsed.length} | Test-only: ${testOnly.length} | Re-exports: ${reexported.length}`);
if (unused.length + testOnly.length > 0) {
    const files = new Set([...unused, ...testOnly].map(e => e.decl.file));
    console.log(`Cleanup candidates: ${unused.length + testOnly.length} across ${files.size} files`);
}
if (possiblyUsed.length > 0) {
    console.log(`Review separately: ${possiblyUsed.length} need a call-site check`);
}
console.log("Heuristic: references are text-based; run zig build after any removal.");
