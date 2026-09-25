# Getting started — per-tool walkthroughs

Prerequisites are in the [main README](../README.md#prerequisites). Every reset
script is backup-first, verify-after, and leaves a timestamped `ID_Backups\<ts>`
folder with an audit log and a self-contained restore script.

## Windows

Scripts live in `src/windows/`. Run PowerShell **as Administrator** from the
repo root, or use `GHOST.bat` (interactive menu).

```powershell
.\src\windows\reset_cursor.ps1
.\src\windows\reset_devin.ps1
.\src\windows\reset_zcode.ps1 -Target Primary
.\src\windows\change_device_id.ps1
```

### 1. Reset Cursor ID (`reset_cursor.ps1`)

- Creates fresh identification numbers via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys), `state.vscdb` (`storage.serviceMachineId`), deletes auth secrets (`cursorAuth/*`, `secret://cursorAuth/openAIKey`), rotates `device_id_salt` + `os_crypt.encrypted_key`, deletes Cookies / Network state / sentry / DIPS / Trust Tokens / Crashpad / logs / workspace DB entries (never the workspace files)
- Self-elevates to Administrator, aggressive process tree-kill, watchdog re-verify, old `ID_Backups` purge
- Every write is verified by re-reading; audit log + restore script are generated

**Before running:** Close Cursor. Run PowerShell as Administrator.

### 2. Reset Windsurf / Devin Desktop ID (`reset_devin.ps1`)

- Windsurf rebranded to **Devin Desktop** (June 2026, over-the-air) — the script auto-detects every existing data root under `%APPDATA%` (`Devin`, `Windsurf`) and resets **all** of them in one pass
- Resets Windsurf/Devin and Codeium configuration via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys), `state.vscdb`, deletes auth secrets (`codeium.windsurf-windsurf_auth`, `windsurf_auth-*` + devin-named candidates), `argv.json` in `.windsurf` **and** `.devin` (`crash-reporter-id`, JSONC comments preserved), `.codeium\config.json` (`device_id`), `.windsurf\installation_id` + `cli\installation_id`, deletes `credentials.toml` (auth token), blanks `config.json` `devin.org_id`, scrubs username from Preferences/Local State, deletes Cookies / Network state / DIPS / extended cache dirs
- Timestamped backups + audit log under each root's `%APPDATA%\<root>\ID_Backups\<ts>`

**Before running:** Close Windsurf / Devin Desktop. Run PowerShell as Administrator.

### 3. Reset Trae ID (`reset_trae.ps1`)

- Resets Trae configuration via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys + removes `iCubeAuthInfo://*` + `has_device_id_updated_to_aha=false`), `state.vscdb`, `ModularData\ckg_server\local_env.json` (`device_id` + `host_map`), deletes `aha` (encrypted TinyStorage), scrubs only identity rows in `ModularData\ai-agent` (**chat preserved**), Cookies / Network state / DIPS / SharedStorage / `Partitions\trae-webview` / workspace DB entries
- Timestamped backups + audit log under `%APPDATA%\Trae\ID_Backups\<ts>`

**Before running:** Close Trae. Run PowerShell as Administrator.

### 4. Reset Qoder ID (`reset_qoder.ps1`)

- 31 steps: `storage.json` (4 telemetry keys, main + `CORS_Profile`), `machineid`, `argv.json` (`crash-reporter-id`), `state.vscdb` + expanded auth-secrets delete (`aicoding.auth.*` incl. `loginBroadcast`, `secret.local.machine.variables`, `secret://blackbox.*`), `device_id_salt`, `os_crypt` rotation, browser data, `Crashpad`/`SharedClientCache`/`logs`, `.qoder` cache subdirs (reparse-point-safe), workspace UPSERT-only, plus system steps (HKCU deviceid, HKLM SQM MachineId, MAC, hostname — opt-out via `-SkipMac`/`-SkipHostname`), plus device-flow steps (`.qoder\installation_id` + `.auth\machine_id` rotation, credential/dns/endpoint cache delete, IndexedDB/Partitions/Storage webview purge, `.qoder\tmp\telemetry` + `logs` cleanup, read-only device-flow final probe)
- Timestamped backups + audit log under `%APPDATA%\Qoder\ID_Backups\<ts>`

