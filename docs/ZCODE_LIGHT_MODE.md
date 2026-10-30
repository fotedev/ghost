# ZCode Light Mode — headless per-account workers (2026-10-28)

Run a clone's ZCode account **without its desktop window**: one node process
instead of a full Electron instance. Motivation: the 16 GB box cannot hold all
six desktop instances at once (the 2026-09-25 renderer-OOM freeze was commit
limit exhaustion), and the Start Plan provider throttles above ~3 concurrent
instances anyway (providerCode 3009 — more windows never bought more
throughput).

Everything below was **live-verified on 2026-10-28** against the installed
0.17.0 CLI (`resources\glm\zcode.cjs`) and the ZCodeSecondHome clone profile.

## What was measured

| Shape | Commit footprint |
| --- | --- |
| ZCode desktop instance | ~1.6 GB private commit each (3 running instances = 4.7 GB across 37 processes) |
| Headless CLI worker (`-p` one-shot) | ~0.35 GB main + ~0.58 GB across its 5 plugin-host children ≈ **0.9 GB total** |

Env isolation is complete: with the four levers set, `cli\config.json`,
`cli\db\db.sqlite`, `v2\credentials.json`, `v2\provider_config.json`,
`cli\plugins` and `cli\log` all resolve inside the clone home. Sessions a
light worker creates are visible to that clone's desktop app (same home =
same store) and vice versa.

## What works and what does not

**Works** — `zcode.cjs -p "<task>"` (one-shot, `--mode build|edit|plan|yolo`)
and `zcode.cjs app-server` (long-lived stdio protocol for orchestrators). Both
run under the system node; no Electron needed. `--resume sess_...` / `-c`
continue persisted sessions.

**Does not work** — the interactive TUI standalone. It imports `@zcode/tui`,
which only exists inside the installed `app.asar`, and `ELECTRON_RUN_AS_NODE=1`
disables asar resolution, so `zcode tui` cannot boot outside the app's own
runtime. Light mode is therefore **headless-only**; interactive chat stays on
the desktop app (keep it under the RAM guard instead).

**Model caveat (important)** — a clone home without a *standalone CLI login*
resolves its model to the FREE `opencode-zen` gateway model
(`muse-spark-1.3-contributor-free`), not the account's Start Plan. The desktop
app injects the plan adapter (`account:zai-start-plan/GLM-5.3-Flash` — the
working namespace, per the Primary's `model_usage` history) into its own
children only (`hasInjectedModelAdapter`), and a hand-written
`defaultModelSelection` in `provider_config.json` is normalized away by the
CLI on the next run. The sanctioned fix is one `zcode login zai` **per clone
home** — the login flow itself writes the correct default model selection.
`launch_zcode_cli_light.ps1` detects the missing default and prints the exact
commands.

## Usage

```powershell
# Interactive console worker for the Second account (type a task, empty = exit)
powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_zcode_cli_light.ps1" -Instance Second

# One-shot task on the Fifth account
powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_zcode_cli_light.ps1" -Instance Fifth -Prompt "summarize the TODOs in this repo" -Cwd "C:\path\to\repo"

# Long-lived stdio worker for an orchestrator (the caller owns the pipe)
powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_zcode_cli_light.ps1" -Instance Third -Server
```

GHOST.bat ZCode submenu **[7]** launches the interactive variant in its own
window. `-Mode` maps to the CLI's permission modes (default `build`).

## One-time login per clone home (enables the Start Plan)

The one-click way: **GHOST.bat ZCode [28]** — pick the clone, a browser opens,
sign in with THAT clone's account, and the launcher verifies
`defaultModelSelection` landed (exit 0 = done). Manually:

```bat
set HOME=%USERPROFILE%\ZCodeSecondHome
set USERPROFILE=%USERPROFILE%\ZCodeSecondHome
set ZCODE_DATA_BASE_DIR=%USERPROFILE%\ZCodeSecondHome
set ZCODE_STORAGE_DIR=%USERPROFILE%\ZCodeSecondHome\.zcode
node "%LOCALAPPDATA%\Programs\ZCode\resources\glm\zcode.cjs" login zai
```

Log in with **that clone's** account in the browser window. The login writes
`defaultModelSelection` itself; the light launcher's warning (and the T3
bridge's) disappears after that. One credential = one instance — never share
a login across clone homes.

## RAM discipline for the desktop instances

- Soft guard: `launch_zcode_second_instance.ps1` now counts running ZCode
  instances and, at `-MaxConcurrent` (default 3), prints live commit numbers
  and asks. Non-interactive callers (watchdog relaunch, test harness) warn and
  continue instead of hanging. Relaunching an already-running clone just
  focuses it and never prompts.
- `-LowRam` (experimental): launches the app with `--disable-gpu`, dropping the
  per-instance GPU process. Off by default — rendering falls back to software.
- Pagefile: the OOM incident happened at a 16 GB RAM + ~16 GB pagefile commit
  limit. A fixed pagefile of ~32 GB on the fastest drive is the cheap insurance
  (System Properties → Performance → Advanced → Virtual memory → set Custom
  size 32768/32768 on the SSD, then reboot).
- The Start Plan admission control (see `tools/diagnose_zcode_throttle.ps1`)
  is the other ceiling: even with infinite RAM, 4-6 concurrent instances fight
  over provider concurrency. Two or three active instances is the sweet spot.

## T3 Code (pingdotgg) — evaluated 2026-10-28, deferred

T3 Code is an open-source control surface for headless agent CLIs (Claude
Code, Codex, OpenCode, Grok, ...) with desktop/web/mobile clients. Verdict for
this fleet:

- **No ZCode/Z.ai provider** — it cannot drive the Start Plan accounts at all,
  and multi-account for a single provider is still an open feature request
  (issues #2111 / #1444).
- It DOES support "Local ACP command" providers (arbitrary executable +
  per-provider environment overrides) — but the zcode CLI speaks its own
  `app-server` stdio protocol, not ACP (verified: zero ACP markers in the
  bundle), so wiring it in means writing and maintaining an ACP ↔ app-server
  bridge against two fast-moving early-stage projects. Deferred until the
  unified-window + mobile-control benefit justifies that maintenance.
- The zero-effort T3 win is elsewhere: the OpenCode fleet (`opencode` CLI) is
  natively supported and could move into a single T3 window today.

The light worker here (`launch_zcode_cli_light.ps1`, especially `-Server`) is
the building block any such bridge would sit on.
