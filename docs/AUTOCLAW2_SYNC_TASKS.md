# AutoClaw2 MCP + chat sync — task breakdown

Status: **MCP-first milestone DONE (2026-11-04)** — see the status table below.
Executable list for
`docs/AUTOCLAW2_SYNC_PLAN.md`; every task cites the spec decision or acceptance
criterion it satisfies (`docs/AUTOCLAW2_SYNC_SPEC.md`).

## Status (2026-11-04 — milestone shipped on `feat/autoclaw2-sync`)

| Tasks | Status |
|---|---|
| AC2S-010…015, 020, 021, 030, 031 | **DONE** — Python core + manifest + merge + orchestrator; 39 unittests green (work_events copy + D3 SKIP+WARN alignment included) |
| AC2S-022 | **DONE** — `tests/autoclaw2_sync.Tests.ps1` (lean Pester: orchestrator exit codes + verdict rendering; the merge invariant itself stays pinned by the unittests) |
| AC2S-032, 033 | **DONE** — launcher step `[2b]` + GHOST.bat row `[8]` (gid 73) |
| AC2S-040…043, 050…055 | **DONE** — chat inventory + cross-profile diff (missing / already-imported / refused-im), guarded import with work_events, sidecar revert; rows `[9]`/`[10]` = gids 75/76 |
| AC2S-063, 064 | **DONE** — harness scenario U + docs sweep |
| AC2S-001…005 (spikes E1-E5), 034, 056 (live acceptance A1-A7 / C2-C7), 060…062 (watcher, gid 74 reserved), 065 (final gate) | **PENDING** — the supervised follow-up PR runs the Phase 0 runbook first |

Conventions used below: **D** = spec decision, **A/C** = acceptance criterion,
**F** = failure mode. A task is done only when its *Verify* column produces the
stated evidence — "code written" is not done.

Two standing rules for every task: all SQL lives in `src/python/ghost/autoclaw2.py`
(D13), and every `.ps1` edit ends with a `Parser::ParseFile` check.

---

## Wave map

| Wave | Tasks | Why this order |
|---|---|---|
| W0 | AC2S-001 … AC2S-005 | Answers decide the chat scope (E1/E4 gate Phase 5) |
| W1 | AC2S-010 … AC2S-015 | Read-only core: nothing can be written yet |
| W2 | AC2S-020 … AC2S-022 | Pure merge + manifest, unit-tested with no DB |
| W3 | AC2S-030 … AC2S-034 | **First usable feature: MCP apply** |
| W4 | AC2S-040 … AC2S-043 | Zero-risk chat value (report only) |
| W5 | AC2S-050 … AC2S-056 | Chat copy, gated on W0 verdicts |
| W6 | AC2S-060 … AC2S-065 | Watcher, menu, docs, final verification |

W3 and W4 are independent — either can ship first. W5 must not start until
AC2S-005 is complete.

---

## W0 — Spikes (read-only, sacrificial profile only)

### AC2S-001 — Spike E1/E2: does a written session appear, and does startup normalize it?
**Depends:** — **Satisfies:** spec §9 E1/E2
**Do:** copy `%USERPROFILE%\AutoClaw2ClonesHome\c1` to `%TEMP%\ac2-spike\c1`, delete
the copy's `lockfile`, insert one throwaway session (1 request entry + 1 assistant
entry + head) with fresh ids, launch `AutoClaw2.exe` with `ZWORK_USER_DATA` set to
the copy, then diff the six chat tables before/after.
**Accept:** verdict line `E1: visible|needs-restart` and `E2: rows-rewritten:<cols>|untouched`.
**Verify:** both verdicts pasted into spec §9; the real `c1` DB hash is unchanged.

### AC2S-002 — Spike E3: do copied `tool_artifact` entries render?
**Depends:** 001 **Satisfies:** E3, F5
**Do:** pick the smallest `c1` session containing `tool_artifact` entries, copy it
plus its `governed_tool_artifacts`/`_custody` rows into the spike copy, open it.
**Accept:** `E3: renders|degrades|errors` + which entry types survive.
**Verify:** verdict in spec §9; if `errors`, the drop-and-count rule (F5) is
confirmed as mandatory.

