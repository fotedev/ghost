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
├── Launch-ZCode-Second|Third|Fourth.bat  # double-click wrappers around the launcher
├── launch_autoclaw_clone.ps1          # AutoClaw clone launcher (-Instance inst1..inst4, -Status)
├── Launch-AutoClaw-Clone.bat          # double-click wrapper (interactive instance picker)
└── reset_autoclaw.ps1                 # AutoClaw identity reset (-Target Primary|inst1..4|All)
src/python/
├── ghost_cli.py                       # bootstrap: PS scripts call this absolute path
└── ghost/                             # stdlib-only Python core (identity + SQLite logic)
tools/
├── watch_zcode_captcha.ps1            # captcha-stall watchdog (no identity writes)
├── patch_zcode_icon_override.ps1/.mjs # app.asar icon/accent/AUMID patch (engine v7)
├── install_zcode_second_shortcuts.ps1 # clone shortcuts (Desktop + Start menu)
├── refresh_zcode_second_chats.ps1     # cross-instance chat refresh + -Watch watcher
├── patch_autoclaw_ports.ps1/.mjs      # app.asar MCP-port-array patch, 4 -> 8 slots (engine v1)
├── install_autoclaw_clone_shortcuts.ps1 # AutoClaw clone shortcuts (Desktop + Start menu)
└── zcode-{blue,yellow,green}-branding/  # per-clone icon assets + generator
```

## Shared library API (`identity_utils.ps1`)

| Function | Role |
|---|---|
| `New-IdentitySet` | `{ devDeviceId (GUID), machineId (64 hex), macMachineId (128 hex), sqmId ({GUID}) }` |
| `Assert-Administrator` | exits 1 when not elevated |
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
| `json-patch`, `identity`, `restore-script`, `audit-log` | Python twins of the utils functions — `identity` is a manual diagnostic; the other three have no production caller today (kept as scaffolding for the planned PS→Python migration) | JSON reports |

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
`app.asar` patch (engine v7) that honors `ZCODE_ICON_DIR` (branded icon),
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

## Multi-instance isolation (AutoClaw: Primary + 4 clone slots)

AutoClaw (Electron 33, `C:\Program Files\AutoClaw`) runs as Primary (default
profile) plus up to four numbered clones, `inst1`–`inst4`, under
`%USERPROFILE%\AutoClawCloneHome\instN\{home,profile,tmp}`. Unlike ZCode, the
app **honours `--user-data-dir`** (the single-instance lock keys off the
profile dir), so the launcher passes it as a second belt-and-braces layer on
top of the env levers: `USERPROFILE`/`HOME` (the gateway derives its whole
`~/.openclaw-autoclaw` state tree from `os.homedir()`), `TEMP`/`TMP`/`TMPDIR`,
and `AUTOCLAW_GATEWAY_PORT` (supported override; a busy port silently shifts
up to +9, so the launcher reads the actually-bound port back and records it —
`instance-record.json`, `launch_autoclaw_clone.ps1 -Status`).

The MCP HTTP server binds a **hardcoded 4-slot port array**
(`19681–19684`) in the Electron main process — the multi-instance ceiling —
so `tools/patch_autoclaw_ports.ps1` (+ `.mjs` engine v1) widens it to 8 slots
in the installed `app.asar` (backup + marker + `-Restore`; an app update
reverts it). Verified design constraints and the port plan live in
[docs/AUTOCLAW_CLONES_SPEC.md](AUTOCLAW_CLONES_SPEC.md).

Identity is stricter than ZCode's: AutoClaw keeps TWO device identities
(`auth.json` `deviceId` + `identity\device.json` ed25519 keypair) and one
live operator credential (`devices\paired.json`, admin-scoped). The first-run
seed copies the Primary profile **excluding every credential store**
(`token-cache.json`, `*.backup`, tokens stripped from `auth.json` — `userInfo`
kept, so the clone opens on the account and needs one manual login), rotates
the cloned identities, and never touches the gateway state tree (fresh per
clone; the gateway regenerates `paired.json`). The clone's launcher then
verifies: process tree stable, `/health` on its discovered MCP + gateway
ports, `paired.json` holding only its own key, and the Primary's
`openclaw.json` hash unchanged across the cycle.
`reset_autoclaw.ps1 -Target Primary|inst1|inst2|inst3|inst4|All` repeats the
rotation on demand. Every instance's `settings.json` gets
`system.autoUpdate: false` — any auto-update would replace the patched asar.

## Testing

`tests/identity_utils.Tests.ps1` unit-tests the shared library against
Pester `TestDrive:` fixtures (the library is side-effect-free on dot-source).
`tests/repo-integrity.Tests.ps1` guards against drift: PowerShell parser
zero-errors, `bash -n`, launcher dispatch targets resolving to real files,
README/script consistency, and governance-file presence.
`tests/python/test_ghost_core.py` mirrors those cases for the Python core and
adds real-SQLite coverage (stdlib `unittest`, zero dependencies). CI runs the
analyzer + Pester jobs on `windows-latest`, ShellCheck on `ubuntu-latest`,
and the Python suite in a dedicated `python-core` job.
