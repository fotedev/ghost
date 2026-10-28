# Bug-Sweep Remediation Plan — finishing the 2026-10-24 program

Scope: close out the ~196-finding sweep (`_bug_sweep\BUG_REPORT.md`, local-only)
whose first remediation wave is recorded in
`_bug_sweep\fixes\FIXES_SUMMARY.md` (uncommitted working tree). Both folders are
gitignored — this tracked spec plus [TASK_BACKLOG.md](TASK_BACKLOG.md) §1 carry
the state. Task IDs (BS-*) refer to the backlog.

Status 2026-10-28: fixed = scopes 02, 03, 07, 08, 13, 15, 16, 17 in full +
scope 11's v2 files + parent fixes (`identity_utils.ps1`, `src\python\ghost`,
`install_autoclaw2_clone_shortcuts.ps1` CRITICAL, `change_device_id.ps1` HIGH,
`ghost.sh`, `new_clone_suite.ps1`, trae UTF-8). Blocked = 5 files (workspace
write-guard false positives; ready-to-apply diffs staged). Pending = qoder
(untouched), watchers, trae remainder, installers / change_device_id / scaffold
LOWs, the core SELECT probe. Python suite 66/67 (the one red is the
guard-blocked overwrite-pinning test).

---

## 0. Mandatory step 0 for EVERY workstream: re-verify before applying

The remediation ran in waves and its pending lists are stale in places.
2026-10-28 spot-checks found: the `launch_zcode_second_instance.ps1` sync path
already fixed (`..\..\tools`), `reset_trae.ps1` already carrying done-marker
deletion + the RNG-salt rule + the watchdog/purge verdict block, and the
MiniMax version preflight already probing `Programs\@opencode-aidesktop` first.
Therefore, for every finding: read the sweep report line, read the current
code, apply only the missing delta, and record the verdict per finding
(`FIXED-ALREADY` / `APPLIED` / `N-A`) in a fix log appended to this doc or
written under `_bug_sweep\fixes\`. Never blind-apply a staged hunk.

## 1. WS-1 — apply the five blocked files' staged diffs (needs the TASK_BACKLOG §2 unblock decision)

| File | Findings | Staged fix |
|------|----------|------------|
| `src\windows\reset_autoclaw.ps1` | BS-1 CRITICAL (paired.json no-backup) + HIGH (`-RedactKeys @("privateKeyPem")`) | `_bug_sweep\fixes\BLOCKED_FIXES.md` §1 (Diffs A, B) |
| `src\windows\launch_autoclaw_clone.ps1` | BS-2 CRITICAL (one-token `--user-data-dir` quoting + profile metachar guard) + 10 more | `_bug_sweep\fixes\11-fixes.md` |
| `src\windows\launch_zcode_second_instance.ps1` | BS-4: 2 HIGH + 4 MEDIUM | `_bug_sweep\fixes\10-fixes.md` (sync-path hunk already applied — skip) |
| `src\windows\reset_zcode.ps1` | BS-5: 24h purge floor + honest purge audit + watchdog verdict | `_bug_sweep\fixes\BLOCKED_FIXES.md` §2 (Diffs A–C) |
| `src\python\ghost\sqlite_keys.py` + `tests\python\test_ghost_core.py` | BS-6: 3 LOW + the suite-green test rename | `_bug_sweep\fixes\BLOCKED_FIXES.md` §5 |

Key diff shapes (for the reviewer, full text in the staged files):

- paired.json: replace backup-then-delete with **delete-only** — no backup, no
  `copy` action; the audit's `present→absent` entry is the record. The
  `-BackupRoot/-BackupLabel/-Actions` parameters are kept for call-site
  compatibility but intentionally unused.
- quoting: the 5th `Start-Process` ArgumentList element becomes ONE token
  quoted once: ``"`"--user-data-dir=$CloneProfile`"`` — plus a metachar guard
  (`& ^ % ! " | < >`) on `$CloneProfile`.
