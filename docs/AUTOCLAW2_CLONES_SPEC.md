# AutoClaw2 multi-instance clones (c1..c5) — design spec

Status: **IMPLEMENTED** — shipped 2026-10-23 (see CHANGELOG). Live-verified
the same day on this host: 5 clones + the v2.1.1 Primary + the v1.20 Primary
concurrently, per-clone lock acquisition `acquired:true` in each clone's
zwork log, unique per-profile device IDs, zero writes into any pre-existing
profile.
Project: GHOST (`unban-machine-id`) · Target app:
`%LOCALAPPDATA%\Programs\AutoClaw2\AutoClaw2.exe` (v2.1.1.262, internal name
zwork, package "AutoClaw desktop AI product" by Zhipu AI, Electron asInvoker)

This is a GHOST spec-first document like its v1 sibling
(`docs/AUTOCLAW_CLONES_SPEC.md`). Every mechanism quoted below was read out
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

The v1 suite (`launch_autoclaw_clone.ps1`, `docs/AUTOCLAW_CLONES_SPEC.md`)
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
| Taskbar identity | asar patch engine v12 | not patched (known limitation, see §7) |

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
  shortcuts, per-clone icons + suffixed AUMIDs, `-Remove` support.
- `tools/autoclaw2-{blue,yellow,green,red,orange}-branding\` — icons.

## 7. Known limitations / future work

- Running windows all declare the base AUMID (one taskbar button when
  grouping); shortcut pins stay per-clone. A window-level patch would need
  the asar route the v1 suite uses — deferred until actually needed.
- If a future AutoClaw2 update adds a shared-port listener, revisit a port
  lever (none observed through v2.1.1.262 with 5 copies).
- Each clone's first window shows first-run onboarding: one manual sign-in
  per clone is by design (identity isolation), not a defect.
- Telegram/IM polling across clones follows the one-credential-one-instance
  rule: sign clones into separate accounts/bots to avoid 409 cross-polling.

## 8. Operational rules

- Launch clones SEQUENTIALLY (the all-five script does this).
- Never launch elevated (UIPI), even though the app is asInvoker.
- `-Status` reads the lockfile with an exclusive-open probe (same semantics
  as the v1 suite: held = running, absent = clean stop, free = not started).
