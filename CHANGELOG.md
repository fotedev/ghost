# Changelog

All notable changes to GHOST are documented here. Versions are Git tags
(`vX.Y.Z`); script filenames are unversioned.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.0] — 2026-10-17

### Added

- **Python hybrid Phase 3 pilot — reset_cursor v0.3 thin manifest**
  (2026-10-17): the Cursor reset's 15 steps now run every store mutation
  through `src/python/ghost_cli.py` core subcommands via a single
  `Invoke-GhostCore` helper — new core modules `ghost/filesweep.py`
  (binary-store rename-or-delete, verified deletes, per-file tree sweeps)
  and `ghost/winstore.py` (machine-id file, device_id_salt rotation, dotted
  JSON key removal) plus 7 new subcommands (`backup`, `machineid-file`,
  `salt-rotate`, `json-remove`, `store-delete`, `sweep-file`, `sweep-tree`),
  all covered by the expanded unittest suite (58 cases incl. CLI bridge
  contracts). Step order, audit keys, restore actions and the summary are
  identical to v0.2 (archived at `archive/reset_cursor_windows-v0.2.ps1`,
  local-only); step 4's inline temp-.py heredoc — the last one in the repo —
  is replaced by the shared `delete-secrets` subcommand. Python is now
  required for ALL Cursor reset steps (fail-fast up front). 1031 → 840
  lines. The mandatory live comparison run (pilot acceptance #3) is
  user-supervised and pending. Decision record + design:
  [docs/PYTHON_HYBRID_ROADMAP.md](docs/PYTHON_HYBRID_ROADMAP.md) (Phase 2
  leaf-tools migration CANCELLED with per-tool reasons).

- **Phase 3 continuation — reset_devin v0.4 thin manifest** (2026-10-17):
  the Windsurf/Devin reset's 17 steps (14 per data root × Devin/Windsurf +
  3 global) run every store mutation through the core via `Invoke-GhostCore`,
  same contract as reset_cursor v0.3 (step order, audit keys, restore
  actions, summary identical to v0.3, archived at
  `archive/reset_devin_windows-v0.3.ps1`, local-only). New groundwork
  landed with it: `delete-secrets` generalized (optional exact_keys /
  like_patterns / `ESCAPE '\'` — the windsurf/devin auth patterns; defaults
  stay Cursor, zero caller breakage), `winstore.patch_argv_json` (JSONC
  regex — comments survive, crash-reporter-id replaced/inserted, username
  scrubbed), `winstore.replace_text` (raw-text scrub + absence verify) and
  `winstore.set_json_path` (dotted-path set with the absent-or-empty SKIP
  contract) + the `patch-argv` / `replace-text` / `json-set` subcommands.
  **The repo's last inline temp-.py heredoc is gone.** Also fixed in both
  manifests: `delete-secrets` `survivors` is a per-pattern LIST — PS
  `array -eq 0` filters elements instead of answering "all zero", so
  non-zero survivors could pass the step (reset_zcode already used
  `Measure-Object -Sum`). Python required for all steps; 1419 → 1003 lines.
  Live comparison run pending user supervision.

- **Clone-suite generator** (`tools/new_clone_suite.ps1`, 2026-10-17) —
  turns the app-cloning playbook's Phases 3-10 mechanics into scaffolding:
  from an intake JSON (or interactive defaults) it emits the reset manifest,
  clone launcher, `.bat` wrapper, AUMID-shortcuts installer (+ branding
  wiring + `-RepairPrimaryAumid`) and a spec stub with a ground-truth table,
  then wires a new GHOST.bat submenu (backup + anchor edit + verify-after,
  next submenu id / DispatchOne gids allocated by parsing the current file).
  Every emitted `.ps1` is parse-checked before the tool claims success;
  Phases 0-2 (discovery/isolation design) stay with the agent as marked
  `<TODO: Phase 1 discovery>` slots. Acceptance: a generated demo suite
  passed the harness and repo-integrity, then was removed.

