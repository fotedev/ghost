# Changelog

All notable changes to GHOST are documented here. Versions are Git tags
(`vX.Y.Z`); script filenames are unversioned.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **T3 bridge first live incident + hardening (2026-10-29 ~23:30)**: T3
  threads on unlogged clone homes hung ~4 minutes ("Failed to open provider
  session") — diagnosed from T3's own provider event logs
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
  provider reads the TOP-LEVEL `models` field — the initialize
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
  "ZCode <Color>" + accent) — backup + verify-after, confirmed loaded in the
  server trace. Spec §9 carries the user-supervised live-acceptance runbook
  (its step 2 needs the [28] login or an upstream model recovery). Pester
  56/56; harness 19/19.
- **T3 ZCode bridge implemented (phases A-B, 2026-10-29)**: `tools/t3_bridge_lib.mjs`
  (shared: instance map, four env levers, wire-version gate following the
  minified export chain, NDJSON connection), `tools/t3_bridge_probe.mjs`
  (phase-A live protocol probe with transcript + event-catalogue artifacts),
  `tools/t3_zcode_bridge.mjs` (the ACP v1 ⇄ ZCode Protocol bridge: v1-shaped
  initialize that pins T3's generation detection, session/new with the five
  permission modes advertised, async session/send + event streaming
  (part.delta text/reasoning chunks, tool_call updates, permission forwarding
  via the per-option MF decision objects), cancel-before-terminal forced to
  `cancelled`, -32009 revision self-healing via session/read, mandatory
  `session/requestRuntimePreferences` answered minimally, default-decline
  elsewhere, optional `--model provider/modelId[/level]`), and
  `tools/t3_bridge_fake_client.mjs` (the phase-B acceptance harness). Live
  findings recorded as spec §8 addendum: workspace is an object
  (`{workspacePath, workspaceKey}`), session/send is async (terminal arrives
  via `v4/telemetry/event turn.terminal` + `turn.completed/failed` events),
  `session/subscribe` is REQUIRED before events flow, `state.updated` patches
  carry the authoritative revision, the plan provider only materializes via
  standalone `zcode login zai` (`provider/refreshRegistry` does not), and
  every free zen model rejected upstream that day (one retried 11× for
  >150 s) so text-delta paths are bundle-schema-derived. Hard gates verified
  live: v1-shape initialize, five modes, prompt round-trip, cancel→stop,
  clean exit, stdout purity. `tests/t3_bridge.Tests.ps1` (Pester 56/56 incl.
  the live-gated fake-client run; CI skips it — no clone home there).
- **T3 Code local support: study clone + two specs** (2026-10-28): cloned
  pingdotgg/t3code (MIT, 1016 MB on disk at `C:\programming\github\t3code`,
  HEAD 9826dbb990, read-only reference — no pnpm install, never committed
  here) so GHOST can support its own apps in T3 Code locally without waiting
  for upstream PR merges. `docs/T3_LOCAL_SUPPORT.md` = support matrix (ZCode →
  bridge; OpenCode → T3-native provider; AutoClaw/Cline/desktop IDEs → not
  agent CLIs, documented rationale) + local-vs-upstream split.
  `docs/T3_ZCODE_BRIDGE_SPEC.md` = the ACP v1 ⇄ ZCode Protocol NDJSON bridge
  spec with provenance tables on both sides (ACP transports/negotiation from
  the official docs AND the clone's own source: `AcpSessionRuntime.ts`
  initialize `{protocolVersion:2, clientCapabilities, clientInfo}`,
  `effect-acp/client.ts` response-SHAPE-based v1/v2 generation detection,
  `AcpRegistrySupport.ts` local-command spawn `{command, args, cwd, env,
  shell:false}`; ZCode Protocol from bundle probes: NDJSON envelope without a
  jsonrpc member, `startup/*` + `runtime/capabilities` handshake,
  session method map, server→client requests incl.
  `interaction/requestPermission`, error codes, `session/setModel`/`setMode`)
  — architecture (one bridge process per clone account, four env levers,
  no fs/terminal capabilities since ZCode runs its own tools), full mapping
  tables, seven edge cases (stdout purity, same-home db contention, wire-
  version signature gate, standalone-login prerequisite, revision
  discipline), a phased A-E implementation plan with acceptance criteria, and
  the upstream strategy (ACP Registry entry first; a full
  `packages/provider-zcode` driver only if the generic ACP surface loses
  features — replay-fixture bar per the clone's adding-a-provider.md;
  CONTRIBUTING.md policy noted). Bridge implementation = next task.
