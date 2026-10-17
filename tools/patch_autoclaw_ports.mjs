#!/usr/bin/env node
// AutoClaw patch engine - pure text transforms on an EXTRACTED asar tree.
// Usage: node patch_autoclaw_ports.mjs <extractedDir>
// Prints a JSON result on stdout; exit 0 = all patches applied or already applied,
// exit 1 = any patch found zero sites (tree left untouched).
//
// Engine v6 patch set:
//   mcp-ports-8slot  PRODUCTIVITY_MCP_CANDIDATE_PORTS [19681..19684] -> [19681..19688]
//   home-override    redirect the app's whole ~/.openclaw-autoclaw tree to a
//                    per-clone home. Evolution (all verified live 2026-10-16):
//     v2  262 receiver-form `X.homedir()` sites -> env-preferring wrapper
//     v3  + 6 bare `homedir()` sites from destructured os imports
//     v4  + THE state-dir resolver: `X.app.getPath("home")` -> join(...,
//         OPENCLAW_HOME_DIR, ...parts) - Chromium known-folder API, env-immune
//     v5  THE KICKER: AutoClaw.exe's manifest declares requireAdministrator, so
//         every launch self-elevates (UAC silent for admins) and the elevated
//         process gets a FRESH ENVIRONMENT - the launcher's AUTOCLAW_HOME_DIR /
//         USERPROFILE / HOME never survive (args DO). v5 therefore points the
//         resolver at a MARKER FILE inside the user-data dir:
//         <userData>\.autoclaw-home holds the clone home (written by the
//         launcher, verified after write). v6: the resolver reads the marker
//         via process.argv --user-data-dir, NOT getPath("userData") - the
//         resolver runs before the app applies the profile switch, so v5's
//         getPath lookup always saw the DEFAULT profile (verified live).
// See docs/AUTOCLAW_CLONES_SPEC.md section 5.1/5.3 and section 7.3.
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

const ENGINE_VERSION = 10;
const extractedDir = process.argv[2];
if (!extractedDir) {
  console.error(JSON.stringify({ ok: false, error: "usage: patch_autoclaw_ports.mjs <extractedDir>" }));
  process.exit(1);
}

// Canonical 8-slot replacement. Spacing is fixed so the wrapper's verify-after
// re-read (string contains-check on the packed app.asar) is deterministic.
const PORTS_8SLOT = "[19681, 19682, 19683, 19684, 19685, 19686, 19687, 19688]";
// Exact idempotence anchor: what a patched tree contains verbatim.
const DONE_ANCHOR = "PRODUCTIVITY_MCP_CANDIDATE_PORTS = " + PORTS_8SLOT;
// Pristine anchor: 4-slot array with flexible whitespace (minified vs pretty builds).
const PRISTINE_RE = /((?:const|let|var)\s+)?PRODUCTIVITY_MCP_CANDIDATE_PORTS\s*=\s*\[\s*19681\s*,\s*19682\s*,\s*19683\s*,\s*19684\s*\]/g;

