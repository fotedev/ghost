# Changelog

All notable changes to GHOST are documented here. Versions are Git tags
(`vX.Y.Z`); script filenames are unversioned.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-09-21

First tagged release; the repository restructured to standard open-source
conventions. No reset-script behavior changes in this release except where
noted.

### Changed

- **Repository layout**: `scripts/` → `src/`; docs consolidated; community
  files, tests, and CI added.
- **Filenames are unversioned** — versioning now lives in Git tags and this
  changelog. Old mapping:

  | Old name | New name |
  |---|---|
  | `scripts/windows/reset_cursor_windows-v0.2.ps1` | `src/windows/reset_cursor.ps1` |
  | `scripts/windows/reset_devin_windows-v0.3.ps1` | `src/windows/reset_devin.ps1` |
  | `scripts/windows/reset_trae_windows-v0.2.ps1` | `src/windows/reset_trae.ps1` |
  | `scripts/windows/reset_qoder_windows-v0.4.ps1` | `src/windows/reset_qoder.ps1` |
  | `scripts/windows/reset_qoderwork_windows-v0.1.ps1` | `src/windows/reset_qoderwork.ps1` |
  | `scripts/windows/reset_zcode_windows-v1.4.ps1` | `src/windows/reset_zcode.ps1` |
  | `scripts/windows/reset_minimax_opencode_windows-v1.2.ps1` | `src/windows/reset_minimax_opencode.ps1` |
  | `scripts/linux/reset_cursor_linux.sh` | `src/linux/reset_cursor.sh` |
  | `scripts/linux/reset_windsurf_linux.sh` | `src/linux/reset_windsurf.sh` |
  | `scripts/linux/change_device_id_linux.sh` | `src/linux/change_device_id.sh` |
  | `docs/AGENTS.md` | `AGENTS.md` (repo root) |

- Superseded versions (`archive/`, legacy `*-v0.1` fallbacks) are **no longer
  tracked** — they remain on disk as local-only rollback copies and are purged
  from Git history.
- `docs/AGENTS.md` moved to the repository root as `AGENTS.md` (single source;
  the contributor-facing conventions now live in `CONTRIBUTING.md`).

### Added

- Apache-2.0 `LICENSE`, `NOTICE`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`.
- Pester 5 test suite (`tests/`) and GitHub Actions CI
  (PSScriptAnalyzer + Pester on Windows; ShellCheck + `bash -n` on Linux).
- GitHub issue forms and PR template.
- `.env.example` for the optional Telegram alert credentials.

### Security

- Git history purged of `archive/` paths (contains old-fingerprint material).
- `.envlocal` (Telegram bot token) confirmed never committed; see
  `SECURITY.md` for the redaction rules that apply to all issues and PRs.

### Fixed

- `reset_devin.ps1` (formerly `reset_windsurf_windows-v0.3.ps1`): handles the
  June 2026 Windsurf → Devin Desktop rebrand — auto-detects and resets both
  `%APPDATA%\Devin` and `%APPDATA%\Windsurf` roots in one pass; scrubs
  `credentials.toml`, `config.json devin.org_id`, `cli\installation_id`,
  `.devin\argv.json`, and rebrand-era state.vscdb secret keys.
