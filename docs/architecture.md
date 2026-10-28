# Architecture

GHOST is a flat script toolkit: one shared library per OS, plus one thin
"target manifest" script per application.

## Windows layout

```
src/windows/
├── identity_utils.ps1                 # shared library, dot-sourced by every IDE script
├── reset_<app>.ps1                    # one thin manifest per app
├── change_device_id.ps1               # system-level: fingerprint / registry / profiles
├── spoof_wmi_serials.ps1              # system-level: WMI serial spoof via mofcomp [DYNPROPS] (+ BT MAC)
├── launch_zcode_second_instance.ps1   # ZCode clone launcher (-Instance Second|Third|Fourth|Fifth|Sixth)
├── Launch-ZCode-Second|Third|Fourth|Fifth|Sixth.bat  # double-click wrappers around the launcher
├── launch_autoclaw_clone.ps1          # AutoClaw clone launcher (-Instance inst1..inst4, -Status)
├── Launch-AutoClaw-Clone.bat          # double-click wrapper (interactive instance picker)
├── launch_autoclaw2_clone.ps1         # AutoClaw2 clone launcher (-Instance c1..c5, -Status)
├── launch_cline_clone.ps1             # Cline clone launcher (-Instance c1..c5, -Status)
├── launch_opencode_clone.ps1          # OpenCode clone launcher (-Instance c1..c5, -Status)
├── launch_autoclaw2_clones_all.ps1    # sequential all-five
├── launch_cline_clones_all.ps1        # sequential all-five (fixed 12s stagger)
├── launch_opencode_clones_all.ps1     # sequential all-five (verify-after staggered)
└── reset_autoclaw.ps1                 # AutoClaw identity reset (-Target Primary|inst1..4|All)
src/python/
├── ghost_cli.py                       # bootstrap: PS scripts call this absolute path
└── ghost/                             # stdlib-only Python core (identity + SQLite logic)
tools/
├── watch_zcode_captcha.ps1            # captcha-stall watchdog (no identity writes)
├── watch_zcode_taskbar.ps1            # resident taskbar-identity watcher + .lnk hijack self-heal
├── diagnose_zcode_freeze.ps1          # read-only renderer-OOM / commit-pressure freeze diagnostic
├── diagnose_zcode_throttle.ps1        # read-only Start-Plan admission throttle diagnostic (CLI-only)
├── set_zcode_bot.ps1                  # per-clone Telegram bot audit (sha8) + sync
├── sync_zcode_assets.ps1              # Primary→clone MCP-definitions / skills / plugin-cache sync (-McpOnly is live-safe)
├── zcode_mcp_merge.ps1                # the pure MCP merge core, unit-tested; consumed by the sync tool + watcher
├── watch_zcode_mcp_sync.ps1           # resident watcher: sync_zcode_assets -McpOnly on every Primary config.json change
├── patch_zcode_icon_override.ps1/.mjs # app.asar icon/accent/AUMID/bidi patch (engine v8)
├── install_zcode_second_shortcuts.ps1 # clone shortcuts (Desktop + Start menu)
├── refresh_zcode_second_chats.ps1     # cross-instance chat refresh + -Watch watcher
├── patch_autoclaw_ports.ps1/.mjs      # app.asar ports + taskbar-identity patch (engine v12)
├── install_autoclaw_clone_shortcuts.ps1 # AutoClaw clone shortcuts (Desktop + Start menu)
├── update_ghost.ps1                   # repo self-updater (git / Download-ZIP paths)
├── make_clone_icon.ps1                # generic per-app clone-icon generator
├── new_clone_suite.ps1                # clone-suite scaffolding generator (playbook phases 3-10)
├── zcode-{blue,yellow,green,red,orange}-branding/      # per-clone icon assets + generator
├── autoclaw-{blue,yellow,green,red}-branding/   # AutoClaw per-clone icons
├── install_cline_clone_shortcuts.ps1  # Cline clone shortcuts (Desktop + Start menu)
├── cline-{blue,yellow,green,red,orange}-branding/  # Cline per-clone icons (orange tint-generated)
├── install_autoclaw2_clone_shortcuts.ps1 # AutoClaw2 clone shortcuts (Desktop + Start menu)
├── autoclaw2-{blue,yellow,green,red,orange}-branding/  # AutoClaw2 per-clone icons (tint-generated)
├── patch_opencode_clone_home.ps1/.mjs # app.asar clone-home + taskbar-identity patch (engine v2)
├── install_opencode_clone_shortcuts.ps1 # OpenCode clone shortcuts (Desktop + Start menu)
└── opencode-{blue,yellow,green,red,orange}-branding/  # OpenCode per-clone icons (orange generated)
```

