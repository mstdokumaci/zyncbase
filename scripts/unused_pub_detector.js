#!/usr/bin/env node
"use strict";
const fs = require("fs"), path = require("path");
const SRC = path.resolve(__dirname, "..", "src");
const EXTERNAL = new Set(["std","builtin","sqlite","msgpack","httpx"]);
const TEST_RE = /_(?:test|property_test|thread_safety_test|perf_test|leak_test)\.zig$|test_helpers\.zig$|_test_helpers\.zig$|timed_test_runner\.zig$|msgpack_test_helpers\.zig$|checkpoint_test_helpers\.zig$|app_test_helpers\.zig$|store_test_helpers\.zig$|test_all\.zig$/;

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

const prod = all.filter(f => !TEST_RE.test(f.path));
log(`Files: ${prod.length} prod, ${all.length - prod.length} test`);

// ---- STRIP COMMENTS (preserve strings for imports) ----
function nocomment(t) { return t.replace(/\/\/.*$/gm,"").replace(/\/\*[\s\S]*?\*\//g,""); }

// ---- IMPORT GRAPH ----
const imports = new Map(), bindings = new Map(), reexports = new Map(), aliases = new Map();
for (const f of all) {
    imports.set(f.path, new Set()); bindings.set(f.path, new Map());
    reexports.set(f.path, new Map()); aliases.set(f.path, new Map());
}

const impRe = /const\s+(\w+)\s*=\s*@import\("(.+?)"\)(?:\.(\w+))?\s*;/g;

for (const f of all) {
    const lines = nocomment(f.text).split("\n");
    for (let i = 0; i < lines.length; i++) {
        const ln = lines[i];
        if (!ln.includes("@import") && !ln.startsWith("pub const")) continue;
        impRe.lastIndex = 0;
        let m;
        while ((m = impRe.exec(ln)) !== null) {
            if (EXTERNAL.has(m[2])) continue;
            const sf = canonical(path.resolve(path.dirname(f.abspath), m[2]));
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

// ---- NOSTRINGS (for declaration parsing) ----
function nostrings(t) { return t.replace(/'(?:[^'\\]|\\.)*'/g, "''").replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/^\s*\\\\.*$/gm, ""); }

// ---- PUB DECL EXTRACTION ----
const containerRe = /(?:pub\s+)?const\s+(\w+)\s*=\s*(?:packed\s+|extern\s+)?(struct|enum|union(?:\(enum\))?)\s*(\{)/;
const pubRe = /pub\s+(fn|const|var|struct|enum|union(?:\(enum\))?)\s+(\w+)/g;

log("Extracting decls...");
const decls = [];
let dc = 0;
for (const f of prod) {
    dc++;
    if (dc % 20 === 0) log(`  ${dc}/${prod.length}`);

    const text = nostrings(nocomment(f.text));
    const lines = text.split("\n");
    const scope = [];
    let depth = 0;

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        // Count braces on this line
        let opens = 0, closes = 0;
        for (const c of line) { if (c === "{") opens++; else if (c === "}") closes++; }

        // Pop scopes for net closing (more closes than opens)
        const netCloses = closes - opens;
        for (let k = 0; k < netCloses && scope.length > 0; k++) scope.pop();
        depth += opens - closes;
        if (depth < 0) depth = 0;

        // Container check: detect multi-line struct/enum/union
        const cm = line.trim().match(containerRe);
        const isMultiLine = opens > closes;
        const willPushScope = cm && isMultiLine;

        // pub declarations at CURRENT scope depth (before pushing new scope)
        pubRe.lastIndex = 0;
        let pm;
        while ((pm = pubRe.exec(line)) !== null) {
            const name = pm[2];
            if (depth === 0 && name === "main" && pm[1] === "fn") continue;
            if (depth === 0 && name === "std_options") continue;
            if (name === "Self") continue;

            decls.push({
                file: f.path, line: i+1, name, kind: pm[1],
                parent: scope.length > 0 ? scope[scope.length-1].name : null,
                isReexport: line.includes("@import") || reexports.get(f.path).has(name),
            });
        }

        // Now push new scope
        if (willPushScope) scope.push({ kind: cm[2], name: cm[1] });
    }
}
log(`  Decls: ${decls.length} (${decls.filter(d=>!d.parent).length} top-level, ${decls.filter(d=>d.parent).length} nested)`);

// ---- MAP file path -> full file obj ----
const fileByPath = new Map(all.map(f => [f.path, f]));
const fileType = new Map(all.map(f => [f.path, TEST_RE.test(f.path) ? "test" : "prod"]));

// ---- REFERENCE VERIFICATION ----
// Simple approach: for each decl, check files that legally import its source.
// Count self-reference if name appears on a non-declaration line.
log("Verifying refs...");
const unused = [], testOnly = [], reexported = [];

function countWord(text, word) {
    // Count occurrences of `word` as a whole word using simple loop
    let count = 0, idx = 0;
    while (true) {
        idx = text.indexOf(word, idx);
        if (idx === -1) break;
        // word boundary check
        const before = idx > 0 ? text.charCodeAt(idx - 1) : 0;
        const after = idx + word.length < text.length ? text.charCodeAt(idx + word.length) : 0;
        if (!isIdentChar(before) && !isIdentChar(after)) count++;
        idx += word.length;
    }
    return count;
}

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

function hasMemberAccessOutsideLines(text, name, skipLines) {
    const re = new RegExp("\\.\\s*" + escapeRegex(name) + "\\b", "g");
    let m;
    while ((m = re.exec(text)) !== null) {
        const lineIdx = (text.substring(0, m.index).match(/\n/g) || []).length;
        if (!skipLines.includes(lineIdx + 1)) return true;
    }
    return false;
}

// ---- STRIPPED TEXT CACHE (precomputed per-file, reused for self+ref checks) ----
const strippedCache = new Map();
function getStripped(f) {
    if (!strippedCache.has(f.path)) strippedCache.set(f.path, nostrings(nocomment(f.text)));
    return strippedCache.get(f.path);
}

let vc = 0;
for (const d of decls) {
    vc++;
    if (vc % 100 === 0) log(`  ${vc}/${decls.length}`);

    if (d.isReexport) { reexported.push(d); continue; }

    const legal = new Set([d.file, ...(reachable.get(d.file) || [])]);
    let prodCount = 0, testCount = 0;
    const selfText = getStripped(fileByPath.get(d.file));

    for (const fp of legal) {
        const f = fileByPath.get(fp);
        if (!f) continue;

        const isSelf = fp === d.file;

        if (d.parent) {
            const qn = d.parent + "." + d.name;
            if (isSelf) {
                if (hasWordOutsideLines(selfText, qn, [d.line])) prodCount++
                else if (hasWord(selfText, d.parent) && hasMemberAccessOutsideLines(selfText, d.name, [d.line])) prodCount++;
            } else {
                const fText = getStripped(f);
                if (hasWord(fText, qn)) {
                    if (fileType.get(fp) === "prod") prodCount++; else testCount++;
                } else if (hasWord(fText, d.parent) && hasMemberAccess(fText, d.name)) {
                    if (fileType.get(fp) === "prod") prodCount++; else testCount++;
                }
            }
        } else {
            if (isSelf) {
                if (hasWordOutsideLines(selfText, d.name, [d.line])) prodCount++;
            } else {
                if (hasWord(getStripped(f), d.name)) {
                    if (fileType.get(fp) === "prod") prodCount++;
                    else testCount++;
                }
            }
        }
    }

    if (prodCount === 0 && testCount === 0) unused.push(d);
    else if (prodCount === 0 && testCount > 0) testOnly.push(d);
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
const P = (s,n) => (s||"").padEnd(n).substring(0,n);

console.log("\n" + "=".repeat(80));
console.log("UNUSED-PUB DETECTOR");
console.log("=".repeat(80));

console.log(`\nCOMPLETELY UNUSED (${unused.length})\n`);
for (const d of unused.sort((a,b) => a.file.localeCompare(b.file) || a.line-b.line)) {
    const p = d.parent ? `parent: ${d.parent}` : "";
    console.log(`  ${P(d.file,40)} L${P(String(d.line),4)} pub ${P(d.kind,12)} ${P(d.name,24)} ${p}`);
}

console.log(`\nONLY USED IN TESTS (${testOnly.length})\n`);
for (const d of testOnly.sort((a,b) => a.file.localeCompare(b.file) || a.line-b.line)) {
    const p = d.parent ? `parent: ${d.parent}` : "";
    console.log(`  ${P(d.file,40)} L${P(String(d.line),4)} pub ${P(d.kind,12)} ${P(d.name,24)} ${p}`);
}

console.log(`\nRE-EXPORTED (${reexported.length})\n`);
for (const d of reexported.sort((a,b) => a.file.localeCompare(b.file) || a.line-b.line)) {
    const b = bindings.get(d.file)?.get(d.name);
    console.log(`  ${P(d.file,40)} L${P(String(d.line),4)} pub ${P(d.kind,12)} ${P(d.name,24)} ${b ? "→ "+b.sf+":"+b.si : ""}`);
}

const usedCount = decls.length - unused.length - testOnly.length - reexported.length;
console.log("\n" + "=".repeat(80));
console.log(`Total: ${decls.length} | Prod-used: ${usedCount} | Unused: ${unused.length} | Test-only: ${testOnly.length} | Re-exports: ${reexported.length}`);
if (unused.length + testOnly.length > 0) {
    console.log(`Cleanup candidates: ${unused.length+testOnly.length} across ${new Set([...unused,...testOnly].map(d=>d.file)).size} files`);
}
