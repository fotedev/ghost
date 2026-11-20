# GHOST documentation

| Document | What it covers |
|---|---|
| [Getting started](getting-started.md) | Per-tool walkthroughs: every Windows reset script, the Linux scripts, paths touched, flags |
| [Architecture](architecture.md) | How the toolkit is built: shared library API, the Python core, step pattern, backup/audit/restore lifecycle |
| [CLI cheat sheet](cli.md) | Direct commands for scripts and CI, the full GHOST.bat/ghost.sh submenu row map (parity-tested against the launchers), plus the Python core diagnostics |
| [Troubleshooting](troubleshooting.md) | Common failures and fixes (Python/core missing, locked processes, restoring a reset) |
| [FAQ](faq.md) | Scope, ToS/risk, cross-tool correlation, the Windsurf → Devin rebrand, versioning policy |
| [Why not Sandboxie?](why-not-sandboxie.md) | Sandboxie-Plus vs GHOST: identity vs file isolation, throwaway boxes vs permanent clone profiles, when to use which |
| [ZCode chat sync plan](ZCODE_CHAT_SYNC_WATCHER_PLAN.md) | Root-cause analysis of cross-instance chat visibility + the refresh/watcher design |
| [Python hybrid roadmap](PYTHON_HYBRID_ROADMAP.md) | The PS→Python thin-manifest migration: Phase 2 cancellation record, Phase 3 pilot design + acceptance criteria (pilot ACCEPTED 2026-10-18; devin v0.4 landed) |
| [ZCode Telegram bots](ZCODE_TELEGRAM_BOTS.md) | Per-clone Telegram bot reconciliation: sha8 credential fingerprinting, `set_zcode_bot.ps1` audit/sync, one-token-one-instance |
| [App cloning playbook](APP_CLONING_PLAYBOOK.md) | The generic process for cloning any app into isolated instances: identity suite, developer-inputs contract, icon policy, phases 0–10 |
| [App cloning edge cases](APP_CLONING_EDGE_CASES.md) | The normative EC-xx catalog every clone suite must handle (updates, icons, taskbar, seeds, ports, PS 5.1, ...) |
| [App cloning intake template](APP_CLONING_INTAKE_TEMPLATE.md) | The fill-in form a new clone request starts from (names, colors, icons, credentials, ports) |
| [AutoClaw2 clones spec](AUTOCLAW2_CLONES_SPEC.md) | AutoClaw2 (v2.1.1, zwork) Primary + c1–c5: env-lever isolation (`ZWORK_USER_DATA` pinned before the single-instance lock), fresh per-profile device IDs, no seeding, no patch engine; implemented 2026-10-23; wired into `GHOST.bat` main [4] (rows [1]-[25]) |
| [Cline clones spec](CLINE_CLONES_SPEC.md) | Cline desktop (Tauri/WebView2) Primary + c1–c5: env isolation (`CLINE_DIR` + `WEBVIEW2_USER_DATA_FOLDER` + per-clone hub/sidecar ports) and the tauri-plugin-single-instance anatomy (fixed-key mutex + hidden window) neutralized by the launcher; implemented 2026-10-24 |
| [OpenCode clones spec](OPENCODE_CLONES_SPEC.md) | OpenCode desktop (Electron 2.0.32) Primary + c1–c5: clone-home asar patch (packaged builds hardcode userData; the app's own `XDG_*` redirection reused for CLI state), native per-userData single-instance lock, `setAppUserModelId` wrap + `browser-window-created` stamper with argv identity (the main bundle is ESM — no `require`); implemented and live-verified 2026-10-24/25 (coexistence, ephemeral service ports, Primary snapshot diff = 0 clone-attributable changes) |
| [WMI serial spoofing](WMI_SERIAL_SPOOFING.md) | `spoof_wmi_serials.ps1` (Maintenance [3]): MOF/DYNPROPS redeclaration of the Win32 hardware classes + SQM UserId + Bluetooth MAC, the winmgmt backup/restore contract, and the honest limits (WMI layer only) |
| [ZCode reset edge cases plan](ZCODE_RESET_EDGE_CASES_PLAN.md) | Findings catalog (F-01..F-14), decision points and workstreams for hardening the ZCode reset options; PARTIALLY applied 2026-10-23 (menu-side confirm gate + relaunch note shipped; script-side items pending) |
| [Task backlog](TASK_BACKLOG.md) | The single tracked index of every open task (2026-10-28 survey): bug-sweep remediation state incl. the write-guard-blocked diffs, ZCode W1 items, thin-manifest queue, clone-suite future work, ops backlog |
| [Bug-sweep remediation plan](BUG_SWEEP_REMEDIATION_PLAN.md) | Finishing the 2026-10-24 ~196-finding sweep: the re-verify-before-apply rule, the five blocked files' staged diffs, pending scopes (qoder, watchers, trae, installers), the core SELECT probe, acceptance gates |
| [OpenCode config sync plan](OPENCODE_CONFIG_SYNC_PLAN.md) | Definitions-only Primary→clone `opencode.jsonc` sync (secrets never copied): the scrub design, merge invariant, launcher pre-launch placement, dry-run, acceptance; v2 = resident watcher + menu rows (2026-11-17) |
| [Cline window identity plan](CLINE_WINDOW_IDENTITY_PLAN.md) | Window-level taskbar identity for the Tauri clones (launcher-side stamping — no patch surface): Phase 0 probes, design, acceptance; IMPLEMENTED 2026-11-17 (live probes via tools/probe_cline_window.ps1, user-supervised) |
| [Thin-manifest migration queue](THIN_MANIFEST_MIGRATION_QUEUE_PLAN.md) | Per-script execution breakdown for the remaining five resetters (trae → qoderwork → minimax → qoder → zcode) with the fix-before-migrate sequencing gate |
| [AutoClaw2 sync spec](AUTOCLAW2_SYNC_SPEC.md) | AutoClaw2 MCP + chat sync design (decisions D1–D13, acceptance A1–A7/C1–C7): pre-tested discovery rows, the 16384 inputSchema refine, credentials.enc custody replication, §9.1 the corrupt-CAS incident + heal |
| [AutoClaw2 sync plan](AUTOCLAW2_SYNC_PLAN.md) | AutoClaw2 MCP-first sync implementation plan; the MCP milestone IMPLEMENTED 2026-11-04, the chat import live-verified 2026-11-09 |
| [AutoClaw2 sync tasks](AUTOCLAW2_SYNC_TASKS.md) | Task breakdown citing the sync spec's decisions; status table 2026-11-04 |
| [MCP central registry plan](MCP_CENTRAL_REGISTRY_PLAN.md) | The MCP central registry (`master-mcp.json` → every app's own config shape): design + live status (largely Arabic); implemented 2026-11-04 |
| [ZCode light mode](ZCODE_LIGHT_MODE.md) | Headless per-account ZCode workers: the five env levers, why the interactive TUI cannot run standalone, the free-model vs Start-Plan login recipe |
| [T3 local support](T3_LOCAL_SUPPORT.md) | T3 Code control-surface support schedule for the GHOST-managed apps (local working notes) |
| [T3 ZCode bridge spec](T3_ZCODE_BRIDGE_SPEC.md) | Run ZCode accounts as T3 agents through a bridge process — spec only (phases A–D complete, T3 Code v0.1.4 installed; §9.2 runbook user-supervised) |
| [Rebrand plan 2026-09-24](PLAN-2026-09-24-rebrand.md) | The one-off commit plan for the Clean-Slate-Kit → GHOST rebrand + v1.1.0 (HISTORICAL — commit quotes frozen, never updated) |

The top-level [README](../README.md) is the quick-start entry point.