Two system-level scripts sit above the per-app flow: `change_device_id.ps1`
(fingerprint / registry / profiles) and `spoof_wmi_serials.ps1` — an opt-in
WMI-layer serial spoof (Maintenance [3]) documented separately, including its
winmgmt backup/restore contract and honest limits:
[WMI_SERIAL_SPOOFING.md](WMI_SERIAL_SPOOFING.md).

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
PowerShell side detects an interpreter with a FUNCTIONAL probe (candidates
`python` / `python3` / `py` + per-user install paths are accepted only when
`--version` exits 0 reporting Python 3 — the Microsoft Store app-execution
stubs and stale Python 2 never pass) and invokes
`src\python\ghost_cli.py <command>` — a bootstrap
that puts `src/python` on `sys.path`, so no `PYTHONPATH` or working-directory
assumptions.

| Subcommand | Replaces | Stdout contract |
|---|---|---|
| `sqlite-update <db> <updates_b64> [table]` | `Set-SqliteKeys` temp script | JSON `{before, after}` |
| `delete-secrets <db> [exact_keys] [like_patterns]` | the per-script secrets bridges — generalized for reset_zcode + reset_cursor v0.3 + reset_devin v0.4 | JSON `{deleted, survivors}` |
| `clear-cli-telemetry <db>` | `reset_zcode.ps1` [26/27] bridge | JSON `{deleted}` (connect failure → `{deleted: 0, error}` + exit 0) |
| `chat-check missing\|hot <db> [index]` | `refresh_zcode_second_chats.ps1` helper | `COUNT:`/`MISSING:`/`AGE_MS:`/`INFLIGHT_*:` lines |
| `backup`, `machineid-file`, `salt-rotate`, `json-remove`, `store-delete`, `sweep-file`, `sweep-tree` | the per-step delete/rename/verify PS blocks (Phase 3 thin manifests: reset_cursor v0.3, reset_devin v0.4) | JSON `{ok, path, before, after}` |
| `patch-argv`, `replace-text`, `json-set` | the app-specific PS steps (JSONC argv patch, raw-text scrub, dotted-path JSON set) | JSON reports |
| `json-patch`, `identity`, `restore-script`, `audit-log` | Python twins of the utils functions — `identity` is a manual diagnostic; the others are consumed through the thin-manifest step runners | JSON reports |

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

## Multi-instance isolation (ZCode: Primary + 5 clones)

ZCode runs as six independent instances — Primary (default profile) plus
five branded clones: **Second** (blue), **Third** (yellow), **Fourth**
(green), **Fifth** (red), **Sixth** (orange, 2026-10-24). Isolation rides on
process-scoped environment variables
(`ZCODE_DATA_BASE_DIR`, `ZCODE_DESKTOP_USER_DATA_DIR`,
`ZCODE_DESKTOP_SESSION_DATA_DIR`, `ZCODE_DESKTOP_HOME_DIR`, `HOME`) — the app
overwrites `--user-data-dir`, so env vars are the only working lever. Each
clone gets its own home + roaming directory, a first-run seed clone with a
rotated telemetry identity, and an independent ID set on reset
(`reset_zcode.ps1 -Target Primary|Secondary|Third|Fourth|Fifth|Sixth|Both|All`).

Visual identity comes from `tools/patch_zcode_icon_override.ps1`, a one-time
`app.asar` patch (engine v8) that honors `ZCODE_ICON_DIR` (branded icon),
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
profile) plus four numbered clones, `inst1`–`inst4`, under
`%USERPROFILE%\AutoClawCloneHome\instN\{home,profile,tmp}`. Unlike ZCode, the
app **honours `--user-data-dir`** (the single-instance lock keys off the
profile dir) — and it is the load-bearing lever, because AutoClaw.exe's
manifest declares `requireAdministrator`: every launch self-elevates and the
elevated process gets a FRESH ENVIRONMENT, so the env levers
(`USERPROFILE`/`HOME`/`TEMP`/`AUTOCLAW_GATEWAY_PORT`) set by the launcher
never survive. Isolation therefore rides arguments + marker files: the
launcher elevates its own `cmd /c start` via `-Verb RunAs` so the args ride a
plain CreateProcess; the patched engine's `home-override` (v10+) reads
`<userData>\.autoclaw-home` and redirects the whole `~/.openclaw-autoclaw`
state tree; and the per-clone gateway port lives in the clone's
`settings.json` `gateway.port` (a busy port silently shifts up to +9, so the
launcher reads the actually-bound port back and records it —
`instance-record.json`, `launch_autoclaw_clone.ps1 -Status`). Taskbar
identity v2 (patch engine v12) additionally stamps per-clone process + window
AUMIDs, icons and "AutoClaw <Color>" titles from the
`.autoclaw-identity.json` marker the launcher writes on every launch.

