# AGENTS.md — clean-slate-kit

## Project overview

Fresh-start toolkit for local AI-IDE identity stores — **Cursor**, **Windsurf**, **Trae**, **Qoder**, **ZCode**, **QoderWork**, **MiniMax Agent/OpenCode** — for privacy hygiene, multi-account testing, and dev-environment resets. Windows PowerShell (primary) and Linux Bash scripts.

## Repository layout

```
README.md  how-to-run.bat/txt/sh   # root launchers (scripts live under scripts/)
scripts/windows/                   # current .ps1 resetters + identity_utils.ps1 + change_device_id.ps1
                                   #   (superseded Qoder v0.3 / ZCode v1.1 moved to archive/)
scripts/linux/                     # .sh scripts (id_reset_common.sh + per-IDE resetters)
docs/                              # AGENTS.md, IMPLEMENTATION_GUIDE/PLAN, WALKTHROUGH, research notes
archive/                           # superseded versions (fallbacks — do not run)
tools/                             # reviewed utilities (block_qoder_domains.ps1,
                                   #   watch_zcode_captcha.ps1 — captcha-stall watchdog;
                                   #   Telegram creds via params or .envlocal at repo root)
.trash/                            # moved-aside junk (git-ignored, never committed)
```

## Architecture

```
scripts/windows/identity_utils.ps1  # Shared library, dot-sourced by all IDE scripts
  New-IdentitySet                  #   -> { devDeviceId, machineId, macMachineId, sqmId }
  Assert-Administrator             #   -> exit 1 if not elevated
  Stop-AppProcesses                #   -> kill loop (auto-expands Windsurf->codeium, Trae->Broker)
  Backup-FileToTimestampDir        #   -> copy to <app>\ID_Backups\<ts>\<label>
  Set-JsonIdentity                 #   -> JSON patch + verify-after re-read
  Set-SqliteKeys                   #   -> Python-backed UPSERT + verify-after (uses $env:TEMP for .py)
  Clear-BinaryIdentityStore        #   -> rename or delete; clobbers old .backup first
  Write-AuditLog                   #   -> JSON audit with {file, key, before, after, ok}
  New-RestoreScript                #   -> self-contained .ps1 that reverses all changes
  Get-NewCrashReporterId           #   -> lowercase GUID

reset_cursor_windows-v0.2.ps1     # Cursor: 15 steps (machineid, storage.json, state.vscdb,
                                   #          auth-secrets scrub, device_id_salt, os_crypt rotation,
                                   #          Cookies/NPS/sentry/DIPS/Trust Tokens/Crashpad/logs, workspace DBs)
reset_windsurf_windows-v0.2.ps1    # Windsurf: 16 steps (above + argv.json crash-reporter-id,
                                   #            .codeium\config.json device_id, .windsurf\installation_id,
                                   #            Preferences/Local State username scrub)
reset_trae_windows-v0.2.ps1      # Trae: 16 steps (above + aha delete,
                                   #         ModularData\ckg_server\local_env.json device_id+host_map,
                                   #         ai-agent identity-rows-only scrub (chat preserved), SharedStorage,
                                   #         Partitions\trae-webview, iCubeAuthInfo://* removal,
                                   #         has_device_id_updated_to_aha=false)
reset_qoder_windows-v0.4.ps1       # Qoder: 31 steps (main + CORS_Profile, expanded
                                   #          state.vscdb scrub incl. loginBroadcast +
                                   #          secret.local.machine.variables, .qoder
                                   #          installation_id/.auth machine_id rotation,
                                   #          webview stores, tmp/telemetry+logs, probe;
                                   #          system steps: HKCU deviceid, HKLM SQM, MAC, hostname)
reset_zcode_windows-v1.3.ps1       # ZCode: 27 steps + [6b/27] config.json provider-apiKey strip
                                   #          (Unlink-loop fix) + telemetry-state deviceMid, RUM store,
                                   #          setting.json deviceSid, embedded-browser partition
reset_qoderwork_windows-v0.1.ps1   # QoderWork: 26 steps (agents.db oauth/app_settings scrub,
                                   #          chats preserved; auth.dat, MachineGuid, MAC, hostname;
                                   #          -SkipMac/-SkipHostname/-DryRun)
reset_minimax_opencode_windows-v1.1.ps1  # MiniMax/OpenCode: 22 steps (auth.json wipe -> {} unless
                                   #          -KeepLogin, version preflight ≥1.17.0, distinct
                                   #          updater IDs, Chromium state per profile; chat preserved)
change_device_id.ps1              # System-level: Fingerprint (self-test) / LegacyReset (registry GUIDs)
                                   #   / RepairProfiles (ProfileList .bak keys). Windows-only.
```
(All .ps1 above live in scripts/windows/; .sh scripts in scripts/linux/;
older Qoder v0.1-v0.3 / ZCode v1.0-v1.2 (+ Cursor/Windsurf/Trae v0.1) files
live in archive/ as fallbacks — do not run them.)

