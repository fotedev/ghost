# GHOST — Guided Hardware & OS Scrubbing Toolkit

[![CI](https://github.com/fotedev/ghost/actions/workflows/ci.yml/badge.svg)](https://github.com/fotedev/ghost/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-lightgrey.svg)](#prerequisites)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE.svg)](#prerequisites)

Fresh-start toolkit for local AI-IDE identity stores: rotate device identifiers
for **Cursor**, **Windsurf / Devin Desktop**, **Trae**, **Qoder**, **ZCode**,
**QoderWork**, **MiniMax Agent**, and **OpenCode**, and inspect or reset system
machine IDs. Built for privacy hygiene, multi-account testing, and
CI/dev-environment resets.

## Disclaimer

These scripts modify application and system identifiers on machines **you own
or are authorized to administer**. They may violate vendor Terms of Service.
Use at your own risk — no outcome is guaranteed. See [SECURITY.md](SECURITY.md).

## How it works

Applications create unique IDs to identify your computer. Each reset script
generates fresh IDs, updates the relevant config files (JSON, SQLite, binary
stores), **verifies every write by re-reading it**, backs up everything it
touches, and emits an audit log plus a self-contained restore script.

| Task | Windows | Linux |
|------|---------|-------|
| Reset Cursor | `reset_cursor.ps1` | `reset_cursor.sh` |
| Reset Windsurf / Devin Desktop | `reset_devin.ps1` | `reset_windsurf.sh` |
| Reset Trae | `reset_trae.ps1` | — (legacy only, local) |
| Reset Qoder | `reset_qoder.ps1` | — |
| Reset ZCode (+Qoder stores) | `reset_zcode.ps1` (`-Target Primary\|Secondary\|Third\|Fourth\|Fifth\|Sixth\|Both\|All`) | — |
| ZCode clones (Primary + 5 branded instances) | `launch_zcode_second_instance.ps1 -Instance Second\|Third\|Fourth\|Fifth\|Sixth` + `Launch-ZCode-*.bat` | — |
| ZCode light headless worker (no desktop window) | `launch_zcode_cli_light.ps1 -Instance Second\|...\|Sixth` (`-Prompt` / `-Server`) | — |
| Reset QoderWork | `reset_qoderwork.ps1` | — |
| Reset MiniMax Agent / OpenCode | `reset_minimax_opencode.ps1` | — |
| Device fingerprint | `change_device_id.ps1` | `change_device_id.sh Fingerprint` |
| WMI serial spoof (BIOS/motherboard/disks/RAM via WMI) | `spoof_wmi_serials.ps1` | — |
| System machine ID | Windows Registry `MachineGuid` | `/etc/machine-id` |
| Interactive menu | `GHOST.bat` | `ghost.sh` |

Detailed per-tool walkthroughs (paths touched, preservation lists, flags):
**[docs/getting-started.md](docs/getting-started.md)**.

## Prerequisites

**Windows**: Windows 10/11 · PowerShell 5.1 or 7 (run as Administrator) ·
Python 3 on `PATH` (SQLite writes run through the bundled stdlib-only core in
`src/python/ghost`) · close the target app first.

**Linux**: bash 4+ · python3 (recommended) · `uuidgen` or
`/proc/sys/kernel/random/uuid` · `openssl` or `xxd` · `sudo` only for
`/etc/machine-id`.

```bash
git clone https://github.com/fotedev/ghost.git
cd ghost
```

> **Note on "Download ZIP" copies:** a ZIP extracted from GitHub has no
> `.git`, so the git-based update flow cannot run there. Running the updater
> (`[U]` on the main menu, or Maintenance [2]) once from such a folder either
> converts it in place into a real git clone (after your confirmation, when
> Git is installed) or — when Git is not installed — updates it by
> downloading the latest GitHub archive directly (files are only added or
> replaced, never deleted; every replaced file is backed up first).

## Quick start

Prefer the interactive menus:

```powershell
# Windows (PowerShell as Administrator, from the repo root)
.\GHOST.bat
```

```bash
# Linux
./ghost.sh
```

Or run a script directly — full examples in
[docs/getting-started.md](docs/getting-started.md):

```powershell
.\src\windows\reset_devin.ps1                        # Windsurf + Devin Desktop roots, one pass
.\src\windows\reset_zcode.ps1 -Target Secondary      # survivor instances keep running
.\src\windows\launch_zcode_second_instance.ps1 -Instance Third   # yellow-branded clone
.\src\windows\launch_zcode_cli_light.ps1 -Instance Second        # headless account worker - low RAM
```

```bash
./src/linux/reset_cursor.sh                          # close Cursor first
sudo ./src/linux/change_device_id.sh ResetMachineId  # /etc/machine-id (root)
```

## Repository layout

```
ghost/
├── GHOST.bat       # Windows interactive launcher (double-click)
├── ghost.sh        # Linux interactive launcher
├── src/
│   ├── windows/    # .ps1 resetters (unversioned names) + identity_utils.ps1 + change_device_id.ps1
│   │               #   + ZCode/AutoClaw/AutoClaw2/Cline/OpenCode clone launchers
│   │               #   (launch_zcode_second_instance.ps1, launch_autoclaw_clone.ps1,
│   │               #   launch_autoclaw2_clone.ps1 + launch_autoclaw2_clones_all.ps1,
│   │               #   launch_cline_clone.ps1 + launch_cline_clones_all.ps1,
│   │               #   launch_opencode_clone.ps1 + launch_opencode_clones_all.ps1)
│   ├── linux/      # .sh resetters + id_reset_common.sh
│   └── python/     # stdlib-only Python core (ghost/) + ghost_cli.py bootstrap —
│                   #   owns the shared SQLite/JSON identity logic
├── tools/          # watch_zcode_captcha.ps1 (captcha watchdog),
│                   #   watch_zcode_taskbar.ps1 (taskbar identity watcher),
│                   #   patch_zcode_icon_override.ps1 + .mjs (app.asar icon /
│                   #   accent / AUMID patch — re-run after app updates),
│                   #   install_zcode_second_shortcuts.ps1 (clone shortcuts),
│                   #   install_ghost_shortcut.ps1 (GHOST.lnk), update_ghost.ps1
│                   #   (repo self-updater), refresh_zcode_second_chats.ps1
│                   #   (cross-instance chat refresh + -Watch error watcher),
│                   #   diagnose_zcode_freeze.ps1 (read-only freeze diagnostic),
│                   #   diagnose_zcode_throttle.ps1 (read-only Start-Plan throttle
│                   #   diagnostic — CLI-only, no GHOST.bat entry),
│                   #   patch_autoclaw_ports.ps1 + .mjs (AutoClaw app.asar MCP
│                   #   port-array patch 4 -> 8 slots — re-run after app updates),
│                   #   install_autoclaw_clone_shortcuts.ps1 (AutoClaw clone
│                   #   shortcuts), make_ghost_icon.ps1 (regenerates the launcher icon),
│                   #   make_clone_icon.ps1 (generic per-app clone-icon generator),
│                   #   new_clone_suite.ps1 (clone-suite scaffolding generator),
│                   #   set_zcode_bot.ps1 (per-clone Telegram bot audit/sync),
│                   #   sync_zcode_assets.ps1 (Primary→clone MCP/skills/plugins
│                   #   sync; -McpOnly is safe against RUNNING instances),
│                   #   zcode_mcp_merge.ps1 (unit-tested MCP merge core),
│                   #   watch_zcode_mcp_sync.ps1 (resident MCP sync watcher),
│                   #   zcode-{blue,yellow,green,red,orange}-branding/ +
│                   #   autoclaw-{blue,yellow,green,red}-branding/ (icon assets);
│                   #   cline-{blue,yellow,green,red,orange}-branding/ (clone icons,
│                   #   wired via install_cline_clone_shortcuts.ps1);
│                   #   patch_opencode_clone_home.ps1 + .mjs (OpenCode desktop
│                   #   clone-home + taskbar-identity asar patch — re-run after
│                   #   app updates), install_opencode_clone_shortcuts.ps1
│                   #   (OpenCode clone shortcuts);
│                   #   opencode-{blue,yellow,green,red,orange}-branding/
│                   #   (clone icons, wired via install_opencode_clone_shortcuts.ps1;
│                   #   orange generated 2026-10-24 as a placeholder);
│                   #   install_autoclaw2_clone_shortcuts.ps1 (AutoClaw2 clone
│                   #   shortcuts) + autoclaw2-{blue,yellow,green,red,orange}-branding/
│                   #   (clone icons)
├── tests/          # Pester 5 suite (PowerShell) + stdlib unittest suite (Python core)
├── docs/           # getting-started / architecture / cli / troubleshooting / faq
├── .github/        # CI workflow, issue forms, PR template, CODEOWNERS
└── archive/        # superseded versions — local-only, never committed
```

`identity_utils.ps1` (Windows) and `id_reset_common.sh` (Linux) are the shared
libraries; the per-app scripts are thin target manifests on top. Details:
[docs/architecture.md](docs/architecture.md).

## Configuration

- `reset_zcode.ps1 -Target Primary|Secondary|Third|Fourth|Fifth|Sixth|Both|All` — per-instance
  resets with independent ID sets (survivors untouched in Single mode)
- `reset_qoder.ps1` / `reset_qoderwork.ps1` — `-SkipMac`, `-SkipHostname`,
  `-DryRun`
- `reset_minimax_opencode.ps1` — `-KeepLogin`, `-SkipVersionCheck`
- `tools/patch_zcode_icon_override.ps1` — one-time `app.asar` patch (engine
  v8) enabling `ZCODE_ICON_DIR` / `ZCODE_AUMID_SUFFIX` / `ZCODE_ACCENT_HEX` /
  `ZCODE_INSTANCE_NAME` (per-clone icon, taskbar identity, accent color,
  window title) and injecting bidi auto-direction into the chat (Arabic RTL /
  English LTR per paragraph, code blocks stay LTR; `ZCODE_BIDI_OFF=1` opts
  out); re-run after every ZCode app update (`-Restore` undoes it)
- `tools/install_zcode_second_shortcuts.ps1` — Desktop + Start-menu shortcuts
  for all five clones with per-clone AppUserModel IDs (`-Remove` uninstalls,
  `-RepairPrimaryAumid` fixes a collided Primary pin + restores its icon)
- `tools/sync_zcode_assets.ps1 -Target Second|Third|Fourth|Fifth|Sixth|All` —
  Primary→clone asset sync: merges MCP server definitions from the Primary
  (per-clone toggles stay local), replaces stale `.zcode\skills` copies with a
  junction on the shared `~\.agents` store, mirrors the plugin cache; runs
  automatically before every clone launch. `-McpOnly` syncs the MCP
  definitions only and is safe against RUNNING instances — ZCode [18] for a
  one-shot run (ZCode [17] for the full sync)
- `tools/watch_zcode_mcp_sync.ps1` — resident MCP sync watcher: stat-guards
  the Primary's `~\.zcode\cli\config.json` and re-invokes
  `sync_zcode_assets.ps1 -McpOnly -Target All` on every change, so all five
  clones converge within seconds (`-RunOnce`, `-ApplyLive` recycles running
  clones' app-servers idle-guarded so the open session picks the change up
  immediately, `-InstallAutostart`). ZCode [19] (resident) / [20] (one-shot +
  apply live). The merge invariant lives in `tools/zcode_mcp_merge.ps1`
  (unit-tested by `tests/zcode_mcp_merge.Tests.ps1`)
- `tools/diagnose_zcode_throttle.ps1` — read-only diagnostic for
  "Reconnecting... x/10" / "The system is busy..." turn failures: parses the
  shared agent JSONL logs for Start-Plan admission retries with their cause
  chain + hourly histogram. Verified root cause (2026-10-27): server-side
  admission control, NOT a device/IP ban. CLI-only — no GHOST.bat entry
- `src/windows/spoof_wmi_serials.ps1` — opt-in system-level WMI serial spoof
  (Maintenance [3], behind a confirm gate): redeclares Win32_BIOS / BaseBoard /
  ComputerSystemProduct / SystemEnclosure / DiskDrive / PhysicalMemory serials
  via a generated `.mof`, plus SQMClient UserId + Bluetooth LocalAddress;
  backs the WMI repository up first and generates a `winmgmt /restore` script.
  WMI layer only — design + honest limits:
  [docs/WMI_SERIAL_SPOOFING.md](docs/WMI_SERIAL_SPOOFING.md)
- `tools/refresh_zcode_second_chats.ps1 -Target Primary|Second|Third|Fourth|Fifth|Sixth|All`
  — shows another instance's chats in a running sidebar without an app
  restart; `-Watch` runs as a daemon that auto-refreshes on quota/captcha
  failures
- `tools/diagnose_zcode_freeze.ps1` — read-only freeze diagnostic: scans each
  ZCode instance's logs + crash dumps for renderer-OOM / freeze events and
  prints live RAM/commit pressure (`-Days N` widens the window)
- `tools/watch_zcode_taskbar.ps1` — resident watcher that re-stamps every
  ZCode window's taskbar identity every 5 s (heals merges and fresh windows);
  `-InstallAutostart` adds a startup-folder shortcut, `-RunOnce` for testing
- `tools/install_ghost_shortcut.ps1` — regenerates the `GHOST.lnk` shortcuts
  (Desktop + repo root) that carry the launcher icon; `-Remove` uninstalls
- `tools/update_ghost.ps1` — repo self-updater: fetch + compare + guarded
  `git pull --ff-only` (`-CheckOnly` reports without writing)
- **AutoClaw multi-instance** — `src/windows/launch_autoclaw_clone.ps1
  -Instance inst1|inst2|inst3|inst4` launches independent clones (own profile,
  identity, gateway port; first run seeds the Primary profile minus every
  credential store — one manual login per clone), `-Status` reports processes,
  actual bound ports and health. `src/windows/reset_autoclaw.ps1 -Target
  Primary|inst1..4|All` rotates both device identities and deletes the live
  operator credential. `tools/patch_autoclaw_ports.ps1` widens the installed
  `app.asar`'s hardcoded 4-slot MCP port array to 8 (`-Restore` undoes it;
  re-run after every AutoClaw app update). `tools/install_autoclaw_clone_shortcuts.ps1`
  installs Desktop + Start-menu shortcuts (`-Remove`, `-RepairPrimaryAumid`).
  Design + verified ground truth: [docs/AUTOCLAW_CLONES_SPEC.md](docs/AUTOCLAW_CLONES_SPEC.md)
- **Cline multi-instance** — `src/windows/launch_cline_clone.ps1 -Instance
  c1..c5` launches fully isolated Cline desktop clones beside the Primary:
  each gets its own state tree (`CLINE_DIR`), web login profile
  (`WEBVIEW2_USER_DATA_FOLDER`), and hub/sidecar ports
  (`CLINE_HUB_PORT`/`CLINE_SIDECAR_PORT`); the Tauri single-instance guard
  (fixed-key mutex + hidden window) is neutralized by renaming its hidden
  window, and the launcher aborts a second copy on the same data. `-Status`
  reports locks, ports and sign-in state; `launch_cline_clones_all.ps1`
  launches all five sequentially. `tools/install_cline_clone_shortcuts.ps1`
  installs per-color Desktop + Start-menu shortcuts with suffixed AUMIDs
  (`-Remove`). Fresh profile per clone — one manual sign-in each.
  Design + verified ground truth: [docs/CLINE_CLONES_SPEC.md](docs/CLINE_CLONES_SPEC.md)
- **OpenCode desktop multi-instance** — `src/windows/launch_opencode_clone.ps1
  -Instance c1..c5` launches fully isolated OpenCode desktop clones beside
  the Primary: each gets its own Electron userData + sessionData
  (`<cloneHome>\desktop`, `<cloneHome>\session`) and its own CLI state via
  the app's own `XDG_*` redirection (`data\`, `config\`, `cache\`, `state\`).
  Isolation needs the one-time clone-home asar patch
  (`tools/patch_opencode_clone_home.ps1` — packaged builds hardcode
  `ai.opencode.desktop`; `-Restore` undoes it; re-run after app updates).
  Per-clone taskbar identity (AUMID `ai.opencode.desktop.cN` + window icon
  + "OpenCode <Color>" title) rides the same patch; shortcuts install via
  `tools/install_opencode_clone_shortcuts.ps1` (`-Remove`,
  `-RepairPrimaryAumid`). Fresh state per clone — one manual sign-in each.
  Design + verified ground truth: [docs/OPENCODE_CLONES_SPEC.md](docs/OPENCODE_CLONES_SPEC.md)
- **AutoClaw2 multi-instance** — `src/windows/launch_autoclaw2_clone.ps1
  -Instance c1..c5` launches isolated AutoClaw2 (v2.1.1, zwork) clones beside
  the Primary with 100% env-based isolation and NO asar patching:
  `ZWORK_USER_DATA` pins the whole Electron userData per clone before the
  per-profile single-instance lock, and `AUTOCLAW_PROFILE_ROOT` relocates the
  legacy migration source so no clone reads live Primary state; the app
  generates a fresh device id per profile. `-Status` introspects a clone;
  `launch_autoclaw2_clones_all.ps1` launches all five sequentially;
  `tools/install_autoclaw2_clone_shortcuts.ps1` installs per-color shortcuts
  (`-Remove`). CLI-only — the one suite not wired into `GHOST.bat`.
  Design + verified ground truth: [docs/AUTOCLAW2_CLONES_SPEC.md](docs/AUTOCLAW2_CLONES_SPEC.md)
- Telegram alerts for `tools/watch_zcode_captcha.ps1` come from
  `-TelegramBotToken`/`-TelegramChatId` params or `TELEGRAM_BOT_TOKEN` /
  `TELEGRAM_CHAT_ID` in `.envlocal` (copy [.env.example](.env.example) to
  `.envlocal`; it is git-ignored)

## Testing

```powershell
Invoke-ScriptAnalyzer -Path src,tools,tests -Recurse -Settings ./tests/PSScriptAnalyzerSettings.psd1 -Severity Error
Invoke-Pester -CI -Output Detailed
```

```bash
shellcheck src/linux/*.sh ghost.sh
for f in src/linux/*.sh ghost.sh; do bash -n "$f"; done

# Python core — stdlib unittest, no pip installs, runs on any OS
python -m unittest discover -s tests/python -v
```

CI runs three jobs on every push/PR: PowerShell lint + Pester
(`windows-latest`), ShellCheck (`ubuntu-latest`), and the Python core suite
(see [.github/workflows/ci.yml](.github/workflows/ci.yml)).

## Important notes

- Backups are automatic; a reset is reversible via the generated
  `restore_<App>_<ts>.ps1` — see [docs/troubleshooting.md](docs/troubleshooting.md)
- Close the target editor before running (the scripts force-kill it anyway)
- System ID changes may require a reboot (Linux) or restart (Windows)

## Contributing

PRs welcome — read [CONTRIBUTING.md](CONTRIBUTING.md) first (conventions,
PS 5.1 rules, local-only files, the no-silent-success invariant). Bug reports:
use the issue templates and **redact all machine identifiers and audit logs**.

## Security

Scope, intended use, and mandatory redaction rules:
[SECURITY.md](SECURITY.md). Please report vulnerabilities privately via
GitHub's "Report a vulnerability".

## Changelog & License

Notable changes: [CHANGELOG.md](CHANGELOG.md) ·
Licensed under [Apache License 2.0](LICENSE) — see [NOTICE](NOTICE).
Product names (Cursor, Windsurf, Devin Desktop, Trae, Qoder, ZCode, MiniMax,
OpenCode) belong to their respective owners; GHOST is not affiliated with any
of them.