// home-override anchors: receiver wrapper present / bare wrapper present /
// v6 argv-marker resolver present.
const HOME_OVERRIDE_ANCHOR = "process.env.AUTOCLAW_HOME_DIR";
const HOME_OVERRIDE_V3_ANCHOR = ".trim()) || homedir()";
const V6_SIGNATURE = 'startsWith("--user-data-dir=")';
const V7_SIGNATURE = "__autoclawHomeOverride";
const HOMEDIR_RECEIVER_RE = /([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\.homedir\(\)/g;
const HOMEDIR_BARE_RE = /(?<![.\w$])homedir\(\)/g;
// One simple regex for every `X.getPath("home")` form; per-site decisions use
// the PRE-MATCH context (replace callback offset), never lookbehinds - the
// lookbehind variant double-wrapped `X.app.getPath` inside `require$$N.app`
// receivers (the receiver group can start mid-identifier chain context).
const GETPATH_SIMPLE_RE = /([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\.getPath\(\s*(["'])home\2\s*\)/g;
const GETPATH_HOME_V4WRAPPER_RE = /\(\(process\.env\.AUTOCLAW_HOME_DIR && process\.env\.AUTOCLAW_HOME_DIR\.trim\(\)\) \|\| ([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\.getPath\(\s*(["'])home\2\s*\)\)/g;
// The exact v5 IIFE shape (userData-marker variant) emitted by engine v5.
const V5_IIFE_RE = /\(\(\(\) => \{ try \{ const __d = require\("path"\)\.join\(([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\.getPath\((["'])userData\2\), "\.autoclaw-home"\); const __v = require\("fs"\)\.readFileSync\(__d, "utf8"\)\.trim\(\); if \(__v\) return __v; \} catch \(__e\) \{\} return \1\.getPath\(\2home\2\); \}\)\(\)\)/g;

// The argv-marker scan, cached process-wide in a global (first call computes,
// every later call reuses - homedir()/resolver sites run constantly).
const ARGV_SCAN_CACHED = `(globalThis.__autoclawHomeOverride ??= (() => { let __out = ""; let __err = ""; try { const __a = process.argv; for (let __i = 0; __i < __a.length; __i++) { let __m = null; if (__a[__i].startsWith("--user-data-dir=")) __m = __a[__i].slice("--user-data-dir=".length); else if (__a[__i] === "--user-data-dir" && __i + 1 < __a.length) __m = __a[__i + 1]; if (__m) { __m = __m.replace(/^(?:"|')|(?:"|')$/g, "").trim(); try { const __v = require("fs").readFileSync(require("path").join(__m, ".autoclaw-home"), "utf8").trim(); if (__v) { __out = __v; break; } } catch (__x) { __err = String(__x.message); } } } } catch (__x2) { __err = String(__x2.message); } try { require("fs").appendFileSync(require("os").tmpdir() + "/ac-argv-debug.txt", JSON.stringify({ pid: process.pid, argv: process.argv, out: __out, err: __err }) + String.fromCharCode(10)); } catch (__d) {} return __out; })())`;
const ENV_CHECK = "(process.env.AUTOCLAW_HOME_DIR && process.env.AUTOCLAW_HOME_DIR.trim())";
// The env wrapper's fixed literal prefix (emitted by this engine's v2/v3
// passes) - matched by STRING search, not regex, so it cannot break.
const ENV_PREFIX_LITERAL = ENV_CHECK + " || ";
// The v7 scan body still inside already-v7-patched trees - v8's debug variant
// never reached them (no pass re-emitted the scan). v9 swaps it by literal.
const V7_SCAN_OLD = `(globalThis.__autoclawHomeOverride ??= (() => { try { const __a = process.argv; for (let __i = 0; __i < __a.length; __i++) { let __m = null; if (__a[__i].startsWith("--user-data-dir=")) __m = __a[__i].slice("--user-data-dir=".length); else if (__a[__i] === "--user-data-dir" && __i + 1 < __a.length) __m = __a[__i + 1]; if (__m) { __m = __m.replace(/^(?:"|')|(?:"|')$/g, "").trim(); const __v = require("fs").readFileSync(require("path").join(__m, ".autoclaw-home"), "utf8").trim(); if (__v) return __v; } } } catch (__e) {} return ""; })())`;

function homeOverrideIife(recv, q) {
  // TEMP DEBUG (2026-10-16): record argv + resolution outcome for field diagnosis.
  const debug = `try { require("fs").appendFileSync(require("os").tmpdir() + "/ac-argv-debug.txt", JSON.stringify({ argv: process.argv, resolved: __v, err: String(__e && __e.message || "") }) + "\\n"); } catch (__d) {}`;
  // v6: resolve the marker via process.argv --user-data-dir, NOT
  // getPath("userData") - the resolver runs before the app applies the
  // profile switch (verified live 2026-10-16: v5's getPath lookup always saw
  // the DEFAULT profile, never found the marker, fell back to the real home).
  // argv is set from process start and survives the requireAdministrator
  // self-elevation (env does not).
  return `((() => { let __v = ""; let __e = null; try { const __a = process.argv; for (let __i = 0; __i < __a.length; __i++) { let __m = null; if (__a[__i].startsWith("--user-data-dir=")) __m = __a[__i].slice("--user-data-dir=".length); else if (__a[__i] === "--user-data-dir" && __i + 1 < __a.length) __m = __a[__i + 1]; if (__m) { __m = __m.replace(/^(?:"|')|(?:"|')$/g, "").trim(); const __r = require("fs").readFileSync(require("path").join(__m, ".autoclaw-home"), "utf8").trim(); if (__r) { __v = __r; break; } } } } catch (__x) { __e = __x; } ${debug} if (__v) return __v; return ${recv}.getPath(${q}home${q}); })())`;
}

function listSourceFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) out.push(...listSourceFiles(full));
    else if (/\.(js|cjs|mjs|html)$/.test(name)) out.push(full);
  }
  return out;
}

// Patch definitions. apply(src) returns {src, count}; count -1 = already applied.
const PATCHES = [
  {
    name: "mcp-ports-8slot",
    apply: (src) => {
      if (src.includes(DONE_ANCHOR)) return { src, count: -1 };
      let count = 0;
      PRISTINE_RE.lastIndex = 0;
      const out = src.replace(PRISTINE_RE, (m, decl) => {
        count++;
        return (decl || "") + "PRODUCTIVITY_MCP_CANDIDATE_PORTS = " + PORTS_8SLOT;
      });
      if (count === 0) return { src, count: 0 };
      return { src: out, count };
    },
  },
  {
    name: "home-override",
    // Passes, each self-guarding against its own output:
    //   1. receiver-form `X.homedir()` -> env wrapper (gated on the v2 anchor;
    //      the v2 wrapper's own `X.homedir()` output would double-wrap)
    //   2. bare-form `homedir()` -> env wrapper (gated on the v3 anchor)
    //   3. `X.app.getPath("home")` -> v5 MARKER-FILE resolver (gated on the v5
    //      marker; unwraps the v4 env wrapper first, then pristine sites)
    //   4. legacy env-wrapper sites on homedir/receiver forms stay: env vars
    //      no longer survive elevation, but they are harmless fallbacks.
    apply: (src) => {
      let out = src;
      let count = 0;

      if (!src.includes(HOME_OVERRIDE_ANCHOR)) {
        out = out.replace(HOMEDIR_RECEIVER_RE, (m, obj) => {
          count++;
          return `((process.env.AUTOCLAW_HOME_DIR && process.env.AUTOCLAW_HOME_DIR.trim()) || ${obj}.homedir())`;
        });
      }
      if (!out.includes(HOME_OVERRIDE_V3_ANCHOR)) {
        out = out.replace(HOMEDIR_BARE_RE, () => {
          count++;
          return "((process.env.AUTOCLAW_HOME_DIR && process.env.AUTOCLAW_HOME_DIR.trim()) || homedir())";
        });
      }
      // v9: swap the v7 scan body for the v8 debug-instrumented scan inside
      // already-patched trees (the v7 prefix pass is gated off there).
      if (!out.includes("ac-argv-debug") && out.includes(V7_SIGNATURE)) {
        const pp = out.split(V7_SCAN_OLD);
        if (pp.length > 1) {
          count += pp.length - 1;
          out = pp.join(ARGV_SCAN_CACHED);
        }
      }
      // v10: the app's argv carries a trailing space after the quoted path
      // (verified via the app's own debug record 2026-10-16) - trim the
      // extracted value or the marker read misses by one character.
      const TRIM_SWAP_OLD = '$/g, "");';
      const TRIM_SWAP_NEW = '$/g, "").trim();';
      if (out.includes(TRIM_SWAP_OLD) && out.includes(V7_SIGNATURE)) {
        const tp = out.split(TRIM_SWAP_OLD);
        count += tp.length - 1;
        out = tp.join(TRIM_SWAP_NEW);
      }
      if (!out.includes(V6_SIGNATURE)) {
        // Engine v5 trees: unwrap the userData-marker IIFE to the v6 argv form.
        out = out.replace(V5_IIFE_RE, (m, recv, q) => {
          count++;
          return homeOverrideIife(recv, q);
        });
        // v4 env-wrapper sites: unwrap straight to the v6 IIFE.
        out = out.replace(GETPATH_HOME_V4WRAPPER_RE, (m, recv, q) => {
          count++;
          return homeOverrideIife(recv, q);
        });
        // Pristine (never-wrapped) resolver sites LAST: skip any site whose
        // immediate context marks it as an already-handled fallback or wrapper
        // (the IIFEs emitted above contain `return X.getPath("home")` and the
        // v4 wrapper contains `) || X.getPath("home")` - both must survive).
        out = out.replace(GETPATH_SIMPLE_RE, (m, recv, q, offset, full) => {
          const before = full.slice(Math.max(0, offset - 40), offset);
          if (/return\s+$/.test(before) || /\)\s*\|\|\s*$/.test(before)) { return m; }
          count++;
          return homeOverrideIife(recv, q);
        });
      }
      // v7: prefix every surviving env wrapper with the cached argv-marker
      // scan - the env check alone is dead under the requireAdministrator
      // self-elevation (fresh env), so the marker file must come first.
      // STRING search on the fixed literal prefix (receiver and bare forms
      // share it); no regex, so it cannot break.
      if (!out.includes(V7_SIGNATURE)) {
        const parts = out.split(ENV_PREFIX_LITERAL);
        if (parts.length > 1) {
          count += parts.length - 1;
          out = parts.join(ARGV_SCAN_CACHED + " || " + ENV_PREFIX_LITERAL);
        }
      }
      if (count === 0) {
        return { src, count: (src.includes(HOME_OVERRIDE_ANCHOR) || src.includes(V6_SIGNATURE) || src.includes(V7_SIGNATURE)) ? -1 : 0 };
      }
      return { src: out, count };
    },
  },
];

function markersForPatch(name) {
  switch (name) {
    case "mcp-ports-8slot":
      return ["PRODUCTIVITY_MCP_CANDIDATE_PORTS", "19685", "19686", "19687", "19688"];
    case "home-override":
      return ["AUTOCLAW_HOME_DIR", ".autoclaw-home", "__autoclawHomeOverride"];
    default:
      return [];
  }
}

const results = [];
const files = listSourceFiles(extractedDir);
for (const file of files) {
  const before = readFileSync(file, "utf8");
  let src = before;
  const counts = {};
  const appliedMarkers = [];
  for (const patch of PATCHES) {
    const r = patch.apply(src);
    src = r.src;
    counts[patch.name] = r.count;
    if (r.count > 0) {
      appliedMarkers.push(...markersForPatch(patch.name));
    }
  }
  if (src !== before) {
    writeFileSync(file, src);
  }
  if (PATCHES.some((p) => counts[p.name] !== 0)) {
    results.push({ file: relative(extractedDir, file).split(sep).join("/"), counts, appliedMarkers });
  }
}

const totals = {};
for (const p of PATCHES) totals[p.name] = 0;
const failures = [];
for (const p of PATCHES) {
  for (const r of results) {
    if (r.counts[p.name] > 0) totals[p.name] += r.counts[p.name];
  }
  if (totals[p.name] === 0) {
    const anyAlready = results.some((r) => r.counts[p.name] === -1);
    if (!anyAlready) failures.push(p.name);
  }
}

if (failures.length) {
  console.log(JSON.stringify({ ok: false, engineVersion: ENGINE_VERSION, totals, results, error: "zero patch sites: " + failures.join(",") }));
  process.exit(1);
}

console.log(JSON.stringify({ ok: true, engineVersion: ENGINE_VERSION, totals, results }));