**Before running:** Close Qoder. Run PowerShell as Administrator.

### 5. Reset ZCode ID (`reset_zcode.ps1`)

- 27 steps + `[6b/27]`: everything Qoder-side above (for the Qoder stores ZCode shares) plus `.updaterId`, `telemetry-state.json` (`deviceMid`), credentials OAuth clear, **config.json provider `apiKey` strip (fixes the Unlink → Checking loop)**, coding-plan-cache invalidation, RUM store, `setting.json` (`deviceSid`), session/embedded-browser Chromium data
- Chat stores (`tasks-index.sqlite`, checkpoints, IndexedDB webview data, Local Storage leveldb) are never touched
- Timestamped backups + audit log under `%APPDATA%\ZCode\ID_Backups\<ts>` (per-target: Secondary uses `%APPDATA%\ZCode-Second\ID_Backups\<ts>`, Third `%APPDATA%\ZCode-Third`, Fourth `%APPDATA%\ZCode-Fourth`)
- `-Target Primary` (default reset scope + Qoder steps), `-Target Secondary|Third|Fourth` (selective tree-kill, survivors keep running, Qoder untouched), `-Target Both` (Secondary then Primary, back-compat), `-Target All` (Third + Fourth + Secondary, then Primary incl. Qoder; each child generates its OWN fresh ID set — IDs are never duplicated across instances)

**Before running:** close only the TARGET instance (the script kills it; survivors keep running in Single mode). Run PowerShell as Administrator. After the reset, ZCode prompts for a fresh login. `change_device_id.ps1` is machine-wide and affects ALL instances + Qoder.

### 5b. ZCode clones (multi-instance setup: Primary + Second + Third + Fourth)

Run up to four fully independent ZCode windows side by side (separate Electron locks, separate SQLite stores, separate accounts):

```powershell
# Option A — menu: GHOST.bat → ZCode [1] Second / [3] Third / [4] Fourth / [5] all clones
# Option B — double-click: src\windows\Launch-ZCode-Second.bat / -Third.bat / -Fourth.bat
powershell -File src\windows\launch_zcode_second_instance.ps1 -Instance Third   # example
```

First launch of each clone copies history (`~\.zcode` → `~\ZCodeSecondHome\.zcode` / `ZCodeThirdHome` / `ZCodeFourthHome`, journals excluded), then scrubs the clone to fresh independent IDs (deviceMid, deviceSid, OAuth tokens, provider apiKeys) and routes Telegram bots to Primary only (marker-guarded, runs once per clone — a deliberate re-enable is never reverted). Later launches reuse the independent profile. Isolation is driven by five process-scoped env vars (`ZCODE_DATA_BASE_DIR`, `ZCODE_DESKTOP_USER_DATA_DIR`, `ZCODE_DESKTOP_SESSION_DATA_DIR`, `ZCODE_DESKTOP_HOME_DIR`, `HOME`) — the app overwrites `--user-data-dir`, so env vars are the only working lever. All instances share one install: a single update covers all, but re-run the icon patch (ZCode [12]) after updates. Clone branding: Second = blue, Third = yellow, Fourth = green (separate taskbar buttons + window titles "ZCode Blue"/"ZCode Yellow"/"ZCode Green"). Telegram channel bots must live on ONE instance only (two pollers on one token cause HTTP 409 conflicts and random cross-account billing); the launcher enforces Primary-only automatically.

### 5c. ZCode clone utilities (`tools/`)

