## Summary

<!-- What does this PR change and why? One or two sentences. -->

## Changes

- 

## Checklist

- [ ] CI green (PSScriptAnalyzer + Pester on Windows; ShellCheck + `bash -n` on Linux)
- [ ] Files follow naming: `src/<os>/<tool>.ps1`, unversioned filenames
- [ ] Every write is backup-first + verify-after (no silent success); audit log + restore script wired
- [ ] Chat history / `Local Storage` / `Backups\` / `workspaceStorage` preservation untouched
- [ ] PowerShell 5.1 compatible (no ternary, no `$Input`, `GetBytes()`, no-BOM UTF-8 writes)
- [ ] **No secrets, machine IDs, audit logs, or personal paths committed**
- [ ] `CHANGELOG.md` updated for user-visible changes
- [ ] New files carry `# SPDX-License-Identifier: Apache-2.0`
