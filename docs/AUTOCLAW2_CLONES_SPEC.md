# AutoClaw2 multi-instance clones (c1..c5) — design spec

Status: **IMPLEMENTED** — shipped 2026-10-23 (see CHANGELOG). Live-verified
the same day on this host: 5 clones + the v2.1.1 Primary + the v1.20 Primary
concurrently, per-clone lock acquisition `acquired:true` in each clone's
zwork log, unique per-profile device IDs, zero writes into any pre-existing
profile.
Project: GHOST (`unban-machine-id`) · Target app:
`%LOCALAPPDATA%\Programs\AutoClaw2\AutoClaw2.exe` (v2.1.1.262, internal name
zwork, package "AutoClaw desktop AI product" by Zhipu AI, Electron asInvoker)

This is a GHOST spec-first document. (Its v1.20 sibling,
`docs/AUTOCLAW_CLONES_SPEC.md`, was removed 2026-10-31 with the v1.20 app —
recover it from git history or `archive/autoclaw-v1.20/`.) Every mechanism
quoted below was read out
of the installed app's `resources\app\dist\main.cjs` or live-verified on
this host (provenance §5).

---

## 1. Problem

AutoClaw2 (the v2.1.1 redesign, internally `zwork`) is a single-instance
Electron app. We want **5 independent AutoClaw2 instances** running side by
side, each with its own profile, own agent state, own device identity and
own sign-in — while **preserving every pre-existing installation and
profile untouched**: the v2.1.1 Primary (`%APPDATA%\AutoClaw-oversea-official`),
the v1.20 Primary (`C:\Program Files\AutoClaw` + `~\.openclaw-autoclaw`) and
the four v1.20 clones (`%USERPROFILE%\AutoClawCloneHome\inst1..4`).

## 2. Relationship to the v1.20 AutoClaw suite

The v1.20 suite (its launcher and spec now live in git history /
`archive/autoclaw-v1.20/`)
clones the OLD app, whose elevation manifest (`requireAdministrator`) kills
env levers at the UAC boundary — hence its heavier machinery (USERPROFILE
relocation, asar port patch, taskbar patch engine, identity seeding with
scrub). AutoClaw2 inverts most of that:

| | v1.20 suite (inst1..4) | v2.1.1 suite (c1..c5) |
|---|---|---|
| Elevation | requireAdministrator (env dies) | **asInvoker** (env survives) |
| userData lever | `--user-data-dir` (argv) | **`ZWORK_USER_DATA`** (env, official) |
| Lock separation | profile dir via argv | pinned profile dir via env **before** lock |
| State tree | moved via patched home override | self-contained in userData |
| Gateway | separate process + port patch needed | in-process engine, no port conflict observed |
| Device identity | seed-scrub + rotate | **generated fresh per profile** (no seeding) |
| Credentials | copy profile minus credentials | **nothing copied** — fresh sign-in |
| Taskbar identity | asar patch engine v12 | env-driven plain-text patch (2026-11-06, §7) |

## 3. Mechanism (verified)

From `resources\app\dist\main.cjs` (zwork-single-instance-lock.ts):

```
pinUserDataDirectory()            // resolves profile dir:
  resolveZworkProfileDirectory()  //   env ZWORK_USER_DATA ?? %APPDATA%\AutoClaw-oversea-official
  app.setPath("userData", dir)    //   pin BEFORE the lock
requestSingleInstanceLock()       // keyed on the pinned dir
  -> log "zwork.update.single_instance" {"acquired":true|false}
```

Each distinct `ZWORK_USER_DATA` value therefore acquires its own lock and N
copies coexist. `AUTOCLAW_PROFILE_ROOT` relocates the legacy v1.x migration
source (read-only; default `~\.openclaw-autoclaw`) — each clone points it at
its own migration-root dir so no clone ever reads a live Primary's state.

Device identity: first run generates `device\device-id.json` inside the
profile (sha256 prefixes verified distinct across three profiles on
2026-10-23). No identity seeding, no credential copying, one manual sign-in
per clone (one credential = one instance — the ZCode Telegram rule,
generalized).

## 4. Naming and layout

```
%USERPROFILE%\AutoClaw2ClonesHome\
├── c1\            ZWORK_USER_DATA (Electron userData = whole state)
├── c2\ … c5\
├── c1-migration-root\   (AUTOCLAW_PROFILE_ROOT target, stays empty unless
│    …                    a clone's migration UI writes there)
```

