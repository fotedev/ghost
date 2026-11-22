# OpenCode Config Sync Plan — definitions-only Primary → clone (secrets never copied)

Status: **IMPLEMENTED 2026-11-16** (D2 = the default: sync provider
definitions WITHOUT the secret + one loud WARN per clone — developer pick).
Shipped as `tools\opencode_config_merge.ps1` (pure merge core, 12 Pester
tests) + `tools\sync_opencode_config.ps1` (the child) + the launcher
pre-launch step in `src\windows\launch_opencode_clone.ps1` ([2b/5]; a
failed sync warns and never blocks the launch). **CS-1 v2 shipped
2026-11-17** (PR: the §3/§7 v2 deferrals closed): resident watcher
`tools\watch_opencode_config_sync.ps1` (mutex `OpencodeConfigSyncWatcher`,
log `%LOCALAPPDATA%\watch-opencode-config-sync\config-sync.log`,
launch-ensure step [2c/5], GHOST.bat OpenCode [21]/[22] = gids 110/111,
19 static Pester tests) — the "-ApplyLive deliberately absent" note is now
SUPERSEDED by the CS-7 verdict below (§Phase-0, 2026-11-22): live-apply is
the CHILD'S DEFAULT, no flag needed. §3's "no resident watcher in
v1" is superseded by this entry. In-session acceptance ran
the plan's §5 items 1/3/4/5 on %TEMP% fixtures (dry-run zero-write; the
written clone config AND the audit JSONL Select-String clean for the
Primary's fake key; lockfile-held SKIP; Primary hash stable) — §6's live
runs stay user-supervised. Source: OPENCODE_CLONES_SPEC.md §7 future work —
"Per-clone provider config (`opencode.jsonc` API keys) is manual; a
definitions-only Primary→clone sync (`sync_zcode_assets` pattern) is future
work — never copy live secrets wholesale without a scrub design." This doc IS
that scrub design. Backlog ID: CS-1.

## Phase-0 (CS-7): does a RUNNING clone re-read its config? — LIVE-VERIFIED YES

Controlled probe, 2026-11-22, on clone c1 running its OWN v2.3.2 service
(staged at `c1\desktop\cli\2.3.2-x64\opencode-cli.exe serve --service`),
whose log (`c1\data\opencode\log\opencode.log`) shows the directory
watcher armed on `c1\config\opencode` at boot:

