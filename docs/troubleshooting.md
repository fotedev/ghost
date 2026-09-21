# Troubleshooting

## `[FAILED] Python not found -- secrets deletion SKIPPED`

The Windows IDE scripts shell out to Python for SQLite writes
(`state.vscdb`). Install Python 3 and make sure `python` (or `python3`) is on
`PATH`, then re-run. The script exits 1 on missing Python so the run is never
half-applied silently — check the audit log for entries with `ok: false`.

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

## Telegram bot conflicts (HTTP 409)

One bot token = one polling instance. The second-instance launcher disables
bots in the Secondary profile automatically. If you re-enable one there, you
will get 409s and cross-account billing noise — disable it again.

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