Each IDE script is a **thin target manifest**: dot-source utils -> Assert-Admin -> Stop-App -> New-IdentitySet -> per-target [n/N] steps with verify-after -> audit log -> restore script -> summary.

## Verified ground truth (do not contradict these)

1. All covered IDEs derive **shared** telemetry IDs (`telemetry.machineId`, `.sqmId`, `.devDeviceId`, `.macMachineId`) from the same Windows registry source at first launch. Resetting one but not the others leaves a cross-IDE correlation trail.
2. SQLite must use **Python** (`Get-Command python` / `python3`). .NET SQLite assemblies are NOT registered on this box. `Set-SqliteKeys` in `identity_utils.ps1` handles Python detection + graceful skip.
3. Registry GUID changes (`HKLM:\...\Cryptography\MachineGuid` etc.) do **NOT** affect the fingerprint self-test — the algorithm reads WMI hardware/OS signals (CPU, BIOS, motherboard, RAM, timezone), not those registry keys.
4. The max reliably-changeable fingerprint-signal weight is **0.19** (CPU name 0.12 + tz 0.03 + culture 0.02 + ui.language 0.02), which is below the **0.306** delta needed to flip `sameIdentity` to false. Therefore IDE storage rewrites are the **primary** unbanning mechanism, not the fingerprint self-test.
5. `IMPLEMENTATION_GUIDE.md` is the verified ground truth. Do not trust comments in old scripts — several describe behavior verified NOT to work.

## Mandatory conventions

- **Never silent-success.** Every write must be followed by a re-read and comparison. If a value doesn't match after write, emit `FAILED` and record in the audit log. This is the single most important anti-pattern to avoid.
- **Detect Python via `Get-Command`.** Fall back to `python3`. Never hardcode a Python path.
- **Write temp `.py` to `$env:TEMP`.** Never next to the database file (clutters user dirs).
- **Parameterize SQL.** Never f-string/interpolate values into SQL. Use `?` placeholders.
- **"File existed" is not "value changed".** A backup existing does not mean the new ID is in place. Always verify.
- **Clobber old `.backup` before renaming.** If `target.backup` already exists, remove it first — otherwise `Rename-Item` fails.
- **Never re-add dead SMBIOS/build registry writes.** `SystemManufacturer`, `SystemProductName`, `BIOSVersion`, `CurrentBuild`, `CurrentBuildNumber` — WMI ignores them. See `IMPLEMENTATION_GUIDE.md §5`.

## PowerShell 5.1 compatibility

- Use `RandomNumberGenerator.Create()` + `.GetBytes()` — NOT `.Fill()` (which is .NET Core / .NET 5+ only).
- Never name a variable `$Input` — it's a reserved automatic variable in PS 5.1.
- Never use ternary operator `? :` — it's PS 7+ only. Use `if/else`.
- `ConvertFrom-Json` returns `PSCustomObject`, not `[hashtable]`. Normalize with `ConvertTo-Hashtable` before passing to `[hashtable]`-typed parameters.

## Batch (.bat) launcher rules

- Never use bare `(` / `)` in an `echo` (or any) line inside a parenthesized
  `if (...) (...)` block — CMD treats `)` as the block terminator even inside
  double quotes, aborting the whole script silently. Reword to avoid parens
  (e.g. `a separate window - leave it open`) or escape as `^( ^)`.
  (Bit us in `how-to-run.bat` option [9]: the parent menu vanished instantly.)

## Out of scope

- Linux `.sh` scripts (separate effort)
- `.context/` directory (tool configuration — do not modify)
- `.git/` (do not modify)
- `change_device_id.ps1` (edit only per an explicit Phase-5 task)
- `identity_utils.ps1` (tested and shared — do not modify unless fixing a bug that affects all IDE scripts)

## Working preferences

- **Do NOT auto-commit.** Leave changes in the working tree for review. The user handles versioning.
- **Windows-first.** This is a Windows PowerShell project. Linux scripts exist but are out of scope for changes.
- **Run IDE scripts as Administrator** with the target app **closed first**. Each script calls `Assert-Administrator` and `Stop-AppProcesses` early.
- **Follow the Cursor pattern.** `scripts/windows/reset_cursor_windows-v0.2.ps1` is the canonical reference implementation (v0.1 has the BOM + rename-leaves-old-fingerprint bugs). New IDE scripts should mirror its structure, local helpers, and error handling.
- **Parse-check before declaring done.** Use `[System.Management.Automation.Language.Parser]::ParseFile` to verify syntax of every `.ps1` change.