| Question | Evidence | Verdict |
|---|---|---|
| External edit → live reload? | a real content change (4 `enabled` flips) fired `config.updated` in the clone's service log **within ~2s** | **LIVE-VERIFIED** for the v2.3.2 desktop service |
| Does the write STYLE matter? | both an in-place truncate+write AND the atomic temp+`File.Replace` swap fired the reload (~2s each) | both safe — the atomic writer ships |
| The v1 npm CLI (1.18.32) | 280 `message=loading` lines ALL within ~0.4s of boot, none after | startup-only — new sessions boot fresh; a long-lived TUI needs a restart |
| The historical Primary "bursts" (23 `config.updated` events) | each carries `event.location.directory` = a PROJECT dir — workspace-scoped session events, coincident with (not caused by) the swarm tool's config writes | NOT evidence of global-config reload |
| Service sharing | a launched clone JOINS an already-running 2.3.2 service on port 28894 (c1 reused the Primary's orphaned daemon; after stopping it, c1 spawned its own) | recorded as the new TASK_BACKLOG CS-10 spike (shared-service isolation scope unverified) |

Probe pitfalls recorded (do not repeat): the first two "zero events" runs
were EDITOR NO-OPS — a rename-style `sed -i` write vs. the service's
PS-formatted content (`"enabled":  true`, double space), then a
single-space pattern vs. double-space — a live probe must DIFF CONTENT,
never trust the editor's success.

Consequence shipped (TASK_BACKLOG CS-7): `sync_opencode_config.ps1` syncs
RUNNING clones BY DEFAULT (with the live-reload verify-after polling the
clone's own log; `-SkipRunning` opt-out; `-ReloadProbeSeconds`, default 8),
the watcher needs no flag, the merge write went ATOMIC, and the merge
containers were fixed to the real shape (`mcp.servers.*` nested + direct
`mcp.*` entries — the flat walk let the Primary's whole `servers` block
silently drop clone-only servers inside it).

## 1. Verified ground truth (do not contradict)

- Clone homes are FROZEN: `%USERPROFILE%\OpenCodeClonesHome\c1..c5\` with
  `desktop\` (Electron userData) + `session\` + `data\` / `config\` / `cache\` /
  `state\` (the four `XDG_*` homes). The clone-home asar patch (engine v2)
  mkdirs the subdirs and sets `XDG_CONFIG_HOME` etc. per clone (spec §3.2/§3.4).
- The clone's CLI config therefore lives at `<CloneHome>\cN\config\opencode\…`
  (XDG_CONFIG_HOME → `<home>\config`); the Primary's is
  `~\.config\opencode\opencode.jsonc` and holds **LIVE API keys** — never
  copied verbatim, never committed, redacted in all docs (spec §7).
- The Primary's `~\.local\share\opencode` (3.7 GB `opencode.db`, `auth.json`,
  logs) stays Primary; session rows and credential stores are NEVER copied
  between homes (EC-D03; spec §7/§8).
- Single-instance keys off the per-clone userData; a running clone holds
  `desktop\lockfile` exclusively (the launcher's running probe).
- The ZCode precedent to mirror: `tools/sync_zcode_assets.ps1` (per-launch
  child, backup + verify-after + JSONL audit, running-instance SKIP+WARN,
  `-DryRun`, `-McpOnly`) and `tools/zcode_mcp_merge.ps1` (the unit-tested pure
  merge core: clone-local enabled toggles survive, clone-only servers kept, new
  servers inherit the Primary's enabled value, Primary definitions win).

## 2. What syncs and what never syncs (the scrub design)

**Syncs (definitions only):**
- MCP server DEFINITIONS under the config's `mcp` block (command/args/env-shape
  definitions), with the merge invariant above.
- Provider entries' NON-SECRET shape: provider id, model lists, default
  model/context settings — i.e. structure a fresh clone cannot guess.
- Nothing else in v1. plugins/hooks/skills stay per-clone (ZCode lesson: local
  state shadows discovery).

**Never syncs (hard rules):**
- `apiKey` values, `auth.json`, token caches — anything secret-bearing.
- Anything under `~\.local\share\opencode` (the data home) or `state\`/`cache\`.
- The Primary's files are opened READ-ONLY; the Primary is never written.

**Secret handling (decision D2 — needs the developer's pick):**
- Default: a provider block whose definition requires a secret is synced
  WITHOUT the secret (key absent) + one loud WARN per clone: "fill the API key
  once in the clone" — matching the suite's ONE-manual-login-per-clone rule.
- Alternative: skip such provider blocks entirely (clones stay fully manual).
  Never write a placeholder string that could be mistaken for a key.

## 3. Placement and safety model

- **v1 = launcher pre-launch step (2d-equivalent) in `launch_opencode_clone.ps1`**:
  runs before the clone starts, so there is NO running-instance race at all —
  simpler than ZCode, no `-McpOnly` distinction needed. A failed sync warns and
  never blocks the launch.
- Optional one-shot `-Target c1..c5|All` mode reuses the same child with the
  `desktop\lockfile` exclusive-open probe: held = running → SKIP + WARN
  (mirroring `sync_zcode_assets.ps1` semantics).
- No resident watcher in v1 (OpenCode clone sessions are short; pre-launch
  convergence suffices — revisit only if long-lived clones drift).
- Optional GHOST.bat OpenCode entry later (submenu [1]-[10] today; next free gid
  is 70) — defer to v2 to keep this change launcher-only.

## 4. Implementation shape

- New `tools/opencode_config_merge.ps1` — pure merge core mirroring
  `zcode_mcp_merge.ps1` (ConvertTo-DeepHashtable / Test-DeepEqual /
  Write-JsonNoBom / Invoke-Merge) + the secret-scrub filter. Unit-tested by
  `tests/opencode_config_merge.Tests.ps1` (port the zcode_mcp_merge cases +
  scrub cases: apiKey never present in output, clone-local toggles survive,
  clone-only entries kept, Primary wins on definitions).
  NOTE: this intentionally duplicates the merge invariant in v1 — do NOT
  refactor `zcode_mcp_merge.ps1` in the same change (it is shipping and
  unit-tested); record the dedup as follow-up.
- New `tools/sync_opencode_config.ps1` — the child: `-Instance cN|-Target All`,
  `-DryRun`, per-clone backup of the previous config into the clone home
  (`config-pre-sync-<ts>.json`), verify-after re-read, JSONL audit at
  `<CloneHome>\cN\config-sync-audit.jsonl` (paths + key names only — NEVER
  values, so no secret can leak into the audit).
- Launcher wiring: pre-launch invocation with the clone's `--opencode-clone-home`
  value; skip when the clone's config dir does not exist yet (first run — the
  clone starts anonymous by design).
- PS 5.1 rules: no ternary, `RandomNumberGenerator.Create().GetBytes()`,
  `[Console]::OutputEncoding = UTF8` around any Python/core call (none expected
  here — pure PS + JSON).

## 5. Acceptance criteria

1. Dry-run on a drifted clone prints the would-apply diff (definitions only)
   and writes nothing.
2. Live run converges the clone; verify-after re-read matches the merged
   result; per-clone enabled toggles and clone-only entries survive.
3. Secret gate: `Select-String` the written clone config AND the audit JSONL
   for the Primary's key values (read from the Primary config in-memory only) —
   zero matches, else FAILED.
4. A running clone (lockfile held) → SKIP + WARN, no writes.
5. Primary config file hash unchanged before/after every run.
6. Merge-core unit tests green; `Parser::ParseFile` 0 errors on both new `.ps1`;
   Pester suite green.

## 6. Test plan

- Unit: merge invariant + scrub cases (see §4).
- Live (supervised, clones closed): drift a clone's config by hand → sync →
  verify; run twice (idempotence); `-DryRun` writes nothing (snapshot mtimes);
  lockfile-held SKIP path; Primary hash stable.

## 7. Out of scope

Watcher/autostart, GHOST.bat menu wiring (v2), auth.json or any credential
migration, `opencode.db`/session rows, XDG data-home contents, the OpenCode
Primary reset path (stays IDE Resets [8]).
