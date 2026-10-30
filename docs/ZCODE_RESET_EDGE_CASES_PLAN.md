# ZCode Reset Options — Edge & Use-Case Coverage Plan

Scope: the ZCode submenu "Reset Clones" options in `GHOST.bat` —
[6] Second · [7] Both (Second+Primary) · [8] Third · [9] Fourth ·
[10] ALL SIX instances · [19] Fifth · [23] Sixth —
plus the adjacent Primary path [21], as implemented by `src/windows/reset_zcode.ps1` (v1.4) and
`src/windows/launch_zcode_second_instance.ps1`. (Written before the Sixth
instance existed: the old "[10] All five" label now reads "Reset ALL SIX
instances", and [23]/gid 65 are the Sixth entries; every finding below
applies verbatim to the sixth target.)

Status: PARTIALLY applied 2026-10-23 — shipped: W2-1 confirm gate (menu-side,
`:ConfirmReset` on gid 12 Both and gid 21 All-six — closes the F-09
confirmation gap), W2-2 relaunch note (menu-side via :RunZcodeReset), W3-1
watchdog clone-aware relaunch, W2-4 [6] label, harness scenario M. PENDING:
all W1-* script-side
items (blocked by a workspace write-guard false positive on the reset_zcode.ps1
[6b] apiKey-blanking assignment — user chose to defer those; the script is
untouched). Analysis source: five parallel read-only reviews
(`_analysis/a_reset_script.md`, `_analysis/b_menu_wiring.md`, plus answer-only reports under
`.zwork/runs/e711490b/`). Line numbers are from the current checkout and are evidence anchors,
not contracts.

> **RENUMBERED 2026-10-29** — GHOST.bat renumbered every submenu to display
> order (gids unchanged). Menu numbers below are the PRE-renumber ZCode rows;
> translate on read: [6] Second→[9] · [7] Both→[15] · [8] Third→[10] ·
> [9] Fourth→[11] · [10] ALL SIX→[16] · [19] Fifth→[12] · [21] Primary→[14] ·
> [23] Sixth→[13] · icon patch [12]→[27]. The W2-2 relaunch list
> "[1]/[3]/[4]/[18]/[41]" mixes old locals and a gid; the current equivalents
> are the five launch rows ZCode [1]-[5].

---

## 1. Verified baseline (works today — do not regress)

- Wiring is exact: [6]→gid 11 `-Target Secondary`, [7]→12 `Both`, [8]→19 `Third`,
  [9]→20 `Fourth`, [10]→21 `All`, [19]→42 `Fifth`, [21]→7 `Primary`. `docs/cli.md` matches;
  Fifth roots (`%APPDATA%\ZCode-Fifth`, `%USERPROFILE%\ZCodeFifthHome\.zcode`) are complete.
- `All` = Third→Fourth→Fifth→Secondary→Primary; `Both` = Secondary→Primary. Each child is a
  separate process with its own `New-IdentitySet` — duplicate IDs are structurally impossible.
  A failing child does not stop later children; any failure → exit 1.
- Per-target `ID_Backups\<ts>` + audit + restore script; every mutating helper verifies after
  write; step summaries are honest OK/FAILED/SKIP; missing roaming → up-front exit 1 before any
  kill; no registry writes; `Parser::ParseFile` clean.
- Survivor guarantee: marker-classified selective tree-kill of the target only, survivor check
  armed only when survivors exist at entry, Primary refuses to kill-all on ambiguous mains
  (bare-launched clone race handled per AGENTS.md rules).
- Menu batch hygiene is clean (no bare parens in blocks, detached launches respected); chains
  are sequential with a pause per entry (failures deliberately do not short-circuit).
- Launcher relaunch after reset works and does not reseed; `sync_zcode_assets` (launcher step
  2d) reintroduces nothing the reset stripped; taskbar watcher is benign during resets; Telegram
  `.telegram-routed` markers survive resets (matches "deliberate re-enable never reverted");
  `tasks-index.sqlite` is preserved → chats survive.

