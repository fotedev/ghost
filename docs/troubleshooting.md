# Troubleshooting

## `[FAILED] Python not found ...` / `GHOST Python core not found`

The Windows IDE scripts run their SQLite writes through the bundled Python
core (`src/python/ghost`, invoked via `src\python\ghost_cli.py`). Detection
is a **functional probe**: a candidate (`python`, `python3`, `py`, plus
per-user install paths) is accepted only when `--version` exits 0 reporting
"Python 3" — so the Microsoft Store app-execution aliases (which exit 9009
with a Store ad even with no Python installed), stale Python 2 installs,
and profile aliases can never false-positive. The `py` launcher and
per-user installs are probed too, so an interpreter missing from an
elevated `PATH` is still found.

- **`Python 3 not found ... SKIPPED`** — no working interpreter found.
  Install one and re-run: `winget install Python.Python.3.12` (or python.org).
- **`GHOST Python core not found (src\python\ghost_cli.py)`** — the
  interpreter is fine but the package is missing (broken checkout, or a
  script copied out of the repo). Re-clone or restore `src/python/`.

Verify the core standalone:

```powershell
python src\python\ghost_cli.py identity
```

In every failure case the script exits 1 so the run is never half-applied
silently — check the audit log for entries with `ok: false`.

## `[FAILED] processes still running after N attempts. Aborting reset.`

The app (or a helper — Cline, Blackbox, Roo extensions) is holding files. Close
every editor window, check Task Manager for the app's processes, then re-run.
The script never proceeds with a target app running: stale handles would
recreate the identity files it just deleted.

## Restoring a reset

