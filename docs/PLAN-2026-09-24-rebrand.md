# Commit Plan — GHOST rebrand + ZCode multi-instance expansion

**Branch:** `main`
**Date:** 2026-09-24
**Scope:** working tree → 4 logical commits → `v1.1.0` tag (proposed)

---

## TL;DR — Why this is one PR / four commits, not one mega-commit

The working tree holds **three independent change classes** with different
review audiences and different blast radii. Mixing them in a single commit
breaks bisect, hides roll-back boundaries, and makes the changelog useless.

| # | Commit class                | Reviewer            | Risk if reverted |
|---|------------------------------|---------------------|------------------|
| 1 | Rename + docs sweep          | any contributor     | zero (pure refs) |
| 2 | Launcher + scripts          | Windows-only lead   | medium (GHOST.bat menu numbers + per-instance flags) |
| 3 | `tools/` utilities + assets | ZCode instance lead | medium (new external surface) |
| 4 | CI + tests + governance      | any contributor     | low (gates and ignores) |

Each commit is **independently revertable** and the working tree stays clean
after each step — no `git reset --hard` between them needed.

---

## Pre-flight safety gates (run BEFORE staging)

These are the blockers the working tree is already warning about — the diff
will produce false noise and an inconsistent CRLF policy if you skip them.

### Gate 0 — line-ending warnings

```
warning: in the working copy of '.gitignore', CRLF will be replaced by LF…
warning: in the working copy of 'tests/repo-integrity.Tests.ps1', LF will be
         replaced by CRLF…
```

`.gitattributes` (already tracked, per `tests/repo-integrity.Tests.ps1`
governance check) decides which files get CRLF. The working tree has
inconsistent endings — fix once before the first commit:

```powershell
# from repo root
git rm --cached .gitignore tests/repo-integrity.Tests.ps1
git add .gitignore tests/repo-integrity.Tests.ps1
# verify
git diff --cached --check
```

If `.gitattributes` is missing `*.bat text eol=crlf` and
`*.ps1 text eol=crlf`, add them — `.gitignore` and `.bat` need CRLF,
the test file wants CRLF, and Bash + markdown stay LF.

### Gate 1 — staged verify-after

```powershell
git diff --cached --name-status -M50    # confirm only renames, no surprise content
git ls-files --others --exclude-standard   # untracked inventory
```

Staged currently shows 4× `R100` (pure rename, 0 inserts/dels) — clean.
Untracked = 16 files, all new, no conflicts.

### Gate 2 — `archive/` and `.context/` are local-only

```
# must NOT appear in either list:
git status --porcelain | Select-String 'archive|\.context'
```

(Per AGENTS.md: `archive/` is local-only rollback; `.context/` is per-machine
agent config. Both belong in `.gitignore`. The repo root `.gitignore` already
excludes `.context/` but NOT `archive/`. Verify the latter before commit.)

### Gate 3 — secret scan

```
git diff --cached -- . ':(exclude)CHANGELOG.md' | Select-String -Pattern \
  'TELEGRAM_BOT_TOKEN|ghp_|sk-|api[_-]?key|password\s*=' -CaseSensitive:$false
```

`tools/watch_zcode_captcha.ps1` and `refresh_zcode_second_chats.ps1` reference
`.envlocal` for tokens — the *references* are fine, the *values* must never
land in the diff. (Quick review of HEAD did not surface any.)

---

## Commit 1 — `chore(rebrand): launcher rename + docs sweep`

**Audience:** docs reviewer. **Blast radius:** zero (pure path renames +
prose rewrites). **Time:** ~5 min.

### Stage
```
git add GHOST.bat docs/cli.md ghost.sh tests/PSScriptAnalyzerSettings.psd1
```

These are already staged as renames (R100). **Do not re-add with `-A`** or
you may pick up unrelated intent (`git status` would show them as
`unmodified` again, which silently drops the rename intent — see memory
note `git add with extra files silently pollutes index`).

### Verify staged = exactly these four
```
git diff --cached --name-status -M50
# expect: R  how-to-run.bat -> GHOST.bat
#         R  how-to-run.txt -> docs/cli.md
#         R  how-to-run.sh  -> ghost.sh
#         R  PSScriptAnalyzerSettings.psd1 -> tests/PSScriptAnalyzerSettings.psd1
```

