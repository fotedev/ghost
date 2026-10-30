# Python Hybrid Roadmap — Phase 2 cancelled, Phase 3 pilot design

Status: DECIDED 2026-10-17. Supersedes the 2026-09-24 phase list recorded in
the session memory (the original Phase 2 is unworkable as scoped; the reasons
are recorded here so nobody re-derives them).

## Phase 2 (leaf tools) — CANCELLED

The original Phase 2 proposed migrating the leaf tools to Python. Each target
now fails a hard invariant:

| Tool | Original plan | Why it is cancelled |
|------|---------------|---------------------|
| `tools/make_ghost_icon.ps1` | -> Pillow | The Python core's stdlib-only rule (no pip dependencies) is a deployment invariant: the toolkit must run on a bare Python 3 with zero installs. Pillow breaks it for an offline generator that System.Drawing already serves fine. |
| `tools/install_*_shortcuts.ps1` | -> pywin32 | The .lnk creation is `WScript.Shell` COM (and the AUMID reads are Shell.Application COM). pywin32 = non-stdlib + a fragile COM bridge for ~60 lines of PS that already works. |
| `tools/block_qoder_domains.ps1` | -> Python | The tool is security-sensitive and NEVER committed (.gitignore by design). A Python twin would live outside the repo and fork the maintenance. |

Net value of Phase 2 as scoped: negative. The real duplication lives in the
reset scripts -> Phase 3 is where the effort goes.

## Phase 3 — pilot: reset_cursor.ps1 (the canonical reference)

Target shape (the "thin manifest" contract):

```
reset_cursor.ps1   =  dot-source identity_utils
                   -> Assert-Administrator
                   -> Stop-App (stays PS: Get-Process/Stop-Process)
                   -> a STEP TABLE: id, title, python subcommand, payload
                   -> generic runner: per step, invoke src/python/ghost_cli.py
                      <subcommand> (base64 JSON payload in, JSON out)
                   -> collect audit lines, emit the restore script, summary
```

New core modules (stdlib-only, tested in tests/python/test_ghost_core.py):

| Module | Replaces | Contract notes |
|--------|----------|----------------|
| `ghost/backup.py` | `Backup-FileToTimestampDir` | timestamped `ID_Backups\<ts>\<label>` dir, clobbers an old `.backup` first (rename rule), returns a manifest entry the restore script consumes |
| `ghost/filesweep.py` | the per-step delete/rename/verify PS blocks | every mutation returns `{ok, path, before, after}`; "file existed" is never "value changed" |
| `ghost/winstore.py` | the storage.json / machineid / salt steps | JSON patch + verify-after re-read via the existing `json_patch` |

Unchanged: `sqlite_keys` (already core), the audit JSON shape, the restore
script format, the summary. The PS side keeps: elevation, process control,
and the step-table loop - nothing else.

Migration order after the pilot is accepted (the approved ascending-risk
list): cursor -> devin -> trae -> qoderwork -> minimax -> qoder -> zcode
last. One script per session; the pattern is reviewed after EACH migration,
not batched.

### Pilot acceptance criteria (all mandatory before generalizing)

1. `backup.py` + `filesweep.py` + `winstore.py` land with unittest coverage
   (fixtures on temp dirs; clobber + verify-after negatives included).
2. Pester + unittest green; parse-check on the slimmed manifest.
3. ONE live run of the migrated `reset_cursor.ps1` (admin, Cursor closed)
   compared step-by-step against the pre-migration audit output - identical
   steps, identical verify results, restore script re-verified.
4. A rollback note: the pre-migration script stays in `archive/` (local-only
   fallback convention) until the next suite migrates cleanly.

**PILOT ACCEPTED 2026-10-18.** Criterion 3 satisfied by a live admin run
(Cursor closed): all 15 steps `[OK]`, zero `[FAILED]`; step order and titles
1-15 byte-identical to the archived v0.2 manifest; audit
`audit_20261018_043515.json` + restore script written and parse-checked.
Criterion 4 already in place (`archive/reset_cursor_windows-v0.2.ps1`).
Generalization order stands: devin v0.4 already landed; next trae ->
qoderwork -> minimax -> qoder -> zcode last, one script per session.

### Phase 4 — unchanged

COM-heavy launchers/watchers stay PowerShell (documented 2026-09-24; the
AUMID stamping P/Invoke surface has no stdlib Python equivalent worth the
bridge).
