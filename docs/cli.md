# GHOST CLI — direct commands

Prefer the interactive launchers — **`GHOST.bat`** (Windows, double-click) or
**`./ghost.sh`** (Linux). This page is the direct-command cheat sheet for
scripts and CI. `GHOST.bat` groups its tasks into six submenus with
continuous local numbering (IDE Resets [1]-[8] / ZCode Multi-Instance &
Clones [1]-[29] / System & GHOST Maintenance [1]-[4] / AutoClaw2
Multi-Instance & Clones [1]-[12] / Cline Multi-Instance & Clones
[1]-[9] / OpenCode Multi-Instance & Clones [1]-[10]); chain several tasks in one
prompt using the numbers shown in that submenu (e.g. `1 3 4` inside ZCode), or
from the main menu type a sub-path like `2 1 3 4` (open ZCode, run its
[1] [3] [4]) or a bare global id — this page cites menu positions as
`<submenu> [n]`, e.g. `ZCode [27]` for the icon patch. `[U]` on the main menu
(and Maintenance [2]) runs the self-updater.

## Windows resets (PowerShell as Administrator, from the repo root)

```powershell
powershell -ExecutionPolicy Bypass -File "src\windows\reset_cursor.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\reset_devin.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\reset_trae.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\reset_qoder.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\reset_qoderwork.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Primary
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Secondary
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Third
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Fourth
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Fifth
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Sixth
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target All
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" -Instance Third
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" -Instance Fourth
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" -Instance Fifth
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" -Instance Sixth
powershell -ExecutionPolicy Bypass -File "src\windows\reset_minimax_opencode.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\change_device_id.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\spoof_wmi_serials.ps1"            # Maintenance [3] — WMI serial spoof
powershell -ExecutionPolicy Bypass -File "src\windows\spoof_wmi_serials.ps1" -DryRun     # plan only, no writes
```

## MCP central registry (Maintenance [4])

```powershell
powershell -ExecutionPolicy Bypass -File "tools\sync_mcp_registry.ps1"                   # Maintenance [4] — sync master-mcp.json to all apps (LIVE)
powershell -ExecutionPolicy Bypass -File "tools\sync_mcp_registry.ps1" -DryRun           # preview only — writes nothing
powershell -ExecutionPolicy Bypass -File "tools\sync_mcp_registry.ps1" -Target zcode,windsurf  # subset (cursor, windsurf, vscode, zcode, minimax, opencode, all)
powershell -ExecutionPolicy Bypass -File "tools\mcp\collect_mcp_inventory.ps1"           # harvest: read-only scan of every app -> mcp-inventory.json
```

Author MCPs once in `tools\mcp\master-mcp.json` (device-specific values in the
gitignored `master-mcp.local.json` overlay) and run the sync — every target app
gets the definitions in its own config shape. App-local enable/disable state
survives; app-only servers are never deleted. Secrets ride `${VAR}` names
resolved from machine env. Plan: `docs/MCP_CENTRAL_REGISTRY_PLAN.md`.

Menu equivalents for the reset targets: `reset_zcode.ps1 -Target Primary` =
IDE Resets [7] **and** ZCode [14] (the same task from both menus);
`-Target Secondary` / `Both` / `Third` / `Fourth` / `Fifth` / `Sixth` / `All` =
ZCode [9] Reset **Blue** clone / [15] **Blue** + Primary / [10] **Yellow** /
[11] **Green** / [12] **Red** / [13] **Orange** / [16] **ALL SIX** (menus display
the COLOR names; the CLI params keep the frozen keys). The AutoClaw v1.20 suite
(`reset_autoclaw.ps1` and friends) was REMOVED 2026-10-31 with the v1.20 app
(uninstalled from the dev host 2026-10-29) — recover it from git history or
`archive/autoclaw-v1.20/` for a v1.20 host. AutoClaw2 has no reset script
by design: stop the instance and delete its `AutoClaw2ClonesHome\<cN>` folder.

