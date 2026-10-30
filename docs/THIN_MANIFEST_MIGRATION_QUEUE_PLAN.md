# Thin-Manifest Migration Queue — the remaining five resetters

Status: queue defined by PYTHON_HYBRID_ROADMAP.md (pilot ACCEPTED 2026-10-18;
`reset_cursor.ps1` v0.3 + `reset_devin.ps1` v0.4 landed). The CONTRACT lives in
the roadmap (Phase 3 pilot design + acceptance criteria); this doc is the
per-script execution breakdown plus the sequencing gate the roadmap implies but
does not state. Backlog §4.

## 1. Contract recap (short form — the roadmap is authoritative)

```
reset_<app>.ps1 = dot-source identity_utils
               -> Assert-Administrator
               -> Stop-App (stays PS: Get-Process/Stop-Process)
               -> STEP TABLE: id, title, python subcommand, payload
               -> generic runner: per step, Invoke-GhostCore ->
                  src/python/ghost_cli.py <subcommand>
                  (base64 JSON payload in, JSON out)
               -> collect audit lines, emit the restore script, summary
```

- Every mutation routes through the core (`Invoke-GhostCore` = the single
  PS→Python point); 18 subcommands exist today (`__main__.py`), including
  `sqlite-update`, `delete-secrets`, `clear-cli-telemetry`, `json-patch`,
  `salt-rotate`, `json-remove`, `store-delete`, `sweep-file`, `sweep-tree`,
  `patch-argv`, `replace-text`.
- Step order, step titles, audit keys, restore actions and the summary stay
  IDENTICAL to the pre-migration script (the parity contract).
- PS keeps: elevation, process control, the step-table loop, system-level steps
  (registry/MAC/hostname stay PS by design).
