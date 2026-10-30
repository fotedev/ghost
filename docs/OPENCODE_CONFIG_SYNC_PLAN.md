# OpenCode Config Sync Plan — definitions-only Primary → clone (secrets never copied)

Status: PROPOSED (not started). Source: OPENCODE_CLONES_SPEC.md §7 future work —
"Per-clone provider config (`opencode.jsonc` API keys) is manual; a
definitions-only Primary→clone sync (`sync_zcode_assets` pattern) is future
work — never copy live secrets wholesale without a scrub design." This doc IS
that scrub design. Backlog ID: CS-1.

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
