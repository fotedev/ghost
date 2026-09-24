# GHOST CLI — direct commands

Prefer the interactive launchers — **`GHOST.bat`** (Windows, double-click) or
**`./ghost.sh`** (Linux). This page is the direct-command cheat sheet for
scripts and CI.

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
powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target All
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" -Instance Third
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" -Instance Fourth
powershell -ExecutionPolicy Bypass -File "src\windows\reset_minimax_opencode.ps1"
powershell -ExecutionPolicy Bypass -File "src\windows\change_device_id.ps1"
```

## ZCode captcha watchdog (unattended; no admin needed)

```powershell
powershell -ExecutionPolicy Bypass -File "tools\watch_zcode_captcha.ps1"
powershell -ExecutionPolicy Bypass -File "tools\watch_zcode_captcha.ps1" -RunOnce -DryRun   # test first
```

Telegram escalation reads `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` from
`.envlocal` (repo root; git-ignored). NOTE: the watchdog monitors the PRIMARY
instance only.

## ZCode multi-instance (up to 4 independent windows/accounts; Windows only)

```powershell
powershell -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1" [-Instance Second|Third|Fourth]
```

Or double-click: `src\windows\Launch-ZCode-Second.bat` / `-Third.bat` /
`-Fourth.bat`.

First launch of each clone copies history into its own home
(`%USERPROFILE%\ZCodeSecondHome | ZCodeThirdHome | ZCodeFourthHome`), scrubs
it to fresh IDs, and routes Telegram channel bots to Primary (one-time,
automatic). Branding: Second = blue, Third = yellow, Fourth = green (separate
taskbar buttons + window titles "ZCode Blue"/"ZCode Yellow"/"ZCode Green").
All instances share one install, so one update covers all — but re-run the
icon patch (`tools\patch_zcode_icon_override.ps1`, menu [13]) after every app
update; it is what makes the `ZCODE_ICON_DIR` / `ZCODE_AUMID_SUFFIX` /
`ZCODE_ACCENT_HEX` / `ZCODE_INSTANCE_NAME` branding overrides work.

## ZCode clone shortcuts (Desktop + Start menu; per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\install_zcode_second_shortcuts.ps1"
```

Creates `ZCode Second` / `ZCode Third` / `ZCode Fourth` shortcuts (blue /
yellow / green icons) that run the launcher above; a taskbar pin groups with
that clone's running window. Remove with `-Remove`; scope with `-Instance`.

## ZCode cross-instance chat refresh (no app restart; per-user, no admin needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\refresh_zcode_second_chats.ps1" [-Target Primary|Second|Third|Fourth|All]
```

Shows chats created in another instance inside a running sidebar by recycling
the target's app-server (auto-respawn reseeds its index; verify-after). Menu
[15] = Second only, menu [23] = all instances. A hot-activity guard waits out
in-flight turns (`-Force` bypasses). Watcher mode (`-Watch`, menu [22]) tails
the CLI JSONL logs for terminal failures (captcha stall / quota / rate-limit)
and refreshes every RUNNING instance on a 300 s cooldown.

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
failure. Menu [26].

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