- **ZCode per-clone Telegram bots (UI-assisted, EC-D03)** — `tools/set_zcode_bot.ps1`
  (`-VerifyOnly` audit / `-Target <name> -Fix` backup-first sync): fingerprints
  the encrypted `credentials.json -> bot:<id>:credential` (`enc:v1:`, sha8
  only, never values) + bot id across BOTH `bot-config.json` and
  `bot-config.v3.json` in all 4 homes (the 2026-10-16 Fourth `v2=False /
  v3=True` split looked disabled while polling — both files are now always
  checked); fails loudly on any duplicate-while-enabled (HTTP 409 risk).
  `src/windows/launch_zcode_second_instance.ps1 [2c]` upgraded from
  always-disable to sha8-compare (duplicate -> disable both files; unique ->
  preserve + `.telegram-routed` v2 marker, never reverted). Flow: operator
  creates 3 BotFather bots, pastes each token once in that clone's ZCode UI
  (app mints fresh `bot-<guid>` + `enc:v1:`), tooling guards/syncs. Quota
  decision 2026-10-16: Option C — Fourth keeps its big quota isolated.
  Docs: [docs/ZCODE_TELEGRAM_BOTS.md](docs/ZCODE_TELEGRAM_BOTS.md); tests:
  `tests/set_zcode_bot.Tests.ps1` (4 passing).

- **AutoClaw multi-instance clones (Primary + inst1–inst4)** — full suite per
  [docs/AUTOCLAW_CLONES_SPEC.md](docs/AUTOCLAW_CLONES_SPEC.md):
  `tools/patch_autoclaw_ports.ps1` (+ `.mjs` engine v1) widens the installed
  app's hardcoded 4-slot MCP port array to 8 (backup + marker + `-Restore`,
  verified byte-identical via SHA-256 round-trip; re-run after every AutoClaw
  update); `src/windows/launch_autoclaw_clone.ps1` (-Instance inst1..inst4,
  `-Status`) launches clones with env-var isolation (`USERPROFILE`/`HOME`,
  `AUTOCLAW_GATEWAY_PORT` with actual-port read-back + drift recording) and a
  credential-free seed (tokens stripped, `token-cache.json` excluded, gateway
  state never copied — one manual login per clone) plus verify-after-launch
  health/port/pairing checks; `src/windows/reset_autoclaw.ps1` (-Target
  Primary|inst1..4|All, `-DryRun`) rotates both device identities (auth
  `deviceId` + ed25519 keypair via node:crypto) and deletes the live operator
  credential; `tools/install_autoclaw_clone_shortcuts.ps1` installs per-clone
  AUMID shortcuts with `-RepairPrimaryAumid`; `src/windows/Launch-AutoClaw-Clone.bat`
  double-click wrapper. GHOST.bat gains a fourth submenu (AutoClaw
  Multi-Instance & Clones [1]–[12], gids 29–40) and IDE Resets [9].
- **App cloning playbook docs** — [docs/APP_CLONING_PLAYBOOK.md](docs/APP_CLONING_PLAYBOOK.md)
  (the generic clone-any-app process: identity suite with a
  never-silently-degrade rule, developer-inputs contract, icon policy with
  improvise+report as the default for missing icons, phases 0–10
  checklists, and a fixed final-report format),
  [docs/APP_CLONING_EDGE_CASES.md](docs/APP_CLONING_EDGE_CASES.md) (the
  normative EC-xx catalog distilled from the ZCode 2026-09 and AutoClaw
  2026-10 suites), and [docs/APP_CLONING_INTAKE_TEMPLATE.md](docs/APP_CLONING_INTAKE_TEMPLATE.md)
  (the per-request fill-in form). AGENTS.md gains the "App cloning playbook"
  section; `docs/README.md` indexes all three plus the previously missing
  AUTOCLAW spec row.

### Fixed

- **GHOST.bat menu input executed hostile self-input** (2026-10-17): the
  unquoted `%chain%` / `%choice%` expansions ran `1 & calc` verbatim and
  parens broke the parse. A new `:ValidateChoice` allowlists digits, spaces,
  commas and U/u inside an isolated delayed-expansion probe, and all five
  prompt sites reject before the "0" check, tokenization, for-in dispatch or
  `:RunChain` call. Harness 12/12 incl. hostile amp/parens/submenu scenarios.