## ZCode captcha watchdog (unattended; no admin needed)

```powershell
powershell -ExecutionPolicy Bypass -File "tools\watch_zcode_captcha.ps1"
powershell -ExecutionPolicy Bypass -File "tools\watch_zcode_captcha.ps1" -RunOnce -DryRun   # test first
```

Telegram escalation reads `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` from
`.envlocal` (repo root; git-ignored). NOTE: the watchdog monitors the PRIMARY
instance only.

## ZCode multi-instance (6 independent windows/accounts; Windows only)

```powershell
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" [-Instance Second|Third|Fourth|Fifth|Sixth]
```

Or double-click: `src\windows\Launch-ZCode-Blue.bat` / `-Yellow.bat` /
`-Green.bat` / `-Red.bat` / `-Orange.bat`.

First launch of each clone copies history into its own home
(`%USERPROFILE%\ZCodeSecondHome | ZCodeThirdHome | ZCodeFourthHome |
ZCodeFifthHome | ZCodeSixthHome` — frozen plumbing dir names: Second = the
Blue clone, Third = Yellow, Fourth = Green, Fifth = Red, Sixth = Orange; only
the shortcut/window display layer uses colors), scrubs
it to fresh IDs, and reconciles Telegram channel bots via sha8 credential
comparison (duplicates of Primary disabled, unique clone bots preserved —
see [docs/ZCODE_TELEGRAM_BOTS.md](ZCODE_TELEGRAM_BOTS.md)). Colors ARE the
display vocabulary (menus, console output, shortcut names): Blue, Yellow,
Green, Red #CA0607, Orange #CB5D06 — the `-Instance` params keep the frozen
keys Second/Third/Fourth/Fifth/Sixth
(separate taskbar buttons + window titles "ZCode Blue"/"ZCode Yellow"/
"ZCode Green"/"ZCode Red"/"ZCode Orange"). Every launch also ensures the two
resident watchers an install needs are alive and set to autostart (launcher
step 2e, mutex-guarded, best-effort): the MCP sync watcher and the taskbar
identity watcher — you never have to start them from GHOST manually.
All instances share one install, so one update covers all — but re-run the
icon patch (`tools\patch_zcode_icon_override.ps1`, ZCode [27]) after every app
update; it is what makes the `ZCODE_ICON_DIR` / `ZCODE_AUMID_SUFFIX` /
`ZCODE_ACCENT_HEX` / `ZCODE_INSTANCE_NAME` branding overrides work. Since
engine v9 the patch runs in-place asar surgery (`tools/asar_surgery.mjs`) —
a few seconds on a clean box (no AV); roughly 10–60 s on AV-protected
machines (estimate, not measured) — still far below the old minutes. The
surgery writes one big file instead of ~32k small ones, so per-file AV
overhead is mostly gone, and the swap retries briefly if antivirus holds
the fresh candidate. Close the app first or pass -WaitForClose.

### ZCode light headless worker (no desktop window; ZCode [7])

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_zcode_cli_light.ps1" -Instance Second            # interactive REPL
powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_zcode_cli_light.ps1" -Instance Fifth -Prompt "task" # one-shot
powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_zcode_cli_light.ps1" -Instance Third -Server       # stdio worker
```

Runs a clone's account headless (`resources\glm\zcode.cjs -p` / `app-server`
under the system node): about a quarter of the RAM of a full desktop instance,
sessions isolated to that clone's home and shareable with its desktop app. The
interactive TUI cannot run standalone (`@zcode/tui` lives inside app.asar) and
a home without a standalone `zcode login zai` runs tasks on the free
opencode-zen model, not the Start Plan — the launcher prints the one-time
login recipe when it detects that. Full findings: [ZCODE_LIGHT_MODE.md](ZCODE_LIGHT_MODE.md).

## ZCode clone shortcuts (Desktop + Start menu; per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\install_zcode_second_shortcuts.ps1"
```