### AC2S-003 — Spike E4: does the cloud re-list or overwrite a local-only session?
**Depends:** — **Satisfies:** E4, D8, R1
**Do:** (developer-assisted) import one throwaway session into `c3` (fresh account),
then sign out and back in; observe whether it survives.
**Accept:** `E4: survives|disappears|duplicates`.
**Verify:** verdict in spec §9; `disappears` ⇒ chat copy is descoped to inventory.

### AC2S-004 — Spike E5: is a directly written `pending` source usable?
**Depends:** — **Satisfies:** E5, D5
**Do:** write one http source row (`status='pending'`, `tools_json='[]'`) into the
spike copy's DB, open the sources UI, attempt a tool call.
**Accept:** `E5: usable|app-tests-on-open|inert`.
**Verify:** verdict in spec §9; `inert` ⇒ Track M writes must be accompanied by
`-From Primary` guidance or a documented one-click GUI test step.

### AC2S-005 — Record verdicts and lock the scope
**Depends:** 001-004 **Satisfies:** plan §2 Phase 0 exit
**Do:** append the five verdicts to spec §9, adjust §2 scope if needed, and note
any decision that changed (D8/D11 are the likely ones).
**Accept:** no `TBD` remains in spec §9; scope changes are explicit lines, not silent edits.
**Verify:** `rg "TBD|TODO" docs/AUTOCLAW2_SYNC_SPEC.md` returns nothing.

---

## W1 — Python core, read-only

### AC2S-010 — Module skeleton + profile/account resolution
**Depends:** — **Satisfies:** G1/G2/G11/G12, F1/F2
**Files:** `src/python/ghost/autoclaw2.py`
**Do:** `resolve_profiles()` (Primary + `c1..c5` via `[Environment]::GetFolderPath`
equivalents, never `%APPDATA%`), `resolve_account()` (0 ⇒ `not-signed-in`,
1 ⇒ path, >1 ⇒ `ambiguous-account`), `probe_running()` (`lockfile` exclusive-open,
open/close only, never truncate).
**Accept:** resolution works for all six profiles; `c2/c4/c5` report
`not-signed-in`; a held lockfile reports `running`.
**Verify:** `python -m unittest tests.python.test_ghost_autoclaw2 -k resolve` green.

### AC2S-011 — Locator codec
**Depends:** 010 **Satisfies:** G4, D5
**Files:** `autoclaw2.py`
**Do:** `encode_locator({transport:stdio, command, args, cwd})` →
`stdlib`-free-of-whitespace `stdio+v1:` + JSON with key order `command, args, cwd`
and `cwd` omitted when empty; `decode_locator(str)` → transport dict; http stays a
raw URL. Reject non-`http(s)` URLs and empty commands.
**Accept:** round-trip byte-identical for paths with spaces, unicode args, and
empty `args`; decoding a legacy raw URL yields `{transport: http}`.
**Verify:** `-k locator` tests green, including an equality test against a literal
string copied from the app's own encoding shape.

### AC2S-012 — Schema gate
**Depends:** 010 **Satisfies:** G8, F3, R4
**Files:** `autoclaw2.py`
**Do:** compare `schema_migrations` `(name, order, sha256)` and assert the required
columns exist on the six target tables; return a structured refusal with both
sides printed.
**Accept:** matching profiles pass; a copy with a bumped `order` returns
`refused:schema-mismatch` and writes nothing.
**Verify:** `-k schema` green, including the negative fixture.

### AC2S-013 — Workspace mapping
**Depends:** 010 **Satisfies:** G10, D3, F4
**Files:** `autoclaw2.py`
**Do:** `map_workspaces(source_workspaces, target_workspaces, policy)` with policy
`default` (default workspace + `root_path` matches) or `all`; `root_path`
comparison case-insensitive on Windows, trailing-separator insensitive.
**Accept:** `unban-machine-id` maps across Primary/`c1`; `c3` (default only) still
receives the default-workspace write; unmatched source workspace is reported, not
silently dropped.
**Verify:** `-k workspace` green.

