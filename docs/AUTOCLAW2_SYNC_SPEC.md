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
| G8 | **Schema history is append-only multi-row**: up to 2026-11-04 it was a single row (`0001_clean_dogfood_baseline`, order 80, same sha256 on Primary, `c1`, `c3`); the 4.0.0 update (2026-11-05, ledger migration 80→85) appended `0081_agent_default_project` … `0085_session_goals` on top of the intact baseline. The sync gate therefore requires the baseline tuple to be present + our column sets; the max sequence is deliberately not pinned (86+ stay acceptable). | Live query + the 2026-11-05 gate-refusal verdict (all six rows printed verbatim). |
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
| F3 | Schema drift: baseline row edited/removed, or a required column missing | Refuse (exit 2) with the expected baseline + found rows printed; no partial write. Forward-appended migrations on top of an INTACT baseline are accepted (2026-11-05: the old single-row check refused every post-4.0.0 profile for a whole day — launcher 2b became a silent no-op, now warned loudly) |
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

**Spike verdict E5 (empirical, 2026-11-04 — before the formal Phase 0 run):** manifest-driven
rows written to `c1` exactly per D5 (10 rows verified: `status='pending'`, `error_code=NULL`,
`revision='sync-v1:*'`, `tools_json='[]'`, one default workspace) are **NOT usable as-is**:
the sources UI shows "The server returned an invalid response." for every source (stdio and
http alike) and the runtime logs `sourceDeferredCount: 0` (zero tools from connected sources,
while the app's own cloud-side `mcp_legal_*` connectors keep working). The servers themselves
are healthy — a manual MCP `initialize` handshake against the playwright stdio server
succeeded. The sync layer is therefore exonerated; the failure is in the app's adoption of
externally-written rows. Next probes: (1) click the UI **Reconnect** on a credential-free
stdio source (playwright) — if it adopts, document reconnect-per-source; (2) if it still
fails, the E5 fallback applies: GUI-author sources in Primary once, then distribute with
`-From Primary`; (3) for http sources, expect per-clone sign-in regardless (D4 imports them
unauthenticated).

**E5 RESOLVED (2026-11-05 evening — root cause mined from the 4.0.0 `main.cjs`):** the app
parses every `governed_connected_sources` row STRICTLY (`Gxn` → the `A_` zod schema):
`status` must be `'connected'|'failed'` — the sync's `'pending'` is an ILLEGAL value. Every
pending row fails the parse and renders through the fallback decoder `fFi` with a hardcoded
`error:"invalid_response"` — exactly the "The server returned an invalid response." UI text —
and `test()`/Reconnect throw in `require()` before any network call. This matches the live
evidence perfectly: zero stdio spawns, zero MCP network calls and zero log traces all day in
c1/c3 while the red list showed. The source test itself is **LOCAL** (child_process spawn for
stdio with MCP `initialize` protocolVersion 2025-03-26 + `tools/list`; direct Streamable-HTTP
fetch for http endpoints; the cloud only serves the whitelisted official connectors and
api.github.com). Mined row contracts: slug `^[a-z][a-z0-9_]{0,39}$` (no '-');
`error_code` ∈ {authentication_failed, connection_failed, invalid_response} or NULL;
`tools_json` = JSON array of `{name: ^[a-z][a-z0-9_]{0,63}$, description: non-empty string,
remoteName?, inputSchema? ≤16384 serialized chars}`; `updated_at` = ISO-8601 with `Z`. Tools
are only USABLE when the row is `status='connected'` + the tool name is in `tools_json` +
the workspace is trusted (`work_workspaces.trust_status='trusted'`).
`governed_connected_source_revisions` is a post-success cache, NOT a gate. No entitlement
gate exists on user-added sources. The GUI has no import/export for tools (command/endpoint
are immutable after creation; a clone must delete + re-create via the GUI).

**Fix (implemented 2026-11-05):** the sync now replicates the app's own local test per source
(stdlib-only `discover_stdio`/`discover_http` in `ghost/autoclaw2.py`) and writes PRE-TESTED
rows the app accepts natively — `status='connected'` + real `tools_json` (IL-mapped:
vme-normalized tool names kept consistent with the app's permission lookups, synthesized
descriptions, oversized schemas dropped) + a `native.<sha256[:16]>` revision (T5 replica,
contract `connected-source-tool@2`) on success; `status='failed'` + a legal error_code on
failure (honest — and since the row now parses, the GUI's own Reconnect works on it). Legacy
`pending` rows are rewritten even when the definition is unchanged; sync-authored rows with
illegal slugs migrate in place (`chrome-devtools` → `chrome_devtools`,
`supabase-masarx` → `supabase_masarx`). Verify-after re-reads every row and requires the
strict shape. http sources behind OAuth (Vercel / GitHub Copilot / Sentry / Upstash) test as
`authentication_failed` — sign in once per clone via the GUI (Edit → token), then Reconnect.
The sync warns loudly when the target workspace is untrusted, because tools will not be
offered in new runs until it is trusted in the GUI.

### 9.1 Incident 2026-11-05 — one corrupt CAS blob bricked every clone run (HEALED)

One content-addressed blob in the per-account declarative-resources store
(`accounts\<hash>\runtime\pi-resources\blobs\sha256\`) had content sha256 ≠ its file name:
`c30d9cd48561accc401a04ad079237b43223e3550ba3ff2a712d944be10baa63.r` (7,906,728 B). Every run
start loads the current revision manifest → verifies the blob → `resource_revision_corrupt
(cause: content)` → run failed in ~1–2 s before any model request. The 4.0.0 updater detects
it and attempts a quarantine, but every file/dir in the CAS tree is Windows-ReadOnly, so
`zwork.resource.snapshot_quarantine_failed … code EPERM` fires and the app can never
self-heal. All five top-level `revisions\<hash>\manifest.json` in c1 (and all three in c3)
reference the blob, so no revision loads.

Verified facts (full hash audits + logs, 2026-11-05):
- c1 (2031 blobs): exactly 1 mismatch — this blob, mtime 2026-10-29T12:11Z. c3 (1680 blobs):
  same single mismatch, mtime 2026-11-02T04:46Z. Primary's DORMANT account `27e33829…`: same
  single mismatch (that account is equally bricked if ever reactivated).
- All corrupt copies share ONE wrong-content fingerprint (`e6fc9d1a55b0f171…`, identical byte
  count) — a deterministic bad fetch written under the declared hash, i.e. the app's CAS
  writer accepted content that never matched its name (missing write-time integrity check).
  The Primary's fresh account `68f7331f…` (signed in 2026-11-05) fetched a CLEAN copy of the
  same blob — the upstream source was fixed by then.
- The corruption predates the 4.0.0 update (2.1.1-era runs on 11-05 01:01Z fail identically);
  the update is not the cause and could not heal it.

Heal procedure (executed 2026-11-05, live-verified):
1. Close the clone (lockfile probe). 2. Full CAS hash-audit (content sha256 vs filename) to
enumerate ALL corrupt blobs. 3. Backup the blob + TOP-LEVEL `revisions\<hash>\manifest.json`
copies to `ID_Backups\<ts>\` (never recurse into `revisions\` — it contains dangling
junctions that abort enumeration). 4. Clear ReadOnly on the corrupt blob, overwrite it with a
verified-clean copy from a healthy store (verify the source's hash first), restore ReadOnly,
re-hash to verify. 5. Relaunch via the launcher; send one ping. c1: run completed 18:02 local
(model request issued, answer rendered, zero corrupt events in the log). Fallbacks when no
clean copy exists: rename the blob `.corrupt-bak` (4.0.0 rebuilds the revision), then move
the whole `pi-resources` aside (`pi-resources.bad-<ts>`) — the app re-fetches a fresh catalog
(proven by every fresh account snapshot verifying clean).

**Warning:** never `-RestoreBackup` across the 4.0.0 migration — the
`.autoclaw2-sync-backups` are whole-DB schema-80 copies; restoring one down-migrates the
runtime DB below the app's own migrations.

### 9.2 Incident 2026-11-06 — the last flipped source (cloudinary) + the Primary's two surprises (RESOLVED)

After the E5 fix landed, blue (c1) and green (c3) converged to identical UIs —
Playwright ·21, Chrome DevTools ·3, Obsidian ·15, Supabase ×2 ·20 all green — with
exactly ONE stdio source still flipping to `invalid_response` at every app start:
**cloudinary**, despite the sync's own pre-test reporting `connected(42)` and the
written row passing every check the sync knew about.

**Root cause (bundle + live-DB proven):** the stored-row zod (`IL`, refined from
main.cjs) is STRICTER than the gL registration walk the sanitizer mirrored:
`inputSchema: u.record(...).refine(n => JSON.stringify(n).length <= 16384,
"inputSchema_too_large")` — **16384 chars serialized, per tool**, measured AFTER
keyword stripping. One over-limit tool fails the WHOLE row parse at startup
(`registerOrFail` → fallback renderer). Cloudinary's `upload_asset` serializes to
**20,024 chars** — the only violation in the whole suite (every other connected
source's largest schema is ≤2 KB). The sanitizer's old fast-reject (65536, the gL
walk bound) let it through; `A_` (the row zod) has NO tools-count or total-size cap,
so `max(32)`/`256*1024` caps seen elsewhere in the bundle belong to the app's own
live-discover path, not to rows we write.

**Fix:** `_sanitize_input_schema` now measures the CLEANED schema (UTF-16-exact,
`JSON.stringify` units) and drops the tool when it still exceeds 16384 — raw size is
irrelevant because stripping unsupported keys shrinks schemas. `strict_row_problems`
mirrors the refine (per-tool `inputSchema_too_large` + `remoteName` 1..128) so the
verify-after gate can never wave such a row through again. Live: c1 re-synced
`cloudinary: connected (41 tool(s))` — `upload_asset` is the honest cost.

**Primary surprise 1 — empty profile:** the Primary had NO sources at all (the sync
never targeted it), and `-Target Primary` refused with `ambiguous-account`: the
Primary carries TWO account dirs (dormant `27e33829…` + live `68f7331f…`) and
`resolve_profile` was built to refuse guessing. New rule: an explicit account hint
(exact 64-hex or unique prefix, `-Account <hint>` on the PS side) wins; without one
the account whose `runtime.sqlite` was written most recently is selected, LOUDLY
(stderr WARN). A genuine tie (<60 s apart) still refuses.

**Primary surprise 2 — fresh-account schema stamp:** the live `68f7331f` account was
bootstrap-created (not migrated), and its `schema_migrations` holds a SINGLE row —
`('0001_clean_dogfood_baseline', 85, sha256:2e8dc336…)` — the app's bootstrap
creates the schema directly at the current version and re-stamps the baseline id at
the current sequence. A legitimate second history encoding. `check_schema` accepts
it at exactly that tuple (`FRESH_STAMP_BASELINE`, verdict `history:
"fresh-stamp-85"`, column gate unchanged); any other single-row shape still refuses
as drift.

First Primary sync (2026-11-06): 10 rows written + verified — 6 connected
(playwright ·21, chrome_devtools ·3, supabase ·20, supabase_masarx ·20, cloudinary
·41, obsidian ·15) + 4 honest auth failures (upstash/sentry/github/vercel — OAuth
sign-in per profile, same as clones).

**§9.2.1 — the http-auth contract (mined 2026-11-06, answers "Reconnect does
nothing"):** clicking Reconnect on a token-less http source is EXPECTED to look
like nothing happened — the app re-runs its live test, the endpoint answers 401,
the row is re-recorded `authentication_failed`, and the chip stays red with NO
toast (progress over the E5 era, where Reconnect threw before any network). The
app's OAuth machinery (`integrations.start_oauth`, `authKind:"mcp_oauth"`, PKCE
loopback redirects, `/.well-known/oauth-protected-resource` discovery) belongs to
the BUILT-IN connectors only — user MCP sources never auto-OAuth. The user fix
path is the **"Bearer token (optional)" password field in the "+ Add tool"
dialog** (`tools-mcp-add-credential`) — the Edit dialog deliberately exposes NO
connection parameters ("Connection parameters are set when added. To change the
address, remove and add it again."), so the token is supplied at ADD time: delete
the bare row, re-add the same URL with the token, keeping the SAME source name so
the sync's merge matches the manifest slug and never re-creates a bare duplicate.
The token is stored in the app's per-(workspace, slug) CUSTODY store
(`storeCredential`, row `credential_version` links to it) and injected via an
injected `authHeaders` hook at request time — the row's `endpoint` locator stays
the bare URL. This makes
the sync structurally safe for credentials: `merge_sources` compares
name/endpoint/source_permission only, so a signed-in row is `unchanged` on every
later sync (the launcher's pre-launch [2b] cannot wipe tokens). Bearer values for
GitHub/Vercel already exist machine-wide from the MCP registry sync
(`GITHUB_MCP_AUTHORIZATION` / `VERCEL_MCP_AUTHORIZATION`, full "Bearer …" header
values — strip the `Bearer ` prefix for the dialog field); Sentry and Upstash
need a token created in each service's console per profile. After sign-in +
Reconnect the row reads `status=connected` with a non-NULL `credential_version`
(verifiable live — WAL reads are safe against a running app).

**§9.2.2 — programmatic credential wiring + the app's wire caps (2026-11-06,
"run them now" session):** the credential custody is fully replicable without
the UI: `<account>/runtime/credentials.enc` = Electron safeStorage(file) =
**`b"v10" + nonce(12) + AES-256-GCM(key, nonce, JSON.stringify(dict))`** where
`key` = DPAPI-decrypt(base64decode(Local State → os_crypt.encrypted_key)[5:])
(per-profile, Chromium OSCrypt — .NET ProtectedData does NOT read these files
directly because of the v10+GCM layer; python `cryptography` + ctypes DPAPI
does, proven by decrypting the app's own `model-connection-command-claims.enc`).
Key = `JSON.stringify([ownerId, "source:<workspaceId>:<slug>", version])`
(ownerId = the rows' owner_id UUID), value = the credential STRING — a raw token
becomes `Authorization: Bearer <token>` (mined `EJ`), or a JSON object passes as
a literal headers record. Row `credential_version` must equal the key's version.
The app RE-TESTS every source at startup and rewrites rows natively on success
(omniroute flipped to a `native.` revision the moment its router came up).
Outcomes: github + vercel authenticated THROUGH the wired custody (the app got
past 401 — `invalid_response`, not `authentication_failed`) but its own
discovery then failed: **vercel's raw catalog is 633 KB — 2.4× the app's hard
`JSON.stringify(tools).length > 256*1024` discover cap** (no toolset header
shrinks it) → impossible on v4.0.0; **github fails the startup test
deterministically** while the exact same handshake replays clean externally
(136 KB, max schema 3.5 KB, no dups, no pagination, gL-clean schemas) — an
app-side quirk left unresolved; a runtime Reconnect may still succeed. Stale
tokens (sentry `sntryu_…`, cloudflare `cfut_…`) fail auth honestly until
recreated in each console; upstash/stripe/resend/openseo are OAuth-only.
`discover_http` gained an optional `headers` parameter so the sync can pre-test
credentialed http sources. Final state after the full merge + wiring session:
**10 connected / 10 honest-failed per signed-in profile** (the 10 green include
omniroute ·110 with its local router running, linkedin ·5, github_local ·26;
notion stays connected·0 — the current server exposes no tools with the legacy
`NOTION_TOKEN` even via `OPEN_API_MCP_TOKEN`).

## 10. Provenance

Read today (2026-11-02) on this host: `governed_connected_sources` /
`…_revisions` / `work_sessions` / `neutral_session_*` DDL + counts from the three
live `runtime.sqlite` files; `account-profile.json`, `desktop-preferences.json`,
`telegram-connection.json`; `main.cjs` (28.9 MB) string and snippet extraction for
`governed_connected_sources`, `encodeConnectedSourceLocator`,
`STDIO_LOCATOR_PREFIX`, `desktop-credential-stage`, `mcp-oauth`; profile tree
listings. No file in any profile was modified during this investigation; all
SQLite connections were opened `mode=ro`.