Creates `ZCode Blue` / `ZCode Yellow` / `ZCode Green` / `ZCode Red` /
`ZCode Orange` shortcuts (matching color icons — the shortcut name equals the
window title) that run the launcher above; a taskbar pin groups with
that clone's running window. Remove with `-Remove` (ZCode [29]); install /
scope with `-Instance` (ZCode [8]).
Repair a hijacked Primary pin (clone AUMID + wiped icon) with
`-RepairPrimaryAumid` — the taskbar watcher also self-heals it every ~5 min
(`-RunOnce -CheckPrimaryHijack` for a one-shot repair).

## ZCode cross-instance chat refresh (no app restart; per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\refresh_zcode_second_chats.ps1" [-Target Primary|Second|Third|Fourth|Fifth|Sixth|All]
```

Shows chats created in another instance inside a running sidebar by recycling
the target's app-server (auto-respawn reseeds its index; verify-after). ZCode
[21] = Blue clone only, ZCode [22] = all instances. A hot-activity guard waits out
in-flight turns (`-Force` bypasses). Watcher mode (`-Watch`, ZCode [23]) tails
the CLI JSONL logs for terminal failures (captcha stall / quota / rate-limit)
and refreshes every RUNNING instance on a 300 s cooldown.

## ZCode clone asset sync (MCPs + skills + plugins; per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\sync_zcode_assets.ps1" [-Target Second|Third|Fourth|Fifth|Sixth|All] [-DryRun]
```