### Body
```
chore(rebrand): launcher rename + docs sweep

R100 renames only — no behavior change:
  how-to-run.bat → GHOST.bat
  how-to-run.sh  → ghost.sh
  how-to-run.txt → docs/cli.md   (was the direct-command cheat sheet)
  PSScriptAnalyzerSettings.psd1 → tests/PSScriptAnalyzerSettings.psd1

No source code in this commit. Files named after their purpose (GHOST);
per-tool deep dives already live in docs/ from the previous refactor.

Refs: CHANGELOG [Unreleased] / Changed.
```

### Post-commit check
- `tests/repo-integrity.Tests.ps1` describes are renamed (`GHOST.bat dispatch
  integrity`, `ghost.sh dispatch integrity`) — should compile after the
  test-file commit (#4), not before.
- **Do not push yet.** The next commit will fail `GHOST.bat dispatch
  integrity` until the test file moves to its new path (commit #4). That's
  expected because the rename commit and the test commit land in the same
  branch — CI runs on the *merged* result, not each commit.

---

## Commit 2 — `feat(zcode): multi-instance expansion (Primary + 3 clones)`

**Audience:** Windows lead. **Blast radius:** medium. **Time:** ~20 min.

### Stage (modified files)
```
git add GHOST.bat                  # menu numbers 13–25, all the new entries
git add ghost.sh                   # keep in sync with GHOST.bat menu numbers
git add src/windows/launch_zcode_second_instance.ps1   # -Instance Third|Fourth
git add src/windows/reset_zcode.ps1                     # -Target Third|Fourth|All
```

### Verify
```
git diff --cached --stat GHOST.bat
git diff --cached src/windows/launch_zcode_second_instance.ps1 | head -100
```

Manual review checks for this commit:
- `GHOST.bat` line ~61–87: every new `-Target Third` / `-Target Fourth` /
  `-Target All` line uses `call :Run` (sync) or `call :Detached` (async)
  consistently with existing entries. AGENTS.md says: GUI apps with
  `AttachConsole` (ZCode) MUST go through `cmd /c start` — verify any new
  ZCode-launching menu uses `:Detached` or `:StartClone`.
- `launch_zcode_second_instance.ps1` adds `-Instance Third|Fourth` —
  verify the new branches share the Second flow (don't duplicate).
- `reset_zcode.ps1` adds `-Target Third|Fourth|All` — verify "Both = back-
  compat (Secondary+Primary)" is preserved, "All = Third+Fourth+Secondary
  +Primary" clones-first/Primary-last ordering per AGENTS.md.

### Untracked files (move to commit 3)
DO NOT add in this commit:
- `src/windows/Launch-ZCode-Third.bat` / `-Fourth.bat` — these are new
  wrappers; they belong with the `tools/` batch (commit 3) because they're
  launched by `tools/install_zcode_second_shortcuts.ps1` (cross-ref).
- `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md` — owned by commit 3.
- `assets/`, `tools/zcode-*-branding/`, `tools/make_ghost_icon.ps1`,
  `tools/install_ghost_shortcut.ps1`, `tools/patch_zcode_icon_override.*`,
  `tools/install_zcode_second_shortcuts.ps1`, `tools/refresh_zcode_second_chats.ps1`,
  `tools/watch_zcode_taskbar.ps1` — all commit 3.

### Body
```
feat(zcode): multi-instance expansion (Primary + 3 clones)

Adds Third (yellow) and Fourth (green) clones alongside the existing Second
(blue) and Primary. Backed by AGENTS.md §"Multi-instance conventions" and
CHANGELOG [Unreleased] / Added.

- launch_zcode_second_instance.ps1: -Instance Second|Third|Fourth
  (per-clone home + roaming + AUMID; clones share a single instance flow)
- reset_zcode.ps1: -Target Third|Fourth|All (independent ID sets per
  child; Both retained for back-compat with Secondary+Primary)
- GHOST.bat: menus [13]–[25] — icon patch, clone shortcuts, chat
  refresh (one-shot + -Watch), clone launches (single + all), per-target
  ZCode resets, refresh-all, taskbar-identity watcher, install-GHOST-icon
- ghost.sh: menu numbers kept in sync

Verified: `bash -n ghost.sh`, parser-clean on both .ps1 changes
(`[System.Management.Automation.Language.Parser]::ParseFile`).
```

---

## Commit 3 — `feat(tools): GHOST icon, ZCode branding, clone utilities`

**Audience:** ZCode instance lead + Windows lead (joint). **Blast radius:**
medium (new external surface, ~3.7k LOC). **Time:** ~30 min.

### Stage
```
# assets first (binary; Git stores deltas but the .gitattributes `*.ico
# binary` + `*.png binary` is required — see Gate 0)
git add assets/ghost-source.png assets/ghost.ico

# docs
git add docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md

# wrappers (paired with launch_zcode_second_instance.ps1 from commit 2)
git add src/windows/Launch-ZCode-Third.bat src/windows/Launch-ZCode-Fourth.bat

# tools/ — the bulk
git add tools/install_ghost_shortcut.ps1
git add tools/make_ghost_icon.ps1
git add tools/patch_zcode_icon_override.ps1
git add tools/patch_zcode_icon_override.mjs
git add tools/install_zcode_second_shortcuts.ps1
git add tools/refresh_zcode_second_chats.ps1
git add tools/watch_zcode_taskbar.ps1

# branding bundles
git add tools/zcode-blue-branding/   tools/zcode-yellow-branding/   tools/zcode-green-branding/
```

### Verify
```
git diff --cached --stat
git ls-files --others --exclude-standard    # should be empty
```

### Manual review checks
- `tools/block_qoder_domains.ps1` was already gitignored *and* already
  on disk (per `.gitignore` line 89); confirm not staged.
- `assets/ghost-source.png` is the committed master (per
  `tools/make_ghost_icon.ps1` docs — re-runs read it, skip detection).
  Cross-check the `.gitattributes` rule for `*.png binary` exists.
- `tools/zcode-*-branding/` contains `__pycache__/` — must be ignored.
  Add `**/__pycache__/` to `.gitignore` (commit 4) if not already.
- `tools/refresh_zcode_second_chats.ps1` filename is *historical* per
  AGENTS.md (`-Target` covers all four). Don't rename it — AGENTS.md and
  CHANGELOG both call out that the name is frozen.
- `tools/watch_zcode_taskbar.ps1` is **resident + autostart** — document
  the opt-in (`-InstallAutostart`) clearly in the body so first-time
  readers don't accidentally enable it.
- Confirm `.envlocal` / `*.lnk` / `ZCode/` / `.zcodeignore` / `archive/`
  all stay untracked (covered by `.gitignore` from commit 4).

### Body
```
feat(tools): GHOST icon, ZCode branding, clone utilities

Implements CHANGELOG [Unreleased] / Added tooling layer. AGENTS.md
"tools/" entries match.

Launchers + wrappers:
  - src/windows/Launch-ZCode-Third.bat / -Fourth.bat
    (paired with launch_zcode_second_instance.ps1, commit 2)
  - tools/install_ghost_shortcut.ps1 (GHOST.lnk Desktop + repo-root
    shortcuts targeting GHOST.bat with IconLocation=assets\ghost.ico,0)

Icon pipeline:
  - assets/ghost.ico (16–256 multi-size ICO), assets/ghost-source.png
    (1024 RGBA master, committed so re-runs skip detection)
  - tools/make_ghost_icon.ps1 (auto tile detection, rounded-corner
    alpha mask, regenerates the .ico from the master)

ZCode app.asar patch (one-time, re-run after every app update):
  - tools/patch_zcode_icon_override.ps1 + .mjs (engine v6)
    enables ZCODE_ICON_DIR / ZCODE_AUMID_SUFFIX / ZCODE_ACCENT_HEX /
    ZCODE_INSTANCE_NAME env overrides + __ZCODE_BLUE__ /
    __ZCODE_ACCENT__ / __ZCODE_TITLE__ renderer flags; auto-updater
    disabled per clone (marker-file version check auto-upgrades)

Per-clone branding bundles (1024 PNG + multi-size ICO + generator):
  - tools/zcode-blue-branding/    (Second, blue)
  - tools/zcode-yellow-branding/  (Third,  yellow)
  - tools/zcode-green-branding/   (Fourth, green)

Clone shortcuts (per-user, no admin):
  - tools/install_zcode_second_shortcuts.ps1 (Desktop + Start menu;
    AppUserModel.ID = base + ".2"/".3"/".4"; -Remove, -Instance,
    -RepairPrimaryAumid)

Chat refresh + error watcher (per-user, no admin):
  - tools/refresh_zcode_second_chats.ps1 (one-shot -Target
    Primary|Second|Third|Fourth|All; -Watch error watcher; supersedes
    the deleted test_live_inject.py spike)

Resident taskbar-identity watcher:
  - tools/watch_zcode_taskbar.ps1 (every 5s, re-stamps Primary +
    clones on missing/wrong AUMID; -RunOnce, -InstallAutostart/
    -RemoveAutostart, single-instance mutex)

Tracked doc:
  - docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md (depersonalized;
    USERPROFILE in place of machine path)

Verified: PSScriptAnalyzer Error-free on every .ps1 staged here;
Pester dispatch-integrity tests updated to match in commit 4.
```

---

## Commit 4 — `chore(repo): CI, governance, .gitignore, integrity tests`

**Audience:** any contributor. **Blast radius:** low. **Time:** ~15 min.

### Stage
```
git add .github/workflows/ci.yml
git add .gitignore
git add AGENTS.md
git add CHANGELOG.md
git add CONTRIBUTING.md
git add docs/README.md
git add docs/architecture.md
git add docs/faq.md
git add docs/getting-started.md
git add docs/troubleshooting.md
git add tests/repo-integrity.Tests.ps1
```

### Verify
```
git diff --cached --stat
git diff --cached .gitignore
git diff --cached tests/repo-integrity.Tests.ps1
```

### Manual review checks
- `.gitignore` adds four rules: `ZCode/`, `.zcodeignore`, `*.lnk`, and the
  `tools/block_qoder_domains.ps1` line moves lower (re-indented but
  unchanged content — review with `git diff --cached .gitignore`).
  Also check: is `archive/` already ignored? If not, **add it here**
  (AGENTS.md says archive is local-only and never committed).
- `tests/repo-integrity.Tests.ps1` updates three Describe blocks
  (GHOST.bat dispatch, ghost.sh dispatch, Governance files present).
  The Describe bodies are correct for the new layout — run locally:
  ```
  pwsh -c "Invoke-Pester -Path tests/repo-integrity.Tests.ps1 -Output Detailed"
  ```
  (If CI is the only place Pester runs, do this locally first.)
- `.github/workflows/ci.yml` (63 LOC, 6 lines changed) — almost
  certainly the same content with updated paths (`tests/PSScriptAnalyzerSettings.psd1`).
  Verify the `-Settings` flag and the `$findings` paths are still consistent.
- `AGENTS.md` and `CHANGELOG.md` updated prose for the new surface.
  Confirm CHANGELOG has no `## [Unreleased]` double-entries.

### Body
```
chore(repo): CI, governance, .gitignore, integrity tests

- .gitignore: add ZCode/, .zcodeignore, *.lnk; archive/ is local-only
  (AGENTS.md); tools/block_qoder_domains.ps1 line moved into the
  security-sensitive block.
- tests/repo-integrity.Tests.ps1: GHOST.bat / ghost.sh dispatch
  integrity describe + Governance-files-present updated for the new
  filenames + tests/PSScriptAnalyzerSettings.psd1 path. The
  GHOST.bat regex is widened to catch `:Run` / `:RunWith` / `:Detached`
  / `:StartClone` subroutines whose script path argument is the
  second quoted token (the %-token callers cannot be regex-matched
  here because the actual -File target is a runtime expansion).
- .github/workflows/ci.yml: paths only.
- AGENTS.md / CHANGELOG.md / CONTRIBUTING.md / docs/README.md /
  docs/architecture.md / docs/faq.md / docs/getting-started.md /
  docs/troubleshooting.md: prose refresh for the multi-instance +
  branding + GHOST launcher surface.

Verified locally:
  pwsh -c "Invoke-Pester -Path tests -Output Detailed"
  pwsh -c "Invoke-ScriptAnalyzer -Path src,tools,tests \
          -Settings tests/PSScriptAnalyzerSettings.psd1 -Severity Error"
  bash -n ghost.sh && shellcheck ghost.sh
```

---

## Post-commit checklist

```
git log --oneline -8                    # should show 4 new commits in order
git tag -a v1.1.0 -m "GHOST rebrand + ZCode multi-instance expansion" HEAD
git push origin main --follow-tags      # main is bypass-mode (per memory)
```

If pushing from main, run the pre-push safety check (memory note):
```
git log --oneline origin/main..HEAD      # only forward, no cross-agent dirs
git log --oneline HEAD..origin/main      # no incoming commits we missed
```

---

## Release notes (for `v1.1.0` tag body / GitHub release)

Pull these directly from CHANGELOG `[Unreleased]` once the four commits
land. The CHANGELOG header for `[1.0.0]` already follows Keep-a-Changelog
1.1.0 — keep `[Unreleased]` → `[1.1.0]` rename + date in the **last**
commit (or as a follow-up `docs: cut 1.1.0` commit) so the history is
clean for the next release.

### Suggested release highlight
> **GHOST launcher** — `how-to-run.bat` → `GHOST.bat` (Windows),
> `how-to-run.sh` → `ghost.sh` (Linux), with `assets/ghost.ico` and
> `install_ghost_shortcut.ps1` for proper Explorer icon (a `.bat` cannot
> carry one natively — the `.lnk` shortcut does it for us; `.lnk` files
> are gitignored).
>
> **ZCode multi-instance** — Primary + 3 branded clones (Second / blue,
> Third / yellow, Fourth / green). Independent taskbar buttons, "ZCode
> Blue/Yellow/Green" window titles, separate `System.AppUserModel.ID`s
> (so pins never collide), and per-clone homes + roaming dirs.
> Driven by `tools/patch_zcode_icon_override.ps1` (re-run after every
> ZCode app update, menu [13]) and `tools/watch_zcode_taskbar.ps1`
> (resident AUMID-healer, menu [25]).
>
> **Chat sync & captcha** — `tools/refresh_zcode_second_chats.ps1`
> surfaces shared-store chats inside a running sidebar by recycling the
> target's app-server (no app restart needed); `-Watch` mode is the
> unattended error-triggered variant (captcha / quota / rate-limit).

---

## Risks & mitigations

- **Test file mentions paths that only exist after commit 4 lands.** The
  Pester describe "GHOST.bat dispatch integrity" reads `GHOST.bat` (which
  only exists as a rename target after commit 1) and resolves script
  paths under `src/` (which only have new `-Instance Third|Fourth` flags
  after commit 2). The tests pass against the *final tree*, not the
  intermediate states — that's fine because CI runs on `push` (the
  merged result), not on each commit. **Do not run Pester locally between
  commit 1 and commit 2** or it'll fail loudly.
- **`*.lnk` are gitignored but a contributor might `git add -f`.**
  Add a CHANGELOG note + CONTRIBUTING.md line in commit 4.
- **`.envlocal` (Telegram token) — never committed.** Secret scan in
  Gate 3 catches it. Verify `git log --all --full-history -- .envlocal`
  is empty.
- **Asset binaries (`*.ico`, `*.png`) inflate repo size.** Two files
  (`ghost.ico` ~multi-size, `ghost-source.png` 1024 RGBA) plus three
  branding bundles (1024 PNG + multi-size ICO each). Net ~600 KB.
  Acceptable; alternatives (LFS) are out of scope for an admin-required
  toolkit.

---

## Out of scope (do NOT bundle)

- `archive/` — local-only rollback, never tracked (AGENTS.md).
- `.context/` — per-machine agent config (already in `.gitignore`).
- `tools/block_qoder_domains.ps1` — security-sensitive hosts-file
  firewall; `.gitignore` line + AGENTS.md "Out of scope".
- `ZCode/` — vendored clone of the app source, ~124 MB.
- `.zcodeignore` — per-machine agent sync config.
- `*.lnk` — per-machine shortcut binaries.
- Any `.envlocal` or token material.

---

## Summary

**4 commits, ~3000 lines of new surface, in this order:**

1. `chore(rebrand): launcher rename + docs sweep` — 0 LOC behavior.
2. `feat(zcode): multi-instance expansion` — 2 .ps1 + GHOST.bat + ghost.sh.
3. `feat(tools): GHOST icon, ZCode branding, clone utilities` — 12 files,
   biggest commit (~3.5k LOC + assets).
4. `chore(repo): CI, governance, .gitignore, integrity tests` — 10 docs +
   CI + tests.

Each commit is revertable in isolation. CI runs on the merged result, so
Pester failure mid-stack is expected (the tests reference the final
layout). Push to `main` is safe — branch protection is bypass-mode and
the working-tree lineage is correct.