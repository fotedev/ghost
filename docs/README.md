# GHOST documentation

| Document | What it covers |
|---|---|
| [Getting started](getting-started.md) | Per-tool walkthroughs: every Windows reset script, the Linux scripts, paths touched, flags |
| [Architecture](architecture.md) | How the toolkit is built: shared library API, the Python core, step pattern, backup/audit/restore lifecycle |
| [CLI cheat sheet](cli.md) | Direct commands for scripts and CI, plus the Python core diagnostics |
| [Troubleshooting](troubleshooting.md) | Common failures and fixes (Python/core missing, locked processes, restoring a reset) |
| [FAQ](faq.md) | Scope, ToS/risk, cross-tool correlation, the Windsurf → Devin rebrand, versioning policy |
| [ZCode chat sync plan](ZCODE_CHAT_SYNC_WATCHER_PLAN.md) | Root-cause analysis of cross-instance chat visibility + the refresh/watcher design |
| [App cloning playbook](APP_CLONING_PLAYBOOK.md) | The generic process for cloning any app into isolated instances: identity suite, developer-inputs contract, icon policy, phases 0–10 |
| [App cloning edge cases](APP_CLONING_EDGE_CASES.md) | The normative EC-xx catalog every clone suite must handle (updates, icons, taskbar, seeds, ports, PS 5.1, ...) |
| [App cloning intake template](APP_CLONING_INTAKE_TEMPLATE.md) | The fill-in form a new clone request starts from (names, colors, icons, credentials, ports) |
| [AutoClaw clones spec](AUTOCLAW_CLONES_SPEC.md) | AutoClaw Primary + inst1–inst4: verified ground truth read from the installed app, port plan, risks, decisions, provenance |

The top-level [README](../README.md) is the quick-start entry point.
