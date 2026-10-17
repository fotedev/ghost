# App cloning playbook — the generic "clone any app into isolated instances" process

Date: 2026-10-15. Status: **ACTIVE** — the standing process for every future
clone request. Distilled from the two proven suites: **ZCode** (Primary +
Second/Third/Fourth — the gold standard: full identity incl. per-clone
taskbar buttons, tray icons and accent colors via the asar patch engine) and
**AutoClaw** (Primary + inst1..inst4 — v1: full profile/credential/port
isolation with a documented shared-taskbar-button limitation). Companions:
[APP_CLONING_EDGE_CASES.md](APP_CLONING_EDGE_CASES.md) (the normative EC-xx
catalog — its handling rules apply to every suite) and
[APP_CLONING_INTAKE_TEMPLATE.md](APP_CLONING_INTAKE_TEMPLATE.md) (the
per-request inputs).

How to use: fill the intake form → follow the phases (§6) → consult the
edge-case catalog at every phase → deliver the fixed report (§8).

---

## 1. Purpose and scope

"Cloning an app" = turning one installed app into **N independent
instances** (a Primary plus N−1 clones), each with:

- its **own profile** — user-data/state dirs, env-isolated;
- its **own machine identity** — telemetry IDs and device credentials,
  never a copied identity (a verbatim profile copy is exactly the failure
  class GHOST exists to eliminate);
- its **own visual identity** — window title, accent color, window/tray
  icon, taskbar button;
- its **own tooling** — launcher, reset script, shortcuts, menu entries.

