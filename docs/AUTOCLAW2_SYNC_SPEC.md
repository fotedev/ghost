# AutoClaw2 (zwork) MCP + chat synchronization — design spec

Status: **IMPLEMENTED — Track M + Track C code complete (2026-11-04)**: Python core
(39 unittests green), MCP orchestrator + launcher step [2b] + GHOST.bat rows
[8]/[9]/[10] (gids 73/75/76), chat inventory with cross-profile diff, guarded
import (work_events included) and sidecar revert. Live acceptance stays gated on
the supervised Phase 0 spikes (E1-E5) — a follow-up PR runs that runbook.
Drafted 2026-11-02 on this host. Companion docs: `docs/AUTOCLAW2_SYNC_PLAN.md`
(phases), `docs/AUTOCLAW2_SYNC_TASKS.md` (task breakdown).

Target app: `%LOCALAPPDATA%\Programs\AutoClaw2\AutoClaw2.exe` (v2.1.1.262,
internal name `zwork`, Electron, asInvoker). Suite: `docs/AUTOCLAW2_CLONES_SPEC.md`.

Every structural claim below is tagged **VERIFIED** (observed on this host today
via read-only SQLite/JSON/file probes and `main.cjs` reads) or **INFERRED**
(bundle reading, not yet exercised live). Nothing here is copied from the
v1.20 AutoClaw spec: v2.1.1 shares no storage design with it.

---

## 1. Problem

Two requests, one suite:

1. **MCPs.** The developer uses the same MCP servers across most of his tools and
   wants them defined once, not per app and not per clone (original ask, verbatim
   intent: "make all the MCPs for the device, not per app … or make a shared
   central template and each app imports from it" — AutoClaw2 chat
   *"MCPs Centralization Best"*, clone `c1`, 2026-10-28). Inside the AutoClaw2
   suite this means: one definition set, applied to Primary and to clones
   `c1..c5` without hand-editing each profile.
2. **Chats.** Chats created in one AutoClaw2 instance are invisible in every
   other instance, because each clone is a separate profile *and a separate
   account*. The developer wants the history available across instances.

Both features must obey the suite's standing rules: never silent success,
definitions-only syncing (no credential copying), one manual sign-in per clone,
and Primary is read-only.

## 2. Scope

**In scope**

- Track **M**: a device-level MCP definition manifest + an importer that applies
  it to every AutoClaw2 profile (Primary by explicit opt-in, `c1..c5` by
  default), per workspace, with merge semantics that preserve clone-local state.
- Track **M2**: an optional second source — copy definitions *from* the Primary
  profile's own connected sources (for the day the developer configures MCPs in
  the GUI instead of the manifest).
- Track **C**: a read-only chat **inventory/diff report** (ships first, zero
  risk) and a guarded **history import** that copies a chat tree from a source
  profile into a target profile as a *new local session*.
- GHOST.bat wiring, Pester/unittest coverage, docs, audit + backup + verify-after.

**Out of scope (explicit)**

- Live, bidirectional chat sync and merging two divergent copies of the same
  session (no stable merge key exists; see §4 D8).
- Any reconciliation with the AutoClaw2 cloud account: sessions are owned
  server-side per account and may re-appear or be re-listed independently
  (spike E4).
- Copying credentials, OAuth tokens, IM (Telegram) bindings, `agents`,
  `memory_assets`, model connections, or any `*_credential_*` object.
- Replacing the GUI: the app remains the only way to *author* MCP sources and to
  authenticate them.
- Windows-side identity scrubbing (already covered by the reset/launch suites).

## 3. Verified ground truth (do not contradict)