- purge floor: only backup dirs older than 24h are purgeable (never the current
  run's), and every delete re-verifies with `Test-Path` before auditing
  `deleted` / `still-present`.
- watchdog verdict: count `watchdog-recreate` audit entries with `ok=$false` →
  `$failCount++`, else `$passCount++`.

Procedure per file: step 0 re-verify → apply the diff exactly (count-checked
spans, CRLF preserved, BOM-less UTF-8) → `[System.Management.Automation.Language.Parser]::ParseFile`
0 errors (or `python -m py_compile` + unittest for the `.py`) → run the file's
test surface (Pester suites; `python -m unittest discover -s tests/python`
expecting 67/67 after the BS-6 rename) → record the log. Never run a reset or
launcher live as an automated gate; each fixes log lists what its pass could
NOT verify (live checks) — carry those rows into §7's live matrix.

Guard note: the guard trips on pre-existing credential-shaped lines, not on the
diffs. If the toolchain still refuses after the user approves an exemption,
apply the diffs manually; do not reformulate the flagged lines (they are
verified-correct scrub/read code and changing them is out of scope).

## 2. WS-2 — reset_qoder.ps1 (report 05; untouched by the first wave)

Item classes from `_bug_sweep\05-reset-qoder.md` (~3 HIGH): UTF-8 read sweep
(T2 class), tree-file call-site verdicts (T3), purge verify, argv insert, MAC
restore ledger. Procedure: step 0 re-verify per finding → apply → parse-check →
Pester. Nothing here may change step order, step titles, or audit keys.

## 3. WS-3 — watchers (report 12)

- `tools\watch_zcode_captcha.ps1`: per-tree Primary classification — a running
  clone's bare-cmdline main must not be labeled Primary (apply the AGENTS.md
  process-marker rule verbatim: classify mains by bare-exe CommandLine +
  roaming/home-dir markers, unmatched mains are Primary **only after** the
  marker walk); plus per-pass error isolation — one transient IOException must
  not permanently kill the resident: try/catch per pass, log the failure, keep
  polling, and write a stop line when the watcher truly exits.
- `tools\watch_zcode_taskbar.ps1`: the v6-title fallback must not stamp a lone
  splash-phase clone with the Primary AUMID — align with the watcher's
  process-marker-first rule (the 2026-09-24 green-clone lesson).
- Both must keep their named-mutex single-instance, startup process scan, and
  autostart behavior intact; parse-check + Pester; no live kill/relaunch tests.

## 4. WS-4 — reset_trae.ps1 remainder (report 04) — re-verify first

2026-10-28 spot-checks found done-marker deletion, the UTF-8 sweep, the
no-`Get-Random` salt rule and the watchdog+purge verdict already present.
Walk report 04 item-by-item; apply only what is genuinely missing; expect a
short list. Close BS-9 with an explicit per-finding verdict table.

## 5. WS-5 — installers / change_device_id / scaffold LOWs (reports 14, 09, 20)

- v1 shortcut installers (`install_zcode_second_shortcuts.ps1`,
  `install_autoclaw_clone_shortcuts.ps1`): repair-failure abort (exit non-zero
  when a `-RepairPrimaryAumid` repair fails) + report-14 LOWs.
- `change_device_id.ps1` MEDIUMs: registry-load exit check, RepairProfiles
  `.bak` swap path validation (profile must exist before the swap — lockout
  risk), honest exit codes on failure paths, UTF-8 restore script. (The `.bak`
  HIGH is already fixed — verified.)
- `tools\new_clone_suite.ps1` remaining LOWs (report 20).

## 6. WS-6 — Python core: read-only SELECT probe (02-F08) + suite green

Add a read-only SELECT subcommand to the core (parameterized SQL, JSON rows
out) so reset scripts can verify-by-select without temp `.py` heredocs; then
wire the cursor steps [3]/[14] probes per report 02-F08. Sequence AFTER WS-1's
test-file rename lands so the suite is green as the baseline. Respect the
AGENTS.md rule: core logic lives in `src/python/ghost`, never re-embed Python
in PS.

## 7. Acceptance gates

- Per `.ps1`: `Parser::ParseFile` 0 errors. Per `.py`: `py_compile` + unittest.
  `.mjs` engines are not touched by this plan.
- Pester: `Invoke-Pester -CI -Output Detailed` green (repo-integrity included).
- Python suite 67/67 after BS-6 lands.
- No live destructive run as an automated gate. A supervised live matrix (one
  box, instances closed → open) covers the fixes logs' "NOT verified" rows:
  one reset per touched script class, one clone launch per touched suite,
  `-DryRun` where present.
- Never-silent-success: every applied fix keeps verify-after semantics; purge/
  backup changes must leave honest audit entries (`still-present`, `skipped`).

## 8. Implementation order

1. TASK_BACKLOG §2 unblock decision (user).
2. WS-1 five files — CRITICALs first: `reset_autoclaw.ps1`, then
   `launch_autoclaw_clone.ps1`, then the rest.
3. WS-2 (qoder), WS-3 (watchers).
4. WS-4 (trae close-out), WS-5, WS-6.
5. Supervised live matrix + the CHANGELOG remediation entry (backlog DT-4).

Every phase leaves the tree uncommitted for review (project rule: no
auto-commit).

## 9. Out of scope

- ZCode W1 hardening (docs/ZCODE_RESET_EDGE_CASES_PLAN.md) — but
  `reset_zcode.ps1` appears in BOTH: land the WS-1 diffs and the W1 edits in
  ONE unblocked window to avoid re-tripping the guard twice.
- Thin-manifest migrations (see THIN_MANIFEST_MIGRATION_QUEUE_PLAN.md) — a
  script migrates only after its fixes land here.
- New features of any kind; `identity_utils.ps1` beyond what the parent already
  changed in wave 1.
