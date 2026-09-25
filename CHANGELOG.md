# Changelog

All notable changes to GHOST are documented here. Versions are Git tags
(`vX.Y.Z`); script filenames are unversioned.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **Python detection no longer false-positives on the Microsoft Store
  stubs**: `Get-PythonCommandInfo` (and the chat-refresh tool's detector)
  now functionally probe candidates (`python` / `python3` / `py` + per-user
  install paths) with `--version` and require an exit-0 "Python 3" report —
  the WindowsApps app-execution aliases (exit 9009, no interpreter), stale
  Python 2, and profile aliases are rejected. The `py` launcher and
  per-user installs are found even when an elevated `PATH` hides them;
  not-found messages now point at `winget install Python.Python.3.12`.

### Changed

- **Launcher menus renumbered to continuous local ids**: each `GHOST.bat`
  screen numbers its own tasks — Resets `[1]`–`[8]`, ZCode `[1]`–`[16]`
  (5 launch + 5 reset + 6 sync/watchers), Maintenance `[1]`–`[2]` — with
  per-screen resolvers (`:ZCodeOne` / `:MaintOne`) translating local ids to
  the unchanged global dispatch payloads. Chains typed inside a submenu use
  its local ids; `2 1 3 4` from the main menu opens ZCode and runs local
  `1 3 4` back-to-back (`PENDING_CHAIN` replaces the old `BACK` flow); bare
  global ids (`13`) still work from the main menu only — inside ZCode the
  local ids shadow the old global ones (old `[13]` icon patch is now
  ZCode `[12]`). Docs remapped in `AGENTS.md`, `docs/cli.md`,
  `docs/getting-started.md`, `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md`, and
  `docs/PLAN-2026-09-24-rebrand.md`.
- **UTF-8 piping for the Python core**: `ghost` forces its stdout to UTF-8
  and the PowerShell callers set `[Console]::OutputEncoding = UTF8`, so
  non-ASCII output (e.g. Arabic chat titles in `chat-check MISSING` lines)
  survives the pipe on any console code page.
- **`#Requires -Version 5.1` on every `.ps1`** in `src/windows` + `tools`
  (enforced by a new repo-integrity test) — standard error on archaeic
  hosts instead of mid-script syntax failures; PS 7 satisfies `>= 5.1`.
- **Python core extracted (de-duplicated bridges)**: the four embedded
  Python here-strings that lived inside PowerShell scripts now live in one
  stdlib-only package `src/python/ghost` invoked via
  `src\python\ghost_cli.py` — `Set-SqliteKeys` (identity_utils.ps1), the
  secrets-delete and CLI-telemetry bridges (reset_zcode.ps1), and the
  chat-sync helper (refresh_zcode_second_chats.ps1) no longer write temp
  `.py` files to `$env:TEMP`. Base64-in / JSON-stdout contracts, audit
  wording, and verify-after behavior are unchanged; per-call temp files are
  gone.
- **Launcher rebranded**: `how-to-run.bat` → `GHOST.bat` and
  `how-to-run.sh` → `ghost.sh`; all docs now reference the GHOST launcher by
  name. The direct-command cheat sheet moved from `how-to-run.txt` to
  [docs/cli.md](docs/cli.md), and the analyzer settings moved from the repo
  root to `tests/PSScriptAnalyzerSettings.psd1` (CI + test paths updated).
  Menu numbers are unchanged.

### Added

- **Python core** — `src/python/ghost/` (stdlib only: sqlite3, json,
  secrets, uuid) + `ghost_cli.py` bootstrap; owns the shared SQLite/JSON
  identity logic (identity sets, key UPSERT with verify-after re-read,
  secrets deletion, CLI telemetry scrub, chat-sync diff/hot-activity probe,
  JSON patch, audit log, restore-script generator). Tested by
  `tests/python/test_ghost_core.py` (30 stdlib `unittest` cases, mirrors the
  Pester suite + real-SQLite coverage) and a new CI `python-core` job.
- **GHOST launcher icon + shortcuts** — `assets/ghost.ico` (16–256, generated
  from the poster art by `tools/make_ghost_icon.ps1`: auto tile detection,
  rounded-corner transparency, committed `assets/ghost-source.png` master for
  regeneration). Since a `.bat` cannot carry an Explorer icon, the icon ships
  via `tools/install_ghost_shortcut.ps1` (menu [24]): `GHOST.lnk` on the
  Desktop and in the repo root, pointing at `GHOST.bat` (`.lnk` files are
  gitignored — regenerate, never commit).
- **ZCode multi-instance expansion** — Primary + three branded clones:
  **Second** (blue), **Third** (yellow), **Fourth** (green).
  - `launch_zcode_second_instance.ps1 -Instance Second|Third|Fourth` with
    per-clone homes (`ZCode{Second,Third,Fourth}Home`), roaming dirs
    (`ZCode-Second` / `ZCode-Third` / `ZCode-Fourth`), and first-run
    seed-clone + identity scrub; plus double-click wrappers
    `Launch-ZCode-Second/Third/Fourth.bat`.
  - `reset_zcode.ps1 -Target Third|Fourth|All` — per-instance resets with
    independent ID sets per child, per-target backups and scoped tree-kill
    (survivor instances keep running).
- `tools/patch_zcode_icon_override.ps1` (+ `.mjs` engine v6) — one-time
  `app.asar` patch enabling `ZCODE_ICON_DIR`, `ZCODE_AUMID_SUFFIX`,
  `ZCODE_ACCENT_HEX`, `ZCODE_INSTANCE_NAME` overrides (branded icon, separate
  taskbar button/pins, accent color, "ZCode <Color>" window title) and
  disabling the clones' auto-updater; marker file auto-upgrades older patches.
  Re-run after every ZCode app update (`GHOST.bat` menu [13]).
- `tools/install_zcode_second_shortcuts.ps1` — per-user Desktop + Start-menu
  shortcuts for all three clones, each with its own `System.AppUserModel.ID`
  so pins never collide with the Primary (`-Remove`, `-Instance`,
  `-RepairPrimaryAumid`); menu [14].
- `tools/refresh_zcode_second_chats.ps1` — cross-instance chat refresh
  without an app restart: finds shared-store chats missing from the target's
  sidebar index and recycles its app-server(s) (auto-respawn reseeds the
  index), with a multi-signal hot-activity guard and verify-after
  (`-Target Primary|Second|Third|Fourth|All`; menus [15]/[23]) plus an
  error-triggered `-Watch` daemon that refreshes every running instance on
  captcha-stall / quota / rate-limit failures (menu [22]). Supersedes the
  row-copying `test_live_inject.py` spike (deleted).
- `tools/zcode-{blue,yellow,green}-branding/` — per-clone icon assets
  (`icon_windows.png`, `tray_icon.ico`) and the shared generator.
- `GHOST.bat` menus [13]–[23]: icon patch, clone shortcuts, chat
  refresh (one-shot + watcher), clone launches (single + all), per-instance
  ZCode resets, and refresh-all.
- `tools/update_ghost.ps1` + `GHOST.bat` menu [26] — repo self-updater:
  fetches `origin`, compares HEAD with the remote default branch, lists the
  new commits, and asks before `git pull --ff-only` (`-CheckOnly` = report
  only). Refuses when local commits or a non-`main`/detached branch block the
  fast-forward; a dirty working tree gets an interactive stash → pull →
  restore (a failed restore keeps the stash). Verify-after re-reads HEAD; a
  failed fetch (offline) is a warning, not a failure.

### Security

- Docs depersonalized: machine-specific home paths replaced with
  `%USERPROFILE%` in `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md` (newly tracked).

## [1.0.0] — 2026-09-21

First tagged release; the repository restructured to standard open-source
conventions. No reset-script behavior changes in this release except where
noted.

### Changed

- **Repository layout**: `scripts/` → `src/`; docs consolidated; community
  files, tests, and CI added.
- **Filenames are unversioned** — versioning now lives in Git tags and this
  changelog. Old mapping:

  | Old name | New name |
  |---|---|
  | `scripts/windows/reset_cursor_windows-v0.2.ps1` | `src/windows/reset_cursor.ps1` |
  | `scripts/windows/reset_devin_windows-v0.3.ps1` | `src/windows/reset_devin.ps1` |
  | `scripts/windows/reset_trae_windows-v0.2.ps1` | `src/windows/reset_trae.ps1` |
  | `scripts/windows/reset_qoder_windows-v0.4.ps1` | `src/windows/reset_qoder.ps1` |
  | `scripts/windows/reset_qoderwork_windows-v0.1.ps1` | `src/windows/reset_qoderwork.ps1` |
  | `scripts/windows/reset_zcode_windows-v1.4.ps1` | `src/windows/reset_zcode.ps1` |
  | `scripts/windows/reset_minimax_opencode_windows-v1.2.ps1` | `src/windows/reset_minimax_opencode.ps1` |
  | `scripts/linux/reset_cursor_linux.sh` | `src/linux/reset_cursor.sh` |
  | `scripts/linux/reset_windsurf_linux.sh` | `src/linux/reset_windsurf.sh` |
  | `scripts/linux/change_device_id_linux.sh` | `src/linux/change_device_id.sh` |
  | `docs/AGENTS.md` | `AGENTS.md` (repo root) |

- Superseded versions (`archive/`, legacy `*-v0.1` fallbacks) are **no longer
  tracked** — they remain on disk as local-only rollback copies and are purged
  from Git history.
- `docs/AGENTS.md` moved to the repository root as `AGENTS.md` (single source;
  the contributor-facing conventions now live in `CONTRIBUTING.md`).

### Added

- Apache-2.0 `LICENSE`, `NOTICE`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`.
- Pester 5 test suite (`tests/`) and GitHub Actions CI
  (PSScriptAnalyzer + Pester on Windows; ShellCheck + `bash -n` on Linux).
- GitHub issue forms and PR template.
- `.env.example` for the optional Telegram alert credentials.

### Security

- Git history purged of `archive/` paths (contains old-fingerprint material).
- `.envlocal` (Telegram bot token) confirmed never committed; see
  `SECURITY.md` for the redaction rules that apply to all issues and PRs.

### Fixed

- `reset_devin.ps1` (formerly `reset_windsurf_windows-v0.3.ps1`): handles the
  June 2026 Windsurf → Devin Desktop rebrand — auto-detects and resets both
  `%APPDATA%\Devin` and `%APPDATA%\Windsurf` roots in one pass; scrubs
  `credentials.toml`, `config.json devin.org_id`, `cli\installation_id`,
  `.devin\argv.json`, and rebrand-era state.vscdb secret keys.
