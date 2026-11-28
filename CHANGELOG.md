# Changelog

All notable changes to GHOST are documented here. Versions are Git tags
(`vX.Y.Z`); script filenames are unversioned.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **AutoClaw2 chat lineage + all-to-all mesh sync (2026-11-28)** — the chat
  import layer grew an identity: imports are now tracked per ORIGIN
  (`ChatLineage` back-traces each imported session to its source
  profile/session through the sidecar, with cycle + unknown-origin
  refusals), the active-account pointer (`device\active-product-account.json`)
  drives account selection, and every chat writer holds a cross-process
  lock (`Local\GhostAutoClaw2ChatMesh-<sha>` / flock on POSIX). New core
  verbs + tools: `ac2-chat-reconcile` (account-scoped, digest-planned,
  reversible cleanup of duplicated import history — dry-run returns a
  `plan_id`, apply re-verifies plan + closed target + backup inside
  `BEGIN IMMEDIATE`) and `ac2-chat-mesh` (convergence across Primary +
  c1..c5: per-lineage winners/forks by prefix-extension, append-only
  replay that never seeds a target work queue, sidecar-before-commit
  provenance, one retained verified backup per account, busy profiles
  QUEUED never stopped); `tools/watch_autoclaw2_chat_sync.ps1` (resident
  watcher on a runtime signature + `-RunOnce` preview/apply + autostart,
  AutoClaw2 [26] preview / [27] apply, gids 137/138),
  `tools/launch_autoclaw2_primary_sync.ps1` (Sync & Open Primary Desktop
  handoff — waits for Primary to quit, one gated pass, relaunches the
  stock exe non-elevated), `tools/inspect_autoclaw2_chat_runtime.ps1`
  (fail-closed busy-profile probe by `--user-data-dir`, never exe color)
  and `tools/autoclaw2_primary_lnk.ps1` (shared stock-lnk drift library).
  The clone launcher now matches windows by exe path (splash-swap-safe
  taskbar kick), sets `ZWORK_RELAUNCH_NAME`/`ZWORK_RELAUNCH_COMMAND` and
  repairs a stock lnk Windows retargeted during cold start;
  `patch_autoclaw2_identity.ps1` is engine v3 (fifth `window-relaunch`
  anchor); the shortcuts installer's `-RepairPrimaryAumid` is rebuilt on
  the lnk library (AUMID or per-color-exe drift, hash-verified backups)
  with `-RefreshTaskbar`. Spec docs extended
  (`AUTOCLAW2_SYNC_SPEC.md` lineage/reconciliation/mesh sections).
- **CS-7: OpenCode config-sync goes LIVE (2026-11-22)** — the Phase-0 probe
  (controlled live test on clone c1 running its own v2.3.2 service with the
  config directory watcher armed) LIVE-VERIFIED that a running desktop
  clone re-reads its config on change: an external edit fired
  `config.updated` in the clone's service log within ~2s, for BOTH write
  styles (in-place AND the atomic temp+Replace swap). So
  `sync_opencode_config.ps1` now syncs RUNNING clones by default (with a
  live-reload verify-after that polls the clone's own service log for the
  fresh event and reports VERIFIED / NOT observed — absence is a WARN,
  never a failure: the v1 npm CLI binary is startup-only);
  `-SkipRunning` restores the old skip as an opt-out. Two hardening fixes
  rode along: the merge write is now ATOMIC (temp + `File.Replace`), and
  the merge containers were fixed to the app's REAL shape (`mcp.servers.*`
  nested + direct `mcp.*` entries — the old flat walk let the Primary's
  whole `servers` block silently drop clone-only servers inside it;
  regression-tested). Audit entries gain `running`/`liveReload`. Probe
  history + the service-sharing discovery recorded in
  `docs/OPENCODE_CONFIG_SYNC_PLAN.md` §Phase-0 and TASK_BACKLOG (new CS-10
  spike).
- **CS-10: the OpenCode v2.3.2 service-sharing isolation break — fixed
  per-launch (2026-11-23)** — v2.3.2 keeps a machine-global background
  service registry (`$XDG_STATE_HOME ?? ~/.local/state\opencode\service.json`)
  and the desktop app JOINS a live compatible service at startup BEFORE the
  patched clone-home branch can set `XDG_STATE_HOME`; since the service
  process owns the data home, a joining clone's sessions landed in the
  Primary's `opencode.db` (db-verified). `launch_opencode_clone.ps1` now
  sets the four `XDG_*` levers at PROCESS-ENV level around `Start-Process`
  (saved/restored) — the clone always spawns its OWN clone-local service
  (live-verified: the Primary db byte-untouched with the Primary daemon
  up) — plus a read-only machine-registry guard (WARN when the recorded
  pid is alive; GHOST never writes/deletes the registry). The registry
  tail is now CLOSED (2026-11-28, deep-mined + patched): the app never
  writes `service.json` — the spawned CLI child self-registers using the
  `XDG_STATE_HOME` its env carried at process start, and the app's UNIQUE
  win32 desktop-init deleter (`delete process.env.XDG_STATE_HOME`, ONE
  site in the whole asar) always strips that lever, so the child
  registered machine-default (last-writer-wins — the next Primary launch
  would join the clone's daemon). Patch engine v5 guards the deleter with
  the patch's own global (`globalThis.__opencodeCloneHome||`): the child
  now registers at `<cloneHome>\state\opencode\service.json`, the machine
  registry is only ever written by the Primary's own service, and the
  Primary keeps stock behavior (anchor drift aborts; anchor-absent
  pre-2.3.2 builds skip loudly; 2.4.2 anchors re-verified — the vy
  deleter is still exactly one site, and a full-engine dry-run on the
  live 2.4.2 asar — candidate to %TEMP%, no swap — passed the complete
  pipeline: totals 1/1/1, `node --check` clean, rebuild + verify OK).
  The swap then ran live (2026-11-28, OpenCode closed) and exposed a
  real driver bug: the post-swap probe passed a JSON array through the
  PS 5.1 native-argument boundary, which STRIPS embedded double quotes
  — `JSON.parse` threw AFTER the fully successful swap and the run's
  marker was lost (the machine was repaired: the marker written with
  verified metadata, the backup pairing verified pristine). Driver v5.1
  embeds the need list as a single-quoted JS literal (the shape that
  survives the boundary) and re-pairs a markerless-but-patched asar with
  a scanned pristine backup instead of backing up the patched bytes.
  **LIVE ACCEPTANCE PASSED on c1**: `c1\state\opencode\service.json`
  appeared (the spawned child registered CLONE-LOCALLY), the machine
  registry stayed byte-untouched through every step, and a second c1
  launch REUSED the clone's own service. One manual ingredient — the
  per-clone port — became the new CS-11 spike: **v2.4.2 FIXED the
  service port at the compiled default 28894 and refuses to start on
  collision** (the 2.3.2-era "ephemeral port" verdict is superseded);
  `opencode service set port <port>` persists per-clone to
  `<configHome>\opencode\service.json`, so the launcher seeding a frozen
  per-clone port map is the remaining fix.
- **CS-11: the per-clone service-port seeding (2026-11-28)** — the fix
  for the 2.4.2 fixed-port collision. A shared helper
  (`src/windows/ghost_opencode_service_port.ps1`) carries the frozen
  map **c1..c5 → 28901..28905** (mutual distinctness only — the port
  default is version-computed, not a literal) and
  `Initialize-GhostOpenCodeServicePort` seeds
  `<cloneHome>\config\opencode\service.json`: a valid existing port is
  SKIPPED loudly (a hand-tuned port is never overwritten), otherwise the
  file is MERGED (every existing key preserved — notably the pre-shared
  service password — and `port` set), written atomically via the shared
  `Write-JsonNoBom` (no BOM), verify-after re-read, warn-never-block.
  Wired into BOTH launchers: the desktop launcher's new **[2d/5]**
  pre-launch step and the light worker's run path (its default run
  auto-starts the same `serve --service` child); `-Status` surfaces the
  seeded port. Functional fixtures (fresh/skip/merge/invalid-JSON) +
  launcher/light pins. **Live c2 acceptance**: the fresh seed wrote
  28902, the child started with ZERO collision errors and registered
  clone-locally on 28902 (machine registry byte-untouched) — two seeded
  instances now coexist live.
