# Terminal Agents — spec (claude-code pilot)

Status: **PILOT LIVE** (2026-11-21). The Terminal Agents submenu is GHOST's
home for *terminal* coding agents — CLIs with no desktop window whose
interactive REPL already IS a terminal TUI (unlike the desktop-app suites,
where the ZCode TUI cannot run standalone at all — see
[ZCODE_LIGHT_MODE.md](ZCODE_LIGHT_MODE.md)).

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

**Honest limits (DERIVED until live acceptance = TA-1):** whether a fresh
home needs interactive onboarding before headless use; how a long REPL
session behaves under the light-worker marker contract. There is NO
free-model fallback for claude-code (unlike the ZCode/OpenCode workers) — a
fresh home fails auth errors until its own `-Login` ran.

## 3. Components

- `src\windows\launch_claude_code_light.ps1` — the light worker
  (`-Instance c1..c5`, interactive REPL default / `-Prompt` one-shot /
  `-Yolo` / `-Login` / `-Status`). Creates the clone home on first launch
  (there is no desktop first-run to seed it), sets `CLAUDE_CONFIG_DIR`,
  writes the shared light-worker PID marker (`ghost_light_marker.ps1`)
  around every run mode, verifies the login via `.credentials.json`.
- `src\windows\reset_claude_code.ps1` — the identity resetter (user-scope
  only, never elevates, never kills). `-Instance cN` / `-ConfigDir <dir>`
  / default Primary. W1-9-style dry-run planner first (`-DryRun`), then:
  [1] `.claude.json` identity/telemetry key removal (core `json-remove`;
  `mcpServers` + `projects` + flags PRESERVED), [2] `.credentials.json`
  delete (backup-first), [3] `backups\.claude.json.backup.*` sweep (old
  machineID copies), [4] `state\` + `mcp-needs-auth-cache.json`, [5]
  `cache\` + `statsig\` sweeps, [6] verify-after.
- `tools\status_all_instances.ps1` + `tools\suite_status_lib.ps1` — the
  claudecode suite rows in the cross-suite fleet view (Maintenance [6] /
  Terminal Agents [4]). Attribution is **markers-only**: `CLAUDE_CONFIG_DIR`
  is env-only (never visible in a command line), so a clone's running
  processes are claimed through their light-worker marker (launcher pid →
  process-tree descendants); unclaimed claude-code family processes are the
  user's own default-profile usage (Primary, honestly labeled, not
  GHOST-managed).
- Menu: Terminal Agents submenu — GHOST.bat main-menu row [7] +
  `:TerminalOne` + `:DispatchOne` gids **127-130** (ceiling raised
  125→130); `src\desktop\menu.json` "Terminal Agents" section.

## 4. Preservation policy (same doctrine as every GHOST resetter)

NEVER touched (audited in the plan output): `projects\` transcripts,
`sessions\`, `session-env\`, `history.jsonl`, `settings.json`, `skills\`,
`plugins\`, `daemon\`, `.claude.json` `mcpServers`/`projects`/
`hasCompletedOnboarding`/migration flags, and USER-MADE
`~\.claude.json.bak-<name>` backups (only claude-code's own
`backups\.claude.json.backup.*` remnants go).

## 5. Open items

- **TA-1 (OPEN, user-supervised)** — live acceptance: one real `-Login` on
  a clone home + one real `-Prompt` turn; confirm the fleet view shows the
  worker running via its marker and that the reset + re-login cycle holds.
- **TA-2 (BACKLOG)** — codex (`CODEX_HOME` env lever, TOML config at
  `~\.codex\config.toml`) and gemini-cli: same pattern, own Phase-0 probes
  first (no invented paths).
- **TA-3 (BACKLOG)** — per-clone reset menu rows (`-Instance cN`) once the
  suite grows beyond the pilot.
