# Clean Slate Kit

Fresh-start toolkit for local AI-IDE identity stores: rotate device identifiers for **Cursor**, **Windsurf**, **Trae**, **Qoder**, **ZCode**, **QoderWork**, **MiniMax Agent**, and **OpenCode**, and inspect or reset system machine IDs. For privacy hygiene, multi-account testing, and CI/dev-environment resets. Available for **Windows** (PowerShell) and **Linux** (Bash).

## Repository layout

```
clean-slate-kit/
├── README.md  how-to-run.bat  how-to-run.txt  how-to-run.sh
├── scripts/
│   ├── windows/   # current .ps1 resetters + identity_utils.ps1 + change_device_id.ps1
│   └── linux/     # .sh scripts (id_reset_common.sh + per-IDE resetters)
├── docs/          # AGENTS.md, IMPLEMENTATION_GUIDE/PLAN, WALKTHROUGH, research notes
├── archive/       # superseded script versions (fallbacks — do not run)
├── tools/         # reviewed utilities (block_qoder_domains.ps1 — local-only; watch_zcode_captcha.ps1 — captcha-stall watchdog)
└── .trash/        # moved-aside junk (git-ignored, never committed)
```

## What These Tools Do

Applications often create unique IDs to identify your computer. These scripts generate new IDs, update the relevant config files (JSON, SQLite, binary stores), verify the writes, and create backups automatically.

## Platform Overview

| Task | Windows | Linux |
|------|---------|-------|
| Reset Cursor | `reset_cursor_windows-v0.2.ps1` | `reset_cursor_linux.sh` |
| Reset Windsurf | `reset_windsurf_windows-v0.2.ps1` | `reset_windsurf_linux.sh` |
| Reset Trae | `reset_trae_windows-v0.2.ps1` | `reset_trae_linux-v0.1.sh` |
| Reset Qoder | `reset_qoder_windows-v0.4.ps1` | — |
| Reset ZCode (+Qoder stores) | `reset_zcode_windows-v1.4.ps1` (`-Target Primary\|Secondary\|Both`) | — |
| ZCode second instance (dual-instance) | `launch_zcode_second_instance.ps1` + `Launch-ZCode-Second.bat` | — |
| Reset QoderWork | `reset_qoderwork_windows-v0.1.ps1` | — |
| Reset MiniMax Agent / OpenCode | `reset_minimax_opencode_windows-v1.1.ps1` | — |
| Device fingerprint | `change_device_id.ps1` | `change_device_id_linux.sh Fingerprint` |
| System machine ID | Windows Registry `MachineGuid` | `/etc/machine-id` |
| Interactive menu | `how-to-run.bat` | `how-to-run.sh` |