- **Captcha watchdog could run twice and leaked its log-tail state**
  (2026-10-17): a second resident copy (menu [11] again) double-fired
  restarts/Telegram escalations on the shared state file — the watcher now
  carries the taskbar watcher's guard (startup process scan + named mutex,
  `-RunOnce` always runs). `Read-NewLogLines` was rewritten byte-level: it
  consumes only up to the last complete newline (a trailing partial line or
  partial multi-byte char is re-read complete next pass) and advances the
  offset by bytes actually consumed instead of a file length probed after
  `ReadToEnd` (the old race skipped whatever the agent appended in between).
- **update_ghost misidentified a Download-ZIP copy sitting inside another
  repository as a clone** (2026-10-17): `rev-parse --is-inside-work-tree`
  answers "true" against the PARENT repo, so the updater fetched/pulled/reset
  in the wrong place ("no origin remote" as the visible symptom). The clone
  track now additionally requires `--show-toplevel` to equal the GHOST folder
  itself; a parent-tree hit warns explicitly and routes into the ZIP-copy
  conversion flow.
- **Chat refresh classified a splash-phase clone as the Primary**
  (2026-10-17): `refresh_zcode_second_chats.ps1` matched mains by window
  title only, and a clone launching (splash title plain "ZCode") was claimed
  as a Primary main with its app-servers recycled as Primary's. Classification
  is now process-marker-first (the verified 2026-09-24/26 taskbar rule):
  WMI subtree walk to the root main, clone roaming/home markers, clone v6
  color title overrides a spurious Primary read; unresolved windows are
  skipped, never guessed. Live smoke against running instances passed.
- **Shortcut installers broke under PowerShell 7** (2026-10-17): both
  installers set the `.lnk` TargetPath to `$PSHOME\powershell.exe`, which
  does not exist in pwsh's own directory — shortcuts created by a pwsh-run
  installer targeted a nonexistent exe. They now pin the OS-shipped
  `System32\WindowsPowerShell\v1.0\powershell.exe` and fail fast if absent.
- **block_qoder_domains corrupted non-ASCII hosts comments** (2026-10-17,
  local-only tool): the hosts round-trip read BOM-less bytes as UTF-8 and
  wrote with ASCII encoding, flattening every non-ASCII character to a
  permanent `?`. Read/write now both use the system ANSI codepage (BOM
  auto-detect still wins), matching how the Windows resolver reads hosts —
  single-byte-codepage content survives byte-exactly.
- **IDE Resets [9] dispatched the wrong task**: the Resets submenu had no
  local→gid resolver, so typed ids reached `:DispatchOne` raw — local [9]
  "Reset AutoClaw" therefore ran global gid 9 (the ZCode captcha watchdog,
  already reachable as ZCode [11]) instead of gid 28
  (`reset_autoclaw.ps1 -Target Primary`). A `:ResetsOne` resolver now maps
  1–8 identity + 9→28, and both Resets dispatch sites route through it
  (the prompt loop and the main-menu chained input `1 9`); bare global ids
  from the main menu keep using `:RunChain`. Verified 2026-10-16: a
  harness extracted the shipped `:ResetsOne` verbatim and passed all five
  cases (1→gid 1, 8→gid 8, **9→gid 28**, unknown→error, chained `9 2`→
  gid 28 then gid 2); CRLF intact (434/0); Pester repo-integrity green.
- **Green-clone-alone showed the Primary's taskbar icon**: the Start-menu
  `ZCode.lnk` had been hijacked with `dev.zcode.app.4` AND its icon field
  wiped (`,0`), so the shell resolved the clone's AUMID to an icon-less
  shortcut and fell back to the exe default icon. `Repair-PrimaryAumid` in
  `tools/install_zcode_second_shortcuts.ps1` now also restores the Primary
  shortcut's icon to `<ZCode.exe>,0` (Desktop + both Start-menu copies
  covered), and the resident `tools/watch_zcode_taskbar.ps1` self-heals a
  hijack every ~5 min (read-only check, repair only when broken,
  REPAIR/FAIL logged; `-RunOnce -CheckPrimaryHijack` for a one-shot
  repair). Verified 2026-09-28: Primary `ZCode.lnk` back to `dev.zcode.app`
  with a healthy icon; the green window's identity was already correct.
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
  screen numbers its own tasks — Resets `[1]`–`[8]`, ZCode `[1]`–`[17]`
  (5 launch + 5 reset + 7 sync/watchers), Maintenance `[1]`–`[2]` — with
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
