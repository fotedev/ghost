# AutoClaw2 MCP + chat sync — implementation plan

Status: **MCP-first milestone IMPLEMENTED (2026-11-04)** — Phases 1-5 code +
tests landed on `feat/autoclaw2-sync` (39 unittests + lean Pester suite + harness
scenario); Phase 0 spikes and the live acceptance runs stay supervised-pending
for the follow-up PR. Depends on
`docs/AUTOCLAW2_SYNC_SPEC.md` (decisions D1-D13, acceptance criteria A1-A7 /
C1-C7). Task-level breakdown: `docs/AUTOCLAW2_SYNC_TASKS.md`.

Ship order is deliberate: **MCP first** (deterministic, no immutability
constraints, no cloud interference), **chat inventory second** (read-only,
useful immediately), **chat copy last** (blast radius, needs the Phase 0
answers).

---

## 1. Strategy

| Principle | Consequence |
|---|---|
| Definitions only | MCP rows carry no credentials; chat copies carry no IM bindings, no `agents`, no `memory_assets` |
| Refuse over guess | A precondition miss returns exit 2 with a remedy, never a best-effort write |
| Converge, don't mirror | Merge invariant (D6) keeps clone-local decisions; absence in the manifest is not deletion |
| Closed profile only | Every write happens with the target's `lockfile` provably free |
| Python owns SQL | `src/python/ghost/autoclaw2.py` is the only place SQL exists |
| Verify-after everywhere | Re-read + deep compare + audit line before any exit code |

## 2. Phases

### Phase 0 — Spikes (read-only; ~0.5 day)