| Menu | Script | What it does |
|---|---|---|
| ZCode [12] | `tools\patch_zcode_icon_override.ps1` | One-time `app.asar` patch (engine v6) enabling the `ZCODE_ICON_DIR` / `ZCODE_AUMID_SUFFIX` / `ZCODE_ACCENT_HEX` / `ZCODE_INSTANCE_NAME` overrides — per-clone icon, separate taskbar button + pins, accent color, "ZCode <Color>" window title. Auto-detects the install dir; re-run after **every ZCode app update**. `-Restore` rolls back, `-Force` re-patches, `-InstallDir` overrides detection; the marker file auto-upgrades patches made by older engines. |
| ZCode [2] | `tools\install_zcode_second_shortcuts.ps1` | Desktop + Start-menu shortcuts for all three clones (`ZCode Second/Third/Fourth.lnk`), each stamped with its own AppUserModel ID so taskbar pins never collide with the Primary. `-Instance Second\|Third\|Fourth` scopes, `-Remove` uninstalls, `-RepairPrimaryAumid` strips a stray clone AUMID from the Primary's `ZCode.lnk`. |
| ZCode [13] / [15] | `tools\refresh_zcode_second_chats.ps1` | Shows chats created in another instance inside a running sidebar, no app restart: finds shared-store chats missing from the target's tasks-index, recycles its app-server(s) (auto-respawn reseeds the index), then verifies. `-Target Primary\|Second\|Third\|Fourth\|All`; a hot-activity guard waits out in-flight turns (up to ~90 s, `-Force` bypasses). ZCode [13] = Second only, [15] = all instances. |
| ZCode [14] | same script, `-Watch -Target All` | Detached watcher: tails the CLI JSONL logs for terminal failures (captcha stall / quota / rate-limit — same signatures as `watch_zcode_captcha.ps1`) and refreshes every RUNNING instance on a 300 s cooldown. |

### 6. Reset QoderWork ID (`reset_qoderwork.ps1`)

- 26 steps: `machine-id`, `installation_id`, `.status.json`, Chromium profile (`Preferences` salt, Cookies, Local/Session Storage, caches, SharedStorage, `Local State`), `agents.db` OAuth + `app_settings` scrub (**chats/messages/projects preserved**), `auth.dat`/`auth-v2.dat`, HKLM MachineGuid, HKCU deviceid, HKLM SQM MachineId, MAC + hostname, old-backup purge, watchdog re-verify
- Supports `-SkipMac`, `-SkipHostname`, and `-DryRun` (prints actions without writing)

**Before running:** Close QoderWork. Run PowerShell as Administrator.

### 7. Reset MiniMax Agent / OpenCode (`reset_minimax_opencode.ps1`)

Combined reset for two Electron apps plus their CLI homes, with every path verified against a live install:

- **MiniMax Agent**: `%APPDATA%\MiniMax Agent` (Chromium profile) + `%USERPROFILE%\.minimax` (CLI home)
- **OpenCode**: `%APPDATA%\ai.opencode.desktop` (Chromium profile) + `%USERPROFILE%\.local\share\opencode` (CLI home)

Flags: `-KeepLogin` (preserves OpenCode `auth.json` for paid/topped-up Zen logins; default wipes to `{}` + prints the re-login command), `-SkipVersionCheck` (skips the client-version preflight — the server rejects outdated `User-Agent`s).

The 22 steps fall into six groups:

1. **Process kill** — aggressive tree-kill of MiniMax/OpenCode/mavis (wildcard-verified twice; hard-abort if unkillable). `node`/`python` and other IDE extensions are never matched.
2. **Auth wipes → `{}`** (forces re-login) — OpenCode `auth.json`; MiniMax `mcode-public\auth.json`, `auth-state.json`, `local-runtime.auth.json`. Audit entries record node names/counts only — token values are never logged.
3. **ID rotation** — `.updaterId` (both apps), OpenCode `gh\device-id`, MiniMax `remote-control\state.json` `desktop_device_id` (regenerated preserving the value's original format), updater-tmp sweep, `windowIds[]` rotation + per-window UUID file deletion, `Local State → uninstall_metrics` removal.
4. **Chromium state per profile** — Cookies/DIPS/SharedStorage (incl. `-wal`/`-journal`/`-shm` suffix sweep)/Trust Tokens/Network Persistent State/TransportSecurity; Local Storage + IndexedDB (MiniMax main profile); Session Storage/WebStorage/Shared Dictionary; cache trees deleted per-file; Crashpad; logs; `Local State` `os_crypt.encrypted_key`; `Preferences` `device_id_salt` (rotated only if present). The `mavis-browser` partition is cleared on **Local Storage only**.
5. **MiniMax misc** — `shared_proto_db`, `observability-outbox.jsonl`, `embedded-browser-tabs.json`, `hot-update\`, `logs\`, `daemon.lock`, `lockfile` + `opencode\locks`, `tmp\`, `run\`, `auth.lock`, and the `user`/`sharedUser` nodes of `minimax-agent-config.json` (the `config` node is kept).
6. **Finale** — watchdog re-probe (re-deletes anything a slow shutdown recreated), old `ID_Backups` purge, JSON audit log, self-contained restore script, done marker, exit 1 on any failure.

Safety features — never wiped:

- `%USERPROFILE%\.local\share\opencode\opencode.db` (+ `repos/`, `snapshot/`, `storage/`, `tool-output/`) is app-shared storage, preserved in place and never copied to backups. Storage isolation is the app-side fix; keep the app updated.
- MiniMax user content: `sessions\` (chat history), `sqlite.db` (+shm/wal), `memory\`, `plans\`, `workspace\`, `bin\`, `mcp\`, `credentials\mavis\telegram.json`, `state\`, `v2\`, and every other non-targeted `.minimax` item.
- OpenCode user content: `drafts.sqlite`, `window-state*.json`, `Local Storage`, `skills\`, `pnpm\`, `.config\opencode\`, `mcp-auth.json` (third-party).
- `%USERPROFILE%\.mavis` is a junction to `.minimax` — audited only, never touched (reparse-point guard on all deletions).
- Backup-first for every change; if a run changes nothing, the empty backup dir is removed and no restore script is written.

**Before running:** Close MiniMax Agent and OpenCode first, and run from a terminal *outside* OpenCode (the script also force-kills them). Run PowerShell as Administrator. No Python required — the script performs no SQLite writes.

### 8. Change Windows Device ID (`change_device_id.ps1`)

| Mode | Description |
|------|-------------|
| `Fingerprint` (default) | JSON fingerprint from system signals; does not modify IDs |
| `LegacyReset` | Changes Windows device IDs and computer name (Admin) |
| `RepairProfiles` | Repairs ProfileList `.bak` keys (Admin) |

```powershell
.\src\windows\change_device_id.ps1
.\src\windows\change_device_id.ps1 -Mode LegacyReset
.\src\windows\change_device_id.ps1 -Mode RepairProfiles
```

> Note: machine-wide — affects **all four** ZCode instances + Qoder at once.

## Linux

Scripts live in `src/linux/`. Requirements: bash 4+, python3 (recommended), `uuidgen` or readable `/proc/sys/kernel/random/uuid`, `openssl` or `xxd`, `sudo` only for `/etc/machine-id`.

```bash
cd /path/to/this/repo
chmod +x src/linux/*.sh
./ghost.sh
```

Or run scripts directly:

```bash
# Cursor (close Cursor first)
./src/linux/reset_cursor.sh
sudo ./src/linux/reset_cursor.sh   # also resets /etc/machine-id

# Windsurf (close Windsurf first)
./src/linux/reset_windsurf.sh
sudo ./src/linux/reset_windsurf.sh

# Fingerprint only (no root)
./src/linux/change_device_id.sh Fingerprint

# Reset Linux system machine-id (root)
sudo ./src/linux/change_device_id.sh ResetMachineId
```

### Linux paths

| App | Config location |
|-----|-----------------|
| Cursor | `~/.config/Cursor/` |
| Windsurf | `~/.config/Windsurf/`, `~/.windsurf/`, `~/.codeium/` |
| Trae | `~/.config/Trae/` |
| Fingerprint state | `~/.local/state/LicenseIdentity/fingerprint_state.json` |

`XDG_CONFIG_HOME` and `XDG_STATE_HOME` are respected when set.

### Linux scripts

- `reset_cursor.sh` — Resets Cursor IDs (`machineId`, `storage.json`, `state.vscdb`)
- `reset_windsurf.sh` — Resets Windsurf and Codeium IDs
- Trae Linux: no current wrapper yet — the legacy standalone lives in `archive/` (local-only, never committed)
- `change_device_id.sh` — `Fingerprint` or `ResetMachineId`
- `id_reset_common.sh` — Shared helpers sourced by the thin-wrapper scripts above
- `ghost.sh` — Interactive menu (repo root)

> **Note:** `change_device_id.ps1` modes `LegacyReset` and `RepairProfiles` are **Windows-only** (registry and profile list). On Linux use `ResetMachineId` for system ID changes.