> The Windows IDE reset scripts share a common library, `identity_utils.ps1`, which they dot-source. It provides GUID generation, process termination, backup/restore, JSON + SQLite (Python-backed) updates with verify-after, audit logging, and restore-script generation. Per-run audit logs (`audit_<ts>.json`) and restore scripts (`restore_<App>_<ts>.ps1`) land under `<App>\ID_Backups\<ts>\`.

---

## Linux

### Requirements

- **bash** 4+
- **python3** (recommended — used for JSON and SQLite updates)
- **uuidgen** or readable `/proc/sys/kernel/random/uuid`
- **openssl** or **xxd** (for random hex IDs)
- **sudo** (optional) — only needed to reset `/etc/machine-id`

### Quick start

```bash
cd /path/to/this/repo
chmod +x scripts/linux/*.sh
./how-to-run.sh
```

Or run scripts directly:

```bash
# Cursor (close Cursor first)
./scripts/linux/reset_cursor_linux.sh
sudo ./scripts/linux/reset_cursor_linux.sh   # also resets /etc/machine-id

# Windsurf (close Windsurf first)
./scripts/linux/reset_windsurf_linux.sh
sudo ./scripts/linux/reset_windsurf_linux.sh

# Fingerprint only (no root)
./scripts/linux/change_device_id_linux.sh Fingerprint

# Reset Linux system machine-id (root)
sudo ./scripts/linux/change_device_id_linux.sh ResetMachineId
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

- `reset_cursor_linux.sh` — Resets Cursor IDs (`machineId`, `storage.json`, `state.vscdb`)
- `reset_windsurf_linux.sh` — Resets Windsurf and Codeium IDs
- `reset_trae_linux-v0.1.sh` — Resets Trae IDs (legacy standalone; no thin-wrapper version yet)
- `change_device_id_linux.sh` — `Fingerprint` or `ResetMachineId`
- `id_reset_common.sh` — Shared helpers sourced by the thin-wrapper scripts above
- `how-to-run.sh` — Interactive menu (repo root)
- `reset_cursor_linux-v0.1.sh`, `reset_windsurf_linux-v0.1.sh` — Legacy standalone fallbacks (self-contained, predate `id_reset_common.sh`)

> **Note:** `change_device_id.ps1` modes `LegacyReset` and `RepairProfiles` are **Windows-only** (registry and profile list). On Linux use `ResetMachineId` for system ID changes.

---

## Windows

### 1. Reset Cursor ID (`reset_cursor_windows-v0.2.ps1`)

- Creates fresh identification numbers via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys), `state.vscdb` (`storage.serviceMachineId`), deletes auth secrets (`cursorAuth/*`, `secret://cursorAuth/openAIKey`), rotates `device_id_salt` + `os_crypt.encrypted_key`, deletes Cookies / Network state / sentry / DIPS / Trust Tokens / Crashpad / logs / workspace DB entries (never the workspace files)
- Self-elevates to Administrator, aggressive process tree-kill, watchdog re-verify, old `ID_Backups` purge
- Every write is verified by re-reading; audit log + restore script are generated

**Before running:** Close Cursor. Run PowerShell as Administrator.

### 2. Reset Windsurf ID (`reset_windsurf_windows-v0.2.ps1`)

- Resets Windsurf and Codeium configuration via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys), `state.vscdb`, deletes auth secrets (`codeium.windsurf-windsurf_auth`, `windsurf_auth-*`), `argv.json` (`crash-reporter-id`, JSONC comments preserved), `.codeium\config.json` (`device_id`), `.windsurf\installation_id`, scrubs username from Preferences/Local State, deletes Cookies / Network state / DIPS / workspace DB entries
- Timestamped backups + audit log under `%APPDATA%\Windsurf\ID_Backups\<ts>`

**Before running:** Close Windsurf. Run PowerShell as Administrator.

### 3. Reset Trae ID (`reset_trae_windows-v0.2.ps1`)

- Resets Trae configuration via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys + removes `iCubeAuthInfo://*` + `has_device_id_updated_to_aha=false`), `state.vscdb`, `ModularData\ckg_server\local_env.json` (`device_id` + `host_map`), deletes `aha` (encrypted TinyStorage), scrubs only identity rows in `ModularData\ai-agent` (**chat preserved**), Cookies / Network state / DIPS / SharedStorage / `Partitions\trae-webview` / workspace DB entries
- Timestamped backups + audit log under `%APPDATA%\Trae\ID_Backups\<ts>`

**Before running:** Close Trae. Run PowerShell as Administrator.

### 4. Reset Qoder ID (`reset_qoder_windows-v0.4.ps1`)

- 31 steps: `storage.json` (4 telemetry keys, main + `CORS_Profile`), `machineid`, `argv.json` (`crash-reporter-id`), `state.vscdb` + expanded auth-secrets delete (`aicoding.auth.*` incl. `loginBroadcast`, `secret.local.machine.variables`, `secret://blackbox.*`), `device_id_salt`, `os_crypt` rotation, browser data, `Crashpad`/`SharedClientCache`/`logs`, `.qoder` cache subdirs (reparse-point-safe), workspace UPSERT-only, plus system steps (HKCU deviceid, HKLM SQM MachineId, MAC, hostname — opt-out via `-SkipMac`/`-SkipHostname`), plus v0.4 device-flow steps (`.qoder\installation_id` + `.auth\machine_id` rotation, credential/dns/endpoint cache delete, IndexedDB/Partitions/Storage webview purge, `.qoder\tmp\telemetry` + `logs` cleanup, read-only device-flow final probe)
- Timestamped backups + audit log under `%APPDATA%\Qoder\ID_Backups\<ts>`

**Before running:** Close Qoder. Run PowerShell as Administrator.

### 5. Reset ZCode ID (`reset_zcode_windows-v1.4.ps1`)

- 27 steps + `[6b/27]`: everything Qoder-side above (for the Qoder stores ZCode shares) plus `.updaterId`, `telemetry-state.json` (`deviceMid`), credentials OAuth clear, **config.json provider `apiKey` strip (fixes the Unlink → Checking loop)**, coding-plan-cache invalidation, RUM store, `setting.json` (`deviceSid`), session/embedded-browser Chromium data
- Chat stores (`tasks-index.sqlite`, checkpoints, IndexedDB webview data, Local Storage leveldb) are never touched
- Timestamped backups + audit log under `%APPDATA%\ZCode\ID_Backups\<ts>` (per-target: Secondary uses `%APPDATA%\ZCode-Second\ID_Backups\<ts>`)
- `-Target Primary` (default reset scope + Qoder steps), `-Target Secondary` (selective tree-kill, survivor keeps running, Qoder untouched), `-Target Both` (two independent child runs, Secondary first; each generates its OWN fresh ID set — IDs are never duplicated across instances)

**Before running:** close only the TARGET instance (the script kills it; the survivor keeps running in Single mode). Run PowerShell as Administrator. After the reset, ZCode prompts for a fresh login. `change_device_id.ps1` is machine-wide and affects BOTH instances + Qoder.

### 5b. ZCode second instance (dual-instance setup)

Run two fully independent ZCode windows side by side (separate Electron locks, separate SQLite stores, separate accounts):

```powershell
# Option A — menu: how-to-run.bat → [10]
# Option B — double-click: scripts\windows\Launch-ZCode-Second.bat
```

First launch clones history (`~\.zcode` → `~\ZCodeSecondHome\.zcode`, journals excluded), then scrubs the clone to fresh independent IDs (deviceMid, deviceSid, OAuth tokens, provider apiKeys) and routes Telegram bots to Primary only (marker-guarded, runs once — a deliberate re-enable in Secondary is never reverted). Later launches reuse the independent profile. Isolation is driven by five process-scoped env vars (`ZCODE_DATA_BASE_DIR`, `ZCODE_DESKTOP_USER_DATA_DIR`, `ZCODE_DESKTOP_SESSION_DATA_DIR`, `ZCODE_DESKTOP_HOME_DIR`, `HOME`) — the app overwrites `--user-data-dir`, so env vars are the only working lever. Both instances share one install: a single update covers both. Telegram channel bots must live on ONE instance only (two pollers on one token cause HTTP 409 conflicts and random cross-account billing); the launcher enforces Primary-only automatically.

### 6. Reset QoderWork ID (`reset_qoderwork_windows-v0.1.ps1`)

- 26 steps: `machine-id`, `installation_id`, `.status.json`, Chromium profile (`Preferences` salt, Cookies, Local/Session Storage, caches, SharedStorage, `Local State`), `agents.db` OAuth + `app_settings` scrub (**chats/messages/projects preserved**), `auth.dat`/`auth-v2.dat`, HKLM MachineGuid, HKCU deviceid, HKLM SQM MachineId, MAC + hostname, old-backup purge, watchdog re-verify
- Supports `-SkipMac`, `-SkipHostname`, and `-DryRun` (prints actions without writing)

**Before running:** Close QoderWork. Run PowerShell as Administrator.

### 7. Reset MiniMax Agent / OpenCode (`reset_minimax_opencode_windows-v1.1.ps1`)

v1.1 fixes post-reset `FreeTierError: OpenCode's free tier can only be used from within OpenCode` (server-side UA gate: only `User-Agent: opencode/<version>` on clients ≥1.17.0 passes). New: version preflight (aborts on outdated clients unless `-SkipVersionCheck`), `-KeepLogin` (preserves `auth.json` for paid/topped-up Zen logins; default still wipes to `{}` + prints re-login command), distinct GUIDs for `.updaterId` vs `gh\device-id` (v1.0 reused one value), names-only auth probe before wiping.

Combined reset for two Electron apps plus their CLI homes, with every path verified against this machine's actual layout:

- **MiniMax Agent**: `%APPDATA%\MiniMax Agent` (Chromium profile) + `%USERPROFILE%\.minimax` (CLI home)
- **OpenCode**: `%APPDATA%\ai.opencode.desktop` (Chromium profile) + `%USERPROFILE%\.local\share\opencode` (CLI home)

The 22 steps fall into six groups:

1. **Process kill** — aggressive tree-kill of MiniMax/OpenCode/mavis (wildcard-verified twice; hard-abort if unkillable). `node`/`python` and other IDE extensions are never matched.
2. **Auth wipes → `{}`** (forces re-login) — OpenCode `auth.json`; MiniMax `mcode-public\auth.json`, `auth-state.json`, `local-runtime.auth.json`. Audit entries record node names/counts only — token values are never logged.
3. **ID rotation** — `.updaterId` (both apps), OpenCode `gh\device-id`, MiniMax `remote-control\state.json` `desktop_device_id` (regenerated preserving the value's original format).
4. **Chromium state per profile** — Cookies/DIPS/SharedStorage/Trust Tokens/Network Persistent State/TransportSecurity; Local Storage + IndexedDB (MiniMax main profile); Session Storage/WebStorage/Shared Dictionary; cache trees deleted per-file; Crashpad; logs; `Local State` `os_crypt.encrypted_key`; `Preferences` `device_id_salt` (rotated only if present). The `mavis-browser` partition is cleared on **Local Storage only**.
5. **MiniMax misc** — `shared_proto_db`, `observability-outbox.jsonl`, `embedded-browser-tabs.json`, `hot-update\`, `logs\`, `daemon.lock`, `tmp\`, `run\`, `auth.lock`, and the `user`/`sharedUser` nodes of `minimax-agent-config.json` (the `config` node is kept).
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
.\scripts\windows\change_device_id.ps1
.\scripts\windows\change_device_id.ps1 -Mode LegacyReset
.\scripts\windows\change_device_id.ps1 -Mode RepairProfiles
```

### Windows usage

1. Open **PowerShell as Administrator**
2. `cd` to this folder
3. Run the script you need, or use `how-to-run.bat`

```powershell
.\scripts\windows\reset_cursor_windows-v0.2.ps1
.\scripts\windows\reset_windsurf_windows-v0.2.ps1
.\scripts\windows\reset_zcode_windows-v1.4.ps1 -Target Primary
.\scripts\windows\change_device_id.ps1
```

---

## Important Notes

- **Backups** are created automatically (`.backup` files or timestamped folders)
- **Close the editor** before running reset scripts
- **System ID changes** may require a reboot (Linux) or restart (Windows)
- **Use at your own risk** — these scripts modify application and system identifiers

## Files Included

**Windows** (`scripts/windows/` — current versions only; superseded ones, incl. Qoder v0.3 and ZCode v1.1, live in `archive/` as fallbacks — do not run them)

- `reset_cursor_windows-v0.2.ps1`
- `reset_windsurf_windows-v0.2.ps1`
- `reset_trae_windows-v0.2.ps1`
- `reset_qoder_windows-v0.4.ps1`
- `reset_zcode_windows-v1.4.ps1` (`-Target Primary|Secondary|Both`; v1.3 stays beside it as rollback fallback — prefer v1.4)
- `launch_zcode_second_instance.ps1` + `Launch-ZCode-Second.bat` (dual-instance launcher)
- `reset_qoderwork_windows-v0.1.ps1`
- `reset_minimax_opencode_windows-v1.1.ps1`
- `identity_utils.ps1` (shared library — dot-sourced by the IDE reset scripts)
- `change_device_id.ps1`
- `how-to-run.bat` (repo root)

**Linux** (`scripts/linux/`)

- `reset_cursor_linux-v0.1.sh`
- `reset_windsurf_linux-v0.1.sh`
- `change_device_id_linux.sh`
- `how-to-run.sh` (repo root)

**Tools** (`tools/` — reviewed utilities, run as the logged-in user, no admin needed)

- `block_qoder_domains.ps1` — hosts-file blocker for the Qoder/QoderWork fingerprint-SDK and telemetry chain (`-Mode Block/Unblock/Status`, `-AllowAuth` keeps sign-in open)
- `watch_zcode_captcha.ps1` — unattended watchdog for the ZCode Aliyun-CAPTCHA stall (`Captcha instance timed out after 10000ms`, upstream `zai-org/feedback#349`). Tails the agent JSONL logs; on fresh failures it restarts ZCode (clears the stuck instance) and, past the escalation threshold, raises a sound alert + optional Telegram message. Recovery extras: if the relaunch fails it retries while the kill is inside `-RelaunchWindowMinutes` (an app closed by you outside that window is left alone; `-NoAutoRelaunch` disables all of it), and after a restart it resumes the failed sessions headlessly in place (`zcode --resume <sess> --prompt <msg>`, capped per session per hour; `-NoAutoContinue` disables). A second failure class, capacity overload (terminal `turn.failed` with `rate_limited`/529/1305/3009/`model_rate_limited` cause chain), never restarts the app — it defers the resume by `-RateLimitResumeDelayMinutes` (default 10) instead. Never touches identity/auth/config files. Telegram creds come from `-TelegramBotToken`/`-TelegramChatId` or, when omitted, from `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` in `.envlocal` (repo root, git-ignored). Test first with `-RunOnce -DryRun`, then leave running in a window (or pick `[9]` in `how-to-run.bat`). Logging: console shows milestones only (`-Verbose` for full detail, DryRun implies verbose); `watch.log` keeps everything (rotated at 5MB); relaunched-app output goes to per-run `relaunch_*.log` files instead of the console; per-run logs older than 7 days (`-LogRetentionDays`) are deleted automatically.
