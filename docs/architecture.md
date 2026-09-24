# Architecture

GHOST is a flat script toolkit: one shared library per OS, plus one thin
"target manifest" script per application.

## Windows layout

```
src/windows/
├── identity_utils.ps1                 # shared library, dot-sourced by every IDE script
├── reset_<app>.ps1                    # one thin manifest per app
├── change_device_id.ps1               # system-level: fingerprint / registry / profiles
├── launch_zcode_second_instance.ps1   # ZCode clone launcher (-Instance Second|Third|Fourth)
└── Launch-ZCode-Second|Third|Fourth.bat  # double-click wrappers around the launcher
src/python/
├── ghost_cli.py                       # bootstrap: PS scripts call this absolute path
└── ghost/                             # stdlib-only Python core (identity + SQLite logic)
tools/
├── watch_zcode_captcha.ps1            # captcha-stall watchdog (no identity writes)
├── patch_zcode_icon_override.ps1/.mjs # app.asar icon/accent/AUMID patch (engine v6)
├── install_zcode_second_shortcuts.ps1 # clone shortcuts (Desktop + Start menu)
├── refresh_zcode_second_chats.ps1     # cross-instance chat refresh + -Watch watcher
└── zcode-{blue,yellow,green}-branding/  # per-clone icon assets + generator
```

## Shared library API (`identity_utils.ps1`)

| Function | Role |
|---|---|
| `New-IdentitySet` | `{ devDeviceId (GUID), machineId (64 hex), macMachineId (128 hex), sqmId ({GUID}) }` |
| `Assert-Administrator` | exits 1 when not elevated |
| `Stop-AppProcesses` | kill loop with helper expansion (e.g. `Windsurf` → `Devin` + `codeium`) |
| `Backup-FileToTimestampDir` | copy to `<app>\ID_Backups\<ts>\<label>` before any mutation |
| `Set-JsonIdentity` | JSON patch + verify-after re-read |
| `Set-SqliteKeys` | Python-backed SQLite UPSERT + verify-after (invokes `src\python\ghost_cli.py sqlite-update`, parameterized SQL) |
| `Clear-BinaryIdentityStore` | rename or delete binary stores; clobbers stale `.backup` first |
| `Write-AuditLog` | JSON audit entries `{file, key, before, after, ok}` |
| `New-RestoreScript` | emits a self-contained `.ps1` that reverses every recorded change |
| `Get-NewCrashReporterId` | lowercase GUID |

## Python core (`src/python/ghost`)

Stdlib-only Python package that owns the SQLite/JSON identity logic the
PowerShell scripts used to embed as per-call temp `.py` here-strings. The
PowerShell side detects an interpreter (`python`, then `python3`, via
`Get-Command`) and invokes `src\python\ghost_cli.py <command>` — a bootstrap
that puts `src/python` on `sys.path`, so no `PYTHONPATH` or working-directory
assumptions.

| Subcommand | Replaces | Stdout contract |
|---|---|---|
| `sqlite-update <db> <updates_b64> [table]` | `Set-SqliteKeys` temp script | JSON `{before, after}` |
| `delete-secrets <db>` | `reset_zcode.ps1` secrets bridge | JSON `{deleted, survivors}` |
| `clear-cli-telemetry <db>` | `reset_zcode.ps1` [26/27] bridge | JSON `{deleted}` (connect failure → `{deleted: 0, error}` + exit 0) |
| `chat-check missing\|hot <db> [index]` | `refresh_zcode_second_chats.ps1` helper | `COUNT:`/`MISSING:`/`AGE_MS:`/`INFLIGHT_*:` lines |
| `json-patch`, `identity`, `restore-script`, `audit-log` | Python twins of the utils functions | JSON reports |

Payloads travel base64-encoded to sidestep native-argument quoting; values
always use `?` placeholders; table names are validated against
`^[A-Za-z_][A-Za-z0-9_]*$` on both the PowerShell and Python sides; every
mutation is verified by a read-only re-open. Tests:
`tests/python/test_ghost_core.py` (stdlib `unittest`, mirrors the Pester
cases + real-SQLite coverage; CI runs it in the `python-core` job).

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

## Multi-instance isolation (ZCode: Primary + 3 clones)

ZCode runs as four independent instances — Primary (default profile) plus
three branded clones: **Second** (blue), **Third** (yellow), **Fourth**
(green). Isolation rides on process-scoped environment variables
(`ZCODE_DATA_BASE_DIR`, `ZCODE_DESKTOP_USER_DATA_DIR`,
`ZCODE_DESKTOP_SESSION_DATA_DIR`, `ZCODE_DESKTOP_HOME_DIR`, `HOME`) — the app
overwrites `--user-data-dir`, so env vars are the only working lever. Each
clone gets its own home + roaming directory, a first-run seed clone with a
rotated telemetry identity, and an independent ID set on reset
(`reset_zcode.ps1 -Target Primary|Secondary|Third|Fourth|Both|All`).

Visual identity comes from `tools/patch_zcode_icon_override.ps1`, a one-time
`app.asar` patch (engine v6) that honors `ZCODE_ICON_DIR` (branded icon),
`ZCODE_AUMID_SUFFIX` (separate taskbar button + pins), `ZCODE_ACCENT_HEX` +
`ZCODE_INSTANCE_NAME` (accent color + "ZCode <Color>" window title). The patch
also disables the clones' auto-updater so it can never silently revert itself —
an app update wipes it; re-run after every update. Telegram bots are enforced
Primary-only via a per-home marker (one token = one polling instance).

Cross-instance chat visibility is a sidebar-index problem, not a data problem:
all instances share one session store, so `tools/refresh_zcode_second_chats.ps1`
recycles the target instance's app-server (auto-respawn reseeds the index
baseline). Root-cause analysis and the error-triggered `-Watch` mode:
[ZCODE_CHAT_SYNC_WATCHER_PLAN.md](ZCODE_CHAT_SYNC_WATCHER_PLAN.md).

## Testing

`tests/identity_utils.Tests.ps1` unit-tests the shared library against
Pester `TestDrive:` fixtures (the library is side-effect-free on dot-source).
`tests/repo-integrity.Tests.ps1` guards against drift: PowerShell parser
zero-errors, `bash -n`, launcher dispatch targets resolving to real files,
README/script consistency, and governance-file presence. CI runs both on
`windows-latest` plus ShellCheck on `ubuntu-latest`.