Every clone resolves its own user-scope config
(`<CloneHome>\.zcode\cli\config.json`), so Primary-side MCP/plugin/skill
changes never reach the clones and the seed copies drift. This syncs MCP
server definitions from the Primary (per-clone on/off toggles stay local;
new servers carry the Primary's enabled value; clone-only servers are kept),
replaces the stale `<CloneHome>\.zcode\skills` copies with a junction on the
shared `~\.agents` store (every instance sees the same live skills), and
mirrors the plugin cache + marketplaces. A running instance is skipped with
a warning (skills/plugin mirroring must not race a live app — close it
first, or add `-McpOnly`); an unseeded home is skipped (the launcher seeds
it on first launch). Every write is backed up and verified by re-read; audit
trail at `<CloneHome>\.zcode\asset-sync-audit.jsonl`. ZCode [17]. The
launcher also runs it automatically before every clone launch (step 2d).

With `-McpOnly` only the MCP definitions sync, and that is verified safe
against RUNNING instances (2026-10-27: the app holds no handle on
config.json, never rewrites it on exit, and reads `mcp.servers` at every
app-server spawn — one per new session): ZCode [18].

## ZCode MCP sync watcher (per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\watch_zcode_mcp_sync.ps1" [-RunOnce] [-DryRun] [-IntervalSeconds 5] [-ApplyLive] [-Target Second|Third|Fourth|Fifth|Sixth|All] [-InstallAutostart|-RemoveAutostart]
```

Resident watcher: whenever the Primary's `~\.zcode\cli\config.json` changes
(add an MCP server there — via the Primary's MCP settings UI or the file —
and it is the ONE place), it invokes `sync_zcode_assets.ps1 -McpOnly` as a
child process (the watcher writes nothing itself — backup, verify-after and
the JSONL audit live in the sync tool), so every clone converges within
seconds, running instances included. A synced definition is picked up by
each instance's next chat automatically (every new session re-reads the
config at app-server spawn — no restart). The first pass on start converges
existing drift; a deep re-verify runs every ~5 min. `-ApplyLive` (ZCode
[20]) additionally recycles running instances' app-servers after a real
change — idle-guarded, never mid-turn — so the currently open session gets
the new MCP immediately. `-InstallAutostart` writes a hidden Startup-folder
shortcut (like the taskbar watcher); single-instance via a named mutex plus
a startup process scan. Log: `%LOCALAPPDATA%\watch-zcode-mcp-sync\mcp-sync.log`.
ZCode [19] (resident) / [20] (one-shot + live apply). You normally never
start it yourself: every clone launch (launcher step 2e) starts it hidden
and installs its autostart shortcut if missing — install-and-forget.

## ZCode freeze diagnostic (per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\diagnose_zcode_freeze.ps1" [-Days 7]
```

Explains the "window drags but content is dead" freeze from the app's own
telemetry: scans every instance's `<home>\.zcode\v2\logs` for renderer /
child-process deaths and freeze events, reads the crash archive's dump
annotations, and prints live RAM / commit / pagefile pressure. ZCode [26].
Read-only. Verified root cause (2026-09-25): renderer OOM from OS
commit-limit exhaustion with 4 instances; the splash-then-close relaunch is
the app's post-crash quit path, not corruption — just launch again. See
`docs/troubleshooting.md`.

## ZCode throttle diagnostic (per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\diagnose_zcode_throttle.ps1" [-Days 7]
```

Explains "Reconnecting... x/10" and "The system is busy..." turn failures
from the shared agent runtime JSONL (`~\.zcode\cli\log\zcode-*.jsonl` —
every instance writes there, so events cannot be pinned to one instance):
lists Start Plan admission-busy retries and failed turns with their cause
chain (`StartPlanBusyAutoRetryExhaustedError` / `model_rate_limited` /
`providerCode 3009` "model concurrency limit exceeded"), an hourly
histogram in local time, and a per-session rollup. Verified root cause
(2026-10-27): Z.ai's Start Plan admission control refusing new model
streams when the pool saturates — the UI counter is the client's
11-attempt recovery loop, and it is NOT a device/IP ban (auth + billing
keep working; a ban surfaces as 401/403, never as "busy"). Read-only.
Includes the discrimination test for the next incident: close every
instance except one and retry. Symptom-side guidance and the live incident
record: [troubleshooting.md](troubleshooting.md). CLI-only — no GHOST.bat
entry.

## GHOST repo updater (per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\update_ghost.ps1"            # check, then ask to update
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\update_ghost.ps1" -CheckOnly # report only, no writes
```

Fetches `origin` and compares HEAD with the remote default branch, lists the
new commits, and (without `-CheckOnly`) asks before a `git pull --ff-only`.
Refuses when local commits or a non-`main` branch block the fast-forward; a
dirty working tree gets an interactive stash -> pull -> restore offer (a
failed restore keeps the stash). A failed fetch (offline) is a warning, not a
failure. Main menu [U] / Maintenance [2].

ZIP-extracted copies (no `.git`) are handled too. With Git installed the
updater offers an in-place conversion into a real clone (git init + fetch +
align to origin; a failed fetch, a setup failure or a declined overwrite
removes the temporary `.git` again, leaving the folder untouched). Without
Git it updates the folder by downloading the latest GitHub archive directly
(add/overwrite only, per-file backup + SHA256 verify, never deletes).
Params: `-OriginUrl` (conversion remote, for forks), `-ZipUrl` (archive URL;
also accepts a local `file:///...` path for offline testing), `-Convert`
(non-interactive confirmation; the local-edits overwrite prompt still
requires interactive confirmation).

## GHOST Python core (diagnostics; no admin needed)

All SQLite/JSON identity logic lives in a stdlib-only Python package
(`src/python/ghost`); the PowerShell bridges call it through
`src\python\ghost_cli.py`. It is also usable directly for quick checks:

```powershell
python src\python\ghost_cli.py identity                      # fresh 4-field identity set (JSON)
python src\python\ghost_cli.py chat-check hot "%USERPROFILE%\.zcode\cli\db\db.sqlite"
python src\python\ghost_cli.py chat-check missing "%USERPROFILE%\.zcode\cli\db\db.sqlite" "%USERPROFILE%\.zcode\v2\tasks-index.sqlite"
```

`chat-check hot` reports the multi-signal in-flight-turn guard (commit age,
uncompleted assistant steps, running tools); `chat-check missing` lists
shared-store chats absent from an instance's sidebar index — the same probes
`refresh_zcode_second_chats.ps1` runs internally. Further subcommands:
`sqlite-update`, `delete-secrets`, `clear-cli-telemetry`, `json-patch`,
`restore-script`, `audit-log` (stdout contracts documented in
[architecture.md](architecture.md)).

## Cline multi-instance (5 clones + Primary; per-user, no admin needed)

```powershell
powershell -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c1
powershell -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c2   # ... c5
powershell -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c1 -Status
powershell -ExecutionPolicy Bypass -File "src\windows\launch_cline_clones_all.ps1"
powershell -ExecutionPolicy Bypass -File "tools\install_cline_clone_shortcuts.ps1"
powershell -ExecutionPolicy Bypass -File "tools\install_cline_clone_shortcuts.ps1" -Remove
```

Each clone gets its own state tree, web login profile and hub/sidecar
ports; the launcher neutralizes the app's single-instance hidden window
and aborts a second copy on the same data. First run per clone: ONE
manual sign-in. Menu equivalents: launch c1/c2/c3/c4/c5 = Cline
[1]/[2]/[3]/[4]/[5]; all five = Cline [6]; status = Cline [8];
shortcuts = Cline [7] (`-Remove` = [9]).

## OpenCode multi-instance (5 clones + Primary; per-user, no admin needed)

```powershell
powershell -ExecutionPolicy Bypass -File "tools\patch_opencode_clone_home.ps1"   # once; close ALL OpenCode windows (or pass -WaitForClose like menu row [10])
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c1
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c2   # ... c5
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c1 -Status
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clones_all.ps1"
powershell -ExecutionPolicy Bypass -File "tools\install_opencode_clone_shortcuts.ps1"
powershell -ExecutionPolicy Bypass -File "tools\install_opencode_clone_shortcuts.ps1" -Remove
powershell -ExecutionPolicy Bypass -File "tools\install_opencode_clone_shortcuts.ps1" -RepairPrimaryAumid
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_cli_light.ps1" -Instance c1              # headless light worker (prompt loop)
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_cli_light.ps1" -Instance c1 -Prompt "summarize the repo"   # one-shot
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_cli_light.ps1" -Instance c1 -Server -Port 4096             # foreground v2 API/web server
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_cli_light.ps1" -Instance c1 -Acp                            # foreground ACP stdio server (T3 Code surface)
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_cli_light.ps1" -Instance c1 -Login                         # one-time account login
powershell -ExecutionPolicy Bypass -File "src\windows\launch_opencode_cli_light.ps1" -Instance c1 -StopService                   # stop the clone's background service
powershell -ExecutionPolicy Bypass -File "tools\install_t3_opencode_instances.ps1"          # seed the 5 clones into T3 Code (close T3 first)
powershell -ExecutionPolicy Bypass -File "tools\install_t3_opencode_instances.ps1" -Remove   # unseed
```

Isolation needs the ONE-TIME clone-home asar patch (packaged builds
hardcode the Electron userData): the launcher aborts loudly when it is
missing, and an app update reverts it — the byte-probe re-patches
automatically on the next run (re-run OpenCode [10] after any manual
update). Each clone gets its own userData/sessionData plus its own
`XDG_*` CLI-state home, its own single-instance lock, and per-clone
taskbar identity (AUMID + window icon + "OpenCode <Color>" title).
Service ports are ephemeral per instance (no port plan). First run per
clone: ONE manual sign-in. Menu equivalents: launch
c1/c2/c3/c4/c5 = OpenCode [1]-[5]; all five = [6]; light worker = [7]
(gids 79/80 for worker/login); login = [8]; shortcuts = [9]
(`-Remove` = [12]); patch = [10]; status = [11].

The light worker (`src/windows/launch_opencode_cli_light.ps1`, OpenCode
[7]) runs the shipped `opencode-cli.exe` headless on the clone's own
XDG state — sessions share history with that clone's desktop app. A
fresh clone WORKS but on the FREE model (iceman-free); `-Login` attaches
the clone's account (one credential = one instance). `-Auto` passes
`--auto` for tasks that would otherwise wait on approval prompts.

## AutoClaw2 multi-instance (5 clones + Primary; per-user, no admin needed)

```powershell
powershell -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c1
powershell -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c2   # ... c5
powershell -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c1 -Status
powershell -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clones_all.ps1"
powershell -ExecutionPolicy Bypass -File "tools\install_autoclaw2_clone_shortcuts.ps1"
powershell -ExecutionPolicy Bypass -File "tools\install_autoclaw2_clone_shortcuts.ps1" -Remove
```

### AutoClaw2 MCP + chat sync (AutoClaw2 [8]-[10])

```powershell
powershell -ExecutionPolicy Bypass -File "tools\sync_autoclaw2_mcp.ps1"                   # [8] — apply tools\autoclaw2-mcp.master.json to closed clones (LIVE)
powershell -ExecutionPolicy Bypass -File "tools\sync_autoclaw2_mcp.ps1" -Target c1 -DryRun # plan only
powershell -ExecutionPolicy Bypass -File "tools\sync_autoclaw2_mcp.ps1" -RestoreBackup -Target c1  # restore the newest pre-run backup
powershell -ExecutionPolicy Bypass -File "tools\sync_autoclaw2_chats.ps1" -Mode Inventory  # [9] — read-only cross-profile chat report
powershell -ExecutionPolicy Bypass -File "tools\sync_autoclaw2_chats.ps1" -Mode Import -SessionId <uuid> -Target c1          # [10] dry-run plan
powershell -ExecutionPolicy Bypass -File "tools\sync_autoclaw2_chats.ps1" -Mode Import -SessionId <uuid> -Target c1 -Apply   # guarded one-way copy
powershell -ExecutionPolicy Bypass -File "tools\sync_autoclaw2_chats.ps1" -Revert -ImportId <uuid> -Target c1                # undo one import
```

Definitions only (no credentials travel): the master manifest
`tools\autoclaw2-mcp.master.json` is the source of truth, merge preserves
clone-local `enabled` toggles and never deletes clone-only sources, written
rows stay `pending` for the app to test (D5), and every write happens on a
CLOSED profile (D7 — the launcher's pre-launch step [2b] is the primary path).
Chat import copies a session as a NEW local session with an `[import]` title
prefix (D11), refuses IM-bound sessions (D12), and is revertible by import id.
Spec: `docs\AUTOCLAW2_SYNC_SPEC.md`. The live acceptance runs (A1-A7, C2-C7)
are still gated on the supervised Phase 0 spikes.

Isolation is 100% env-based and needs NO patching: `ZWORK_USER_DATA` pins
the whole Electron userData per clone BEFORE the per-profile
single-instance lock (N copies coexist natively), and
`AUTOCLAW_PROFILE_ROOT` relocates the legacy v1.x migration source so no
clone ever reads a live Primary's state. The app generates a fresh
`device\device-id.json` per profile (no identity seeding, no credential
copying). First run per clone: ONE manual sign-in. Menu equivalents: launch
c1/c2/c3/c4/c5 = AutoClaw2 [1]-[5]; all five = [6]; shortcuts = [7];
Import MCPs = [8]; chat inventory = [9]; import chats = [10]
(`-Remove` = [12]); status = [11].

## Linux

```bash
chmod +x src/linux/*.sh
./ghost.sh           # interactive menu

# Or run directly:
./src/linux/reset_cursor.sh                          # close Cursor first
sudo ./src/linux/reset_cursor.sh                     # also resets /etc/machine-id
./src/linux/reset_windsurf.sh                        # close Windsurf first
./src/linux/change_device_id.sh Fingerprint          # no root
sudo ./src/linux/change_device_id.sh ResetMachineId  # /etc/machine-id (root)
```