The MCP HTTP server binds a **hardcoded 4-slot port array**
(`19681–19684`) in the Electron main process — the multi-instance ceiling —
so `tools/patch_autoclaw_ports.ps1` (+ `.mjs` engine v12 — ports plus the
taskbar-identity families) widens it to 8 slots in the installed `app.asar`
(backup + marker + `-Restore`; an app update reverts it). Verified design constraints and the port plan live in
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
`openclaw.json` hash unchanged across the cycle. The first-run seed is gated
on the Primary's PROFILE LOCKFILE (never "any AutoClaw.exe process" — a
running clone must not block another clone's first launch), and no
gateway/MCP ports answer until that one manual login completes (the sign-in
screen never signals UI-ready, so the embedded gateway start stays parked).
`reset_autoclaw.ps1 -Target Primary|inst1|inst2|inst3|inst4|All` repeats the
rotation on demand. Every instance's `settings.json` gets
`system.autoUpdate: false` — any auto-update would replace the patched asar.

## Multi-instance isolation (OpenCode desktop: Primary + 5 clones)

OpenCode desktop (Electron 2.0.32, asInvoker) runs as Primary plus five
clones under `%USERPROFILE%\OpenCodeClonesHome\c1..c5\{desktop,session,data,
config,cache,state}`. Packaged builds hardcode the Electron userData, so
isolation needs the one-time **clone-home asar patch**
(`tools/patch_opencode_clone_home.ps1`, engine v2): the argv flag
`--opencode-clone-home=<dir>` feeds the app's own test-mode bootstrap, which
pins userData/sessionData per clone and sets the four `XDG_*` env vars the
app reads unconditionally for its CLI state. The per-clone userData gives
each clone its own single-instance lock natively, and the same patch wraps
the app's single `setAppUserModelId` call + a `browser-window-created`
listener for per-clone taskbar identity (identity rides pure argv — the
main bundle is ESM with no `require`). Service ports are ephemeral per
instance. Design + live verification:
[docs/OPENCODE_CLONES_SPEC.md](OPENCODE_CLONES_SPEC.md).

## Multi-instance isolation (Cline: Primary + 5 clones)

Cline desktop (Tauri 2.11.1 / WebView2 — no asar, nothing patchable) runs
as Primary plus five clones under `%USERPROFILE%\ClineClonesHome\c1..c5\`:
`CLINE_DIR` relocates the whole state tree, `WEBVIEW2_USER_DATA_FOLDER`
gives each clone its own web login profile, and fixed per-clone hub/sidecar
ports (25471..25475 / 3131..3135) sit outside the stock defaults. The
app's fixed-key tauri-plugin-single-instance guard (session mutex + hidden
window) is neutralized by the launcher — it renames the hidden window
pre+post launch — which then enforces per-clone single-instance itself via
the clone's own hub-lock probe. Shortcut pins carry `bot.cline.app.c1..c5`
+ per-color icons; running windows share the base identity (reported
degraded by developer decision). Design:
[docs/CLINE_CLONES_SPEC.md](CLINE_CLONES_SPEC.md).

## Multi-instance isolation (AutoClaw2: Primary + 5 clones)

AutoClaw2 (Electron, asInvoker) needs no patching at all: `ZWORK_USER_DATA`
pins each clone's whole userData BEFORE the native per-profile
single-instance lock, so N copies coexist natively under
`%USERPROFILE%\AutoClaw2ClonesHome\c1..c5\`, while `AUTOCLAW_PROFILE_ROOT`
relocates the legacy v1.x migration source so no clone reads a live
Primary's state. The app generates a fresh device id per profile (no
seeding, no credential copying; one manual sign-in per clone) — app
updates break nothing. NOT wired into `GHOST.bat`; run the launchers
directly. Design: [docs/AUTOCLAW2_CLONES_SPEC.md](AUTOCLAW2_CLONES_SPEC.md).

## Testing

`tests/identity_utils.Tests.ps1` unit-tests the shared library against
Pester `TestDrive:` fixtures (the library is side-effect-free on dot-source).
`tests/repo-integrity.Tests.ps1` guards against drift: PowerShell parser
zero-errors, `bash -n`, launcher dispatch targets resolving to real files,
README/script consistency, and governance-file presence.
`tests/python/test_ghost_core.py` mirrors those cases for the Python core and
adds real-SQLite coverage (stdlib `unittest`, zero dependencies).
`tests/zcode_mcp_merge.Tests.ps1` pins the MCP merge invariant itself (clone-local
toggles survive, clone-only servers kept, new servers inherit the Primary's
value, Primary definitions win). CI runs the
analyzer + Pester jobs on `windows-latest`, ShellCheck on `ubuntu-latest`,
and the Python suite in a dedicated `python-core` job.
