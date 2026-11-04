#!/usr/bin/env node
// ZCode blue-branding patch engine — text transforms applied DIRECTLY inside
// the app.asar via tools/asar_surgery.mjs (no extract-to-disk, no repack).
// Usage: node patch_zcode_icon_override.mjs <sourceAsar> <candidateOut> <checksDir>
// Prints a JSON result on stdout; exit 0 = all patches applied or already applied
// (candidate asar written and fully verified), exit 1 = any patch found zero
// sites, a marker check failed, node --check rejected a patched file, or the
// rebuild verification failed (no candidate is swapped by this script - the
// PS driver owns the swap).
//
// Engine v2 patch set:
//   icon-window   (v1) window icon path      -> env ZCODE_ICON_DIR override
//   icon-tray     (v1) tray icon path        -> env ZCODE_ICON_DIR override
//   aumid-suffix  (v1) AppUserModelID        -> optional ".<ZCODE_AUMID_SUFFIX>"
//   main-args     (v2) BrowserWindow additionalArguments -> --zcode-blue=<0|1>
//   preload-blue  (v2) contextBridge         -> window.__ZCODE_BLUE__ (sync, pre-render)
//   splash-html   (v2) startup splash inline logo -> blue via html.zblue CSS class
//   sidebar-logo  (v2) sidebar/settings Z data-URI -> conditional blue variant
//   react-badge   (v2) in-app loading badge paths -> conditional blue fill
// Engine v6 patch set (multi-instance accents):
//   main-args     (v6) also forwards --zcode-accent=<ZCODE_ACCENT_HEX> and
//                      --zcode-title=<ZCODE_INSTANCE_NAME> to the renderer
//   preload-blue  (v6) also exposes window.__ZCODE_ACCENT__ / __ZCODE_TITLE__
//   splash-html   (v6) accent-driven CSS var + "ZCode <title>" window name
//   sidebar-logo  (v6) fill reads __ZCODE_ACCENT__ (fallback BLUE_HEX)
//   react-badge   (v6) fill reads __ZCODE_ACCENT__ (fallback BLUE_HEX)
// __ZCODE_BLUE__ stays the binary on/off switch (derived from ZCODE_ICON_DIR);
// the accent only picks the color. No accent env -> exact v5 blue behavior.
// Engine v7 patch set (bidi auto-direction):
//   preload-bidi  (v7) appends a snippet after the __ZCODE_TITLE__ exposure that
//                      injects a <style id="zcode-bidi-auto-style"> making chat
//                      text blocks run the Unicode bidi algorithm per paragraph
//                      (unicode-bidi: plaintext -> Arabic RTL, English LTR, code
//                      blocks forced back to LTR) and stamps dir="auto" so text
//                      alignment follows the detected direction. Reads env vars
//                      directly in the renderer - ZCODE_BIDI_OFF=1 opts out per
//                      launch; no launcher/main-process changes. Inert on apps
//                      without the patch.
// App-update recovery note (2026-10-24): the app's auto-updater replaces
//   app.asar wholesale, wiping every patch site while the sidecar marker file
//   survives - so the driver script byte-probes the asar for these signature
//   strings ('ZCODE_ICON_DIR', 'ZCODE_AUMID_SUFFIX', 'zcode-bidi-auto-style')
//   instead of trusting the marker. Engine v7 site set unchanged; keep the
//   probe list in sync when a future engine adds new signature strings.
// Engine v8 patch set (updater-secondary tolerance for 3.16.3+):
//   updater-secondary (v8) the auto-updater gate grew a second conjunction -
//     enabled:<x>==="production"&&<flag>,onBeforeQuitAndInstall: - so the v7
//     exact anchor found zero sites on 3.16.3 and aborted the whole patch.
//     v8 matches both shapes (bare and &&<flag> conjunct) and appends
//     !process.env.ZCODE_ICON_DIR as an extra && term when the conjunct is
//     present.
// Engine v9 patch set: NONE - the patch sites are unchanged from v8. v9 swaps
//   the IO layer: instead of running on an EXTRACTED asar tree (full ~340 MB
//   extract + repack + per-file npx verify), the engine reads the patch
//   targets via ranged reads straight out of app.asar and rebuilds the
//   candidate archive in one streaming pass (tools/asar_surgery.mjs). The
//   syntax gate (node --check) and marker re-verification moved in-engine;
//   the JSON contract (ok/totals/results/appliedMarkers) is unchanged and
//   gained timings + patched file sizes.
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

