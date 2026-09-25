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
| Reset ZCode (+Qoder stores) | `reset_zcode.ps1` (`-Target Primary\|Secondary\|Third\|Fourth\|Both\|All`) | — |
| ZCode clones (Primary + 3 branded instances) | `launch_zcode_second_instance.ps1 -Instance Second\|Third\|Fourth` + `Launch-ZCode-*.bat` | — |
| Reset QoderWork | `reset_qoderwork.ps1` | — |
| Reset MiniMax Agent / OpenCode | `reset_minimax_opencode.ps1` | — |
| Device fingerprint | `change_device_id.ps1` | `change_device_id.sh Fingerprint` |
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
│                   #   zcode-{blue,yellow,green}-branding/ (icon assets)
├── tests/          # Pester 5 suite (PowerShell) + stdlib unittest suite (Python core)
├── docs/           # getting-started / architecture / cli / troubleshooting / faq
├── .github/        # CI workflow, issue forms, PR template, CODEOWNERS
└── archive/        # superseded versions — local-only, never committed
```

`identity_utils.ps1` (Windows) and `id_reset_common.sh` (Linux) are the shared
libraries; the per-app scripts are thin target manifests on top. Details:
[docs/architecture.md](docs/architecture.md).

## Configuration

- `reset_zcode.ps1 -Target Primary|Secondary|Third|Fourth|Both|All` — per-instance
  resets with independent ID sets (survivors untouched in Single mode)
- `reset_qoder.ps1` / `reset_qoderwork.ps1` — `-SkipMac`, `-SkipHostname`,
  `-DryRun`
- `reset_minimax_opencode.ps1` — `-KeepLogin`, `-SkipVersionCheck`
- `tools/patch_zcode_icon_override.ps1` — one-time `app.asar` patch enabling
  `ZCODE_ICON_DIR` / `ZCODE_AUMID_SUFFIX` / `ZCODE_ACCENT_HEX` /
  `ZCODE_INSTANCE_NAME` (per-clone icon, taskbar identity, accent color,
  window title); re-run after every ZCode app update (`-Restore` undoes it)
- `tools/install_zcode_second_shortcuts.ps1` — Desktop + Start-menu shortcuts
  for all three clones with per-clone AppUserModel IDs (`-Remove` uninstalls,
  `-RepairPrimaryAumid` fixes a collided Primary pin)
- `tools/refresh_zcode_second_chats.ps1 -Target Primary|Second|Third|Fourth|All`
  — shows another instance's chats in a running sidebar without an app
  restart; `-Watch` runs as a daemon that auto-refreshes on quota/captcha
  failures
- `tools/watch_zcode_taskbar.ps1` — resident watcher that re-stamps every
  ZCode window's taskbar identity every 5 s (heals merges and fresh windows);
  `-InstallAutostart` adds a startup-folder shortcut, `-RunOnce` for testing
- `tools/install_ghost_shortcut.ps1` — regenerates the `GHOST.lnk` shortcuts
  (Desktop + repo root) that carry the launcher icon; `-Remove` uninstalls
- `tools/update_ghost.ps1` — repo self-updater: fetch + compare + guarded
  `git pull --ff-only` (`-CheckOnly` reports without writing)
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
