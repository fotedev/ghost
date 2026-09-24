# Contributing to GHOST

Thanks for your interest in contributing! This document covers setup, the
project's non-negotiable conventions, and the PR workflow.

## Prerequisites

- **Windows 10/11** with PowerShell **5.1 or 7** (the scripts must run on 5.1)
- **Python 3** on `PATH` (used only for SQLite writes via `Set-SqliteKeys`)
- **Git**, and for shell-script changes: **bash 4+** and [ShellCheck](https://www.shellcheck.net)
- Pester 5 and PSScriptAnalyzer for tests:
  ```powershell
  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
  ```

## Repository layout

```
src/windows/   PowerShell resetters (unversioned names) + identity_utils.ps1
src/linux/     Bash resetters + id_reset_common.sh
tools/         standalone utilities (watchdog etc.)
tests/         Pester 5 suite (unit + repo integrity)
docs/          user guides (research notes stay local-only)
archive/       superseded versions — local-only, NEVER committed
```

## Running the tests locally

```powershell
# Lint (must produce zero Error-severity findings)
Invoke-ScriptAnalyzer -Path src,tools,tests -Recurse -Settings ./tests/PSScriptAnalyzerSettings.psd1 -Severity Error

# Test suite
Invoke-Pester -CI -Output Detailed
```

```bash
# Shell scripts
shellcheck src/linux/*.sh ghost.sh
for f in src/linux/*.sh ghost.sh; do bash -n "$f"; done
```

## Non-negotiable conventions

These are enforced in review (see `AGENTS.md` for the full rationale):

1. **Never silent-success.** Every write is followed by a re-read + comparison.
   Mismatch ⇒ `FAILED` output + audit-log entry. No exceptions.
2. **Backup before you touch.** Every mutated file goes through
   `Backup-FileToTimestampDir` into the app's `ID_Backups/<ts>` dir, and the run
   emits a self-contained restore script (`New-RestoreScript`).
3. **Preserve chat history and workspaces.** Chat stores, `Local Storage`,
   `Backups\`, and `workspaceStorage` are never deleted (UPSERT-only at most).
4. **PS 5.1 compatible.** No ternary `? :`, no `$Input` variable name,
   `RandomNumberGenerator.Create().GetBytes()` (not `.Fill()`), no-BOM UTF-8
   writes via `[System.IO.File]::WriteAllText`.
5. **Parameterized SQL only**, temp `.py` scripts in `$env:TEMP`, Python
   detected via `Get-Command python` → `python3` fallback.
6. **Dot-source `identity_utils.ps1`** — shared logic lives there; per-IDE
   scripts are thin target manifests.
7. **Scope isolation.** Identity scripts touch app data only; MAC/hostname/
   registry-source work belongs exclusively in `change_device_id.ps1`.

## Naming and versioning

- Scripts live at `src/<os>/<tool>.ps1` with **no version suffix** — Git tags
  are the version record (`CHANGELOG.md` documents notable changes).
- Never commit superseded versions. Test your replacement against the previous
  behavior locally, then delete or move old files to `archive/` (git-ignored).
- New files should carry an SPDX header: `# SPDX-License-Identifier: Apache-2.0`.

## What stays out of the repo (local-only)

`.envlocal` (real tokens — see `.env.example`), `archive/`, `docs/` research
notes, `tools/block_qoder_domains.ps1`, `.context/`, `.qoder/`, `.trash/`,
and anything containing machine IDs, audit logs, or credentials. If a file
would identify a device or account, it does not get committed.

## PR workflow

1. Fork / branch from `main` (`feat/<topic>` or `fix/<topic>`).
2. Commits follow [Conventional Commits](https://www.conventionalcommits.org)
   style (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`) — matching the
   existing log.
3. Run the full local gate (lint + tests + shellcheck) before pushing.
4. Open a PR using the template; CI must be green.
5. Update `CHANGELOG.md` for user-visible changes.

## License

By contributing you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