Scope: Windows PowerShell (the repo's primary platform), desktop
Electron-style apps first. Every app-specific fact MUST be verified against
the **installed** app on this host — never inferred from upstream source,
docs, or hope (the `AUTOCLAW_CLONES_SPEC.md` §5/§13 pattern: quoted
decompiled code + live probes + provenance). Applies to any future app.

## 2. The identity suite (required features per clone)

| # | Feature | Class | Achieved via (reference suites) |
|---|---|---|---|
| 1 | Profile isolation (`home` / `profile` / `tmp` per clone) | MANDATORY | env levers (`USERPROFILE`/`HOME`/`TEMP`/`TMP`/`TMPDIR`, `ZCODE_DATA_BASE_DIR`-style); `--user-data-dir` only as a second layer when the app honours it |
| 2 | Telemetry + device-identity rotation | MANDATORY | per-target ID sets in the reset script (`New-IdentitySet`); All-mode = clones first, Primary last; never duplicate an ID set |
| 3 | Credential isolation (no shared tokens/keys/paired devices) | MANDATORY | seed EXCLUDES credential stores; strips tokens keeping `userInfo`; verify-after-launch own-key check |
| 4 | Own launcher script + double-click shortcuts | MANDATORY | `launch_<app>_clone.ps1 -Instance <role>`; .lnk targets the launcher (a .lnk cannot set env vars) |
| 5 | Own reset script (`-Target` per instance) | MANDATORY | backup → mutate → verify-after → audit → restore script; independent IDs per target |
| 6 | Distinct window title ("App `<Color>`") | DEGRADABLE | patch hook (`ZCODE_INSTANCE_NAME` pattern) — strongly recommended: prevents the .lnk pin-collision class (EC-C01) |
| 7 | Distinct taskbar button (AUMID + icon) | DEGRADABLE | full: window-level `System.AppUserModel.ID` stamp + kick + resident watcher (ZCode); degraded: shortcut AUMIDs only, running windows share one button (AutoClaw v1) |
| 8 | Distinct tray icon | DEGRADABLE | patch hook reading an icon-dir env (`ZCODE_ICON_DIR` pattern) |
| 9 | Distinct window icon | DEGRADABLE | same hook as [8] |
| 10 | Per-clone accent color | DEGRADABLE | patch hook (`ZCODE_ACCENT_HEX` → renderer flags); needs in-app recolor points |

**Degradation rule — never silently degrade.** A DEGRADABLE feature ships at
the highest rung the app actually supports; the final report (§8) marks
every instance full / degraded / absent with the reason and the EC id. A
MANDATORY feature that is absent means the clone is NOT done.

Degradation ladders:

- Taskbar [7]: window stamp + watcher → shortcut-AUMID-only pins (running
  windows merge — AutoClaw §5.8) → none.
- Tray/window icon [8][9]: per-clone icon-dir hook → stock icon for all
  clones (identity still distinct via title/accent) → report absent.
- Accent [10]: in-app recolor → accent dropped, everything else kept.
- Title [6]: in-app title hook → stock title (report degraded + the
  pin-collision risk).

## 3. Developer inputs contract (the ONLY developer touchpoints)

Everything else is the agent's job (§4). The Developer supplies, via
[APP_CLONING_INTAKE_TEMPLATE.md](APP_CLONING_INTAKE_TEMPLATE.md):

1. App name/slug, instance count, role names.
2. **Colors** — one accent hex per clone, Developer-specified (defaults
   offered: the ZCode palette — Second blue `#066BCB`, Third yellow
   `#D4AA10`, Fourth green `#13826A`). The Primary is never recolored.
3. **Icons** — developer-supplied files per clone (paths), or the §5
   policy applies.
4. Credential policy (default: one credential = one instance; the seed
   keeps `userInfo` only).
5. Optional port base (otherwise the agent picks one with drift spacing).
6. Watcher scope (default: taskbar watcher for full suites).

Runtime touchpoints that cannot be automated:

- **One manual login per clone** on first launch — never automated, never
  cloned, never batched (ZCode Telegram 409 + AutoClaw `paired.json`
  lessons, EC-D03).
- **Close the Primary during the FIRST seed** — the launcher waits up to
  180s then aborts (a live Chromium profile cannot be robocopied, EC-E01).
- **UAC click** for self-elevating reset scripts.
- **Final icons** if the agent generated placeholders (§5) — drop files at
  the reported paths, re-run the branding/shortcuts menu entries.

If the intake form arrives empty, the agent fills it from the documented
defaults and **reports every default chosen** (§8.3).

## 4. Automation contract

The agent does WITHOUT asking (no per-step approval):

- Phase 1 discovery + the per-app spec doc (`docs/<APP>_CLONES_SPEC.md`).
- All scripts: reset / launcher / shortcuts / patch engine / watcher.
- Branding generation per §5 — including placeholder generation.
- GHOST.bat menu integration (new submenu or extension + resolver + gids).
- Tests: parser parse-check on every `.ps1`, Pester suites green, PS 5.1
  rules.
- Docs: AGENTS.md section, CHANGELOG entry, docs/README.md index row.
- The final report (§8).

The agent must NOT:

- auto-commit (Working preferences — leave everything uncommitted);
- modify `identity_utils.ps1`, `change_device_id.ps1`, `.context/`,
  `archive/`, `.git/` (Out of scope);
- contradict AGENTS.md "Verified ground truth";
- invent app facts — every constraint is verified from the installed app;
- leave a silent-success path (never silent-success is mandatory).

## 5. Icon & branding policy (Developer decision 2026-10-15)

Asset convention: `tools/<appslug>-<role>-branding/` holding the icon files
the app consumes. Reference: `tools/zcode-blue-branding/` =
`icon_windows.png` + `tray_icon.ico` (+ the shared generator). The launcher
copies branding into the clone home so the instance stays self-contained if
the repo moves, and sets the icon env var **only when the files exist** (a
set-but-absent path yields a broken icon — EC-B02).

Decision tree when wiring clone icons:

1. **Developer-supplied icons exist** → wire them (window + tray + shortcut
   `IconLocation`), verify-after, report "developer icons used at `<paths>`".
2. **Icons missing → DEFAULT branch: improvise + report.** Derive tinted
   variants from the app's stock icon via the generator pipeline (reference:
   `generate_branding.py --mask <hue> --out-dir` — emits `icon_windows.png`
   + multi-size `tray_icon.ico` + the measured accent hex for the env var),
   wire them, and flag every generated file as PLACEHOLDER in the report:
   what was created, where, and that the Developer replaces them by dropping
   real files at the same paths + re-running the branding and shortcuts
   menu entries.
3. **Generation infeasible** (no extractable stock icon, no pipeline) →
   fall back to the stock app icon for every clone (identity stays distinct
   via title/accent where hooks exist) and report the exact drop paths +
   expected formats so the Developer can supply icons for a re-wire.