- **TA-2 (partial): the status tools run on the shared classifier
  (2026-11-28)** — of the 8 real per-suite classifier sites, the two
  non-destructive STATUS tools are flipped onto
  `tools/suite_status_lib.ps1`: `status_zcode_instances.ps1` (running-
  ness from the lib; its detail probes — roaming/clone home/deviceMid —
  and the commit pressure stay) and `diagnose_suite_pressure.ps1` (the
  `[1]` table lib-backed with the snapshot injected, which ADDS the
  subtree-marker walk and the LightWorker column it lacked). The taskbar
  watchers (need a window→instance lib API) and the four reset
  kill-target resolvers (kill-safety deltas) stay, recorded with
  reasons. Factual drifts reconciled with evidence: the per-color
  AutoClaw2 exe copies DO exist (the reset's stale comment fixed), and
  the AutoClaw2 profile lockfile is **live-verified** (exists exactly
  while the app runs, gone after stop) — the lib's autoclaw2 row gained
  the lockfile probe, so a HELD lock now claims a stock-exe clone and
  the blanket "UNCLASSIFIABLE" note is gone for that suite.
- **Repo-hygiene wave (2026-11-28)** — four recorded follow-ups closed in
  one pass: the merge-helper trio (`ConvertTo-DeepHashtable` /
  `Test-DeepEqual` / `Write-JsonNoBom`) moved into the shared
  `tools/json_merge_lib.ps1` (the three pure merge cores dot-source it;
  the dedup also FIXED A REAL BUG — `cline_mcp_merge.ps1`'s drifted copy
  compared `$B[$i]` instead of `$eb[$i]` in the array branch, diverging
  for non-IList enumerables; the shared lib is the ATOMIC writer shape);
  the two redundant literal `1-136` dispatch-header pins deleted (the
  generic repo-integrity pin derives the ceiling and is strictly
  stronger); the 24h ID_Backups purge floor (the #73 zcode policy shape)
  ported to `reset_cursor.ps1` + `reset_devin.ps1` — a same-day re-run
  can no longer erase the only undo copies of an earlier chained run
  (trae/zcode/qoder already carried it); and the one stale doc spot
  (`docs/architecture.md` patch row → engine v5). Pins: the purge-floor
  contract across all five floored resetters + a no-inline-copies guard
  on the three merge cores.

## [1.7.0] - 2026-11-22

### Added
- **Terminal Agents suite 2: codex (2026-11-21)** — the OpenAI Codex CLI
  (npm `@openai/codex`) joins as the second Terminal-Agents suite, on the
  claude-code pilot's exact pattern: ONE env-lever home (`CODEX_HOME`,
  Phase-0 LIVE-VERIFIED — `--version`, `codex login status`, `codex mcp
  list` and an exec attempt all honored it while the Primary `~\.codex`
  stayed byte-identical), light-worker PID markers for attribution, and an
  evidence-based identity resetter. `launch_codex_light.ps1` (Terminal
  Agents [6]/[7], gids **133**/**134**): interactive TUI default,
  `codex exec --skip-git-repo-check` one-shot with STDIN CLOSED (codex
  exec reads stdin — live-captured), `-Yolo` = `--yolo`, `-Login` verifies
  `auth.json`. `reset_codex.ps1` (Terminal Agents [8], **gid 135**):
  deletes `auth.json` + `installation_id` (PROVEN to regenerate fresh) +
  `cap_sid` + the runtime SQLite stores (`state_*/logs_*/goals_*/queue_*`
  + wal/shm) + sandbox/tmp junk; `config.toml`, `AGENTS.md`, chats
  (`sessions\`), memories and thread history PRESERVED; NO TOML/JSON
  edits at all. `status_all_instances.ps1` + `suite_status_lib.ps1` gain
  the codex suite (markers-only attribution like claude-code; Terminal
  Agents [9] = **gid 136**, ceiling 132→136). Honest limits recorded:
  an unauthenticated `codex exec` FAILS LOUDLY (no claude-style hang) and
  skills load from the SHARED `~\.agents` store. gemini-cli stays
  deferred-by-absence (`~\.gemini` is Antigravity's).

### Added
- **Terminal Agents: the Z.ai gateway lever — claude-code rides the existing GLM plan (2026-11-21)** —
  Z.ai's GLM Coding Plan officially exposes an Anthropic-compatible endpoint
  (`https://api.z.ai/api/anthropic`, documented for Claude Code), so the
  claude-code clones no longer need an Anthropic subscription: set
  `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` once via setx (machine env;
  the token value is never printed or stored by GHOST) and the gateway IS
  the auth — no OAuth login, and the launcher's no-login warning goes
  quiet. `launch_claude_code_light.ps1` gains `-Gateway` (Terminal Agents
  [5], **gid 132**, ceiling 130→132): prints the exact setx recipe when
  unset, and runs a REAL verify turn on the c1 home (light-worker marker on)
  when set. Un-blocks the remaining TA-1 items (real turn + onboarding
  question) on the user's existing Start Plan — the only user-supervised
  step left is fetching a Z.ai API key and running the recipe.

### Verified
- **TA-1 live acceptance, half-verified (2026-11-21)** — the light-worker
  PID-marker + fleet-view contract VERIFIED LIVE on the claude-code suite
  (mid-run `c1 RUNNING / light worker` capture + clean `stopped` after);
  the no-subscription failure mode captured: an unauthenticated headless
  `-p` HANGS silently (always `-Login` first). The real login + turn stay
  OPEN, gated on an Anthropic subscription. Docs: TASK_BACKLOG TA-1,
  TERMINAL_AGENTS_SPEC §2/§5, cli.md honest limits.

### Added
- **ZCode clone memory sync — one shared memory store for all instances
  (2026-11-21)** — each clone's `.zcode\cli\memories` is a private seed-time
  copy, so memory saved in one instance never reached the others (live
  measurement: five clone stores of 233 markdown files each vs 957 on the
  Primary, MEMORY.md index pointers diverged by hundreds of lines). New
  `tools/sync_zcode_memories.ps1` (ZCode submenu [34], gid 131) applies the
  skills-sync junction pattern to the memory stores: newer-wins robocopy
  merge clone→Primary (`/E /XO`, Primary never downgraded; junk
  `_backup-merge-*` / `memories.pre-sync-*` dirs excluded everywhere), a
  UTF-8-safe MEMORY.md index union with a mojibake peel, whole-dir
  move-aside backup (`memories.pre-sync-<ts>`), junction onto the Primary
  store, verify-after everywhere (junction LinkType + resolved target +
  content probe; index writes re-read + compared), JSONL audit at
  `<CloneHome>\.zcode\memory-sync-audit.jsonl`. Encoding is the whole point:
  the peel exists because the 2026-11-21 live incident showed PS 5.1
  `Get-Content` ANSI defaults re-appending UTF-8 index lines as layered
  mojibake (one real index: 7749 lines holding 845 unique) — the lib
  (`tools/zcode_memory_merge.ps1`, pure + unit-tested) reads/writes explicit
  no-BOM UTF-8, peels CP1252-as-UTF-8 layers with an EXCEPTION-fallback
  encoder (bare GetEncoding(1252) BEST-FITS unmappable chars like Arabic
  alef to '?', silently corrupting them — caught by the fixtures), and
  preserves single-line arrays through the return unwrap. Guards mirror the
  asset sync: RUNNING instances skipped unless `-AllowRunning` (owner
  override), unseeded homes skipped, already-junctioned stores verified +
  idempotent-skipped. `-Target Second|Third|Fourth|Fifth|Sixth|All`,
  `-DryRun`. Derived from the live all-with-all sync performed 2026-11-21;
  live acceptance on a fresh multi-clone machine pending. Docs: cli.md
  "ZCode clone memory sync", getting-started ZCode [34], README task table.
- **Terminal Agents family + the claude-code pilot (2026-11-21)** — GHOST's
  home for TERMINAL coding agents (CLIs whose interactive REPL already is a
  terminal TUI, so no desktop isolation layer is needed). Pilot = claude-code
  (npm `@anthropic-ai/claude-code` 2.1.314, Phase-0 evidence-cited):
  per-instance homes ride ONE env lever (`CLAUDE_CONFIG_DIR` — live-verified:
  a fresh dir + `claude mcp list` creates `.claude.json` + `backups\` there;
  each fresh home auto-generates its own `machineID`/`userID`). New:
  `src/windows/launch_claude_code_light.ps1` (`-Instance c1..c5`, REPL /
  `-Prompt` / `-Yolo` / `-Login` / `-Status`; light-worker PID marker around
  every run mode; login verified via the home's own `.credentials.json`) +
  `src/windows/reset_claude_code.ps1` (user-scope resetter, W1-9 dry-run
  planner, evidence-based identity/telemetry key scrub + OAuth deletion +
  `backups/.claude.json.backup.*`/`state`/`cache`/`statsig` sweeps;
  transcripts/sessions/history/settings/skills/mcpServers PRESERVED; handles
  the Primary profile-root `.claude.json` vs clone consolidated-home layout
  asymmetry; fixture-tested end-to-end incl. idempotence). Honest limits
  recorded: no free-model fallback (fresh homes need their own `-Login`);
  one-shot tool approvals need `-Yolo`. Spec:
  `docs/TERMINAL_AGENTS_SPEC.md`; open items TA-1 (live acceptance,
  user-supervised) + TA-3 (codex/gemini backlog) in TASK_BACKLOG §5.
- **Unified cross-suite instance status — Maintenance [6] (gid 126) +
  Terminal Agents [4] (gid 130)** — "how do I know which clone/instance is
  running" answered in ONE read-only report:
  `tools/status_all_instances.ps1` covers every suite (ZCode, AutoClaw2,
  Cline, OpenCode, Claude Code) in one invocation with honestly-labeled
  signals (exe copy / markers / lockfile / title / bare main / light worker
  — a stock-exe AutoClaw2 clone stays `UNCLASSIFIABLE externally`, never
  guessed) + the OS commit/RAM header. The classifier rules (EC-K01
  bare-exe mains, copy-exe-first, queue-based subtree marker walk, lockfile
  probes, title maps) live in ONE shared lib now,
  `tools/suite_status_lib.ps1` (`Get-GhostSuiteInstanceState`, injectable
  process snapshots for tests) — the six live-verified per-suite inline
  copies are deliberately untouched for now (dedup recorded as TA-2).
- **Headless light-worker visibility (the PID-marker contract)** — every
  light-worker launcher (ZCode `launch_zcode_cli_light.ps1`,
  `launch_opencode_cli_light.ps1`, `launch_cline_cli_light.ps1`, the new
  claude-code worker, and the Linux `launch_zcode_cli_light.sh` twin) now
  writes `<clone-home>\.ghost-light-worker.json` (launcher pid + mode,
  key names only) for the whole run and removes it on exit
  (`src/windows/ghost_light_marker.ps1` = the one shared copy; readers
  validate pid liveness + a PowerShell/pwsh process-name sanity check, so a
  hard-killed worker reads as stale, never as running). Until now headless
  workers were invisible to every status surface (no window, no AUMID, no
  lockfile).
- **Terminal Agents submenu (main menu [7])** — GHOST.bat + menu.json +
  parity tests: locals [1]-[4] = claude-code worker (gid 127, detached),
  c1 login (gid 128, detached), Primary identity reset (gid 129,
  confirm-run), suite instance status (gid 130). Ceiling raised 125→130 per
  the raise-when-landing rule; the retired v1 gids 37-40+63 stay
  reserved-dead.

### Changed
- `tests/ghost_hub_menu.Tests.ps1` (seven sections incl. "Terminal Agents"
  last, gid ceiling 130) + `tests/docs_launcher_parity.Tests.ps1` (seven
  submenu ceilings; every new row cited in docs/cli.md). docs/cli.md gains
  the "Which instance is running? (Maintenance [6])" guide (the honest
  signal vocabulary + the deep per-suite tools) and the "Terminal Agents"
  section; README gains the claude-code/status rows + the light-worker
  marker; docs/T3_LOCAL_SUPPORT.md fixes the stale Cline row (the CLI
  worker predates it) and notes the GHOST claude-code pilot; TASK_BACKLOG
  §5 gains TA-1/TA-2/TA-3.

## [1.6.0] - 2026-11-20

### Added
- **Docs re-baseline + docs↔launcher parity test (2026-11-20)** — issue #2
  item 3 closed: `tests/docs_launcher_parity.Tests.ps1` pins docs/cli.md to
  the launcher (GHOST.bat is the source of truth): every rendered submenu row
  position must be cited in the cheat sheet (a single `[N]` or a covering
  `[N]-[M]` range), the intro's six submenu ceilings must match the launcher
  exactly, and the wiring the citations hang off is pinned too — every
  `:Opt` row must resolve through its submenu resolver to a gid the
  `:DispatchOne` table actually dispatches with no dangling resolver case,
  and menu.json must render the same rows in the same order as every `.bat`
  submenu. The audit it replaces found 85 uncited row positions and 4 stale
  ranges across the 2026-11-14..17 renumber waves. This release re-baselines
  every user-facing doc to the current launcher state: docs/cli.md (the
  header ceilings now [1]-[33] / [1]-[25] / [1]-[23] / [1]-[27]; the three
  pre-renumber identity-reset headings fixed; ~20 rows newly documented —
  the per-suite sync / taskbar-watcher / pressure / dry-run rows, ZCode
  [25]/[26]/[29]/[32]/[33], Maintenance [1], and the ghost.sh clone layer
  options 10-13), README (the MCP central registry, the blanket -DryRun
  parity statement, the macOS wave + Linux clone layer in the repo layout,
  the five-job CI description, the current AutoClaw2 row map),
  docs/getting-started (a Maintenance-rows section, the ZCode
  [25]/[29]/[31]-[33] utility rows, the Linux clone layer),
  docs/README (the 8 tracked docs missing from the index), docs/architecture
  (the desktop hub, the MCP registry layer, the suite sync/watch/pressure/
  exe-identity tools, the v9/v4 engine notes) and the AGENTS.md
  pre-renumber row citations.
- **Windows resetter dry-run parity COMPLETE (2026-11-20)** — issue #2's
  "what-if/dry-run mode for all reset scripts" item closed: the five
  classic resetters gained the W1-9-style report-only planner
  (`reset_cursor.ps1`, `reset_trae.ps1`, `reset_devin.ps1`,
  `reset_minimax_opencode.ps1`, `reset_qoder.ps1`; `reset_zcode`,
  `reset_qoderwork` and the three suite resetters already had it — every
  Windows resetter now plans). Each planner prints the real step list
  with resolved store paths + presence (devin's is multi-root aware: the
  Devin + Windsurf `%APPDATA%` detection mirrors the main path), the
  would-kill process set (read-only probe, no kill), the core-availability
  note, and the preservation policy — then exits 0 BEFORE self-elevation
  (a report-only run never triggers UAC) and before any kill/write: no
  python invocation, no backup dir, no audit/restore/marker file. The
  hand-maintained plan lists are cross-checked against the real
  `--- [N/M]` step headings by `tests/reset_dryrun.Tests.ps1` (20 tests:
  per-app planner-before-elevation, planner purity, drift tripwire, and a
  functional zero-write probe under redirected
  APPDATA/LOCALAPPDATA/USERPROFILE). Not-installed targets get an honest
  "the real run would abort here" + exit 0. CLI-only (the qoderwork
  precedent — no new menu rows/gids). docs/cli.md gains the -DryRun lines.
- **CS-8 real-data validation (2026-11-20)** — the OpenCode chat sync's
  inventory + zero-write dry-run plan ran against the REAL stores (the
  58-session / 2772-message Primary db + clone c1's 19 sessions):
  58 missing sessions planned with correct family ordering (the 4
  subagent sessions sort after their parent), 2772 messages, 58
  instruction_state rows, 4 of 9 project rows would be copied verbatim,
  Arabic/Unicode titles and empty titles handled — zero fixes needed, the
  fixture-built contract held at scale. Evidence recorded in
  docs/TASK_BACKLOG.md (CS-8 row); live import + UI display acceptance
  remains user-supervised.
- **OpenCode cross-instance chat sync (2026-11-20)** — the deferred
  chat-sync discovery spike resolved: the store contract was MINED from
  the live dbs (sessions live IN `opencode.db` — `session_v2` →
  `project` FK, the whole message payload in `session_message.data`
  JSON, `session_part`/`blob`/`blob_ref` declared but empty in the
  observed schema; project ids STABLE per worktree path across
  instances; auth OUTSIDE the db — `account`/`credential`/
  `control_account` were 0 rows and are never read). **Core**:
  `src/python/ghost/opencode.py` (`oc-chat-inventory` / `oc-chat-import`
  / `oc-chat-revert` — same-id PK idempotence (a reverted import is
  plannable again), ancestor+descendant family expansion, project row
  reuse-by-path or verbatim copy, one transaction with FK ON + WAL-safe
  sqlite3 backup + verify-after recount + sampled byte-compare, schema-
  mismatch refusal on drift, `chat-sync-manifest.json` sidecar, the
  "[import] " title tag). **Orchestrator**: `tools/sync_opencode_chats.ps1`
  (default = diff report; `-SessionIds`/`-AllMissing` plan, `-Apply`,
  `-DryRun`, `-Revert -ImportId`; the CS-1 lockfile probe skips a
  RUNNING clone; a db-less clone is skipped; source opened read-only;
  audit `chat-sync-audit.jsonl` carries ids + counts only — never
  message bodies). **Wiring**: OpenCode [26] inventory diff (gid 124) +
  [27] guarded import (gid 125) — the gid ceiling rose 123→125 (the
  retired AutoClaw v1 gids 37-40+63 stay reserved-dead per the hub-menu
  test). Tests: `tests/python/test_ghost_opencode.py` (15, incl. CLI
  e2e) + `tests/opencode_chat_sync.Tests.ps1` (15 static contract) +
  the orchestrator's %TEMP% fixture matrix (diff/plan/apply/
  idempotence/revert). LIVE acceptance = user-supervised (CS-8): import
  into a closed clone and confirm its UI lists the sessions after the
  next launch.
- **Cline chat-sync verdict (2026-11-20, CS-9 — DEFERRED-BY-EVIDENCE)**
  — the other deferred spike closed with a mined store map: chat
  history = `data/sessions/<id>/*.json` files plus a `sessions.db` that
  is a RUNTIME PROCESS REGISTRY (not a history store), `session-search.db`
  FTS + agenda/teams side dbs; data volume ~NIL (one session across
  c1..c3); the desktop UI's task-history source is unverified
  (snappy-compressed WebView2 LevelDB defeats a literal strings probe);
  checkpoints live in workspace git refs and do not port. Reopen
  triggers recorded in docs/TASK_BACKLOG.md + docs/CLINE_CLONES_SPEC.md
  §7 — the store map is closed, do not re-derive it.
- **macOS ZCode reset (2026-11-19)** — the SEVENTH and last macOS resetter;
  the wave is COMPLETE (issue #36 — every slug now has a macOS resetter).
  **`src/macos/reset_zcode.sh`** (v0.1): the Linux `reset_zcode.sh` v0.2
  map VERBATIM — no invented steps, hence NO machineid-file step
  (platform.py has no zcode machineid_file row, unlike cursor/qoder; the
  Electron identity rides storage.json/state.vscdb). 6 steps: the Electron
  identity stores (storage.json flat telemetry keys + serviceMachineId +
  state.vscdb ItemTable upserts via the shared `reset_electron_stores`),
  `~/.zcode/v2/telemetry-state.json` deviceMid (core json-set + verify),
  the `~/.zcode/v2/credentials.json` OAuth clear (zcodejwttoken exact +
  every `oauth:`-prefixed key), `~/.zcode/v2/setting.json`
  webRemoteControlExternalRelayDevice.deviceSid (dotted json-set + verify),
  the `~/Library` sweep (Caches/Logs/ZCode delete_store + `com.zhipuai*`
  Preferences + `*[Zz][Cc]ode*` savedState/HTTPStorages nullglob globs —
  DERIVED, the bundle id is unverified on a real Mac; NOTE the `[Zz][Cc]ode`
  shape: `*[Zz]ode` would MISS "ZCode" — smoke-caught), and the final probe
  (storage.json + telemetry-state + setting.json re-verified). PRESERVATION
  (matches Windows/Linux): the shared CLI session db
  (`~/.zcode/cli/db/db.sqlite`) + `cli/config.json` are NEVER touched
  (loudly audited); no clone mode (the Linux `--instance` layout is a
  Linux-launcher concept). Smoke-tested end-to-end on the dev host against
  a seeded fake home: Pass 6 / Fail 0 + checker ALL PASS (22 assertions incl.
  the FLAT-key shape the macOS Electron storage.json actually holds — the
  same shape the #95 flat-fallback fix serves), idempotent re-run exit 0
  (the Library deletions skip loudly), abort path exits 1 before any
  mutation. Live macOS acceptance = user-supervised.
- **macOS QoderWork + MiniMax resets (2026-11-19)** — the fifth and sixth
  macOS resetters (issue #36 follow-up; Qoder + Cursor + Trae +
  Devin/Windsurf shipped first), one PR, both DERIVED-flagged and
  absence-tolerant. **`src/macos/reset_qoderwork.sh`** (v0.1, 16 steps):
  the LIVE-VERIFIED Windows `reset_qoderwork.ps1` v0.2 map ported onto the
  macOS column — machineId files probed in THREE spellings (Windows
  `machine-id` vs Linux `machineid` vs Electron camelCase; the macOS
  spelling is unverified so whichever exists rotates), the Electron 5-key
  telemetry stores, `~/.qoderwork/installation_id`, the `.status.json`
  logged-out patch (version/schema_version/product preserved, fresh UTC
  `snapshot_at`, writer=main), `external-commands/registry.json`
  commands=[], the cache/log sweeps, `rum-electron-store` (ARMS
  `_arms_uid`), the Local State delete, the `Partitions/main` salt +
  network stores + Local/Session Storage + Shared Dictionary, the cache
  trees, SharedStorage + dns-cache, `auth.dat`/`auth-v2.dat`, and the
  signature `data/agents.db` purge-tables scrub with the EXACT Windows
  whitelist (15 tables + 12 app_settings keys; chats/sub_chats/messages/
  projects NEVER in the list; the `proxy` setting survives; backup-first
  with `--sqlite-wal`; schema-missing tables tolerated per the core WARN
  contract — smoke-proven with 2 of the 15 tables deliberately absent) and
  `data/dynamic-text/qoder-work.json` PRESERVED (UI strings).
  **`src/macos/reset_minimax_opencode.sh`** (v0.1, 13 steps): the Linux
  v0.2 MiniMax-only scope + the MiniMax-side Windows v1.4 steps —
  machineId files in three spellings, the Electron telemetry stores, the
  mcode-public auth deletions (auth.json + auth-state.json + the legacy
  root auth-state; absent IS the fresh-install state — `{}` there throws
  Invalid OAuth state and blocks the login page), the
  `v2/session-handoff/device-id` rotation, `local-runtime.auth.json`
  wiped to `{}`, `minimax-agent-config.json` user/sharedUser removal
  (config kept), `remote-control/state.json` desktop_device_id rotation,
  `.updaterId`, the MiniMax Chromium sweeps (15-file network list +
  DIPS*/SharedStorage* prefix probes + cache/web-storage trees + Crashpad
  + Local State os_crypt pointer + uninstall_metrics + Preferences salt),
  the mavis-browser Local Storage, and the misc run-state trees/files.
  The OpenCode-desktop Electron steps do NOT port (no macOS map rows for
  `ai.opencode.desktop`; the `opencode` alias resolves to opencode-cli)
  — the CLI XDG auth is NEVER touched (loudly audited), and sessions/ +
  sqlite.db + credentials/mavis/telegram.json + .mavis + system-ca-certs
  are preserved. A smoke-caught port bug added the derivation-fallback
  contract: rows that exist only in the linux/macos platform columns
  (`mcode_public`, `session_handoff_device_id`) are derived from the
  mapped roots with the SAME relative structure when the resolved map
  lacks them (loud PROVENANCE warn, never silent) — required on any host
  whose own column predates those rows. Both smoke-tested end-to-end on
  the dev host against one seeded fake home: QoderWork Pass 16 / Fail 0 +
  checker ALL PASS (82 assertions incl. the chat-table row counts + the
  schema-missing tolerance), MiniMax Pass 13 / Fail 0 + checker ALL PASS
  (77 assertions incl. the XDG byte-identical preservation); idempotent
  re-runs exit 0, abort paths exit 1. Live macOS acceptance =
  user-supervised.
- **macOS Devin/Windsurf reset (2026-11-19)** — the fourth macOS resetter
  (issue #36 follow-up; Qoder + Cursor + Trae shipped first).
  **`src/macos/reset_devin.sh`** (v0.1): 17 steps porting the
  LIVE-VERIFIED Windows `reset_devin.ps1` v0.4 + Linux `reset_devin.sh`
  v0.3 step maps onto the macOS platform.py column (config =
  `~/Library/Application Support/Windsurf` per the Linux precedent),
  all DERIVED-flagged and absence-tolerant — machineId files in BOTH
  spellings, the Electron 5-key telemetry semantics via the shared
  `reset_electron_stores`, the state.vscdb auth-secret DELETE with the
  EXACT Windows v0.4 ESCAPE'd windsurf/devin LIKE patterns (5 exact keys
  + 5 patterns, escape = backslash; smoke-verified with a literal-underscore
  decoy that must NOT match), the stale `state.vscdb.backup`, the
  Preferences salt + Local State os_crypt pointer + the username
  replace-text scrub on both (pinned-user smoke assertion), the Network
  transport + DIPS + SharedStorage + Trust Tokens sweeps, the EXTENDED
  rebrand-era cache sweep (CachedData/CachedProfilesData/
  CachedExtensionVSIXs/CachedConfigurations/DawnGraphiteCache/
  DawnWebGPUCache/Shared Dictionary — Windows-verified live 2026-09-21),
  Crashpad + logs, workspaceStorage upserts with sidecars preserved,
  `cli/installation_id` + `~/.windsurf/installation_id` (distinct fresh
  lowercase GUIDs), `credentials.toml` delete, `devin.org_id` blanking
  (skip_if_empty), the shared `~/.codeium/config.json` device_id rotation
  (+ api_key blank; the Linux portal/inference URL writes deliberately
  DROPPED — they would overwrite live user endpoints), the argv.json
  crash-reporter-id patch in BOTH `~/.windsurf` and `~/.devin` + the
  updater-cache trees in Application Support + Caches. **Preservation
  policy**: Local Storage, Backups, WebStorage, IndexedDB, and the
  workspaceStorage files are NEVER touched; a Devin-named Application
  Support sibling is deliberately NOT probed (it cannot be told apart
  from the devin CLI home on a case-insensitive volume — live macOS
  acceptance resolves this). Smoke-tested end-to-end on the dev host
  against a seeded fake home: Pass 17 / Fail 0 first try, checker ALL
  PASS (88 assertions), idempotent re-run all-skips, abort path exits 1.
  Live macOS acceptance = user-supervised.
- **macOS Trae reset (2026-11-19)** — the third macOS resetter (issue #36
  follow-up; Qoder + Cursor shipped first). **`src/macos/reset_trae.sh`**
  (v0.1): 15 steps on the Windows `reset_trae.ps1` v0.3 + Linux
  `reset_trae.sh` v0.3 step maps, all DERIVED-flagged and
  absence-tolerant — machineId files in BOTH spellings, Electron stores
  via the shared `reset_electron_stores`, the `iCubeAuthInfo://`
  top-level-prefix removal from storage.json (json-remove prefixes mode;
  the prefixed keys embed full URLs so dotted-path walking cannot address
  them), the `has_device_id_updated_to_aha` = STRING `"false"` flag in
  BOTH storage.json and state.vscdb (the Windows payload semantics; a
  JSON string keeps the verify-after comparison deterministic), the aha
  tree delete, the `ModularData/ckg_server/local_env.json` 19-digit
  device_id rotation (the CSPRNG twin: python3 `secrets.randbelow(9 *
  10**18) + 10**18`, first digit non-zero) + whole-`host_map` removal
  (the Linux v0.3 decision vs Windows' `host_map.default=""`), the
  `env_codekg.db` delete, the `ModularData/ai-agent` IDENTITY-ROWS-ONLY
  scrub (core `scrub-rows` with its Trae defaults — key NAMES only,
  values never inspected, chat rows survive; tree backed up first, every
  `*.db` scrubbed with a per-DB zero-survivor gate), the Preferences
  `device_id_salt` + Local State os_crypt pointer, the Network transport +
  DIPS + SharedStorage + Trust Tokens sweeps, the webview/cache trees
  (incl. `Partitions/trae-webview`, `WebStorage`, `Shared Dictionary`),
  Crashpad + logs, and the workspaceStorage `serviceMachineId` upserts.
  **Preservation policy**: Local Storage, the Backups tree, every
  workspaceStorage file, and all ai-agent chat rows are NEVER touched
  (loudly audited). Smoke-tested end-to-end on the dev host against a
  seeded fake home: Pass 15 / Fail 0 first try, checker ALL PASS (53
  assertions — identity cross-consistency, the fresh 19-digit device_id
  format, the iCube prefix-anchoring decoy kept, chat rows intact, every
  deletion and preservation), idempotent re-run all-skips, not-installed
  abort exits 1 before any mutation. Live macOS acceptance remains
  user-supervised.

- **Gmail MCP server in the registry (2026-11-18)** — `master-mcp.json`
  gains `gmail` [only:zcode]: the local Go server
  (`rajesh-chettiar-insightgen/gmail-mcp-server`, built at
  `Tools\gmail-mcp\gmail-mcp-server.exe`) over stdio with
  `${GMAIL_CLIENT_ID}`/`${GMAIL_CLIENT_SECRET}`/`${OPENAI_API_KEY}`
  env-guard placeholders (scopes `gmail.readonly` + `gmail.compose`;
  drafts-only — no send/delete; OAuth token cached at
  `%APPDATA%\Roaming\auto-gmail\token.json`; `OPENAI_API_KEY` powers the
  optional style-guide feature only). The official remote
  `gmailmcp.googleapis.com` was evaluated and REJECTED for ZCode:
  ZCode's built-in MCP OAuth binds its loopback callback to an
  ephemeral port (Google requires exact-match registered Web-client
  redirect URIs) and sends no offline-access/refresh params.

- **macOS Cursor reset (2026-11-18)** — the second macOS resetter (issue #36
  follow-up; Qoder shipped first). **`src/macos/reset_cursor.sh`** (v0.1):
  13 steps on the Windows `reset_cursor.ps1` v0.3 + live-verified Linux
  `reset_cursor.sh` v0.2 step maps, all DERIVED-flagged and
  absence-tolerant — machineId files in BOTH spellings (Linux writes
  camelCase `machineId`, Windows lowercase `machineid`; the macOS spelling
  is unverified so whichever file exists is rotated — on the default
  case-insensitive APFS they are one file and the second rotate is an
  honest same-value rewrite), Electron stores via the shared
  `reset_electron_stores`, the state.vscdb auth secrets via core
  `delete-secrets` with NO config (the Cursor defaults:
  `secret://aicoding.auth.%`, `secret://blackbox.%`, `gituser` — ItemTable
  only, per-key audit + zero-survivor verdict), the Preferences
  `device_id_salt`, the Local State `os_crypt.encrypted_key` pointer
  (`json-remove`; the Keychain "Chromium Safe Storage" entry itself stays
  a manual step), the Network transport + DIPS + SharedStorage + Trust
  Tokens sweeps, the sentry tree, the cache trees, Crashpad + logs, the
  workspaceStorage `serviceMachineId` upserts, and the stale `.backup`
  sidecar purge. **Preservation policy is Cursor's, not Qoder's**: Local
  Storage, the Backups tree, workspaceStorage files, and the chat-bearing
  `cursorDiskKV` table are NEVER touched (loudly audited). Smoke-tested
  end-to-end on the dev host against a seeded fake home: Pass 13 / Fail 0,
  checker ALL PASS (identity cross-consistency, zero secret survivors,
  every deletion, AND every preservation), idempotent re-run all-skips,
  not-installed abort exits 1 before any mutation. One `set -u` bug caught
  by the smoke (`local summary` without an initializer is an unbound
  variable on every bash). Live macOS acceptance remains user-supervised.

- **macOS platform maps for every slug (2026-11-18)** — the follow-up to the
  macOS Qoder wave (issue #36): `ghost/platform.py` now carries a `macos`
  column for ALL slugs (cursor, devin, trae, qoderwork, zcode, minimax,
  opencode-cli join qoder), so `ghost_cli.py paths <slug>` on a darwin host
  returns honest derived paths for every app instead of a loud "unmapped"
  error. Conventions: Electron userData under
  `~/Library/Application Support/<App>` (devin keeps the Windsurf product
  name, matching its linux column), platform-agnostic CLI dot-dirs per the
  Linux wave, and opencode's XDG rows keep their unset-env defaults
  (`~/.config`, `~/.local/share`) rather than `~/Library`. Every macOS row
  is `verified: False` (no live Mac has confirmed any of them — ground
  truth #5); the platform-integrity test now REQUIRES all three columns per
  slug, pins every macOS row unverified + home-resolved, and asserts darwin
  resolves every slug (mock-based, CI-OS-independent). Resetter scope is
  unchanged: only `src/macos/reset_qoder.sh` ships; a future per-app
  macOS resetter flips its own rows' provenance explicitly.

- **CI Linux helper-contract lane (2026-11-17)** — a new `linux-helpers`
  ubuntu job that closes the bug class `bash -n` + shellcheck cannot see:
  a MISSING shared function (the `b64_json` latent bug — a helper consumed
  by the shared `reset_electron_stores` but defined only in cursor/trae —
  killed four reset scripts at step 1 under `set -e` and passed every
  static gate). The job sources `id_reset_common.sh` and (1) asserts a
  29-name contract list of shared helpers is DEFINED (new shared helpers
  must be added to the list — the workflow comment says so), (2)
  fixture-exercises the core helpers end-to-end: `b64_json_stdin` round
  trip, `b64_kv_payload`→`json-set`, `b64_remove_payload`→`json-remove`,
  the `core_json_remove` wrapper + backup dir, `rotate_text_file` +
  verify-after + audit line, and `verify_json_keys` positive AND negative
  honesty. Runs with a functional `has_python3` probe (the PR-#97 fix) so
  a stub interpreter can never pass the lane.

- **ZCode Linux MCP definitions sync (2026-11-17)** — the Linux twin of the
  Windows `sync_zcode_assets.ps1` MCP area: `src/linux/sync_zcode_assets.sh`
  v0.1 (ghost.sh option 13) syncs the Primary's `~/.zcode/cli/config.json`
  `mcp.servers` definitions (READ-ONLY) onto each clone's
  `<CloneHome>/.zcode/cli/config.json` — Primary wins, clone-local `enabled`
  survives, clone-only servers kept. `--instance Second..Sixth|All` +
  `--dry-run` (writes nothing, not even audit); config-less clone = loud
  SKIP; no running-instance guard (MCP is the Windows-verified safe area —
  config re-read per app-server spawn); backup `mcp-sync-backups/` +
  names-only `asset-sync-audit.jsonl`. **MCP-ONLY scope by design**: the
  skills/.agents/plugin-cache areas are Windows-specific mechanics
  (junctions/robocopy) whose Linux ports need LC-1 live-layout evidence
  first. Rides the NEW core verb `ghost_cli.py json-merge-defs`
  (`src/python/ghost/json_merge.py`) — the Primary→clone merge invariant
  ported from `zcode_mcp_merge.ps1`, generic over `--base-path`/
  `--preserve-keys` so other suites' Linux syncs reuse it
  (`tests/python/test_ghost_json_merge.py`, 18: the Windows invariant cases
  + file-level backup/verify/dry-run contracts). Functional smoke ran the
  fixture HOME through dry-run/real/idempotent/skip paths (the
  missing-function class is invisible to `bash -n`/shellcheck).
  **LATENT FIX**: `id_reset_common.sh` `has_python3()` is now a FUNCTIONAL
  probe — the bare `command -v` passed on Windows dev hosts where `python3`
  is the Microsoft Store App-Execution alias stub, silently losing audit
  lines there; the probe executes a real statement so the stub case fails
  LOUD at `resolve_ghost_cli`. Frozen-layout tripwire: the sync's
  `CLONE_HOME_NAME` map is pinned to `launch_zcode_clone.sh`'s by
  `tests/linux_clone_layer.Tests.ps1` (27).

- **Cline light headless worker (2026-11-17)** — the Cline suite gains the
  ZCode/OpenCode light-worker capability: `src\windows\launch_cline_cli_light.ps1`
  (Cline [22] / gid 122; [23] / gid 123 = the one-time CLI account login row)
  runs the desktop install's OWN standalone CLI (`cline-cli.exe`, a Bun SEA,
  v3.0.74 — the same engine the desktop app spawns as its hub/sidecar
  daemons) on the clone's own `CLINE_DIR` state with the clone's frozen
  `CLINE_HUB_PORT`/`CLINE_SIDECAR_PORT` (port-table drift tripwired to
  `launch_cline_clone.ps1` by `tests/cline_cli_light.Tests.ps1`, 18).
  Modes: interactive CLI session (default; the CLI's own act-mode +
  auto-approval defaults are loud in the banner), `-Prompt` one-shot
  (`-Json` = `--json` headless output, `-Timeout`, `-Model`,
  `-NoAutoApprove` = `--auto-approve false`, `-Yolo` = the CLI's limited
  `-y` set), `-Auth` = the interactive `auth` flow (exit-code gated — no
  file-verified persistence check exists yet). Honest limits in the header:
  a held desktop hub lock WARNs (never blocks — shared-home semantics; the
  CLI is expected to attach to the running hub, UNVERIFIED) and login
  persistence location is UNVERIFIED (the desktop web login may not cover
  the CLI). Phase-0 evidence recorded in the header: `--help` captured
  2026-11-17 (positional prompt = one-shot; `--json`/piped stdin =
  headless). GHOST.bat dispatch header corrected to the real range
  (1-123; **5 unused** — the carried "63 unused" figure was arithmetically
  wrong; the integrity test only pins the upper bound). Live acceptance
  (hub attach while the desktop clone runs, CLI login persistence) recorded
  in TASK_BACKLOG.
- **macOS Qoder reset — the repo's first macOS platform (issue #36, 2026-11-17)** —
  **`src/macos/reset_qoder.sh`** (v0.1): a full-attempt 9-step Qoder resetter
  for macOS built on the shared lib + the OS-neutral Python core — Electron
  stores (storage.json + state.vscdb via `reset_electron_stores`), the exact
  Windows [3b] secret purge (`purge-keys` with per-key count audits), the
  Preferences `device_id_salt` (`salt-rotate`), the machineid files
  (`machineid-file`), the `~/.qoder` installation_id / .auth/machine_id
  rotations (`rotate_text_file`) + credential-transaction sentinel + argv.json
  crash-reporter-id (`patch-argv`), the workspaceStorage serviceMachineId
  upserts, the `~/Library` sweep (Caches/Logs/Preferences/Saved Application
  State/HTTPStorages, bundle-id globs), the webview partitions + the Chromium
  network/cache stores + SharedClientCache inside the userData, and the
  `.qoder` tmp/telemetry + logs run-state trees (`sweep-tree`). Every path is
  DERIVED (Electron `~/Library/Application Support/Qoder` conventions) and
  ABSENCE-TOLERANT — a store the app never created is a loud audited skip,
  never a guess; the header carries the DERIVED-PATH SCOPE block plus the
  NOT-covered list (Keychain "Chromium Safe Storage", IOPlatformUUID,
  hostname, MAC, and the chat-bearing memories/canvas/knowledges stores).
  **`ghost/platform.py`** gains an opt-in `"macos"` column (qoder rows:
  config/qoder_dir/installation_id/auth_machine_id, all unverified), a live
  `sys.platform` three-way selector, and a LOUD error for a darwin host
  asking for an unmapped slug (never a silent linux fallback); the platform
  integrity test now allows macos as a third column and pins the qoder macOS
  rows + the darwin selector (mock-based, CI-OS-independent). Three shared
  bugs the macOS smoke fixture caught are fixed in
  **`src/linux/id_reset_common.sh`**: `verify_json_keys` now falls back to a
  flat-literal key read when the nested walk misses (Chromium storage.json
  holds LITERAL dotted keys — the nested-only verify would have failed every
  correct storage.json write on Linux too), `emit_restore_script` guards the
  empty-RESTORE_ENTRIES iteration (macOS's stock bash 3.2 treats
  `"${arr[@]}"` under `set -u` as a fatal unbound-variable error), and the
  `ensure_not_running` prompt drops the bash-4-only `${var,,}` lowercase
  (macOS ships bash 3.2). The macOS smoke ran the full 9-step pipeline
  against a seeded fake home on the dev host: Pass 13 / Fail 0, 56-assertion
  post-check ALL PASS (identity cross-consistency, zero secret survivors
  with the chat key preserved, JSONC comment survival, every deletion,
  backups + audit + restore.sh), idempotent re-run all-skips, and the
  not-installed abort path exits 1 before any mutation. CI shell lint and
  README/docs now cover `src/macos/*.sh`. Live macOS acceptance remains
  user-supervised (all rows stay provenance-flagged until then).
- **OpenCode definitions-only Primary→clone config sync (CS-1, 2026-11-16)** —
  the scrub design in `docs\OPENCODE_CONFIG_SYNC_PLAN.md` is implemented
  (D2 = the doc's default, developer-picked: sync provider definitions
  WITHOUT the secret + one loud WARN per clone). **`tools\opencode_config_merge.ps1`**
  — pure merge core mirroring `zcode_mcp_merge.ps1`: the zcode invariant
  (Primary definitions win, clone-local `enabled` survives, clone-only
  entries kept) over the config's `mcp` + `provider` blocks, PLUS the
  secret scrub: apiKey-shaped keys at ANY depth inside a Primary provider
  block (the real shape is `provider.<id>.options.apiKey` — a top-level
  scan would have missed it and the secret would have crossed) are REMOVED
  and reported; a secret the CLONE already has survives; no placeholder is
  ever written; the Primary object is never mutated. Intentionally
  duplicates the zcode helpers (that file ships + is unit-tested; dedup =
  recorded follow-up). **`tools\sync_opencode_config.ps1`** — the child:
  `-Instance cN | -Target All`, `-DryRun`, jsonc-aware config reader
  (registry-precedent comment stripper), lockfile-held clone = RUNNING →
  SKIP + WARN, config-less clone = SKIP (first run anonymous by design),
  backup `config-pre-sync-<ts>.json` into the clone home, verify-after
  re-read + deep-compare, JSONL audit at `<CloneHome>\config-sync-audit.jsonl`
  (paths + key NAMES only — never values), Primary READ-ONLY with a hash
  re-check after every run. **Launcher wiring** — `launch_opencode_clone.ps1`
  gains step `[2b/5]` BEFORE the clone starts: no running-instance race, no
  `-McpOnly` distinction needed, a failed sync warns and NEVER blocks the
  launch. **Tests** — `tests/opencode_config_merge.Tests.ps1` (12): the
  zcode invariant cases ported + the scrub cases (Primary key never
  crosses / clone key survives / `api_key` spelling / mcp env wholesale) +
  JSONC strip + no-BOM round-trip. In-session fixture acceptance ran the
  plan's §5 items 1/3/4/5: dry-run zero-write; the written clone config AND
  the audit JSONL Select-String clean for the Primary's fake key; SKIP
  paths; Primary hash stable; idempotence ("already in sync" on run 2).
  Pester 250/250, parse 0, both new files PSSA-clean. §6 live runs stay
  user-supervised. GHOST.bat/menu wiring deferred to v2 per the plan.
- **OpenCode config sync v2 — resident watcher + menu wiring (CS-1 v2,
  2026-11-17)** — the v2 deferrals closed. **`tools\watch_opencode_config_sync.ps1`**
  (new): resident watcher stat-guarding the Primary
  `~\.config\opencode\opencode.jsonc` (mtime+size, JSONC parse-guard through
  the merge core's `ConvertFrom-JsoncText` — a torn config skips the pass,
  never syncs) and on every change spawning `sync_opencode_config.ps1
  -Target All` as a console-less child (600s kill cap, the ZCode
  MCP-watcher mechanics); the watcher writes nothing itself; first pass
  converges drift, deep re-verify every 60 passes, log at
  `%LOCALAPPDATA%\watch-opencode-config-sync\config-sync.log`, single
  instance via mutex `OpencodeConfigSyncWatcher` + startup process scan;
  `-RunOnce/-DryRun/-IntervalSeconds/-InstallAutostart/-RemoveAutostart`;
  **NO `-ApplyLive` by design** (a running OpenCode clone's config re-read
  timing is unverified — recorded as a TASK_BACKLOG item). **Launcher** —
  `launch_opencode_clone.ps1` gains step `[2c/5]`: ensure the watcher is
  running hidden + install the Startup `.lnk` once (mutex probe, best-effort,
  never blocks the launch — the ZCode-2e pattern). **Menu wiring** —
  GHOST.bat OpenCode submenu gains the Config Sync section ([21] one-shot
  sync = gid 110, [22] resident watcher = gid 111) with matching
  `src\desktop\menu.json` rows; dispatch range header → 1-111; hub-test gid
  ceiling → 111. **Tests** — `tests\watch_opencode_config_sync.Tests.ps1`
  (19): hygiene, param surface (incl. the deliberately-absent
  `-ApplyLive`/`-Target`), wiring contract (child, mutex, log, .lnk,
  DryRun passthrough, JSONC guard, 60-pass deep verify) + launcher 2c +
  gid 110/111 wiring assertions. Pester hub 17 + integrity 11 + watcher 19
  green.
- **Cline MCP settings sync (2026-11-17)** — the Cline suite's missing sync
  capability (the audit gap: Cline had NO MCP story at all). Store verified
  on the dev host: `<profile>\data\settings\cline_mcp_settings.json`
  (container `mcpServers`, Claude-Desktop format) is AUTH-FREE — the
  Primary's file is exactly `{"mcpServers": {}}`, login lives in
  secrets.json/providers.json. **`tools\cline_mcp_merge.ps1`** — pure merge
  core, the zcode invariant adapted to Cline's per-server `disabled` flag:
  Primary definitions win, the clone's LOCAL disabled state survives, a new
  server carries the Primary's disabled value (absent on both = enabled),
  clone-only servers never removed, Primary never mutated.
  **`tools\sync_cline_mcp.ps1`** — the child: `-Instance cN | -Target All`,
  `-DryRun`, `-Quiet` (launcher path), fixture overrides; hub-lock-held
  clone = RUNNING → SKIP + WARN; missing store = CREATE (deliberate
  deviation from the OpenCode config-less SKIP — this store is auth-free
  and the app only creates it on first MCP-panel use, so waiting would
  mean definitions never reach a fresh clone); backup
  `cline_mcp_settings-pre-sync-<ts>.json` + verify-after re-read +
  deep-compare + JSONL audit `<CloneHome>\mcp-sync-audit.jsonl` (server
  NAMES only); Primary READ-ONLY with a hash re-check. **Launcher** —
  `launch_cline_clone.ps1` gains the `[2b]` pre-launch step (`-Quiet`
  child, `-SkipMcpSync` escape hatch, failed sync warns and NEVER blocks;
  runs before the single-instance neutralize) + an `mcp settings:` line in
  `-Status`. **Menu wiring** — GHOST.bat Cline submenu gains the Config
  Sync section ([18] sync = gid 112, [19] dry-run plan = gid 113) with
  matching `menu.json` rows; dispatch range header → 1-113; hub-test gid
  ceiling → 113. **Tests** — `tests\cline_mcp_sync.Tests.ps1` (23): the
  invariant cases + FUNCTIONAL %TEMP% fixture runs of the child (fresh
  clone create+apply+audit, disabled survival + clone-only keep + backup,
  dry-run zero-write, idempotence, RUNNING skip via a held lock handle,
  missing-home skip, unparseable-Primary fail-loud) + launcher/gid wiring.
  Also AGENTS.md: the stale "NO reset script in this suite" bullet
  rewritten (reset_cline.ps1 shipped 2026-11-14). Pester cline-sync 23
  green.
- **Cline window-level taskbar identity (CS-2 IMPLEMENTED, 2026-11-17)** —
  the 2026-10-24 DEGRADED decision closed with the developer go. Tauri has
  no patchable surface, so it is the plan's launcher-side stamp
  (`docs\CLINE_WINDOW_IDENTITY_PLAN.md` §3, verbatim): `launch_cline_clone.ps1`
  stamps `bot.cline.app.cN` (EQUAL to the shortcut AUMID so the running
  button resolves the clone's colored icon) onto the launched process's
  main-window property store — the proven ZCode step-4 interop block,
  `PropVariantClear` imported from **ole32** (oleaut32 dropped it in Win10
  19041.7548, ground truth #6) — plus the distinct "Cline `<Color>` vN"
  title from the exe VERSIONINFO (the pin-collision guard). Re-stamps on
  main-window handle change inside the post-launch poll (splash-swap
  tolerant); verify-after read-back; any mismatch = loud WARN and the
  launch STANDS (identity is cosmetic, acceptance 3). `-Status` reports
  the live window AUMID. NO resident watcher (plan §3.5). **`tools\probe_cline_window.ps1`**
  (new, read-only, off-menu): the §4 Phase-0 probes (a)-(c) as a runnable
  tool — per-window anatomy (class/title/hwnd), live store AUMID, WebView2
  child census, and the `SetCurrentProcessExplicitAppUserModelID` exe scan;
  probe (d) = re-run after a clone restart. Phase-0 live probes + the
  acceptance run are user-supervised (no Cline window was open when
  shipped). Pester: `tests\cline_window_stamp.Tests.ps1` (14).
- **Generic suite taskbar-identity watcher (2026-11-17)** — the ZCode
  resident watcher (`watch_zcode_taskbar.ps1`) mechanics generalized to the
  AutoClaw2 and OpenCode suites: **`tools\watch_suite_taskbar.ps1`** with a
  MANDATORY `-Suite autoclaw2|opencode` (Cline excluded by its plan — the
  launcher's one-time CS-2 stamp covers it). Per-suite maps: AUMID base
  (`com.zhipuai.autoclaw2` / `ai.opencode.desktop`), mutex
  (`Autoclaw2TaskbarIdentityWatcher` / `OpencodeTaskbarIdentityWatcher`),
  log (`%LOCALAPPDATA%\watch-<suite>-taskbar\taskbar.log`), Startup `.lnk`
  name, and the installer repair script. Classification = per-color exe
  copy on the root command line FIRST (deterministic mid-splash), then argv
  markers (opencode's `--opencode-clone-home` ONLY — autoclaw2 passes env,
  not argv), then the opencode title map ("OpenCode `<Color>`"). **Honest
  limit documented, not hidden**: a stock-exe AutoClaw2 clone is
  unclassifiable externally (no argv markers, shared "AutoClaw" title) —
  warned once per hwnd and left alone (a clone-AUMID-vs-Primary-verdict
  guard never re-stamps a probable clone to base); such clones keep
  identity via the in-app patch (gid 78) + launcher kick, or gain watcher
  coverage via the per-color exe copies (gid 105). Whole copy family via
  the suite WMI filter (`AutoClaw2%`/`OpenCode%`); .kick toggle + read-back
  verify; primary-lnk hijack guard every ~5 min = clone-AUMID predicate on
  Shell `ExtendedProperty` + the suite installer's `-RepairPrimaryAumid`
  console-less child (120s cap) + re-read verify. Menu wiring: AutoClaw2
  [23] = **gid 114**, OpenCode [23] = **gid 115** (matching `menu.json`
  rows; dispatch header → 1-115; hub-test ceiling → 115). The menu row is
  the only entry point (the suite launchers deliberately do NOT ensure it).
  Pester: `tests\watch_suite_taskbar.Tests.ps1` (17). Live runs =
  user-supervised.
- **Generic suite pressure report (2026-11-17)** — the portable half of the
  ZCode diagnostics generalized: **`tools\diagnose_suite_pressure.ps1`** with
  a MANDATORY `-Suite autoclaw2|cline|opencode` (ZCode keeps its dedicated
  `diagnose_zcode_freeze`/`diagnose_zcode_throttle`). Read-only, three
  sections: [1] instance table with honestly-labeled running signals —
  per-color exe copy = definitive; lockfile probe (opencode
  `<home>\desktop\lockfile`, cline hub lock) = held = running; opencode
  title map; autoclaw2 documented as no-lockfile; a stock-exe clone with no
  signal = **UNCLASSIFIABLE, never guessed**; [2] the live commit/RAM/
  pagefile block that caught the 2026-09-25 renderer-OOM commit-limit
  freeze (>=90% commit = the OOM-territory warning); [3] optional `-Days`
  Electron log scan for `render-process-gone`/`child-process-gone` with
  DERIVED-provenance dirs skipped loudly when absent — client-side
  `.log`/`.txt` extension filter + `-Depth 3` bound (the first draft's
  `-Include` swept a `.sqlite` blob into the scan; fixed and pinned by a
  test). Smoke-tested read-only against all three suites on the dev host
  (real output verified: honest unknowns, live commit numbers, log dirs).
  Menu wiring: AutoClaw2 [24] = **gid 116**, Cline [20] = **gid 117**,
  OpenCode [24] = **gid 118** (dispatch header → 1-118; hub-test ceiling →
  118). Pester: `tests\diagnose_suite_pressure.Tests.ps1` (11).
- **Launcher 2f exe-identity wiring + per-suite dry-run rows (2026-11-17)** —
  the last parity deltas. **Launcher step 2f** ported to all three suites
  (`launch_autoclaw2_clone.ps1` `[2f]`, `launch_cline_clone.ps1` `[2f]`,
  `launch_opencode_clone.ps1` `[2f/5]`): marker fast-check → spawn
  `patch_<app>_exe_identity.ps1 -Target <instance> -InstallDir ...` on drift
  → launch from `<App>-<Color>.exe` with the STOCK-exe fallback + loud
  warning on any failure (never blocks the launch) — the ZCode step-2f
  pattern verbatim-adapted. **The 2026-11-14 "repo-only opt-in" decision is
  REVERSED by the parity build-out plan** (~1.2 GB disk per suite; copies
  lose Authenticode validity — the SmartScreen caveat stays hedged in
  docs). **Dry-run reset plan rows** (the gid-109 pattern): AutoClaw2 [25] =
  **gid 119**, Cline [21] = **gid 120**, OpenCode [25] = **gid 121**
  (`reset_<app>.ps1 -Target All -DryRun`, matching `menu.json` rows;
  dispatch header → 1-121; hub-test ceiling → 121). Pester:
  `tests\suite_launcher_2f.Tests.ps1` (9).
- **Linux resetter depth (2026-11-17)** — the Linux debt's first big
  repayment: the six .sh resets deepened toward their Windows store maps,
  every mutation through the shared Python core with backup + verify-after
  + JSONL audit + restore emission. **`platform.py`** — Linux labels added
  for the new stores (trae machineid_file/local_env, qoder
  installation_id/auth_machine_id, qoderwork agents_db, zcode
  telemetry_state/credentials/setting_json, minimax mcode_public/
  session_handoff_device_id) — ALL DERIVED-flagged until a live Linux host
  verifies (ground truth #5); `test_ghost_platform.py` pins them unverified.
  **reset_zcode v0.2** — ~/.zcode/v2 telemetry-state deviceMid (json-set),
  credentials OAuth clear (json-remove "oauth:" top-level prefix + exact
  zcodejwttoken — the Windows v1.5 shape), setting.json deviceSid (dotted
  json-set); **reset_trae v0.3** — has_device_id_updated_to_aha=false +
  iCubeAuthInfo://* top-level-prefix removal + ckg_server local_env.json
  19-digit device_id rotation + host_map removal; **reset_qoder v0.2** —
  ~/.qoder installation_id + .auth/machine_id 36B-GUID rotations +
  .credential-transaction sentinel delete; **reset_qoderwork v0.2** —
  agents.db purge-tables with the EXACT Windows v0.2 table whitelist + keyed
  app_settings deletions (chats NEVER deleted, "proxy" preserved);
  **reset_minimax_opencode v0.2** — mcode-public auth.json/auth-state.json +
  legacy root auth-state.json deletions ("{}" blocks the login page —
  absent = fresh-install parity) + session-handoff device-id rotation;
  **reset_devin v0.3** — the repo's LAST inline python3 heredocs migrated
  onto core replace-text (username scrub, grep-sweep verify stays) + json-
  patch (Codeium config keyed upsert — unknown keys survive, strictly safer
  than the old whole-file rewrite). **Shared lib** — new helpers
  (b64_json_stdin, b64_kv_payload, b64_remove_payload, core_json_set_kv,
  core_json_remove, rotate_text_file). **LATENT BUG FIXED**:
  reset_electron_stores piped into `b64_json`, which only reset_cursor/
  reset_trae defined locally — the four consumers (zcode/qoder/qoderwork/
  minimax) died at step 1 with "command not found" under set -e (latent
  since 2026-11-14; `bash -n` and shellcheck cannot see a missing
  function); the stdin builder now lives in the shared lib. The roaming-
  equivalent deep stores (RUM, webview partitions, aha dir, SharedStorage)
  stay Windows-only with the unverified-layout caveat printed loudly. All
  new core-verb chains functionally smoke-tested against %TEMP% fixtures
  (json-set/json-remove prefix/json-patch/purge-tables); shell syntax
  `bash -n` clean; unittest 196 OK. Live Linux runs remain user-supervised.
- **ZCode Linux clone layer (PR 8, 2026-11-17)** - the Linux debt's second
  repayment, evidence-first: the vendored ZCode tree PROVES Linux desktop
  builds exist (electron-builder linux targets, executableName "zcode")
  and that ALL FIVE isolation levers are platform-independent app code
  (packages/desktop/src/main/desktopRuntimeEnv.ts + a dedicated
  `ZCODE_HOME` CLI-root override - cleaner on Linux than the Windows HOME
  trick). **`src/linux/launch_zcode_clone.sh`** - per-clone launcher
  (Second..Sixth) on the FROZEN cross-platform layout
  (`~/ZCode<Name>Home/.zcode` + `~/ZCode-<Name>` userData - same names as
  the Windows launcher): first-run seed from ~/.zcode (live-lock excludes,
  the `.zcode-seeding`/`.zcode-seeded` marker gates, Primary-closed gate
  180s) + identity scrub through the Python core with **fail-closed**
  semantics (a clone never runs on Primary identity - the Windows seed
  rule); Linux identity = `ZCODE_INSTANCE_NAME` window title + per-color
  branding (NO property store - taskbar grouping is not a Linux concept);
  `--zcode-bin` pins the binary (DERIVED probe: PATH + /opt + user bins).
  **`src/linux/launch_zcode_cli_light.sh`** - the light headless worker:
  the Windows five-lever set MINUS the desktop-userData levers (headless =
  no Electron), `--app-dir` pins the `resources/glm/zcode.cjs` bundle
  (DERIVED probe), the free-model login recipe printed (the Windows
  verified limits carried over), refuses an unseeded home.
  **`reset_zcode.sh --instance`** - clone reset: the SAME v0.2 steps rooted
  at the clone layout + backup-first `sweep-tree` of the desktop userData
  (config/session); the Primary path stays fail-closed on an absent store.
  **ghost.sh options 10-12** wired. Static Pester:
  `tests\linux_clone_layer.Tests.ps1` (18). Everything DERIVED-flagged;
  **live acceptance = user-supervised on a Linux host** (recorded as
  TASK_BACKLOG **LC-1**).
- **Scaffold/icon LOWs — bug-sweep report 20 walk (BS-10 part 3 +
  DT-4, 2026-11-16)**: of report 20's findings, 5 were genuinely open (3
  MEDIUMs already fixed; one target fixed). `new_clone_suite.ps1`
  **20-L1**: the GHOST.bat wiring now honors the intake's instance count —
  ONE Launch + ONE Reset row/gid pair PER CLONE (the old hardcoded
  `-CloneCount 2` left resolver ids 3+ resolving to UnknownTask forever on
  a larger intake) — resolver ids, `:DispatchOne` rows, submenu rows and
  the range header all scale, keeping the repo-integrity invariant
  "every resolver target has a dispatch case"; `Edit-GhostMenu` gains an
  optional `-BatPath` (fixture-tested against a %TEMP% launcher copy:
  CloneCount 3 → 6 resolver lines → gids 110-115 with per-clone
  `-Instance instN`). Found + fixed WHILE probing: the range-header
  replace (anchor 5) was a silent NO-OP against the real header format
  ("(1-109; 63 unused; ...)") — a generated suite would have shipped a
  stale range and failed `tests/repo-integrity.Tests.ps1`; the replace now
  matches the number only and verifies the edit landed. **20-L2**: the
  reset skeleton's example uses the REAL helper signatures
  (`Backup-FileToTimestampDir -Source/-BackupRoot/-Label`,
  `Set-JsonIdentity -Path/-Updates/-Audit [ref]` — the old example called
  parameters that do not exist). **20-L3**: the shortcuts skeleton
  verify-after re-reads TargetPath + Arguments + WorkingDirectory +
  IconLocation (the old one checked TargetPath only while its [ok] line
  printed an AUMID it never verified). `make_clone_icon.ps1` **20-L4**:
  `-ManualCrop 'x,y,size'` is bounds-checked against the source BEFORE any
  GDI+ work (the C# `crop.Intersect` clamp silently distorted
  out-of-bounds crops; probe: 9999-size crop on a 32px source throws with
  the values). `make_ghost_icon.ps1` **20-L6**: the background classifier's
  hard-tuned constants are named (SAT_MAX / 188..220 band / ≥238 white
  cut), carried into the compile-checked C# and printed verbatim in the
  tile-detection failure message so a future poster re-tune knows exactly
  which dials to move. **DT-4**: a new CHANGELOG entry records the
  2026-10-24 sweep remediation wave for release notes (the sweep folders
  stay gitignored). Pester 238/238, harness PASS, unittest OK, parse 0,
  PSSA per-file baselines identical.
- **2026-10-24 bug-sweep remediation, recorded for release notes (DT-4,
  2026-11-16)**: the sweep itself (`_bug_sweep\`, ~196 findings: 3 CRITICAL /
  24 HIGH / 75 MEDIUM / 94 LOW across 20 reports) is gitignored, so the
  CHANGELOG never recorded its remediation wave. Summary, from the sweep's
  own FIXES_SUMMARY: the 2026-10-24 in-tree wave fixed ~130 findings across
  22 files — executor scopes 02 reset_cursor (11), 03 reset_devin (10),
  07 reset_qoderwork (11/11), 08 reset_minimax (9/9), 13 refresh+sync
  (12/12), 15 patch engines (12/13), 16 tools misc (11/11), 17 update_ghost
  (4/4), 11 launch_autoclaw2 (4/15, rest blocked then); the parent fixed the
  shared `identity_utils.ps1` core (backup uniquify killing the
  same-label-clobber class, UTF-8 reads, guarded writes, `-RedactKeys`,
  `Test-GhostValueEqual`, BOM-less audit, hostname RNG bias), the Python
  core modules, the autoclaw2 installer's CRITICAL base-AUMID constant, the
  `change_device_id.ps1` HIGH `.bak`-key abort class, `ghost.sh` child-fail
  isolation, and `new_clone_suite.ps1`'s 3 MEDIUMs. Five files were blocked
  by workspace write-guard false positives with staged diffs ready — those
  landed later: the launcher/reset_zcode/sqlite_keys trio as PRs #72–#74
  (2026-11-15 hardening wave), reset_autoclaw/launch_autoclaw with the v1.20
  sunset deletion (2026-11-01). The "pending" tail of that summary was
  systematically stale — the 2026-11-15/16 walks (PRs #75–#77, #81, #83)
  closed reports 05/09/12/14/20 against current code with evidence.
- **Shortcut installer hardening — bug-sweep report 14 walk + same-family
  siblings (BS-10, 2026-11-16)**: of report 14's findings, 6 were genuinely
  open in the zcode/autoclaw2 installers (the autoclaw-v1 target is deleted;
  the CRITICAL/HIGH base-AUMID + verify-exit findings already landed in the
  2026-10-24 batch). `install_zcode_second_shortcuts.ps1`: **14-M2** — the
  base AUMID is adopted only when CLEAN (the old first-read adoption took a
  clone-suffixed value, so a FAILED repair left `dev.zcode.app.2.2`-shaped
  AUMIDs stamped onto every clone shortcut); `Get-InstalledZCodeAumid`
  skips suffixed reads and a hard stop refuses to stamp after a failed
  self-heal; **14-L3** — `-RepairPrimaryAumid` + `-Remove` are both
  honored (the old repair block exited before the removal ran); **14-L5**
  — verify-after covers `.Description`; **14-L2** — header "N = 2..6"
  matches the ValidateSet. `install_autoclaw2_clone_shortcuts.ps1`:
  **14-M3** — the exe-icon fallback only fires when the exe really exists
  (absent exe ⇒ IconLocation left unset, contract "never a set-but-absent
  icon path" restored, verify asserts the unset case); **14-L4** —
  `-Remove` re-reads every delete. Same-family fixes in the NEWER
  `install_opencode_clone_shortcuts.ps1` / `install_cline_clone_shortcuts.ps1`
  (not in the report, same defect classes): both installers now carry
  `$script:Failed` + `exit 1` on every verify/remove failure (opencode
  printed FAIL then exited 0), the 14-C1 poisoning-class guard on the
  stock-lnk base adoption (an unsuffixed read only), the 14-L4
  remove-verify, the 14-M3-class icon fallback chain (cline), and opencode's
  repair path records its FAILs (they were printed and forgotten) and honors
  a combined `-Remove`. Pester 238/238, harness PASS, unittest OK, parse 0,
  PSSA per-file baselines identical (one pre-existing trailing-whitespace
  finding removed). No live shortcut writes — user-supervised.
- **CI runner-only failures fixed (2026-11-16)** — main's CI had been red
  since the 2026-11-14 parity wave (PR #62 broke `PowerShell lint + tests`,
  PR #66 broke `Python core tests (ubuntu)` and `Shell lint`); the merges
  used admin bypass, so the red jobs went unnoticed. Three fixes, none of
  them logic regressions on Windows:
  - `tests/exe_identity_suites.Tests.ps1` dot-sourced the three new
    `patch_*_exe_identity.ps1` wrappers whose MAIN flow runs at script
    level — on the runner (no AutoClaw2/Cline/OpenCode installs) the
    `Resolve-*InstallDir` throw aborted the whole file (11 tests failed).
    The wrappers now carry the canonical dot-source guard
    (`if ($MyInvocation.InvocationName -eq '.') { return }`, cf.
    `reset_autoclaw2.ps1`) placed AFTER every function + `$script:`
    constant — direct runs are unchanged; the Pester harness gets the maps
    without resolving an install, so the tests now actually RUN on CI
    instead of aborting.
  - `tests/python/test_ghost_autoclaw2.py`: the two exclusive-lock tests
    use `ctypes.windll` (kernel32 `CreateFileW` no-sharing) — now
    `skipUnless(sys.platform.startswith("win"))` (the runner's ubuntu leg
    errored 2×); `test_root_match_is_case_and_slash_insensitive` asserted
    Windows-only behavior unconditionally — `normalize_root` case-folds
    ONLY on `os.name == "nt"` (correct: NTFS is case-insensitive, POSIX is
    not), so on Linux the differing-case path is a genuine non-match and
    the test now asserts the SKIP+WARN outcome there instead.
  - `Shell lint` (shellcheck): `reset_trae.sh`'s `b64_json` was a REAL
    latent bug — the function read `$1` while every call site PIPES the
    JSON (argv[1] arrived empty, `json.loads('')` would raise on Linux);
    it now reads STDIN (SC2120/SC2119 resolved; `reset_cursor.sh` keeps
    its argv style, its call site passes the document). Also: the dead
    `<pass_var> <fail_var>` parameters of `reset_electron_stores` removed
    (no caller passed them, the body never used them — SC2034; the
    function's return code is the outcome and callers bump their own
    counters); intentional shellcheck shapes suppressed with justification
    comments (SC2016 `$(dirname %q)` emitted into the GENERATED restore
    script; SC2153 caller-assigned `BACKUP_ROOT`; SC2088 `~/.app` display
    labels in the three "not mapped on this platform" branches).
    Local: `bash -n` clean, Pester 238/238, unittest OK.
- **change_device_id.ps1 hardening — bug-sweep report 09 walk (BS-10, PR
  2026-11-16)**: of report 09's findings, 7 were genuinely open (7 of the
  reset_autoclaw ones are obsolete — the target was deleted with the v1
  suite; the HIGH .bak/hive-load findings already landed 2026-11-11).
  **09-M1**: every `reg export` now checks `$LASTEXITCODE` (reg.exe never
  throws, so the old try/catch was dead code) — the LegacyReset nine-key
  backup aborts BEFORE the first destructive write on any failed export,
  and RepairProfiles refuses to repair without its ProfileList rollback
  artifact. **09-M2**: RepairProfiles validates each `.bak` key's
  `ProfileImagePath` exists on disk before the swap (a leftover temp
  profile would point ProfileList at a missing path after the rename =
  logon lockout); such keys are skipped loudly. **09-M3**: the generated
  restore script is written no-BOM UTF-8 (was `-Encoding ASCII`, which
  mangled every path the moment `%TEMP%` carries a non-ASCII username).
  **09-M4**: failure paths now exit 1 (elevation refusal, repair failure,
  aborted-after-rollback, unreadable state) and success paths exit 0 —
  the menu's child exit code is meaningful. **09-L1**: the create-new-key
  branch re-reads and compares after the write (never-silent-success).
  **09-L2**: `Read-State` distinguishes genuine first-run ($null) from an
  UNREADABLE state file (corrupt JSON / DPAPI failure = sentinel object);
  `Write-State` refuses to overwrite an unreadable state (a fresh salt
  would silently re-base the fingerprint history) and Fingerprint mode
  fails loudly with `stateUnreadable` in the JSON. **09-L3**: the HKCU
  pass no longer double-writes the current user's entries — the SID pass
  records what it wrote for the current user's SID and HKCU only carries
  entries the SID pass could not reach (the duplicate write also appended
  a rollback entry recording the pass-1 random as the "original"). PSSA
  rule multiset identical (4 trailing-whitespace findings removed), parse
  clean. Destructive modes stay user-supervised.
- **ZCode reset W1-9 -DryRun + W2-3 menu row (gid 109) + W3-2 watchdog
  preflight + W4-2 harness scenarios** (2026-11-15): the W1 remainder is
  COMPLETE. **W1-9 (F-11)**: `reset_zcode.ps1 -DryRun` is a report-only
  planner — it prints the target roots, presence checks (shared CLI db,
  Qoder, partial profile), the would-kill process set + survivor count and
  the full 27-step plan, then exits 0 BEFORE the Python preflight, before
  any kill and before any write; a DryRun also skips self-elevation (the
  elevation block moved below the DryRun gate) and the orchestrator
  (Both/All) prints its child sequence without spawning them. Verified
  under redirected USERPROFILE/APPDATA fixtures: zero fixture writes (the
  two created dirs are powershell.exe's own startup artifact, present in
  the control run too). **W2-3**: GHOST.bat ZCode local **[33]** → **gid
  109** "Dry-run reset planner" (All instances, dispatched via :RunWith —
  no elevation needed), wired into the resolver, the dispatch ladder, the
  :DispatchOne header range (1-109) and menu.json (inline-note mode with
  the report-only disclaimer; the hub-parity ARGS check now word-splits a
  RunWith row's args token to match the runtime `%~3` expansion). **W3-2
  (F-03)**: the reset probes the captcha watchdog's `ZcodeCaptchaWatchdog`
  mutex before the kill and warns that its blanket taskkill can void the
  survivor guarantee + repopulate the Primary (audited). **W4-2**: two new
  harness scenarios — V runs the two-token ZCode chain "2 33" END-TO-END
  through the dispatcher into the real dry-run planner (report-only, so
  the one reset-family row the harness can execute for real) and W runs
  the ZCode unknown-token continuation ("2 99" → exactly one Unknown
  task); scenario D/E moved to the new unassigned gid 110. The harness
  also pins the test copy's working directory to the repo root (GHOST.bat
  self-normalizes via `cd /d "%~dp0"`; without the swap the first
  dispatched-script scenario fails on relative paths). Pester 238/238
  (incl. the repo-integrity dispatch-range check and the hub-parity ARGS),
  harness PASS, unittest 194 OK, PSSA 21=21, parse clean. Live runs
  pending user supervision.
- **ZCode reset W1-4 abort checkpoint + W1-6/W1-7/W1-10 UX hardening**
  (2026-11-15): the second slice of the W1 remainder. **W1-4 (F-05)**: the
  whole 27-step pipeline now runs inside `try/finally` whose flush re-writes
  the audit log + regenerates the restore script EVEN on a hard abort — the
  old write-only-at-the-tail layout left a mid-run abort with mutations
  applied but NO audit and NO restore script (the flush is idempotent with
  the tail write; flush failures are loud). **W1-6 (F-07)**: a clone target
  with instances running but ZERO mains classifying as it (the classic
  bare-launched clone that owns the Primary profile) now emits the loud
  WARN instead of silently "OK-ing in ~3 s having killed nothing"; Primary
  keeps its ambiguity abort. **W1-7 (F-08)**: the self-elevation deletes
  the stale `zcode_v1.5_done.txt` before relaunch and relays the child's
  exit code via `-PassThru` (a failing reset no longer exits 0). **W1-10
  (F-13)**: a clone home whose profile is PARTIAL (no `v2\setting.json`)
  warns explicitly with the reseed hint (the launcher's `.zcode-seeded`/
  `.zcode-seeding` markers auto-heal partials) and audits the warning.
  Pester 238/238, harness PASS, unittest 194 OK, PSSA 21=21, parse clean.
  Live comparison run pending user supervision.
- **ZCode reset W1-1 shared-db scrub [26b] + W1-3 strict backups** (2026-11-15):
  the first two items of the ZCode W1 remainder (edge-cases plan F-01
  severity H / F-04 severity H). **Step [26b/27]** (a deliberate extension
  of the 27-step contract): the LIVE shared CLI store
  `~\.zcode\cli\db\db.sqlite` is read by EVERY instance, and step [26]
  only reaches it when the target's user profile IS the shared one
  (Primary) — a clone-only reset left its telemetry/machineId/deviceId
  rows intact (the cross-instance correlation trail F-01 was filed for).
  Clone targets now scrub the shared db too: WAL-aware strict backup then
  `clear-cli-telemetry`, whose 10 s busy timeout makes a survivor-held db
  an honest FAILED entry + WARN (never a silent skip); survivors are
  verified zero. **Strict backups**: all 9 `Backup-ViaCore` call sites
  now check the result — backup FAILED ⇒ audit `backup-failed` +
  `failCount++` + the mutation is SKIPPED (the v1.4 warn-and-proceed
  contract let a locked `credentials.json` be modified unrestorable). The
  core `backup` verb gains `--sqlite-wal` (best-effort
  `PRAGMA wal_checkpoint(TRUNCATE)` then `-wal`/`-shm` sibling copies)
  so the undo copy of a WAL-mode db can be reopened even when live
  writers held it (+3 unittests: locked-writers sibling copy, quiet-db
  clean path, non-sqlite source tolerated) — unittest 194 OK. Pester
  238/238, harness PASS, PSSA 21=21, parse clean. Live comparison run
  pending user supervision.
- **ZCode reset clone-target Qoder gate (W1-2) + BS-8 verification closure
  + clear-cli-telemetry tests (W4-3)** (2026-11-15): single-target CLONE
  resets no longer run the Qoder steps — the edge-cases plan's F-02
  (severity H) closed per its recorded decision D2 (in-script gate on
  `$Target -eq 'Primary'`, defense in depth). Why it mattered: the Qoder
  kill is Primary-only, so on a clone-only reset a live Qoder could
  re-persist `storage.json` AFTER verify (a silent revert of step [1])
  and a hard Qoder file lock could abort the whole run before audit/
  restore exist; the v1.4 header claimed "clone targets never touch
  Qoder" while the code did the opposite — with the gate the comment is
  finally true. Both/All orchestrators already routed Qoder to the
  Primary child via `-SkipQoder`, so their behavior is unchanged. Also:
  **BS-8 (the two ZCode watchers) closed verification-only** — all 9
  report-12 findings are already fixed in current code (per-tree marker
  classification with copy-family patterns, live-exe resolution,
  per-pass error isolation + atomic state writes, parsed-fields-only
  1305, hourly-cap requeue, midnight day-switch drain, `-RunOnce` scan
  exclusion, the taskbar Primary-never-guesses guard, `SeenHwnds` prune —
  evidence cited file:line in TASK_BACKLOG), and **W4-3** lands the two
  recorded `clear-cli-telemetry` unittests (a store with no matching rows
  reports zeroed counts honestly; a locked DB surfaces the error dict
  after the busy timeout instead of a silent success). unittest
  189 → 191 OK. Pester 238/238, harness PASS. The whole H-severity
  bug-sweep tier (BS-1..BS-9 + BS-11) is now closed; the remaining tiers
  are the W1 remainder, BS-10, CS-1 and the DT items.
- **Qoder reset v0.5 bug-sweep hardening (BS-7) + purge-policy alignment**
  (2026-11-15): report 05 walked item-by-item against the v0.5 thin
  manifest — the two HIGHs the migration had already closed are recorded
  (ANSI decode: zero direct app-store reads left; argv.json missing key:
  the core `patch_argv_json` INSERTS when absent), and the genuine
  remainders are fixed. Step [30] now routes the `.qoder` run-state trees
  through the sweep-tree core twin (`Clear-TreeFilesIndividually` — defined
  since v0.5 but NEVER called; the header promised it) so one locked log
  no longer leaves 99% of the tree on disk; steps [13]–[18] keep the
  whole-path store-delete by documented choice. The [21] purge gets the
  #73 policy shape: 24 h floor + never the current run, old runs'
  `audit_*.json`/`restore_*.ps1` preserved at the `ID_Backups` root, and
  VERIFIED deletes (`still-present` audited `ok=$false` — the old code
  audited a green "deleted" for a locked dir with the complete old
  fingerprint snapshot still on disk). Self-elevation deletes the stale
  done-marker and relays the child exit code via `-PassThru` (a failing
  reset no longer exits 0). The taskkill stderr race (native stderr under
  `EAP=Stop` aborts the run pre-audit) is caught and logged. The MAC
  ledger/restore is now a true inversion: the manifest records
  `previousValue`/`previousExisted`/`ifIndex`/`writeOk` per adapter (only
  when the write landed), the restore REMOVES invented overrides (the old
  script pinned the reset-time MAC over the burned-in address on adapters
  that never had one), skips adapters whose write never landed, and
  addresses by `-InterfaceIndex` (the `-Name` parameter accepts
  wildcards). `Remove-QoderPathSafely` returns an honest
  `deleted`/`delete-failed` verdict and steps [20]/[21]/[22] count
  failures (the watchdog probe returns the trae/zcode `allOk` contract).
  The final state.vscdb probe RE-ASSERTS the written value via the core
  `sqlite-update` verb (idempotent, heals a post-run recreation) instead
  of replaying step-[3] audit entries, and a missing DB file fails
  honestly. The stale "WIN-<8hex>" header line corrected (the code
  produces the DESKTOP-XXXXXXX factory-default pattern). One finding
  stays OPEN and recorded: no top-level guard before the end-of-run
  audit/restore write (the W1-4 incremental-audit class). `reset_trae.ps1`
  gets the same 24 h purge floor + manifest preservation (its deletes
  were already verified), closing the recorded candidate follow-up.
  Verified with a 7-check functional probe of the extracted qoder purge
  function. Pester 238/238, harness PASS, unittest 189 OK, PSSA 18=18 /
  4=4 baselines, parse clean. Live comparison run pending user
  supervision.
- **Bug-sweep backlog re-status + trae hardening remainder (BS-9 walk)
  (2026-11-15)**: `reset_trae.ps1` v0.3 walked item-by-item against the
  bug-sweep report (04) — 9 of 11 findings CLOSED with evidence (the
  v0.3 thin manifest had incidentally fixed or pre-fixed them: all JSON
  mutations in the core, `scrub-rows` tightened matching + reported
  skips, watchdog step counts failures, verified purge, wrapped
  `.Trim()`, core-generated salt, cline-host counted in the clean check,
  `sweep-tree` verify-after by recount, watchdog probe expanded 4→6).
  One genuine remainder APPLIED: the self-elevation relaunch now uses
  `-PassThru` + `.ExitCode` and relays the elevated child's exit code
  (a failing reset no longer looks green to callers that check
  `$LASTEXITCODE`; the stale-marker half of that finding was already
  fixed). One finding stays OPEN and recorded: no top-level guard before
  the end-of-run audit/restore write (the W1-4 incremental-audit class).
  `docs/TASK_BACKLOG.md` fully re-statused: BS-4/BS-5/BS-6 → FIXED (PRs
  #72–#74), BS-9/BS-11/CS-6/DT-1 → CLOSED with evidence, the 2026-10
  write-guard blocker §2 marked RESOLVED-IN-PRACTICE (the exact files it
  blocked were edited repeatedly by #43-era and #67–#71 sessions), W1-5/
  W1-8 marked done, the migration queue §4 marked COMPLETE (#67–#71),
  and the priority order rewritten (next tier: BS-8 watchers → BS-7 walk
  vs v0.5 → the W1 remainder). OPENCODE_CLONES_SPEC §7's stale
  "preflight lane" note rewritten (verified: `@opencode-aidesktop` IS
  the first probed lane). Pester 238/238, harness PASS, unittest 189 OK.
- **Python core hardening (BS-6)** (2026-11-15): three
  `_bug_sweep\fixes\BLOCKED_FIXES.md` §5 fixes in
  `src/python/ghost/sqlite_keys.py`. (a) `_ro_connect` now URI-quotes the
  normalized path (`quote(..., safe="/:")`) — a profile dir with a SPACE
  ("C:\Users\My Name\...") previously truncated the `file:` URI at the
  space, so every verify-after re-open targeted a nonexistent location and
  returned `after` values of `None`; (b) `sqlite_update` returns an `ok`
  verdict (`after` matches the update exactly OR as text — the TEXT-affinity
  value column reads an int written as `5` back as `"5"`), letting PS
  callers treat a redirected/torn write as FAILED instead of trusting the
  green success line; (c) `delete_secrets` records an exact key as deleted
  only when `cursor.rowcount > 0` — the old unconditional append reported
  phantom removals for keys that were never in the table. The fourth §5
  item (the backup-uniquify test rename) had already landed
  (`test_existing_destination_is_uniquified_not_clobbered`). +7 unittests
  (spaced-path verify, direct quote pin, ok true / text-affinity true /
  forced-false via a redirected verify store, absent exact key not
  reported, present key still reported) — unittest 189 OK. Pester 238/238,
  harness PASS.
- **ZCode reset v1.5 backup-purge hardening (BS-5 / W1-5)** (2026-11-15):
  the `_bug_sweep\fixes\BLOCKED_FIXES.md` §2 staged diffs applied to
  `reset_zcode.ps1` [27/27] and adapted to the v1.5 thin manifest. The old
  unconditional name-filter purge wiped every same-day `ID_Backups` dir —
  including the only undo copy of an earlier chained run (e.g.
  `reset_qoder.ps1` minutes earlier; the Qoder keep-dir Join-Path never
  exists because reset_zcode writes its Qoder-profile backups under the
  ZCode backup root). New policy: the current run's dir is never deleted,
  only dirs OLDER than 24 h are purgeable, and before deleting an old dir
  its `audit_*.json` + `restore_*.ps1` move up to the `ID_Backups` root
  (each carries its run's timestamp) so every earlier run's undo evidence
  survives its data purge — the edge-cases plan's D3 retention policy.
  Every delete is now VERIFIED (`Remove-Item` then `Test-Path`; a locked
  dir is audited `still-present` with `ok=$false` + a red FAILED line
  instead of a green "deleted"), and the [27] watchdog step stops claiming
  a green pass when a re-delete failed: `watchdog-recreate` audit entries
  with `ok=$false` now count into `$failCount` (the old unconditional
  `passCount++` turned those into exit 0). Verified with a 7-check
  functional probe of the extracted purge function (old dir deleted +
  manifests preserved at root + same-day run protected + current run kept
  + verified audit entries). Pester 238/238, harness PASS, unittest 182
  OK, PSSA unchanged (21 baseline = 21 new), parse clean. Live comparison
  run pending user supervision.
- **ZCode clone launcher bug-sweep hardening (BS-4)** (2026-11-15): the
  `_bug_sweep\fixes\10-fixes.md` staged designs (2026-10-24, then blocked by a
  workspace write-guard false positive) applied to
  `launch_zcode_second_instance.ps1` and adapted to the current code.
  **Seed gate = completion marker**: `.zcode-seeded` is written only after
  robocopy 0-7 AND the identity scrub verified — the old single-file gate
  (`v2\setting.json`) let an aborted robocopy pass as seeded once that one
  file existed; `.zcode-seeding` is written BEFORE the copy so a crash
  mid-seed is auto-cleared and re-seeded on the next launch; profiles built
  by earlier launcher versions are ADOPTED, never re-seeded over. **Primary
  closed gate**: the copy source `~\.zcode` holds the shared CLI db held by
  EVERY running instance, so the seed now waits up to 180 s for ALL ZCode
  mains to close (fails CLOSED on a WMI error) instead of copying live WAL
  stores and deleting the copied journals (torn pages + lost
  committed-but-uncheckpointed transactions). **Every seed-scrub write
  re-read-verifies** (telemetry deviceMid, setting.json deviceSid,
  credentials.json `oauth:`/`zcodejwttoken` absence, provider apiKeys
  emptiness, `.updaterId`); a FAILED scrub withholds the seed marker and
  throws before launch — the clone can never run on Primary identity.
  deviceSid is now CSPRNG `GetBytes()` + rejection sampling (was
  `Get-Random`). **Telegram reconcile fail-closed + multi-bot**: ALL Primary
  bots are fingerprinted into sha8/id sets (was first-bot-only, so a clone
  copy of bot #2 matched nothing) and a failed/unavailable fingerprint now
  really disables every enabled clone bot (the old code only printed
  "falling back to disable" and then PRESERVED the seed-copy duplicate —
  two pollers on one token, HTTP 409 + cross-account billing, locked in by
  the marker); every disable write is re-read-verified and the
  `.telegram-routed` marker is withheld on any write failure so the
  reconcile retries. Window resolve is title-ONLY (the fresh-PID fallback
  adopted any new bare-exe main, incl. a sibling clone's); branding icon
  seed copy wrapped in try/catch; `ZcodeWindowAumid` Add-Type guarded with
  `-as [type]` (in-session re-run no longer throws). The dead
  `$tgPrimaryCreds` probe is gone. Behavior change (deliberate): first-time
  seeding now requires every ZCode instance closed — remediation text
  explains seeding several clones one at a time. Pester 238/238, harness
  PASS, unittest 182 OK, PSSA findings 6 (baseline 7), parse clean. Live
  acceptance pending user supervision.
- **ZCode reset v1.5 — thin manifest over the Python core; Phase 3
  COMPLETE** (2026-11-14): the final migration (#7 of 7). The 27 steps,
  their order, audit keys, restore actions and summary are identical to
  v1.4 (archived `archive/reset_zcode_windows-v1.4.ps1`, local-only); every
  store mutation now runs through the one `Invoke-GhostCore` helper.
  Highlights: credentials OAuth clear = `json-remove` with the `oauth:`
  TOP-LEVEL PREFIX + the `zcodejwttoken` exact key (the M1 prefix mode —
  the key names embed colons, dotted walking cannot address them);
  `provider.*.options.apiKey` strip = ONE pre-backup + per-provider
  `json-set` gated on an EXISTING apiKey (the v1.4 conditional preserved —
  no provider gains an `options.apiKey` it did not have); RUM store =
  one `json-patch` (`_arms_uid` + `_arms_session`); `setting.json`
  `deviceSid` = `json-set` dotted path (created when missing, the v1.4
  Add-Member behavior); `clear-cli-telemetry` keeps its error-dict contract
  through the unified helper. **RNG fix (repo convention
  "RandomNumberGenerator via .GetBytes() only")**: v1.4 generated the
  Preferences salt with `Get-Random` (time-seeded PRNG, not a CSPRNG) and
  shared it across EVERY profile the run touched — the core's salt-rotate
  now generates a CSPRNG 32-lowercase-hex salt PER PROFILE, and
  `$newArmsUid`/`$newDeviceSid` moved off Get-Random to GetBytes. The
  fail-fast Python preflight (one of the v1.5 items recorded PENDING in the
  CHANGELOG) lands here; the remaining recorded v1.5 script items
  (shared-db scrub [26b], strict backups, abort checkpoint, -DryRun, purge
  salvage) stay PENDING — separate debt, not part of the migration.
  **Phase 3 of the Python hybrid roadmap is now COMPLETE: all seven IDE
  resets are thin manifests and no temp-.py heredoc remains anywhere in the
  repo.** Pester 238/238, harness PASS, unittest 182 OK. Live comparison
  run pending user supervision.
- **MiniMax/OpenCode reset v1.4 — thin manifest over the Python core**
  (2026-11-14): Phase 3 migration #5 — the script that previously required
  NO Python now routes every store mutation through `Invoke-GhostCore`
  (machineid-file / json-remove / json-patch / salt-rotate / sweep-file /
  sweep-tree / store-delete / backup). The 22 steps, their order, audit
  keys, restore actions and summary are identical to v1.3 (archived
  `archive/reset_minimax_opencode_windows-v1.3.ps1`, local-only). Guard
  KEPT: the tree sweeps still refuse to delete when the pre-backup failed
  (v1.3's no-backup-no-delete never-silent-success rule). Improvements
  over v1.3: the Preferences salt is now generated PER PROFILE by the core
  (v1.3 shared ONE salt across MiniMax and OpenCode Preferences — a
  cross-profile correlation signal), and the restore manifest only lists
  os_crypt backups when the key was actually removed. Documented delta: an
  UNPARSEABLE auth file now FAILS the wipe step loudly instead of being
  force-overwritten to `{}` (the core never clobbers unparseable JSON —
  delete the file manually or restore from the backup to recover). Python
  now required (fail-fast preflight). Pester 238/238, harness PASS,
  unittest 177 OK. Live comparison run pending user supervision.
- **QoderWork reset v0.2 — thin manifest over the Python core** (2026-11-14):
  Phase 3 migration #4. The 26 steps, their order, audit keys, restore
  actions and summary are identical to v0.1 (archived
  `archive/reset_qoderwork_windows-v0.1.ps1`, local-only); every FILE-level
  store mutation now runs through `Invoke-GhostCore` → `machineid-file` /
  `json-patch` / `salt-rotate` / `store-delete` / `backup`. The v0.1
  temp-.py heredoc (`qoderwork_scrub_agents_{guid}.py`) is gone, replaced by
  the new shared core verb **`purge-tables`** (`sqlite_keys.purge_table_rows`:
  DELETE every row from whitelisted tables + exact-key rows from one keyed
  table; table names regex-whitelisted, schema evolution tolerated per table
  AND per keyed table, verify-after = read-only reopen recount so the
  caller's "after == 0" check IS the verification). Behavioral deltas,
  both strictly safer: the external-commands registry empties the
  `commands` key instead of rewriting the whole file (unknown top-level
  keys survive schema evolution), and the Preferences salt is generated in
  the core (32 lowercase hex vs v0.1's uppercase GUID-N — same length/
  format class, case not significant to the app). FIXED a latent v0.1 gap:
  the heredoc crashed when the `app_settings` table was absent while the
  PS side already carried a schema-missing branch for it — the core
  tolerates a missing keyed table per key, so that branch is finally
  reachable. `-DryRun` still writes NOTHING (no core invocation, no TEMP
  files) and runs without Python; the registry/MAC/hostname system steps
  [22]-[26] stay PowerShell by contract. 177 unittests green (4 new:
  purge-tables schema-tolerance + CLI contract). Live comparison run
  pending user supervision.
- **Trae reset v0.3 — thin manifest over the Python core** (2026-11-14):
  Phase 3 migration #3 (roadmap order trae → qoderwork → minimax → qoder →
  zcode). The 16 steps, their order, audit keys, restore actions and summary
  are identical to v0.2 (archived `archive/reset_trae_windows-v0.2.ps1`,
  local-only); every store mutation now runs through `Invoke-GhostCore` →
  `machineid-file` / `json-patch` / `json-remove` / `json-set` /
  `sqlite-update` / `sweep-file` / `sweep-tree` / `store-delete` /
  `salt-rotate` / `backup`. The v0.2 temp-.py heredoc
  (`trae_scrub_aiagent_{guid}.py`) is gone, replaced by the new shared core
  verb **`scrub-rows`** (`sqlite_keys.scrub_identity_rows`: key-NAME
  matching in EVERY key-like table of a database — typed and untyped
  columns, `key > itemkey > k > id > name` priority, ESCAPE'd
  single-token-adjacency patterns so spaced human text can never match;
  values/chat content never inspected; verify-after survivor recount +
  `skipped_tables` reported). `json-remove` gained optional top-level
  **prefix removal** (`removed_prefixes` in the report) for the
  `iCubeAuthInfo://*` auth keys whose names embed URLs and can never be
  addressed as dotted paths (the dotted walk silently no-ops on them).
  Also fixed a latent v0.2 bug: `$traeDoneMarker` was never assigned (8
  bare references), so every elevated run crashed at the final marker write
  and non-admin self-elevation broke before relaunching — v0.3 uses the
  fixed cursor-style marker (`%TEMP%\trae_v0.3_done.txt`, the reset_cursor
  v0.3 pattern). Python now required for EVERY step (fail-fast preflight).
  173 unittests green (6 new: scrub-rows multi-table/escape semantics +
  json-remove prefix). Live comparison run pending user supervision.
- **Linux resets for the remaining agents** (2026-11-14): new
  `reset_qoder.sh`, `reset_qoderwork.sh`, `reset_zcode.sh` (default
  profile; the shared CLI session store deliberately untouched — matches
  the Windows reset) and `reset_minimax_opencode.sh` (the OpenCode CLI
  XDG stores deliberately untouched — they carry the CLI login). All four
  are DERIVED-PATH scope: the Linux layouts come from `ghost.platform`
  (provenance-flagged unverified, printed loudly at run start) and the
  scripts skip loudly when a store is absent — nothing is guessed. Every
  mutation goes through the shared Python core with verify-after, audit
  and restore emission. `ghost.sh` upgraded to grouped sections (IDE
  Resets 1-7 / System 8-9). FAQ's honest Linux answer updated (the
  "Windows-only" phrasing was stale).
- **Linux resets modernized to the Windows standard** (2026-11-14):
  `reset_cursor.sh` v0.2 + `reset_trae.sh` v0.2 route every store mutation
  through the shared Python core (`ghost_cli.py json-patch` /
  `sqlite-update` / `machineid-file` — ONE copy of the logic for Windows +
  Linux), and fail loudly when python3 or the core file is missing instead
  of silently skipping (the thin-manifest contract). Both now carry
  timestamped `ID_Backups/<ts>` dirs, JSONL audit, verify-after re-reads
  on every write, and a self-generated `restore.sh` — the README's
  advertised verify-after/audit/restore trio finally holds on Linux.
  `reset_windsurf.sh` → **`reset_devin.sh`** (the 2026-06-02 Devin
  rebrand finally reached Linux; the Codeium-era `codeium.com/waitlist`
  URL the old script wrote into the Codeium config on every reset is
  scrubbed) with the same audit/restore standard. `reset_trae.sh`
  PROMOTED from the local-only archive v0.1 (never committed) — deeper
  Windows-side Trae stores are not covered on Linux yet (provenance
  flagged in `ghost.platform`). `ghost.sh` menu upgraded (Trae row +
  Devin naming). `id_reset_common.sh` gains the core bridge
  (`resolve_ghost_cli`/`core_backup`), JSONL audit, restore-script
  emission and verify-after helpers shared by all Linux resets.
- **Cross-platform identity-store path layer** (2026-11-14): new
  `src/python/ghost/platform.py` — the single source of truth for WHERE each
  agent keeps its identity stores per OS (cursor, devin/windsurf, trae,
  qoder, qoderwork, zcode, minimax, opencode-cli; the desktop clone suites
  are deliberately unmapped — no Linux builds discovered, guessing
  forbidden). New `ghost_cli.py paths <slug>` verb prints the resolved map
  as JSON with `unverified` rows surfaced loudly (exit 2 on an unknown
  slug) — the Linux `.sh` resets consume it instead of hardcoding paths,
  so a path fix lands in one place. Provenance flags: cursor/devin/
  opencode-cli verified on both platforms (existing shipped scripts / live
  probing); trae/qoder/qoderwork/zcode-Linux rows derived from the Windows
  layout + documented Linux conventions and flagged `verified: false`
  (ground truth #5) pending live Linux verification. CI's python-core job
  gains an ubuntu-latest matrix leg so the core stays path-correct on
  Linux. Unit tests: `tests/python/test_ghost_platform.py` (9).
- **AutoClaw2 identity reset** (2026-11-14): new
  `src/windows/reset_autoclaw2.ps1` (`-Target Primary|c1..c5|All`,
  `-KeepLogin`, `-DryRun`) closes the suite's last MANDATORY playbook gap —
  the identity reset. Per profile it rotates `device\device-id.json`
  (verified old != new), clears the signed-out pointer, deletes the
  per-account auth + runtime-secret stores, the network session stores,
  `Local State` (OSCrypt key), telemetry (`apmplus`, `log_sdk_v2.db`,
  `diagnostics`, `logs`) and the caches/webview partitions; chats, work
  runs, projects, MCP connections and Telegram routing are preserved.
  Backups to `ID_Backups\<ts>\` + audit JSON + a restore script per
  target; thin manifest over the Python core (`store-delete` /
  `sweep-tree` / `json-patch` / `backup` — no new core verbs needed).
  Menu: AutoClaw2 [14]-[20] (gids 84-90, appended in display order, never
  renumbered; the ALL row is gated by the new `:ConfirmAc2Reset`, and
  `:RunAc2Reset` prints the relaunch-safety note); desktop hub rows match
  (menu.json modes `zcode-reset` / `confirm-reset`, ARGS-parity proven by
  the extended hub test). The pure target/marker/device-id-shape helpers
  are unit-tested through the script's dot-source guard
  (`tests/reset_autoclaw2.Tests.ps1`, 10 tests). Live acceptance stays
  user-supervised — nothing was executed against the live profiles.
- **Cline identity reset** (2026-11-14): new `src/windows/reset_cline.ps1`
  (`-Target Primary|c1..c5|All`, `-KeepLogin`, `-DryRun`) — OVERRIDES the
  Cline spec's earlier "no reset script by design" decision. Deletes
  `data\secrets.json` (clineAccountId + tokens) + `data\settings\providers.json`
  (provider OAuth) — the only auth stores — and sweeps stale hub locks,
  logs, cache and the web-login Chromium profile (`webview\EBWebView` per
  clone; the Primary's lives at `%LOCALAPPDATA%\bot.cline.app`). `data\db\*.db`
  (sessions/tasks/hub/teams/connectors), `data\sessions\` and the settings
  files are preserved. HKLM MachineGuid is deliberately untouched
  (system-level; `change_device_id.ps1` owns it). Menu: Cline [10]-[16]
  (gids 91-97, appended in display order; the ALL row gated by
  `:ConfirmClineReset`; `:RunClineReset` prints the relaunch-safety note);
  hub rows + wrapper table + harness scenarios extended. Pure helpers
  unit-tested via the dot-source guard (`tests/reset_cline.Tests.ps1`,
  11 tests). Live acceptance stays user-supervised.
- **OpenCode desktop identity reset** (2026-11-14): new
  `src/windows/reset_opencode.ps1` (`-Target Primary|c1..c5|All`,
  `-KeepLogin`, `-DryRun`). One target spans TWO profile surfaces (the
  clone-home patch pins them per clone): the Electron userData
  (`desktop\` per clone; `%APPDATA%\ai.opencode.desktop` for the
  Primary) and the XDG data home (`data\opencode` per clone;
  `~\.local\share\opencode` for the Primary). Deletes `auth.json` +
  `mcp-auth.json` (CLI OAuth), `gh\device-id`, `desktop\.updaterId`
  (clones), the session profile's `Local State` (OSCrypt key) + network
  session stores, caches and Crashpad/logs/compile-cache. Preserves
  `opencode.db` (+wal/shm) = sessions, repos, snapshots, drafts, the CLI
  cache and `config\opencode\*.json` (MCP definitions). Menu: OpenCode
  [13]-[19] (gids 98-104, appended in display order; the ALL row gated
  by `:ConfirmOpenCodeReset`; `:RunOpenCodeReset` prints the
  relaunch-safety note); hub rows + wrapper table + harness scenarios
  extended. Pure helpers unit-tested via the dot-source guard
  (`tests/reset_opencode.Tests.ps1`, 7 tests). Live acceptance stays
  user-supervised.
- **AutoClaw2 MCP sync watcher** (2026-11-14): the gid-74 row — reserved
  since 2026-11-04 — is LIVE. New
  `tools/watch_autoclaw2_mcp_sync.ps1` stat-guards the central master
  manifest `tools/autoclaw2-mcp.master.json` (mtime+size + JSON
  parse-guard — a torn manifest skips the pass, never syncs) and
  re-applies it via `sync_autoclaw2_mcp.ps1` as a child (console-less
  spawn + 600s kill cap). The watcher writes nothing itself; the first
  pass converges drift, a deep re-verify runs every ~5 min, and the log
  lives at `%LOCALAPPDATA%\watch-autoclaw2-mcp-sync\ac2-mcp-sync.log`.
  Single instance via mutex + startup process scan;
  `-InstallAutostart`/`-RemoveAutostart` manage a hidden Startup .lnk.
  NO `-ApplyLive` by design — the AutoClaw2 sync targets CLOSED profiles
  only (D7), so a synced definition lands on each profile's next launch.
  Menu: new AutoClaw2 [11] row (locals 12+ shifted +1, gids unchanged).
- **Shared RAM/concurrency launch guard across all four suites**
  (2026-11-14): the soft guard `launch_zcode_second_instance.ps1` carried
  since 2026-10-28 (count running mains; at/over the threshold print live
  commit numbers and route the ask: visible console → Read-Host, hidden
  console → topmost Yes/No default-No, `-NonInteractive`/redirected stdin →
  warn+continue) is generalized into `src/windows/ghost_launch_guard.ps1`
  and wired into the AutoClaw2, Cline and OpenCode clone launchers
  (`-MaxConcurrent 3`, `-NonInteractive`; ZCode refactored onto the lib).
  EC-K01 bare-exe mains counting per suite family; the guard fires only
  for a NEW instance — each launcher's own relaunch-focus/single-instance
  check runs first. Rationale: the 2026-09-25 renderer-OOM commit-limit
  freeze is a Windows ceiling, not a ZCode quirk; every suite can now hit
  it. Unit-tested via mocks (`tests/ghost_launch_guard.Tests.ps1`, 11).
- **Task-Manager exe identity generalized to all four suites**
  (2026-11-14, repo-only + opt-in): the pure core and the whole
  orchestration (freshness gate, running gate, copy, Win32 update
  transaction, re-read verify, sidecar marker, JSONL audit) moved
  verbatim from the ZCode-only files into the generic
  `tools/exe_identity_lib.ps1` (`Invoke-GhostExeIdentityPatch`;
  `zcode_exe_identity_lib.ps1` is now a shim = dot-source + the ZCode
  alias map, so the existing 21 ZCode tests exercise the generic core
  transitively). New thin patchers:
  `tools/patch_autoclaw2_exe_identity.ps1` (AutoClaw2 [15] / gid 105),
  `patch_cline_exe_identity.ps1` (Cline [10] / gid 106) and
  `patch_opencode_exe_identity.ps1` (OpenCode [13] / gid 107) build
  `<App>-<Color>.exe` copies with patched icon groups + FileDescription.
  **Deliberately NOT wired into any launcher and NOT executed against the
  dev host during this work** (user decision: "make them in the repo but
  don't setup them - i'm using zcode only") — the menu rows are the only
  entry point. Read-only `-DryRun` acceptance passed for all three
  (noting: AutoClaw2 + OpenCode copies already existed on the host from an
  earlier same-day session, markers fresh — left untouched; Cline has
  none). Suite maps + branding ICOs + no-cross-suite-drift tripwires
  unit-tested (`tests/exe_identity_suites.Tests.ps1`, 11).
- **ZCode clone status row** (2026-11-14): `tools/status_zcode_instances.ps1`
  (ZCode Maintenance [32] / gid 108) — ZCode's parity for the `-Status`
  probe the three newer suites' launchers already carry. Read-only:
  per-instance running state (copy-family + marker classified), roaming +
  clone-home presence, the `v2\telemetry-state.json` `deviceMid` prefix and
  per-instance commit pressure. Live-verified on 4 running instances.
  **Latent hang fixed on the way**: the fresh subtree walks in the three
  2026-11-14 reset scripts used an array-slice "pop"
  (`$stack = $stack[1..($stack.Count-1)]`) that does NOT shrink a
  1-element PowerShell array (`@('A')[1..0] == @('A')` — out-of-range
  indices clamp), so any walk spun forever on leaf nodes — a real reset
  with a running instance would have hung at the stop step. All walks now
  use Queue semantics (Dequeue REMOVES; the same pattern the ZCode launcher
  always used) and a repo-wide tripwire test forbids the slice-pop pattern
  from returning.
- **AutoClaw2 chat sync: `-Account` source hint + source-account
  provenance** (2026-11-11): `tools/sync_autoclaw2_chats.ps1 -Account
  <sha-prefix>` pins the multi-account Primary's account dir for the
  inventory diff, `-AllMissing` planning and every import (new
  `account_hint` / `source_account_hint` payload keys through
  `ac2-chat-inventory` / `-import` / `-revert`; `resolve_profile` always had
  the plumbing — the MCP commands used it, the chat commands never did).
  Reason: the newest-runtime.sqlite default silently SWITCHES the sync
  source when the Primary re-logs into a fresh account (live 2026-11-11:
  `68f7331f…` stopped being written at 09:14 and the new `830c6348…` took
  over — the old account's chats became invisible to the chat sync the same
  minute). Every inventory `[ok]` line and audit record now carries the
  resolved account sha + how it was picked (hint / newest-mtime), so a
  source switch is visible instead of buried. Blind-shell preflight: when a
  profile dir does not resolve, the run prints the APPDATA/USERPROFILE it
  used before the [SKIP] lines — the 2026-11-11 16:24Z inventory ran from a
  shell whose APPDATA pointed elsewhere and reported Primary
  profile-missing + c1 not-signed-in, an empty diff that reads as "nothing
  to sync".
- **ZCode clone OAuth deep-link callback forwarder** (2026-11-11, new
  off-menu tool `tools/watch_zcode_deeplink_forward.ps1`): the machine-wide
  URL scheme always boots the PRIMARY profile (every launch re-registers
  `HKCU\Software\Classes\zcode\shell\open\command` to its own exe and the OS
  spawn carries no clone env), so a clone's browser callback opened the
  Primary and died with "OAuth state mismatch" while the clone's own poll
  hit the business-token exchange. The watcher polls the ZCode process
  family for fresh env-less callback spawns, re-delivers the callback URL
  into every RUNNING instance with its own environment (the OAuth state
  match decides which receiver completes; mismatched ones reject
  harmlessly) and kills the stray Primary-profile spawn (`-NoKillSpawn`
  keeps it). Read-only on the registry, writes nothing to disk.
- **ZCode business-token exchange hardening patch** (2026-11-11, new
  off-menu pair `tools/patch_zcode_business_exchange.ps1` + `.mjs` on the
  shared asar-surgery layer): `exchangeBusinessToken` posted the OAuth
  token with a HARD 10s timeout (`zLe=1e4`) and NO retry — clones died at
  `zai_oauth_required` with the callback already delivered (a 10.14s
  "fetch failed" = the timeout; a separate ~800ms server-envelope failure
  later succeeded = transient). Two byte-anchors in `out/host/index.js`:
  `zLe=1e4` → `zLe=6e4` (length-neutral) + a one-shot retry after a 3s
  backoff spliced into the `resolve()` tail. Marker
  `resources\zcode-business-exchange.marker.json` + `ID_Backups\<ts>`;
  re-run after app updates; built repo-only — never live-applied on the
  dev host (opt-in).

### Fixed
- **ZCode clones could not activate ANY plugin** (2026-11-11):
  `tools/sync_zcode_assets.ps1` mirrored `cli\plugins\cache` but never
  synced `cli\plugins\installed_plugins.json` — clones had no file at all,
  so nothing enabled on the Primary ever activated on a clone. New area 4
  copies the Primary's file with every `installPath` rewritten from the
  Primary cache to the clone's own cache mirror; backup + verify-after
  (full-file round-trip + per-entry installPath existence on the clone) +
  audit, skipped by `-McpOnly`, and an existing clone file is preserved
  when the Primary has none (no destructive delete).
- **Console-less processes flashed visible cmd windows** (2026-11-11):
  `tools/watch_zcode_mcp_sync.ps1` spawned its sync child via a bare `&`
  call and `tools/sync_zcode_assets.ps1` fell back to `cmd.exe /c mklink`
  the same way — a watcher running without a console gave the child a
  brand-new VISIBLE window on every 5-minute deep-verify. Both now spawn
  console-less (`CreateNoWindow`); the watcher child also gained a 600s
  kill cap so a wedged sync can never block the watch loop.
- **GHOST.exe "Import chats to clones" row failed on its own script**
  (2026-11-11): menu.json gid 76 was missing `-AllMissing` (the GHOST.bat
  row has carried it since the 2026-11-09 `:Run` arg fix), so importing
  from the desktop hub hit `[FAILED] -Mode Import needs -SessionId …` and
  copied nothing. The parity test now compares every action gid's ARGS
  against its .bat dispatch line (plus Detached title/psFlags and the
  RunWith `-WaitForClose` ↔ `waitForClose` mapping) — script+mode parity
  alone let this drift through CI; negative-check proven.
- **AutoClaw2 schema gate crashed on a schema-less runtime DB**
  (2026-11-11): `check_schema` ran its migration-history SELECT unguarded,
  so a zero-byte / half-created `runtime.sqlite` (fresh re-login account
  shell) died with `sqlite3.OperationalError` instead of the clean
  `schema-mismatch` refusal. The gate probes `sqlite_master` first and
  reports the missing table as drift.
- **Primary `ZCode.lnk` hijack repair now also restores the drifted TARGET**
  (2026-11-11): a Windows pin rewrite can retarget the Primary's Start-menu
  shortcut onto a per-color exe copy — live-verified: the lnk carried target
  `ZCode-Orange.exe` + an orange Start tile after an auto-repair had logged
  SUCCESS, because the old repair kept the drifted target ("the lnk's own
  target wins") and set the icon FROM it, permanently blessing the clone's
  icon behind a clean AUMID the AUMID-only hijack guard could no longer see.
  `tools/install_zcode_second_shortcuts.ps1 -RepairPrimaryAumid` now
  restores target → stock `ZCode.exe` first (new `Repair-PrimaryLnkTarget`),
  resolves the icon from the stock exe (the "target wins" rule is gone), and
  the resident watcher's guard (`tools/watch_zcode_taskbar.ps1`) detects all
  three hijack shapes — AUMID clone suffix, clone-exe target, wrong/wiped
  icon — through the new shared pure core `tools/zcode_primary_lnk_lib.ps1`
  (unit-tested by `tests/zcode_primary_lnk_lib.Tests.ps1`); target/icon
  checks stay silent when no stock exe resolves so the guard never demands a
  repair it cannot complete. Side-effect closed: the hijacked tile launched
  `ZCode-Orange.exe` env-less (Primary profile, but Task Manager showed it
  as "ZCode Orange" and the copy-family classifier treated it as that clone).

## [1.5.0] - 2026-11-11

### Added
- **Menu: "Launch ZCode Primary" row** (2026-11-10): ZCode submenu [9]
  (new gid 82, new `src\windows\launch_zcode_primary.ps1`) launches the
  stock Primary instance detached and NON-ELEVATED — spawned via
  explorer.exe so the app is always medium-IL (UIPI otherwise silently
  strips drag-drop into an elevated instance) and immune to ZCode's
  AttachConsole console hijack. No clone env vars are ever set: default
  look, bare base AUMID. Verify-after polls 20s for a Primary-classified
  main (subtree carries no clone markers — same classifier as the taskbar
  watcher) and prints the PID, FAILED exit 1 if none; relaunching while
  the Primary runs just focuses its window. Launch transcript at
  tools\logs\launch_zcode_primary.log. Also in GHOST.exe (runtime
  menu.json row, detached mode — no rebuild needed). The Primary reset row
  (ZCode [15], gid 7 — still also IDE Resets [7]) gained a
  "- Primary profile - chats kept" tail in GHOST.bat + menu.json.
- **ZCode Task Manager identity — per-color exe copies** (2026-11-11): Task
  Manager's background-process groups take their display name and icon from
  the executable IMAGE itself (embedded icon resource + VERSIONINFO
  FileDescription), so all six instances running the stock `ZCode.exe`
  rendered as identical stock `ZCode (N)` rows no matter what the
  taskbar/shortcut/window stack did. New
  `tools\patch_zcode_exe_identity.ps1` (+ pure core
  `tools\zcode_exe_identity_lib.ps1`, unit-tested) builds per-color exe
  copies `ZCode-Blue.exe` … `ZCode-Orange.exe` in the install dir (~235 MB
  each, support files shared; ~1.2 GB total) and patches their icon group
  (Win32 UpdateResource, PS 5.1-safe P/Invoke) + FileDescription
  (`ZCode <Color>`), verify-after re-reading the written resources and the
  version info — never silent success. The clone launcher's new step 2f
  fast-checks a sidecar marker (source size+mtime+SHA256 + icon SHA256 +
  engine version) and rebuilds a copy only on drift (app update, icon
  change), then starts that clone from its copy; the Primary keeps the stock
  exe. Copies lose Authenticode validity (resource edits) — AV-protected
  machines may see a SmartScreen prompt on first launch of a copy (this dev
  box runs none; estimate-hedged in docs). Manual rebuild: ZCode submenu
  [31] (new gid 83, appended in display order — gids never renumber) or
  `-Target All` / `-DryRun` / `-Force`.
- **Classifier widening for the copy family** (2026-11-11): every ZCode
  process enumeration across 8 scripts widened from the bare
  `Name='ZCode.exe'` / `Get-Process -Name ZCode` to the whole copy family
  (`Name LIKE 'ZCode%'` / `'ZCode*'` + copy-aware cmdline regex) — the old
  predicates made a clone running from its exe copy invisible to the RAM
  guard, PID-diff discovery, taskbar stamping, selective resets, the
  asset-sync running guard, chat refresh, the MCP-sync watcher and the
  captcha watchdog. Classification gained the copy-exe name as a FIRST
  signal (ZCode-Blue.exe → Second etc.) — deterministic even mid-splash
  before marker-carrying children exist; markers remain signal #2, titles
  the fallback. The captcha watchdog's marker patterns gained the copy exe
  names, its taskkill hammer covers the copies, and its Primary relaunch
  now accepts ONLY the stock install-dir exe (never a copy path). Also
  fixed a silent PRE-EXISTING gap found while writing the new regex: the
  unquoted-path branch of the bare-exe rule used `[^\s"]*`, which can never
  cross the space in `C:\Program Files\...` — machine-wide installs were
  misclassified as Primary; it is `[^"]*` now. Test-pinned by
  tests/zcode_exe_identity.Tests.ps1 (21 tests incl. launcher-parity and a
  copy-family tripwire over all 8 enumeration sites); the resident watchers
  pick the new classifiers up on their next restart (a watcher started
  before the edit keeps the old code — relaunch via ZCode [26] or any clone
  launch's step 2e).
- **GHOST.exe — Windows desktop GUI wrapper** (2026-11-10): single-file
  C# (.NET 4.0 WinForms) launcher compiled on the fly by
  `tools\build_ghost_exe.ps1` using the in-box `csc.exe` (no SDK needed).
  Carries native icon, DPI awareness, embedded UAC manifest, search filtering,
  and executes menu actions with real-time logging. Data-driven from
  `src\desktop\menu.json` with 1:1 parity enforced by `tests\ghost_hub_menu.Tests.ps1`.
- **AutoClaw2 notification-tray identity — identity patch v2** (2026-11-09):
  `tools/patch_autoclaw2_identity.ps1` splices a FOURTH byte-anchor inside the
  generic tray builder (`mTr`): `t=r(e(n.iconPath))` ->
  `t=r(e(process.env.ZWORK_CLONE_ICON||n.iconPath))` — the notification-area
  tray icon now follows `ZWORK_CLONE_ICON` too.
- **Netlify MCP server added to the central registry** (2026-11-08): the
  29th entry `netlify-mcp` in `tools/mcp/master-mcp.json`.
- **Namecheap MCP server added to the central registry** (2026-11-10): HTTP
  MCP endpoint with bearer token authentication.

### Changed
- **ZCode submenu renumbered** (2026-11-10): the new Launch row inserted as
  local [9] shifted locals 9-29 → 10-30 (gids NEVER move).
- **Maintenance submenu expanded**: now [1]-[5] with gid 81 (`tools\build_ghost_exe.ps1`).
- **GHOST shortcuts prefer GHOST.exe**: `tools\install_ghost_shortcut.ps1`
  links to `GHOST.exe` when built, falling back to `GHOST.bat`.

### Fixed
- **Menu "Change Device ID" (IDE Resets [1]) never changed anything** (2026-11-10):
  gid 1 now dispatches through `:ConfirmRun` with `-Mode LegacyReset`. Fixed `reg load`
  error handling via `$LASTEXITCODE`, skipped unmountable profile hives loudly,
  and unified hostname generation with `Get-NewHostname`.
- **MCP registry sync: codex "registry-disabled" skip** (2026-11-10):
  pure `Select-CodexView` filter drops remote and disabled entries before per-app transform.
- **AutoClaw2 chat import empty-pane timeline regression & re-import** (2026-11-10):
  remapped `request_entry_id` and `answer_entry_id` under new run IDs to fix empty imported
  timeline pane; permitted re-importing reverted sessions.
- **AutoClaw2 chat import menu rows & batch import** (2026-11-09):
  fixed `:Run` argument forwarding and added `-AllMissing` batch import mode.
- **AutoClaw2 clone windows taskbar grouping kick** (2026-11-09):
  launcher kicks taskbar group with temporary identity transition to separate buttons.
## [1.4.0] - 2026-11-07

### Security
- **Supabase project refs scrubbed from the PUBLIC repo's entire history**
  (2026-11-07): the four refs (`eysuâ€¦`/`jcuâ€¦`/`cetvâ€¦`/`zfhfeâ€¦`) had been
  committed since PR #25/#26 in `master-mcp.json`, `mcp-inventory.json` and
  `autoclaw2-mcp.master.json`. Working tree: every ref replaced by a
  dedicated `${SUPABASE_PROJECT_REF_*}` env placeholder (MAIN/MASARX/
  IPLOGGER/PORTFOLIO â€” 4 new user-scope vars, harvest never printed), the
  collector now redacts refs by SHAPE in all three forms they appear in
  (`--project-ref` flag-follow args, `project_ref=` query values,
  `<ref>.supabase.co` hosts â€” JSON, TOML and flattened-command forms), and
  `ghost.autoclaw2.expand_env_value` teaches the AutoClaw2 manifest loader
  to expand `${VAR}` (unresolved = left as-is + loud stderr WARN, never
  silently empty). History: mirror clone + `git filter-repo
  --replace-text` over 129 commits (full refs AND the `Supabase (eysuvsof)`
  / `(jcufigo)` name fragments), verified zero occurrences by pickaxe, then
  force-pushed main + release/v1.2.0 + all tags (ruleset temporarily
  disabled via API and restored byte-identically; release.yml disabled for
  the tag push and re-enabled â€” no spurious release runs). Tokens were
  verified NEVER present in any commit (pickaxe on all history: empty).
  Residual: the pre-rewrite commits remain reachable via GitHub's
  `refs/pull/*` archive of PRs #25-#27 (deleting the PRs would purge that
  too â€” refs are non-secret identifiers, so left in place).

### Added
- **The OpenCode clone fleet moves into T3 Code** (2026-11-07): a live spike
  proved `opencode acp` is a real ACP-over-stdio server under a clone's XDG
  env (`protocolVersion: 1` â€” the exact v1 shape T3's generation detection
  keys on â€” plus a live `session/new` sessionId; clean exit, zero orphans),
  so `tools/install_t3_opencode_instances.ps1` (new) seeds five
  `acpRegistry` provider instances into `~/.t3/userdata/settings.json` â€”
  the OpenCode counterpart of the five hand-seeded ZCode bridge instances.
  Same pattern, same discipline: the entries launch
  `launch_opencode_cli_light.ps1 -Instance cN -Acp` (new mode) so per-clone
  isolation rides OUR script's four XDG levers â€” the entries carry NO env
  field and there is zero dependence on any T3 env-override schema;
  backup-first, merge-never-overwrite (only the five `opencode-c1..c5`
  keys â€” favorites and the `zcode-*` instances survive), verify-after
  deep-compare, idempotent, `-Remove`, and a loud running-T3 guard (T3
  reads settings.json only at startup). Tests:
  `tests/opencode_t3_seed.Tests.ps1` (8 â€” AST-extracted core on TEMP
  fixtures, the real settings file never touched). T3-UI acceptance
  (Providers render, streamed reply, model switch, concurrency) is
  user-supervised â€” spec Â§3.10.
- **MCP central registry â€” full-device collect + two new sync targets**
  (2026-11-07): the registry now reaches every MCP-capable agent on the
  box. `tools/mcp/master-mcp.json` grew 25 -> 28 servers
  (`supabase-My-portfolio` â€” Orange-clone discovery, scoped `only:zcode`,
  secret formalized as a NEW dedicated env var
  `${SUPABASE_ACCESS_TOKEN_PORTFOLIO}` after the one-token-per-org lesson;
  `node_repl` â€” Codex runtime, `only:codex`; `computer-use` â€” Copilot
  plugin, dormant scoped to the never-target `copilot-computer-use`),
  and sentry's per-app literal `SENTRY_ACCESS_TOKEN` header was
  formalized as `${SENTRY_ACCESS_TOKEN}` (both harvested from the app
  configs into user-scope env, values never printed). New targets:
  `claude-code` (`~/.claude.json` â€” surgical merge of the top-level
  `mcpServers` property only; app state and `projects.*` untouched) and
  `codex` (`~/.codex/config.toml` â€” new pure module
  `tools/mcp/codex_toml.ps1`, a line-based TOML reader/writer that
  represents ONLY `[mcp_servers.*]` tables and splices them back verbatim
  around everything else; presence==enabled, so registry-disabled and
  remote (url) entries are left untouched; app-only keys such as
  `startup_timeout_sec` and the `[mcp_servers.<n>.env]` sub-table
  survive per-key). `tools/mcp/collect_mcp_inventory.ps1` harvests the
  four newly-found sources too (claude-code, codex TOML, Copilot
  computer-use plugin, OpenCode-Primary mcp section â€” apiKeys in that
  file deliberately unread). Live full-device push verified:
  windsurf/vscode/minimax = sentry header formalization, ZCode Primary
  +1 (the resident watcher propagated it to all five clones within
  seconds), claude-code +19 servers, codex +10 stdio (10 remote entries
  skipped loudly); second run fully in-sync (idempotent); watcher
  `-ApplyLive` recycled the idle instances and correctly DEFERRED the
  ones with active chats (Green/Orange) â€” never -Force. Tests:
  `tests/mcp_registry_sync.Tests.ps1` (14 â€” TOML parse/round-trip/
  verbatim-preservation, bare-key refusal, registry invariants incl. a
  never-literal-secrets scan of the master); Pester 110/110, unittest
  150/150, CI lint gate (Severity Error) clean.
- **OpenCode light worker â€” headless CLI mode for the clones** (2026-11-07):
  the OpenCode counterpart of the ZCode LIGHT worker. All prior OpenCode
  support was desktop-clone-only; the v2 CLI itself was never driven. A
  live spike (scratch XDG env, CLI v2.2.5) verified the whole surface:
  `src/windows/launch_opencode_cli_light.ps1` (OpenCode submenu [7], gid 79)
  runs the shipped `<install>\resources\opencode-cli.exe` on a clone's own
  state using ONLY the four XDG env levers the clone-home asar patch already
  feeds the desktop app (`debug paths` proved data/cache/config/state all
  follow XDG_* while `home` stays the real profile â€” no HOME/USERPROFILE
  redirect needed, unlike ZCode light). Modes: interactive prompt loop
  (default), `-Prompt` one-shot (`run`), `-Server` foreground `serve
  [--port]` (the "run a server" case â€” HTTP verified), `-StopService`
  (automates the Â§3.8 orphan-kill note), `-Login` (submenu [8], gid 80 â€”
  one-time `auth login` per clone home, verify-after =
  `<data>\opencode\auth.json` non-{}). Anonymous homes WORK but run the
  FREE model (iceman-free) â€” the opencode-zen analogue; `-Auto`/`-Standalone`
  pass the CLI's `--auto`/`--standalone`. `run` auto-starts the clone's
  background service (clean stop verified, zero orphans). Tests:
  `tests/opencode_cli_light.Tests.ps1` (15 â€” AST extraction + a functional
  poisoned-env child for the fail-fast guard + the `Test-CloneLoggedIn`
  verify primitive). GHOST.bat OpenCode submenu renumbered locally
  (shortcuts [9], patch [10], status [11], remove [12]; gids 53-62
  untouched). Live acceptance 2026-11-07 (spec Â§3.9.1): one-shot `-Json`
  turn, single + dual-instance `serve` coexistence, orphan-free shutdown â€”
  which caught TWO real launcher bugs, both fixed: (1) assigning the
  launcher function's output swallowed the CLI's ENTIRE stdout (the turn
  succeeded and the answer landed in the session store while stdout showed
  only the banner) â€” the script now calls it as a bare statement and
  branches on `$LASTEXITCODE`, and scripted consumers get `-Json`
  (`--format json`, the CLI's NDJSON contract) because the default
  renderer's final answer is not guaranteed on non-TTY stdout; (2) the CLI
  resolves its project from `$env:PWD` (unix convention) â€” PowerShell
  children inherit a STALE PWD, so every turn silently bound to the
  launcher's launch dir instead of `-Cwd` until the script sets it.
  `-Login` browser-flow acceptance remains user-supervised (Â§3.9.1).
- **AutoClaw2 clones get colored taskbar buttons** (2026-11-06): the suite's
  last DEGRADED item â€” running windows all shared the base AUMID
  `com.zhipuai.autoclaw2` and the exe icon, so every clone collapsed into one
  grouped taskbar button while only the shortcut pins stayed per-clone
  (spec Â§7: "deferred until actually needed"). It turned out AutoClaw2 4.0.0
  ships UNPACKED â€” the whole main process is the plain-text
  `resources\app\dist\main.cjs` (no `app.asar`, no runtime integrity check;
  the bootstrap does a bare `require()` and `payload-verify.cjs` is an
  existence-only check the app never spawns) â€” so
  `tools/patch_autoclaw2_identity.ps1` (new, AutoClaw2 [13] / gid 78,
  `-WaitForClose`/`-Restore`/`-Force`) does NOT need the asar-surgery route:
  it splices THREE byte-anchors, each verified to occur exactly once in the
  14.3 MB bundle, making the AUMID and window icon env-driven
  (`setAppUserModelId`, the per-window `setAppDetails` `appId`/`appIconPath`
  â€” the `relaunchCommand` backtick literal is never touched â€” and the main
  window's `setIcon`). `launch_autoclaw2_clone.ps1` now sets
  `ZWORK_AUMID=com.zhipuai.autoclaw2.cN` (matching the SHORTCUT AUMIDs, so
  pins and windows group together) + `ZWORK_CLONE_ICON=<the tinted
  tray_icon.ico>` per clone; with no env set the patched bundle behaves
  stock, so bare/Primary launches are untouched. Idempotent with a sibling
  backup `main.cjs.bak-zwork-identity-<stamp>`, a sha256 marker, a
  `node --check` gate through the app's own vendor node, verify-after with
  auto-restore, and fresh-backup re-apply after app updates;
  `install_autoclaw2_clone_shortcuts.ps1` gained `-RepairPrimaryAumid`
  (EC-C01). Tests: `tests/autoclaw2_identity_patch.Tests.ps1` (8 â€” the
  splice core is AST-extracted verbatim and the REAL spliced fixture is run
  under node both with and without the env). Window TITLE stays the shared
  "AutoClaw" (renderer `<title>` re-override is out of scope).
- **AutoClaw2 MCP + chat sync suite** (2026-11-04): the dead-session design
  (docs/AUTOCLAW2_SYNC_{SPEC,PLAN,TASKS}.md) is implemented on closed profiles
  only â€” `tools/autoclaw2-mcp.master.json` (device MCP manifest, definitions
  only, seeded from the ZCode Primary working set) + `tools/sync_autoclaw2_mcp.ps1`
  (GHOST.bat AutoClaw2 [8] / gid 73, launcher pre-launch step [2b]) writing
  connected-sources rows via the new `src/python/ghost/autoclaw2.py` core
  (merge preserves clone-local `enabled` toggles and never deletes; rows stay
  `pending` for the app to test; clean backup + `-RestoreBackup`; verify-after
  + JSONL audit), and `tools/sync_autoclaw2_chats.ps1` (AutoClaw2 [9]/[10] =
  gids 75/76) for the read-only cross-profile chat inventory and the guarded
  one-way history import (fresh UUIDv4 ids incl. `work_events`, `[import]`
  title prefix, IM sessions refused, sidecar idempotency + `-Revert
  -ImportId`). 39 unittests + lean Pester orchestrator suite + harness scenario
  U green. Live acceptance (A1-A7 / C2-C7) stays gated on the supervised
  Phase 0 spikes; the MCP watcher row is deferred with gid 74 reserved.
- **MCP central registry + one-way sync to every app** (2026-11-04):
  `tools/mcp/master-mcp.json` (25 servers, single source of truth) + gitignored
  `master-mcp.local.json` overlay (device values, local wins) + the
  `tools/sync_mcp_registry.ps1` importer (Maintenance [4] / gid 77) pushing
  definitions into ZCode Primary, Windsurf, VS Code and MiniMax in each app's
  own config shape (Cursor auto-skips until installed; OpenCode clones sync
  once their configs exist). Merge preserves app-local enable/disable state and
  never deletes app-only servers; secrets stay as `${VAR}` names resolved from
  machine env â€” all 20 were set from the apps' own working values, so the
  written files contain zero placeholders; every write is backed up to
  `MCP_Backups\<ts>\`, verify-after deep-compared, and audited to JSONL. Live
  run 2026-11-04: windsurf +17, vscode +18, zcode +7, minimax +19 adds, all
  app-only servers kept, second run idempotent. Harvest direction:
  `tools/mcp/collect_mcp_inventory.ps1` (read-only, 109 definitions across all
  hosts) â€” promotion into the master stays a per-name human decision. Plan:
  `docs/MCP_CENTRAL_REGISTRY_PLAN.md`.
- **ZCode clone launches persist their console output to a log** (2026-11-03):
  `launch_zcode_second_instance.ps1` appends every run to
  `tools\logs\launch_zcode_<Instance>.log` via a PowerShell transcript (one
  file per instance, `-Append` with invocation headers) â€” the auto-closing
  GHOST.bat launcher windows (ZCode [1]-[6]) and the hidden Desktop/Start-menu
  shortcut launches no longer lose their output: the ram-guard question and
  answer, seed/telegram/sync step results, spawn PID and taskbar stamping are
  all reviewable after the fact. Logging is fully best-effort: a transcript
  failure prints a yellow warning and never blocks the launch, and
  `Stop-Transcript` runs before the ram-guard `exit 0` paths and at script
  end. GHOST.bat ZCode [6] also prints the log location after opening the
  five windows.
- `tests/patch_surgery.Tests.ps1` â€” runs the surgery module's selftest
  (synthetic asar with text/binary/empty/deduplicated-twin/unpacked entries,
  round-trip rebuild + verify + corrupt-header abort) and the pickle-framing
  probe; 5 tests.
- **ZCode patch [27] waits for you to close the app** (2026-10-31):
  `patch_zcode_icon_override.ps1` gained `-WaitForClose` (GHOST.bat ZCode
  [27] passes it via `:RunWith`'s new optional extra-args slot) â€” when
  ZCode.exe is running from the install dir the script no longer throws and
  forces a manual re-run; it prints the running PIDs, polls until every one
  has exited (two consecutive clear probes, 30-min default timeout, Ctrl+C
  to abort) and continues straight into the patch. Direct runs without the
  switch keep the bare throw; `-Restore` honors the switch too. The [27]
  follow-up note now reminds about relaunching via the ZCode shortcuts (a
  bare ZCode.exe opens the PRIMARY profile).
- **OpenCode patch [8] waits for you to close the app** (2026-10-31):
  `patch_opencode_clone_home.ps1` gained `-WaitForClose` (GHOST.bat OpenCode
  [8] passes it via `:RunWith`'s extra-args slot, mirroring ZCode [27]) â€”
  when OpenCode.exe is running from the install dir the script no longer
  throws and forces a manual re-run; it prints the running PIDs, polls until
  every one has exited (two consecutive clear probes, 30-min default timeout,
  Ctrl+C to abort) and continues straight into the patch. Direct runs without
  the switch keep the bare throw; `-Restore` honors the switch too. The [8]
  follow-up note now reminds about relaunching via the OpenCode shortcuts (a
  bare OpenCode.exe opens the PRIMARY profile).

### Changed
- **AutoClaw2 sync: the last flipped source healed + the Primary is now a sync
  target** (2026-11-06): cloudinary was the one stdio source still flipping to
  `invalid_response` at every app start while every other source rendered
  green â€” the stored-row zod (`IL`) refines each tool's serialized
  `inputSchema` to â‰¤16384 chars (`inputSchema_too_large`), stricter than the
  registration walk the sanitizer mirrored, and cloudinary's `upload_asset`
  serializes to 20,024 chars; one over-limit tool fails the WHOLE row parse.
  `_sanitize_input_schema` now measures the CLEANED schema (UTF-16-exact
  `JSON.stringify` units) against 16384 and drops over-limit tools
  (live: `cloudinary: connected (41 tool(s))` â€” `upload_asset` is the honest
  cost), and `strict_row_problems` mirrors the refine so verify-after can
  never wave such a row through. `-Target Primary` (previously blocked by the
  two-account ambiguity: dormant `27e33829â€¦` + live `68f7331fâ€¦`) now
  disambiguates â€” explicit `-Account <hint>` (exact hash or unique prefix)
  wins, otherwise the newest-`runtime.sqlite` account is picked LOUDLY; a
  sub-60 s tie still refuses. The fresh-account bootstrap's single
  re-stamped `schema_migrations` row (`0001â€¦/85/2e8dc336â€¦`) is accepted by
  the schema gate as a second legitimate history encoding
  (`FRESH_STAMP_BASELINE`); any other single-row shape still refuses. First
  Primary sync: 10 rows â€” 6 connected + 4 honest OAuth auth-failures. Spec
  Â§9.2 records the full incident. 148 unittests green. Same day the master
  manifest merged the FULL ZCode Primary set (20 servers, merge-not-replace â€”
  the 10 ZCode-disabled ones added enabled per developer decision; live result
  per profile: linkedin Â·5 + github_local Â·26 + notion connectedÂ·0 (server
  exposes no tools with the legacy NOTION_TOKEN env) + honest failures for
  omniroute (local router down) and the 8 unauthenticated http sources), and a
  programmatic credential-wiring session closed the auth story without any UI
  clicking: the app's credential custody (`<account>/runtime/credentials.enc`,
  Electron safeStorage = v10 + AES-256-GCM under a per-profile DPAPI'd
  Chromium OSCrypt key, key = [ownerId, "source:<ws>:<slug>", version], value
  = token string) was replicated from Python and wired with the ZCode config's
  live tokens across all three signed-in profiles; the omniroute local router
  was started (`omniroute serve`, port 20128) and its command wrapped in the
  cmd.exe .cmd-shim pattern â€” final state **10 connected / 10 honest-failed
  per profile** (github/vercel authenticate through the wired custody but the
  app's own startup discover then fails â€” vercel's 633 KB catalog is 2.4Ã— its
  hard 256 KB cap, impossible on 4.0.0; github's clean replay leaves it an
  app-side quirk â€” runtime Reconnect may still succeed; stale sentry/cloudflare
  tokens fail auth until recreated). `discover_http` gained an optional
  `headers` parameter for credentialed pre-tests; spec Â§9.2.1/Â§9.2.2.
- **AutoClaw2 clone runs un-bricked + sync schema gate follows the app** (2026-11-05):
  every c1/c3 run died in ~1 s with `resource_revision_corrupt (cause: content)` â€”
  one CAS blob whose content hash â‰  its filename (the same wrong-content fingerprint
  sits in c1, c3 and Primary's dormant account; the app's own quarantine fails EPERM
  on the all-ReadOnly store, so it can never self-heal). Healed live by overwriting
  the blob with a verified-clean copy from the Primary's fresh account (backup +
  hash verify-after; c1 ping completed with a model request; full procedure
  documented in `docs/AUTOCLAW2_SYNC_SPEC.md` Â§9.1). The same day the 4.0.0 update
  moved the runtime DB schema 80â†’85 as an append-only multi-row migration history,
  which made the sync's single-row gate refuse every profile and the launcher's
  pre-launch step [2b] a silent no-op â€” `ghost/autoclaw2.py` `check_schema` now
  requires an intact baseline row + our column sets instead of exactly one row (4
  new unittests; live acceptance `[SKIP] c1 - running`), and
  `launch_autoclaw2_clone.ps1` gained `-SkipMcpSync` plus a loud warning when the
  sync refuses. **Never `-RestoreBackup` across the migration** â€” the sync backups
  are whole-DB schema-80 copies and would down-migrate the runtime DB.
- **AutoClaw2 MCP sources now sync pre-tested and usable** (2026-11-05): the
  "The server returned an invalid response." on every synced source is fully
  explained by the 4.0.0 bundle â€” the app strictly parses each
  `governed_connected_sources` row and `pending` (what the sync used to write)
  is not a legal status, so every row rendered through a fallback that
  hardcodes that message and the GUI's Reconnect threw before any network
  call. The source test is local (spawn/fetch), so `ghost/autoclaw2.py` now
  runs the same discovery per source (stdlib MCP stdio handshake +
  Streamable-HTTP) and writes what the app accepts: `connected` + real
  `tools_json` (IL shape, vme-normalized tool names, synthesized descriptions,
  oversized schemas dropped) + a `native.` revision, or `failed` + a legal
  error_code. Legacy `pending` rows are rewritten even when the definition is
  unchanged, illegal slugs migrate in place (`chrome_devtools`,
  `supabase_masarx`), verify-after requires the app's strict row shape, and
  untrusted workspaces warn loudly (tools are not offered in runs until the
  workspace is trusted). OAuth http sources (Vercel / GitHub Copilot / Sentry
  / Upstash) land as `authentication_failed` â€” sign in per clone, then
  Reconnect. Spec Â§9 records the full mined contracts. 129 unittests (incl. a
  real stdio MCP server fixture) + Pester 73/73.
- **The asar patches now take seconds, not minutes** (2026-11-03): the ZCode
  icon patch [27] (engine v9) and the OpenCode clone-home patch [8]
  (engine v4) share a new `tools/asar_surgery.mjs` IO layer that replaces the
  old extract/repack pipeline (`npx @electron/asar extract` of the ~340 MB /
  ~32k-file archive to %TEMP%, up to 4 repacks in a sidecar-convergence loop,
  one npx spawn per patched-file verify). The engine now ranges-reads only the
  text entries straight out of `app.asar`, applies the same patch anchors in
  memory, rebuilds the candidate in one streaming pass â€” untouched payload
  region copied byte-for-byte, patched contents appended at the tail, only the
  patched header entries rewritten (integrity recomputed) â€” and fully verifies
  it (header walk + whole-region byte compare + patched-content compare) in
  the same node process. The sidecar `app.asar.unpacked` is never touched
  (swaps run with a new `-SkipUnpackedSwap`); `npx` is no longer needed at
  all. Measured live: ZCode [27] ~6 s end-to-end (was minutes), OpenCode [8]
  ~2.5 s; patched-file output proven byte-identical to the previous engines'
  on the real pristine asars of both apps. Those numbers come from a dev box
  with no antivirus. On machines with Defender/AV we expect roughly 10-60 s
  (estimate, not measured), and the relative improvement is likely larger
  there: the old pipeline's per-file scan overhead across ~32k extracted
  files and the npx first-run npm download are gone entirely, and the
  ~290 s regex cost that dominated every machine was pure CPU.
  `node --check`, marker/backup/restore, update-recovery probing and all
  abort gates unchanged. Note on safety of the approach itself: every
  patched build through v8 boots normally, which is only possible with
  Electron's `EnableEmbeddedAsarIntegrityValidation` fuse off - replacing
  `app.asar` has been safe so far; re-confirm after the v9 live run and at
  each future acceptance.
- **Patch hardening for AV-protected machines** (2026-11-03): both patch
  drivers now retry the asar swap up to 6 times (300 ms apart) when antivirus
  briefly holds the freshly written ~340 MB candidate - retrying on
  IOException AND UnauthorizedAccessException (Access denied), including
  PowerShell-wrapped InnerExceptions. ZCode's swap is rename-based
  (app.asar -> app.asar.old -> candidate in -> delete .old, rename-back on
  failure), so the install is never left without an app.asar; OpenCode keeps
  its live-proven delete + locked-asar in-place fallback order. A free-disk
  preflight aborts cleanly with MB numbers before anything is written and
  models the true peak: backup + candidate coexist on one volume (~2.6x the
  asar size when install and %TEMP% share a volume, split 2.3x install /
  1.3x temp across volumes; -Restore staged copy + move-in likewise).
  Verified by Pester tests that hold the file with FileShare.None: a ~1 s
  lock succeeds after retries, and a lock outlasting the window rolls back
  with the original app.asar intact.
- **Pre-existing perf bug fixed while measuring**: the ZCode `preload-blue`
  patch anchor matched with a per-position backtracking regex that cost
  ~290 s across the bundle (the silent bulk of the old [3/7] step) â€” it now
  uses a literal-needle indexOf + backward receiver scan (byte-identical
  output). The OpenCode `clone-identity` anchor got the same treatment
  (regex-equivalence unit-proven over tricky receiver/argument shapes).
- **Colors are now the ONLY user-facing clone names** (2026-11-03): GHOST.bat
  rows (`Launch Blue clone` / `Reset Red clone` / `Launch Yellow clone` for
  ZCode, AutoClaw2, Cline and OpenCode) and the suite scripts' console output
  (ram-guard, seed, telegram-route, reset banners and per-step tags, sync
  headers and tags, taskbar/MCP watcher logs, shortcut installers, status
  lines) lead with the COLOR vocabulary, matching the shortcut file names
  unified on 2026-11-01 â€” the frozen keys (Second..Sixth, c1..cN) survive
  only in CLI params, dirs, AUMIDs and log filenames, and in identification
  lines as `Color (key)` / `Color / key` so params and docs stay
  correlatable. `.lnk` Description metadata is color-led too; the suite
  generator templates teach the pattern to future suites.

### Fixed
- **A stray click can no longer freeze the reset console's output** (2026-11-04):
  QuickEdit selection (a click or click-drag inside the console window) blocks
  all console writes until a key is pressed â€” during a Fifth reset the output
  appeared stalled at the terminate step while the script kept running
  underneath. `reset_zcode.ps1` now drops `ENABLE_QUICK_EDIT_MODE` from its
  console's mode at startup (best-effort, other flags preserved, the
  elevated-relaunch child gets it too) and says so in a dim line. Ctrl+S
  display pause is a host feature that cannot be disabled â€” any key resumes
  it; same recovery family as the `[DBG]:` tip below.
- **The reset console now explains the `[DBG]:` debugger state** (2026-11-03):
  pressing Ctrl+Break during a reset drops PowerShell's console host into its
  "Break All" debugger (`Entering debug mode` + an `[DBG]:` prompt) with no
  on-screen guidance â€” it looks like the reset crashed although the script is
  healthy (verified: zero `Write-Debug`/`Set-PSDebug` in the repo, `-NoProfile`
  on both spawn paths, clean `[OK]` output immediately before the break).
  `:RunZcodeReset` now prints a one-line tip BEFORE running: the `[DBG]:`
  prompt means Ctrl+Break was pressed, `q` + Enter quits, and the menu item
  can simply be re-run (an interrupted reset stopped before the identity
  rewrite, so re-running is safe).
- **ZCode clone shortcuts hung invisibly at the RAM guard** (2026-11-01):
  the Desktop/Start-menu shortcuts run the launcher with `-WindowStyle
  Hidden`, whose hidden-console stdin is NOT redirected â€” so the guard's only
  non-interactive probe (`[Console]::IsInputRedirected`) passed and the
  `Launch anyway? (y/N)` prompt was written into a window nobody could see:
  at/over `-MaxConcurrent` the launcher hung invisibly and ZCode never
  appeared (looked like the app failed to run). The guard now routes by entry
  point: `-NonInteractive` or redirected stdin warns and continues (unchanged
  watchdog/harness contract), a visible console (GHOST.bat,
  Launch-ZCode-*.bat) keeps the Read-Host prompt, and a hidden console gets a
  topmost Yes/No dialog (default No, same live commit numbers). Fixed
  launcher-side so already-installed shortcuts need no reinstall;
  `watch_zcode_captcha.ps1` relaunches pass `-NonInteractive` (also closing a
  latent hang â€” the hidden watchdog console could block on the old prompt).
- **ZCode light worker + T3 bridge died at bootstrap after the 0.17.1 CLI
  update** (2026-10-31): every plain-node launch of
  `resources\glm\zcode.cjs` (`-p`, `app-server`, `login` â€” the bundle's
  `nbs()` argv gate demands the builtin provider config for all three) failed
  with `æ— æ³•å®šä½ CLI ZCode Built-in Provider Config`: the bundle's
  `resolveBundledZCodeBuiltinProviderConfig` fallback derives both candidates
  from `process.argv[1]` via a dev-monorepo climb (`glm\provider\
  zcode-builtin.json` â€” removed from the package; then `5Ã— ..\config\provider\`
  landing at `%USERPROFILE%\AppData\config\provider\` â€” never exists) and
  never reaches the packaged file at `resources\config\provider\
  zcode-builtin.json`. Fixed with the FIFTH env lever
  `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` (the same override the desktop app
  injects into its own CLI children, and which `watch_zcode_captcha.ps1`
  already sets): `launch_zcode_cli_light.ps1` resolves it after the four
  isolation levers (bundled install copy first, newest
  `<home>\.zcode\v2\runtime\provider` runtime-cache copy as fallback, clear
  fail-fast when neither exists) and the printed standalone-login recipe gained
  the matching fifth `set` line; the T3 bridge suite gets the same lever via
  `resolveBuiltinProviderConfig` + `buildChildEnv`/`spawnAppServer` in
  `tools/t3_bridge_lib.mjs` (bridge + probe + fake client in one spot), which
  now fails fast with an English message instead of letting the child die on
  the opaque Chinese error. Desktop instances and the Primary CLI were never
  affected (the app injects the env itself). Docs: ZCODE_LIGHT_MODE.md
  (five-lever contract + regression note + login recipe), AGENTS.md, T3
  bridge spec Â§8.
- **GHOST.bat ZCode submenu section headers printed CMD errors** (2026-10-30):
  `call :Div "Sync & Chat Refresh"` (row [17]) and `call :Div "Watchers &
  Diagnostics"` (row [24]) rode a bare `&` into `:Div`'s unquoted
  `echo   -- %~1 --`, so CMD split on it â€” the menu showed `-- Sync` then
  `'Chat' is not recognized as an internal or external command` (and
  `-- Watchers` â†’ `'Diagnostics' not recognized`). Labels reworded to
  `Sync + Chat Refresh` / `Watchers + Diagnostics` (row style already avoids
  `&`); rem comment synced; AGENTS.md .bat rules gained the `&`-through-
  label-arg bullet. The harness now guards the whole class: a static S0b
  scan (no `&` in `:Div`/`:Hdr`/`:Opt` label args, every `&` on an `echo`
  line caret-escaped) plus a global assertion inherited by every scenario
  that CMD error output never leaks into captured menu output.
- **OpenCode 2.2.5.0 broke the clone suite â€” engine v3 re-derived and the
  fleet is live again (2026-11-01)**: the updater replaced `app.asar`
  wholesale on 2026-10-31 (2.2.5.0, 235 MB â€” marker + prior backup gone),
  and the v2 clone-home byte anchor (the 2.0.32 `isPackaged?void 0:...`
  ternary tail) had ZERO sites in the new bundle â€” the patch aborted with
  zero damage (fresh pristine backup kept) and c1..c5 were unlaunchable.
  Recon of the new bundle showed the mechanism intact: the bootstrap
  test-root fn (minified `ue()`, was `ye()`) reads
  `process.env.OPENCODE_DESKTOP_TEST_ROOT` (1 occurrence) and â€” new in
  2.2.5.0 â€” the SAME bootstrap fn (`z()`) pins `userData`/`sessionData`
  inline straight from its return, so v3 shrinks the hook to ONE slot: the
  clone-home argv scan slotted into the non-onboarding branch ahead of the
  env fallback (the onboarding `rmSync`-wipe branch stays first); the
  clone-identity regex matched 2.2.5.0 unchanged (`g.setAppUserModelId(le)`
  â€” 1 site). Re-patched (marker v3 + `node --check` + candidate/live
  signature verify) and live-verified: c1 launched with
  `OpenCodeClonesHome\c1\{desktop,session}` receiving all writes, window
  title "OpenCode Blue" observed live, and the Primary profile snapshot
  diff = **0 changes** (1338 files path|size|mtime identical before/after).
  A stale "run OpenCode [7]" citation fixed to [8] in AGENTS.md. Spec
  gained the engine v3 addendum (docs/OPENCODE_CLONES_SPEC.md).

### Changed
- **Menu label naming unified (2026-10-31)** â€” one row pattern across every
  submenu: the label carries the action + name ONLY, and the color + all
  qualifiers live in the tail. ZCode reset rows [9]-[13] had the color inside
  the label (`Reset Third instance - Yellow`) while the launch rows kept it
  in the tail, and [9] had no color at all â€” all five now read
  `Reset <Name> instance` + `- <Color> (survivors kept running)`; the
  dash-descriptors embedded in labels moved to tails ([22] `Refresh chats -
  ALL instances` â†’ `Refresh ALL chats`, [27] `Re-apply app patch - v8â€¦` â†’
  `Re-apply app patch` + `- v8, icons + bidi auto (after app update)`, [28]
  `Login clone account - one-time plan setup` â†’ `Login clone account` +
  `- one-time plan setup (light workers + T3 bridge)`); ZCode [6]'s tail now
  matches the other suites' phrasing (`- Second..Sixth, one after another`).
  Section placement unified: OpenCode `Install clone shortcuts` moved from
  Maintenance into Launch Clones [7] (matching AutoClaw2/Cline), the patch row
  moved to Maintenance [8] â€” locals [7]/[8] swapped, gids 59/60 unchanged.
  NEW row: ZCode [29] `Remove clone shortcuts` (gid 72,
  `install_zcode_second_shortcuts.ps1 -Remove`) â€” ZCode was the only suite
  without one; dispatch header widened to 1-72. Naming-scheme rule documented
  (AGENTS.md .bat rules): ZCode clones keep their legacy NAMES
  (Second..Sixth â€” dirs/shortcuts/`ZCode <Color>` titles frozen), newer
  suites use `c1..cN`, and `clone` is the unified docs term. The
  `:RunZcodeReset` note no longer cites the nonexistent "ZCode Color"
  shortcuts. Docs truth sweep: the four stale "AutoClaw2 is CLI-only / not
  wired into GHOST.bat" claims fixed (README, getting-started Ã—2,
  architecture) to cite main [4] rows [1]-[9]; cli.md ZCode range [1]-[29]
  + `IDE Resets` casing + OpenCode equivalents (patch [8], shortcuts [7])
  + the [29] cite; AGENTS.md header, `blue, Second` typo, complete
  Fifth/Sixth shortcut list, `c1..c5`, `clone slots`â†’`clones`, playbook
  palette gains Sixth orange `#CB5D06`; README table rows now quote the
  exact GHOST.bat labels. Harness: O retargeted (patch [8], shortcuts [7])
  + M asserts the new [29] row.
- **Clone shortcut display names unified to `<Suite> <Color>.lnk`
  (2026-11-01)**: one naming vocabulary across all four clone suites â€” the
  desktop/Start-menu shortcuts are now `ZCode Blue` .. `ZCode Orange`,
  `Cline Blue..Orange`, `OpenCode Blue..Orange`, `AutoClaw2 Blue..Orange`.
  Color is the only vocabulary already shared by every suite (per-color
  icons, `<suite>-<color>-branding` dirs, and the app-patched `ZCode <Color>`
  / `OpenCode <Color>` window titles), so the shortcut name now equals the
  window title. All four installers gained LEGACY cleanup: the pre-rename
  names (ZCode `Second..Sixth`, others `c1..c5`) are deleted on every
  install AND `-Remove` run, so a rename never orphans .lnks. Technical keys
  stay frozen: `-Instance` values (ZCode Second..Sixth, others c1..c5),
  clone-home dirs, AUMIDs (ZCode suffixes `2..6`), `-Target` values, window
  titles; the alias map (Secondâ†”c1â†”Blue â€¦) is documented in AGENTS.md and
  the playbook. `Launch-ZCode-Second/Third/Fourth/Fifth/Sixth.bat` wrappers
  renamed to `Launch-ZCode-Blue/Yellow/Green/Red/Orange.bat` (git mv; the
  `-Instance` argument inside is unchanged); GHOST.bat notes + the
  `:StartClone`/`:Detached` console titles now speak the color vocabulary
  too (`ZCode Second Instance` â†’ `ZCode Blue`, `Cline c1` â†’ `Cline Blue`,
  â€¦); docs swept (cli.md, getting-started, troubleshooting, architecture,
  AGENTS.md, playbook, launcher comment). Applied live: all four installers
  run on the dev host, leaving exactly the five color-named shortcuts per
  suite on Desktop + Start menu.

### Removed
- **AutoClaw v1.20 suite sunset â€” code removed from the tracked repo
  (2026-10-31)**: the v1.20 app was uninstalled from the dev host
  2026-10-29 and `GHOST.bat` main [4] was rewired to the AutoClaw2 suite
  the same day; the dead machinery now leaves the tree entirely â€”
  `src/windows/launch_autoclaw_clone.ps1`, `src/windows/reset_autoclaw.ps1`,
  `src/windows/Launch-AutoClaw-Clone.bat`,
  `tools/install_autoclaw_clone_shortcuts.ps1`,
  `tools/patch_autoclaw_ports.ps1` + `.mjs` (engine v12),
  `tools/autoclaw-{blue,yellow,green,red}-branding/` and
  `docs/AUTOCLAW_CLONES_SPEC.md`. Recoverable from git history (last full
  presence: 874346f and its descendants) or the gitignored local copy at
  `archive/autoclaw-v1.20/`. Docs scrubbed to sunset notes: AGENTS.md
  (conventions section compressed, layout tree, playbook suites list),
  README, architecture, cli, docs/README, the AutoClaw2 spec sibling refs,
  playbook/edge-cases, TASK_BACKLOG (BS-1/BS-2/CS-4 â†’ MOOT),
  ZCODE_RESET_EDGE_CASES_PLAN F-11, and the tool headers that cited the
  removed files. `tools/new_clone_suite.ps1` GHOST.bat anchor fixed â€” it
  still matched the retired "AutoClaw Multi-Instance" render line and would
  have thrown on any future scaffold run ("AutoClaw2 Multi-Instance" now).

## [1.3.0] - 2026-10-30

### Added
- **T3 bridge first live incident + hardening (2026-10-29 ~23:30)**: T3
  threads on unlogged clone homes hung ~4 minutes ("Failed to open provider
  session") â€” diagnosed from T3's own provider event logs
  (`~/.t3/userdata/logs/provider/events.<threadId>.log`): initialize +
  session/new succeeded, the PROMPT hung in the free-model 11-attempt retry
  loop. The bridge now (1) passes the home's known default model to
  `session/create`, so an unmaterialized provider fails FAST with
  `login_required` guidance pointing at GHOST.bat ZCode [28] (non-registry
  failures fall back to the server default with a loud warning), and (2)
  carries a 180 s turn watchdog (`session/stop` + `turn_watchdog` error
  instead of an endless hang). Fake client gains the fast-fail branch
  (unlogged home passes in seconds); Pester 56/56.
- **T3 bridge phases D-E + login helper (2026-10-29 evening)**: the bridge now
  advertises models on the `session/new` response (T3's generic acpRegistry
  provider reads the TOP-LEVEL `models` field â€” the initialize
  `_meta.modelState` path is Grok-only, per `compat.ts`/`runtimeModel.ts` in
  the study clone), sourced from the home's `v2\config.json` enabled
  providers (plan families also registered under their `account:<family>`
  runtime namespace) + live `state.updated` patches; `session/set_model`
  (v1 name verified) unpacks `"providerId/modelId[/level]"` into ZCode's
  `session/setModel`; usage-limit classification keys on the structured
  `errorCode`. `launch_zcode_cli_light.ps1 -Login` (GHOST.bat ZCode **[28]**,
  gid 71) runs the one-time `zcode login zai` per clone home with
  defaultModelSelection verify-after. **T3 Code v0.1.4 installed**
  (`winget install T3Tools.T3Code`) and the five accounts pre-seeded into
  `~/.t3/userdata/settings.json` (`providerInstances`, driver `acpRegistry`,
  `source: "local"`, node.exe + bridge + `--Instance <name>`, displayName
  "ZCode <Color>" + accent) â€” backup + verify-after, confirmed loaded in the
  server trace. Spec Â§9 carries the user-supervised live-acceptance runbook
  (its step 2 needs the [28] login or an upstream model recovery). Pester
  56/56; harness 19/19.
- **T3 ZCode bridge implemented (phases A-B, 2026-10-29)**: `tools/t3_bridge_lib.mjs`
  (shared: instance map, four env levers, wire-version gate following the
  minified export chain, NDJSON connection), `tools/t3_bridge_probe.mjs`
  (phase-A live protocol probe with transcript + event-catalogue artifacts),
  `tools/t3_zcode_bridge.mjs` (the ACP v1 â‡„ ZCode Protocol bridge: v1-shaped
  initialize that pins T3's generation detection, session/new with the five
  permission modes advertised, async session/send + event streaming
  (part.delta text/reasoning chunks, tool_call updates, permission forwarding
  via the per-option MF decision objects), cancel-before-terminal forced to
  `cancelled`, -32009 revision self-healing via session/read, mandatory
  `session/requestRuntimePreferences` answered minimally, default-decline
  elsewhere, optional `--model provider/modelId[/level]`), and
  `tools/t3_bridge_fake_client.mjs` (the phase-B acceptance harness). Live
  findings recorded as spec Â§8 addendum: workspace is an object
  (`{workspacePath, workspaceKey}`), session/send is async (terminal arrives
  via `v4/telemetry/event turn.terminal` + `turn.completed/failed` events),
  `session/subscribe` is REQUIRED before events flow, `state.updated` patches
  carry the authoritative revision, the plan provider only materializes via
  standalone `zcode login zai` (`provider/refreshRegistry` does not), and
  every free zen model rejected upstream that day (one retried 11Ã— for
  >150 s) so text-delta paths are bundle-schema-derived. Hard gates verified
  live: v1-shape initialize, five modes, prompt round-trip, cancelâ†’stop,
  clean exit, stdout purity. `tests/t3_bridge.Tests.ps1` (Pester 56/56 incl.
  the live-gated fake-client run; CI skips it â€” no clone home there).
- **T3 Code local support: study clone + two specs** (2026-10-28): cloned
  pingdotgg/t3code (MIT, 1016 MB on disk at `C:\programming\github\t3code`,
  HEAD 9826dbb990, read-only reference â€” no pnpm install, never committed
  here) so GHOST can support its own apps in T3 Code locally without waiting
  for upstream PR merges. `docs/T3_LOCAL_SUPPORT.md` = support matrix (ZCode â†’
  bridge; OpenCode â†’ T3-native provider; AutoClaw/Cline/desktop IDEs â†’ not
  agent CLIs, documented rationale) + local-vs-upstream split.
  `docs/T3_ZCODE_BRIDGE_SPEC.md` = the ACP v1 â‡„ ZCode Protocol NDJSON bridge
  spec with provenance tables on both sides (ACP transports/negotiation from
  the official docs AND the clone's own source: `AcpSessionRuntime.ts`
  initialize `{protocolVersion:2, clientCapabilities, clientInfo}`,
  `effect-acp/client.ts` response-SHAPE-based v1/v2 generation detection,
  `AcpRegistrySupport.ts` local-command spawn `{command, args, cwd, env,
  shell:false}`; ZCode Protocol from bundle probes: NDJSON envelope without a
  jsonrpc member, `startup/*` + `runtime/capabilities` handshake,
  session method map, serverâ†’client requests incl.
  `interaction/requestPermission`, error codes, `session/setModel`/`setMode`)
  â€” architecture (one bridge process per clone account, four env levers,
  no fs/terminal capabilities since ZCode runs its own tools), full mapping
  tables, seven edge cases (stdout purity, same-home db contention, wire-
  version signature gate, standalone-login prerequisite, revision
  discipline), a phased A-E implementation plan with acceptance criteria, and
  the upstream strategy (ACP Registry entry first; a full
  `packages/provider-zcode` driver only if the generic ACP surface loses
  features â€” replay-fixture bar per the clone's adding-a-provider.md;
  CONTRIBUTING.md policy noted). Bridge implementation = next task.
- **ZCode light mode: headless per-account workers + desktop RAM guard**
  (2026-10-28; spike-verified â€” docs/ZCODE_LIGHT_MODE.md): the 16 GB box
  cannot hold all six desktop instances (the 2026-09-25 renderer-OOM freeze
  was commit-limit exhaustion), so the fleet now has a light path and a guard.
  `src/windows/launch_zcode_cli_light.ps1` (GHOST.bat ZCode [27], gid 70)
  runs a clone's account headless via `resources\glm\zcode.cjs` under the
  system node â€” interactive REPL, `-Prompt` one-shot or `-Server` stdio worker
  â€” with full per-home isolation (HOME+USERPROFILE+ZCODE_DATA_BASE_DIR+
  ZCODE_STORAGE_DIR), ~0.9 GB commit vs ~1.6 GB+ per desktop instance, and
  sessions shared with that clone's desktop app. Verified limits are recorded
  in the launcher header and the doc: the interactive TUI cannot run
  standalone (@zcode/tui is asar-locked; ELECTRON_RUN_AS_NODE disables asar),
  and a home without a one-time standalone `zcode login zai` runs tasks on the
  free opencode-zen model instead of the Start Plan (the launcher detects this
  and prints the login recipe; the working plan provider namespace
  `account:zai-start-plan` was discovered from the Primary db's model_usage).
  `launch_zcode_second_instance.ps1` gains a soft `-MaxConcurrent 3` RAM guard
  (live commit numbers + confirm; non-interactive callers warn+continue so
  watchdog/harness callers never hang; focus-relaunches never prompt) and an
  experimental `-LowRam` (`--disable-gpu`). T3 Code (pingdotgg) was evaluated
  as a "merge all accounts into one window" target and DEFERRED: no ZCode/Z.ai
  provider, single-provider multi-account is still an open feature request
  there, and an ACP â†” app-server bridge would be permanent maintenance against
  an early-stage third-party app (its one zero-effort win: the OpenCode fleet
  is natively supported). Docs: ZCODE_LIGHT_MODE.md, cli.md ZCode [27],
  README table + layout, AGENTS.md conventions. Harness scenario S covers the
  new menu row (19 scenarios); repo-integrity auto-derives the 1-70 range.

### Changed
- **GHOST.bat AutoClaw submenu rewired to the AutoClaw2 (zwork) suite**
  (2026-10-29): the v1.20 app was uninstalled from the dev host and its
  ~2.2 GB of remnants (gateway state, clone homes, a 769 MB staged updater,
  dead shortcuts, Temp diagnostics) cleaned, so main menu [4] is now
  "AutoClaw2 Multi-Instance & Clones" - items [1]-[9] = launch c1..c5 /
  launch all-five / install clone shortcuts / clone status / remove clone
  shortcuts, mapping to the reused gids 28-36. The v1.20 items (launch/reset
  inst1..4 + Primary, ports-patch v12 re-apply, status) left the menu and
  dispatch cases 37-40 + 71 were retired; the underlying v1.20 scripts stay
  in the repo for hosts that still run v1.20 (run them directly). IDE Resets
  [9] "Reset AutoClaw" was removed with it (Resets is [1]-[8]; no
  renumbering). AutoClaw2 needs no reset script (stop the instance + delete
  its clone home) and no ports patch (in-process engine). Docs: cli.md,
  APP_CLONING_EDGE_CASES EC-A01, AGENTS.md. Harness: scenario H retargeted
  to the AutoClaw2 render (19 scenarios).
- **GHOST.bat submenu ids renumbered to display order** (2026-10-29): every
  submenu's local ids now run strictly ascending 1..N in visual order,
  grouped by `:Div` sections â€” the old ZCode submenu carried out-of-sequence
  rows (19/21 inside the reset block, launchers 18/22 inside the sync block)
  and Cline appended c4/c5 after Launch ALL. ZCode: Launch Clones [1]-[8]
  (Second/Third/Fourth/Fifth/Sixth, ALL [6], light worker [7], shortcuts
  [8]) / Reset Clones [9]-[16] (Second..Sixth, Primary [14], Both [15],
  ALL SIX [16]) / Sync & Chat Refresh [17]-[23] / Watchers & Diagnostics
  [24]-[26] / Maintenance [27] (icon patch [27]); Cline: Launch [1]-[7]
  (c1..c5, ALL [6], shortcuts [7]) / Maintenance [8]-[9]; the two
  hand-inlined separator lines became `call :Div`. **Gids are unchanged** â€”
  a renumber touches only the echo blocks + resolver ladders, so every gid
  citation in specs, wiring history and repo-integrity stays valid (the
  AutoClaw2 rewiring above reused 28-36 on its own). Docs synced: cli.md,
  getting-started, troubleshooting, README, AGENTS.md (+ a display-order
  rule bullet in the .bat rules), ZCODE_CHAT_SYNC_WATCHER_PLAN,
  ZCODE_LIGHT_MODE, ZCODE_RESET_EDGE_CASES (renumber translation note),
  APP_CLONING_EDGE_CASES, AUTOCLAW_CLONES_SPEC; script headers
  (launch_zcode_second_instance, launch_zcode_cli_light, sync_zcode_assets,
  watch_zcode_mcp_sync). Harness: rows F/M/N/R/S retargeted to the new
  numbers + a static ascending-ids guard per submenu (scenario count
  unchanged at 19).

### Fixed
- **Blank clone shortcut icons on Desktop/Start Menu/taskbar (AutoClaw2 +
  Cline suites) - two stacked root causes** (2026-10-29): (1) the installed
  .lnk files carried a RELATIVE IconLocation (`tools\<suite>-branding\
  tray_icon.ico`) that Windows can never resolve - a bare-filename
  `$MyInvocation` fallback could yield a relative repo root at install time;
  both shortcut installers now resolve `$RepoRoot` through `Resolve-Path`,
  refuse non-absolute roots, and their verify-after additionally re-reads the
  IconLocation (must be absolute + exist) alongside target/AUMID; all 20
  shortcuts reinstalled with absolute icon paths. (2) `tools/make_clone_icon.ps1`
  wrote PNG-compressed frames for EVERY ICO size, but PNG frames are
  shell-legal at 256 only - small PNG frames decode as noise/blank in
  Explorer and System.Drawing (every suite the generator produced was
  affected: autoclaw v1, autoclaw2, cline, opencode; the zcode ICOs were
  always correct DIBs). The generator now writes 32-bit BGRA DIB frames below
  256 + a PNG frame at 256 with a frame-magic verify gate, and all 19
  branding ICOs were regenerated from their existing masters. Verified
  through the real shell pipeline (SHGetFileInfo on the .lnk): colored logos
  render. Housekeeping: removed the dead v1.20 AutoClaw implicit taskbar pin
  left behind by the app uninstall.

## [1.2.0] â€” 2026-10-28

### Added
- **Open-task survey: tracked task backlog + four planning specs**
  (2026-10-28): the 2026-10-24 bug-sweep remediation state lived only in
  gitignored local folders; `docs/TASK_BACKLOG.md` now carries the tracked
  status of every open item (the five write-guard-blocked files incl. 2
  CRITICALs with ready-to-apply staged diffs, the pending qoder/watchers/trae
  scopes, ZCode W1, the migration queue, clone-suite future work, ops backlog)
  â€” spot-checked against the current tree, several stale pending items marked
  DONE-since-source. New specs: `BUG_SWEEP_REMEDIATION_PLAN.md` (finish the
  sweep: re-verify-before-apply rule, per-file procedure, acceptance gates),
  `OPENCODE_CONFIG_SYNC_PLAN.md` (definitions-only Primaryâ†’clone config sync,
  secrets never copied), `CLINE_WINDOW_IDENTITY_PLAN.md` (launcher-side window
  stamping design, developer-deferred), `THIN_MANIFEST_MIGRATION_QUEUE_PLAN.md`
  (per-script breakdown for the remaining five resetters with the
  fix-before-migrate gate); docs/README.md index updated.
- **Docs re-baseline: every doc brought up to the six-instance /
  engine-v8 / MCP-sync-trio state** (2026-10-28): README + docs/README +
  cli/architecture/getting-started/troubleshooting refreshed with the Sixth
  clone, ZCode [24]-[26] MCP sync trio, diagnose_zcode_throttle.ps1
  (CLI-only), spoof_wmi_serials.ps1 (Maintenance [3]), the
  Cline/OpenCode/AutoClaw2 suites and cross-links to their specs;
  ZCODE_TELEGRAM_BOTS.md instance counts updated to 6 homes (faq.md
  audited â€” its answers reference the README platform table, no counts to
  change);
  AGENTS.md + GHOST.bat [12] engine label v7 -> v8;
  ZCODE_RESET_EDGE_CASES_PLAN.md menu labels and status refreshed.
  Historical v7 mentions kept where they document what shipped at the time.
- **Install-and-forget watchers: the clone launcher ensures the resident
  watchers** (2026-10-27): users who only install the clones never open
  GHOST to start watchers manually, so launcher step 2e now runs on EVERY
  clone launch (menu, Desktop/Start shortcuts, Launch ALL â€” all route
  through launch_zcode_second_instance.ps1) and ensures both main watchers:
  the MCP sync watcher and the taskbar identity watcher. Mechanism per
  watcher: a mutex probe (no WMI, microseconds) detects "already running";
  a missing Startup .lnk is installed once via the watcher's own
  -InstallAutostart (which verify-after reads back); then the watcher
  starts hidden via Start-Process with a pre-quoted -File argument (PS 5.1
  ArgumentList joins unquoted). Best-effort by contract: any failure warns
  and never blocks the launch; duplicates are converged by each watcher's
  own mutex guard. The captcha watchdog stays manual (ZCode [13]) â€” its
  kill/relaunch intervention and Telegram wiring make it a poor
  auto-start default. Scope decided with the developer (MCP sync +
  taskbar; start-now + autostart).
- **ZCode MCP sync: add in ONE place (Primary), every clone gets it live**
  (2026-10-27): a 15-agent verification pass (app.asar disassembly + logs of
  all six instances) proved the long-standing "a live app may rewrite its
  config on exit" guard rationale FALSE â€” the app holds no handle on
  `<CloneHome>\.zcode\cli\config.json`, never rewrites it on exit (its own
  writes are event-driven atomic tmp+rename), and reads `mcp.servers` at
  every app-server spawn, one per new session (6-41 bootstraps/day per
  instance). New: `tools/zcode_mcp_merge.ps1` â€” the pure merge core
  extracted from sync_zcode_assets.ps1's Sync-McpDefinitions (unit-tested by
  `tests/zcode_mcp_merge.Tests.ps1`: clone-local enabled toggles survive,
  clone-only servers are never removed, new servers inherit the Primary's
  enabled value, Primary definitions win, key-order-insensitive deep
  compare); `tools/sync_zcode_assets.ps1 -McpOnly` â€” MCP-definitions-only
  sync that is safe against RUNNING instances (skills/plugins keep the
  old skip); `tools/watch_zcode_mcp_sync.ps1` â€” resident watcher (taskbar
  watcher pattern: named mutex ZcodeMcpSyncWatcher + startup process scan +
  self-titling console + Startup-folder autostart) that invokes the sync
  child on every Primary config change (mtime+size signature, parse-guarded,
  debounced), converges all drift on its first pass and re-verifies deeply
  every ~5 min, with opt-in `-ApplyLive` recycling running instances'
  app-servers after a sync (idle-guarded, never mid-turn, never -Force).
  Wired as GHOST.bat ZCode `[24]` (one-shot live sync, gid 67), `[25]`
  (resident watcher, gid 68) and `[26]` (sync + apply to running instances
  now, gid 69); dispatch header range 1-66 -> 1-69. The watcher itself never
  writes config â€” every write goes through sync_zcode_assets.ps1's backup +
  verify-after + JSONL audit.

### Fixed
- **Launcher step 2d pre-launch sync never ran** (found 2026-10-28 by a
  live launch test): `$SyncScript = Join-Path $PSScriptRoot '..\tools\...'`
  resolved to `src\tools\` from the launcher's home in `src\windows\` â€”
  the sync script lives at the repo-root `tools\`, so every launch printed
  the quiet yellow "not found - skipping (clone stays as last synced)" line
  and the pre-launch asset sync had effectively never executed since the
  scripts moved into src/windows (OSS restructure v1.0.0). Branding's
  step 3b always used the correct `'..\..\tools\'` depth, proving the
  inconsistency. Fixed the path for 2d AND for the new step 2e watcher
  paths (same trap).
- **ZCode taskbar watcher auto-repair dead since 2026-09-28**
  (2026-10-25): the resident watcher DETECTED every Primary shortcut hijack
  (ZCode.lnk rewritten with a clone AUMID + wiped icon â€” the Start-menu
  dedupe hiding a clone entry + the white taskbar icon) but its repair
  never ran: inside Invoke-PrimaryHijackGuard the local
  `$repair = Join-Path ...` assignment targeted the function's own
  `[switch]$Repair` parameter (PowerShell variables are case-insensitive),
  and binding the script-path string to a switch parameter throws
  "Cannot convert ... to SwitchParameter" â€” 228 identical logged failures
  before a diagnostic line captured the exception's InvocationInfo pointing
  at the assignment. Renamed to `$repairScript`; auto-repair verified live
  ([REPAIR] log line + clean ZCode.lnk read-back on both Desktop and Start
  Menu).
- **ZCode icon-override patch silently skipped after app updates**
  (2026-10-24): the app updater replaces app.asar wholesale but leaves the
  marker file in resources\, so patch_zcode_icon_override.ps1's
  "marker exists" gate exited as "Already patched" and every clone lost its
  in-app window + tray icons after an update (taskbar shortcut icons
  survived since they never needed the patch). The script now byte-probes
  app.asar for the engine's signature strings before the gate: signatures
  present -> unchanged already-patched early exit; signatures missing ->
  automatic re-patch without -Force, plus a FRESH backup of the new pristine
  asar (reusing the original backup would have let a later -Restore
  downgrade the app to the pre-update version).
- **Icon-override engine v8: updater-secondary anchor tolerated on app
  3.16.3** (2026-10-24): the 3.16.3 build added a second conjunction to the
  auto-updater gate (enabled:<x>==="production"&&<flag>), so the v7 exact
  anchor matched zero sites and aborted the whole re-patch after 9 of the 10
  patch families had already applied (the engine refuses half-applied trees). v8 matches the bare and conjunct shapes
  and appends the ZCODE_ICON_DIR guard as an extra && term; marker
  patchVersion bumps to 8 so the next run auto-upgrades older markers.
- **AutoClaw port/identity patch same update-recovery hardening**
  (2026-10-24): the 1.20.0.887 update replaced app.asar AND removed
  autoclaw-ports-patch.marker.json + ID_Backups, so re-running
  patch_autoclaw_ports.ps1 would have treated the install as never patched
  (fine) but a marker that DID survive would have dead-locked the gate like
  the ZCode case. The script now byte-probes the asar for the v12 signature
  strings (__autoclawWrapBW, .autoclaw-identity.json, __autoclawHomeOverride,
  "19684, 19685" - all engine-emitted; a docstring-derived phantom string,
  .autoclaw-icon.ico, was caught in review: it only ever exists as a runtime
  userData file, never inside the asar) before the gate, re-patches
  automatically when they are missing,
  takes a fresh timestamped backup of the new pristine asar, and gates the
  -Force pristine-extract on the probe instead of a findstr test (after an
  update the new asar must be the extract source, not the old backup).
  Dry-run verified against the live 1.20.0.887 asar: engine v12 applies all
  four families (mcp-ports-8slot 1, home-override 569, aumid-suffix 2,
  window-identity 4).

### Added
- **ZCode Start-Plan throttle diagnostic â€” `tools/diagnose_zcode_throttle.ps1`**
  (2026-10-27, read-only): explains the "Reconnecting... x/10" /
  "The system is busy, and automatic retries have reached the maximum
  count" failures from the shared agent runtime JSONL
  (`~\.zcode\cli\log\zcode-*.jsonl`, which every instance writes to). It
  lists `model.main_turn.retry_start_plan_admission_busy` retries and
  `turn.failed` entries with their cause chain
  (`StartPlanBusyAutoRetryExhaustedError` â†’ `providerCode 3009` "model
  concurrency limit exceeded" / `model_rate_limited`, `maxAttempts 11` â€”
  the UI's x/10 counter), builds an hourly histogram (local time) and a
  per-session rollup, and the verdict spells out the finding that settled
  the day's incident: server-side Start Plan admission control refusing
  new streams under load â€” NOT a device/IP ban (auth + billing unaffected;
  different accounts failed in the same minute; zero occurrences on
  10-24..26) â€” plus the discrimination test (close all instances but one)
  and the concurrency mitigations. `-Days N` widens the window; PS 5.1
  parse-checked and live-validated against the 2026-10-27 logs.
- **WMI hardware-serial spoof â€” `src/windows/spoof_wmi_serials.ps1`**
  (2026-10-27, Maintenance `[3]` / gid 66, behind a `:ConfirmRun` gate): the
  one portable technique from a Hydra Spoofer 1.5.5 review, rewritten to the
  GHOST bar (the source's Python was not taken â€” bare excepts, zero
  verify-after, f-string MOF generation, a wrong `Win32_BaseBoard` key). A
  generated `.mof` redeclares `Win32_BIOS` / `Win32_BaseBoard` /
  `Win32_ComputerSystemProduct` / `Win32_SystemEnclosure` /
  `Win32_DiskDrive` / `Win32_PhysicalMemory` with `[DYNPROPS]` (real CIM key
  properties, escaped literals, real instance keys) and compiles via
  `mofcomp`, so WMI clients read spoofed serials; plus `SQMClient UserId`
  and Bluetooth `LocalAddress` rotation (`-SkipBluetooth`) â€” the two
  identity values GHOST had no coverage for. Backup-first
  (`winmgmt /backup` aborts the run on failure), verify-after re-query as
  the arbiter, audit log, generated `winmgmt /restore` script. Deliberately
  excluded: CPU/GPU (Phase 5 + out of scope), `DigitalProductId`
  randomization (activation risk), volume serials (license + unproven
  signal â€” backlog in docs/WMI_SERIAL_SPOOFING.md). WMI layer only â€” does
  not move the fingerprint self-test score (ground truth #4).
- **ZCode Sixth clone (orange) â€” 6-instance suite** (2026-10-24): a fifth
  branded clone joins the suite, bringing ZCode to parity with the other
  suites (Primary + 5 clones) â€” instance `Sixth`, window title "ZCode
  Orange", home `%USERPROFILE%\ZCodeSixthHome`, roaming
  `%APPDATA%\ZCode-Sixth`, AUMID `dev.zcode.app.6`, accent `#CB5D06`
  (derived from the blue accent by the same hue rotation that produced
  Fifth's `#CA0607`), icon via `tools/zcode-orange-branding/` (blue master
  +180Â° hue-rotate through `tools/make_clone_icon.ps1`). Wired everywhere
  the four older clones are: launcher `-Instance Sixth` (+
  `Launch-ZCode-Sixth.bat`), shortcuts installer (five clones now;
  `ZCode Sixth.lnk`), taskbar watcher, captcha watchdog, chat refresher
  (`-Target ...|Sixth|All`), asset sync (`-Target ...|Sixth|All`), bot
  guardian (`tools/set_zcode_bot.ps1`), reset (`-Target Sixth`, `All` =
  Third+Fourth+Fifth+Sixth+Secondary+Primary), freeze diagnostic, and
  GHOST.bat ZCode submenu `[22]`/`[23]` (gids 64/65; the launch-all and
  reset-all flows cover Sixth).
- **OpenCode desktop multi-instance suite (c1..c5)** (2026-10-24): a
  complete clone suite for OpenCode desktop (Electron 2.0.32, asInvoker,
  `%LOCALAPPDATA%\Programs\@opencode-aidesktop`) beside the untouched
  Primary (`%APPDATA%\ai.opencode.desktop` + `~\.local\share\opencode` +
  `~\.config\opencode` â€” the latter holds live API keys and is never read
  by clone scripts). Unlike AutoClaw2/Cline, packaged builds have NO env
  lever for the userData (`OPENCODE_DESKTOP_TEST_ROOT` is unpackaged-only;
  `OPENCODE_TEST_ONBOARDING` wipes its root every boot), so isolation runs
  through the one-time clone-home asar patch
  `tools/patch_opencode_clone_home.ps1` + `.mjs` (engine v1): the argv
  flag `--opencode-clone-home=<dir>` feeds the app's OWN `ye()` test-mode
  branch, which pins userData/sessionData per clone AND sets the four
  `XDG_*` env vars (the app's own redirection surface, read
  unconditionally in production) before the background-service spawn; the
  per-clone userData also gives each clone its own Chromium
  single-instance lock (N copies coexist natively). The same patch wraps
  the app's SINGLE `setAppUserModelId` site (taskbar AUMID
  `ai.opencode.desktop.cN`) and registers an app-level
  `browser-window-created` listener that stamps window AUMID + per-color
  icon + "OpenCode <Color>" title (this app has no `new X.BrowserWindow(`
  sites â€” imports are aliased â€” so the AutoClaw-v12 constructor subclass
  does not apply; the event is the equivalent hook). Engine carries the
  full safety set: marker + patchVersion, `-Restore`, `node --check`,
  zero-site abort, and the update-recovery byte-probe (an app update
  reverts the patch; the probe re-patches automatically with a FRESH
  backup). Launchers `src/windows/launch_opencode_clone.ps1` /
  `launch_opencode_clones_all.ps1` (sequential): patch-signature preflight
  ABORTS unpatched installs, per-clone lockfile running guard, identity
  marker + icon rewritten fresh each launch, detached start + verify-after.
  Shortcuts `tools/install_opencode_clone_shortcuts.ps1` (Desktop + Start
  menu, suffixed AUMIDs, `-Remove`, `-RepairPrimaryAumid`). Orange (c5)
  generated as a PLACEHOLDER via `make_clone_icon.ps1 -HueRotate 180` from
  the blue master. No seeding, no reset script (Cline model): fresh state
  per clone, ONE manual sign-in each. GHOST.bat submenu [6] OpenCode
  Multi-Instance & Clones (gids 53-62); harness extended to 17 scenarios.
  All anchors statically verified against the installed asar; LIVE-VERIFIED
  2026-10-24/25: engine v1â†’v2 upgrade path proven (the main bundle is ESM â€”
  no `require` â€” so v1's fs-based identity resolver silently no-oped and v2
  moved identity to pure argv flags), locked-asar in-place swap fallback +
  two-tier core/current signature probe landed from the same session, all
  five clones verified (per-clone lockfiles HELD simultaneously, every
  Chromium child on its own --user-data-dir, "OpenCode Blue"/"Orange"
  window titles, ephemeral per-instance service ports â€” no port plan
  needed), the updater stages 2.1.4 without installing (darwin-only
  autoInstallOnAppQuit; patch survived), and the Primary snapshot diff
  showed only the live user session's own artifacts â€” 0 clone-breach
  signatures. One manual login per clone remains the developer touchpoint.
- **Cline multi-instance suite (c1..c5)** (2026-10-24): a complete clone
  suite for the standalone Cline desktop app (Tauri 2.11.1 + WebView2,
  no asar) beside the untouched Primary `~\.cline` (120-file snapshot
  diff = 0 across the whole verification session). Isolation is 100%
  env-based and live-verified: `CLINE_DIR` (whole state tree),
  `WEBVIEW2_USER_DATA_FOLDER` (per-clone web login profile),
  `CLINE_HUB_PORT` + `CLINE_SIDECAR_PORT` (per-clone ports 25471-25475 /
  3131-3135, outside the stock defaults and the stock hub probe range
  25463..25466). The app's tauri-plugin-single-instance guard (fixed-key
  mutex `bot.cline.app-sim` + hidden window `bot.cline.app-sic`/`-siw`)
  is defeated WITHOUT patching: the second copy only exits when
  FindWindowW finds the hidden window, so the launcher renames it
  (`.neutralized`) pre- and post-launch with verify â€” 3 clones verified
  running concurrently this way. The launcher itself enforces per-clone
  single-instance (aborts on the clone's own held hub lock, since the
  app-level guard is neutralized). Fresh profile per clone â€” ONE manual
  sign-in each (identity: HKLM MachineGuid is shared, account identity
  lives in the clone's `data\secrets.json` only). Taskbar identity is
  shortcut-AUMIDs-only by developer decision (no patchable surface; pins
  distinct via `bot.cline.app.cN`, running windows share the base
  identity). New files: `src/windows/launch_cline_clone.ps1`
  (+`-Status`), `src/windows/launch_cline_clones_all.ps1` (sequential,
  honest fixed-stagger docs), `tools/install_cline_clone_shortcuts.ps1`
  (Desktop + Start Menu, per-clone icons, suffixed AUMIDs, `-Remove`),
  `tools/cline-orange-branding/` (5th color, tint-generated from the
  blue master â€” hue-rotate rejected: the two-tone logo would produce the
  rejected green family), `docs/CLINE_CLONES_SPEC.md` (spec +
  provenance), GHOST.bat submenu [5] Cline Multi-Instance & Clones
  (gids 44-52; harness extended to 14 scenarios). Pester + parse checks
  green.
- **AutoClaw2 multi-instance suite (c1..c5)** (2026-10-23): a complete
  clone suite for the v2.1.1 redesign (zwork) beside the existing v1.20
  inst1..4 system, with zero writes into any pre-existing install/profile
  (v1.20 Primary, its clones, and the v2.1.1 Primary all preserved).
  Isolation via the app''s official env lever `ZWORK_USER_DATA` (pinned
  BEFORE `requestSingleInstanceLock()`; live-verified `acquired:true`
  x5) + `AUTOCLAW_PROFILE_ROOT` pointing at a per-clone migration root
  so clones never read a live Primary. asInvoker manifest verified (env
  survives; no UAC relay needed - unlike v1.20). Per-profile device
  identity is generated fresh by the app (device-id.json hashes verified
  6/6 unique), so no identity seeding and no credential copying: ONE
  manual sign-in per clone. New files:
  `src/windows/launch_autoclaw2_clone.ps1` (+`-Status`),
  `src/windows/launch_autoclaw2_clones_all.ps1` (sequential all-five),
  `tools/install_autoclaw2_clone_shortcuts.ps1` (Desktop + Start Menu,
  per-clone tinted icons, `-Remove`),
  `tools/autoclaw2-{blue,yellow,green,red,orange}-branding/`,
  `docs/AUTOCLAW2_CLONES_SPEC.md` (spec + provenance). Known limitation:
  running windows share the base AUMID (one taskbar button per grouping);
  shortcut AUMID suffix stamping deferred - the property-store write was
  denied on this host (documented, cosmetic only). GHOST.bat menu
  integration intentionally left to the developer (in-flight edits).
  Verified live: 6 concurrent v2.1.1 copies (Primary + c1..c5) beside
  v1.20 Primary + inst1, ~4.4 GB total RAM, no port conflicts.

- **ZCode submenu [21] â€” "Reset ZCode Primary instance"** (2026-10-23): a
  copy of IDE Resets [7] inside ZCode Multi-Instance & Clones, appended to
  the end of the Reset Clones block (every existing entry and number
  untouched). Both entries resolve to the same global id (gid 7 â†’
  `reset_zcode.ps1 -Target Primary`), so the Primary reset is reachable
  from either menu.

- **AutoClaw submenu [13] â€” "Reset AutoClaw Primary instance"** (2026-10-23):
  the same copy pattern as ZCode [21] â€” IDE Resets [9] ("Reset AutoClaw")
  cloned into AutoClaw Multi-Instance & Clones, appended to the end of the
  Reset Clones block (every existing entry and number untouched). Both
  entries resolve to the same global id (gid 28 â†’
  `reset_autoclaw.ps1 -Target Primary`), so the Primary reset is reachable
  from either menu.

- **CPU name spoof in `change_device_id.ps1` LegacyReset** (2026-10-18):
  Phase 5's last live item â€” writes a fictional `ProcessorNameString` to
  ALL `HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\*` subkeys
  (8-name realistic pool, `Get-Random`) so the fingerprint self-test's
  heaviest changeable signal (`cpu.name`, weight 0.12) actually moves,
  completing the documented 0.19 delta. Rides the existing
  backup/changelog/verify-after/rollback loop; `CentralProcessor.reg`
  exported to the backup dir and imported by the restore script; summary
  prints the new name. Accepted by the live user-supervised run the same
  day: `cpu.name` moved live (no reboot needed) â€” Phase 5 fully accepted.

- **ZCode Fifth clone (red) â€” 5-instance suite** (2026-10-17): a fourth
  branded clone joins the suite â€” instance `Fifth`, window title
  "ZCode Red", home `%USERPROFILE%\ZCodeFifthHome`, roaming
  `%APPDATA%\ZCode-Fifth`, AUMID `dev.zcode.app.5`, accent `#CA0607`.
  Branding lives in `tools/zcode-red-branding/` (blue master +150Â°
  hue-rotate via the new generic `tools/make_clone_icon.ps1` â€” identical
  geometry to the existing four icons). Wired end to end: launcher
  `-Instance Fifth` (+ `Launch-ZCode-Fifth.bat`), shortcuts installer
  (four clones now; `ZCode Fifth.lnk` live-verified), taskbar watcher,
  chat refresher (`-Target ...|Fifth|All`), reset (`-Target Fifth`,
  `All` = Third+Fourth+Fifth+Secondary+Primary), freeze diagnostic,
  Telegram bot guardian, and GHOST.bat ZCode `[18]` (gid 41; no
  renumbering â€” existing citations stay valid) with the launch-all and
  reset-all flows covering Fifth. First live launch is pending (the
  one-time seed needs the Primary closed â€” robocopy exit 9 otherwise;
  a partial seed is auto-detected and must be removed before re-running).

- **ZCode reset menu item for Fifth** (2026-10-17): GHOST.bat ZCode submenu
  gains `[19]` "Reset Fifth instance - Red" under `-- Reset Clones --`
  (gid 42 â†’ `reset_zcode.ps1 -Target Fifth`) â€” the individual reset that
  was previously CLI-only. No renumbering; existing citations stay valid.

- **Generic clone-icon generator `tools/make_clone_icon.ps1` +
  AutoClaw per-clone icons** (2026-10-17): app-agnostic icon pipeline
  (PS 5.1 + System.Drawing only): corner-sampled background detection â†’
  tile crop (`-BgTolerance`/`-ManualCrop`) â†’ rounded-corner alpha master â†’
  multi-size `tray_icon.ico` (16..256 PNG-in-ICO) + `icon_windows.png` +
  source provenance; `-HueRotate` derives clone colors. AutoClaw
  inst1..inst4 shortcuts now carry per-clone icons
  (`tools/autoclaw-{blue,yellow,green,red}-branding/` from
  developer-supplied renders; red = blue +150Â°; `bad-green` rejected by
  the developer), falling back to the exe icon when a branding dir is
  missing. **Full staged color suites** for the future opencode/cline clones
  (`tools/{opencode,cline}-{blue,yellow,green,red}-branding/`, all eight
  dirs with `tray_icon.ico` + 1024 master + `source.jpg` provenance â€”
  cline's unnamed renders assigned by measured dominant hue; `bad-green`
  excluded) â€” icons only, no launcher/reset wiring yet by design.

- **ZCode clone asset sync `tools/sync_zcode_assets.ps1`** (2026-10-17):
  every clone resolves its own user-scope config
  (`<CloneHome>\.zcode\cli\config.json` â€” the HOME override reaches the
  app's config resolution, unlike the shared CLI session db), so the
  one-time seed copies had drifted: all three seeded clones still ran the
  broken `npx @supabase/mcp-server-supabase@latest` entry, lacked `sentry`,
  had stale skill copies shadowing the shared `.agents` store, and missed
  newer plugin versions. The sync merges MCP server DEFINITIONS from the
  Primary (per-clone on/off toggles stay local; new servers carry the
  Primary's enabled value; clone-only servers are kept; plugins/hooks stay
  local), moves the stale `.zcode\skills` copies aside and junctions
  `<CloneHome>\.agents` â†’ `~\.agents` (live skills, no elevation), and
  robocopy-mirrors the plugin cache + marketplaces when the version set
  drifts (`plugins\data`/`cli\agents` stay per-instance). Running instance
  = skip + warn; unseeded home = skip note; backup + verify-after
  everywhere; JSONL audit per clone home. Wired as GHOST.bat ZCode `[20]`
  (gid 43; no renumbering) and as launcher step 2d (pre-launch sync, never
  blocks the launch). `-Target Second|Third|Fourth|Fifth|All` + `-DryRun`.

- **AutoClaw clone taskbar identity v2 (spec Â§7.3c) â€” IMPLEMENTED**
  (2026-10-17, live-verified 2026-10-18): separate taskbar buttons,
  colored window icons and "AutoClaw <Color>" titles per clone, in the
  taskbar AND the app itself. Shipped as two new families of the EXISTING
  `tools/patch_autoclaw_ports.ps1` branding patch (engine v11 at ship;
  v12 after the next-day fixes, see Fixed below): `aumid-suffix` wraps
  both `setAppUserModelId` call sites to declare
  `com.zhipuai.autoclaw.inst1..4` (equal to the shipped shortcut AUMIDs),
  and `window-identity` routes every `new BrowserWindow` through a
  subclass that stamps the window-level identity at creation time, sets
  the branded window icon and forces the title. Branding rides a marker
  file â€” `launch_autoclaw_clone.ps1` step 4c writes
  `<CloneProfile>\.autoclaw-identity.json` and copies the branded
  `.autoclaw-icon.ico` every launch (env vars die at the UAC boundary,
  marker files do not); a missing marker means stock behavior, so the
  Primary and bare native-host spawns are untouched. Live-verified on
  the first relaunch 2026-10-18: the EC-C07 property-store readback
  returns `com.zhipuai.autoclaw.inst1` on a live clone window.

- **Phase 3 continuation â€” reset_devin v0.4 thin manifest** (2026-10-17):
  the Windsurf/Devin reset's 17 steps (14 per data root Ã— Devin/Windsurf +
  3 global) run every store mutation through the core via `Invoke-GhostCore`,
  same contract as reset_cursor v0.3 (step order, audit keys, restore
  actions, summary identical to v0.3, archived at
  `archive/reset_devin_windows-v0.3.ps1`, local-only). New groundwork
  landed with it: `delete-secrets` generalized (optional exact_keys /
  like_patterns / `ESCAPE '\'` â€” the windsurf/devin auth patterns; defaults
  stay Cursor, zero caller breakage), `winstore.patch_argv_json` (JSONC
  regex â€” comments survive, crash-reporter-id replaced/inserted, username
  scrubbed), `winstore.replace_text` (raw-text scrub + absence verify) and
  `winstore.set_json_path` (dotted-path set with the absent-or-empty SKIP
  contract) + the `patch-argv` / `replace-text` / `json-set` subcommands.
  **No temp-.py heredoc remains in the cursor/devin thin manifests** (the
  repo's last heredoc — trae's ai-agent scrub — ships with the trae v0.3
  migration, 2026-11-14; this sentence was overbroad until then). Also fixed in both
  manifests: `delete-secrets` `survivors` is a per-pattern LIST â€” PS
  `array -eq 0` filters elements instead of answering "all zero", so
  non-zero survivors could pass the step (reset_zcode already used
  `Measure-Object -Sum`). Python required for all steps; 1419 â†’ 1003 lines.
  Live comparison run pending user supervision.

### Fixed

- **ZCode reset menu + watchdog hardening (partial)** (2026-10-23,
  docs/ZCODE_RESET_EDGE_CASES_PLAN.md): GHOST.bat confirms before the
  destructive multi-instance resets (gid 12 Both, gid 21 All-five; `choice`
  reads the console so chains and the .bat harness are unaffected), and every
  reset_zcode dispatch now prints the post-reset relaunch warning via
  `:RunZcodeReset` (bare ZCode.exe = Primary profile). ZCode [6] label
  pluralized; harness gains scenario M (reset-block render).
  tools/watch_zcode_captcha.ps1 snapshots running instances by process markers
  BEFORE its kill and relaunches clones via the launcher, Primary bare â€” the
  old blanket bare ZCode.exe relaunch repopulated only the Primary profile and
  silently voided every "survivors kept running" claim. The reset_zcode.ps1
  v1.5 script-side items (shared-db scrub [26b], strict backups, abort
  checkpoint, Python preflight, -DryRun, purge salvage, elevation exit-code
  propagation) are PENDING â€” blocked by a workspace write-guard false positive
  on [6b]'s apiKey-blanking line (user chose to defer).

- **AutoClaw2 clone icons recolored** (2026-10-23): the first branding run
  for the c1..c5 suite shipped five byte-identical `tray_icon.ico` files â€”
  the new app icon is a monochrome white logo and `-HueRotate` does
  nothing on gray art. `tools\make_clone_icon.ps1` gains a colorize mode
  (`-TintHue/-TintSat/-TintValueFloor`: set hue + saturation, keep value,
  dark tile background untouched), and all five
  `tools\autoclaw2-{blue,yellow,green,red,orange}-branding` dirs were
  regenerated with hues calibrated from the old autoclaw/zcode suites
  (blue 206 / yellow 46 / green 166 / red 356 / orange 25; measured hue
  deltas â‰¤0.1Â°, five distinct hashes, background mean within Â±1 RGB).
  Shortcuts already pointed at these paths (AUMIDs intact); icon cache
  refreshed. Pre-color set archived at
  `archive\autoclaw2-branding-precolor-20261023\`.

- **AutoClaw patch engine v12 â€” three live-verified fixes** (2026-10-18,
  found by the first live relaunch of the taskbar-identity v2):
  (1) the window-identity wrap called `setAppDetails({ appUserModelId })` â€”
  Electron 33's option key is **`appId`** (verified against the shipped
  binary), so the window-level AUMID was never stamped;
  (2) ctor-time stamping alone does not survive HWND recreation â€” the wrap
  now re-stamps on `show` and on every title re-assert; the EC-C07
  property-store readback now returns `com.zhipuai.autoclaw.inst1` live
  (previously `<EMPTY>`); and
  (3) `-Force` re-patch extracted the LIVE already-patched asar, whose
  wrapped anchors made the engine skip its own sites â€” old injected code
  silently survived re-runs while the marker timestamp refreshed. The tool
  now extracts the PRISTINE backup asar whenever the live file carries the
  wrap marker; engine bumped 11â†’12 so existing markers upgrade via the
  normal re-apply path.
- **AutoClaw launcher shipped clones without a window icon** (2026-10-18):
  `launch_autoclaw_clone.ps1` computed `$RepoRoot` one level short of the
  repo root (copied the tools/ one-parent pattern into a src/windows/ two-deep
  script) and looked for the tray icon under `src\tools\...` â€” every launch
  WARNed "icon source missing" and the clone identity went out iconless.
  Fixed; live-verified: icon copies + window shows it.

- **Window-stamping interop broke machine-wide** (2026-10-17): the
  Windows 10 19041.**7548** cumulative update (July 2026) **removed the
  `PropVariantClear` export from `oleaut32.dll`** â€” every `IPropertyStore`
  stamp/read (taskbar watcher, clone launcher step [4]) died instantly
  with `EntryPointNotFoundException`, and the resident watcher exited on
  its first pass since the API disappeared. Both call sites
  (`tools/watch_zcode_taskbar.ps1`, `src/windows/launch_zcode_second_instance.ps1`)
  now import `PropVariantClear` from **`ole32.dll`** (verified present:
  `ole32!PropVariantClear`; `oleaut32!PropVariantClear` = absent,
  `propsys!PropVariantClear` = absent). Watcher passes live-verified:
  Second/Third/Fourth re-stamped successfully.

### Changed

- **Docs re-baseline of stale deferred-task lists** (2026-10-18):
  `docs/IMPLEMENTATION_PLAN.md` Phase 5 re-checked against the current
  `change_device_id.ps1` â€” the 5 dead registry writes are already gone and
  the bcdedit item is retired (the current lineage has no RAM section, and
  `maxmem/truncatememory` never changed `TotalPhysicalMemory`, the signal
  actually scored); `docs/AUTOCLAW_CLONES_SPEC.md` Â§12 Definition-of-done
  boxes ticked with evidence dates (static gates re-run 2026-10-18:
  Pester 36/36, PSSA Error-clean; the open items are the multi-instance
  live verifications beyond inst1); `AGENTS.md` stale AutoClaw
  "not yet implemented" sentence corrected (taskbar identity v2 shipped
  2026-10-17). Same-day live closeouts: the CPU-spoof acceptance run
  changed `cpu.name` live (no reboot needed) â€” Phase 5 fully accepted;
  the AutoClaw taskbar-identity v2 EC-C07 window-AUMID readback observed
  live on the first relaunch; and the Phase 3 thin-manifest pilot was
  ACCEPTED by a live `reset_cursor.ps1` run (15/15 steps identical to the
  archived v0.2, audit + restore script verified) â€” remaining migrations
  per the roadmap order: trae â†’ qoderwork â†’ minimax â†’ qoder â†’ zcode last.

- **Docs â€” AutoClaw clone taskbar identity upgraded to a REQUIRED v2 design**
  (2026-10-17): the shared taskbar button is no longer the accepted end state.
  `docs/AUTOCLAW_CLONES_SPEC.md` Â§7.3c now requires separate taskbar
  buttons/window groups per clone (per-clone process AUMID
  `com.zhipuai.autoclaw.inst1..4` via an app.asar branding patch, aligned with the
  shipped shortcut AUMIDs) and the clone color icons visible BOTH in the taskbar AND
  in the app window itself. Branding config rides a `--user-data-dir` marker file
  (env vars do not survive the app's self-elevation); the window-level
  IPropertyStore stamp is the elevation-gated fallback. Implemented the
  same day (engine v11 â€” see the Added entry above) and live-verified
  2026-10-18; the v1 shortcut-AUMID-only identity is historical.
  `AGENTS.md`, `docs/APP_CLONING_PLAYBOOK.md` (intro + row 7 + Phase 8),
  `docs/APP_CLONING_EDGE_CASES.md` (EC-C06) and `docs/README.md` aligned.

## [1.1.0] â€” 2026-10-17

### Added

- **Python hybrid Phase 3 pilot â€” reset_cursor v0.3 thin manifest**
  (2026-10-17): the Cursor reset's 15 steps now run every store mutation
  through `src/python/ghost_cli.py` core subcommands via a single
  `Invoke-GhostCore` helper â€” new core modules `ghost/filesweep.py`
  (binary-store rename-or-delete, verified deletes, per-file tree sweeps)
  and `ghost/winstore.py` (machine-id file, device_id_salt rotation, dotted
  JSON key removal) plus 7 new subcommands (`backup`, `machineid-file`,
  `salt-rotate`, `json-remove`, `store-delete`, `sweep-file`, `sweep-tree`),
  all covered by the expanded unittest suite (58 cases incl. CLI bridge
  contracts). Step order, audit keys, restore actions and the summary are
  identical to v0.2 (archived at `archive/reset_cursor_windows-v0.2.ps1`,
  local-only); step 4's inline temp-.py heredoc â€” the last one in the repo â€”
  is replaced by the shared `delete-secrets` subcommand. Python is now
  required for ALL Cursor reset steps (fail-fast up front). 1031 â†’ 840
  lines. The mandatory live comparison run (pilot acceptance #3) is
  user-supervised and pending. Decision record + design:
  [docs/PYTHON_HYBRID_ROADMAP.md](docs/PYTHON_HYBRID_ROADMAP.md) (Phase 2
  leaf-tools migration CANCELLED with per-tool reasons).

- **Clone-suite generator** (`tools/new_clone_suite.ps1`, 2026-10-17) â€”
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

- **ZCode per-clone Telegram bots (UI-assisted, EC-D03)** â€” `tools/set_zcode_bot.ps1`
  (`-VerifyOnly` audit / `-Target <name> -Fix` backup-first sync): fingerprints
  the encrypted `credentials.json -> bot:<id>:credential` (`enc:v1:`, sha8
  only, never values) + bot id across BOTH `bot-config.json` and
  `bot-config.v3.json` in all 4 homes (the 2026-10-16 Fourth `v2=False /
  v3=True` split looked disabled while polling â€” both files are now always
  checked); fails loudly on any duplicate-while-enabled (HTTP 409 risk).
  `src/windows/launch_zcode_second_instance.ps1 [2c]` upgraded from
  always-disable to sha8-compare (duplicate -> disable both files; unique ->
  preserve + `.telegram-routed` v2 marker, never reverted). Flow: operator
  creates 3 BotFather bots, pastes each token once in that clone's ZCode UI
  (app mints fresh `bot-<guid>` + `enc:v1:`), tooling guards/syncs. Quota
  decision 2026-10-16: Option C â€” Fourth keeps its big quota isolated.
  Docs: [docs/ZCODE_TELEGRAM_BOTS.md](docs/ZCODE_TELEGRAM_BOTS.md); tests:
  `tests/set_zcode_bot.Tests.ps1` (4 passing).

- **AutoClaw multi-instance clones (Primary + inst1â€“inst4)** â€” full suite per
  [docs/AUTOCLAW_CLONES_SPEC.md](docs/AUTOCLAW_CLONES_SPEC.md):
  `tools/patch_autoclaw_ports.ps1` (+ `.mjs` engine v1) widens the installed
  app's hardcoded 4-slot MCP port array to 8 (backup + marker + `-Restore`,
  verified byte-identical via SHA-256 round-trip; re-run after every AutoClaw
  update); `src/windows/launch_autoclaw_clone.ps1` (-Instance inst1..inst4,
  `-Status`) launches clones with env-var isolation (`USERPROFILE`/`HOME`,
  `AUTOCLAW_GATEWAY_PORT` with actual-port read-back + drift recording) and a
  credential-free seed (tokens stripped, `token-cache.json` excluded, gateway
  state never copied â€” one manual login per clone) plus verify-after-launch
  health/port/pairing checks; `src/windows/reset_autoclaw.ps1` (-Target
  Primary|inst1..4|All, `-DryRun`) rotates both device identities (auth
  `deviceId` + ed25519 keypair via node:crypto) and deletes the live operator
  credential; `tools/install_autoclaw_clone_shortcuts.ps1` installs per-clone
  AUMID shortcuts with `-RepairPrimaryAumid`; `src/windows/Launch-AutoClaw-Clone.bat`
  double-click wrapper. GHOST.bat gains a fourth submenu (AutoClaw
  Multi-Instance & Clones [1]â€“[12], gids 29â€“40) and IDE Resets [9].
- **App cloning playbook docs** â€” [docs/APP_CLONING_PLAYBOOK.md](docs/APP_CLONING_PLAYBOOK.md)
  (the generic clone-any-app process: identity suite with a
  never-silently-degrade rule, developer-inputs contract, icon policy with
  improvise+report as the default for missing icons, phases 0â€“10
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
  restarts/Telegram escalations on the shared state file â€” the watcher now
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
  does not exist in pwsh's own directory â€” shortcuts created by a pwsh-run
  installer targeted a nonexistent exe. They now pin the OS-shipped
  `System32\WindowsPowerShell\v1.0\powershell.exe` and fail fast if absent.
- **block_qoder_domains corrupted non-ASCII hosts comments** (2026-10-17,
  local-only tool): the hosts round-trip read BOM-less bytes as UTF-8 and
  wrote with ASCII encoding, flattening every non-ASCII character to a
  permanent `?`. Read/write now both use the system ANSI codepage (BOM
  auto-detect still wins), matching how the Windows resolver reads hosts â€”
  single-byte-codepage content survives byte-exactly.
- **IDE Resets [9] dispatched the wrong task**: the Resets submenu had no
  localâ†’gid resolver, so typed ids reached `:DispatchOne` raw â€” local [9]
  "Reset AutoClaw" therefore ran global gid 9 (the ZCode captcha watchdog,
  already reachable as ZCode [11]) instead of gid 28
  (`reset_autoclaw.ps1 -Target Primary`). A `:ResetsOne` resolver now maps
  1â€“8 identity + 9â†’28, and both Resets dispatch sites route through it
  (the prompt loop and the main-menu chained input `1 9`); bare global ids
  from the main menu keep using `:RunChain`. Verified 2026-10-16: a
  harness extracted the shipped `:ResetsOne` verbatim and passed all five
  cases (1â†’gid 1, 8â†’gid 8, **9â†’gid 28**, unknownâ†’error, chained `9 2`â†’
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
  install paths) with `--version` and require an exit-0 "Python 3" report â€”
  the WindowsApps app-execution aliases (exit 9009, no interpreter), stale
  Python 2, and profile aliases are rejected. The `py` launcher and
  per-user installs are found even when an elevated `PATH` hides them;
  not-found messages now point at `winget install Python.Python.3.12`.

### Changed

- **Launcher menus renumbered to continuous local ids**: each `GHOST.bat`
  screen numbers its own tasks â€” Resets `[1]`â€“`[8]`, ZCode `[1]`â€“`[17]`
  (5 launch + 5 reset + 7 sync/watchers), Maintenance `[1]`â€“`[2]` â€” with
  per-screen resolvers (`:ZCodeOne` / `:MaintOne`) translating local ids to
  the unchanged global dispatch payloads. Chains typed inside a submenu use
  its local ids; `2 1 3 4` from the main menu opens ZCode and runs local
  `1 3 4` back-to-back (`PENDING_CHAIN` replaces the old `BACK` flow); bare
  global ids (`13`) still work from the main menu only â€” inside ZCode the
  local ids shadow the old global ones (old `[13]` icon patch is now
  ZCode `[12]`). Docs remapped in `AGENTS.md`, `docs/cli.md`,
  `docs/getting-started.md`, `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md`, and
  `docs/PLAN-2026-09-24-rebrand.md`.
- **UTF-8 piping for the Python core**: `ghost` forces its stdout to UTF-8
  and the PowerShell callers set `[Console]::OutputEncoding = UTF8`, so
  non-ASCII output (e.g. Arabic chat titles in `chat-check MISSING` lines)
  survives the pipe on any console code page.
- **`#Requires -Version 5.1` on every `.ps1`** in `src/windows` + `tools`
  (enforced by a new repo-integrity test) â€” standard error on archaeic
  hosts instead of mid-script syntax failures; PS 7 satisfies `>= 5.1`.
- **Python core extracted (de-duplicated bridges)**: the four embedded
  Python here-strings that lived inside PowerShell scripts now live in one
  stdlib-only package `src/python/ghost` invoked via
  `src\python\ghost_cli.py` â€” `Set-SqliteKeys` (identity_utils.ps1), the
  secrets-delete and CLI-telemetry bridges (reset_zcode.ps1), and the
  chat-sync helper (refresh_zcode_second_chats.ps1) no longer write temp
  `.py` files to `$env:TEMP`. Base64-in / JSON-stdout contracts, audit
  wording, and verify-after behavior are unchanged; per-call temp files are
  gone.
- **Launcher rebranded**: `how-to-run.bat` â†’ `GHOST.bat` and
  `how-to-run.sh` â†’ `ghost.sh`; all docs now reference the GHOST launcher by
  name. The direct-command cheat sheet moved from `how-to-run.txt` to
  [docs/cli.md](docs/cli.md), and the analyzer settings moved from the repo
  root to `tests/PSScriptAnalyzerSettings.psd1` (CI + test paths updated).
  Menu numbers are unchanged.

### Added

- **Python core** â€” `src/python/ghost/` (stdlib only: sqlite3, json,
  secrets, uuid) + `ghost_cli.py` bootstrap; owns the shared SQLite/JSON
  identity logic (identity sets, key UPSERT with verify-after re-read,
  secrets deletion, CLI telemetry scrub, chat-sync diff/hot-activity probe,
  JSON patch, audit log, restore-script generator). Tested by
  `tests/python/test_ghost_core.py` (30 stdlib `unittest` cases, mirrors the
  Pester suite + real-SQLite coverage) and a new CI `python-core` job.
- **GHOST launcher icon + shortcuts** â€” `assets/ghost.ico` (16â€“256, generated
  from the poster art by `tools/make_ghost_icon.ps1`: auto tile detection,
  rounded-corner transparency, committed `assets/ghost-source.png` master for
  regeneration). Since a `.bat` cannot carry an Explorer icon, the icon ships
  via `tools/install_ghost_shortcut.ps1` (menu [24]): `GHOST.lnk` on the
  Desktop and in the repo root, pointing at `GHOST.bat` (`.lnk` files are
  gitignored â€” regenerate, never commit).
- **ZCode multi-instance expansion** â€” Primary + three branded clones:
  **Second** (blue), **Third** (yellow), **Fourth** (green).
  - `launch_zcode_second_instance.ps1 -Instance Second|Third|Fourth` with
    per-clone homes (`ZCode{Second,Third,Fourth}Home`), roaming dirs
    (`ZCode-Second` / `ZCode-Third` / `ZCode-Fourth`), and first-run
    seed-clone + identity scrub; plus double-click wrappers
    `Launch-ZCode-Second/Third/Fourth.bat`.
  - `reset_zcode.ps1 -Target Third|Fourth|All` â€” per-instance resets with
    independent ID sets per child, per-target backups and scoped tree-kill
    (survivor instances keep running).
- `tools/patch_zcode_icon_override.ps1` (+ `.mjs` engine v6) â€” one-time
  `app.asar` patch enabling `ZCODE_ICON_DIR`, `ZCODE_AUMID_SUFFIX`,
  `ZCODE_ACCENT_HEX`, `ZCODE_INSTANCE_NAME` overrides (branded icon, separate
  taskbar button/pins, accent color, "ZCode <Color>" window title) and
  disabling the clones' auto-updater; marker file auto-upgrades older patches.
  Re-run after every ZCode app update (`GHOST.bat` menu [13]).
- `tools/install_zcode_second_shortcuts.ps1` â€” per-user Desktop + Start-menu
  shortcuts for all three clones, each with its own `System.AppUserModel.ID`
  so pins never collide with the Primary (`-Remove`, `-Instance`,
  `-RepairPrimaryAumid`); menu [14].
- `tools/refresh_zcode_second_chats.ps1` â€” cross-instance chat refresh
  without an app restart: finds shared-store chats missing from the target's
  sidebar index and recycles its app-server(s) (auto-respawn reseeds the
  index), with a multi-signal hot-activity guard and verify-after
  (`-Target Primary|Second|Third|Fourth|All`; menus [15]/[23]) plus an
  error-triggered `-Watch` daemon that refreshes every running instance on
  captcha-stall / quota / rate-limit failures (menu [22]). Supersedes the
  row-copying `test_live_inject.py` spike (deleted).
- `tools/zcode-{blue,yellow,green}-branding/` â€” per-clone icon assets
  (`icon_windows.png`, `tray_icon.ico`) and the shared generator.
- `GHOST.bat` menus [13]â€“[23]: icon patch, clone shortcuts, chat
  refresh (one-shot + watcher), clone launches (single + all), per-instance
  ZCode resets, and refresh-all.
- `tools/update_ghost.ps1` + `GHOST.bat` menu [26] â€” repo self-updater:
  fetches `origin`, compares HEAD with the remote default branch, lists the
  new commits, and asks before `git pull --ff-only` (`-CheckOnly` = report
  only). Refuses when local commits or a non-`main`/detached branch block the
  fast-forward; a dirty working tree gets an interactive stash â†’ pull â†’
  restore (a failed restore keeps the stash). Verify-after re-reads HEAD; a
  failed fetch (offline) is a warning, not a failure.

### Security

- Docs depersonalized: machine-specific home paths replaced with
  `%USERPROFILE%` in `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md` (newly tracked).

## [1.0.0] â€” 2026-09-21

First tagged release; the repository restructured to standard open-source
conventions. No reset-script behavior changes in this release except where
noted.

### Changed

- **Repository layout**: `scripts/` â†’ `src/`; docs consolidated; community
  files, tests, and CI added.
- **Filenames are unversioned** â€” versioning now lives in Git tags and this
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
  tracked** â€” they remain on disk as local-only rollback copies and are purged
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
  June 2026 Windsurf â†’ Devin Desktop rebrand â€” auto-detects and resets both
  `%APPDATA%\Devin` and `%APPDATA%\Windsurf` roots in one pass; scrubs
  `credentials.toml`, `config.json devin.org_id`, `cli\installation_id`,
  `.devin\argv.json`, and rebrand-era state.vscdb secret keys.
