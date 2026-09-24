#!/usr/bin/env node
// ZCode blue-branding patch engine — pure text transforms on an EXTRACTED asar tree.
// Usage: node patch_zcode_icon_override.mjs <extractedDir>
// Prints a JSON result on stdout; exit 0 = all patches applied or already applied,
// exit 1 = any patch found zero sites (tree left untouched).
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
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";

const ENGINE_VERSION = 6;
const extractedDir = process.argv[2];
if (!extractedDir) {
  console.error(JSON.stringify({ ok: false, error: "usage: patch_zcode_icon_override.mjs <extractedDir>" }));
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
      // Idempotence must be checked BEFORE the regex: the patch appends AFTER
      // the matched call, so the regex still matches an already-patched file
      // and would stack duplicate exposures on every engine upgrade.
      if (src.includes('exposeInMainWorld("__ZCODE_ACCENT__"')) return { src, count: -1 };
      const accent =
        '.contextBridge.exposeInMainWorld("__ZCODE_ACCENT__",' +
        '(process.argv.find(a=>a.startsWith("--zcode-accent="))||"").slice(15))';
      const title =
        '.contextBridge.exposeInMainWorld("__ZCODE_TITLE__",' +
        '(process.argv.find(a=>a.startsWith("--zcode-title="))||"").slice(14))';
      // v5 -> v6 upgrade: extend the existing __ZCODE_BLUE__ exposure(s).
      const reBlue = /([\w$]+)\.contextBridge\.exposeInMainWorld\("__ZCODE_BLUE__",process\.argv\.includes\("--zcode-blue=1"\)\)/g;
      if (reBlue.test(src)) {
        let count = 0;
        const out = src.replace(reBlue, (m, recv) => {
          count++;
          return m + "," + recv + accent + "," + recv + title;
        });
        return { src: out, count };
      }
      const re = /([\w$]+)\.contextBridge\.exposeInMainWorld\("__ZCODE_DEVICE_ID__",\s*([\w$]+)\(\)\)/;
      const m = src.match(re);
      if (!m) return { src, count: 0 };
      const addition =
        m[0] + "," + m[1] +
        '.contextBridge.exposeInMainWorld("__ZCODE_BLUE__",process.argv.includes("--zcode-blue=1"))' +
        "," + m[1] + accent + "," + m[1] + title;
      return { src: src.replace(m[0], addition), count: 1 };
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
      const re = /enabled:(\w+)==="production",onBeforeQuitAndInstall:/;
      const m = src.match(re);
      if (!m) return { src, count: 0, markers: [] };
      const out = src.replace(
        m[0],
        "enabled:" + m[1] + '==="production"&&!process.env.ZCODE_ICON_DIR,onBeforeQuitAndInstall:',
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
      appliedMarkers.push(...(r.markers ?? markersForPatch(patch.name)));
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

console.log(JSON.stringify({ ok: true, engineVersion: ENGINE_VERSION, totals, results }));