- Archive the pre-migration version first (`archive\`, local-only convention);
  it stays there until the NEXT script migrates cleanly (rollback note).
- Core modules `ghost/backup.py`, `ghost/filesweep.py`, `ghost/winstore.py`
  carry the backup/sweep/winstore invariants; extend the core with tests rather
  than embedding Python in PS (AGENTS.md).

## 2. Sequencing gate (NEW, 2026-10-28) — fix before migrate

A script migrates only AFTER its bug-sweep fixes have landed
(docs/BUG_SWEEP_REMEDIATION_PLAN.md). Migrating an unfixed script would freeze
buggy behavior as the parity contract. Concretely:

| Order | Script | Gate | Notes |
|-------|--------|------|-------|
| 1 | `reset_trae.ps1` (16 steps) | BS-9 close-out (report 04 re-verified; 2026-10-28 spot-checks say most items already landed) | NEXT per the roadmap order |
| 2 | `reset_qoderwork.ps1` (26 steps) | ready (sweep scope 07: 11/11 fixed) | — |
| 3 | `reset_minimax_opencode.ps1` (22 steps) | ready (sweep scope 08: 9/9 fixed) | the CS-6 preflight-lane docs note is stale, no code gate |
| 4 | `reset_qoder.ps1` (31 steps) | BS-7 (sweep scope 05 — untouched) | biggest surface; migrate last-but-one |
| 5 | `reset_zcode.ps1` (27 steps + [6b]) | W1 hardening (ZCODE_RESET_EDGE_CASES_PLAN) + BS-5, in the same unblocked window | LAST per the roadmap; the [6b] apiKey-blanking line is the write-guard trigger — migrations touch whole files, so this script is unreadable to the toolchain until the guard question is resolved |

One script per session; the pattern is reviewed after EACH migration, never
batched (roadmap rule).

## 3. Per-script step-mapping plans

### 3.1 reset_trae.ps1 — NEXT

Step inventory (AGENTS.md + script header): machineid/storage.json identity
patch, argv.json crash-reporter-id, device_id_salt, os_crypt rotation,
state.vscdb + workspace DBs, Cookies/NPS/sentry/DIPS/Trust Tokens/Crashpad/logs
sweeps, `ModularData\ai-agent` identity-ROWS-ONLY scrub (chat preserved),
`ModularData\ckg_server\local_env.json` device_id + host_map, `aha` delete,
SharedStorage, `Partitions\trae-webview`, `iCubeAuthInfo://*` removal,
`has_device_id_updated_to_aha=false`.

Mapping:
- JSON identity stores (storage.json, argv.json via JSONC, local_env.json
  device_id + host_map, Preferences salt) → `winstore` / `json-patch` /
  `patch-argv`; the host_map dict patch needs the generic JSON patch path.
- state.vscdb + workspace DBs + ai-agent identity rows + iCubeAuthInfo rows →
  `sqlite-update` + `delete-secrets` (parameterized; identity-rows-only LIKE
  patterns — the generalized delete-secrets covers it).
- os_crypt / Cookies / NPS / sentry / DIPS / Trust Tokens / Crashpad / logs /
  aha / SharedStorage / Partitions sweeps → `sweep-file` / `sweep-tree` /
  `store-delete`.
- Expected NEW core subcommands: none known — confirm during migration; if a
  step genuinely needs one, extend the core FIRST with unittest coverage, then
  map the step.

### 3.2 reset_qoderwork.ps1

- `agents.db` oauth/app_settings scrub → `delete-secrets` (+ the schema-missing
  warn semantics that sweep scope 07 fixed — carry them into the core contract),
  real re-count verification via SELECT.
- `auth.dat` → `store-delete`; state.json patch → `json-patch`.
- MachineGuid / MAC / hostname system steps → stay PS (final steps).

### 3.3 reset_minimax_opencode.ps1

- `auth.json` wipe → `json-patch` to `{}` (and the v1.3 mcode-public DELETES →
  `sweep-file` — a `{}` there blocks the login page; keep the distinction).
- Version preflight (≥1.17.0) + distinct updater IDs → stays PS (process/paths).
- Chromium per-profile sweeps, updater-tmp, DIPS/SharedStorage suffix sweeps,
  lockfiles, uninstall_metrics → `sweep-tree` (glob/suffix variants — check the
  core's sweep options; extend if a suffix sweep is missing).
- `windowIds` rotation + per-window file delete; `.minimax\v2\session-handoff\device-id`
  → `json-patch` / `sweep-file` / `json-set`.

### 3.4 reset_qoder.ps1

- Main + CORS_Profile storage.json/state.vscdb sets, expanded state.vscdb scrub
  (loginBroadcast, secret.local.machine.variables) → `delete-secrets` +
  `sqlite-update`; webview partition stores → `sweep-tree`.
- `.qoder` installation_id/.auth machine_id rotation → `json-set` /
  `store-delete`; tmp/telemetry+logs → `sweep-tree`; probe step → stays PS.
- HKCU deviceid / HKLM SQM / MAC / hostname → stay PS (system steps).

### 3.5 reset_zcode.ps1 — LAST

- Per-target `-Target Primary|Secondary|…|All` semantics unchanged; selective
  tree-kill stays PS.
- Shared-CLI-db step already core-backed (`clear-cli-telemetry`); telemetry
  deviceMid / RUM store / setting.json deviceSid → `json-set` / `store-delete`.
- The [6b] provider-apiKey strip (Unlink-loop fix) must keep its EXACT
  semantics — this is the line family that trips the workspace write guard;
  migrate only in the unblocked window together with W1 + BS-5
  (docs/BUG_SWEEP_REMEDIATION_PLAN.md §9).

## 4. Per-script acceptance (mandatory, from the pilot's criteria)

1. Unittest coverage for any new/changed core subcommand (temp-dir fixtures,
   clobber + verify-after negatives).
2. Pester green + unittest suite green (67/67) + `Parser::ParseFile` 0 errors
   on the slimmed manifest.
3. ONE live admin run (app closed) compared step-by-step against the
   pre-migration audit output — identical steps, identical verify results,
   restore script re-verified.
4. Rollback note: the pre-migration script sits in `archive\` until the next
   suite migrates cleanly.

## 5. Out of scope

Phase 2 leaf-tool migrations (CANCELLED — roadmap), Phase 4 COM-heavy
launchers/watchers (stay PS, documented), the ZCode W1 hardening itself (its
own plan), new features beyond the parity contract.
