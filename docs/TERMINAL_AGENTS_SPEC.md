# Terminal Agents — spec (claude-code + codex)

Status: **TWO SUITES LIVE** (2026-11-21: the claude-code pilot + the codex
suite). The Terminal Agents submenu is GHOST's home for *terminal* coding
agents — CLIs with no desktop window whose interactive REPL already IS a
terminal TUI (unlike the desktop-app suites, where the ZCode TUI cannot run
standalone at all — see [ZCODE_LIGHT_MODE.md](ZCODE_LIGHT_MODE.md)).

## 1. Why a new family

The four clone suites (ZCode / AutoClaw2 / Cline / OpenCode) are DESKTOP
apps: cloning them needs Electron/Tauri isolation layers (env levers, asar
patches, per-color exe copies). External terminal agents — **claude-code,
codex, gemini-cli, …** — are already headless CLIs, so the whole desktop
layer is unnecessary: cloning them needs exactly ONE thing, a per-instance
config home via an env lever, plus the GHOST identity work (reset + fresh
device identity per home). This spec records the evidence and the pattern
so each new agent is a small, evidence-gated addition.

## 2. claude-code — Phase-0 evidence (live probes, 2026-11-21, CLI 2.1.314)

All findings below were probed on the dev host; nothing is invented:

| Question | Evidence | Verdict |
|---|---|---|
| Binary | npm shim `%APPDATA%\npm\claude` (→ `node …\@anthropic-ai\claude-code\cli.js`); `claude --version` → `2.1.314 (Claude Code)` | functional probe required (`--version` exit 0 + version shape), never a bare path hit |
| Isolation lever | `CLAUDE_CONFIG_DIR=<dir>`: a fresh dir + `claude mcp list` created `<dir>\.claude.json` + `<dir>\backups\` there; `claude auth status` reports the dir as `configDirectory` | **LIVE-VERIFIED** — ONE env var redirects the entire store |
| Store layout (clone) | `CLAUDE_CONFIG_DIR=X` consolidates everything under X: `.claude.json`, `settings.json`, `projects\` (transcripts), `sessions\`, `history.jsonl`, `skills\`, `plugins\`, `cache\`, `state\`, `backups\`, `.credentials.json` | live-probed structure |
| Store layout (Primary) | WITHOUT the env var the JSON store stays at the PROFILE ROOT (`~\.claude.json`, observed 11.6 KB there) while the dir tree lives in `~\.claude\` | **layout asymmetry** — the resetter handles both shapes |
| Device identity | `.claude.json` carries `machineID` + `userID`; a fresh probe dir generated `0fea79a0…` while the Primary holds `4bc5e04e…` | fresh homes self-identify; a reset scrubs the keys to re-identify |
| Identity/telemetry keys | `machineID`, `userID`, `firstStartTime`, `numStartups`, `tipsHistory`, `tipLifetimeShownCounts`, `seenNotifications`, `lastReleaseNotesSeen`, `changelogLastFetched`, `closedIssuesLastChecked`, `skillUsage`, `pluginUsage`, `lastPlanModeUse` (all observed in the live file) | the resetter's scrub list; absent keys are verified no-ops |
| Auth | `~\.claude\.credentials.json` (OAuth token) inside the config dir; `claude auth login/logout/status` | reset deletes the file (re-login required); `-Login` runs `auth login` per home |
| Headless surface | `claude -p/--print` one-shot; default = interactive REPL (a terminal TUI) | natively headless AND TUI-capable |
| Permissions | `--dangerously-skip-permissions` (+ `--allow-dangerously-skip-permissions` opt-in flag) | one-shot tasks needing tool approvals fail without `-Yolo` |
| **Gateway lever** | Z.ai's GLM Coding Plan officially exposes an Anthropic-compatible endpoint (`https://api.z.ai/api/anthropic`) documented FOR Claude Code: `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` replace OAuth entirely ([docs.z.ai/scenario-example/develop-tools/claude](https://docs.z.ai/scenario-example/develop-tools/claude), [docs.z.ai/devpack/tool/others](https://docs.z.ai/devpack/tool/others)) | **VERIFIED-DOCS 2026-11-21** (upstream official); live use gated on the user's own Z.ai API key; secrets ride machine-env var names only |

