# Cline desktop multi-instance clones (c1..c5) — design spec

Status: **IMPLEMENTED** — shipped 2026-10-24 (see CHANGELOG). Live-verified
the same day on this host: 3 clones concurrently beside a clean `~\.cline`
(120-file snapshot diff = 0 across the whole session), per-clone state
trees + WebView2 profiles + hub/sidecar ports, single-instance guard
neutralized, full cleanup verified (0 processes, 0 ports, mutex released).
Project: GHOST (`unban-machine-id`) · Target app:
`%LOCALAPPDATA%\Cline\cline-app.exe` (window title "Cline v0.0.48"; Tauri
2.11.1 / wry / WebView2 — **not** Electron, **no asar anywhere**;
agent core numbering 4.1.21; backend `bin\desktop-backend\index.js` +
`cline-cli.exe` (Bun SEA) children; manifest has **no
requestedExecutionLevel ⇒ asInvoker**)

This is a GHOST spec-first document (AUTOCLAW2_CLONES_SPEC pattern).
Every mechanism below was read out of the installed app's files or
live-verified on this host (provenance §5).

---

## 1. Problem

Cline desktop is single-instance by plugin. We want **5 independent
Cline instances** running side by side, each with its own state tree,
web login session, hub daemon, ports and sign-in — while the Primary
(`~\.cline`, the user's real account + 46 MB of session/hub databases)
stays **untouched**, and a normally-launched stock Cline keeps working
beside the clones.

## 2. Relationship to the AutoClaw2 suite

Same shape as `docs/AUTOCLAW2_CLONES_SPEC.md` (cN naming, env-only
isolation, fresh profile per clone, no seeding, no patch engine), one
mechanism harder: AutoClaw2's lock is pinned to the env-overridable
userData dir **before** the single-instance lock; Cline's single-instance
key is FIXED (the app identifier), so the launcher neutralizes its
hidden window instead (§3.2).

| | AutoClaw2 (c1..c5) | Cline (c1..c5) |
|---|---|---|
| Shell | Electron asInvoker | **Tauri 2.11.1** asInvoker (WebView2, no asar) |
| State lever | `ZWORK_USER_DATA` | **`CLINE_DIR`** (whole `~\.cline` tree) |
| Web-session lever | n/a (in userData) | **`WEBVIEW2_USER_DATA_FOLDER`** (stock: `%LOCALAPPDATA%\bot.cline.app`) |
| Ports | none (in-process) | **`CLINE_HUB_PORT` + `CLINE_SIDECAR_PORT`** per clone (stock 25463..25466 / 3126) |
| Single-instance | per-profile lock (official) | fixed-key plugin — **neutralized by the launcher** (§3.2) |
| Device identity | fresh `device\device-id.json` | fresh profile, `secrets.json` only after first sign-in |
| Credentials | nothing copied | nothing copied — fresh sign-in per clone |
| Taskbar identity | not patched (known limitation) | not patched (developer decision 2026-10-24, same limitation) |

## 3. Mechanism (verified)

### 3.1 Isolation levers (all env, all honored live)

- `CLINE_DIR` — relocates the whole `~\.cline` tree: `data\` (SQLite
  dbs: sessions/tasks/hub-events/hub-runs/session-search…, `locks\hub\`,
  `logs\`, `settings\`, `secrets.json` after login, `cache\`), `cron\`,
  `tasks\`, `apps\`, `workspaces\`. Referenced in BOTH the Rust shell
  and `bin\desktop-backend\index.js`; verified live: three clones each
  materialized their own full tree with their own
  `data\locks\hub\production.json.instance.lock`.
- `WEBVIEW2_USER_DATA_FOLDER` — the WebView2 profile holding the
  accounts.cline.app web login session. Verified live: per-clone
  `EBWebView` tree + `msedgewebview2.exe` children carrying
  `--user-data-dir=<clone>\webview` in their command lines. (The stock
  `bot.cline.app` folder name is the Tauri identifier used as the
  WebView2 default data dir.)
- `CLINE_HUB_PORT` / `CLINE_SIDECAR_PORT` — the hub daemon and desktop
  sidecar listeners (defaults: hub 25463 with candidate range
  `25463..25466` — `var ost=25463,ast=25466` in `index.js` — and sidecar
  3126 = `CLINE_SIDECAR_PORT` default). Verified live: clones assigned
  25471/3131, 25472/3132, 25468/3128 all bound by their own
  `cline-cli.exe` children while other instances held their own ports.

### 3.2 The single-instance guard and its neutralization

`tauri-plugin-single-instance` (compiled in — plugin-name string in the
exe bytes) does, at startup:

```rust
let id = &app.config().tauri.bundle.identifier;        // "bot.cline.app"
CreateMutexW(null, true, format!("{}-sim", id))        // bot.cline.app-sim
if GetLastError() == ERROR_ALREADY_EXISTS {
    let hwnd = FindWindowW(format!("{}-sic", id), format!("{}-siw", id));
    if hwnd != 0 { /* WM_COPYDATA argv forward */ app.exit(0); }   // <-- ONLY exit path
} else {
    /* hold mutex + create the hidden window (class -sic, title -siw) */
}
```

Live-verified anatomy: mutex `bot.cline.app-sim` exists **session-local**
(`Local\` namespace; `Global\` variant absent), hidden window class
`bot.cline.app-sic` / title `bot.cline.app-siw` owned by the running
instance. **The second copy only exits when `FindWindowW` FINDS that
window** — if the (class, title) pair no longer resolves, the launch
falls through and boots normally (this is the plugin's own code path,
and it was verified live twice).

Neutralization: the launcher renames the hidden window title to
`bot.cline.app-siw.neutralized` (`SetWindowTextW`, cross-process,
same-integrity — asInvoker app, non-elevated launcher) **before and
after every launch**, then verifies `FindWindowW == 0`. After that any
number of copies coexist (3 verified). The mutex is untouched and its
lifecycle is irrelevant to launches; it dies with its owning instance
(observed: gone after the owner was stopped). A stock Cline launched
normally keeps working beside the clones for the same reason — but a
stock launch that itself CREATES the fresh hidden window re-arms the
guard, which is exactly why the launcher also neutralizes pre-launch.

Because the app-level guard is neutralized, **the launcher enforces
per-clone single-instance itself**: it aborts (exit 1) when the clone's
own hub lock (`<CLINE_DIR>\data\locks\hub\production.json.instance.lock`,
exclusive-open probe) is held — two writers on one SQLite/hub tree is
the failure this prevents.

### 3.3 Identity

Machine identity = `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid`
(read via `reg.exe` by `@cline/core` `getMachineId-win-*.js` — the
OpenTelemetry pattern; same shared source as every other IDE here, GHOST
ground truth #1). Account/device identity lives in the state tree only:
`data\secrets.json` (`clineAccountId`, `userInfo` id/refresh tokens) and
`data\settings\providers.json` (provider OAuth tokens). A fresh
`CLINE_DIR` starts with **no** secrets at all — one manual sign-in per
clone (one credential = one instance, ZCode rule generalized).

### 3.4 Updates

No files are patched, so an app update breaks nothing — the clones
launch the same installed exe with env overrides only.
`CLINE_NO_AUTO_UPDATE` exists (3 refs in the backend) but is
deliberately NOT set: clones stay current with the installed app, and
nothing in the mechanism depends on the exe's version.

## 4. Naming and layout

```
%USERPROFILE%\ClineClonesHome\
├── c1\ … c5\         CLINE_DIR (whole state tree; created by launcher)
│    └── webview\     WEBVIEW2_USER_DATA_FOLDER (per-clone Chromium profile)
```

Fixed port plan (outside the stock defaults AND the stock hub candidate
range, so a clone never fights the Primary's ports or drifts into
another clone's):

| clone | CLINE_HUB_PORT | CLINE_SIDECAR_PORT | color / branding | AUMID |
|---|---|---|---|---|
| Primary (stock) | 25463..25466 (probe) | 3126 | — stock | bot.cline.app |
| c1 | 25471 | 3131 | blue   `cline-blue-branding` | bot.cline.app.c1 |
| c2 | 25472 | 3132 | yellow `cline-yellow-branding` | bot.cline.app.c2 |
| c3 | 25473 | 3133 | green  `cline-green-branding` | bot.cline.app.c3 |
| c4 | 25474 | 3134 | red    `cline-red-branding` | bot.cline.app.c4 |
| c5 | 25475 | 3135 | orange `cline-orange-branding` | bot.cline.app.c5 |

The Primary (`~\.cline`, `%LOCALAPPDATA%\bot.cline.app`) is **never
written** by any clone script. The stock Start Menu `Cline.lnk` is only
READ (base-AUMID discovery via `Shell.Application`
`ExtendedProperty('System.AppUserModel.ID')`), never written.

## 5. Provenance (2026-10-24, this host)

- asInvoker: no `requestedExecutionLevel` in `cline-app.exe` bytes in
  either ASCII or UTF-16 decoding (PowerShell regex over both).
- Tauri 2.11.1 + plugin: `tauri-*` / `tauri-runtime-wry` /
  `single-instance` strings in the exe; window class `Tauri Window`,
  title `Cline v0.0.48`; tray window class `tray_icon_app`.
- Single-instance anatomy: `OpenMutexW('bot.cline.app-sim')` = exists
  (`Local\` yes, `Global\` no) and `FindWindowW('bot.cline.app-sic',
  'bot.cline.app-siw')` = found, both while an instance ran; both GONE
  after it was stopped (mutex dies with the owner).
- Neutralization: `SetWindowTextW` rename → `FindWindowW` = 0 → a
  second copy booted instead of exiting; verified twice (c2 after the
  rename, c3 with no further action) — 3 concurrent cline-app.exe
  mains with 3 windows.
- Env levers: c1/c2/c3 each materialized `<clone>\data` + `<clone>\
  webview\EBWebView`; `msedgewebview2.exe` children carried
  `--user-data-dir=<clone>\webview`; `CLINE_HUB_PORT`/`CLINE_SIDECAR_PORT`
  assignments 25467/3127, 25468/3128, 25471/3131, 25472/3132 observed
  LISTENING owned by the launching clone's `cline-cli.exe` children.
- Primary untouched: 120-file `~\.cline` snapshot (path+mtime+size)
  compared before/after the whole session — **0 diffs**, twice.
- Hardcoded ports: `var ost=25463,ast=25466` + `CLINE_SIDECAR_PORT)||3126`
  read from `bin\desktop-backend\index.js`; full `CLINE_*` env inventory
  grepped from the backend and `cline-cli.exe`.
- MachineId source: `@cline/core/dist/getMachineId-win-*.js` reads
  `HKLM\...\Cryptography\MachineGuid` via `reg.exe QUERY`.
- Icon source: `tools\cline-{blue,yellow,green,red}-branding\` staged
  2026-10-17 from developer renders (accents #2979B9/#EBBF1C/#39A18A/
  #B92932). Orange (c5) generated 2026-10-24 from the blue master via
  `tools\make_clone_icon.ps1 -TintHue 25 -TintSat 0.9` (hue-rotate was
  rejected: the logo is a two-tone cyan/magenta mark and rotation
  produces the previously-rejected green family); verified: bright-pixel
  hue 25°, dark tile preserved, sha256 distinct from blue.

## 6. Files

- `src/windows/launch_cline_clone.ps1` — per-clone launcher (+`-Status`):
  port plan, hub-lock running-guard (abort), pre+post single-instance
  window neutralization with verify, post-launch checks (state dir,
  both ports listening, window not findable) within 60s.
- `src/windows/launch_cline_clones_all.ps1` — sequential all-five.
- `tools/install_cline_clone_shortcuts.ps1` — Desktop + Start Menu
  shortcuts, per-clone icons + suffixed AUMIDs, `-Remove` support.
- `tools/cline-{blue,yellow,green,red,orange}-branding\` — icons.

## 7. Known limitations / future work

- Running windows all share the base identity (one taskbar button when
  grouped; identical window titles "Cline v0.0.48"). Shortcut pins stay
  per-clone (AUMID + colored icon). A window-level patch would need a
  stamping helper (the ZCode pattern) — deferred by developer decision
  2026-10-24; there is no asar to patch, so the v1-AutoClaw engine route
  does not apply.
- No distinct window title / tray icon / accent (nothing patchable; the
  app's tray is process-internal). Reported degraded per the playbook
  never-silently-degrade rule.
- MachineGuid is shared by every instance (same as every IDE on this
  box); per-instance differentiation is the account identity in
  `data\secrets.json` / `providers.json`.
- If two launches race (one instance still booting while another's
  fresh hidden window exists un-neutralized for a moment), the later
  launch can exit — the launcher neutralizes pre-launch and polls
  post-launch, and the all-five script staggers 12s; do not launch in
  parallel.
- A stock Cline launched while NO launcher-neutralized state exists and
  another instance runs may still single-instance (stock behavior) if it
  finds an un-neutralized window; running the clone launcher once fixes
  it. `-Status` reports the window state.
- If a future Cline update changes the identifier or the plugin naming
  (`-sim/-sic/-siw`), the neutralization silently stops matching — the
  launcher then degrades to stock single-instance behavior (clones exit
  while another runs) and `-Status` shows the window as FINDABLE.
  Re-derive from the new exe (spec §3.2 procedure).

## 8. Operational rules

- Launch clones SEQUENTIALLY (the all-five script does this); never
  elevated (UIPI), even though the app is asInvoker.
- One manual sign-in per fresh clone — by design, never automated.
- Clone "reset" = stop the instance, delete
  `%USERPROFILE%\ClineClonesHome\<cN>`, launch again (no reset script in
  this suite; the Primary reset is out of scope 2026-10-24).
- `-Status` = hub-lock exclusive-open probe (held = running, absent =
  never started / cleanly stopped, free = not running), expected-port
  check and single-instance window check.