### AC2S-014 — `ac2-inventory` subcommand
**Depends:** 010-013 **Satisfies:** G1-G9
**Files:** `autoclaw2.py`, `src/python/ghost/__main__.py`
**Do:** base64 JSON payload in, JSON out: per profile `{account, running, schema,
workspaces, sessions, sources, migrations}` — counts only, no bodies, no
credential columns.
**Accept:** one call covers all six profiles in <6 s; payload never contains a
message body or a credential value.
**Verify:** `ghost_cli.py ac2-inventory --payload <b64>` output reviewed; DB mtimes
unchanged before/after.

### AC2S-015 — Unit test batch 1
**Depends:** 010-014 **Satisfies:** plan §4 unit layer
**Files:** `tests/python/test_ghost_autoclaw2.py`
**Do:** ≥20 cases: resolution matrix, locator codec, schema gate, workspace
mapping, redaction, and a "read-only" assertion helper.
**Accept:** green in CI-less local run; no test touches a real profile read-write.
**Verify:** `python -m unittest tests.python.test_ghost_autoclaw2` → `OK (n tests)`.

---

## W2 — Manifest and merge

### AC2S-020 — Master manifest + loader/validator
**Depends:** 011 **Satisfies:** D1, spec §5.4
**Files:** `tools/autoclaw2-mcp.master.json`, `autoclaw2.py`
**Do:** ship a 2-server sample manifest (one stdio, one http with
`requiresCredential: true`); validate `schemaVersion`, slug regex, transport enum,
absolute command/URL, duplicate slugs — all **before** opening any DB.
**Accept:** invalid slug / relative command / duplicate slug each produce a
specific error and exit 2; a valid manifest loads.
**Verify:** `-k manifest` green.

### AC2S-021 — Merge core
**Depends:** 020 **Satisfies:** D6, A3, A7
**Files:** `autoclaw2.py`
**Do:** pure `merge_sources(manifest_entries, existing_rows)` → `{create, update,
keep_local, manifest_absent}`; clone-local `enabled` and
`tool_permissions_json` win; manifest wins on name/locator/`source_permission`;
absence never deletes.
**Accept:** idempotence (`merge(merge(x)) == merge(x)`), and the same four
invariants the ZCode suite already pins.
**Verify:** `-k merge` green.

### AC2S-022 — Pester merge suite
**Depends:** 021 **Satisfies:** plan §4 unit layer
**Files:** `tests/autoclaw2_mcp_merge.Tests.ps1`
**Do:** port `tests/zcode_mcp_merge.Tests.ps1` cases + three AutoClaw2 ones
(workspace targeting, `pending` preserved on update, `requiresCredential` never
written to a column).
**Accept:** all cases pass; no shared helper refactor of the ZCode script.
**Verify:** `Invoke-Pester tests\autoclaw2_mcp_merge.Tests.ps1` → 0 failed.

---

## W3 — MCP apply (first shippable feature)

### AC2S-030 — `ac2-mcp-apply`
**Depends:** 012, 013, 021 **Satisfies:** D5, D6, A1, A2, A3
**Files:** `autoclaw2.py`, `__main__.py`
**Do:** one transaction per profile; `INSERT … ON CONFLICT(owner_id,
workspace_id, slug) DO UPDATE` limited to `name, endpoint, enabled,
source_permission, revision, updated_at`; insert-only sets `kind='mcp'`,
`status='pending'`, `tools_json='[]'`; re-read + deep compare; per-profile verdict
JSON.
**Accept:** A1/A2/A3 hold; a mismatch yields `FAILED` with the column diff, not a
warning.
**Verify:** run against a temp copy first (dry-run then apply), assert DB hash
changes only in `governed_connected_sources`.