- **ZCode light mode: headless per-account workers + desktop RAM guard**
  (2026-10-28; spike-verified — docs/ZCODE_LIGHT_MODE.md): the 16 GB box
  cannot hold all six desktop instances (the 2026-09-25 renderer-OOM freeze
  was commit-limit exhaustion), so the fleet now has a light path and a guard.
  `src/windows/launch_zcode_cli_light.ps1` (GHOST.bat ZCode [27], gid 70)
  runs a clone's account headless via `resources\glm\zcode.cjs` under the
  system node — interactive REPL, `-Prompt` one-shot or `-Server` stdio worker
  — with full per-home isolation (HOME+USERPROFILE+ZCODE_DATA_BASE_DIR+
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
  there, and an ACP ↔ app-server bridge would be permanent maintenance against
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
  grouped by `:Div` sections — the old ZCode submenu carried out-of-sequence
  rows (19/21 inside the reset block, launchers 18/22 inside the sync block)
  and Cline appended c4/c5 after Launch ALL. ZCode: Launch Clones [1]-[8]
  (Second/Third/Fourth/Fifth/Sixth, ALL [6], light worker [7], shortcuts
  [8]) / Reset Clones [9]-[16] (Second..Sixth, Primary [14], Both [15],
  ALL SIX [16]) / Sync & Chat Refresh [17]-[23] / Watchers & Diagnostics
  [24]-[26] / Maintenance [27] (icon patch [27]); Cline: Launch [1]-[7]
  (c1..c5, ALL [6], shortcuts [7]) / Maintenance [8]-[9]; the two
  hand-inlined separator lines became `call :Div`. **Gids are unchanged** —
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

## [1.2.0] — 2026-10-28

### Added
- **Open-task survey: tracked task backlog + four planning specs**
  (2026-10-28): the 2026-10-24 bug-sweep remediation state lived only in
  gitignored local folders; `docs/TASK_BACKLOG.md` now carries the tracked
  status of every open item (the five write-guard-blocked files incl. 2
  CRITICALs with ready-to-apply staged diffs, the pending qoder/watchers/trae
  scopes, ZCode W1, the migration queue, clone-suite future work, ops backlog)
  — spot-checked against the current tree, several stale pending items marked
  DONE-since-source. New specs: `BUG_SWEEP_REMEDIATION_PLAN.md` (finish the
  sweep: re-verify-before-apply rule, per-file procedure, acceptance gates),
  `OPENCODE_CONFIG_SYNC_PLAN.md` (definitions-only Primary→clone config sync,
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
  audited — its answers reference the README platform table, no counts to
  change);
  AGENTS.md + GHOST.bat [12] engine label v7 -> v8;
  ZCODE_RESET_EDGE_CASES_PLAN.md menu labels and status refreshed.
  Historical v7 mentions kept where they document what shipped at the time.
- **Install-and-forget watchers: the clone launcher ensures the resident
  watchers** (2026-10-27): users who only install the clones never open
  GHOST to start watchers manually, so launcher step 2e now runs on EVERY
  clone launch (menu, Desktop/Start shortcuts, Launch ALL — all route
  through launch_zcode_second_instance.ps1) and ensures both main watchers:
  the MCP sync watcher and the taskbar identity watcher. Mechanism per
  watcher: a mutex probe (no WMI, microseconds) detects "already running";
  a missing Startup .lnk is installed once via the watcher's own
  -InstallAutostart (which verify-after reads back); then the watcher
  starts hidden via Start-Process with a pre-quoted -File argument (PS 5.1
  ArgumentList joins unquoted). Best-effort by contract: any failure warns
  and never blocks the launch; duplicates are converged by each watcher's
  own mutex guard. The captcha watchdog stays manual (ZCode [13]) — its
  kill/relaunch intervention and Telegram wiring make it a poor
  auto-start default. Scope decided with the developer (MCP sync +
  taskbar; start-now + autostart).
- **ZCode MCP sync: add in ONE place (Primary), every clone gets it live**
  (2026-10-27): a 15-agent verification pass (app.asar disassembly + logs of
  all six instances) proved the long-standing "a live app may rewrite its
  config on exit" guard rationale FALSE — the app holds no handle on
  `<CloneHome>\.zcode\cli\config.json`, never rewrites it on exit (its own
  writes are event-driven atomic tmp+rename), and reads `mcp.servers` at
  every app-server spawn, one per new session (6-41 bootstraps/day per
  instance). New: `tools/zcode_mcp_merge.ps1` — the pure merge core
  extracted from sync_zcode_assets.ps1's Sync-McpDefinitions (unit-tested by
  `tests/zcode_mcp_merge.Tests.ps1`: clone-local enabled toggles survive,
  clone-only servers are never removed, new servers inherit the Primary's
  enabled value, Primary definitions win, key-order-insensitive deep
  compare); `tools/sync_zcode_assets.ps1 -McpOnly` — MCP-definitions-only
  sync that is safe against RUNNING instances (skills/plugins keep the
  old skip); `tools/watch_zcode_mcp_sync.ps1` — resident watcher (taskbar
  watcher pattern: named mutex ZcodeMcpSyncWatcher + startup process scan +
  self-titling console + Startup-folder autostart) that invokes the sync
  child on every Primary config change (mtime+size signature, parse-guarded,
  debounced), converges all drift on its first pass and re-verifies deeply
  every ~5 min, with opt-in `-ApplyLive` recycling running instances'
  app-servers after a sync (idle-guarded, never mid-turn, never -Force).
  Wired as GHOST.bat ZCode `[24]` (one-shot live sync, gid 67), `[25]`
  (resident watcher, gid 68) and `[26]` (sync + apply to running instances
  now, gid 69); dispatch header range 1-66 -> 1-69. The watcher itself never
  writes config — every write goes through sync_zcode_assets.ps1's backup +
  verify-after + JSONL audit.

