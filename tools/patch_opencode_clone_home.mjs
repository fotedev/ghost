#!/usr/bin/env node
// OpenCode desktop patch engine - text transforms applied DIRECTLY inside the
// app.asar via tools/asar_surgery.mjs (no extract-to-disk, no repack).
// Usage: node patch_opencode_clone_home.mjs <sourceAsar> <candidateOut> <checksDir>
// Prints a JSON result on stdout; exit 0 = all patches applied or already applied
// (candidate asar written and fully verified), exit 1 = any patch found zero
// sites, a marker check failed, node --check rejected a patched file, or the
// rebuild verification failed (no candidate is swapped by this script - the
// PS driver owns the swap).
//
// Engine v1 patch set (all anchors byte-verified against the installed
// OpenCode 2.0.32 app.asar, 2026-10-24 - see docs/OPENCODE_CLONES_SPEC.md).
// Engine v3 (2026-11-01): re-derived for the 2.2.5.0 bundle - the clone-home
// anchor is now the app's generic test-root read (1 occurrence), slotted
// into the non-onboarding branch; the clone-identity regex matches 2.2.5.0
// unchanged (`g.setAppUserModelId(le)` - 1 site).
//
//   clone-home      give packaged builds the TEST_ROOT-equivalent: the app's
//                   bootstrap test-root read (`ue()` in 2.2.5.0 - was the
//                   `ye()` ternary tail in 2.0.32) is extended with an argv
//                   scan of `--opencode-clone-home=<dir>` slotted into the
//                   NON-onboarding branch ahead of the env fallback:
//                     L?onboarding:(CLONE_HOME_SCAN||process.env.OPENCODE_DESKTOP_TEST_ROOT)
//                   The onboarding branch must stay first (it rmSync-wipes its
//                   root). The app's OWN body then does the rest for free:
//                   mkdirs the data/config/cache/state/desktop/session/
//                   documents subdirs, sets XDG_DATA/CONFIG/CACHE/STATE_HOME
//                   from them (the app's OWN redirection surface, read
//                   unconditionally in production) and - since 2.2.5.0 - the
//                   SAME bootstrap fn (z()) pins userData=<home>\desktop +
//                   sessionData=<home>\session straight from ue()'s return
//                   value. No flag => the scan yields "" and the expression
//                   falls through to the env var exactly like stock - the
//                   Primary and any bare spawn are untouched. (The app is
//                   asInvoker, so argv - not a marker file - is the identity
//                   channel; there is no UAC boundary to survive.)
//
//   clone-identity  per-clone taskbar identity at the app's SINGLE
//                   setAppUserModelId call site (count = 1 in 2.0.32 AND in
//                   2.2.5.0: `g.setAppUserModelId(le)` inside the bootstrap
//                   z(), where `le` is the channel AUMID/userData name):
//                   wraps the argument to append ".<aumidSuffix>" AND registers
//                   an app-level "browser-window-created" listener that stamps
//                   every window's WINDOW-level AUMID via setAppDetails at
//                   creation (BEFORE show/grouping), sets the window icon and
//                   forces the title against renderer document.title updates.
//                   NOTE: this app has NO `new X.BrowserWindow(` sites (its
//                   imports are aliased - `BrowserWindow as L/J/i`), so the
//                   AutoClaw-v12 constructor-subclass wrap does not apply here;
//                   the browser-window-created event is the equivalent hook and
//                   needs no constructor anchor at all. The listener closes over
//                   the app's own AUMID base expression (captured `me`), so no
//                   base id is hardcoded.
//   v2 (2026-10-24, live finding): the app's main bundle (out/main/index.js)
//                   is ESM - `require` is undefined, so v1's fs-based identity
//                   resolver silently no-oped (caught error -> null -> stock
//                   identity; isolation was unaffected). The identity now rides
//                   PURE ARGV - the launcher passes --opencode-clone-id/-title/
//                   -icon alongside the home flag - so the injected code never
//                   touches fs and works in ESM and CJS alike. The launcher
//                   still writes .opencode-clone-identity.json beside the icon
//                   for human/-Status introspection only.
// Engine v4 (2026-11-03): patch sites unchanged from v3. v4 swaps the IO layer
//   to asar surgery (tools/asar_surgery.mjs) - ranged reads of only the text
//   entries, in-memory transforms, one streaming rebuild + full verify - and
//   fixes the same pre-existing perf bug found in the ZCode engine: the
//   clone-identity per-position regex scan. The patch anchors and output
//   bytes are identical.
import { mkdirSync, writeFileSync, openSync, closeSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import {
  parseAsarHeader,
  listSourceEntries,
  readEntryBytes,
  rebuildAsar,
  verifyRebuild,
} from "./asar_surgery.mjs";

const ENGINE_VERSION = 4;
const sourceAsar = process.argv[2];
const candidateOut = process.argv[3];
const checksDir = process.argv[4];
if (!sourceAsar || !candidateOut || !checksDir) {
  console.error(JSON.stringify({ ok: false, error: "usage: patch_opencode_clone_home.mjs <sourceAsar> <candidateOut> <checksDir>" }));
  process.exit(1);
}

// ── clone-home (F1) ──────────────────────────────────────────────────────────
// Pristine anchor: the app's own test-root read. 2.2.5.0 (v3 anchor, verified
// 1 occurrence in the asar 2026-11-01): the bootstrap `ue()` reads
//   let e=L?O.join(D(),`opencode-onboarding-${ie()}`):process.env.OPENCODE_DESKTOP_TEST_ROOT;
// so the GENERIC env-name anchor slots the scan into the non-onboarding
// branch while keeping the onboarding rmSync-wipe branch first. 2.0.32
// (v2 anchor, retired): `isPackaged?void 0:process.env.OPENCODE_DESKTOP_TEST_ROOT`.
const HOME_PRISTINE = "process.env.OPENCODE_DESKTOP_TEST_ROOT";
// Done anchor: what a patched tree contains verbatim.
const HOME_DONE = "globalThis.__opencodeCloneHome ??=";
// Cached argv scan: the clone home path or "". Trim-tolerant (a trailing
// space after a quoted path is the observed cmd-start argv shape elsewhere).
const CLONE_HOME_SCAN = `(globalThis.__opencodeCloneHome ??= (() => { let __h = ""; try { const __a = process.argv; for (let __i = 0; __i < __a.length; __i++) { const __v = __a[__i].trim().replace(/^(?:"|')|(?:"|')$/g, ""); const __eq = __v.indexOf("="); if (__eq > 0 && __v.slice(0, __eq) === "--opencode-clone-home") { const __val = __v.slice(__eq + 1).trim(); if (__val) { __h = __val; break; } } else if (__v === "--opencode-clone-home" && __i + 1 < __a.length) { const __val = __a[__i + 1].trim().replace(/^(?:"|')|(?:"|')$/g, ""); if (__val) { __h = __val; break; } } } } catch (__x) {} return __h; })())`;

// ── clone-identity (F2+F3) ───────────────────────────────────────────────────
// Pristine anchor: any `<recv>.setAppUserModelId(<bareIdent>)` call (1 site in
// 2.0.32 AND 2.2.5.0, receiver captured so the listener can attach to the same
// app object; the wrapped output's argument is an expression - IDENT+((__i)=>..)
// - so it can never re-match the anchor: idempotence by construction).
// v4 perf: matched by literal-needle indexOf + backward receiver scan instead
// of the v1-v3 global regex, whose per-position word-run backtracking is the
// same ~minutes-class cost the ZCode engine's preload-blue regex had. The
// scan is byte-equivalent: receiver = maximal dotted [\w$] chain ending right
// before ".setAppUserModelId(" whose segments start with [A-Za-z_$] (the
// regex's leftmost capture); ident = \s*IDENT\s* between the parens.
// Done anchor: the resolver's cache assignment.
const IDENTITY_DONE = "globalThis.__opencodeCloneIdentity ??=";
// Self-contained resolver: PURE ARGV (no fs, no require - the app's main
// bundle is ESM where require is undefined, the v1 live finding). The
// launcher passes --opencode-clone-id=<cN> (mandatory) plus optional
// --opencode-clone-title=<t> / --opencode-clone-icon=<path>; values may be
// quoted by the caller - stripped here. Missing id flag => null => every
// injected site is a no-op (stock behavior).
const IDENTITY_RESOLVER = `(globalThis.__opencodeCloneIdentity ??= (() => { let __id = null; try { const __a = process.argv; let __cid = "", __ct = "", __ci = ""; for (let __i = 0; __i < __a.length; __i++) { const __v = __a[__i].trim().replace(/^(?:"|')|(?:"|')$/g, ""); const __eq = __v.indexOf("="); if (__eq < 0) continue; const __k = __v.slice(0, __eq); const __val = __v.slice(__eq + 1).trim().replace(/^(?:"|')|(?:"|')$/g, ""); if (__k === "--opencode-clone-id") __cid = __val; else if (__k === "--opencode-clone-title") __ct = __val; else if (__k === "--opencode-clone-icon") __ci = __val; } if (!__cid) return null; __id = { aumidSuffix: __cid }; if (__ct) __id.title = __ct; if (__ci) __id.iconPath = __ci; } catch (__x) { return null; } return __id; })())`;
// Window-stamp listener body (injected as an extra argument to the SAME
// statement): stamps the WINDOW-level AUMID via setAppDetails at creation,
// sets the icon, and forces the title against renderer document.title
// updates (page-title-updated preventDefault + re-assert on show).
function windowStampIife(recv, baseExpr) {
  return `,${recv}.on("browser-window-created", (__e, __w) => { try { const __id = globalThis.__opencodeCloneIdentity; if (!__id) return; const __aumid = ${baseExpr} + (__id.aumidSuffix ? "." + __id.aumidSuffix : ""); const __stamp = () => { try { if (typeof __w.setAppDetails === "function") __w.setAppDetails({ appId: __aumid }); } catch (__s1) {} }; __stamp(); if (__id.iconPath) { try { __w.setIcon(__id.iconPath); } catch (__s2) {} } if (__id.title) { try { if (__w.getTitle() !== __id.title) __w.setTitle(__id.title); } catch (__s3) {} try { __w.on("page-title-updated", (__e2) => { try { __e2.preventDefault(); } catch (__s4) {} try { if (__w.getTitle() !== __id.title) __w.setTitle(__id.title); } catch (__s5) {} __stamp(); }); } catch (__s6) {} } try { __w.on("show", () => { __stamp(); }); } catch (__s7) {} } catch (__s8) {} })`;
}

// Patch definitions. apply(src) returns {src, count}; count -1 = already applied.
const PATCHES = [
  {
    name: "clone-home",
    apply: (src) => {
      if (src.includes(HOME_DONE)) return { src, count: -1 };
      const parts = src.split(HOME_PRISTINE);
      if (parts.length === 1) return { src, count: 0 };
      // The scan slots into the non-onboarding branch, ahead of the env
      // fallback: L?onboarding:(SCAN||process.env.OPENCODE_DESKTOP_TEST_ROOT)
      const replacement = `(${CLONE_HOME_SCAN}||process.env.OPENCODE_DESKTOP_TEST_ROOT)`;
      return { src: parts.join(replacement), count: parts.length - 1 };
    },
  },
  {
    name: "clone-identity",
    apply: (src) => {
      if (src.includes(IDENTITY_DONE)) return { src, count: -1 };
      const CALL = ".setAppUserModelId(";
      const isIdentStart = (ch) => /[A-Za-z_$]/.test(ch);
      const isWordChar = (ch) => /[\w$]/.test(ch);
      const hits = [];
      let from = 0;
      for (;;) {
        const callAt = src.indexOf(CALL, from);
        if (callAt === -1) break;
        // backward dotted-receiver scan from the '.' before the call
        let start = callAt;
        let hasRecv = true;
        for (;;) {
          let s = start;
          while (s > 0 && isWordChar(src[s - 1])) s--;
          if (s === start) { hasRecv = false; break; } // empty segment - no regex match here
          start = s;
          if (start > 0 && src[start - 1] === "." && start - 1 > 0 && isIdentStart(src[start - 2])) {
            start--; // continue the dotted chain (regex: (?:\.[A-Za-z_$][\w$]*)*)
          } else break;
        }
        if (!hasRecv) { from = callAt + CALL.length; continue; }
        // the regex receiver starts with [A-Za-z_$]: trim any leading digits
        // the backward [\w$] sweep collected (unreachable in valid JS)
        while (start < callAt && /[0-9]/.test(src[start])) start++;
        const recv = src.slice(start, callAt);
        // ident tail: \s* IDENT \s* )
        let p = callAt + CALL.length;
        while (p < src.length && /\s/.test(src[p])) p++;
        if (p >= src.length || !isIdentStart(src[p])) { from = p > callAt ? p : callAt + CALL.length; continue; }
        let q = p;
        while (q < src.length && isWordChar(src[q])) q++;
        let r = q;
        while (r < src.length && /\s/.test(src[r])) r++;
        if (src[r] !== ")") { from = callAt + CALL.length; continue; }
        hits.push({ start, end: r + 1, recv, ident: src.slice(p, q) });
        from = r + 1;
      }
      if (hits.length === 0) return { src, count: 0 };
      let out = src;
      // splice from last to first so earlier indices stay valid
      for (let i = hits.length - 1; i >= 0; i--) {
        const h = hits[i];
        const replacement =
          h.recv + ".setAppUserModelId(" + h.ident +
          '+((__i)=>__i&&__i.aumidSuffix?"."+__i.aumidSuffix:"")(' + IDENTITY_RESOLVER + "))" +
          windowStampIife(h.recv, h.ident);
        out = out.slice(0, h.start) + replacement + out.slice(h.end);
      }
      return { src: out, count: hits.length };
    },
  },
];

function markersForPatch(name) {
  switch (name) {
    case "clone-home":
      return ["__opencodeCloneHome", "--opencode-clone-home"];
    case "clone-identity":
      // Both live in the injected expression itself (engine-emitted, ESM-safe
      // argv-only v2 resolver). Never list the browser-window-created listener
      // separately - a file could carry the AUMID wrap without reaching the
      // listener injection point (same statement, but keep the per-file
      // verify conservative).
      return ["__opencodeCloneIdentity", "--opencode-clone-id"];
    default:
      return [];
  }
}

const T0 = process.hrtime.bigint();
const lap = (from) => Number(process.hrtime.bigint() - from) / 1e6;
const timings = {};
const DEBUG = process.env.GHOST_PATCH_DEBUG === "1";
const patchTimings = {};
const debugLog = (...a) => { if (DEBUG) console.error("[debug]", ...a); };

// 1. Parse header + ranged-read/patch every text entry in memory.
const { header, payloadBase } = parseAsarHeader(sourceAsar);
const results = [];
const patchedContents = new Map(); // rel -> new utf8 content (only changed files)
const srcFd = openSync(sourceAsar, "r");
try {
  let seen = 0;
  for (const { rel, node } of listSourceEntries(header)) {
    const before = readEntryBytes(srcFd, payloadBase, node).toString("utf8");
    let src = before;
    const counts = {};
    const appliedMarkers = [];
    for (const patch of PATCHES) {
      const pT = DEBUG ? process.hrtime.bigint() : null;
      const r = patch.apply(src);
      if (DEBUG) patchTimings[patch.name] = (patchTimings[patch.name] || 0) + Number(process.hrtime.bigint() - pT) / 1e6;
      src = r.src;
      counts[patch.name] = r.count;
      if (r.count > 0) {
        appliedMarkers.push(...markersForPatch(patch.name));
      }
    }
    if (src !== before) {
      patchedContents.set(rel, src);
      // verify-after-patch on the in-memory content (the markers the PS
      // driver used to re-check by re-reading the extracted tree)
      for (const marker of appliedMarkers) {
        if (!src.includes(marker)) {
          console.log(JSON.stringify({ ok: false, engineVersion: ENGINE_VERSION, error: `patch verify FAILED after write: marker '${marker}' missing in ${rel}` }));
          process.exit(1);
        }
      }
    }
    if (PATCHES.some((p) => counts[p.name] !== 0)) {
      results.push({ file: rel, counts, appliedMarkers });
    }
    seen++;
    if (DEBUG && seen % 5000 === 0) debugLog("scanned", seen, "entries");
  }
} finally {
  closeSync(srcFd);
}
timings.readPatchMs = Math.round(lap(T0));
if (DEBUG) {
  for (const [name, ms] of Object.entries(patchTimings)) debugLog("patch", name, Math.round(ms) + "ms");
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

// 2. Syntax gate: node --check every patched js/cjs/mjs BEFORE rebuilding
// (markers alone cannot catch a structurally broken bundle). Only files that
// changed in this run are checked; already-applied sites carry the previous
// engine's verified output.
const tSyntax = process.hrtime.bigint();
mkdirSync(checksDir, { recursive: true });
const syntaxFailures = [];
for (const r of results) {
  if (!/\.(js|cjs|mjs)$/.test(r.file)) continue;
  const content = patchedContents.get(r.file);
  if (content === undefined) continue;
  const checkPath = join(checksDir, r.file.replace(/\//g, "__"));
  writeFileSync(checkPath, content, "utf8");
  try {
    execFileSync(process.execPath, ["--check", checkPath], { stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    syntaxFailures.push({ file: r.file, output: String((e && (e.stderr || e.stdout)) || e).trim() });
  }
}
timings.syntaxMs = Math.round(lap(tSyntax));
if (syntaxFailures.length) {
  const f = syntaxFailures[0];
  console.log(JSON.stringify({
    ok: false,
    engineVersion: ENGINE_VERSION,
    totals,
    results,
    error: "node --check rejected " + f.file + " - aborting before rebuild: " + f.output,
    syntaxFailures,
  }));
  process.exit(1);
}

// 3. Rebuild: copy the untouched payload region byte-for-byte, append the
// patched contents at the tail, rewrite only the patched header entries.
const tRebuild = process.hrtime.bigint();
const expected = new Map();
for (const [rel, content] of patchedContents) expected.set(rel, Buffer.from(content, "utf8"));
const meta = rebuildAsar({
  sourcePath: sourceAsar,
  outPath: candidateOut,
  transform: (rel) => patchedContents.get(rel) ?? null,
});
timings.rebuildMs = Math.round(lap(tRebuild));

// 4. Verify the candidate: header walk + full payload-region byte compare +
// exact patched-content compare (stronger than the old per-file extract).
const tVerify = process.hrtime.bigint();
const v = verifyRebuild({ sourcePath: sourceAsar, outPath: candidateOut, expected, meta });
timings.verifyMs = Math.round(lap(tVerify));
timings.totalMs = Math.round(lap(T0));
if (!v.ok) {
  console.log(JSON.stringify({
    ok: false,
    engineVersion: ENGINE_VERSION,
    totals,
    results,
    error: "candidate asar verification FAILED: " + v.errors.join("; "),
    verifyErrors: v.errors,
  }));
  process.exit(1);
}

console.log(JSON.stringify({
  ok: true,
  engineVersion: ENGINE_VERSION,
  totals,
  results,
  timings,
  patchedSizes: meta.patched,
  outSize: meta.outSize,
  verifyChecked: v.checked,
}));