### AC2S-031 — `tools/sync_autoclaw2_mcp.ps1` orchestrator
**Depends:** 030 **Satisfies:** D7, D10, F1, A4, A5, A6
**Files:** `tools/sync_autoclaw2_mcp.ps1`
**Do:** params `-Target c1..c5|All`, `-From Master|Primary`, `-IncludePrimary`,
`-AllWorkspaces`, `-DryRun`, `-Quiet`, `-RestoreBackup` (LIVE is the default
without -DryRun); per-profile sqlite3 backup API
backup; running probe; base64 payload → `ghost_cli.py ac2-mcp-apply` by absolute
path; verify-after; JSONL audit `<ProfileDir>\.autoclaw2-sync-audit.jsonl`;
exit 0/1/2.
**Accept:** `-DryRun` byte-identical DB hash; running clone ⇒ SKIP + WARN exit 0;
no credential value in the audit line.
**Verify:** `-DryRun` on `c1`, then real apply, then re-run (audit says
`unchanged`); ParseFile clean.

### AC2S-032 — Launcher pre-launch step `[2b]`
**Depends:** 031 **Satisfies:** D7, plan §2 Phase 3
**Files:** `src/windows/launch_autoclaw2_clone.ps1`
**Do:** call `sync_autoclaw2_mcp.ps1 -Target <instance> -Quiet` before
`Start-Process`; failure is a warning only (never blocks a launch); skip silently
when the manifest is absent.
**Accept:** fresh clone launches with sources already present; a broken manifest
prints one WARN and still launches.
**Verify:** launch `c4` (no account yet) ⇒ `not-signed-in` note, launch proceeds.

### AC2S-033 — GHOST.bat row `[8]`
**Depends:** 031 **Satisfies:** plan §5
**Files:** `GHOST.bat`
**Do:** add the `:Div "Sync + Chat Import"` section, row `[8] "Import MCPs to
clones" "- from the master manifest; all c1..c5"`, resolver `8 → 73`, dispatch
case 73, header range `1-72` → `1-76`.
**Accept:** menu renders, `4 8` chain runs, no CMD error.
**Verify:** `.bat-harness-test.ps1` scenario (added in AC2S-063) green; manual `4` → `8`.

### AC2S-034 — Acceptance run A1-A7
**Depends:** 030-033 **Satisfies:** A1-A7
**Do:** execute the seven criteria on `c1` (and `c4` for the not-signed-in path),
capture audit lines and counts.
**Accept:** all seven pass with printed evidence.
**Verify:** evidence block pasted into the PR description.

---

## W4 — Chat inventory (zero-risk value)

### AC2S-040 — `ac2-chat-inventory` + cross-profile diff
**Depends:** 014 **Satisfies:** C1, D9, D12
**Files:** `autoclaw2.py`, `__main__.py`
**Do:** per session `{session_id, title, workspace_root, entries, events, runs,
artifacts, external_provider, imported_already}`; diff source→target as
`present | missing | already-imported | refused-im`.
**Accept:** counts match the live DBs (Primary 9 / `c1` 4 / `c3` 0 at draft time);
no message bodies in output.
**Verify:** `-k inventory` green + one live run reviewed.