Answer E1-E5 from spec §9 on a **sacrificial copy** of `c1`'s profile
(`%TEMP%\ac2-spike\`), never on Primary and never on a signed-in profile in place.

| Spike | Method | Output |
|---|---|---|
| E1 | Copy `c1` profile tree → temp, write one throwaway session directly in its DB, launch `AutoClaw2.exe` with `ZWORK_USER_DATA` pointed at the copy, observe the sidebar | one-line verdict: visible / needs restart |
| E2 | Snapshot the copy's DB before/after that launch (`sqlite3 .dump` hash of the 6 chat tables) | rows rewritten? which columns |
| E3 | Copy one session containing `tool_artifact` entries with their artifact rows, open the chat | renders / errors / degraded |
| E4 | Import one session into `c3` (fresh account), observe after a sign-out/sign-in cycle | survives cloud / disappears |
| E5 | Write one `pending` http source row into the copy, open the sources UI | usable / inert / app-testable |

**Exit criteria:** all five verdicts appended to spec §9; if E1 or E4 is negative,
the chat track is re-scoped to inventory-only and the plan continues with Track M.

> Hard rule for Phase 0: copy the profile with the app closed; the copy's
> `lockfile` is deleted before launch; the real profiles are opened `mode=ro` only.

### Phase 1 — Python core: discovery + planning (1 day)

- `src/python/ghost/autoclaw2.py`
  - `resolve_profiles()` — Primary + `c1..c5` by `[Environment]` paths (G12), returns
    `{name, user_data, account_dir, db_path, lockfile, running}`.
  - `resolve_account(profile)` — exactly one child of `accounts\`; zero ⇒ SKIP reason
    `not-signed-in`, more than one ⇒ `ambiguous-account` (refuse).
  - `workspaces(conn)` / `default_workspace(conn)`.
  - `read_sources(conn)` → rows with decoded transport (`stdio+v1:` decode).
  - `encode_locator()` / `decode_locator()` — byte-exact per G4.
  - `check_schema(conn)` — `schema_migrations` name/order/sha256 + required
    columns present (F3).
- Subcommands in `ghost/__main__.py`: `ac2-inventory`, `ac2-mcp-plan`.
- Tests `tests/python/test_ghost_autoclaw2.py`: locator round-trip (incl. unicode
  args and spaces), account resolution (0/1/2 dirs), workspace mapping, schema
  gate, and "no write" assertions (open `mode=ro`, assert file mtime unchanged).

**Exit criteria:** `ghost_cli.py ac2-inventory --payload <b64>` returns JSON for
all six profiles in <1 s each; 20+ unit tests green; no file mtime changes.

### Phase 2 — Merge core + manifest (1 day)

- `tools/autoclaw2-mcp.master.json` (schema per spec §5.4, starts with 2 sample
  entries, commented as samples to be replaced by the developer).
- Merge function inside `autoclaw2.py` (`merge_sources(manifest, existing)`) —
  pure, no I/O, returns `{create, update, keepLocal, manifestAbsent}`.
- `tests/autoclaw2_mcp_merge.Tests.ps1` — Pester, porting the four ZCode cases
  plus three AutoClaw2-specific ones (workspace targeting, `pending` status
  preservation, `requiresCredential` never written).

**Exit criteria:** invariant table from spec D6 asserted case-by-case; merge is
idempotent (merge(merge(x)) == merge(x)); manifest validation rejects bad slugs
before any DB access.

### Phase 3 — MCP apply + launcher hook + GHOST row (1 day)

- `ac2-mcp-apply` in the core: one transaction per profile, `INSERT … ON CONFLICT
  (owner_id, workspace_id, slug) DO UPDATE` limited to the D5 columns, then
  re-read + compare, then return a per-profile verdict.
- `tools/sync_autoclaw2_mcp.ps1` — `-Target c1..c5|All`, `-From Master|Primary`,
  `-IncludePrimary`, `-AllWorkspaces`, `-DryRun`, `-Quiet`, `-RestoreBackup`
  (LIVE is the default without -DryRun; D7 keeps every write on a closed
  profile); backup via the sqlite3 backup API; running
  probe (`lockfile` exclusive open); audit JSONL; exit 0/1/2.
- `src/windows/launch_autoclaw2_clone.ps1` — new pre-launch step `[2b]` calling
  the sync with `-Target <instance> -Quiet`; never blocks the launch, warns on
  failure (mirrors the ZCode launcher step 2d contract).
- GHOST.bat row `[8]` → gid 73.

**Exit criteria:** A1-A7 pass on `c1`; launcher run on a fresh clone converges
before the window appears; a failed sync prints a warning and still launches.

### Phase 4 — Chat inventory (0.5 day)

- `ac2-chat-inventory`: per profile → per session
  `{session_id, title, workspace_root, counts:{entries,events,runs,artifacts},
  external_provider, imported_already}`; plus a cross-profile diff
  (`missing-in-target`, `already-imported`, `refused-im`).
- `tools/sync_autoclaw2_chats.ps1 -Mode Inventory` — human table + `report.json`
  under `<ProfileDir>\.autoclaw2-chat-reports\<ts>\`; writes nothing else.
- GHOST.bat row `[9]` → gid 75 (the watcher's reserved gid 74 ships with Phase 6).

**Exit criteria:** C1 passes; diff for Primary→`c1` lists exactly the sessions
absent from `c1`; report contains no message bodies (titles only, redacted).

### Phase 5 — Chat import (1.5 days, gated on Phase 0)

- `ac2-chat-import` implementing spec §5.5 exactly: fixed FK order, id rewriting,
  `[import]` prefix, FTS rows, artifact subset, IM refusal, idempotency key.
- `-Apply` required; `-SessionId`/`-Since`/`-Limit` selectors; `-TitleTag`;
  `-MaxUnresolvedPct` (default 5).
- Sidecar `<ProfileDir>\.autoclaw2-chat-imports.json` + `-Revert -ImportId <id>`
  (deletes only sessions this tool created, tombstones first per G6).
- `tools/sync_autoclaw2_chats.ps1 -Mode Import -Apply` + GHOST row `[10]` → gid 76
  (plain `:Run` — the gates live in the script: closed profile, clean backup,
  dry-run planning, sidecar revert).

**Exit criteria:** C2-C7 pass; a deliberately interrupted run leaves zero partial
rows; `-Revert` restores the pre-import session count exactly.

### Phase 6 — Watcher, wiring, docs (1 day)

- `tools/watch_autoclaw2_mcp_sync.ps1` — stat-guard on the manifest (mtime+size+
  parse), ~1 s debounce, applies to closed profiles only, `-RunOnce`, `-DryRun`,
  `-IntervalSeconds`, `-InstallAutostart`/`-RemoveAutostart`, mutex
  `Autoclaw2McpSyncWatcher` + startup process scan, log at
  `%LOCALAPPDATA%\watch-autoclaw2-mcp-sync\mcp-sync.log`. Writes nothing itself —
  it shells out to `sync_autoclaw2_mcp.ps1`.
- GHOST.bat watcher row → gid 74 (detached), inserted in display order when the
  watcher ships (locals renumber then; gids never); header range already
  widened to `1-76` (63 stays unused); the `:Div "Sync + Chat Import"` section
  and the Maintenance move to `[11]`/`[12]` (gids 35/36 unchanged) shipped with
  the milestone.
- Docs: `README.md` row, `docs/cli.md` section, `docs/architecture.md` tool list,
  `CHANGELOG.md` under `[Unreleased]`, and a §7 follow-up note in
  `docs/AUTOCLAW2_CLONES_SPEC.md` pointing at this suite.
- Harness: new `.bat-harness-test.ps1` scenario asserting the four rows render,
  locals ascend 1..13, and no bare `&`/parens regressions.

**Exit criteria:** watcher converges a manifest edit into two closed clones within
one pass; second watcher instance exits cleanly; harness scenario green.

## 3. File-by-file change list

| File | Change |
|---|---|
| `src/python/ghost/autoclaw2.py` | **new** — discovery, locator codec, merge, plan, apply, verify, inventory, import, revert |
| `src/python/ghost/__main__.py` | + 6 subcommand registrations (ac2-inventory, ac2-mcp-plan/apply, ac2-chat-inventory/import/revert) |
| `tests/python/test_ghost_autoclaw2.py` | **new** — 39 unittest cases |
| `tools/autoclaw2-mcp.master.json` | **new** — device manifest (seeded from the ZCode Primary working set 2026-11-04) |
| `tools/sync_autoclaw2_mcp.ps1` | **new** — MCP orchestrator |
| `tools/watch_autoclaw2_mcp_sync.ps1` | **new** — resident watcher (deferred: follow-up PR) |
| `tools/sync_autoclaw2_chats.ps1` | **new** — chat inventory / guarded import / revert |
| `tests/autoclaw2_sync.Tests.ps1` | **new** — lean Pester orchestrator suite |
| `src/windows/launch_autoclaw2_clone.ps1` | + pre-launch sync step `[2b]` |
| `GHOST.bat` | + rows `[8]-[10]` (gids 73/75/76; 74 reserved for the watcher), locals renumber, header range 1-76 |
| `.bat-harness-test.ps1` | + scenario U for the three new rows |
| `docs/{README,cli,architecture,CHANGELOG,AUTOCLAW2_CLONES_SPEC}` | doc updates |
| `AGENTS.md` | one bullet in the AutoClaw2 area describing the new tools + gids |

## 4. Test matrix

| Layer | What | Where |
|---|---|---|
| Unit (Python) | locator codec, merge, id rewriting, idempotency, refusals, no-secret assertions | `tests/python/test_ghost_autoclaw2.py` |
| Unit (Pester) | merge invariant vs clone-local toggles | `tests/autoclaw2_mcp_merge.Tests.ps1` |
| Contract | exit codes 0/1/2, `-DryRun` byte-identical DB hash, SKIP on held lock | Pester + a temp profile fixture |
| Integration | real `c1` apply / re-apply / revert; chat import into a copied profile | manual, scripted in `_analysis` scratch only |
| Harness | menu rows, ascending locals, no CMD error, header range | `.bat-harness-test.ps1` |
| Live acceptance | A1-A7, C1-C7 (spec §8) executed once on the dev host | runbook in the task doc |

Every test must fail loudly: no `Write-Warning` where a verdict is expected.

## 5. GHOST.bat wiring (exact)

```
:AUTOCLAW
  :Div "Launch Clones"      [1]-[7]   -> gids 28,29,30,31,32,33,34
  :Div "Sync + Chat Import" [8]-[10]  -> gids 73,75,76               <- NEW SECTION
  :Div "Maintenance"        [11]-[12] -> gids 35,36 (unchanged gids)
```

| Local | Row label | Tail | gid | Command |
|---|---|---|---|---|
| 8 | `Import MCPs to clones` | `- from the central master manifest` | 73 | `:Run "tools\sync_autoclaw2_mcp.ps1" -Target All` |
| 9 | `Chat inventory` | `- read-only cross-profile report` | 75 | `:Run "tools\sync_autoclaw2_chats.ps1" -Mode Inventory -Target All` |
| 10 | `Import chats to clones` | `- one-way Primary to clones - DB backed up first` | 76 | `:Run "tools\sync_autoclaw2_chats.ps1" -Mode Import -Apply -Target All` |
| (later) | `MCP sync watcher` | `- auto-sync on manifest change` | **74 (reserved)** | `:Detached "AutoClaw2 MCP Sync Watcher" …` — ships with the follow-up PR |

Rules honored: gids never renumber (74 stays the watcher's slot even while the
row is absent); new rows sit in display order inside their
section; labels carry action + name only, qualifiers in the tail; no bare `&` in
label args; no parentheses inside parenthesized blocks; dispatch header widened
to `1-76` (63 stays unused).

## 6. Risk register

| ID | Risk | L | I | Mitigation | Trigger to stop |
|---|---|---|---|---|---|
| R1 | Cloud re-lists/overwrites imported chats | H | H | Spike E4 before Phase 5; state "local copy" in report | E4 shows deletion ⇒ chat copy stays out of scope |
| R2 | Artifact refs break chat open | M | H | Spike E3; drop-and-count with threshold; `-MaxUnresolvedPct` | E3 errors on >5% of entries |
| R3 | App normalizes imported rows at startup | M | M | Spike E2; verify-after on a second launch | E2 rewrites ids ⇒ revert design |
| R4 | Schema drift after an app update | M | H | `check_schema` gate (name+order+sha256+columns), refuse exit 2 | New migration appears ⇒ re-derive before shipping |
| R5 | WAL/lock damage from writing a running profile | L | H | Closed-profile-only rule; sqlite3 backup API backups; exclusive-open probe | Any `database is locked` ⇒ abort, never retry blindly |
| R6 | Developer expects live sharing, gets a copy | M | M | Docs + report wording; `[import]` prefix; inventory diff shows it | — |
| R7 | Secret leakage into logs/audit | L | H | Core never selects credential columns into payloads; test asserts it | Any credential value in a log ⇒ release blocker |
| R8 | Menu regression (`)` in a block, bare `&`) | L | M | Harness scenario S0b + new scenario | Harness red |

## 7. Rollback

| Scope | Mechanism |
|---|---|
| One MCP run | the run backs up `runtime.sqlite` via the sqlite3 backup API before its first write ⇒ `sync_autoclaw2_mcp.ps1 -RestoreBackup -Target <profile>` restores that exact pre-run copy (hash-verified; the merge never deletes, so restore is the whole undo story) |
| One chat import | `sync_autoclaw2_chats.ps1 -Revert -ImportId <id> -Target <profile>` — tombstones then deletes only rows created by that import (sidecar is the source of truth) |
| Catastrophic | restore `<ProfileDir>\.autoclaw2-sync-backups\<ts>\runtime.sqlite` with the app closed, then `PRAGMA quick_check` |
| Menu | revert `GHOST.bat` + launcher step in one commit (docs-only change otherwise) |

## 8. Effort and sequencing

| Phase | Effort | Depends on | Ships alone? |
|---|---|---|---|
| 0 Spikes | 0.5 d | — | no (decision input) |
| 1 Core inventory/plan | 1 d | 0 | yes (`ac2-inventory`) |
| 2 Merge + manifest | 1 d | 1 | yes (tests) |
| 3 MCP apply | 1 d | 2 | **yes — first usable feature** |
| 4 Chat inventory | 0.5 d | 1 | **yes — zero-risk value** |
| 5 Chat import | 1.5 d | 4 + E1/E2/E3 | yes |
| 6 Watcher + wiring + docs | 1 d | 3, 5 | yes |

Total ≈ 6.5 focused days. Phases 3 and 4 are independent and can land in either
order; Phase 5 must not start before the Phase 0 verdicts exist.

## 9. Definition of done

1. `python -m unittest tests.python.test_ghost_autoclaw2` green; Pester merge
   suite green; `.bat-harness-test.ps1` green.
2. `[System.Management.Automation.Language.Parser]::ParseFile` clean on every new
   or edited `.ps1`.
3. Acceptance criteria A1-A7 and C1-C7 executed on the dev host with printed
   evidence (audit lines + counts), pasted into the PR description.
4. Spec §9 verdicts filled in (no `TBD` left).
5. `AGENTS.md`, `README.md`, `docs/cli.md`, `docs/architecture.md`, `CHANGELOG.md`
   updated in the same change.
6. Ships as the `feat/autoclaw2-sync` worktree branch — commit + PR + squash
   merge (main-branch protection requires PRs). The dead session's original
   untracked copies stay in the main tree untouched until the merge lands;
   cleaning them up afterwards is the developer's call.