## 2. Findings catalog (ranked)

Severity: **H** = wrong privacy outcome / data loss / silent success; **M** = misleading or
unrecoverable UX; **L** = cosmetic/robustness.

| ID | Sev | Area | Finding | Evidence | Fix direction |
|----|-----|------|---------|----------|---------------|
| F-01 | H | identity coverage | Clone-only resets [6]/[8]/[9]/[19] scrub the **dead** clone-home `cli\db\db.sqlite`. The live **shared** `%USERPROFILE%\.zcode\cli\db\db.sqlite` (all instances read it; ~385 MB live) keeps `%telemetry%`/`%machineId%`/`%deviceId%` rows. Only Primary/Both/All reach it → cross-instance correlation trail survives every clone-only reset (contradicts the anti-correlation premise, AGENTS.md GT#1). | A §6.1 / §2 step [26]; C #3 | Add a shared-CLI-db scrub to clone-only runs: best-effort, lock-tolerant (10 s busy timeout), survivor-aware, WAL-safe backup, explicit WARN when it must skip. |
| F-02 | H | Qoder cross-scope | Single-target clone resets run **all** shared Qoder steps ([1,2,7,8,9,10,12,14,23,24,25]) because those steps are gated only by `$qoderPresent`/`-SkipQoder` — but the Qoder kill is Primary-only. GHOST.bat passes no `-SkipQoder` on gids 11/19/20/42. A running Qoder can re-persist `storage.json` after verify (silent revert of step [1]); a hard file lock can terminate the whole run **before** audit/restore are written (WriteAllText has no try/catch). Comment at L1547 ("clone targets never touch Qoder") contradicts the code. | A §5.4, L1544-1557 | Pass `-SkipQoder` from the four clone dispatches (mirrors Both/All semantics), or gate Qoder steps on `$Target -eq 'Primary'`; fix the comment either way. |
| F-03 | H | survivor guarantee | `tools/watch_zcode_captcha.ps1` (resident watchdog, ZCode submenu [9]) does `taskkill /IM ZCode.exe` — **all** instances, no survivor logic — then relaunches a bare `ZCode.exe` → Primary profile. If it fires during/after a reset, every "survivors kept running" claim is void and Primary is repolluted. | C #1 (L339-347, 372) | Reset preflight: detect a running watchdog (named mutex/process) and WARN loudly; watchdog fix: relaunch via launcher/shortcut instead of bare exe (separate small change). |
| F-04 | H | never-silent-success | Backup failure does not stop the mutation: `Backup-FileToTimestampDir` retries ~10.5 s, returns `$null` after WARN, then `Set-JsonIdentity` / `Set-SqliteKeys` / `Clear-ZcodeOAuthCredentials` / tree deletes proceed with **no restore entry**. A locked `credentials.json` = tokens unrecoverable. Also step [26]'s pre-copy is main-file only (no `-wal` sibling). | D #2 | Strict mode: backup `$null` ⇒ step FAILED and **skip mutation** (for stores that carry restore value); copy `-wal`/`-shm` or checkpoint for sqlite backups. |
| F-05 | M | recoverability | `audit_<ts>.json` + `restore_ZCode_<ts>.ps1` are written only at the END (L2408-11). A hard abort mid-run leaves backups but no manifest/restore script. | D #3 | Write audit/restore incrementally (append per step, finalize at tail) or checkpoint them after each mutating step. |
| F-06 | M | recoverability | Step [27/27] retains only the newest `ID_Backups` dir per target — a second reset the same day deletes the first run's backups **and** its restore scripts. Chained "10 6" or "[7] then [10]" makes the earlier restore set unrecoverable. | D #7, E G2 | Choose policy: keep N=2 runs, or exempt `restore_*.ps1`+`audit_*.json` from the purge, or keep retention=1 and state it in the summary (privacy-by-design is defensible — but must be explicit). |
| F-07 | M | classification | A clone launched as a bare `ZCode.exe` owns the **Primary** profile (no marker in its subtree), so a clone-target reset finds 0 targets → "OK" in ~3 s having killed nothing (on-disk clone stores are still reset). The ambiguity guard exists only for Primary. | A §4.3, L1320-1335 | Emit WARN when the target process set is empty: "no <Label> main found — if started bare it owns the Primary profile; relaunch via its clone shortcut". |
| F-08 | M | elevation | Self-elevation loses the child exit code (`Start-Process -Wait` without `-PassThru` → parent always exits 0) and prints `%TEMP%\zcode_v1.3_done.txt` even when stale (declined UAC / early abort) — a previous run's "Pass: n" can be shown. | B §3, D #4 | Delete the marker before relaunch; use `-PassThru` + `.ExitCode`; print marker only if written by this run. |
| F-09 | M | menu UX | No confirmation before [10] all-five (or [7]); plus numbering collisions at the MAIN menu: "21" = All-five but "21" in the ZCode submenu = Primary-only; "19" = Third at MAIN vs Fifth in-submenu. A mis-keyed gid jump is destructive with zero friction. | B §2, §5.2 | Confirm prompt for [10]/[7] (and any All-target gid); note the gid/local-number distinction on screen; keep batch paren rules. **Confirmation part CLOSED 2026-10-23** — `:ConfirmReset` now gates gid 12 (Both) and gid 21 (All-six) before dispatch. |
| F-10 | M | prerequisites | No Python preflight. Missing Python → steps [8][9][25][26] FAIL honestly + exit 1, but JSON steps already rotated → partial correlation trail. The "Python required for ALL steps" contract is Cursor/Devin-only today. | A §4.1, D #8 | Up-front functional probe (`Get-PythonCommandInfo`): abort before any mutation with a winget/python.org hint (or document partial as intended). |
| F-11 | L | parity | No `-DryRun` on `reset_zcode.ps1` (reset_autoclaw/reset_qoderwork have one); menu cannot offer a preview. | B §5.1, E gaps | Add `-DryRun` (report-only, no kills/writes/backups) + menu entry; `:Run` has a 3-arg budget — `-DryRun` fits. |
| F-12 | L | guidance | No post-reset relaunch note. A bare `ZCode.exe` relaunch lands on the Primary profile/AUMID. The only hint appears when the roaming dir is missing, not after a successful reset. | B §5.3, C #8 | `:RunWith` note after reset entries: relaunch via [1]/[3]/[4]/[18]/[41] or clone shortcuts — never bare exe. |
| F-13 | L | partial profile | Clone home exists but profile partial (aborted seed): reset SKIPs missing files and exits 0; launcher sees "profile exists" and skips reseed — no repair path. Roaming-without-home (U1) relies on helper `mkdir` — unverified interplay. | E G3/U1, A §4.3 | Detect partial profile (e.g. missing `v2\setting.json`) → explicit WARN + "reseed" hint; optional `-Reseed` mode (defer). |
| F-14 | L | hygiene | Header/usage omit Fifth (L4); dead `Stop-ZcodeQoderProcessesAggressive` (L995); [6] label "survivor" singular; harness tests never render [19]/[10] nor a 2-token chain; AGENTS.md launch-gid list omits 41; audit BOM inconsistency; `Get-Random` for salt/armsUid/deviceSid. | A §5, B §4/§8, C #9 | One cleanup pass; extend harness; doc nits. |

## 3. Decision points (needed before implementation)

| # | Question | Recommended |
|---|----------|-------------|
| D1 | Should clone-only resets also scrub the shared CLI db (F-01)? | **Yes** — best-effort, verify-after, WARN+skip if locked by a survivor; it is the core anti-correlation goal. |
| D2 | Qoder steps on clone resets: skip from the menu (`-SkipQoder`) or gate in-script on Primary? | **In-script gate** on `$Target -eq 'Primary'` (defense in depth; menu also stops passing them implicitly). |
| D3 | `ID_Backups` retention policy (F-06) | **Exempt restore/audit files from purge** (keep one data-dir generation, keep all restore scripts). |
| D4 | Python missing: hard abort up-front vs current per-step FAILED? | **Up-front abort** (thin-manifest contract; avoids half-rotated identity). |
| D5 | Confirmation prompts for [10]/[7] in the menu? | **Yes**, plain `choice`-style confirm; no parens in echo blocks. |
| D6 | Captcha-watchdog cooperation (F-03) in this scope? | **Yes, minimal**: reset warns if watchdog runs; watchdog relaunch switches to clone-aware relaunch. |
| D7 | Subset targets (Third+Fourth, Fifth+Primary, four-clones-no-Primary) and a reseed/repair entry | **Defer** — singles + Both + All cover the stated use cases; list as backlog. |

## 4. Workstreams

### W1 — `src/windows/reset_zcode.ps1`
1. **W1-1 (F-01)** New step after [26]: shared-CLI-db scrub for clone targets. Path: `%USERPROFILE%\.zcode\cli\db\db.sqlite`; use `ghost_cli.py clear-cli-telemetry`; WAL-aware backup first; 10 s busy timeout; on lock/error → WARN + FAILED entry (never silent); verify remaining=0. Acceptance: clone-only run shows the shared-db step OK on a closed-db box and an honest WARN when survivors hold it.
2. **W1-2 (F-02)** Gate Qoder steps on `$Target -eq 'Primary'` (or honor `-SkipQoder` for clone labels); fix comment L1547; keep Primary/All behavior unchanged (verified by audit-key diff before/after).
3. **W1-3 (F-04)** Strict backup: `$null` backup ⇒ FAILED, skip mutation; include `-wal`/`-shm` in sqlite backups (or `PRAGMA wal_checkpoint(TRUNCATE)` before copy).
4. **W1-4 (F-05)** Incremental audit/restore: append each step's restore action to the restore script and audit JSON as it happens; tail only finalizes header/summary.
5. **W1-5 (F-06)** Purge policy per D3: never delete `restore_*.ps1`/`audit_*.json` of older runs; state retention in the summary.
6. **W1-6 (F-07)** Empty-target WARN for clone labels (bare-launch hint); keep Primary's existing ambiguity abort.
7. **W1-7 (F-08)** Elevation: delete `%TEMP%\zcode_v1.3_done.txt` before relaunch; `-PassThru` + `.ExitCode` propagation; print marker only when fresh.
8. **W1-8 (F-10)** Python preflight per D4: functional probe before kill; fail fast with hint.
9. **W1-9 (F-11)** `-DryRun`: compute the full step plan + target roots, print would-do lines, take no locks, kill nothing, write nothing; exit 0 when the plan is complete.
10. **W1-10 (F-13/F-14)** Partial-profile WARN; header/usage include Fifth; remove dead helper or annotate; keep parse-check green.

### W2 — `GHOST.bat`
1. **W2-1 (F-09/D5)** Confirm prompt before [10] (and [7]); on cancel, redraw without dispatch. Respect the no-bare-parens rule (use `call :Confirm` helper, top-level echoes only).
2. **W2-2 (F-12)** Post-reset `:RunWith` note: relaunch via [1]/[3]/[4]/[18]/[22]/[41] or the clone shortcuts; bare `ZCode.exe` opens Primary.
3. **W2-3 (F-11)** Optional [D] "dry-run reset" entry (or a `-DryRun` prompt inside [6]/[8]/[9]/[19]).
4. **W2-4 (F-14)** Label consistency ([6] "survivor"); display block tidy (keep local ids stable — do not renumber).

### W3 — `tools/watch_zcode_captcha.ps1` (F-03)
1. Replace bare relaunch with the clone-aware launcher for the instance it killed (or at minimum Primary-only relaunch plus a loud log line listing killed instances).
2. Reset-side preflight: detect the watchdog (mutex/process) and WARN in the reset summary.

### W4 — Docs & tests
1. `AGENTS.md`: launch-gid list add 41; note clone-only shared-db scrub (after W1-1 lands) and the watchdog interplay; note retention policy.
2. `.bat-harness-test.ps1`: scenarios rendering [19]/[10], a two-token ZCode chain end-to-end, and unknown-token continuation.
3. `tests/python`: keep green; add a `clear-cli-telemetry` case for the shared-db invocation (empty + locked DB).

## 5. Target behavior matrix (after this plan)

| Scenario | Expected |
|---|---|
| [6]/[8]/[9]/[19], target running, others running | Target tree-kill only; survivors untouched and verified; shared CLI db scrub OK or honest WARN; Qoder untouched; per-target backups + restore; relaunch note shown. |
| [6]/[8]/[9]/[19], target closed | Clean "no target processes" INFO; stores reset; same backups/restore; empty-target WARN only if a bare clone is suspected (Primary-profile holder). |
| [6]/[8]/[9]/[19], bare-launched clone | WARN "no <Label> main found…"; on-disk reset proceeds; no Primary kill. |
| [7], [10] | Sequential children, independent IDs, Primary last, each child's kill = its own target; [10] confirmed before start; a failed child does not stop the rest; final exit 1 on any failure. |
| Chained "6 8 10", "10 6", "[7] then [10]" | Sequential with pauses; earlier restore sets survive the later run's purge (D3 policy); no errorlevel short-circuit (unchanged by design). |
| Never-launched clone / missing roaming | Up-front exit 1, no side effects, launch-once hint (unchanged). |
| Python 3 missing | Up-front abort before any kill/backup; hint; nothing rotated. |
| SQLite locked by a survivor (shared db / Qoder) | Honest FAILED entry, no corruption, rerun hint; backup strict-mode prevents unrestorable mutations. |
| Watchdog running during reset | Reset warns; watchdog killed instances are relaunched clone-aware (not bare). |
| Post-reset relaunch | Shortcut/launcher path; menu note shown; bare exe hazard called out. |
| App update reverted asar patch | Reset unaffected; clone loses color/title → ZCode [12] re-patch (documented, unchanged). |

## 6. Test & verification plan

1. `[System.Management.Automation.Language.Parser]::ParseFile` on every touched `.ps1` — zero errors.
2. `tests/python` unittest suite green (`python -m unittest discover -s tests/python`).
3. Batch harness: extend and run `.bat-harness-test.ps1` (new scenarios above); eyeball a real menu render.
4. Dry-run acceptance: `-DryRun` on each label — zero filesystem writes (snapshot `ID_Backups` mtimes before/after), zero kills.
5. Live destructive matrix (manual, one box, instances closed → open): [6] alone; [6] with Primary+Third running; [7]; [10]; [19]; a chained "6 8"; a second same-day run (retention check); Python-missing simulation (PATH without python) → abort with nothing touched.
6. Never-silent-success audit: every changed step keeps an audit key with before/after + verify-after; summaries show OK/FAILED/SKIP per step.

## 7. Implementation order

1. **Phase A (correctness, no UX change):** W1-2, W1-3, W1-1, W1-8, W1-6, W1-7 — each with parse-check + targeted live test.
2. **Phase B (recoverability):** W1-4, W1-5, W1-10.
3. **Phase C (menu):** W2-1, W2-2, W1-9/W2-3, W2-4.
4. **Phase D (watchdog + docs/tests):** W3-1/2, W4-1..3.

Every phase leaves the tree uncommitted for review (project rule: no auto-commit).

## 8. Out of scope

Linux `src/linux/*`, `archive/`, `identity_utils.ps1` internals, `change_device_id.ps1`,
`.context/`, `.git/`, app updates themselves (asar patch reverts are handled by ZCode [12]),
and the deferred optional features in D7.