### AC2S-041 — `tools/sync_autoclaw2_chats.ps1 -Mode Inventory`
**Depends:** 040 **Satisfies:** C1
**Files:** `tools/sync_autoclaw2_chats.ps1`
**Do:** human table + `report.json` under
`<ProfileDir>\.autoclaw2-chat-reports\<ts>\`; writes nothing else; `-Target All`
default, `-Source Primary|cN`.
**Accept:** report exists, DB hashes unchanged.
**Verify:** run twice; second run hashes identical.

### AC2S-042 — GHOST.bat row `[10]`
**Depends:** 041 **Satisfies:** plan §5
**Files:** `GHOST.bat`
**Do:** row `[10] "Chat inventory" "- read-only report; writes nothing"`,
resolver `10 → 75`, case 75.
**Accept:** renders and runs.
**Verify:** `4` → `10` shows counts; no writes.

### AC2S-043 — Redaction test
**Depends:** 040 **Satisfies:** plan §4, R7
**Files:** `tests/python/test_ghost_autoclaw2.py`
**Do:** assert the inventory payload and report never contain message bodies,
`credential_version` values, `.enc` contents, or IM tokens.
**Accept:** test fails if any body text is added to the payload.
**Verify:** `-k redaction` green.

---

## W5 — Chat import (gated on AC2S-005)

### AC2S-050 — Id mapping + writer
**Depends:** 003, 005, 040 **Satisfies:** D8, C2, C3
**Files:** `autoclaw2.py`
**Do:** plan a session tree, then write in the spec §5.5 order (`work_sessions` →
`work_runs` → `work_events` → `neutral_session_entries` → `neutral_session_heads`
→ FTS → artifacts); generate ids with `uuid4()` only (the `CHECK`s assert UUID v4
shape); rewrite entry ids as `<new_run_id>:<suffix>`; remap all four head id
columns and recompute `next_session_seq`/`entry_count`; set
`work_runs.credential_version` to NULL; copy `payload` verbatim; never
`UPDATE`/`DELETE`.
**Accept:** C2 and C3 on the spike copy; triggers remain enabled.
**Verify:** import one session into the copy, launch, open the chat.

### AC2S-051 — FTS + artifact subset
**Depends:** 050 **Satisfies:** C7, F5
**Files:** `autoclaw2.py`
**Do:** insert FTS rows with `body` recomputed from copied payloads; copy only
referenced artifacts + custody **and the referenced `desktop-attachments` blobs**;
drop referencing entries when the source blob is missing and count them.
**Accept:** C7 passes; unresolved ratio is reported and aborts above
`-MaxUnresolvedPct`.
**Verify:** `-k fts|artifact` green + a live FTS search for a distinctive phrase.

### AC2S-052 — Sidecar provenance + idempotency
**Depends:** 050 **Satisfies:** C4, D10, D11
**Files:** `autoclaw2.py`
**Do:** record `{import_id, source_profile, source_session_id, content_hash,
created_at, new_session_id}` in `<ProfileDir>\.autoclaw2-chat-imports.json`;
skip on matching content hash; `[import]` title prefix via `-TitleTag`.
**Accept:** re-import of the same session writes zero rows and reports `skipped`.
**Verify:** `-k idempotent` green + live double run.

### AC2S-053 — `-Revert -ImportId`
**Depends:** 052 **Satisfies:** plan §7
**Files:** `autoclaw2.py`
**Do:** tombstone (`deleted_at`) then delete only rows created by that import id;
update the sidecar; never touch anything else.
**Accept:** session count returns to the pre-import value; other sessions intact.
**Verify:** import → revert → count comparison.

### AC2S-054 — PS wrapper `-Mode Import -Apply`
**Depends:** 050-053 **Satisfies:** D10, C5, C6
**Files:** `tools/sync_autoclaw2_chats.ps1`
**Do:** gates (lockfile free, schema match, backup), `-Apply` required, selectors
`-SessionId`/`-Since`/`-Limit`, `-MaxUnresolvedPct`, `-Revert`; audit + verdict;
exit 0/1/2.
**Accept:** C5 refuses IM sessions; C6 simulated failure leaves zero partial rows.
**Verify:** kill the run mid-way in the spike copy → count unchanged.

### AC2S-055 — GHOST.bat row `[11]`
**Depends:** 054 **Satisfies:** plan §5
**Files:** `GHOST.bat`
**Do:** row `[11] "Import chats" "- one-way Primary to clones; backs the DB up
first"`, resolver `11 → 76`, `:ConfirmRun` gate.
**Accept:** confirmation gate shown; cancel runs nothing.
**Verify:** `4` → `11` → `N` prints "Cancelled".

### AC2S-056 — Acceptance run C2-C7
**Depends:** 054-055 **Satisfies:** C2-C7
**Do:** run the six criteria (spike copy for destructive steps, `c3` for the
cloud-observable one), capture evidence.
**Accept:** all pass, or the failing one is reported as a scope reduction with the
spike verdict that caused it.
**Verify:** evidence block in the PR description.

---

## W6 — Watcher, menu order, docs

### AC2S-060 — `tools/watch_autoclaw2_mcp_sync.ps1`
**Depends:** 031 **Satisfies:** D7, F10
**Files:** `tools/watch_autoclaw2_mcp_sync.ps1`
**Do:** stat-guard manifest (mtime+size+parse), ~1 s debounce, invoke the sync as a
child for **closed** profiles only, `-RunOnce`, `-DryRun`, `-IntervalSeconds`,
`-InstallAutostart`/`-RemoveAutostart`, mutex `Autoclaw2McpSyncWatcher` + startup
process scan, self-titling console, log
`%LOCALAPPDATA%\watch-autoclaw2-mcp-sync\mcp-sync.log`.
**Accept:** one edit converges two closed clones in one pass; a second instance
exits 0 with a note; the watcher itself writes no DB row.
**Verify:** `-RunOnce` after a manifest edit; process-scan test with two copies.