const ENGINE_VERSION = 9;
const sourceAsar = process.argv[2];
const candidateOut = process.argv[3];
const checksDir = process.argv[4];
if (!sourceAsar || !candidateOut || !checksDir) {
  console.error(JSON.stringify({ ok: false, error: "usage: patch_zcode_icon_override.mjs <sourceAsar> <candidateOut> <checksDir>" }));
  process.exit(1);
}
// Flat blue sampled from the generated icon's Z stroke (RGB 6,107,203).
// Fallback accent when ZCODE_ACCENT_HEX is not set (v5 behavior).
const BLUE_HEX = "#066BCB";
// URL-escaped form used inside data-URI SVG fills (# -> %23).
const BLUE_URI = BLUE_HEX.replace("#", "%23");
// main -> renderer forwards for the per-instance accent/title (v6).
const ACCENT_ARG = ',"--zcode-accent="+(process.env.ZCODE_ACCENT_HEX||"")';
const TITLE_ARG = ',"--zcode-title="+(process.env.ZCODE_INSTANCE_NAME||"")';
// Engine v7: exact tail preload-blue writes for the __ZCODE_TITLE__ exposure.
// preload-bidi appends right after it, so the anchor exists on pristine trees
// (patches chain within a file) and on v6 trees alike.
const BIDI_ANCHOR =
  /exposeInMainWorld\("__ZCODE_TITLE__",\(process\.argv\.find\(a=>a\.startsWith\("--zcode-title="\)\)\|\|""\)\.slice\(14\)\)/g;
// Snippet appended to the preload bundle (comma-expression continuation of the
// exposure chain - never a statement). Runs the bidi algorithm per chat text
// block: CSS plaintext gives per-paragraph/per-line direction; the Mutation-
// Observer stamps dir="auto" so text-align follows the detected direction too.
// Code blocks are explicitly forced back to LTR because unicode-bidi inherits
// into nested pre/code inside lists/blockquotes. Opt out: ZCODE_BIDI_OFF=1.
const BIDI_APPEND = `,(() => {
  if (process.env.ZCODE_BIDI_OFF === "1") return;
  const sel = '[data-row-id] [data-conversation-selectable="true"] p,[data-streamdown="list-item"],[data-streamdown^="heading-"],[data-streamdown="blockquote"],[data-streamdown="table-cell"],[data-streamdown="table-header-cell"],[data-v4-user-input-collapsible-content="true"],[data-testid="v4-composer-input"]';
  const css = sel + '{unicode-bidi:plaintext;text-align:start}' +
    ',[data-streamdown^="code-block"],[data-streamdown^="code-block"] *,[data-streamdown^="mermaid"],[data-streamdown^="mermaid"] *,[data-language],[data-language] *,pre,code,kbd,samp{unicode-bidi:isolate;direction:ltr}';
  const inject = () => {
    if (document.getElementById("zcode-bidi-auto-style")) return;
    const el = document.createElement("style");
    el.id = "zcode-bidi-auto-style";
    el.textContent = css;
    (document.head || document.documentElement).appendChild(el);
  };
  const stamp = (root) => {
    if (!root || root.nodeType !== 1) return;
    const list = root.matches && root.matches(sel) ? [root] : [];
    if (root.querySelectorAll) for (const el of root.querySelectorAll(sel)) list.push(el);
    for (const el of list) {
      if (el.hasAttribute("dir") || (el.closest && el.closest("[data-language]"))) continue;
      el.setAttribute("dir", "auto");
    }
  };
  let started = false;
  const start = () => {
    if (started) return;
    started = true;
    inject();
    stamp(document.body);
    new MutationObserver((muts) => {
      for (const m of muts) for (const n of m.addedNodes) stamp(n);
    }).observe(document.documentElement, { childList: true, subtree: true });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})()`;

// Wrap the argument of `<receiver>.setAppUserModelId(` in extra parens plus the
// AUMID suffix expression. Paren matcher skips string literals.
function wrapSetAppUserModelIdArg(src) {
  const needle = "setAppUserModelId(";
  const idx = src.indexOf(needle);
  if (idx === -1) return { src, count: 0 };
  const argStart = idx + needle.length;
  let depth = 1;
  let i = argStart;
  let inStr = null;
  while (i < src.length && depth > 0) {
    const ch = src[i];
    if (inStr) {
      if (ch === "\\") i++;
      else if (ch === inStr) inStr = null;
    } else if (ch === '"' || ch === "'" || ch === "`") {
      inStr = ch;
    } else if (ch === "(") depth++;
    else if (ch === ")") depth--;
    i++;
  }
  if (depth !== 0) return { src, count: 0 };
  const argEnd = i - 1;
  const arg = src.slice(argStart, argEnd);
  if (arg.includes("ZCODE_AUMID_SUFFIX")) return { src, count: -1 };
  const wrapped =
    "(" + arg + '+(process.env.ZCODE_AUMID_SUFFIX?"."+process.env.ZCODE_AUMID_SUFFIX:""))';
  return { src: src.slice(0, argStart) + wrapped + src.slice(argEnd), count: 1 };
}