| # | Fact | Evidence |
|---|---|---|
| G1 | **Every profile is its own account.** Clone account emails and `owner_id`s differ from Primary's. `c2/c4/c5` have no `accounts\` child at all (never signed in). | `account-profile.json` in each profile: Primary `simplelogin-newsletter.trapdoor057@…` owner `cc6238cc-…`; `c1` `…almighty039@…` owner `4c747a92-…`; `c3` `wanted_slider835@…` owner `b7743708-…`. `c2/c4/c5`: `accounts` empty. |
| G2 | **All state is per-account, inside the profile.** Chat DB path is `<userData>\accounts\<sha256>\runtime\runtime.sqlite`. | File probe; 29.5 MB Primary / 12.8 MB `c1` / 0 MB `c3`. |
| G3 | **MCP servers are "connected sources"**, `kind='mcp'`, table `governed_connected_sources`, primary key `(owner_id, workspace_id, slug)` — i.e. **per workspace**, not per profile and not per device. | Table DDL read from the live DBs; bundle `INSERT INTO governed_connected_sources (owner_id, workspace_id, kind, slug, name, endpoint, enabled, status, error_code, credential_version, source_permission, tool_permissions_json, revision, tools_json, updated_at)`. |
| G4 | **Locator encoding**: HTTP sources store the raw URL in `endpoint`; stdio sources store `stdio+v1:{json}` with `command`/`args`/`cwd` in the same column. | Bundle: `STDIO_LOCATOR_PREFIX = "stdio+v1:"`, `encodeConnectedSourceLocator`, `decodeConnectedSourceLocator`. |
| G5 | **Credentials are separate objects, never in the row.** `credential_version` is nullable; staged refs look like `desktop-credential-stage:v1:<uuid>`. Secrets sit encrypted in `<account>\account-credentials.enc` and `<account>\runtime\owner-secrets.enc`; MCP OAuth token files would live in `<userData>\mcp-oauth\` (dir absent — no OAuth source configured yet). | Bundle + file probe. |
| G6 | **Chat entries are append-only by construction.** Triggers abort `UPDATE` (`neutral_session_entry_immutable`) and abort `DELETE` unless the session is tombstoned first (`deleted_at` set). | Live `sqlite_master` trigger text. |
| G7 | **Chat surface = 5 tables + FTS + events.** Per profile today: Primary 9 sessions / 9 heads / 2003 entries / 84 FTS rows / 6088 events / 52 runs / 482 artifacts; `c1` 4 / 4 / 929 / 36 / 2698 / 22 / 194; `c3` all zeros. FTS is a **standalone** FTS5 table (`session_id`, `entry_id` UNINDEXED, `body`, `tokenize='trigram'`), not external-content. | Live counts + DDL. |
| G8 | **Schema version is uniform**: `schema_migrations` = `0001_clean_dogfood_baseline`, order 80, same sha256 on Primary, `c1`, `c3`. | Live query. |
| G9 | **Zero MCP sources exist on this host** — `governed_connected_sources` and `…_revisions` are empty in Primary, `c1`, `c3`. A Primary→clone copy would currently be a no-op. | Live counts. |
| G10 | **Cross-profile workspace identity is `root_path`, not id.** The same repo path is workspace `f00dd839-…` in Primary and `197b9021-…` in `c1`. `c3` has only the default workspace (1 row). | Live `work_workspaces` dump. |
| G11 | **The app is asInvoker and in-process**: no app-server child to recycle (unlike ZCode). A running instance holds `<ProfileDir>\lockfile` exclusively and keeps `runtime.sqlite` in WAL with live handles. | Launcher design + live `-wal`/`-shm` presence + open probe. |
| G12 | **Agent shells lack `%APPDATA%`/`%LOCALAPPDATA%`.** Resolve with `[Environment]::GetFolderPath('ApplicationData')` / `('LocalApplicationData')`. | Observed empty env vars in this shell. |
| G13 | **Telegram/IM is one-credential-one-instance**: Primary holds the only `work_im_bot_settings` row; clones hold none. Copying IM-bound sessions would break this. | Live rows. |

## 4. Design decisions

| ID | Decision | Why | Rejected alternative |
|---|---|---|---|
| **D1** | Track M's source of truth is a **repo-tracked manifest** `tools/autoclaw2-mcp.master.json`, definitions only. | G9: no profile has sources to copy from, so "sync from Primary" has nothing to sync on day one. A manifest is exactly the "central template" the developer asked for, is reviewable/diffable, and is the only form that works before the GUI is configured. | Primary-as-source only (vacuous today); per-clone manual GUI entry (no automation). |
| **D2** | Track M **also** supports `-From Primary`, reading the Primary's rows and mapping workspaces by `root_path`. | Once the developer configures sources in Primary's GUI, that becomes the natural authoring surface; both sources feed the same merge core. | Ignoring Primary forever (rewrites by hand). |
| **D3** | **Workspace targeting is explicit**: default target set = each profile's *default* workspace plus any workspace whose `root_path` matches a source workspace. `-AllWorkspaces` expands to every workspace; unmatched source workspaces are SKIP + WARN. | G3 + G10: sources are per workspace; ids never match across profiles, `root_path` does. Guessing would silently put a server in the wrong project. | Writing to every workspace (surprising), writing to none (feature looks broken). |
| **D4** | **Definitions only.** Never write `credential_version`, never touch `account-credentials.enc` / `owner-secrets.enc` / `mcp-oauth\`. A source that needs auth is imported *unauthenticated* with `requiresCredential: true` in the report and a one-time per-clone WARN. | Repo rule (one credential = one instance); G5. | Copying encrypted blobs (breaks per-account isolation, unverifiable). |
| **D5** | **Row contract for a written source**: `kind='mcp'`, `enabled` from merge, `status='pending'`, `error_code=NULL`, `credential_version=NULL`, `source_permission` from manifest (default `allowed`), `tool_permissions_json='{}'` (local value preserved on update), `revision = "sync-v1:" + sha256(canonical definition)`, `tools_json='[]'` on insert (left untouched on update), `updated_at` = now. `governed_connected_source_revisions` is **never** written. | The app owns the revision/tools history; we must not fake a tool catalog we have not fetched. `pending` lets the app test the source on first use. | Pretending `connected` + fabricated `tools_json` (silent lie; app may serve zero tools while claiming success). |
| **D6** | **Merge invariant** (ported from `zcode_mcp_merge.ps1`): clone-local `enabled` survives; clone-only sources are kept; a new source inherits the manifest's `enabled`; the manifest wins on `name`/locator/`source_permission`; `tool_permissions_json` stays clone-local. | Proven invariant, already unit-tested for ZCode; keeps per-clone toggles meaningful. | "Mirror the manifest" (destroys local decisions, deletes hand-made servers). |
| **D7** | **Write timing**: pre-launch hook (`launch_autoclaw2_clone.ps1`, clone provably closed) is the primary path; the watcher applies **only to closed profiles**; `-ApplyLive` is opt-in and prints a restart instruction. | G11: WAL + in-memory engine state; a live external write is unverifiable from the app's point of view. | Writing into a running instance and claiming success. |
| **D8** | Track C is **one-way history import**, not sharing: sessions are copied into the target as **new local sessions** with fresh ids and a provenance record; nothing existing is updated or deleted. | G1/G2: there is no shared store to re-index; each account owns its DB, so "visibility" can only be materialized by copying. G6 forbids rewriting entries anyway. | Junction/symlink one DB across profiles (different `owner_id`, WAL, exclusive locks, cloud ownership — impossible); row-level merge of the same session (no stable, non-reused key). |
| **D9** | Track C ships **inventory first**: `-Mode Inventory` produces a JSON + human diff report and writes nothing. Copy is a separate, explicit `-Apply`. | The copy path carries real unknowns (artifact references, FTS, cloud re-list). A dry-run is shippable value with zero blast radius. | Shipping copy-only and discovering breakage in the developer's real history. |
| **D10** | Copy prerequisites are hard gates: target `lockfile` free; matching `schema_migrations` (name+order+sha256); target DB backed up via the sqlite3 backup API (WAL-safe single file); source opened read-only; idempotency key `(source_profile, source_session_id, content_hash)` recorded in `<ProfileDir>\.autoclaw2-chat-imports.json`; abort if unresolved artifact refs exceed the configured threshold. | Never silent success; re-runs must not duplicate; a failed run must be reversible. | Best-effort copy with a warning. |
| **D11** | Quarantine by default: imported sessions are titled `[import] <original title>` (prefix configurable via `-TitleTag`, empty to disable) and carry a provenance row in the sidecar file. | The developer must be able to tell imported history apart from local history, and delete it wholesale later. | Importing indistinguishably (unreviewable, unremovable). |
| **D12** | Never import sessions whose `external_provider` is set (Telegram/IM). | G13: IM sessions are bound to a bot token owned by one instance; copying them invites 409 and cross-account billing. | Copying IM history. |
| **D13** | All SQL lives in `src/python/ghost/autoclaw2.py`, invoked through `ghost_cli.py` by absolute path; PowerShell only orchestrates (locks, backups, verdicts, audit). | Repo mandate: "SQLite logic lives in `src/python/ghost` — never re-embed Python in PS"; parameterized SQL only. | Inline `sqlite3` calls in `.ps1`. |

## 5. Architecture

### 5.1 Components

```
tools/autoclaw2-mcp.master.json      # device-level MCP definitions (reviewed, committed)
src/python/ghost/autoclaw2.py        # all SQL + planning + apply + verify (stdlib only)
src/python/ghost/__main__.py         # + subcommands: ac2-mcp-plan, ac2-mcp-apply,
                                     #   ac2-chat-inventory, ac2-chat-import
