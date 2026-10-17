# App cloning intake template — fill this BEFORE cloning a new app

Date: 2026-10-15. Companion of [APP_CLONING_PLAYBOOK.md](APP_CLONING_PLAYBOOK.md)
(§3 defines which fields are Developer-supplied vs defaulted). Copy this
file per clone request and fill it — or let the agent fill it from the
documented defaults and report every default (playbook §8.3).

---

## App

- App name / slug: `______` (slug = lowercase, no spaces — e.g. `zcode`,
  `autoclaw`; used in every generated filename)
- Exe path (blank = agent auto-detects from the installed app): `______`
- Installed version: `______`
- Electron app / asar patchable: `yes / no / unknown — agent verifies in
  Phase 1`

## Instances

- Instance count (incl. Primary): `4` (default)
- Roles + names: `Primary` + `______`, `______`, `______`
  (defaults: ZCode-style `Second`/`Third`/`Fourth`, or AutoClaw-style
  `inst1`..`inst4`; names are FROZEN once the first clone launches —
  renaming dirs later orphans installed profiles)

## Colors (Developer-specified; defaults offered otherwise)

| Role | Accent hex | Notes |
|---|---|---|
| Primary | — stock, never recolored | |
| `<role1>` | `#______` | default offered: `#066BCB` (blue) |
| `<role2>` | `#______` | default offered: `#D4AA10` (yellow) |
| `<role3>` | `#______` | default offered: `#13826A` (green) |

## Icons (Developer-supplied files, or the policy below)

Icon policy (playbook §5; default = improvise + report, decided
2026-10-15):

- [ ] **improvise + report** — the agent derives tinted variants from the
      app's stock icon, wires them, and flags every generated file as
      PLACEHOLDER with its path for later replacement
- [ ] **stock-default + report** — every clone keeps the stock app icon;
      the agent reports the exact drop paths + expected formats and waits

Per-role icon files (fill only when supplying icons):

| Role | Window icon (png/ico path) | Tray icon (ico path) |
|---|---|---|
| `<role1>` | `______` | `______` |
| `<role2>` | `______` | `______` |
| `<role3>` | `______` | `______` |

Asset convention when supplied: `tools/<appslug>-<role>-branding/`
(reference layout: `icon_windows.png` + `tray_icon.ico`).

## Credentials

- One credential = one instance enforced: `yes` (default)
- Seed keeps `userInfo` only; strips tokens/refreshTokens/keypairs/paired
  devices: `yes` (default)
- App-specific stores to preserve or exclude beyond the default sweep:
  `______`

## Ports

- Preferred base port(s) (blank = the agent picks, spaced beyond the
  discovered drift window): `______`

## Tooling

- Taskbar identity: `full (window stamp + watcher) / shortcut-only
  (degraded) / none` — default: full attempt, degrade + report
- Watchers: taskbar `yes/no` (default yes for full suites); captcha-style
  stall watchdog `yes/no` (default no)
- GHOST.bat: `new submenu / extend an existing one` (default: agent
  decides, reported)

## Provenance line (filled by the agent after Phase 1)

- Per-app spec doc: `docs/<APP>_CLONES_SPEC.md` — every ground-truth claim
  cites the installed app's files/probes; no guesses.