### AC2S-061 — Autostart
**Depends:** 060 **Satisfies:** D7
**Files:** `tools/watch_autoclaw2_mcp_sync.ps1`
**Do:** install a Startup `.lnk` once (hidden), idempotent, `-RemoveAutostart` cleans it.
**Accept:** reinstall is a no-op; removal leaves no orphan `.lnk`.
**Verify:** inspect `Startup` folder before/after.

### AC2S-062 — Menu completion + renumber
**Depends:** 033, 042, 055, 060 **Satisfies:** plan §5, AGENTS menu rules
**Files:** `GHOST.bat`
**Do:** row `[9] "MCP sync watcher" "- auto-sync on manifest change (separate
window)"` → `:Detached`, resolver `9 → 74`, case 74; move Maintenance to
`[12]`/`[13]` (gids 35/36 unchanged); confirm locals ascend 1..13.
**Accept:** every row renders; chains `4 9`, `4 12`, `4 13` work.
**Verify:** harness scenario + manual pass over the submenu.

### AC2S-063 — Harness scenario
**Depends:** 062 **Satisfies:** plan §4 harness layer
**Files:** `.bat-harness-test.ps1`
**Do:** assert the four new rows render, locals ascend, gids 73-76 are in the
dispatch table, header range is `1-76`, and the submenu produces no CMD error.
**Accept:** scenario green; a deliberate `)` in a row makes it red.
**Verify:** run the harness twice (must be idempotent).

### AC2S-064 — Docs sweep
**Depends:** 062 **Satisfies:** plan §9
**Files:** `README.md`, `docs/cli.md`, `docs/architecture.md`,
`docs/AUTOCLAW2_CLONES_SPEC.md` §7, `CHANGELOG.md`, `AGENTS.md`
**Do:** document the three tools, the four menu rows, exit codes, audit/backup
paths, and the chat-import semantics ("copy, not share"); add the AGENTS bullet
with gids 73-76 next to the existing AutoClaw2 notes.
**Accept:** no stale "AutoClaw2 has no reset/sync tooling" claim remains; every
gid mentioned matches `GHOST.bat`.
**Verify:** `rg "73|74|75|76" GHOST.bat docs/` cross-check by eye.

### AC2S-065 — Final verification gate
**Depends:** all **Satisfies:** plan §9
**Do:** run everything in one pass — unittest, Pester, harness, ParseFile on each
touched `.ps1`, `-DryRun` on `c1`, inventory on all profiles — and paste the
output.
**Accept:** all green; working tree clean of scratch files (no `_analysis` or
`%TEMP%` artifacts referenced by shipped docs).
**Verify:** the pasted transcript is reproducible on a second run.

---

## Explicitly deferred (do not do in this change)

| Item | Why |
|---|---|
| Bidirectional / live chat sync | No stable merge key; cloud ownership (D8, E4) |
| Cloud reconciliation or account migration | Server-owned, unauditable |
| Copying credentials / OAuth / IM bindings | Repo rule + G5 + G13 |
| Per-server tool-permission sync | Owned by the GUI; local by design (D6) |
| Syncing `agents`, `memory_assets`, model connections | Definitions belong to the app |
| A shared MCP store outside the profiles (junction/symlink) | App resolves per-account paths; would also break WAL |
| ZCode/OpenCode/Cline MCP centralization | Separate suites; the manifest format is intentionally reusable for them later (D1 note) |

## Suggested first commit boundary

`AC2S-001 … AC2S-034` (spikes + core + MCP apply + row `[8]`) is one reviewable
unit: it never touches chat data and leaves the suite strictly more capable.
Chat inventory (`W4`) can ride along or follow; chat import (`W5`) must be its own
change so a reviewer can reject it without rejecting MCP sync.
