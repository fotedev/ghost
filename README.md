# Machine ID Reset Tools

Scripts to reset device identifiers for **Cursor**, **Windsurf**, **Trae**, **MiniMax Agent**, and **OpenCode**, and to inspect or reset system machine IDs. Available for **Windows** (PowerShell) and **Linux** (Bash).

## What These Tools Do

Applications often create unique IDs to identify your computer. These scripts generate new IDs, update the relevant config files (JSON, SQLite, binary stores), verify the writes, and create backups automatically.

## Platform Overview

| Task | Windows | Linux |
|------|---------|-------|
| Reset Cursor | `reset_cursor_windows-v0.1.ps1` | `reset_cursor_linux-v0.1.sh` |
| Reset Windsurf | `reset_windsurf_windows-v0.1.ps1` | `reset_windsurf_linux-v0.1.sh` |
| Reset Trae | `reset_trae_windows-v0.1.ps1` | `reset_trae_linux-v0.1.sh` |
| Reset MiniMax Agent / OpenCode | `reset_minimax_opencode_windows-v1.0.ps1` | — |
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
chmod +x *.sh
./how-to-run.sh
```

Or run scripts directly:

```bash
# Cursor (close Cursor first)
./reset_cursor_linux-v0.1.sh
sudo ./reset_cursor_linux-v0.1.sh   # also resets /etc/machine-id

# Windsurf (close Windsurf first)
./reset_windsurf_linux-v0.1.sh
sudo ./reset_windsurf_linux-v0.1.sh

# Fingerprint only (no root)
./change_device_id_linux.sh Fingerprint

# Reset Linux system machine-id (root)
sudo ./change_device_id_linux.sh ResetMachineId
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

- `reset_cursor_linux-v0.1.sh` — Resets Cursor IDs (`machineId`, `storage.json`, `state.vscdb`)
- `reset_windsurf_linux-v0.1.sh` — Resets Windsurf and Codeium IDs
- `change_device_id_linux.sh` — `Fingerprint` or `ResetMachineId`
- `how-to-run.sh` — Interactive menu

> **Note:** `change_device_id.ps1` modes `LegacyReset` and `RepairProfiles` are **Windows-only** (registry and profile list). On Linux use `ResetMachineId` for system ID changes.

---

## Windows

### 1. Reset Cursor ID (`reset_cursor_windows-v0.1.ps1`)

- Creates fresh identification numbers via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys), `state.vscdb`, and renames Cookies / Network state / sentry / DIPS / workspace DBs
- Every write is verified by re-reading; audit log + restore script are generated

**Before running:** Close Cursor. Run PowerShell as Administrator.

### 2. Reset Windsurf ID (`reset_windsurf_windows-v0.1.ps1`)

- Resets Windsurf and Codeium configuration via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys), `state.vscdb`, `argv.json` (`crash-reporter-id`), `.codeium\config.json` (`device_id`), `.windsurf\installation_id`, scrubs `$USERNAME` from Preferences/Local State, renames Cookies / Network state / DIPS / workspace DBs
- Timestamped backups + audit log under `%APPDATA%\Windsurf\ID_Backups\<ts>`

**Before running:** Close Windsurf. Run PowerShell as Administrator.

### 3. Reset Trae ID (`reset_trae_windows-v0.1.ps1`)

- Resets Trae configuration via `identity_utils.ps1`
- Updates `machineid`, `storage.json` (4 telemetry keys + removes `iCubeAuthInfo://*` + `has_device_id_updated_to_aha=false`), `state.vscdb`, `ModularData\ckg_server\local_env.json` (`device_id` + `host_map`), and renames `aha` (encrypted TinyStorage), `ModularData\ai-agent` (chat DB), Cookies / Network state / DIPS / SharedStorage / `Partitions\trae-webview` / workspace DBs
- Timestamped backups + audit log under `%APPDATA%\Trae\ID_Backups\<ts>`

**Before running:** Close Trae. Run PowerShell as Administrator.

### 4. Reset MiniMax Agent / OpenCode (`reset_minimax_opencode_windows-v1.0.ps1`)

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

### 5. Change Windows Device ID (`change_device_id.ps1`)

| Mode | Description |
|------|-------------|
| `Fingerprint` (default) | JSON fingerprint from system signals; does not modify IDs |
| `LegacyReset` | Changes Windows device IDs and computer name (Admin) |
| `RepairProfiles` | Repairs ProfileList `.bak` keys (Admin) |

```powershell
.\change_device_id.ps1
.\change_device_id.ps1 -Mode LegacyReset
.\change_device_id.ps1 -Mode RepairProfiles
```

### Windows usage

1. Open **PowerShell as Administrator**
2. `cd` to this folder
3. Run the script you need, or use `how-to-run.bat`

```powershell
.\reset_cursor_windows-v0.1.ps1
.\reset_windsurf_windows-v0.1.ps1
.\change_device_id.ps1
```

---

## Important Notes

- **Backups** are created automatically (`.backup` files or timestamped folders)
- **Close the editor** before running reset scripts
- **System ID changes** may require a reboot (Linux) or restart (Windows)
- **Use at your own risk** — these scripts modify application and system identifiers

## Files Included

**Windows**

- `reset_cursor_windows-v0.1.ps1`
- `reset_windsurf_windows-v0.1.ps1`
- `reset_trae_windows-v0.1.ps1`
- `reset_minimax_opencode_windows-v1.0.ps1`
- `identity_utils.ps1` (shared library — dot-sourced by the IDE reset scripts)
- `change_device_id.ps1`
- `how-to-run.bat`

**Linux**

- `reset_cursor_linux-v0.1.sh`
- `reset_windsurf_linux-v0.1.sh`
- `change_device_id_linux.sh`
- `how-to-run.sh`
