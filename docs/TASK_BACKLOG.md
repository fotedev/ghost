# GHOST Task Backlog (2026-10-28 survey)

Single tracked index of every open task in the repo. Motivation: the local-only
work folders (`_analysis/`, `_bug_sweep/` — both gitignored) hold the raw
findings and the 2026-10-24 remediation state, but nothing tracked records it;
this backlog carries the essential status into the repo. Every item below was
re-verified against the current checkout on 2026-10-28 unless quoted otherwise.
Line numbers are evidence anchors, not contracts.

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
| BS-1 | H (CRITICAL) | `reset_autoclaw.ps1` — `devices\paired.json` (a LIVE admin-scoped operator token) is backed up before deletion and the generated restore script resurrects it over the gateway-regenerated one. Plus step [2/7] must pass `-RedactKeys @("privateKeyPem")` so ed25519 keys stop leaking into the audit JSON. | OPEN — backup-then-delete confirmed in code | `_bug_sweep\fixes\BLOCKED_FIXES.md` §1, Diffs A+B |
| BS-2 | H (CRITICAL) | `launch_autoclaw_clone.ps1` — the `--user-data-dir` argument embeds quotes inside the token; under `CommandLineToArgvW` a spaced profile path truncates at the space, so the clone's gateway writes into the **Primary's** `~/.openclaw-autoclaw`. Plus 10 more findings in the same file (UTF-8 reads, `-Status` lockfile probe, pid-attribution lockfile sampling, `'*.backup'` seed glob, `.preseed` cleanup). | OPEN — the quoted-inside-token form confirmed (~line 684) | `_bug_sweep\fixes\11-fixes.md` (staged hunks) |
| BS-3 | — | `install_autoclaw2_clone_shortcuts.ps1` base AUMID read from v1's `.lnk` (cross-suite contamination) | DONE 2026-10-24 — constant `com.zhipuai.autoclaw2` + failure exits verified in code | `fixes\FIXES_SUMMARY.md` |
| BS-4 | H×2 M×4 | `launch_zcode_second_instance.ps1` — telegram fingerprint-failure must really disable (not preserve the duplicate bot), seed completion marker + Primary-closed gate, verify-after on the seed writes, RNG deviceSid, Add-Type guard, branding try/catch. | OPEN (BLOCKED) — but the sync-path item is already fixed (`..\..\tools` verified in code); re-diff hunk-by-hunk before applying | `_bug_sweep\fixes\10-fixes.md` |
| BS-5 | H×2 | `reset_zcode.ps1` — the [27] purge wipes same-day backups (incl. `reset_qoder.ps1`'s fresh ones; the Qoder keep-dir never exists) and audits unverified deletes; the watchdog step prints `Pass` and exits 0 even when re-deletes fail. | OPEN — unconditional `$passCount++` confirmed | `_bug_sweep\fixes\BLOCKED_FIXES.md` §2, Diffs A–C |
| BS-6 | L×3 | `sqlite_keys.py` — URI-quoted read-only connect, `"ok"` in the `sqlite_update` return, rowcount-gated `delete_secrets`; plus the test rename (`test_existing_destination_is_clobbered` → `test_existing_destination_is_uniquified`) that turns the suite green (66/67 today — the only red). | OPEN (BLOCKED) | `_bug_sweep\fixes\BLOCKED_FIXES.md` §5 |
| BS-7 | H×3 | `reset_qoder.ps1` — untouched by the remediation (UTF-8 reads, tree-file call-site verdicts, purge verify, argv insert, MAC restore ledger). | OPEN — pending scope | `_bug_sweep\05-reset-qoder.md` |
| BS-8 | H | Watchers — `watch_zcode_captcha.ps1` labels a running clone's bare-cmdline main "Primary" (spurious Primary relaunch when only clones run) and has no per-pass error isolation (one transient IOException permanently kills the resident, no stop line logged); `watch_zcode_taskbar.ps1` v6-title fallback can stamp a lone splash-phase clone with the Primary AUMID. | OPEN — pending scope | `_bug_sweep\12-zcode-watchers.md` |
| BS-9 | M/L | `reset_trae.ps1` remainder. Spot-checks 2026-10-28: done-marker deletion, the UTF-8 sweep, the no-`Get-Random` salt rule, and the watchdog+purge verdict block are ALL already present — the FIXES_SUMMARY pending list is stale. Walk report 04 item-by-item to confirm and close. | LIKELY MOSTLY DONE — re-verify | `_bug_sweep\04-reset-trae.md` |
| BS-10 | M/L | v1 shortcut installers repair-failure abort + LOWs (report 14); `change_device_id.ps1` MEDIUMs — reg-load exit check, RepairProfiles `.bak` path validation (lockout risk), exit codes on failure paths, UTF-8 restore script (report 09); scaffold LOWs (report 20). | OPEN — pending scope | `_bug_sweep\14-…`, `09-…`, `20-…` |
| BS-11 | M | Python core: a read-only SELECT probe subcommand (report 02-F08 was SKIPPED only because the core was parent-owned during the child pass; several reset steps want verify-by-select without heredocs). | OPEN | `_bug_sweep\02-reset-cursor.md` F08 |

## 2. Prerequisite: the write-guard unblock decision

Five files reject ANY agent-toolchain write: the guard scans the whole
resulting file and matches **pre-existing credential-shaped lines** (token
READS, api-key BLANKING code, redacted-looking test constants) — none is a real
credential. Not bypassed, per the guard's own instruction. This blocks BS-1,
BS-2, BS-4, BS-5, BS-6 (2 CRITICAL + 4 HIGH total), the ZCode W1 hardening (§3),
and the suite-green test rename (BS-6). AGENTS.md records the same
false-positive class on `reset_zcode.ps1` [6b] since 2026-10-23.

Options: (a) apply the staged diffs manually in an editor — fastest, the diffs
are ready and span-checked; (b) approve a guard exemption for these five files
and re-run the fix pass; (c) a mix. This single decision unblocks the highest-
severity work in the repo.

## 3. ZCode reset hardening — W1 / W2-3 / W3-2 / W4 (spec exists)

Source + spec: [ZCODE_RESET_EDGE_CASES_PLAN.md](ZCODE_RESET_EDGE_CASES_PLAN.md)
(W1-1..W1-10 script-side items deferred 2026-10-23 on the same guard false
positive; W2-1 confirm gate, W2-2 relaunch note, W2-4 label, W3-1 watchdog
clone-aware relaunch and harness scenario M shipped). Remaining:

- **W1-1..W1-10** in `reset_zcode.ps1`: shared-CLI-db scrub for clone-only
  resets (`clear-cli-telemetry` exists in the core — verified), Qoder steps
  gated on Primary, strict backup mode (no backup ⇒ no mutation), incremental
  audit/restore, purge retention policy (overlaps BS-5 — same file, sequence in
  the same unblocked window), empty-target WARN, elevation marker + exit-code
  relay, Python preflight, `-DryRun`, partial-profile WARN + header/usage fix.
- **W2-3** optional dry-run menu entry; **W3-2** reset-side watchdog-running
  preflight WARN.
- **W4-1** `AGENTS.md` launch-gid list add 41 (verified still missing
  2026-10-28); **W4-2** harness scenarios: a two-token ZCode chain end-to-end
  and unknown-token continuation (scenarios A–R exist; those two do not);
  **W4-3** `clear-cli-telemetry` tests (empty + locked DB; the test file is
  guard-blocked — sequence after §2).

## 4. Thin-manifest migration queue (roadmap exists; execution spec new)

Roadmap: [PYTHON_HYBRID_ROADMAP.md](PYTHON_HYBRID_ROADMAP.md) — pilot accepted
2026-10-18; `reset_cursor.ps1` v0.3 and `reset_devin.ps1` v0.4 landed. Per-
script execution breakdown + the fix-before-migrate sequencing gate:
[THIN_MANIFEST_MIGRATION_QUEUE_PLAN](THIN_MANIFEST_MIGRATION_QUEUE_PLAN.md).
Queue: trae → qoderwork → minimax → qoder → zcode (one script per session,
pattern reviewed after each). Gate: a script migrates only AFTER its sweep
fixes land — trae after BS-9 closes, qoderwork/minimax are ready, qoder after
BS-7, zcode last after W1 + BS-5.

## 5. Clone-suite future work

| ID | Sev | Task | Status | Spec |
|----|-----|------|--------|------|
| CS-1 | M | OpenCode definitions-only Primary→clone config sync — per-clone provider/MCP definitions are manual today; `~\.config\opencode\opencode.jsonc` holds LIVE API keys and must never be copied wholesale (needs the scrub design) | OPEN — future work (OPENCODE_CLONES_SPEC §7) | [OPENCODE_CONFIG_SYNC_PLAN](OPENCODE_CONFIG_SYNC_PLAN.md) |
| CS-2 | L | Cline window-level taskbar identity — running windows share the base identity (one grouped button, identical titles); shortcut pins are per-clone only. No asar surface (Tauri) — a launcher-side stamping helper is the only route | DEFERRED-BY-DECISION (developer, 2026-10-24) — design captured, implement only on an explicit go | [CLINE_WINDOW_IDENTITY_PLAN](CLINE_WINDOW_IDENTITY_PLAN.md) |
| CS-3 | L | AutoClaw2 window-level identity via the v1 asar route | DEFERRED-BY-DECISION ("until actually needed", AUTOCLAW2_CLONES_SPEC §7) | none (deliberate) |
| CS-4 | OPS | AutoClaw live-verification backlog: inst2 manual login, inst3/inst4 first launches, then the spec checklist (independent `deviceId`s per clone and vs Primary, `paired.json` purity, all four gateway + MCP `/health` answers, actual-port recording with drift) | OPEN — recorded in AUTOCLAW_CLONES_SPEC.md checklist | AUTOCLAW_CLONES_SPEC.md |
| CS-5 | OPS | `tools\opencode-orange-branding\` is a generated PLACEHOLDER — drop developer renders in and re-run `install_opencode_clone_shortcuts.ps1` | OPEN (AGENTS.md, 2026-10-24) | AGENTS.md tools notes |
| CS-6 | L | "Stale version preflight lane" in `reset_minimax_opencode.ps1` — re-verified 2026-10-28: `Programs\@opencode-aidesktop` IS the first probed lane, the code is already right; the OPENCODE_CLONES_SPEC §7 bullet is stale → docs fix only | DONE-since-source (docs note stale) | OPENCODE_CLONES_SPEC §7 |

## 6. Docs & release hygiene

- **DT-1**: `AGENTS.md` launch-gid list add 41 (W4-1) — see §3.
- **DT-2**: harness scenario gaps (two-token chain, unknown-token continuation) — see W4-2 in §3.
- **DT-3**: `clear-cli-telemetry` tests (empty + locked DB) — see W4-3 in §3 (guard-blocked until §2).
- **DT-4**: `CHANGELOG.md` has no record of the 2026-10-24 sweep remediation (the sweep folders are gitignored). When releasing, summarize from `_bug_sweep\fixes\FIXES_SUMMARY.md` (fixed table + blocked list).

## Priority order

1. §2 unblock decision → apply BS-1..BS-6 staged diffs (2 CRITICAL + 4 HIGH).
2. BS-7 (qoder) and BS-8 (watchers) — the real remaining pending scopes.
3. BS-9 / BS-10 / BS-11 — re-verify item-by-item, close what is genuinely open.
4. ZCode W1 (after BS-5, same file — one unblocked window) + W2-3 / W3-2 / W4.
5. Migration queue (trae first).
6. CS-1 (+ the CS-6 docs note) and DT items; CS-2 / CS-3 only on a developer go.
7. OPS items (CS-4, CS-5) whenever the user drives them.

## Recorded non-tasks (do not re-derive)

- Python Phase 2 (leaf tools → Python) — CANCELLED with reasons (roadmap).
- Cline / AutoClaw2 / OpenCode clone reset scripts — clone reset = stop
  instance + delete the clone home + relaunch (per each suite's spec).
- `ZCode/` (vendored reverse-engineering reference), `archive/`, `_analysis/`,
  `_bug_sweep/` — local-only, gitignored.
- `testResults.xml` / `.pytest_cache` / `NUL` — gitignored, not tasks.
