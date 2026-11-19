# GHOST Task Backlog (2026-10-28 survey)

Single tracked index of every open task in the repo. Motivation: the local-only
work folders (`_analysis/`, `_bug_sweep/` — both gitignored) hold the raw
findings and the 2026-10-24 remediation state, but nothing tracked records it;
this backlog carries the essential status into the repo. Every item below was
re-verified against the current checkout on 2026-10-28 unless quoted otherwise.
Line numbers are evidence anchors, not contracts.

**Re-status 2026-11-15**: the staged-diff hardening wave shipped (BS-4 →
PR #72, BS-5 → PR #73, BS-6 → PR #74) and BS-9 / BS-11 / CS-6 / DT-1 were
walked to closure item-by-item against the current code — statuses below
reflect that pass. The Phase 3 migration queue is COMPLETE (#67–#71).
**Second pass same day**: BS-7 walked vs the v0.5 manifest and fixed
(#76), BS-8 closed verification-only (all 9 findings pre-fixed), W1-2 and
W4-3 done (#77). The whole H-severity bug-sweep tier is now closed; the
remaining tiers were the W1 remainder (done 2026-11-15, §3), BS-10 (done
2026-11-16, §1) and CS-1 (done 2026-11-16, §5) — the recorded backlog is
now fully walked and closed (see the priority order at the bottom).

Status vocabulary:

- **OPEN** — recorded as a task, not done.
- **BLOCKED** — the agent toolchain cannot write the file (workspace write-guard
  false positives; see §2). Diffs are staged and ready.
- **DEFERRED-BY-DECISION** — a recorded decision to not do it now; a design may
  still be captured so a later go costs one session.
- **OPS** — a user-driven live action (launches, logins, icon drops), not code.
- **DONE-since-source** — the source doc says pending, but the current code
  already has the fix (re-verified 2026-10-28).

Severity: **H** = wrong privacy outcome / data loss / silent success; **M** =
misleading or unrecoverable UX; **L** = cosmetic/robustness (repo convention).

---

## 1. Finish the 2026-10-24 bug-sweep remediation

Canonical sources: `_bug_sweep\BUG_REPORT.md` (~196 findings: 3 CRITICAL /
24 HIGH / 75 MEDIUM / 94 LOW) and `_bug_sweep\fixes\FIXES_SUMMARY.md` (the
remediation ledger — all uncommitted, in the working tree). Execution spec:
[BUG_SWEEP_REMEDIATION_PLAN](BUG_SWEEP_REMEDIATION_PLAN.md).

Already fixed in the first wave (scopes 02, 03, 07, 08, 13, 15, 16, 17 fully;
11's v2 files; plus parent fixes to `identity_utils.ps1`, the Python core,
`install_autoclaw2_clone_shortcuts.ps1` (critical #3 — verified in code),
`change_device_id.ps1` (the `.bak` HIGH), `ghost.sh`, `new_clone_suite.ps1`,
and the trae UTF-8 sweep). What remains:

| ID | Sev | Task | Status (verified 2026-10-28) | Fix location |
|----|-----|------|------------------------------|--------------|
| BS-1 | H (CRITICAL) | `reset_autoclaw.ps1` — `devices\paired.json` (a LIVE admin-scoped operator token) is backed up before deletion and the generated restore script resurrects it over the gateway-regenerated one. Plus step [2/7] must pass `-RedactKeys @("privateKeyPem")` so ed25519 keys stop leaking into the audit JSON. | MOOT 2026-10-31 — file removed with the AutoClaw v1.20 sunset (git history / `archive/autoclaw-v1.20/`) | `_bug_sweep\fixes\BLOCKED_FIXES.md` §1, Diffs A+B |
| BS-2 | H (CRITICAL) | `launch_autoclaw_clone.ps1` — the `--user-data-dir` argument embeds quotes inside the token; under `CommandLineToArgvW` a spaced profile path truncates at the space, so the clone's gateway writes into the **Primary's** `~/.openclaw-autoclaw`. Plus 10 more findings in the same file (UTF-8 reads, `-Status` lockfile probe, pid-attribution lockfile sampling, `'*.backup'` seed glob, `.preseed` cleanup). | MOOT 2026-10-31 — file removed with the AutoClaw v1.20 sunset (git history / `archive/autoclaw-v1.20/`) | `_bug_sweep\fixes\11-fixes.md` (staged hunks) |
| BS-3 | — | `install_autoclaw2_clone_shortcuts.ps1` base AUMID read from v1's `.lnk` (cross-suite contamination) | DONE 2026-10-24 — constant `com.zhipuai.autoclaw2` + failure exits verified in code | `fixes\FIXES_SUMMARY.md` |
| BS-4 | H×2 M×4 | `launch_zcode_second_instance.ps1` — telegram fingerprint-failure must really disable (not preserve the duplicate bot), seed completion marker + Primary-closed gate, verify-after on the seed writes, RNG deviceSid, Add-Type guard, branding try/catch. | **FIXED 2026-11-15 — PR #72**: all `10-fixes.md` designs applied and adapted to the current launcher (marker seed gate `.zcode-seeded`/`.zcode-seeding` + adopt path, Primary-closed copy gate 180 s fail-CLOSED, verify-after on all six scrub writes + a FAILED scrub throws before launch, CSPRNG deviceSid with rejection sampling, fail-closed multi-bot telegram reconcile with verified disables + withheld marker, title-only window resolve, branding try/catch, Add-Type guard). The recorded skips stand: sync path was already fixed, UIPI probe not feasible | `_bug_sweep\fixes\10-fixes.md` |
| BS-5 | H×2 | `reset_zcode.ps1` — the [27] purge wipes same-day backups (incl. `reset_qoder.ps1`'s fresh ones; the Qoder keep-dir never exists) and audits unverified deletes; the watchdog step prints `Pass` and exits 0 even when re-deletes fail. | **FIXED 2026-11-15 — PR #73** (= W1-5): 24 h retention floor + never the current run; `audit_*.json`/`restore_*.ps1` of purged runs preserved at the `ID_Backups` root (the D3 policy); deletes verified (`still-present` audited `ok=$false` + red FAILED); the watchdog step counts `watchdog-recreate` `ok=$false` into `failCount`. Verified with a 7-check functional probe of the extracted function | `_bug_sweep\fixes\BLOCKED_FIXES.md` §2, Diffs A–C |
| BS-6 | L×3 | `sqlite_keys.py` — URI-quoted read-only connect, `"ok"` in the `sqlite_update` return, rowcount-gated `delete_secrets`; plus the test rename (`test_existing_destination_is_clobbered` → `test_existing_destination_is_uniquified`) that turns the suite green (66/67 today — the only red). | **FIXED 2026-11-15 — PR #74**: (a) `quote(..., safe="/:")` ro-connect (spaced profile paths truncated the URI before), (b) `sqlite_update` returns `ok` (exact OR text-affinity match), (c) rowcount-gated exact-key deletes; (d) the test rename had already landed (`test_existing_destination_is_uniquified_not_clobbered`, suite green since) — +7 unittests, 189 OK | `_bug_sweep\fixes\BLOCKED_FIXES.md` §5 |
| BS-7 | H×3 | `reset_qoder.ps1` — untouched by the remediation (UTF-8 reads, tree-file call-site verdicts, purge verify, argv insert, MAC restore ledger). | **CLOSED 2026-11-15** — walked report 05 against the v0.5 thin manifest. Closed by the migration: the ANSI-decode HIGH (zero direct app-store reads left; every JSON mutation in the core) and the argv-insert MEDIUM (core `patch_argv_json` inserts the key when absent, winstore.py:315). Applied in PR W1: step [30] uses the sweep-tree core twin (was defined but NEVER called; the header promised it), the [21] purge got the #73 policy (24 h floor + manifest preservation + VERIFIED deletes), stale-marker deletion + `-PassThru` exit relay, taskkill stderr race caught, MAC ledger/restore = true inversion (previousValue/previousExisted/ifIndex/writeOk; `-InterfaceIndex` addressing), honest `Remove-QoderPathSafely` verdict + steps [20]/[21]/[22] count failures, stale "WIN-<8hex>" header fixed, final state.vscdb probe re-asserts instead of replaying audit. One finding stays OPEN: no top-level guard (the W1-4 class). Trae's purge got the same floor + preservation (deletes were already verified) | `_bug_sweep\05-reset-qoder.md` |
| BS-8 | H | Watchers — `watch_zcode_captcha.ps1` labels a running clone's bare-cmdline main "Primary" (spurious Primary relaunch when only clones run) and has no per-pass error isolation (one transient IOException permanently kills the resident, no stop line logged); `watch_zcode_taskbar.ps1` v6-title fallback can stamp a lone splash-phase clone with the Primary AUMID. | **CLOSED 2026-11-15 — verification-only**: all 9 report-12 findings are ALREADY FIXED in current code (the same FIXES_SUMMARY staleness BS-9 proved). Evidence, file:line against the current checkout: captcha HIGH = per-tree marker classification with copy-family patterns + empty-cmdline ambiguity (`Get-ZcodeInstanceSnapshot`, watch_zcode_captcha.ps1:454+); exe resolution = live path + 3-candidate fallback (`Resolve-ZCodeExe` :153); per-pass try/catch + atomic temp+rename state writes + "watchdog stopped" log (:1236-1258); parsed-fields-only 1305 (:890); hourly-cap requeue (:793); midnight day-switch drain (:958-985); `-RunOnce` scan exclusion (:1211); taskbar Primary-never-guesses-from-bare-'ZCode' guard (:317-325); `SeenHwnds` per-pass prune (:330-336); same `-RunOnce` exclusion (:503) | `_bug_sweep\12-zcode-watchers.md` |
| BS-9 | M/L | `reset_trae.ps1` remainder. Spot-checks 2026-10-28: done-marker deletion, the UTF-8 sweep, the no-`Get-Random` salt rule, and the watchdog+purge verdict block are ALL already present — the FIXES_SUMMARY pending list is stale. Walk report 04 item-by-item to confirm and close. | **CLOSED 2026-11-15** — walked report 04 against v0.3: ANSI-decode HIGH closed (every JSON mutation in the core; remaining PS reads use explicit `-Encoding UTF8`), broad-substring + schema-skips closed by `scrub-rows` (ESCAPE'd adjacency, `skipped_tables` reported), watchdog step [16] counts failures, purge verified, `.Trim()` wrapped in try/catch, salt via `salt-rotate` (0 `Get-Random`), cline-host counted in the clean check, `sweep-tree` verify-after by recount, watchdog probe expanded 4→6. One remainder APPLIED: `-PassThru` + exit-code relay in the self-elevation. One finding stays OPEN: no top-level guard before the end-of-run audit/restore write (= the W1-4 incremental-audit class). Observation: trae's purge has no 24 h floor (the W1-5 policy was decided for reset_zcode only) — candidate follow-up | `_bug_sweep\04-reset-trae.md` |
| BS-10 | M/L | v1 shortcut installers repair-failure abort + LOWs (report 14); `change_device_id.ps1` MEDIUMs — reg-load exit check, RepairProfiles `.bak` path validation (lockout risk), exit codes on failure paths, UTF-8 restore script (report 09); scaffold LOWs (report 20). | **CLOSED 2026-11-16** — walked reports 14/09/20 against current code first (the staleness pattern again: 9 findings already fixed, 9 obsolete with the v1-suite deletions). Genuinely open = 18 (6 M / 12 L), all closed: **report 09 → PR #81** (change_device_id.ps1: reg-export `$LASTEXITCODE` checks with pre-destructive abort, `.bak` `ProfileImagePath` on-disk validation before the swap, no-BOM-UTF-8 restore script, failure-path exit 1 / success exit 0, create-branch verify-after, Read-State absent-vs-unreadable sentinel + Write-State refusal, HKCU pass dedup via the SID-pass written-set). **report 14 → PR #83** (zcode installer: clean-only base-AUMID adoption + hard stop vs the `dev.zcode.app.2.2` poisoning, repair+`-Remove` honored, `.Description` verify, header N=2..6; autoclaw2: exe-existence-guarded icon fallback + `-Remove` verify-after; plus the same defect classes in the newer opencode/cline installers — `$script:Failed`/exit 1 plumbing, the 14-C1-class stock-lnk base guard, remove-verify, opencode repair FAILs recorded). **report 20 → PR #84** (new_clone_suite: intake-driven menu wiring — per-clone Launch/Reset rows+gids, `-BatPath` fixture probe; the range-header replace was found to be a silent NO-OP vs the real "(1-109; 63 unused…)" format and fixed + verified; real skeleton helper signatures; full shortcut verify-after; make_clone_icon `-ManualCrop` bounds throw; make_ghost_icon classifier constants named in the failure message). Pester 238→238→238 then 250 with CS-1 | `_bug_sweep\14-…`, `09-…`, `20-…` |
| BS-11 | M | Python core: a read-only SELECT probe subcommand (report 02-F08 was SKIPPED only because the core was parent-owned during the child pass; several reset steps want verify-by-select without heredocs). | **CLOSED 2026-11-15** — the `count-keys` verb (PR #70) IS the probe: READ-ONLY survivor count, no mutation, no table creation, exact + LIKE on ItemTable (`purge-keys` / `scrub-rows` / `purge-tables` cover the remaining report-02 needs) | `_bug_sweep\02-reset-cursor.md` F08 |

## 2. ~~Prerequisite: the write-guard unblock decision~~ — RESOLVED-IN-PRACTICE (2026-11-15)

The 2026-10 guard false positives (five files rejecting ANY write on
**pre-existing credential-shaped lines** — token READS, api-key BLANKING
code, redacted-looking test constants) no longer fire: the exact files it
blocked were edited repeatedly by later sessions (`launch_zcode_second_instance.ps1`
in the #43 era, `reset_zcode.ps1` across #67–#71, `sqlite_keys.py` in #70–#71).
The staged designs in `_bug_sweep\fixes\` are now applied: BS-4 → PR #72,
BS-5 → PR #73, BS-6 → PR #74 (BS-1/BS-2 went MOOT with the v1.20 sunset).
Standing fallback unchanged: if `artifact_secret_detected` ever fires on one
of these files again, stop and surface to the user — never bypass the guard
(precedent: BLOCKED_FIXES.md).

## 3. ZCode reset hardening — W1 / W2-3 / W3-2 / W4 — **FULLY APPLIED 2026-11-15**

Source + spec: [ZCODE_RESET_EDGE_CASES_PLAN.md](ZCODE_RESET_EDGE_CASES_PLAN.md)
(W1-1..W1-10 script-side items deferred 2026-10-23; W2-1 confirm gate, W2-2
relaunch note, W2-4 label, W3-1 watchdog clone-aware relaunch and harness
scenario M shipped 2026-10-23; the W1 script-side items + W2-3 + W3-2 +
W4-2/W4-3 landed 2026-11-15 across PRs #71/#73/#77/#78/#79 and the W1-9
pass — every item is DONE; the live destructive matrix in the spec's §6
remains user-supervised).

- **W1 remainder** in `reset_zcode.ps1` — **FULLY APPLIED 2026-11-15** (all
  of W1-1..W1-10 + W2-3 + W3-2 + W4-2; W1-2/W1-5/W1-8 closed earlier):
  W1-9 `-DryRun` report-only planner (skips elevation + Python preflight;
  verified zero-write under redirected fixtures) + W2-3 the GHOST.bat
  ZCode [33] / gid 109 menu row (:RunWith dispatch, hub-parity ARGS word-
  split added) + W3-2 the captcha-watchdog mutex preflight WARN + W4-2 the
  two harness scenarios (V two-token chain end-to-end through the real
  dry-run planner, W ZCode unknown-token continuation) + the harness CWD
  pin (`cd /d "%~dp0"` → repo root) so dispatched-script scenarios resolve
  repo-relative paths.
- **W2-3** optional dry-run menu entry; **W3-2** reset-side watchdog-running
  preflight WARN.
- **W4-1** `AGENTS.md` launch-gid list add 41 — **OBSOLETE (closed
  2026-11-15)**: the list was restructured away in the 2026-10-29+
  AGENTS.md rewrites (no launch-gid enumeration remains — grep
  "launch-gid" = 0; the gid map lives in GHOST.bat's resolver).
  **W4-2** harness scenarios: a two-token ZCode chain end-to-end
  and unknown-token continuation (scenarios A–R exist; those two do not);
  **W4-3** `clear-cli-telemetry` tests (empty store + locked DB) —
  **DONE 2026-11-15** (both cases in tests/python/test_ghost_core.py;
  unittest 189 → 191 OK).

## 4. Thin-manifest migration queue (roadmap exists; execution spec new)

Roadmap: [PYTHON_HYBRID_ROADMAP.md](PYTHON_HYBRID_ROADMAP.md) — pilot accepted
2026-10-18; per-script execution breakdown:
[THIN_MANIFEST_MIGRATION_QUEUE_PLAN](THIN_MANIFEST_MIGRATION_QUEUE_PLAN.md).
**COMPLETE 2026-11-14** — PRs #67–#71 (trae v0.3 → qoderwork v0.2 → minimax
v1.4 → qoder v0.5 → zcode v1.5, one script per PR, pattern reviewed after
each; zero temp-.py heredocs remain). The fix-before-migrate sequencing gate
was consciously superseded by the approved migration plan; the hardening debt
it guarded was carried as BS-4/BS-5/BS-6 and is now paid (see §1).

## 5. Clone-suite future work

| ID | Sev | Task | Status | Spec |
|----|-----|------|--------|------|
| CS-1 | M | OpenCode definitions-only Primary→clone config sync — per-clone provider/MCP definitions are manual today; `~\.config\opencode\opencode.jsonc` holds LIVE API keys and must never be copied wholesale (needs the scrub design) | **DONE 2026-11-16 — PR #85**: the plan's scrub design implemented (D2 = the developer-picked default: providers sync WITHOUT apiKey + one loud WARN per clone). `tools\opencode_config_merge.ps1` (pure core: the zcode invariant over `mcp`+`provider` + the DEEP secret scrub — the real shape `provider.<id>.options.apiKey` would have defeated a top-level scan; clone-local secrets survive; no placeholders) + `tools\sync_opencode_config.ps1` (jsonc reader, lockfile-held SKIP, config-less SKIP, backup + verify-after + names-only JSONL audit, Primary hash re-checked) + the launcher `[2b/5]` pre-launch step (failed sync warns, never blocks). 12 Pester tests; fixture acceptance = plan §5 items 1/3/4/5 + idempotence (§5.2/§6 live runs user-supervised). **v2 DONE 2026-11-17**: the GHOST.bat/menu wiring deferral closed (OpenCode [21]/[22] = gids 110/111) + the resident watcher `tools\watch_opencode_config_sync.ps1` shipped (mutex `OpencodeConfigSyncWatcher`, launcher [2c/5] launch-ensure, 19 Pester tests) | [OPENCODE_CONFIG_SYNC_PLAN](OPENCODE_CONFIG_SYNC_PLAN.md) |
| CS-7 | L | OpenCode config-sync live-apply — a RUNNING clone's config re-read timing (per app-server spawn, like ZCode, or launch-only) is UNVERIFIED; until probed, the watcher syncs definitions but cannot recycle a live instance | OPEN — needs a Phase-0 probe against a live clone (app logs / process behavior), then either a guarded `-ApplyLive` on the watcher (zcode idle-guard mechanics) or a documented launch-only contract | [OPENCODE_CONFIG_SYNC_PLAN](OPENCODE_CONFIG_SYNC_PLAN.md) |
| LC-1 | OPS | ZCode Linux clone layer LIVE acceptance — the launchers/resets shipped DERIVED (PR 8, 2026-11-17): run launch_zcode_clone.sh + reset --instance + the light worker + sync_zcode_assets.sh (v0.1 MCP-only, 2026-11-17) on a real Linux host with the desktop build, record the running-layout evidence (window anatomy, .desktop integration, AppImage paths) and flip the platform.py Linux labels to verified. LC-1 evidence ALSO unlocks the skills/.agents/plugin-cache sync ports (Windows-specific mechanics; Linux analogs unproven on the real layout) | OPEN — user-supervised (needs a Linux host) | launch_zcode_clone.sh header (evidence-cited Phase-0) |
| CS-2 | L | Cline window-level taskbar identity — running windows share the base identity (one grouped button, identical titles); shortcut pins are per-clone only. No asar surface (Tauri) — a launcher-side stamping helper is the only route | **IMPLEMENTED 2026-11-17** (the developer go came with the parity build-out plan): `launch_cline_clone.ps1` stamps `bot.cline.app.cN` onto the launched process's main-window property store (the proven ZCode step-4 interop, ole32 `PropVariantClear`) + sets the distinct "Cline `<Color>` vN" title, re-stamps on handle change inside the poll, verifies by read-back, and degrades to a loud WARN without blocking (identity = cosmetic, plan acceptance 3). NO resident watcher (plan §3.5). Phase-0 live probes = `tools/probe_cline_window.ps1` (read-only, off-menu; probes a–c report live anatomy/class/store-AUMID/webview children/exe API scan; probe d = re-run after a clone restart) — **live acceptance user-supervised**; no window was running when shipped. 14 static Pester tests | [CLINE_WINDOW_IDENTITY_PLAN](CLINE_WINDOW_IDENTITY_PLAN.md) |
| CS-3 | L | AutoClaw2 window-level identity via the v1 asar route | DEFERRED-BY-DECISION ("until actually needed", AUTOCLAW2_CLONES_SPEC §7) | none (deliberate) |
| CL-1 | L | Cline light worker LIVE acceptance — `launch_cline_cli_light.ps1` shipped 2026-11-17 (Cline [22]/[23], gids 122/123) with two DERIVED behaviors that need a live run: (a) hub attach while the desktop clone is running (same CLINE_DIR + hub port — the CLI is expected to attach to the running hub, sessions shared); (b) CLI login persistence location (the desktop web login may not cover the CLI; the `-Auth` row is the fix but no file-verified check exists) | OPEN — user-supervised (run [22] with and without the desktop clone open; run [23] once and check a headless one-shot uses the account) | launch_cline_cli_light.ps1 header (Phase-0 evidence: `--help` 3.0.74 captured 2026-11-17) |
| AC-1 | L | AutoClaw2 light worker — **CLOSED-BY-EVIDENCE 2026-11-17, infeasible**: the installed 4.0.0 bundle has NO bin entry, NO cli bundle, NO argv flags (`process.argv` = relaunch args only), the Pi-derived "zcode" agent is embedded in `dist\main.cjs` and runs only inside the Electron main process, and the windowless harness mode is dev-gated off by an `isPackaged` early-return. Reusable-but-unsupported surfaces only (vendored bun/node runtimes, the internal HMAC execution-worker child, `zwork:remote-control:*` IPC). Do not re-derive without NEW bundle evidence (e.g. a future release shipping a CLI) | CLOSED — evidence recorded | none (bundle-mined verdict) |
| CS-4 | OPS | AutoClaw live-verification backlog: inst2 manual login, inst3/inst4 first launches, then the spec checklist (independent `deviceId`s per clone and vs Primary, `paired.json` purity, all four gateway + MCP `/health` answers, actual-port recording with drift) | MOOT 2026-10-31 — v1.20 sunset removed the suite, spec and checklist (git history / `archive/autoclaw-v1.20/`) | AUTOCLAW_CLONES_SPEC.md |
| CS-5 | OPS | `tools\opencode-orange-branding\` is a generated PLACEHOLDER — drop developer renders in and re-run `install_opencode_clone_shortcuts.ps1` | OPEN (AGENTS.md, 2026-10-24) | AGENTS.md tools notes |
| CS-6 | L | "Stale version preflight lane" in `reset_minimax_opencode.ps1` — re-verified 2026-10-28: `Programs\@opencode-aidesktop` IS the first probed lane, the code is already right; the OPENCODE_CLONES_SPEC §7 bullet is stale → docs fix only | **CLOSED 2026-11-15** — the stale §7 note rewritten (verified against the v1.4 thin manifest: the `@opencode-aidesktop` lane is probed first) | OPENCODE_CLONES_SPEC §7 |
| CS-8 | L | OpenCode cross-instance CHAT sync — the parity gap (ZCode + AutoClaw2 have chat tools; OpenCode/Cline don't; the deferred "chat-sync spike") | **IMPLEMENTED 2026-11-20** — the spike resolved FEASIBLE by store mining: sessions live IN `opencode.db` (`session_v2` → `project` FK; the whole message payload rides `session_message.data` JSON; `session_part`/`blob`/`blob_ref` declared but empty in the observed schema; per-session `instruction_state`/`instruction_entry` + hash-addressed `instruction_blob`; project ids STABLE per worktree path across instances; auth OUTSIDE the db — `account`/`credential`/`control_account` were 0 rows and are NEVER read). Shipped: `src/python/ghost/opencode.py` core verbs (`oc-chat-inventory/-import/-revert`; same-id PK idempotence — a reverted import is plannable again; ancestor+descendant family expansion; project row reuse-by-path or verbatim copy; one transaction + FK ON + WAL-safe sqlite3 backup + verify-after recount + sampled byte-compare; `chat-sync-manifest.json` sidecar; "[import] " title tag) + `tools\sync_opencode_chats.ps1` (default diff report, `-SessionIds`/`-AllMissing` plan, `-Apply`, `-DryRun`, `-Revert -ImportId`; CS-1 lockfile probe; db-less clone = SKIP; source opened read-only) + OpenCode [26]/[27] = gids 124/125 (ceiling 123→125 per the hub-menu raise rule; the retired v1 gids 37-40+63 stay reserved-dead). unittest 15 + Pester 15 + the orchestrator's %TEMP% fixture matrix (diff/plan/apply/idempotence/revert) all green. **LIVE acceptance = user-supervised**: import into a closed clone and confirm its UI lists the imported sessions after the next launch (the display hop is the one unverified step) | OPENCODE_CLONES_SPEC §7 |
| CS-9 | L | Cline cross-instance CHAT sync — the other deferred chat-sync spike | **DEFERRED-BY-EVIDENCE 2026-11-20 — the store map below is closed, do not re-derive it**: c1's hub store mined live — chat history = `data/sessions/<id>/<id>.json` + `<id>.messages.json` FILES plus a `data/db/sessions.db` that is a RUNTIME PROCESS REGISTRY (pid/status/cwd/`messages_path` pointers, 1 row total — NOT a history store) + `session-search.db` FTS + agenda/tasks/teams side dbs; data volume ~NIL (ONE session across c1..c3); the desktop UI's task-history source is UNVERIFIED (the `bot.cline.app`/`EBWebView` WebView2 profile is snappy-compressed LevelDB — a literal strings probe cannot see values, so whether the UI reads the hub store or webview-local IndexedDB — i.e. whether a hub-side import would even DISPLAY — is undecided); Cline checkpoints live in workspace git refs (`refs/cline/checkpoints`) and do NOT port. Reopen triggers: a live UI-history probe (the CS-2 probe analog) + real session volume | CLINE_CLONES_SPEC §7 |

## 6. Docs & release hygiene

- **DT-1**: `AGENTS.md` launch-gid list add 41 — **OBSOLETE (closed 2026-11-15)**: the list no longer exists after the AGENTS.md restructures; the gid map lives in GHOST.bat's resolver. See W4-1 in §3.
- **DT-2**: harness scenario gaps (two-token chain, unknown-token continuation) — see W4-2 in §3.
- **DT-3**: `clear-cli-telemetry` tests (empty + locked DB) — see W4-3 in §3.
- **DT-4**: `CHANGELOG.md` has no record of the 2026-10-24 sweep remediation (the sweep folders are gitignored). When releasing, summarize from `_bug_sweep\fixes\FIXES_SUMMARY.md` (fixed table + blocked list) — note the 2026-11-15 wave (PRs #72–#74) already carries CHANGELOG entries. — **DONE 2026-11-16 (PR #84)**: the release-note entry is IN the CHANGELOG now (fixed-table summary + the blocked trio's landing via #72–#74 + the staleness note).
- **DT-5**: MCP registry Phase 2 (optional, design done — `docs/MCP_CENTRAL_REGISTRY_PLAN.md` §6): `supergateway --config tools\mcp\master-mcp.json --port 8310 --host 127.0.0.1` serves every registry server on `http://127.0.0.1:8310/<name>/mcp`; `--host 127.0.0.1` is MANDATORY (upstream default binds every interface); persistent run via a Startup-folder `.lnk` (same pattern as the watchers); optional `--apiKey`. Port 8310 verified free on the dev host.

## Priority order (2026-11-20)

1. ~~§2 unblock decision → BS-1..BS-6 staged diffs~~ — DONE (BS-1/2 MOOT with the v1.20 sunset; BS-4/5/6 = PRs #72–#74).
2. ~~BS-8~~ — CLOSED verification-only (all 9 findings pre-fixed).
3. ~~BS-7~~ — CLOSED (#76: walked vs v0.5; remainders applied).
4. ~~ZCode W1 remainder~~ — FULLY APPLIED (#71/#73/#77/#78/#79 + the W1-9 pass; see §3).
5. ~~Migration queue~~ — COMPLETE (#67–#71).
6. ~~BS-10 + CS-1 + DT-4~~ — ALL CLOSED (BS-10 = PRs #81/#83/#84 after the walk; CS-1 = #85; DT-4 = #84). Also this pass: the runner-only CI failures from the 2026-11-14 wave fixed (PR #82 — Pester exe-identity dot-source guards, ubuntu-python platform guards, shellcheck `b64_json` stdin bug + dead params + justified suppressions).
7. Remaining recorded work: CS-2 / CL-1 / **CS-8** (the OpenCode chat-sync LIVE acceptance — import into a closed clone, confirm the UI lists it) live acceptance (user-supervised); CS-3 only on a developer go; CS-5 (orange branding renders) whenever the user drives it; CS-7 (OpenCode live-apply probe) whenever a Phase-0 probe is driven; DT-5 (supergateway, optional) is live dev-host setup = user-supervised; CS-9 (Cline chat sync) is DEFERRED-BY-EVIDENCE (store map closed, reopen triggers recorded). AC-1 (AutoClaw2 light worker) is CLOSED-BY-EVIDENCE — do not re-derive. The recorded bug-sweep backlog is now fully walked and closed; any further "pending" lists must be re-walked against current code first (the BS-8/BS-9/BS-10 lesson).

## Recorded non-tasks (do not re-derive)

- Python Phase 2 (leaf tools → Python) — CANCELLED with reasons (roadmap).
- Cline / AutoClaw2 / OpenCode clone reset scripts — clone reset = stop
  instance + delete the clone home + relaunch (per each suite's spec).
- `ZCode/` (vendored reverse-engineering reference), `archive/`, `_analysis/`,
  `_bug_sweep/` — local-only, gitignored.
- `testResults.xml` / `.pytest_cache` / `NUL` — gitignored, not tasks.