**Honest limits (LIVE acceptance 2026-11-21, half-verified — TA-1):**
- There is NO free-model fallback for claude-code (unlike the ZCode/OpenCode
  workers), and the user holds NO paid Anthropic subscription — so until a
  home's own `-Login` ran (gated on Pro/Max or Console credits), headless
  use is UNAVAILABLE.
- **The unauthenticated failure mode is a HANG, not an error** (live-captured
  2026-11-21): `claude -p "…"` without credentials sits silently forever in a
  non-TTY session (120s+ observed, zero output — waiting on interactive
  login/onboarding that can never complete headlessly). The launcher's
  light-worker marker honestly reports the stuck worker RUNNING the whole
  time; killing the claude child lets the launcher's cleanup remove the
  marker and the fleet row returns to `stopped`. Rule: ALWAYS `-Login`
  first; a hung `-p` IS the unauthenticated signature.
- **The marker + fleet-view contract is VERIFIED LIVE** on this suite: the
  mid-run capture showed `c1 RUNNING / signal light worker /
  YES (pid 15312, prompt)` with the marker JSON on disk, and a clean
  `stopped` after the child died.
- Whether a fresh home needs interactive onboarding before headless use
  remains untested (gated on a subscription) — with the hang above, treat
  every unauthenticated headless run as unusable regardless.

## 3. codex — Phase-0 evidence (live probes, 2026-11-21, CLI 0.166.0)

All findings below were probed on the dev host; nothing is invented:

| Question | Evidence | Verdict |
|---|---|---|
| Binary | npm shim `%APPDATA%\npm\codex` (`codex.cmd`/`codex.ps1` → `node …\@openai\codex\bin\codex.js` → the vendored native `codex.exe` under `@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\`); `codex --version` → `codex-cli 0.166.0` | functional probe required (`--version` exit 0 + `codex-cli\s+\d+\.\d+` shape), never a bare path hit |
| Isolation lever | `CODEX_HOME=<dir>`: `--version`, `codex login status` ("Not logged in", exit 1), `codex mcp list` and an exec attempt ALL honored the override (the binary's own banner names `codex_home`; 84 `CODEX_HOME` references in the binary); the Primary `~\.codex` was byte-identical before/after every probe | **LIVE-VERIFIED** — ONE env var redirects the entire store |
| Store layout (clone = Primary shape) | A REAL run attempt auto-generates the runtime state in a fresh home: `installation_id` (36 B UUID), six SQLite stores (`state_5/logs_2/goals_1/queue_1/memories_1/thread_history_1` + `-wal/-shm`), `.sandbox_migration`, `.sandbox\` logs, `.tmp\` plugin clones, `sessions\`, `skills\`, `thread-writer-locks\`. Read-only commands (`login status`, `mcp list`) create NOTHING; `config.toml` and `auth.json` are NOT auto-created | live-probed; **NO layout asymmetry** — Primary and clones consolidate inside the home (CODEX_HOME only moves where "inside" is) |
| Device identity | `installation_id` auto-generates on the first real run (the fresh probe home got one immediately) | fresh homes self-identify; the resetter DELETES it — proven to regenerate fresh |
| Auth | `auth.json` inside the home (Primary observed keys: `OPENAI_API_KEY` + `auth_mode` — API-key auth shape); `codex login` (browser/device flow) or `codex login --with-api-key` (key via stdin); `codex login status` exit 1 = not logged in | reset deletes the file (re-login required); `-Login` runs `codex login` per home |
| Headless surface | `codex exec` one-shot (prints its session banner immediately); default = the interactive TUI | natively headless AND TUI-capable |
| Permissions | `codex exec` defaults to sandbox read-only + approval never; `--yolo` (= `--dangerously-bypass-approvals-and-sandbox`) bypasses both | one-shot tasks that write files need `-Yolo` |
| stdin quirk | `codex exec` prints "Reading additional input from stdin..." and consumes stdin | the launcher's one-shot CLOSES stdin (`$null \| & $CodexExe …`) so a run cannot stall on an open console pipe |
| Skills | codex loads skills from the SHARED `~\.agents` store (a fresh-home exec read `C:\Users\FOTE\.agents\skills\*.md`) | skills are NOT isolated per clone home (honest limit, shared by design) |
| gemini-cli | `gemini` binary ABSENT (npm globals carry only `@openai`); `~\.gemini` belongs to Antigravity (`agy.exe`, `antigravity*` subdirs) | **deferred-by-absence** — never touched until the real gemini CLI exists |

**Honest limits (live-captured 2026-11-21):**
- A fresh home with no auth FAILS a one-shot with an AUTH error after
  printing its banner — it does NOT hang silently (unlike claude-code).
  `codex login status` = "Not logged in" (exit 1). Fix = `-Login` for THAT
  home or `codex login --with-api-key`. No free-model fallback.
- Under a TEMP-shaped home the binary warns it refuses to create PATH-alias
  helper binaries (probe artifact only — real profile homes are unaffected).
- The runtime SQLite stores are HOT: `state_5.sqlite-wal` wrote ~2.3 MB even
  on an unauthenticated run attempt. Close codex sessions before a reset
  (the resetter warns; it never kills).

## 4. Components

- `src\windows\launch_claude_code_light.ps1` — the claude-code light worker
  (`-Instance c1..c5`, interactive REPL default / `-Prompt` one-shot /
  `-Yolo` / `-Login` / `-Status` / `-Gateway`). Creates the clone home on
  first launch (there is no desktop first-run to seed it), sets
  `CLAUDE_CONFIG_DIR`, writes the shared light-worker PID marker
  (`ghost_light_marker.ps1`) around every run mode, verifies the login via
  `.credentials.json`.
- `src\windows\reset_claude_code.ps1` — the claude-code identity resetter
  (user-scope only, never elevates, never kills). `-Instance cN` /
  `-ConfigDir <dir>` / default Primary. W1-9-style dry-run planner first
  (`-DryRun`), then: [1] `.claude.json` identity/telemetry key removal
  (core `json-remove`; `mcpServers` + `projects` + flags PRESERVED), [2]
  `.credentials.json` delete (backup-first), [3]
  `backups\.claude.json.backup.*` sweep (old machineID copies), [4]
  `state\` + `mcp-needs-auth-cache.json`, [5] `cache\` + `statsig\` sweeps,
  [6] verify-after.
- `src\windows\launch_codex_light.ps1` — the codex light worker (same mode
  set minus `-Gateway`). Sets `CODEX_HOME`, closes stdin in the one-shot
  (`codex exec --skip-git-repo-check`), verifies the login via `auth.json`.
- `src\windows\reset_codex.ps1` — the codex identity resetter (user-scope
  only, never elevates, never kills). `-Instance cN` / `-CodexDir <dir>` /
  default Primary. Dry-run planner first, then: [1] `auth.json` delete
  (backup-first), [2] `installation_id` delete (PROVEN regenerated fresh),
  [3] `cap_sid` sweep, [4] runtime SQLite sweep (`state_*/logs_*/goals_*/
  queue_*` + wal/shm — `memories_*` and `thread_history_*` PRESERVED), [5]
  `version.json` + `.sandbox_migration` + `.sandbox\` + `.tmp\` sweeps, [6]
  verify-after. NO TOML/JSON edits at all — `config.toml` is user settings
  and is never touched. A rerun after a real reset hits the fresh-home
  guard loudly (both identity anchors gone = a fresh home by definition).
- `tools\status_all_instances.ps1` + `tools\suite_status_lib.ps1` — the
  claudecode + codex suite rows in the cross-suite fleet view (Maintenance
  [6] / Terminal Agents [4] and [9]). Attribution is **markers-only** for
  both: `CLAUDE_CONFIG_DIR` / `CODEX_HOME` are env-only (never visible in a
  command line), so a clone's running processes are claimed through their
  light-worker marker (launcher pid → process-tree descendants); unclaimed
  family processes are the user's own default-profile usage (Primary,
  honestly labeled, not GHOST-managed).
- Menu: Terminal Agents submenu — GHOST.bat main-menu row [7] +
  `:TerminalOne` + `:DispatchOne` gids **127-136** (claude-code 127-130 +
  gateway 132; codex 133-136; ceiling raised 132→136);
  `src\desktop\menu.json` "Terminal Agents" section.

## 5. Preservation policy (same doctrine as every GHOST resetter)

- **claude-code** — NEVER touched (audited in the plan output):
  `projects\` transcripts, `sessions\`, `session-env\`, `history.jsonl`,
  `settings.json`, `skills\`, `plugins\`, `daemon\`, `.claude.json`
  `mcpServers`/`projects`/`hasCompletedOnboarding`/migration flags, and
  USER-MADE `~\.claude.json.bak-<name>` backups (only claude-code's own
  `backups\.claude.json.backup.*` remnants go).
- **codex** — NEVER touched (audited in the plan output): `config.toml`
  (user model settings, `mcp_servers`, plugins, marketplaces, projects
  trust, hooks), `AGENTS.md` (user instructions), `.codex-global-state.json`
  (+ `.bak`, the desktop app's UI state), `history.jsonl`,
  `session_index.jsonl`, `transcription-history.jsonl`, `sessions\` (chat
  rollout transcripts), `memories_*.sqlite` + `thread_history_*.sqlite`
  (+ wal/shm), `MCP_Backups\`, `plugins\`, `skills\`, `vendor_imports\`,
  `visualizations\`, `computer-use\`, `sqlite\`, and USER-MADE backups.

## 6. Open items

- **TA-1 (half-DONE 2026-11-21; the real turn is now UN-BLOCKED via the
  Z.ai gateway lever)** — the fleet-view + marker contract is VERIFIED LIVE
  (see the claude-code honest limits above). The remaining items — one real
  `-Prompt` turn, the onboarding question, and the reset + re-login cycle —
  needed an Anthropic subscription the user does not hold, SO the **gateway
  lever shipped (2026-11-21)**: set
  `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`
  + `ANTHROPIC_AUTH_TOKEN=<Z.ai API key>` once via setx and Terminal Agents
  [5] runs a real verify turn on c1 riding the EXISTING Z.ai plan — no
  Anthropic account, no OAuth login. With the pair set the launcher's
  no-login warning goes quiet (gateway auth satisfies headless use). The
  user-supervised step is fetching the key from the Z.ai console and
  running the two setx commands (the recipe is printed by [5] when unset).
- **TA-2 (DONE for codex 2026-11-21 — this wave)** — the codex suite
  shipped (gids 133-136; `CODEX_HOME` lever LIVE-VERIFIED; evidence in §3).
  **gemini-cli stays deferred-by-absence**: the CLI does not exist on this
  machine and `~\.gemini` is Antigravity's store — never touched until the
  real CLI is installed (own Phase-0 probes first, no invented paths).
- **TA-3 (SHIPPED for both suites)** — per-clone identity resets ride the
  resetters' `-Instance cN` (claude-code) / `-Instance cN` (codex); the
  menu rows reset the Primary, clone-home resets run the script with
  `-Instance` (documented in the confirm text + docs/cli.md). A real
  `codex login` on a clone home remains USER-SUPERVISED.