tools/sync_autoclaw2_mcp.ps1         # MCP orchestrator: preflight, backup, invoke, verify, audit
tools/watch_autoclaw2_mcp_sync.ps1   # resident: manifest stat-guard -> closed profiles only
tools/sync_autoclaw2_chats.ps1       # chat inventory / guarded import
src/windows/launch_autoclaw2_clone.ps1   # + pre-launch step [2b] (non-blocking, best-effort)
GHOST.bat                            # AutoClaw2 submenu rows [8]-[11], gids 73-76
```

PS↔Python contract follows the existing bridge style: a **base64 JSON payload
in**, a **JSON verdict out** on stdout, exit code authoritative (`0` ok,
`1` failed, `2` refused by a gate). Every mutation is re-read and compared
before the exit code is chosen.

### 5.2 Track M data flow

```
manifest ──┐
           ├─► normalize (slug, transport, locator canonical form)
Primary ───┘        │
                    ▼
        per profile: discover account dir ──► pick workspaces (D3)
                    │
                    ▼
        read existing governed_connected_sources (owner, workspace)
                    │
                    ▼
        merge (D6) ──► plan ──[-DryRun? report & exit 0]──► apply in ONE transaction
                    │                                              │
                    ▼                                              ▼
        audit JSONL + human table                        re-read + deep compare
                                                         (status/pending preserved,
                                                          locator byte-identical)