### Fixed
- **Launcher step 2d pre-launch sync never ran** (found 2026-10-28 by a
  live launch test): `$SyncScript = Join-Path $PSScriptRoot '..\tools\...'`
  resolved to `src\tools\` from the launcher's home in `src\windows\` —
  the sync script lives at the repo-root `tools\`, so every launch printed
  the quiet yellow "not found - skipping (clone stays as last synced)" line
  and the pre-launch asset sync had effectively never executed since the
  scripts moved into src/windows (OSS restructure v1.0.0). Branding's
  step 3b always used the correct `'..\..\tools\'` depth, proving the
  inconsistency. Fixed the path for 2d AND for the new step 2e watcher
  paths (same trap).
- **ZCode taskbar watcher auto-repair dead since 2026-09-28**
  (2026-10-25): the resident watcher DETECTED every Primary shortcut hijack
  (ZCode.lnk rewritten with a clone AUMID + wiped icon — the Start-menu
  dedupe hiding a clone entry + the white taskbar icon) but its repair
  never ran: inside Invoke-PrimaryHijackGuard the local
  `$repair = Join-Path ...` assignment targeted the function's own
  `[switch]$Repair` parameter (PowerShell variables are case-insensitive),
  and binding the script-path string to a switch parameter throws
  "Cannot convert ... to SwitchParameter" — 228 identical logged failures
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
- **ZCode Start-Plan throttle diagnostic — `tools/diagnose_zcode_throttle.ps1`**
  (2026-10-27, read-only): explains the "Reconnecting... x/10" /
  "The system is busy, and automatic retries have reached the maximum
  count" failures from the shared agent runtime JSONL
  (`~\.zcode\cli\log\zcode-*.jsonl`, which every instance writes to). It
  lists `model.main_turn.retry_start_plan_admission_busy` retries and
  `turn.failed` entries with their cause chain
  (`StartPlanBusyAutoRetryExhaustedError` → `providerCode 3009` "model
  concurrency limit exceeded" / `model_rate_limited`, `maxAttempts 11` —
  the UI's x/10 counter), builds an hourly histogram (local time) and a
  per-session rollup, and the verdict spells out the finding that settled
  the day's incident: server-side Start Plan admission control refusing
  new streams under load — NOT a device/IP ban (auth + billing unaffected;
  different accounts failed in the same minute; zero occurrences on
  10-24..26) — plus the discrimination test (close all instances but one)
  and the concurrency mitigations. `-Days N` widens the window; PS 5.1
  parse-checked and live-validated against the 2026-10-27 logs.
- **WMI hardware-serial spoof — `src/windows/spoof_wmi_serials.ps1`**
  (2026-10-27, Maintenance `[3]` / gid 66, behind a `:ConfirmRun` gate): the
  one portable technique from a Hydra Spoofer 1.5.5 review, rewritten to the
  GHOST bar (the source's Python was not taken — bare excepts, zero
  verify-after, f-string MOF generation, a wrong `Win32_BaseBoard` key). A
  generated `.mof` redeclares `Win32_BIOS` / `Win32_BaseBoard` /
  `Win32_ComputerSystemProduct` / `Win32_SystemEnclosure` /
  `Win32_DiskDrive` / `Win32_PhysicalMemory` with `[DYNPROPS]` (real CIM key
  properties, escaped literals, real instance keys) and compiles via
  `mofcomp`, so WMI clients read spoofed serials; plus `SQMClient UserId`
  and Bluetooth `LocalAddress` rotation (`-SkipBluetooth`) — the two
  identity values GHOST had no coverage for. Backup-first
  (`winmgmt /backup` aborts the run on failure), verify-after re-query as
  the arbiter, audit log, generated `winmgmt /restore` script. Deliberately
  excluded: CPU/GPU (Phase 5 + out of scope), `DigitalProductId`
  randomization (activation risk), volume serials (license + unproven
  signal — backlog in docs/WMI_SERIAL_SPOOFING.md). WMI layer only — does
  not move the fingerprint self-test score (ground truth #4).
- **ZCode Sixth clone (orange) — 6-instance suite** (2026-10-24): a fifth
  branded clone joins the suite, bringing ZCode to parity with the other
  suites (Primary + 5 clones) — instance `Sixth`, window title "ZCode
  Orange", home `%USERPROFILE%\ZCodeSixthHome`, roaming
  `%APPDATA%\ZCode-Sixth`, AUMID `dev.zcode.app.6`, accent `#CB5D06`
  (derived from the blue accent by the same hue rotation that produced
  Fifth's `#CA0607`), icon via `tools/zcode-orange-branding/` (blue master
  +180° hue-rotate through `tools/make_clone_icon.ps1`). Wired everywhere
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
  `~\.config\opencode` — the latter holds live API keys and is never read
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
  sites — imports are aliased — so the AutoClaw-v12 constructor subclass
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
  2026-10-24/25: engine v1→v2 upgrade path proven (the main bundle is ESM —
  no `require` — so v1's fs-based identity resolver silently no-oped and v2
  moved identity to pure argv flags), locked-asar in-place swap fallback +
  two-tier core/current signature probe landed from the same session, all
  five clones verified (per-clone lockfiles HELD simultaneously, every
  Chromium child on its own --user-data-dir, "OpenCode Blue"/"Orange"
  window titles, ephemeral per-instance service ports — no port plan
  needed), the updater stages 2.1.4 without installing (darwin-only
  autoInstallOnAppQuit; patch survived), and the Primary snapshot diff
  showed only the live user session's own artifacts — 0 clone-breach
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
  (`.neutralized`) pre- and post-launch with verify — 3 clones verified
  running concurrently this way. The launcher itself enforces per-clone
  single-instance (aborts on the clone's own held hub lock, since the
  app-level guard is neutralized). Fresh profile per clone — ONE manual
  sign-in each (identity: HKLM MachineGuid is shared, account identity
  lives in the clone's `data\secrets.json` only). Taskbar identity is
  shortcut-AUMIDs-only by developer decision (no patchable surface; pins
  distinct via `bot.cline.app.cN`, running windows share the base
  identity). New files: `src/windows/launch_cline_clone.ps1`
  (+`-Status`), `src/windows/launch_cline_clones_all.ps1` (sequential,
  honest fixed-stagger docs), `tools/install_cline_clone_shortcuts.ps1`
  (Desktop + Start Menu, per-clone icons, suffixed AUMIDs, `-Remove`),
  `tools/cline-orange-branding/` (5th color, tint-generated from the
  blue master — hue-rotate rejected: the two-tone logo would produce the
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

- **ZCode submenu [21] — "Reset ZCode Primary instance"** (2026-10-23): a
  copy of IDE Resets [7] inside ZCode Multi-Instance & Clones, appended to
  the end of the Reset Clones block (every existing entry and number
  untouched). Both entries resolve to the same global id (gid 7 →
  `reset_zcode.ps1 -Target Primary`), so the Primary reset is reachable
  from either menu.

- **AutoClaw submenu [13] — "Reset AutoClaw Primary instance"** (2026-10-23):
  the same copy pattern as ZCode [21] — IDE Resets [9] ("Reset AutoClaw")
  cloned into AutoClaw Multi-Instance & Clones, appended to the end of the
  Reset Clones block (every existing entry and number untouched). Both
  entries resolve to the same global id (gid 28 →
  `reset_autoclaw.ps1 -Target Primary`), so the Primary reset is reachable
  from either menu.

- **CPU name spoof in `change_device_id.ps1` LegacyReset** (2026-10-18):
  Phase 5's last live item — writes a fictional `ProcessorNameString` to
  ALL `HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\*` subkeys
  (8-name realistic pool, `Get-Random`) so the fingerprint self-test's
  heaviest changeable signal (`cpu.name`, weight 0.12) actually moves,
  completing the documented 0.19 delta. Rides the existing
  backup/changelog/verify-after/rollback loop; `CentralProcessor.reg`
  exported to the backup dir and imported by the restore script; summary
  prints the new name. Accepted by the live user-supervised run the same
  day: `cpu.name` moved live (no reboot needed) — Phase 5 fully accepted.

- **ZCode Fifth clone (red) — 5-instance suite** (2026-10-17): a fourth
  branded clone joins the suite — instance `Fifth`, window title
  "ZCode Red", home `%USERPROFILE%\ZCodeFifthHome`, roaming
  `%APPDATA%\ZCode-Fifth`, AUMID `dev.zcode.app.5`, accent `#CA0607`.
  Branding lives in `tools/zcode-red-branding/` (blue master +150°
  hue-rotate via the new generic `tools/make_clone_icon.ps1` — identical
  geometry to the existing four icons). Wired end to end: launcher
  `-Instance Fifth` (+ `Launch-ZCode-Fifth.bat`), shortcuts installer
  (four clones now; `ZCode Fifth.lnk` live-verified), taskbar watcher,
  chat refresher (`-Target ...|Fifth|All`), reset (`-Target Fifth`,
  `All` = Third+Fourth+Fifth+Secondary+Primary), freeze diagnostic,
  Telegram bot guardian, and GHOST.bat ZCode `[18]` (gid 41; no
  renumbering — existing citations stay valid) with the launch-all and
  reset-all flows covering Fifth. First live launch is pending (the
  one-time seed needs the Primary closed — robocopy exit 9 otherwise;
  a partial seed is auto-detected and must be removed before re-running).

- **ZCode reset menu item for Fifth** (2026-10-17): GHOST.bat ZCode submenu
  gains `[19]` "Reset Fifth instance - Red" under `-- Reset Clones --`
  (gid 42 → `reset_zcode.ps1 -Target Fifth`) — the individual reset that
  was previously CLI-only. No renumbering; existing citations stay valid.

- **Generic clone-icon generator `tools/make_clone_icon.ps1` +
  AutoClaw per-clone icons** (2026-10-17): app-agnostic icon pipeline
  (PS 5.1 + System.Drawing only): corner-sampled background detection →
  tile crop (`-BgTolerance`/`-ManualCrop`) → rounded-corner alpha master →
  multi-size `tray_icon.ico` (16..256 PNG-in-ICO) + `icon_windows.png` +
  source provenance; `-HueRotate` derives clone colors. AutoClaw
  inst1..inst4 shortcuts now carry per-clone icons
  (`tools/autoclaw-{blue,yellow,green,red}-branding/` from
  developer-supplied renders; red = blue +150°; `bad-green` rejected by
  the developer), falling back to the exe icon when a branding dir is
  missing. **Full staged color suites** for the future opencode/cline clones
  (`tools/{opencode,cline}-{blue,yellow,green,red}-branding/`, all eight
  dirs with `tray_icon.ico` + 1024 master + `source.jpg` provenance —
  cline's unnamed renders assigned by measured dominant hue; `bad-green`
  excluded) — icons only, no launcher/reset wiring yet by design.

- **ZCode clone asset sync `tools/sync_zcode_assets.ps1`** (2026-10-17):
  every clone resolves its own user-scope config
  (`<CloneHome>\.zcode\cli\config.json` — the HOME override reaches the
  app's config resolution, unlike the shared CLI session db), so the
  one-time seed copies had drifted: all three seeded clones still ran the
  broken `npx @supabase/mcp-server-supabase@latest` entry, lacked `sentry`,
  had stale skill copies shadowing the shared `.agents` store, and missed
  newer plugin versions. The sync merges MCP server DEFINITIONS from the
  Primary (per-clone on/off toggles stay local; new servers carry the
  Primary's enabled value; clone-only servers are kept; plugins/hooks stay
  local), moves the stale `.zcode\skills` copies aside and junctions
  `<CloneHome>\.agents` → `~\.agents` (live skills, no elevation), and
  robocopy-mirrors the plugin cache + marketplaces when the version set
  drifts (`plugins\data`/`cli\agents` stay per-instance). Running instance
  = skip + warn; unseeded home = skip note; backup + verify-after
  everywhere; JSONL audit per clone home. Wired as GHOST.bat ZCode `[20]`
  (gid 43; no renumbering) and as launcher step 2d (pre-launch sync, never
  blocks the launch). `-Target Second|Third|Fourth|Fifth|All` + `-DryRun`.

- **AutoClaw clone taskbar identity v2 (spec §7.3c) — IMPLEMENTED**
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
  file — `launch_autoclaw_clone.ps1` step 4c writes
  `<CloneProfile>\.autoclaw-identity.json` and copies the branded
  `.autoclaw-icon.ico` every launch (env vars die at the UAC boundary,
  marker files do not); a missing marker means stock behavior, so the
  Primary and bare native-host spawns are untouched. Live-verified on
  the first relaunch 2026-10-18: the EC-C07 property-store readback
  returns `com.zhipuai.autoclaw.inst1` on a live clone window.

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

### Fixed

- **ZCode reset menu + watchdog hardening (partial)** (2026-10-23,
  docs/ZCODE_RESET_EDGE_CASES_PLAN.md): GHOST.bat confirms before the
  destructive multi-instance resets (gid 12 Both, gid 21 All-five; `choice`
  reads the console so chains and the .bat harness are unaffected), and every
  reset_zcode dispatch now prints the post-reset relaunch warning via
  `:RunZcodeReset` (bare ZCode.exe = Primary profile). ZCode [6] label
  pluralized; harness gains scenario M (reset-block render).
  tools/watch_zcode_captcha.ps1 snapshots running instances by process markers
  BEFORE its kill and relaunches clones via the launcher, Primary bare — the
  old blanket bare ZCode.exe relaunch repopulated only the Primary profile and
  silently voided every "survivors kept running" claim. The reset_zcode.ps1
  v1.5 script-side items (shared-db scrub [26b], strict backups, abort
  checkpoint, Python preflight, -DryRun, purge salvage, elevation exit-code
  propagation) are PENDING — blocked by a workspace write-guard false positive
  on [6b]'s apiKey-blanking line (user chose to defer).

- **AutoClaw2 clone icons recolored** (2026-10-23): the first branding run
  for the c1..c5 suite shipped five byte-identical `tray_icon.ico` files —
  the new app icon is a monochrome white logo and `-HueRotate` does
  nothing on gray art. `tools\make_clone_icon.ps1` gains a colorize mode
  (`-TintHue/-TintSat/-TintValueFloor`: set hue + saturation, keep value,
  dark tile background untouched), and all five
  `tools\autoclaw2-{blue,yellow,green,red,orange}-branding` dirs were
  regenerated with hues calibrated from the old autoclaw/zcode suites
  (blue 206 / yellow 46 / green 166 / red 356 / orange 25; measured hue
  deltas ≤0.1°, five distinct hashes, background mean within ±1 RGB).
  Shortcuts already pointed at these paths (AUMIDs intact); icon cache
  refreshed. Pre-color set archived at
  `archive\autoclaw2-branding-precolor-20261023\`.

- **AutoClaw patch engine v12 — three live-verified fixes** (2026-10-18,
  found by the first live relaunch of the taskbar-identity v2):
  (1) the window-identity wrap called `setAppDetails({ appUserModelId })` —
  Electron 33's option key is **`appId`** (verified against the shipped
  binary), so the window-level AUMID was never stamped;
  (2) ctor-time stamping alone does not survive HWND recreation — the wrap
  now re-stamps on `show` and on every title re-assert; the EC-C07
  property-store readback now returns `com.zhipuai.autoclaw.inst1` live
  (previously `<EMPTY>`); and
  (3) `-Force` re-patch extracted the LIVE already-patched asar, whose
  wrapped anchors made the engine skip its own sites — old injected code
  silently survived re-runs while the marker timestamp refreshed. The tool
  now extracts the PRISTINE backup asar whenever the live file carries the
  wrap marker; engine bumped 11→12 so existing markers upgrade via the
  normal re-apply path.
- **AutoClaw launcher shipped clones without a window icon** (2026-10-18):
  `launch_autoclaw_clone.ps1` computed `$RepoRoot` one level short of the
  repo root (copied the tools/ one-parent pattern into a src/windows/ two-deep
  script) and looked for the tray icon under `src\tools\...` — every launch
  WARNed "icon source missing" and the clone identity went out iconless.
  Fixed; live-verified: icon copies + window shows it.

- **Window-stamping interop broke machine-wide** (2026-10-17): the
  Windows 10 19041.**7548** cumulative update (July 2026) **removed the
  `PropVariantClear` export from `oleaut32.dll`** — every `IPropertyStore`
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
  `change_device_id.ps1` — the 5 dead registry writes are already gone and
  the bcdedit item is retired (the current lineage has no RAM section, and
  `maxmem/truncatememory` never changed `TotalPhysicalMemory`, the signal
  actually scored); `docs/AUTOCLAW_CLONES_SPEC.md` §12 Definition-of-done
  boxes ticked with evidence dates (static gates re-run 2026-10-18:
  Pester 36/36, PSSA Error-clean; the open items are the multi-instance
  live verifications beyond inst1); `AGENTS.md` stale AutoClaw
  "not yet implemented" sentence corrected (taskbar identity v2 shipped
  2026-10-17). Same-day live closeouts: the CPU-spoof acceptance run
  changed `cpu.name` live (no reboot needed) — Phase 5 fully accepted;
  the AutoClaw taskbar-identity v2 EC-C07 window-AUMID readback observed
  live on the first relaunch; and the Phase 3 thin-manifest pilot was
  ACCEPTED by a live `reset_cursor.ps1` run (15/15 steps identical to the
  archived v0.2, audit + restore script verified) — remaining migrations
  per the roadmap order: trae → qoderwork → minimax → qoder → zcode last.

- **Docs — AutoClaw clone taskbar identity upgraded to a REQUIRED v2 design**
  (2026-10-17): the shared taskbar button is no longer the accepted end state.
  `docs/AUTOCLAW_CLONES_SPEC.md` §7.3c now requires separate taskbar
  buttons/window groups per clone (per-clone process AUMID
  `com.zhipuai.autoclaw.inst1..4` via an app.asar branding patch, aligned with the
  shipped shortcut AUMIDs) and the clone color icons visible BOTH in the taskbar AND
  in the app window itself. Branding config rides a `--user-data-dir` marker file
  (env vars do not survive the app's self-elevation); the window-level
  IPropertyStore stamp is the elevation-gated fallback. Implemented the
  same day (engine v11 — see the Added entry above) and live-verified
  2026-10-18; the v1 shortcut-AUMID-only identity is historical.
  `AGENTS.md`, `docs/APP_CLONING_PLAYBOOK.md` (intro + row 7 + Phase 8),
  `docs/APP_CLONING_EDGE_CASES.md` (EC-C06) and `docs/README.md` aligned.

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