The v2.1.1 Primary (`%APPDATA%\AutoClaw-oversea-official`), the v1.20
Primary (`~\.openclaw-autoclaw`, `%APPDATA%\autoclaw`) and the v1 clone
homes (`AutoClawCloneHome`) are **never touched** — the launcher neither
reads nor writes them. Shortcuts/AUMIDs use base `com.zhipuai.autoclaw2`
(declared by the app) with `.cN` suffixes; the stock `AutoClaw.lnk` is only
READ (AUMID discovery), never written.

## 5. Provenance (2026-10-23, this host)

- asInvoker manifest: read from AutoClaw2.exe bytes (`requestedExecutionLevel
  level="asInvoker"`).
- Lock-before-pin order + `ZWORK_USER_DATA`/`AUTOCLAW_PROFILE_ROOT` consumption:
  read from `resources\app\dist\main.cjs`.
- N-instance coexistence: live-verified (3 concurrent copies, each log
  `zwork.update.single_instance acquired:true`, 4 processes each; primary
  gateway port 18789 untouched).
- Per-profile device-id uniqueness: sha256 of `device\device-id.json`
  compared across three profiles (distinct).
- In-process engine / no port binding: `Get-NetTCPConnection` during the
  3-copy test (only the v1.20 gateway on 18789).
- Icon source: app's own `app-icon-square` 512×512 renderer asset (a
  monochrome WHITE logo). The first icon run used `-HueRotate` only and
  shipped five byte-identical icons (hue-rotate is a no-op on gray art);
  fixed 2026-10-23 with the new `-TintHue/-TintSat` colorize mode in
  `tools\make_clone_icon.ps1` — hues calibrated from the old
  autoclaw/zcode suites: blue 206 / yellow 46 / green 166 / red 356 /
  orange 25 (sat 0.82–0.98, value preserved, dark tile untouched; five
  distinct hashes verified).

## 6. Files

- `src/windows/launch_autoclaw2_clone.ps1` — per-clone launcher (+`-Status`).
- `src/windows/launch_autoclaw2_clones_all.ps1` — sequential all-five.
- `tools/install_autoclaw2_clone_shortcuts.ps1` — Desktop + Start Menu
  shortcuts, per-clone icons + suffixed AUMIDs, `-Remove` support,
  `-RepairPrimaryAumid` (EC-C01) since 2026-11-06.
- `tools/patch_autoclaw2_identity.ps1` — window + notification-tray identity
  patch (2026-11-06, §7; v2 2026-11-09 adds the tray anchor); tested by
  `tests/autoclaw2_identity_patch.Tests.ps1`.