```

Locator canonicalization is byte-exact: HTTP → `trim`med absolute `http(s)` URL;
stdio → `stdio+v1:` + `{"command":…,"args":[…],"cwd":…}` with property order
`command, args, cwd` and `cwd` omitted when empty (matching
`encodeConnectedSourceLocator`). A slug is `^[a-z0-9][a-z0-9_-]{0,63}$`; anything
else is rejected at manifest load, not at write time.

### 5.3 Track C data flow

```
source profile (read-only)      target profile (closed, backed up)
  work_sessions                   plan: session -> {entries, heads, events, artifacts}
  neutral_session_heads                    │
  neutral_session_entries  ────────────────┤  new ids, [import] title, provenance
  work_events                              ▼
  neutral_session_fts            one transaction: INSERT session, heads, entries,
  governed_tool_artifacts(_custody)          events, fts rows, referenced artifacts
                                           │
                                           ▼
                                 verify: counts + spot-check + FTS hit test
                                           │
                                           ▼
                                 sidecar provenance + audit + verdict
```

Order of writes is fixed by foreign keys and by the head's paired-null CHECK:
`work_sessions` → `work_runs` → `work_events` → `neutral_session_entries` →
`neutral_session_heads` → `neutral_session_fts` → artifacts
(`governed_tool_artifacts`, `governed_tool_artifact_custody`) → attachment blobs.
Entry ids are rewritten as `<new_run_id>:<suffix>` preserving the original suffix
(`:request`, `:answer`, `:resource:…`) so the app's own parent-chain logic keeps
working.

**ID generation is schema-constrained, not free-form:** `work_events.event_id`,
`run_id` and `session_id` carry `CHECK` expressions asserting **UUID v4** shape
(version nibble `4`, variant in `8/9/a/b`). Generated ids must therefore be real
`uuid4()` values; a sequential or slug-shaped id aborts the transaction. The same
rule applies to entry ids, which inherit the run id prefix.

`payload` on every copied entry must satisfy `json_valid(payload)` — copy it
verbatim (already valid), never re-serialize with a lossy encoder.

### 5.4 Master manifest (format)

```json
{
  "schemaVersion": 1,
  "comment": "Device-level MCP definitions. Definitions only - no credentials.",
  "defaults": { "enabled": true, "sourcePermission": "allowed", "targets": ["all-clones"] },
  "servers": [
    { "slug": "filesystem", "name": "Filesystem", "transport": "stdio",
      "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:\\work"],
      "cwd": "", "enabled": true, "sourcePermission": "allowed",
      "requiresCredential": false, "notes": "local stdio, no auth" },
    { "slug": "remote-docs", "name": "Docs (HTTP)", "transport": "http",
      "endpoint": "https://example.invalid/mcp", "enabled": true,
      "sourcePermission": "approval_required", "requiresCredential": true,
      "credentialHint": "sign in once per clone" }
  ]
}
```

Rules: `slug` unique and pattern-checked; `transport` ∈ {`stdio`,`http`};
`requiresCredential: true` is **descriptive only** — it changes the report and the
WARN, never the write. Env-var *names* may be listed (`envKeys`), values never.

### 5.5 Track C copy contract (exact)

| Table | Copied | Rewritten | Notes |
|---|---|---|---|
| `work_sessions` | yes | `session_id`, `owner_id`, `workspace_id`, `title` (prefix), `created_at`/`updated_at` kept, `archived_at` cleared | `visibility` kept; `external_*` rows refused (D12) |
| `work_runs` | yes | `run_id`, `session_id`, **`credential_version` → NULL** | keeps model/route snapshot columns (`connection_*`) as-is — those are catalog references, not secrets; the credential version belongs to the source account and never travels (D4) |
| `work_events` | yes | `event_id` (fresh UUIDv4 — the column CHECKs demand it), `run_id`, `session_id`; the autoincrement `cursor` is reassigned by the target (rows insert in source cursor order) | `payload_json` kept byte-identical — embedded id references, if any, are left as-is (entries, not events, drive the app's rendering) |
| `neutral_session_heads` | yes | `session_id`, `conversation_head_entry_id`, `conversation_run_id`, `settled_answer_entry_id`, `settled_run_id`; recompute `next_session_seq` and `entry_count` | all four id columns are NOT NULL together or NULL together (table CHECK) — a half-remapped head is rejected by the schema, which is the safety net we want |
| `neutral_session_entries` | yes (INSERT only) | `session_id`, `entry_id`, `run_id`, `parent_entry_id` | never `UPDATE`/`DELETE` (G6); `entry_type` must stay inside the table's CHECK set (`request`, `attachment`, `reasoning`, `assistant`, `resource`, `tool_call`, `tool_result`, `compaction`, `answer`) |
| `runtime\desktop-attachments\*` | only blobs referenced by a copied `attachment` entry | — | missing blob ⇒ drop the entry and count it (same rule as artifacts, F5) |
| `neutral_session_fts` | yes | `session_id`, `entry_id` | `body` recomputed from the copied entry payload |
| `governed_tool_artifacts` + `_custody` | only those referenced by copied `tool_artifact` entries | ids | missing source file on disk → entry dropped + counted |
| everything else | **no** | — | `memory_assets`, `agents`, `im_*`, `scheduled_*`, connector tables stay put |

## 6. Safety and invariants

1. **Never silent success.** Every write is followed by a re-read + deep compare;
   mismatch ⇒ `FAILED`, backup retained, audit record, exit 1.
2. **Backup before mutation.** MCP: `runtime.sqlite` copied with the sqlite3
   backup API (WAL-safe single file) to
   `<ProfileDir>\.autoclaw2-sync-backups\<ts>\`. Chats: same, plus the sidecar
   file copied.
3. **Primary is read-only** unless `-IncludePrimary` is passed explicitly; even
   then the same backup+verify rules apply.
4. **No credential, token, or IM object is ever read into a payload, logged, or
   written.** Audit records carry paths, slugs, column names, and counts — never
   values from credential-bearing columns.
5. **Idempotency.** Re-running produces zero writes (plan diff empty) — asserted
   by test, not by inspection.
6. **Refusal over guessing.** Unknown schema version, missing account, missing
   workspace, held lockfile, unreadable source, unresolved refs above threshold ⇒
   exit 2 with a specific remedy line.
7. **One transaction per profile.** A profile either converges fully or is left
   untouched.
8. **Audit is append-only JSONL**, one line per target profile per run:
   `<ProfileDir>\.autoclaw2-sync-audit.jsonl`.

## 7. Failure modes

| ID | Situation | Handling |
|---|---|---|
| F1 | Target clone running (lockfile held) | Pre-launch path: not possible; one-shot/watcher: SKIP + WARN, exit 0 (nothing attempted), re-run suggested |
| F2 | `accounts\` empty (fresh clone, G1) | SKIP with "sign in once first" — never invent an account dir |
| F3 | Schema version or column set differs | Refuse (exit 2) with both versions printed; no partial write |
| F4 | Source workspace has no `root_path` match | SKIP that workspace + WARN; default workspace still targeted |
| F5 | Copied session references a missing artifact file/row | Drop the referencing entry, count it, surface in the report; abort if ratio > threshold (default 5%) |
| F6 | App rewrites/repairs imported rows on next start | Detected by post-run verify (second read after launch in the acceptance run); documented, not hidden |
| F7 | Cloud re-lists or overwrites imported sessions | Out of our control (E4). Report states "local copy"; developer decides whether to keep |
| F8 | `-wal` still present after backup/restore | Never restore by file copy while app runs; the sqlite3 backup API produces a single clean file; post-restore `PRAGMA quick_check` |
| F9 | Manifest edited with an invalid slug/locator | Rejected at load, before any DB is opened |
| F10 | Watcher already running | Named mutex `Autoclaw2McpSyncWatcher` + startup process scan (ZCode pattern), second copy exits 0 with a note |

## 8. Acceptance criteria

**Track M**

- A1 A manifest with 2 servers (1 stdio, 1 http) applied to `c1` produces exactly
  2 rows in the default workspace, `status='pending'`, `tools_json='[]'`,
  `revision` starting `sync-v1:`, and zero writes elsewhere.
- A2 Re-running is a no-op: plan diff empty, exit 0, audit line says `unchanged`.
- A3 A clone-local `enabled=0` on a synced slug survives a re-sync; a
  clone-only slug is never deleted; `tool_permissions_json` is untouched.
- A4 `-DryRun` writes nothing (byte-identical DB hash before/after) and prints
  the full plan.
- A5 With the clone running, the one-shot run exits 0 with a SKIP + WARN and
  leaves the DB byte-identical.
- A6 No file under `account-credentials.enc`, `owner-secrets.enc`, `mcp-oauth\`
  is opened for writing; the audit line contains no credential value.
- A7 Removing a server from the manifest leaves the clone row in place (merge,
  not mirror) and reports it as `manifest-absent`.

**Track C**

- C1 `-Mode Inventory` on Primary + `c1` prints per-session rows (id, title,
  workspace root, entry/event/artifact counts, IM flag) and writes only the
  report file.
- C2 Import of one small session into a *sacrificial copy* of a clone profile
  yields: session visible in the app, correct title prefix, message text intact,
  tool cards intact or explicitly counted as dropped.
- C3 Entries are inserted, never updated: the run works with the immutability
  triggers active (no trigger disabled, no pragma bypass).
- C4 Import is idempotent (same content hash ⇒ skip) and never duplicates.
- C5 A session with `external_provider` set is refused with a clear message.
- C6 Aborting mid-run (simulated failure) leaves the target DB at its pre-run
  state (transaction rollback) and the sidecar unchanged.
- C7 Verification: entry/head/event counts match the plan, FTS search for a
  distinctive phrase in the imported session returns ≥1 hit.

## 9. Open questions → Phase 0 spikes

| ID | Question | Spike | Fallback if unfavourable |
|---|---|---|---|
| E1 | Does a **closed-profile** write show up in the sidebar on next launch with no extra step? | Copy a throwaway session into a copy of `c1`'s DB, launch, look | Require a restart (already the norm) or a `-Repair` re-run |
| E2 | Does the app **rewrite/normalize** imported rows at startup (revision, status, tools)? | Diff the DB before/after one launch | Accept as "app-owned after import"; document |
| E3 | Do `tool_artifact` entries open cleanly when their artifact rows are copied? | Copy one session containing tool calls | Drop those entries, keep text (F5) |
| E4 | Does the **cloud account** re-list/overwrite local-only sessions? | Import into `c3` (fresh account), sign out/in, observe | Declare chats "local history only"; ship MCP-only |
| E5 | Can an MCP source be authored **only** in the GUI, or does a written `pending` row become usable after the app tests it? | Write one `pending` http row, open the sources UI, use it | Keep `-From Primary` as the only write path (M2) |

Each spike is **read-only outside a sacrificial profile copy** and must end with a
one-line verdict appended to this document.

## 10. Provenance

Read today (2026-11-02) on this host: `governed_connected_sources` /
`…_revisions` / `work_sessions` / `neutral_session_*` DDL + counts from the three
live `runtime.sqlite` files; `account-profile.json`, `desktop-preferences.json`,
`telegram-connection.json`; `main.cjs` (28.9 MB) string and snippet extraction for
`governed_connected_sources`, `encodeConnectedSourceLocator`,
`STDIO_LOCATOR_PREFIX`, `desktop-credential-stage`, `mcp-oauth`; profile tree
listings. No file in any profile was modified during this investigation; all
SQLite connections were opened `mode=ro`.