4. **Replacement later is idempotent**: drop icons → re-run branding +
   shortcuts installer. NEVER a re-clone, never a re-seed.

Never: fail the clone over icons; silently guess; leave a broken
`IconLocation` or a set-but-absent icon env path.

## 6. Phases 0–10 (checklists)

### Phase 0 — Intake

- [ ] Fill/complete the intake form (developer values or documented defaults).
- [ ] Record every default chosen for the report (§8.3).

### Phase 1 — Discovery (read the INSTALLED app, never guess)

- [ ] Install dir + exe path; app version; Electron version; asar patchable?
      (asar-integrity fuse / integrity.json — AutoClaw: none, patchable).
- [ ] Isolation levers: is `--user-data-dir` honoured? what follows
      `os.homedir()` / `USERPROFILE`/`HOME`? app-specific env vars?
- [ ] Single-instance lock: what keys it (profile dir? global?) → re-launch
      semantics (focus vs second copy).
- [ ] Update mechanism: built-in updater + its settings flag; does the app
      bundle `resources\node\node.exe`?
- [ ] Credential + identity store inventory: EVERY file holding
      tokens/refreshTokens/deviceIds/keypairs/paired devices/updater IDs —
      with what each holds (AutoClaw example: `auth.json.deviceId`,
      `identity\device.json` ed25519, `devices\paired.json` admin token,
      `token-cache.json`, `.updaterId`).
- [ ] Ports: hardcoded candidate-port arrays (ceilings)? drift behavior
      (`PORT_PROBE_RANGE`-style)?
- [ ] Tray support; AUMID behavior (set unconditionally in the app?).
- [ ] Output: `docs/<APP>_CLONES_SPEC.md` with §5-style verified ground
      truth (quoted code / live probes), §9-style risks, §10-style
      decisions, §13-style provenance. No "probably" — every claim cites
      evidence.

### Phase 2 — Isolation design

- [ ] FROZEN layout under
      `%USERPROFILE%\<App>CloneHome\<inst>\{home,profile,tmp}` (+ per-clone
      roaming dirs if the app uses %APPDATA%). Names frozen from day one —
      renaming dirs later orphans installed profiles (ZCode Second rule).
      Primary paths recorded, never written by clone scripts.
- [ ] Env levers FIRST; CLI flags only as a second layer (ZCode overwrites
      `--user-data-dir` via `app.setPath` — EC-D02).
- [ ] Port plan table: per-instance preferred ports spaced beyond the drift
      window (AutoClaw: spacing 11 for a +9 drift), widened by patch if the
      app hardcodes a candidate array.

### Phase 3 — Reset script (`src/windows/reset_<app>.ps1`)

- [ ] Mirror the repo pattern: dot-source `identity_utils.ps1` →
      `Assert-Administrator` → per-target steps → audit → restore script →
      summary (exit 1 on any failure). `#Requires -Version 5.1` in the
      first 3 lines.
- [ ] `-Target Primary|<roles>|All` (+ `-DryRun`); All = clones first,
      Primary last; **independent ID sets per target — never duplicate**.
- [ ] Every step: backup → mutate → no-BOM write → verify-after re-read →
      audit entry. Credential stores: backup → delete → verify-absent.
- [ ] Generated keys verified by shape (ed25519 PEM lengths via node:crypto;
      node = functional probe → app-bundled fallback).
- [ ] Selective kill per target subtree (process markers); abort with a
      diagnostic dump when classification is ambiguous.
- [ ] Result channel file for the non-elevated parent; self-elevation
      forwards the target args.

### Phase 4 — Launcher (`src/windows/launch_<app>_clone.ps1`)

- [ ] `-Instance <role>` + `-Status`; already-running clone → report +
      exit 0 (single-instance focus).
- [ ] First-run seed: gated on a completion marker ONLY (never on a profile
      file — EC-E02); Primary-closed wait ≤180s then abort; robocopy with
      credential/cache/lock exclusions; post-copy re-checks; seed-scrub
      with verify-after (identity rotation, token strip keeping `userInfo`,
      `autoUpdate=false`); marker written ONLY after full verify; a partial
      profile is cleared + re-seeded.
- [ ] Launch: detached (`cmd /c start`), sequential, never elevated;
      per-instance env block.
