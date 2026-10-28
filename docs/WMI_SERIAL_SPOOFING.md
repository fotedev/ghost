# WMI hardware-serial spoofing (`spoof_wmi_serials.ps1`)

Status: implemented 2026-10-27 (Maintenance [3] / gid 66). Opt-in system-level
script — never part of any IDE reset flow.

## What it does

Rewrites what **WMI** reports for hardware serials by compiling a generated
`.mof` file into the WMI repository (`mofcomp`), plus two registry identity
values GHOST had no coverage for:

| Surface | Values spoofed |
|---|---|
| `Win32_BIOS` | `SerialNumber` |
| `Win32_BaseBoard` | `SerialNumber` |
| `Win32_ComputerSystemProduct` | `IdentifyingNumber`, `UUID` |
| `Win32_SystemEnclosure` | `SerialNumber` |
| `Win32_DiskDrive` | `SerialNumber` (per physical disk) |
| `Win32_PhysicalMemory` | `SerialNumber` (per module) |
| `HKLM\SOFTWARE\Microsoft\SQMClient` | `UserId` (new GUID) |
| `HKLM\SYSTEM\...\BTHPORT\Parameters\Devices\*` | `LocalAddress` (Bluetooth, `-SkipBluetooth` to skip) |

Deliberately NOT touched: CPU (Phase 5 of `change_device_id.ps1` owns
`CentralProcessor`), GPU, NIC MAC (`reset_qoder.ps1` [26]),
`ComputerName`/`MachineGuid`/`ProductId` (`change_device_id.ps1` LegacyReset).

## The technique

The `.mof` redeclares each class in `root\CIMv2` with the `[DYNPROPS]`
qualifier and one `instance` per real instance (real value on the key
property, spoofed serials on the target properties), then compiles with
`mofcomp`. WMI clients (`Get-CimInstance`, the `systeminformation` npm
package many Electron apps use for telemetry) then read the spoofed values.
`#pragma autorecover` records the file so a WMI repository rebuild re-applies
it — as long as the `.mof` still exists at its recorded path (it is preserved
in the run's backup folder).

Class redeclarations use the REAL CIM key property (`Tag` for
`Win32_BaseBoard`/`Win32_SystemEnclosure`, not `Manufacturer`) so the update
merges instead of failing the compile. Unlisted properties survive the merge.
Values are backslash/quote-escaped before they enter the MOF text.

## Honest limits

- **WMI layer only.** Anything reading SMBIOS directly — the
  `HKLM\HARDWARE\DESCRIPTION` tree, `GetSystemFirmwareTable`, kernel drivers
  — still sees the real values. Nothing is written to firmware.
- **Does not move the fingerprint self-test score.** Its weighted signals are
  `cpu.name` + timezone + culture (max 0.19 < the 0.306 needed to flip
  `sameIdentity`; verified ground truth #4). This script is defense-in-depth
  against IDE telemetry that collects serials via WMI, not the primary reset
  mechanism — the per-IDE store rewrites remain that.
- **Not durable across major system events.** Windows feature updates rebuild
  the WMI repository; if the preserved `.mof` was cleaned out of `%TEMP%` the
  autorecover re-apply fails silently. After an update, re-run the script
  (the verify-after reports honestly what still holds).
- **The verify-after is the arbiter.** After compiling, the script re-queries
  every class and compares to the plan. If this box's WMI stack ignores the
  override the run reports FAILED — it can never silently claim a spoof it
  did not observe. Effectiveness was confirmed by the generated values
  reading back, not assumed from the source project.

## Backup / restore contract

Every run creates `%TEMP%\WmiSerialsBackup_<ts>\` (the system-level
convention set by `change_device_id.ps1`) containing:

- `wmi-repo.bak` — full `winmgmt /backup` of the repository. The script
  **aborts before any mutation** if this fails (mutation-refused contract).
- `wmi_serials_before.json` — the pre-run WMI-reported serials.
- `SQMClient.reg` / `BTHPORT_Devices.reg` — pre-run registry exports.
- `spoof_serials.mof` — the compiled MOF (kept for autorecover + re-apply).
- `audit_<ts>.json` — the standard GHOST audit entries.
- `restore_wmiserials_<ts>.ps1` — re-imports the exports, runs
  `winmgmt /restore`, restarts `bthserv`.

## Origin + what was deliberately not ported

Ported from a 2026-10-27 review of Hydra Spoofer 1.5.5 (MIT). Only the
technique was taken; none of the code, because the source had bare `except:`
everywhere, zero verify-after, f-string MOF generation (injection-prone), a
wrong key property for `Win32_BaseBoard`, a fragile restore (recompiling
`cimwin32.mof` leaves the injected instances in place), and a randomized
`DigitalProductId` that can corrupt Windows activation display data. Its
`requirements.txt` lists `discord_webhook`/`python-telegram-bot`/`discord`,
but the reviewed code makes no network exfiltration calls (unused leftovers).

Backlog (not implemented): **volume serial spoofing** via Sysinternals
`Volumeid.exe` — no evidence any covered IDE reads volume serials, and the
Sysinternals license forbids redistribution (would need a user-supplied
binary). Revisit only if a per-IDE investigation surfaces a volume-serial
signal.
