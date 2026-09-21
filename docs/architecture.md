# Architecture

GHOST is a flat script toolkit: one shared library per OS, plus one thin
"target manifest" script per application.

## Windows layout

```
src/windows/
├── identity_utils.ps1        # shared library, dot-sourced by every IDE script
├── reset_<app>.ps1           # one thin manifest per app
├── change_device_id.ps1      # system-level: fingerprint / registry / profiles
└── launch_zcode_second_instance.ps1 + .bat
tools/
└── watch_zcode_captcha.ps1   # standalone watchdog (no identity writes)
```

## Shared library API (`identity_utils.ps1`)

| Function | Role |
|---|---|
| `New-IdentitySet` | `{ devDeviceId (GUID), machineId (64 hex), macMachineId (128 hex), sqmId ({GUID}) }` |
| `Assert-Administrator` | exits 1 when not elevated |
| `Stop-AppProcesses` | kill loop with helper expansion (e.g. `Windsurf` → `Devin` + `codeium`) |
| `Backup-FileToTimestampDir` | copy to `<app>\ID_Backups\<ts>\<label>` before any mutation |
| `Set-JsonIdentity` | JSON patch + verify-after re-read |
| `Set-SqliteKeys` | Python-backed SQLite UPSERT + verify-after (temp `.py` in `$env:TEMP`, parameterized SQL) |
| `Clear-BinaryIdentityStore` | rename or delete binary stores; clobbers stale `.backup` first |
| `Write-AuditLog` | JSON audit entries `{file, key, before, after, ok}` |
| `New-RestoreScript` | emits a self-contained `.ps1` that reverses every recorded change |
| `Get-NewCrashReporterId` | lowercase GUID |

## The per-script step pattern

Every IDE reset script follows the same skeleton:

```
dot-source identity_utils -> Assert-Administrator -> Stop-<App>Processes
-> New-IdentitySet -> per-target [n/N] steps (backup -> mutate -> verify)
-> audit log (audit_<ts>.json) -> restore script (restore_<App>_<ts>.ps1)
-> summary (Pass/Fail counts, exit 1 on any failure)
```

Two invariants hold across all scripts:

1. **No silent success** — every write is re-read and compared; a mismatch is a
   `FAILED` line and an audit entry with `ok = false`.
2. **Chat history and workspaces are never deleted** — chat stores,
   `Local Storage`, `Backups\`, and `User\workspaceStorage` are preserved
   (workspace DBs get an UPSERT of `storage.serviceMachineId` only).

## Multi-root design (`reset_devin.ps1`)

Windsurf rebranded to Devin Desktop (June 2026, over-the-air update), so a
machine can carry the legacy `%APPDATA%\Windsurf` root and the new
`%APPDATA%\Devin` root side by side. The script:

- probes `%APPDATA%` for `Devin` and `Windsurf` (NTFS is case-insensitive) and
  resets **every root that exists**, in one pass, with one shared identity set;
- gives each root its **own** `ID_Backups\<ts>` folder (no backup-label
  collisions), with the combined audit + restore script in the primary root;
- treats rebrand-era extras as first-class targets: `credentials.toml`,
  `config.json devin.org_id`, `cli\installation_id`, `.devin\argv.json`;
- verified non-targets (documented, never touched): `%USERPROFILE%\.devin-shared`
  and `%LOCALAPPDATA%\devin` (CLI binaries only).

## Dual-instance isolation (ZCode)

Two independent ZCode windows are isolated with process-scoped environment
variables (`ZCODE_DATA_BASE_DIR`, `ZCODE_DESKTOP_USER_DATA_DIR`,
`ZCODE_DESKTOP_SESSION_DATA_DIR`, `ZCODE_DESKTOP_HOME_DIR`, `HOME`) — the app
overwrites `--user-data-dir`, so env vars are the only working lever. Resets
run per-target with independent ID sets; Telegram bots are enforced Primary-only.

## Testing

`tests/identity_utils.Tests.ps1` unit-tests the shared library against
Pester `TestDrive:` fixtures (the library is side-effect-free on dot-source).
`tests/repo-integrity.Tests.ps1` guards against drift: PowerShell parser
zero-errors, `bash -n`, launcher dispatch targets resolving to real files,
README/script consistency, and governance-file presence. CI runs both on
`windows-latest` plus ShellCheck on `ubuntu-latest`.