- [ ] Port discovery: scan expected range + drift window against the
      clone's own subtree; health-check DISCOVERED ports (never the
      requested); write `instance-record.json` (requested vs actual) +
      re-read verify.
- [ ] Verify-after-launch: subtree appears ≤30s and is stable 5s; gateway /
      health pass; own-credentials-only check (foreign key = FAILED);
      Primary config hash unchanged (change = FAILED isolation breach).
      Missing MCP port = WARN (patch likely reverted — EC-A01/EC-F02).

### Phase 5 — Branding (per §5 policy)

- [ ] Generate/obtain per-clone icons + accent + title; wire via the patch
      hooks; copy branding into the clone home.
- [ ] Icon env var set only when files exist; shortcut `IconLocation`
      `"<icon>,0"` quoted + verify-after re-read.

### Phase 6 — App patch (`tools/patch_<app>_<concern>.ps1` + `.mjs` engine)

- [ ] Text-transform engine + ps1 wrapper: backup → `npx @electron/asar`
      extract → transform (idempotence anchors; zero patch sites = exit 1
      with the tree untouched) → `node --check` every patched
      .js/.cjs/.mjs → repack → verify markers inside the packed candidate
      (`extract-file`) → swap with size floor + `.old` rollback → marker
      json `{patchVersion, backupDir, patchedFiles}`.
- [ ] `-Restore` = staged copy of the newest backup (the backup itself
      stays intact), marker removed; the ORIGINAL first-run backup is
      reused so a restore never returns to an intermediate patched state.
- [ ] Updater guard: `system.autoUpdate=false` on every clone (reset +
      seed-scrub) + an asar-level disable for clones where a hook exists —
      an in-app `quitAndInstall` wipes the shared patch (EC-A02).
- [ ] App closed (check scoped to that install dir); re-apply after any
      app update (the marker `patchVersion` gate makes the menu entry
      auto-upgrade an old marker).

### Phase 7 — Shortcuts (`tools/install_<app>_clone_shortcuts.ps1`)

- [ ] Per-user Desktop + Start Menu .lnk per clone; params `-Instance`,
      `-Remove`, `-DesktopOnly`, `-StartMenuOnly`, `-SkipAumid`,
      `-RepairPrimaryAumid`.
- [ ] .lnk target = the launcher with `-Instance` (a .lnk cannot set env
      vars).
- [ ] AUMID = `<base>.<suffix>` written via IPropertyStore (PROPERTYKEY
      `9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3` pid 5); base read from the
      Primary .lnk when present; **read AUMIDs ONLY via `Shell.Application`
      `ExtendedProperty('System.AppUserModel.ID')`** (EC-C09).
- [ ] Self-heal the Primary base BEFORE writing clone AUMIDs (a poisoned
      base stacks suffixes — EC-I03). Every lnk field write re-read +
      compared.

### Phase 8 — Taskbar identity