Every run writes `restore_<App>_<ts>.ps1` next to the audit log under
`<App>\ID_Backups\<ts>\`. Run it from PowerShell to copy every backed-up file
back to its original location:

```powershell
powershell -ExecutionPolicy Bypass -File "%APPDATA%\<App>\ID_Backups\<ts>\restore_<App>_<ts>.ps1"
```

Only the current run's backup is preserved — older `ID_Backups` timestamp
folders are purged at the end of each successful run (by design: they hold
your OLD fingerprints, which is exactly what the reset is trying to remove).

## A watchdog recreated an identity file

The scripts re-probe core identity files (`Cookies`, `DIPS`, `SharedStorage`,
`machineid`) after a delay and re-delete anything that reappears, recording
`watchdog-recreate` audit entries. If you see repeated recreation, the app's
background service is still running — kill it and re-run.

## ZCode Unlink → Checking loop after reset

`reset_zcode.ps1` strips provider `apiKey` values from `config.json` (step
`[6b/27]`) specifically to break this loop. If you see it again, you are
running an outdated copy of the script.

## OpenCode `FreeTierError` after reset

The server gates on `User-Agent: opencode/<version>` for clients ≥ 1.17.0.
Update the OpenCode CLI (or run with `-SkipVersionCheck` if you know the
version is current).

## MiniMax Code: "Account information is temporarily unavailable" after reset

The toast is MiniMax Code's generic fallback for "startup account-init failed"
— not a ban message. With reset versions ≤ v1.2 it fired on every launch
because the reset emptied
`.minimax\auth\prod\en\mcode-public\auth-state.json` to `{}`. The app's
`@mavis/oauth-core` schema-validates that file (`state-store.js parseState`,
verified in app.asar v3.0.73): `{}` or any partial object throws
`TypeError('Invalid OAuth state.')` on every startup, which is NOT classified
as needing a login, so the app never reaches the login page and every
authenticated request logs `Invalid OAuth state.`.

v1.3 deletes the file instead — a MISSING file is the fresh-install state
(`read()` → null → status `anonymous` → login page). If you still carry the
broken state, close MiniMax Code and delete:

- `%USERPROFILE%\.minimax\auth\prod\en\mcode-public\auth-state.json`
- `%USERPROFILE%\.minimax\auth\prod\en\mcode-public\auth.json`
- `%USERPROFILE%\.minimax\auth\auth-state.json` (legacy root, if present)

Then launch MiniMax Code: it goes straight to the sign-in page. Never
re-create these files by hand as `{}`.

## Telegram bot conflicts (HTTP 409)

One bot token = one polling instance. The clone launcher disables bots in each
clone profile automatically. If you re-enable one in a clone, you will get 409s
and cross-account billing noise — disable it again.

## A ZCode clone lost its icon / color / title after an app update

The per-clone branding rides on an `app.asar` patch (`ZCODE_ICON_DIR`,
`ZCODE_AUMID_SUFFIX`, `ZCODE_ACCENT_HEX`, `ZCODE_INSTANCE_NAME`) that a ZCode
app update silently reverts. Re-apply it once — `GHOST.bat` → ZCode [12], or
`tools\patch_zcode_icon_override.ps1` — and every clone restores its icon,
accent color, taskbar button and "ZCode <Color>" window title.

## A ZCode window drags but its content is dead / relaunch shows the splash then closes

This is a renderer DEATH, not a hang (verified 2026-09-25). The main process
keeps the frame alive — so the window still moves — while the renderer
process is gone; the app documents this exact "empty shell" state in its own
source. The instance's log (`<home>\.zcode\v2\logs\YYYY-MM-DD.log`) records
`render-process-gone reason:"oom"`. That day Primary and Second died in the
same second and Fourth that morning; the archived dump carries
`v8-oom-last-os-error: 1455` (`ERROR_COMMITMENT_LIMIT`) — the Windows commit
limit (RAM + pagefile) was exhausted, with msedge and git crashing the same
minute. Running all four instances amplifies it. This is OS memory
exhaustion, not an app leak, a GPU problem, or a GHOST-side fault.

What to do:

- Run the diagnostic: `GHOST.bat` → ZCode [17]
  (`tools\diagnose_zcode_freeze.ps1`) — prints the per-instance crash
  timeline, dump annotations and live commit pressure.
- After the splash-then-close, just launch the instance again. The quit path
  that closes it right after the splash is the app's post-crash shutdown
  (its log: "all windows closed after preparation, exiting app"), not
  corruption.
- Long-term fix: enlarge the pagefile (System Properties → Advanced →
  Performance Settings → Advanced → Virtual memory; a fixed size around
  1.5-2x RAM, or system-managed) and/or run fewer instances concurrently.
- Not the cause (checked 2026-09-25): GPU caches, the icon asar patch, the
  captcha watchdog (idle since 09-17) and db.sqlite locking.

## Chats from one ZCode instance don't appear in another instance's sidebar

All instances share one session store, but each sidebar index is seeded at
app-server spawn with no snapshot backfill — the data is there, the index is
stale. Refresh without restarting the app: `GHOST.bat` → ZCode [13] (Second
only) or [15] (all instances), or keep the detached watcher running (ZCode [14],
`-Watch -Target All`) to auto-refresh every running instance on quota/captcha
failures. The hot-activity guard may defer the refresh while a turn streams;
`-Force` bypasses it.

## ZCode windows stay merged in one taskbar button even though identities are stamped

The watcher (ZCode [16]) stamps every window's `System.AppUserModel.ID`, but a
taskbar group that was formed while identities were still missing can PERSIST
after the stamps land — the shell does not always re-evaluate an existing
group, and a stale group can even keep the WRONG ICON (verified 2026-09-26:
both windows read `dev.zcode.app` / `dev.zcode.app.2` from their property
stores yet stayed grouped for ~1h; a freshly launched green clone kept the
Primary's icon until an Explorer refresh).

Both stampers therefore KICK the group instead of stamping outright
(automated 2026-09-26): the watcher kicks on every re-stamp and once for
every first-seen window, and the launcher kicks right after pinning — a
brief `.kick`-suffixed identity, then the correct final one, which forces
the shell to rebuild the group and re-resolve the icon (no Explorer refresh
needed). The manual kick below is only a fallback for a stuck window when
no watcher is running:

```powershell
# hwnd from tools\watch_zcode_taskbar.ps1 logs or Get-Process MainWindowHandle
$final = 'dev.zcode.app'   # Primary; clones use dev.zcode.app.<2|3|4>
[ZcodeWindowAumid]::Stamp($hwnd, "$final.kick") ; [ZcodeWindowAumid]::Stamp($hwnd, $final)
```

If the watcher is running it re-stamps the final value within one interval
even if the kick script dies mid-toggle, so this is safe. A silent watcher
log does NOT mean the watcher is dead — check the mutex first (a second
instance logs "watcher already running"). A watcher process started BEFORE
a script edit keeps the old code — close its window and relaunch ZCode [16].

## A clone launched with the Primary's profile or taskbar icon

A bare `ZCode.exe` launch always gets the Primary's profile, AUMID and taskbar
button. Launch clones only via their `ZCode Second/Third/Fourth` shortcuts or
the `Launch-ZCode-*.bat` wrappers. If the Primary's Start-menu pin was taken
over by a clone's AUMID, repair it with
`tools\install_zcode_second_shortcuts.ps1 -RepairPrimaryAumid`.

A pin rewrite can also empty that shortcut icon field (verified 2026-09-28:
the hijacked Start-menu ZCode.lnk carried dev.zcode.app.4 with an empty icon,
so a green clone running alone showed the Primary icon even though its window
identity was correct). -RepairPrimaryAumid now restores the Primary shortcut
icon to <ZCode.exe>,0 too. The resident watcher (ZCode [16]) self-heals a hijack
every ~5 min (REPAIR/FAIL logged to taskbar.log); -RunOnce -CheckPrimaryHijack
repairs once without starting the resident loop. Restart the resident watcher
after any watcher-script edit: an old copy keeps the old code.

## System ID changes need a restart

`change_device_id.ps1` (registry MachineGuid, hostname) and
`change_device_id.sh ResetMachineId` (`/etc/machine-id`) may require a Windows
restart / Linux reboot to fully propagate. Fingerprint mode never changes
anything and needs nothing.

## Script ran, `Fail: 0`, but the app still recognizes the machine

Check the audit log's final probes (storage.json + state.vscdb) — if those
passed, the app-side stores were changed. Remember: IDE storage resets are the
primary mechanism; registry/MachineGuid changes alone do not flip app-side
identity. Also confirm you ran the script for **every** tool the vendor's
backend can correlate (all covered IDEs derive shared telemetry IDs from the
same Windows registry source at first launch).
