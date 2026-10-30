#!/usr/bin/env node
// OpenCode desktop patch engine - pure text transforms on an EXTRACTED asar tree.
// Usage: node patch_opencode_clone_home.mjs <extractedDir>
// Prints a JSON result on stdout; exit 0 = all patches applied or already applied,
// exit 1 = any patch found zero sites (tree left untouched).
//
// Engine v1 patch set (all anchors byte-verified against the installed
// OpenCode 2.0.32 app.asar, 2026-10-24 - see docs/OPENCODE_CLONES_SPEC.md):
//
//   clone-home      give packaged builds the TEST_ROOT-equivalent: the app's own
//                   bootstrap runs `ye()` whose packaged branch hardcodes
//                   userData = %APPDATA%\ai.opencode.desktop
//                   (`<recv>.isPackaged?void 0:process.env.OPENCODE_DESKTOP_TEST_ROOT`
//                   - exactly 1 site). The patch swaps that branch for an argv
//                   scan of `--opencode-clone-home=<dir>`; ye()'s EXISTING body
//                   then does the rest for free: mkdirs the
//                   data/config/cache/state/desktop/session/documents subdirs,
//                   sets XDG_DATA/CONFIG/CACHE/STATE_HOME from them (the app's
//                   OWN redirection surface, read unconditionally in production)
//                   and the call site sets userData=<home>\desktop +
//                   sessionData=<home>\session. No flag => the branch evaluates
//                   to void 0 exactly like stock - the Primary and any bare
//                   spawn are untouched. (The app is asInvoker, so argv - not a
//                   marker file - is the identity channel; there is no UAC
//                   boundary to survive.)
//
//   clone-identity  per-clone taskbar identity at the app's SINGLE
//                   setAppUserModelId call site (count = 1 in 2.0.32):
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
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

const ENGINE_VERSION = 2;
const extractedDir = process.argv[2];
if (!extractedDir) {
  console.error(JSON.stringify({ ok: false, error: "usage: patch_opencode_clone_home.mjs <extractedDir>" }));
  process.exit(1);
}

// ── clone-home (F1) ──────────────────────────────────────────────────────────
// Pristine anchor: the exact minified ternary tail (string search cannot
// break; byte-verified 1 occurrence in the 2.0.32 asar).
const HOME_PRISTINE = "isPackaged?void 0:process.env.OPENCODE_DESKTOP_TEST_ROOT";
// Done anchor: what a patched tree contains verbatim.
const HOME_DONE = "globalThis.__opencodeCloneHome ??=";
// Cached argv scan: the clone home path or "". Trim-tolerant (a trailing
// space after a quoted path is the observed cmd-start argv shape elsewhere).
const CLONE_HOME_SCAN = `(globalThis.__opencodeCloneHome ??= (() => { let __h = ""; try { const __a = process.argv; for (let __i = 0; __i < __a.length; __i++) { const __v = __a[__i].trim().replace(/^(?:"|')|(?:"|')$/g, ""); const __eq = __v.indexOf("="); if (__eq > 0 && __v.slice(0, __eq) === "--opencode-clone-home") { const __val = __v.slice(__eq + 1).trim(); if (__val) { __h = __val; break; } } else if (__v === "--opencode-clone-home" && __i + 1 < __a.length) { const __val = __a[__i + 1].trim().replace(/^(?:"|')|(?:"|')$/g, ""); if (__val) { __h = __val; break; } } } } catch (__x) {} return __h; })())`;

// ── clone-identity (F2+F3) ───────────────────────────────────────────────────
// Pristine anchor: any `<recv>.setAppUserModelId(<bareIdent>)` call (1 site in
// 2.0.32, receiver captured so the listener can attach to the same app
// object; the wrapped output's argument is an expression, so it can never
// re-match this regex - idempotence by construction).
const AUMID_CALL_RE = /([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\.setAppUserModelId\(\s*([A-Za-z_$][\w$]*)\s*\)/g;
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
    name: "clone-home",
    apply: (src) => {
      if (src.includes(HOME_DONE)) return { src, count: -1 };
      const parts = src.split(HOME_PRISTINE);
      if (parts.length === 1) return { src, count: 0 };
      const replacement = `isPackaged?(${CLONE_HOME_SCAN}||void 0):process.env.OPENCODE_DESKTOP_TEST_ROOT`;
      return { src: parts.join(replacement), count: parts.length - 1 };
    },
  },
  {
    name: "clone-identity",
    apply: (src) => {
      if (src.includes(IDENTITY_DONE)) return { src, count: -1 };
      let count = 0;
      AUMID_CALL_RE.lastIndex = 0;
      const out = src.replace(AUMID_CALL_RE, (m, recv, ident) => {
        count++;
        return (
          `${recv}.setAppUserModelId(${ident}+((__i)=>__i&&__i.aumidSuffix?"."+__i.aumidSuffix:"")(${IDENTITY_RESOLVER}))` +
          windowStampIife(recv, ident)
        );
      });
      if (count === 0) return { src, count: 0 };
      return { src: out, count };
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