// Patch definitions. apply(src) returns {src, count}; count -1 = already applied.
const PATCHES = [
  {
    name: "icon-window",
    min: 1,
    apply: (src) => {
      const done = 'process.env.ZCODE_ICON_DIR||process.resourcesPath,"icon_windows.png"';
      if (src.includes(done)) return { src, count: -1 };
      const re = /process\.resourcesPath\s*,\s*(["'])icon_windows\.png\1/g;
      let count = 0;
      const out = src.replace(re, () => {
        count++;
        return done;
      });
      return { src: out, count };
    },
  },
  {
    name: "icon-tray",
    min: 1,
    apply: (src) => {
      const done = 'process.env.ZCODE_ICON_DIR||process.resourcesPath,"tray_icon.ico"';
      if (src.includes(done)) return { src, count: -1 };
      const re = /process\.resourcesPath\s*,\s*(["'])tray_icon\.ico\1/g;
      let count = 0;
      const out = src.replace(re, () => {
        count++;
        return done;
      });
      return { src: out, count };
    },
  },
  {
    name: "aumid-suffix",
    min: 1,
    apply: (src) => wrapSetAppUserModelIdArg(src),
  },
  {
    name: "main-args",
    min: 1,
    apply: (src) => {
      // Engine v3 bug repair: the v3 replacement dropped the template literal's
      // closing backtick, leaving an unterminated template that broke the main
      // bundle with SyntaxError: Unexpected identifier 'blocked'.
      // Engine v4 bug repair: the v4 fix inserted the backtick BEFORE the
      // interpolation's closing brace instead of after it -> SyntaxError:
      // Missing } in template expression. Both broken forms are repaired here.
      // Correct shape (v6): additionalArguments:[`--device-id=${expr}`,
      //   "--zcode-blue="+...,"--zcode-accent="+...,"--zcode-title="+...]
      const goodNeedle = ACCENT_ARG;
      if (src.includes(goodNeedle)) return { src, count: -1 };
      let out = src;
      let count = 0;
      // Step 1: repair v3/v4 broken shapes to the v5-good prefix. The leftover
      // tail after `,"--zcode-blue="` is preserved (same behavior as v5) and
      // picked up by step 2.
      const reBroken = /additionalArguments:\[`--device-id=\$\{([^}`]+)`?\},"--zcode-blue="/g;
      out = out.replace(reBroken, (_m, expr) => {
        count++;
        return 'additionalArguments:[`--device-id=${' + expr + '}`,"--zcode-blue="';
      });
      // Step 2: extend the v5 tail (blue arg only) with the accent/title args.
      const v5Tail = ',"--zcode-blue="+(process.env.ZCODE_ICON_DIR?"1":"0")]';
      const v6Tail = ',"--zcode-blue="+(process.env.ZCODE_ICON_DIR?"1":"0")' + ACCENT_ARG + TITLE_ARG + "]";
      count += out.split(v5Tail).length - 1;
      out = out.split(v5Tail).join(v6Tail);
      // Step 3: pristine trees - build the full v6 shape directly.
      const re = /additionalArguments:\[`--device-id=\$\{([^}]+)\}`\]/g;
      out = out.replace(re, (_m, expr) => {
        count++;
        return 'additionalArguments:[`--device-id=${' + expr +
          '}`,"--zcode-blue="+(process.env.ZCODE_ICON_DIR?"1":"0")' + ACCENT_ARG + TITLE_ARG + "]";
      });
      return { src: out, count };
    },
  },
  {
    name: "preload-blue",
    min: 1,
    apply: (src) => {
      // Idempotence must be checked BEFORE the match: the patch appends AFTER
      // the matched call, so the anchor still matches an already-patched file
      // and would stack duplicate exposures on every engine upgrade.
      if (src.includes('exposeInMainWorld("__ZCODE_ACCENT__"')) return { src, count: -1 };
      const accent =
        '.contextBridge.exposeInMainWorld("__ZCODE_ACCENT__",' +
        '(process.argv.find(a=>a.startsWith("--zcode-accent="))||"").slice(15))';
      const title =
        '.contextBridge.exposeInMainWorld("__ZCODE_TITLE__",' +
        '(process.argv.find(a=>a.startsWith("--zcode-title="))||"").slice(14))';
      // v9 perf: v2-v8 matched with /([\w$]+)\.contextBridge\.exposeInMainWorld\("..."/
      // regexes, whose per-position word-run backtracking cost ~290 s across
      // the ~22k-entry ZCode bundle (the silent bulk of the old patch step).
      // The literal-needle indexOf + backward receiver scan is byte-equivalent
      // (the receiver capture is exactly the maximal [\w$]+ run immediately
      // before the literal, which is also the regex's leftmost capture) and
      // ~1000x faster.
      const BLUE_CALL =
        '.contextBridge.exposeInMainWorld("__ZCODE_BLUE__",process.argv.includes("--zcode-blue=1"))';
      const DEV_CALL = '.contextBridge.exposeInMainWorld("__ZCODE_DEVICE_ID__",';
      const isWordChar = (ch) => /[\w$]/.test(ch);
      const recvStartBefore = (litStart) => {
        let start = litStart;
        while (start > 0 && isWordChar(src[start - 1])) start--;
        return start;
      };
      // v5 -> v6 upgrade: extend the existing __ZCODE_BLUE__ exposure(s).
      const blueHits = [];
      let from = 0;
      for (;;) {
        const lit = src.indexOf(BLUE_CALL, from);
        if (lit === -1) break;
        const start = recvStartBefore(lit);
        blueHits.push({ start, end: lit + BLUE_CALL.length, recv: src.slice(start, lit) });
        from = lit + BLUE_CALL.length;
      }
      if (blueHits.length) {
        let out = src;
        // splice from last to first so earlier indices stay valid
        for (let i = blueHits.length - 1; i >= 0; i--) {
          const h = blueHits[i];
          out = out.slice(0, h.end) + "," + h.recv + accent + "," + h.recv + title + out.slice(h.end);
        }
        return { src: out, count: blueHits.length };
      }
      // Pristine: append after the __ZCODE_DEVICE_ID__ exposure call
      // (regex equivalent: recv + DEV_CALL + \s* + factory + "()))").
      const lit = src.indexOf(DEV_CALL);
      if (lit === -1) return { src, count: 0 };
      const start = recvStartBefore(lit);
      const recv = src.slice(start, lit);
      let p = lit + DEV_CALL.length;
      while (p < src.length && /\s/.test(src[p])) p++;
      let q = p;
      while (q < src.length && isWordChar(src[q])) q++;
      if (q === p || src.slice(q, q + 3) !== "())") return { src, count: 0 };
      const matched = src.slice(start, q + 3);
      const addition =
        matched + "," + recv +
        '.contextBridge.exposeInMainWorld("__ZCODE_BLUE__",process.argv.includes("--zcode-blue=1"))' +
        "," + recv + accent + "," + recv + title;
      return { src: src.slice(0, start) + addition + src.slice(q + 3), count: 1 };
    },
  },
  {
    name: "preload-bidi",
    min: 1,
    apply: (src) => {
      // Idempotence before the regex (same reason as preload-blue): this patch
      // appends after the matched call, so the anchor still matches a v7 file.
      if (src.includes("zcode-bidi-auto-style")) return { src, count: -1 };
      let count = 0;
      const out = src.replace(BIDI_ANCHOR, (m) => {
        count++;
        return m + BIDI_APPEND;
      });
      return { src: out, count };
    },
  },
  {
    name: "splash-html",
    min: 2, // identity script (class + window title + accent var) + CSS rule
    apply: (src) => {
      if (src.includes("var(--zcode-accent")) return { src, count: -1, markers: [] };
      // v6 identity script: class + "ZCode <title>" + --zcode-accent CSS var.
      // The Secondary's window reads "ZCode Blue"/"ZCode Yellow"/... in
      // Alt-Tab/taskbar/pins, which also prevents pin collisions with the
      // Primary's ZCode.lnk. No title env -> legacy "ZCode Blue".
      const v6Script =
        '<script>window.__ZCODE_BLUE__&&(document.documentElement.classList.add("zblue"),' +
        'document.title="ZCode "+(window.__ZCODE_TITLE__||"Blue"),' +
        'window.__ZCODE_ACCENT__&&document.documentElement.style.setProperty("--zcode-accent",window.__ZCODE_ACCENT__));</script>';
      const v5Script =
        '<script>window.__ZCODE_BLUE__&&(document.documentElement.classList.add("zblue"),document.title="ZCode Blue");</script>';
      const v6Css = "html.zblue .startup-logo { color: var(--zcode-accent," + BLUE_HEX + "); }";
      const v5Css = "html.zblue .startup-logo { color: " + BLUE_HEX + "; }";
      let out = src;
      const markers = [];
      let count = 0;
      if (out.includes(v5Script)) {
        // v5 -> v6 upgrade: swap script + CSS rule in place.
        out = out.split(v5Script).join(v6Script);
        count++;
        if (out.includes(v5Css)) {
          out = out.split(v5Css).join(v6Css);
          count++;
        }
        markers.push("html.zblue");
        return { src: out, count, markers };
      }
      // Pristine: inject AFTER <title> so document.title wins over the static tag.
      const titleAnchor = "<title>ZCode</title>";
      if (out.includes(titleAnchor)) {
        out = out.replace(titleAnchor, titleAnchor + v6Script);
        count++;
      } else if (out.includes("<head>")) {
        out = out.replace("<head>", "<head>" + v6Script);
      } else {
        return { src, count: 0, markers: [] };
      }
      const cssRe = /\.startup-logo \{[^}]*color: #ffffff;[^}]*\}/;
      const cssMatch = out.match(cssRe);
      if (!cssMatch) return { src, count: 0, markers: [] };
      out = out.replace(cssRe, cssMatch[0] + "\n      " + v6Css);
      count++;
      markers.push("html.zblue");
      return { src: out, count, markers };
    },
  },
  {
    name: "updater-secondary",
    min: 1,
    // The Secondary shares the patched app.asar with the Primary; its own
    // auto-update (quitAndInstall) would silently rewrite resources and strip
    // every patch mid-session. The Primary keeps updating normally.
    apply: (src) => {
      const done = "&&!process.env.ZCODE_ICON_DIR,onBeforeQuitAndInstall:";
      if (src.includes(done)) return { src, count: -1, markers: [done] };
      // v8: match both the bare gate (pre-3.16.3) and the conjunct gate
      // (3.16.3+: enabled:<x>==="production"&&<flag>). Appends the env guard
      // as an extra && term when the conjunct is present.
      const re = /enabled:(\w+)==="production"(&&[\w.]+)?,onBeforeQuitAndInstall:/;
      const m = src.match(re);
      if (!m) return { src, count: 0, markers: [] };
      const guard = m[2]
        ? "&&" + m[2].slice(2) + "&&!process.env.ZCODE_ICON_DIR"
        : "&&!process.env.ZCODE_ICON_DIR";
      const out = src.replace(
        m[0],
        "enabled:" + m[1] + '==="production"' + guard + ",onBeforeQuitAndInstall:",
      );
      return { src: out, count: 1, markers: [done] };
    },
  },
  {
    name: "sidebar-logo",
    min: 1,
    apply: (src) => {
      // v6 fill expression evaluated at render time: accent hex URL-escaped,
      // falling back to the flat blue. Lives inside the conditional blue URI's
      // template literal, so it nests as ${...}.
      const accentExpr =
        'window.__ZCODE_ACCENT__?window.__ZCODE_ACCENT__.replace("#","%23"):"' + BLUE_URI + '"';
      if (src.includes(accentExpr)) return { src, count: -1 };
      // v5 -> v6 upgrade: v5 hardcoded BLUE_URI inside the conditional blue
      // URIs (only our patch ever writes that escape). Swap every occurrence
      // for the accent expression - covers both fill='..' and fill:.. forms.
      if (src.includes(BLUE_URI)) {
        const replacement = "${" + accentExpr + "}";
        const n = src.split(BLUE_URI).length - 1;
        return { src: src.split(BLUE_URI).join(replacement), count: n };
      }
      if (src.includes("__ZCODE_BLUE__?`data:")) return { src, count: -1 };
      // the 18x18 data-URI carrying the Zai logo (unique path start M2.91528)
      const marker = "M2.91528";
      let searchFrom = 0;
      let patched = 0;
      let out = src;
      for (;;) {
        const pathAt = out.indexOf(marker, searchFrom);
        if (pathAt === -1) break;
        const uriStart = out.lastIndexOf("data:image/svg+xml", pathAt);
        if (uriStart === -1) {
          searchFrom = pathAt + marker.length;
          continue;
        }
        const uriEnd = out.indexOf("`", pathAt); // closing backtick of the template literal
        if (uriEnd === -1) {
          searchFrom = pathAt + marker.length;
          continue;
        }
        const oldUri = out.slice(uriStart, uriEnd);
        const blueUri = oldUri
          .split("fill='white'").join("fill='${" + accentExpr + "}'")
          .split("fill:white").join("fill:${" + accentExpr + "}");
        const replacement =
          "${window.__ZCODE_BLUE__?`" + blueUri + "`:`" + oldUri + "`}";
        out = out.slice(0, uriStart) + replacement + out.slice(uriEnd);
        patched++;
        searchFrom = uriStart + replacement.length;
      }
      return { src: out, count: patched };
    },
  },
  {
    name: "react-badge",
    min: 1,
    apply: (src) => {
      const done = "window.__ZCODE_BLUE__?window.__ZCODE_ACCENT__||`" + BLUE_HEX + "`:`currentColor`";
      if (src.includes(done)) return { src, count: -1 };
      // v5 -> v6 upgrade: hardcoded blue ternary -> accent-driven ternary.
      const v5 = "window.__ZCODE_BLUE__?`" + BLUE_HEX + "`:`currentColor`";
      if (src.includes(v5)) {
        const n = src.split(v5).length - 1;
        return { src: src.split(v5).join(done), count: n };
      }
      const paths = ["M134.4 0.130152", "M256 0.130127", "M121.601 217.732"];
      let count = 0;
      let out = src;
      for (const p of paths) {
        const anchor = "fill:`currentColor`,d:`" + p;
        if (!out.includes(anchor)) continue;
        out = out.split(anchor).join(
          "fill:" + done + ",d:`" + p,
        );
        count++;
      }
      return { src: out, count };
    },
  },
];

const T0 = process.hrtime.bigint();
const lap = (from) => Number(process.hrtime.bigint() - from) / 1e6;
const timings = {};
// GHOST_PATCH_DEBUG=1 -> per-patch accumulated timings + progress on STDERR
// (stdout stays pure JSON for the PS driver).
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
        appliedMarkers.push(...(r.markers ?? markersForPatch(patch.name)));
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

function markersForPatch(name) {
  switch (name) {
    case "icon-window":
    case "icon-tray":
      return ["ZCODE_ICON_DIR"];
    case "aumid-suffix":
      return ["ZCODE_AUMID_SUFFIX"];
    case "main-args":
      return ["--zcode-blue=", "--zcode-accent=", "--zcode-title="];
    case "preload-blue":
      return ["__ZCODE_BLUE__", "__ZCODE_ACCENT__", "__ZCODE_TITLE__"];
    case "preload-bidi":
      return ["zcode-bidi-auto-style"];
    case "splash-html":
      return ["html.zblue", "--zcode-accent", "__ZCODE_TITLE__"];
    case "sidebar-logo":
      return ["__ZCODE_BLUE__?`data:", "__ZCODE_ACCENT__?window.__ZCODE_ACCENT__.replace"];
    case "react-badge":
      return ["window.__ZCODE_BLUE__?window.__ZCODE_ACCENT__||"];
    default:
      return [];
  }
}

if (failures.length) {
  console.log(JSON.stringify({ ok: false, engineVersion: ENGINE_VERSION, totals, results, error: "zero patch sites: " + failures.join(",") }));
  process.exit(1);
}

// 2. Syntax gate: node --check every patched js/cjs/mjs BEFORE rebuilding
// (markers alone cannot catch a structurally broken bundle - the v3
// main-args bug shipped valid markers with a dead main process). The check
// runs on temp copies under checksDir; the candidate asar is not written yet.
const tSyntax = process.hrtime.bigint();
mkdirSync(checksDir, { recursive: true });
const syntaxFailures = [];
for (const r of results) {
  if (!/\.(js|cjs|mjs)$/.test(r.file)) continue;
  const content = patchedContents.get(r.file);
  // Already-applied sites (count -1) changed nothing in this run; their
  // content is the previous engine's output (or pristine vendor bytes on a
  // -Force pristine rebuild) - v8 re-checked the on-disk copy, which is the
  // same bytes, so skipping unchanged files here is behavior-identical.
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
  // rebuild re-reads each candidate entry; hand back the already-patched text
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
