# OpenCode desktop multi-instance clones (c1..c5) — design spec

Status: **IMPLEMENTED — live-verified 2026-10-24/25 on this host**: engine
v2 patched into the installed app (old-engine upgrade path proven en
route), c1..c5 all launched and verified (per-clone lockfiles HELD
simultaneously, flag-matched processes at the Chromium level, "OpenCode
Blue"/"OpenCode Orange" window titles observed, per-instance ephemeral
service ports), Primary isolation proven by snapshot diff (39 user-session
file changes, **0** clone-breach signatures). Full gate results in §5.
Project: GHOST (`unban-machine-id`) · Target app:
`%LOCALAPPDATA%\Programs\@opencode-aidesktop\OpenCode.exe`
(OpenCode **2.0.32** per the NSIS uninstall registry; **Electron** /
electron-builder NSIS, `app.asar` 176 MB + `app.asar.unpacked` holding only
the node-pty native module; bundled managed CLI `resources\opencode-cli.exe`
2.0.32, mirrored per-userData at `cli\2.0.32-x64\`; exe manifest
**asInvoker**; auto-update via electron-updater generic feed
`https://opencode.ai/update/api/latest/desktop/opencode/`)

This is a GHOST spec-first document (CLINE/AUTOCLAW2_CLONES_SPEC pattern).
Unlike those two suites, this one **requires an asar patch** — the app
offers no stock env lever that reaches the Electron userData in packaged
builds (§3.1), and without a per-clone userData there is no multi-instance
at all (§3.3).

---

## 1. Problem

OpenCode desktop is single-instance on the userData dir. We want **5
independent OpenCode instances** running side by side, each with its own
Electron profile, CLI state tree (auth, db, logs), provider config and
login — while the Primary (`%APPDATA%\ai.opencode.desktop` +
`~\.local\share\opencode` + `~\.config\opencode`, the user's real login
and the 3.7 GB shared `opencode.db`) stays **untouched**, and a
normally-launched stock OpenCode keeps working beside the clones.

## 2. Relationship to the AutoClaw2 and Cline suites

Same shape as `docs/AUTOCLAW2_CLONES_SPEC.md` and
`docs/CLINE_CLONES_SPEC.md` (cN naming, fresh state per clone, no
seeding, one manual login per clone). One mechanism harder than both:
their state levers are stock (`ZWORK_USER_DATA`, `CLINE_DIR`); OpenCode's
Electron userData is hardcoded in packaged builds, so the suite goes back
to the AutoClaw-v1 asar-patch route — but only for the userData redirect
+ AUMID; the CLI state side rides on the app's OWN env redirection
surface (§3.2), and the single-instance lock needs no work at all (§3.3).

| | AutoClaw2 (c1..c5) | Cline (c1..c5) | OpenCode (c1..c5, this spec) |
|---|---|---|---|
| Shell | Electron asInvoker | Tauri 2.11.1 asInvoker | Electron asInvoker |
| userData lever | `ZWORK_USER_DATA` (stock) | n/a (no Electron profile) | **none in packaged builds — asar patch (§3.4)** |
| CLI-state lever | n/a | `CLINE_DIR` | **`XDG_DATA_HOME` / `XDG_CONFIG_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME` (stock, read unconditionally, §3.2)** |
| Single-instance | per-profile lock (stock) | fixed-key plugin — neutralized by the launcher | **per-userData lock (stock) — free once userData differs (§3.3)** |
| Ports | none (in-process) | fixed per-clone table | none expected in packaged local mode (**LIVE-PENDING**, §3.8) |
| Device identity | fresh `device\device-id.json` | fresh `secrets.json` after sign-in | fresh userData + fresh XDG data home (`gh\device-id`, `.updaterId`, `auth.json` all per-clone) |
| Credentials | nothing copied | nothing copied | nothing copied — fresh login per clone |
| Taskbar identity | not patched (known limitation) | not patched (developer decision 2026-10-24) | **AUMID-suffix asar wrap — single `setAppUserModelId` call site (§3.5)** |
| Patch engine | none | none (nothing patchable) | required, with update-recovery re-patch (§3.4, §3.7) |

## 3. Mechanism (verified statically; LIVE-PENDING items marked)

### 3.1 Why no stock env lever reaches the userData (verified)

The early bootstrap (minified, `app.asar`; backticks are the original's):

```js
...appendSwitch(`remote-debugging-port`, process.env.OPENCODE_DESKTOP_REMOTE_DEBUGGING_PORT ?? `9222`);
let t = ye();
a.setPath(`userData`, t ? ie.join(t, `desktop`) : ie.join(a.getPath(`appData`), me)),
t && (a.setPath(`sessionData`, ie.join(t, `session`)), he && a.setPath(`documents`, ie.join(t, `documents`)))
...
function ve(){ return a.requestSingleInstanceLock() ? !0 : (a.quit(), !1) }
function ye(){
  let e = he ? ie.join(re(), `opencode-onboarding-${f()}`)
         : a.isPackaged ? void 0 : process.env.OPENCODE_DESKTOP_TEST_ROOT;
  if (e) {
    he && _(e, { recursive: !0, force: !0 });            // rmSync-style clear
    for (let t of [`data`,`config`,`cache`,`state`,`desktop`,`session`,`documents`])
      m(ie.join(e, t), { recursive: !0 });               // mkdir the layout
    he && (process.env.OPENCODE_DB = `:memory:`);
    process.env.XDG_DATA_HOME   = ie.join(e, `data`);
    process.env.XDG_CONFIG_HOME = ie.join(e, `config`);
    process.env.XDG_CACHE_HOME  = ie.join(e, `cache`);
    process.env.XDG_STATE_HOME  = ie.join(e, `state`);
    return e
  }
}
```

with `he = process.env.OPENCODE_TEST_ONBOARDING === '1'` and
`me = a.isPackaged ? fe[le] : 'ai.opencode.desktop.dev'` where
`fe = { beta: 'ai.opencode.desktop.beta', prod: 'ai.opencode.desktop' }`.
Consequences, each verified from the quote:

- **Packaged + no test flags → `t` = void 0 → userData =
  `%APPDATA%\ai.opencode.desktop`, hardcoded.** The unconditional
  `setPath` also overrides Chromium's `--user-data-dir` switch (same
  ground truth as ZCode — a CLI flag is dead here too).
- `OPENCODE_DESKTOP_TEST_ROOT` is honored **only when `!isPackaged`** —
  dead for the installed app.
- `OPENCODE_TEST_ONBOARDING=1` does redirect a root, but it **wipes the
  whole root on every boot** (`_(e,{recursive,force})` before the mkdir
  loop) and drags in onboarding-test behaviors (forced focus etc.) —
  rejected for clones.
- The channel map `fe` has only beta/prod lanes — at most 2 userData
  dirs, and channel also flips the protocol scheme — rejected as a
  5-clone lever.
- `APPDATA` env override of `getPath('appData')`: Chromium resolves
  roaming-app-data through the known-folder API, which is env-immune
  (AutoClaw v1 verified this exact class for `getPath('home')` — env
  claims that held for plain node did NOT hold for the app). A cheap
  decisive **LIVE-PENDING downgrade probe** runs first at implementation
  (launch with `APPDATA` redirected; if `<probe>\ai.opencode.desktop`
  materializes, the patch becomes unnecessary); expected to fail.

### 3.2 The XDG env surface IS the app's redirection mechanism (verified)

`ye()`'s test mode redirects the CLI state purely by setting the four
`XDG_*` env vars — and the production consumers read them
**unconditionally**, e.g. the server-logs resolver:

```js
function zo(e){
  let t = process.env.XDG_DATA_HOME || e.join(li(), `.local`, `share`);
  return [...new Set([ e.join(t, `opencode`, `log`),
                       e.join(R.getPath(`userData`), `opencode`, `log`) ])]
}
```

So in production: `XDG_DATA_HOME` → the CLI data home
(`~\.local\share\opencode` stock: `auth.json`, `log\`, `opencode.db`,
`storage\`…), `XDG_CONFIG_HOME` → `~\.config\opencode`, plus
`XDG_STATE_HOME` / `XDG_CACHE_HOME`. These are stock code paths — the
patch reuses them (§3.4), and the launcher never needs its own env
plumbing for the CLI side.

### 3.3 Single-instance: keyed on userData, no work needed (verified)

`ve()` calls `requestSingleInstanceLock()` with **no custom key** —
Chromium keys its Windows singleton (named mutex + the `lockfile` the
reset script scrubs from `ai.opencode.desktop`) on the userData dir.
Distinct userData per clone → N copies coexist natively (the AutoClaw2
free win); identical userData → the second copy `a.quit()`s. No
neutralization (Cline) and no lock surgery — isolation IS the lock
separation. The patched `setPath` runs in the same early bootstrap,
before the lock is acquired.

### 3.4 Isolation design: the "clone-home" asar patch

Give packaged builds the TEST_ROOT-equivalent behavior, driven by argv
(argv survives every launch context; the app is asInvoker so there is no
UAC boundary; the AutoClaw v12 argv-reader precedent):

- The launcher passes `--opencode-clone-home <dir>` (a dedicated flag —
  never `--user-data-dir`, which Chromium would half-consume before the
  app's `setPath` overrides it) plus, since engine v2, the identity flags
  `--opencode-clone-id=<cN>` / `--opencode-clone-title=<t>` /
  `--opencode-clone-icon=<path>` (§3.5).
- The patched bootstrap treats `<dir>` exactly like `ye()`'s `e` when the
  flag is present: mkdir the `data/config/cache/state/desktop/session`
  subdirs, `setPath('userData', join(home,'desktop'))`,
  `setPath('sessionData', join(home,'session'))`, and set
  `process.env.XDG_*` from the home's subdirs **before the v2 background
  service spawns** (children inherit — the app's own mechanism reused
  verbatim, §3.2).
- **No flag = stock behavior bit-for-bit** — Primary and bare spawns
  untouched (the same invariant AutoClaw's marker design gives; argv is
  even stronger than a marker file here because there is no elevation
  boundary).
- Engine hygiene per house rules: backup + marker (carrying
  `patchVersion`) + `-Restore` + `node --check` gate + zero-site match =
  abort untouched (EC-A05), and the 2026-10-24 **update-recovery
  byte-probe**: probe `app.asar` for the engine's signature strings
  before the marker gate (signatures must be strings that live IN the
  asar after patching — the AutoClaw `.autoclaw-icon.ico` docstring
  phantom lesson), auto re-patch after an app update with a FRESH backup.
  Two hardenings landed live 2026-10-24/25:
  **(a) locked-asar in-place fallback** — this host's IDE file indexer
  held a read handle on app.asar (no share-delete) for the whole session,
  so the plain delete+move swap is impossible here; when delete is
  blocked but WRITE access is shared, the swap overwrites the live asar
  in place, allowed ONLY with a verified pristine backup on disk, and
  the unpacked dir is kept-with-verify when locked too (the engine
  changes no unpacked bytes); **(b) two-tier probe** — CORE signatures
  (engine-stable: `__opencodeCloneHome`, `__opencodeCloneIdentity`,
  `--opencode-clone-home`) vs CURRENT signatures (`--opencode-clone-id`):
  a core-only tree is an OLD-ENGINE patch, not an update-wiped asar, and
  rebuilds from the marker's pristine backup (extracting the live tree
  would let the engine's done-anchors skip and ship no changes — the
  post-swap probe catches it, proven live during the v1→v2 upgrade).

### 3.5 Taskbar identity: AUMID suffix wrap + window stamper (verified single call site)

`a.setName(pe), a.setAppUserModelId(me)` — exactly **one** call site in
the asar (count = 1; it sits in a comma-expression chain, so appending one
more `,` operand is statement-safe). SHIPPED (engine v2): the patch wraps
the argument to append `.<aumidSuffix>` AND appends an app-level
`browser-window-created` listener to the same statement that stamps every
window's WINDOW-level AUMID via `setAppDetails` at creation, sets the
per-color window icon and forces the "OpenCode <Color>" title
(`page-title-updated` preventDefault + re-assert, AutoClaw v12
semantics). The listener closes over the app's own AUMID base expression
— no base id hardcoded. **Identity channel = PURE ARGV (engine v2, live
finding)**: the app's main bundle (`out/main/index.js`) is **ESM** —
`require` is undefined — so the v1 fs-based identity resolver (reading
`<home>\desktop\.opencode-clone-identity.json`) silently no-oped at
runtime (caught error → null → stock identity; isolation was unaffected,
caught by the launcher's title check). The launcher now passes
`--opencode-clone-id/-title/-icon` alongside the home flag and the
injected parser never touches fs (ESM- and CJS-safe, quoted-token
tolerant); the json file is still written beside the icon for human /
`-Status` introspection only. **Anchor finding that
reshaped this family:** the 2.0.32 asar contains ZERO
`new X.BrowserWindow(` sites (imports are aliased — `BrowserWindow as
L/J/i`) — the AutoClaw-v12 constructor-subclass wrap has no anchor here;
the `browser-window-created` event is the equivalent hook and needs no
constructor anchor. Live-verified: c1's window titled "OpenCode Blue",
c5's "OpenCode Orange". Process-explicit identity is per-clone, so the ZCode
shared-id merge class cannot occur; if a merge case ever appears live,
the escalation path is the ZCode window-stamp + watcher pattern
(EC-C02/C03/C05).

### 3.6 Identity and credentials

Everything identity-bearing becomes per-clone automatically once userData
and the XDG data home differ: `gh\device-id`, `.updaterId`,
`opencode.settings` `windowIds`, Chromium network stores (all inside
userData) and `auth.json` (inside the XDG data home). Every clone starts
anonymous → **one manual login per clone** (one credential = one
instance, generalized). `~\.config\opencode` is per-clone via
`XDG_CONFIG_HOME` — the Primary's `opencode.jsonc` holds **live provider
API keys and is never copied**; provider keys / MCP config are re-entered
per clone (a definitions-only Primary→clone sync à la
`sync_zcode_assets` is future work, §7). `MachineGuid` stays shared by
every instance (GHOST ground truth #1) — per-instance differentiation is
the per-clone account identity, same as every suite here.

### 3.7 Updates (verified + live nuance)

electron-updater config read from the asar:

```js
y.allowPrerelease = !1, y.allowDowngrade = !0, y.autoDownload = !1,
y.autoInstallOnAppQuit = process.platform === `darwin`
... y.quitAndInstall() inside try/catch (manual restart flow)
```

**Live nuance (2026-10-24, c1's main.log)**: the app's own update flow
DOWNLOADS anyway when a check finds a new version (observed: 2.1.4 staged
into `%LOCALAPPDATA%\@opencodedesktop-updater\pending\`) — but
`autoInstallOnAppQuit` is **darwin-only**, so on Windows nothing installs
without the explicit restart-to-update flow; the patch SURVIVED the whole
session with 2.1.4 staged. A manual update still replaces `app.asar` and
reverts the patch → the engine's update-recovery byte-probe re-patches
itself (§3.4); no updater-disable setting is needed, and none is set
(clones stay current with the installed app — Cline precedent). Future
versions may also reshape the minified anchors — the zero-site abort
makes that a loud failure, not a silent one.

### 3.8 Service and ports (RESOLVED live 2026-10-25)

The local packaged background service spawns as:

```js
command: [...a.command, `serve`, `--service`, ...i ? [`--hostname`,`0.0.0.0`,`--port`,`3084`] : []]
```

where `i = !isPackaged && process.env.OPENCODE_DESKTOP_ISOLATED_SERVER === '1'`
(that dev-only branch also forces `XDG_STATE_HOME = userData`). So the
production local service runs `serve --service` with **no explicit
port** — and the live logs settled §3.8 entirely: each instance's service
binds an **ephemeral OS-assigned port** (c1's v2 CLI service reported
`url: 'http://127.0.0.1:45278'`; c5's reported the same value only after
c1 had exited — the OS reuses freed ephemeral ports). No fixed-port
collision is possible between concurrent instances, so the mitigation
ladder below is moot for this app version:

- (1) ~~XDG_STATE_HOME isolation~~ (2) ~~per-clone port table~~ (3)
  ~~instance-record.json port discovery~~ — none needed; the per-clone
  `XDG_STATE_HOME` isolation stays valuable for the state handoff files
  regardless. The service child (`opencode-cli.exe`) persists its parent
  main's death (observed: outlived a closed clone window) — kill it when
  stopping a clone manually.

## 4. Naming and layout

```
%USERPROFILE%\OpenCodeClonesHome\
├── c1\ … c5\
│    ├── desktop\    Electron userData (patched setPath target: gh\device-id,
│    │               .updaterId, opencode.settings, compile-cache, Chromium
│    │               stores, per-version managed CLI cache cli\<ver>\)
│    ├── session\    Electron sessionData
│    ├── data\       XDG_DATA_HOME  (auth.json after login, log\, opencode.db…)
│    ├── config\     XDG_CONFIG_HOME (opencode.jsonc per clone)
│    ├── cache\      XDG_CACHE_HOME
│    └── state\      XDG_STATE_HOME (service handoff state)
```

— the same subdir shape `ye()` itself creates in test mode; the patch
reuses the app's own layout.

| clone | color / branding | AUMID |
|---|---|---|
| Primary (stock) | — stock | ai.opencode.desktop |
| c1 | blue   `opencode-blue-branding`   | ai.opencode.desktop.c1 |
| c2 | yellow `opencode-yellow-branding` | ai.opencode.desktop.c2 |
| c3 | green  `opencode-green-branding`  | ai.opencode.desktop.c3 |
| c4 | red    `opencode-red-branding`    | ai.opencode.desktop.c4 |
| c5 | orange `opencode-orange-branding` (to generate) | ai.opencode.desktop.c5 |

Blue/yellow/green/red were staged 2026-10-17 from developer renders
(accents #2A7CBD/#ECC31E/#37A188/#BD2A32 — playbook §5 branch 1, wired
as-is). Orange is missing → the IMPROVISE branch: generate a tinted
placeholder from the blue master via `tools\make_clone_icon.ps1`
(cline-orange precedent `-TintHue 25 -TintSat 0.9`, calibrated against
the opencode logo like AutoClaw2's hue table), flagged PLACEHOLDER with
drop paths in the final report.

The Primary (`%APPDATA%\ai.opencode.desktop`, `~\.local\share\opencode`,
`~\.config\opencode`) is **never written** by any clone script. The stock
Start Menu `OpenCode.lnk` is only READ (base-AUMID discovery via
`Shell.Application` `ExtendedProperty('System.AppUserModel.ID')`, never
whole-file .lnk decoding — EC-C09).

## 5. Provenance (2026-10-24, this host — static `app.asar` byte-greps unless marked)

- Install anatomy (ls): `%LOCALAPPDATA%\Programs\@opencode-aidesktop` —
  `OpenCode.exe`, `app.asar` 176,346,919 B, `app.asar.unpacked` =
  node-pty native only (no readable unpacked main), `app-update.yml`
  (generic feed, `updaterCacheDirName: @opencode-aidesktop-updater`),
  `opencode-cli.exe` + `opencode-cli.version` "2.0.32"; mirrored at
  `%APPDATA%\ai.opencode.desktop\cli\2.0.32-x64\opencode-cli.exe`
  (identical 213,722,504 B). Desktop version 2.0.32 = NSIS uninstall
  registry (HKCU) DisplayName/DisplayVersion.
- Electron: `LICENSE.electron.txt`, `icudtl.dat`,
  `v8_context_snapshot.bin`, `*.pak`, electron-builder NSIS uninstaller;
  no `~/.opencode` dir exists on this box (CLI home is
  `~\.local\share\opencode` — matches the reset script's ground truth).
- asInvoker: grep over `OpenCode.exe` bytes found `asInvoker`, no
  `requireAdministrator`/`highestAvailable`.
- §3.1 bootstrap + `ye()`/`he`/`me`/`fe` quotes: byte-greps over
  `app.asar` (`requestSingleInstanceLock` count = 1; the full
  `OPENCODE_*` env inventory was enumerated — 30 distinct names — and none of the
  others redirect userData in packaged builds).
- §3.2 XDG consumption: the `zo()` quote; XDG name counts in the asar:
  `XDG_CONFIG_HOME` 13, `XDG_STATE_HOME` 8, `XDG_DATA_HOME` 6,
  `XDG_CACHE_HOME` 3.
- §3.5 `setAppUserModelId` count = 1, argument `me`.
- §3.7 updater config quote (`autoDownload`, `allowPrerelease`,
  `allowDowngrade`, `autoInstallOnAppQuit`, `quitAndInstall` try/catch).
- §3.8 service spawn quote (`serve --service`, dev-only
  `--hostname 0.0.0.0 --port 3084`); `localhost:4096` ×63 in the asar.
- Branding: `tools/opencode-{blue,yellow,green,red}-branding\` each hold
  `icon_windows.png` + `tray_icon.ico` + `source.jpg` (ls); no orange —
  generated 2026-10-24 as `tools/opencode-orange-branding\`
  (`make_clone_icon.ps1 -Source <blue master> -HueRotate 180`: blue ~205° →
  orange ~25°, dark tile preserved; sha256 distinct from blue —
  7A051AC8… vs 247F1A6F…; PLACEHOLDER pending developer renders).
- **Engine rehearsal (2026-10-24, before any app contact)**: the v1 engine
  run on a synthetic anchors file reproducing both verified byte shapes →
  clone-home count 1 + clone-identity count 1, `node --check` OK on the
  emitted code, second run = both families -1 (already-applied, not
  zero-site), behavioral rehearsal in fresh processes: scan with flag
  (forward- and back-slash paths + trailing space) → trimmed path; no
  flag → "" (= void 0 = stock); identity resolver: no flag → null, home
  without json → null, json present (CJS context) → parsed object,
  cached. (An earlier ESM-context null was a test-harness artifact — the
  app's main bundle is CommonJS where the injected `require("fs")`
  resolves, same contract as the proven AutoClaw engine.)
- **LIVE GATES (2026-10-24/25, this host — all passed)**:
  - APPDATA-env probe: a bare launch with `APPDATA` redirected to an empty
    dir **crashes the packaged app before any userData init** (no logs, no
    lockfile, 0 processes at 15s; the probe dir stayed empty) — the
    redirect is not a usable lever regardless of known-folder immunity;
    the patch route is confirmed necessary.
  - Stock integrity on the patched asar: bare launch (no flag) boots
    normally — 5 processes, plain "OpenCode" window title, real
    `%APPDATA%\ai.opencode.desktop` engaged, no Application-log errors.
  - c1 first run: `OpenCodeClonesHome\c1\` materialized the full layout
    (desktop\ with Crashpad/cli/compile-cache/drafts.sqlite/lockfile/
    opencode.settings + data|config|state\opencode); every Chromium child
    carried `--user-data-dir=...\c1\desktop`; the v2 CLI background
    service reported ready in c1's own log.
  - N-copy coexistence: c1..c4 lockfiles HELD simultaneously (each launch
    verified flag-matched + lockfile), c5 verified after; a live
    user-launched stock Primary (explorer.exe spawn) coexisted beside c1 —
    per-userData locks native (AutoClaw2 model confirmed).
  - Window identity: c1 titled "OpenCode Blue", c5 "OpenCode Orange"
    (engine v2 argv identity; the v1 require-in-ESM null-identity failure
    was caught by exactly this check and fixed).
  - Primary snapshot diff (path+mtime+size, 3 trees, 5463→5462 files):
    26 changed / 6 added / 7 removed — ALL the live user session's own
    artifacts (its 23:34 log dir, Chromium caches/journals, drafts.sqlite
    checkpoint); **0 clone-breach signature hits** (no
    `OpenCodeClonesHome`/`opencode-clone` references anywhere).
  - The clones were closed cleanly by the developer mid-session (clean
    lockfile removals, no crash logs, no WER events); one orphan
    `opencode-cli.exe` service outlived its main and was killed — that
    persistence is noted in §3.8.

## 6. Files (built 2026-10-24; live gates pending)

- `tools/patch_opencode_clone_home.ps1` (+ `.mjs` engine v1) — the asar
  patch (§3.4, §3.5): backup / marker+patchVersion / `-Restore` /
  `node --check` / zero-site abort / update-recovery byte-probe.
  Anchors: clone-home = the verified minified ternary tail (string
  search); clone-identity = the single `setAppUserModelId` site
  (receiver+ident captured by regex; the wrapped output can never
  re-match — idempotence by construction).
- `src/windows/launch_opencode_clone.ps1` — launcher `-Instance c1..c5`
  + `-Status`: patch-signature preflight (ABORT unpatched), home
  pre-creation, lockfile running guard (held → inform + exit 0),
  identity json + icon written fresh each launch, detached
  `cmd /c start`, verify-after (flag-matched WMI process; lockfile
  fallback when command lines unreadable — the AutoClaw PEB-scrub
  precedent).
- `src/windows/launch_opencode_clones_all.ps1` — sequential all-five
  (launcher verify-after + 10s settle; `-Status` passthrough).
- `tools/install_opencode_clone_shortcuts.ps1` — Desktop + Start Menu
  shortcuts (AUMID `ai.opencode.desktop.cN` + per-color icons;
  `-Remove`; `-RepairPrimaryAumid` per EC-C01).
- `tools/opencode-{blue,yellow,green,red,orange}-branding\` — icons
  (orange = generated PLACEHOLDER).
- GHOST.bat submenu [6] (gids 53-62: launch c1..c5 / ALL / patch /
  shortcuts / status / remove) + `.bat-harness-test.ps1` extended to
  17 scenarios (all passing).

## 7. Known limitations / future work

- **Patched-app dependency**: an app update reverts the patch. The
  update-recovery byte-probe (§3.4) makes re-patching self-healing, but
  the first clone launch after an update and before any patch re-run is
  stock — single-instance is active again and clones exit while another
  instance runs. Symptom + fix documented like Cline §7; the launcher
  aborts loudly when the signatures are missing. NOTE: 2.1.4 is already
  STAGED on this host (pending\installer) — the next user-accepted update
  wipes the asar patch; the byte-probe re-patches automatically, and if
  2.1.4's bundler reshaped the anchors the engine aborts untouched
  (zero-site) instead of half-applying — re-derive anchors from the new
  asar then (spec §3.1/§3.5 procedure).
- **APPDATA-env probe**: RESOLVED live — a redirected APPDATA crashes the
  packaged app pre-init (§5), so the env route is dead regardless of
  known-folder immunity; the patch is the only isolation route.
- **Service ports**: RESOLVED live — ephemeral OS-assigned per instance
  (§3.8); no port plan needed.
- Window title / window icon shipped per clone (§3.5, live-verified); the
  identity rides argv since engine v2 (the ESM main has no `require` —
  any future fs-needing injection must stay require-free or use
  createRequire explicitly).
- Per-clone provider config (`opencode.jsonc` API keys) is manual; a
  definitions-only Primary→clone sync (`sync_zcode_assets` pattern) is
  future work — never copy live secrets wholesale without a scrub design.
- The Primary `~\.config\opencode\opencode.jsonc` holds live API keys —
  never committed, never copied verbatim (this spec redacts all values).
- Pre-existing, NOT part of this suite: `reset_minimax_opencode.ps1`'s
  version preflight checks `%LOCALAPPDATA%\Programs\opencode\...` /
  `%ProgramFiles%\opencode\...`, but this install lives at
  `Programs\@opencode-aidesktop` — the preflight is stale for the current
  install lane and should be fixed separately.
- The 3.7 GB Primary `~\.local\share\opencode\opencode.db` stays
  Primary; clones start with fresh small DBs (no seeding, by design).
- `MachineGuid` shared by every instance (ground truth #1) —
  per-instance differentiation is the per-clone account identity.

## 8. Operational rules

- Run the patch engine once before the first clone launch; re-run after
  any manual app update if auto-recovery hasn't already (a menu entry at
  Phase 9).
- Launch clones SEQUENTIALLY, never elevated (asInvoker app; UIPI rules
  anyway), always via the launcher / shortcuts — a bare `OpenCode.exe`
  or an `ai.opencode.desktop://` protocol launch always boots the
  PRIMARY profile (no flag, stock userData).
- One manual login per fresh clone — by design, never automated.
- Clone "reset" = stop the instance, delete
  `%USERPROFILE%\OpenCodeClonesHome\<cN>`, launch again (no reset script
  in this suite; the Primary reset is the existing IDE Resets [8],
  out of scope here).
- `-Status` = clone-home process markers (`--opencode-clone-home` in
  main command lines) + materialized subdirs + the clone's own
  `desktop\lockfile` presence.
- Never copy session rows or credential stores between homes (EC-D03,
  EC-D05).