- `tools/autoclaw2-{blue,yellow,green,red,orange}-branding\` — icons.

## 7. Known limitations / future work

- **Window-level taskbar identity — SHIPPED 2026-11-06** (was "deferred
  until actually needed"). The 4.0.0 bundle turned out to ship UNPACKED:
  the whole main process is the plain-text
  `resources\app\dist\main.cjs` (14.3 MB) — no `app.asar`, no runtime
  integrity check (the bootstrap does a bare `require()` of it and
  `dist\installer\payload-verify.cjs` is an existence-only check the app
  never spawns), so no asar-surgery route was needed.
  `tools\patch_autoclaw2_identity.ps1` (AutoClaw2 [13] / gid 78) splices
  THREE byte-anchors — each verified to occur exactly once in the
  4.0.0 bundle — so the AUMID and window icon become env-driven,
  following the app's own `ZWORK_*` convention (it never parses argv
  flags):
  1. `setAppUserModelId(Kqn)` → `setAppUserModelId(process.env.ZWORK_AUMID||Kqn)`
     (process-level AUMID, also covers transient windows);
  2. `appId:Kqn,appIconPath:e,` →
     `appId:process.env.ZWORK_AUMID||Kqn,appIconPath:process.env.ZWORK_CLONE_ICON||e,`
     (the per-window `setAppDetails` helper; the following
     `relaunchCommand:`"${e}"`` backtick template literal is NEVER
     touched);
  3. `Uf.app.isPackaged&&Xqn(l,process.execPath)` →
     `Uf.app.isPackaged&&(process.env.ZWORK_CLONE_ICON&&l.setIcon(process.env.ZWORK_CLONE_ICON),Xqn(l,process.execPath))`
     (main-window title-bar/taskbar icon).
  4. `t=r(e(n.iconPath));` →
     `t=r(e(process.env.ZWORK_CLONE_ICON||n.iconPath));`
     (inside the generic tray builder mTr: the NOTIFICATION-AREA tray icon,
     patch v2 2026-11-09. Stock passes the app's own monochrome
     trayTemplate.png - a Windows template asset every copy shares, which is
     why all five tray icons stayed uncolored after the 2026-11-06 window
     anchors landed; with ZWORK_CLONE_ICON set, createFromPath receives the
     clone's tinted tray_icon.ico and the stock 18x18 resize/template-flag
     logic is untouched. Overriding the read INSIDE mTr covers every call
     site; the Find text is unique in the bundle.)
  The launcher then sets `ZWORK_AUMID=com.zhipuai.autoclaw2.cN`
  (matching the SHORTCUT AUMIDs, so pins and running windows group
  together) + `ZWORK_CLONE_ICON=tools\autoclaw2-<color>-branding\tray_icon.ico`
  per clone; with no env (the Primary, bare launches) the patched bundle
  is behaviourally stock. Idempotent; sibling backup
  `main.cjs.bak-zwork-identity-<stamp>`; marker
  `resources\app\autoclaw2-identity-patch.marker.json` (sha256
  before/after); `node --check` gate through the app's own vendor node;
  verify-after re-read with auto-restore; `-Restore`; after an app update
  wipes the patch the script detects the stock bundle and re-applies with
  a FRESH backup. Patch v2 (2026-11-09) skips anchors whose replacement is
  already present (per-anchor resume), so a v1-patched bundle upgrades in
  place: only the new tray anchor is spliced, the fresh backup holds the
  v1-patched file, and the marker records `preDoneAnchors` so `-Restore`
  verifies against that pre-upgrade state. The installer gained
  `-RepairPrimaryAumid` (EC-C01) in the same pass.
  Inherited quirk (stock behaviour, unchanged): the
  window's `relaunchCommand` still points at AutoClaw2.exe, so a taskbar
  "relaunch" on a clone button would open the Primary profile. The new
  env vars are deliberately NOT added to the bundle's agent-shell env
  allowlist (`HX`, the `safeEnvironment` array) — they are main-process
  reads and must not leak into agent shells. Window TITLE stays the
  shared "AutoClaw" (the renderer `<title>` would re-override it;
  `page-title-updated` suppression is out of scope — playbook feature #6
  remains degraded, reported).

  **Taskbar grouping needs a KICK (2026-11-09).** The patched
  `setAppDetails` call writes `System.AppUserModel.ID` on the window at
  construction time, but the shell has already created that window's
  taskbar group by then and does NOT rebuild it on a plain property
  write - two clones keep ONE taskbar button while their stores read
  `...c1` / `...c5` (live-reproduced: c1 + c5 running, distinct stores,
  one AutoClaw button). `launch_autoclaw2_clone.ps1` therefore KICKS the
  window after the launch (temp `<aumid>.kick` -> real `<aumid>`): the
  same window-property route and kick idiom as the ZCode suite, verified
  with a read-back and a FAILED verdict, never silent. Spacing is
  load-bearing - a 300-400 ms temp->real pair can be coalesced by the
  shell and leave the window with NO button at all (reproduced on c5; a
  slower kick restored it), so the writes are 1.2 s apart with a settle
  re-read. Live-verified the same day: four instances (blue / yellow /
  green / orange) -> four separate taskbar buttons with their own tinted
  icons. The kick also works on a STOCK bundle: window-level AUMID has
  top precedence, so the button separates even when the app never sets
  the value (the icon then stays stock).
- If a future AutoClaw2 update adds a shared-port listener, revisit a port
  lever (none observed through v2.1.1.262 with 5 copies).
- Each clone's first window shows first-run onboarding: one manual sign-in
  per clone is by design (identity isolation), not a defect.
- Telegram/IM polling across clones follows the one-credential-one-instance
  rule: sign clones into separate accounts/bots to avoid 409 cross-polling.
- MCP + chat sync across the suite exists since 2026-11-04:
  `tools/sync_autoclaw2_mcp.ps1` (device manifest `tools/autoclaw2-mcp.master.json`
  → closed-clone connected sources) + `tools/sync_autoclaw2_chats.ps1`
  (inventory, guarded one-way import, revert) — spec
  `docs/AUTOCLAW2_SYNC_SPEC.md`; live acceptance is still gated on the
  supervised Phase 0 spikes (E1-E5).

## 8. Operational rules

- Launch clones SEQUENTIALLY (the all-five script does this).
- Never launch elevated (UIPI), even though the app is asInvoker.
- `-Status` reads the lockfile with an exclusive-open probe (same semantics
  as the v1 suite: held = running, absent = clean stop, free = not started).