- [ ] Full (ZCode reference): launcher window-level
      `System.AppUserModel.ID` stamping — resolve by title (survives the
      splash swap), re-stamp on hwnd change, independent final verify,
      then KICK (brief `<aumid>.kick` → final; a stale group keeps the
      wrong icon — EC-C02); resident watcher every 5s (process-marker
      classification first — EC-C05; named mutex + startup process-scan
      single-copy; ~5m hijack self-heal; autostart lnk; self-titled
      console; log at `%LOCALAPPDATA%\watch-<app>-taskbar\` with rotation).
- [ ] Degraded (AutoClaw v1): shortcut-AUMID-only + the shared-button
      limitation documented in the spec + report + v2 candidates listed
      (asar AUMID-suffix env hook, or extracting the ZCode window-stamp
      helper).
- [ ] Never elevated; the launcher must run at the same or higher
      integrity level than the clone (UIPI — EC-C08).

### Phase 9 — GHOST.bat menu integration

- [ ] New submenu (or extend the app's existing one) with section dividers
      — Launch Clones / Reset Clones / Maintenance — via `:Div` + `:Opt`.
- [ ] Per-submenu resolver `:<App>One` (local ids → gids) + new
      `:DispatchOne` cases (next free gid block).
- [ ] Landmines: no bare `(` `)` in echo inside parenthesized blocks; escape
      `^&` `^|`; GUI `AttachConsole` apps + long-running watchers via
      `:Detached`; launch-ALL entries stagger with `timeout /t 3`.
- [ ] repo-integrity: every `-File "...ps1"` referenced from GHOST.bat must
      exist on disk.

### Phase 10 — Tests, docs, governance

- [ ] `[System.Management.Automation.Language.Parser]::ParseFile` zero
      errors on every `.ps1`; `#Requires -Version 5.1` in the first 3
      lines; Pester green (repo-integrity + any new tests); PS 5.1 rules
      (no ternary, no `$Input`, `RandomNumberGenerator.Create().GetBytes()`).
- [ ] repo-integrity constraints: no `scripts/` + windows/linux path
      strings in any tracked text file; every new `src/windows/*.ps1`
      literally listed in README.md.
- [ ] AGENTS.md: Architecture entry for the new scripts + a Multi-instance
      conventions section (mirror ZCode/AutoClaw) — verified ground truth
      only, dated.
- [ ] CHANGELOG `[Unreleased]` Added entry; docs/README.md index row; the
      per-app spec linked from it.
- [ ] Leave everything UNCOMMITTED for Developer review.

## 7. File inventory (what a completed clone suite creates)

```
docs/<APP>_CLONES_SPEC.md                       # Phase 1 output (ground truth + provenance)
src/windows/reset_<app>.ps1                     # Phase 3
src/windows/launch_<app>_clone.ps1              # Phase 4 (+ -Status)
src/windows/Launch-<App>-Clone.bat              # optional double-click wrapper
tools/patch_<app>_<concern>.ps1 + .mjs          # Phase 6 (only if asar surgery is needed)
tools/install_<app>_clone_shortcuts.ps1         # Phase 7 (+ -RepairPrimaryAumid)
tools/watch_<app>_taskbar.ps1                   # Phase 8 full (else omitted; degraded reported)
tools/<appslug>-<role>-branding/                # Phase 5 assets + generator
GHOST.bat                                       # Phase 9 submenu + resolver + gids
AGENTS.md / CHANGELOG.md / docs/README.md       # Phase 10 governance rows
```

Runtime artifacts (created by the scripts, never committed): clone homes
under `%USERPROFILE%\<App>CloneHome\`, per-clone `instance-record.json`,
patch markers under the app's `resources\`, `ID_Backups\<ts>` per target,
watcher logs under `%LOCALAPPDATA%\watch-<app>-taskbar\`.

## 8. Final report format (mandatory, fixed sections)

1. **Feature matrix** — per instance, every §2 feature: full / degraded /
   absent + a one-line reason (degradations cite the EC id).
2. **Built** — files created/modified, menu entries added, patch version
   applied, marker paths.
3. **Autonomous decisions** — intake defaults used, the §5 icon branch
   taken and what was generated where, the port plan, naming, everything
   the Developer did not specify.
4. **Developer touchpoints pending** — one login per clone, the
   close-Primary window for the first seed, placeholder icons to replace
   (exact paths), elevation-required steps.
5. **Verification evidence** — parse results, Pester, live verify-after
   outputs (what was actually re-read and compared).
6. **Known limitations + v2 candidates.**

## 9. Provenance

This playbook distills verified work, not theory:

- **ZCode suite** (2026-09-23 → 09-28): env-only isolation (the CLI `~`
  lesson), asar patch engine v7 (icon/tray/accent/title/AUMID-suffix env
  hooks), window-level stamping + kick + resident watcher, Primary .lnk
  hijack repair, splash-phase misclassification fix, renderer-OOM
  commit-limit diagnosis, Telegram 409 routing rule. Ground truth:
  AGENTS.md "Multi-instance conventions (ZCode: Primary + 3 clones)".
- **AutoClaw suite** (2026-10-08 → 10-15): the installed-app discovery
  method (quoted decompiled code + live probes), credential-free seed +
  marker guards, port-array widening + drift discovery,
  `instance-record.json`, the Primary-hash isolation-breach check. Ground
  truth: [AUTOCLAW_CLONES_SPEC.md](AUTOCLAW_CLONES_SPEC.md) §5/§13.
- Edge-case handling rules:
  [APP_CLONING_EDGE_CASES.md](APP_CLONING_EDGE_CASES.md).
