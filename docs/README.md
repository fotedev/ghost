# GHOST documentation

| Document | What it covers |
|---|---|
| [Getting started](getting-started.md) | Per-tool walkthroughs: every Windows reset script, the Linux scripts, paths touched, flags |
| [Architecture](architecture.md) | How the toolkit is built: shared library API, the Python core, step pattern, backup/audit/restore lifecycle |
| [CLI cheat sheet](cli.md) | Direct commands for scripts and CI, plus the Python core diagnostics |
| [Troubleshooting](troubleshooting.md) | Common failures and fixes (Python/core missing, locked processes, restoring a reset) |
| [FAQ](faq.md) | Scope, ToS/risk, cross-tool correlation, the Windsurf → Devin rebrand, versioning policy |
| [ZCode chat sync plan](ZCODE_CHAT_SYNC_WATCHER_PLAN.md) | Root-cause analysis of cross-instance chat visibility + the refresh/watcher design |
| [Python hybrid roadmap](PYTHON_HYBRID_ROADMAP.md) | The PS→Python thin-manifest migration: Phase 2 cancellation record, Phase 3 pilot design + acceptance criteria (pilot ACCEPTED 2026-10-18; devin v0.4 landed) |
| [ZCode Telegram bots](ZCODE_TELEGRAM_BOTS.md) | Per-clone Telegram bot reconciliation: sha8 credential fingerprinting, `set_zcode_bot.ps1` audit/sync, one-token-one-instance |
| [App cloning playbook](APP_CLONING_PLAYBOOK.md) | The generic process for cloning any app into isolated instances: identity suite, developer-inputs contract, icon policy, phases 0–10 |
| [App cloning edge cases](APP_CLONING_EDGE_CASES.md) | The normative EC-xx catalog every clone suite must handle (updates, icons, taskbar, seeds, ports, PS 5.1, ...) |
| [App cloning intake template](APP_CLONING_INTAKE_TEMPLATE.md) | The fill-in form a new clone request starts from (names, colors, icons, credentials, ports) |
| [AutoClaw clones spec](AUTOCLAW_CLONES_SPEC.md) | AutoClaw Primary + inst1–inst4: verified ground truth read from the installed app, port plan, risks, decisions, provenance; v2 taskbar identity (separate taskbar buttons per clone + clone icons in taskbar and in-app, §7.3c) implemented 2026-10-17, live-verified 2026-10-18 |
| [AutoClaw2 clones spec](AUTOCLAW2_CLONES_SPEC.md) | AutoClaw2 (v2.1.1, zwork) Primary + c1–c5: env-lever isolation (`ZWORK_USER_DATA` pinned before the single-instance lock), fresh per-profile device IDs, no seeding, no patch engine; implemented 2026-10-23; CLI-only (the one suite not wired into `GHOST.bat`) |
| [Cline clones spec](CLINE_CLONES_SPEC.md) | Cline desktop (Tauri/WebView2) Primary + c1–c5: env isolation (`CLINE_DIR` + `WEBVIEW2_USER_DATA_FOLDER` + per-clone hub/sidecar ports) and the tauri-plugin-single-instance anatomy (fixed-key mutex + hidden window) neutralized by the launcher; implemented 2026-10-24 |
| [OpenCode clones spec](OPENCODE_CLONES_SPEC.md) | OpenCode desktop (Electron 2.0.32) Primary + c1–c5: clone-home asar patch (packaged builds hardcode userData; the app's own `XDG_*` redirection reused for CLI state), native per-userData single-instance lock, `setAppUserModelId` wrap + `browser-window-created` stamper with argv identity (the main bundle is ESM — no `require`); implemented and live-verified 2026-10-24/25 (coexistence, ephemeral service ports, Primary snapshot diff = 0 clone-attributable changes) |
| [WMI serial spoofing](WMI_SERIAL_SPOOFING.md) | `spoof_wmi_serials.ps1` (Maintenance [3]): MOF/DYNPROPS redeclaration of the Win32 hardware classes + SQM UserId + Bluetooth MAC, the winmgmt backup/restore contract, and the honest limits (WMI layer only) |
| [ZCode reset edge cases plan](ZCODE_RESET_EDGE_CASES_PLAN.md) | Findings catalog (F-01..F-14), decision points and workstreams for hardening the ZCode reset options; PARTIALLY applied 2026-10-23 (menu-side confirm gate + relaunch note shipped; script-side items pending) |
| [Task backlog](TASK_BACKLOG.md) | The single tracked index of every open task (2026-10-28 survey): bug-sweep remediation state incl. the write-guard-blocked diffs, ZCode W1 items, thin-manifest queue, clone-suite future work, ops backlog |
| [Bug-sweep remediation plan](BUG_SWEEP_REMEDIATION_PLAN.md) | Finishing the 2026-10-24 ~196-finding sweep: the re-verify-before-apply rule, the five blocked files' staged diffs, pending scopes (qoder, watchers, trae, installers), the core SELECT probe, acceptance gates |
| [OpenCode config sync plan](OPENCODE_CONFIG_SYNC_PLAN.md) | Definitions-only Primary→clone `opencode.jsonc` sync (secrets never copied): the scrub design, merge invariant, launcher pre-launch placement, dry-run, acceptance |
| [Cline window identity plan](CLINE_WINDOW_IDENTITY_PLAN.md) | Window-level taskbar identity for the Tauri clones (launcher-side stamping — no patch surface): Phase 0 probes, design, acceptance; developer-deferred, design-ready |
| [Thin-manifest migration queue](THIN_MANIFEST_MIGRATION_QUEUE_PLAN.md) | Per-script execution breakdown for the remaining five resetters (trae → qoderwork → minimax → qoder → zcode) with the fix-before-migrate sequencing gate |

The top-level [README](../README.md) is the quick-start entry point.
