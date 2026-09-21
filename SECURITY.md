# Security Policy

## Scope and intended use

GHOST rotates device identifiers (machine IDs, telemetry GUIDs, Electron/Chromium
stores, registry machine-GUID values) for **AI coding tools installed on machines
you own or are explicitly authorized to administer** — privacy hygiene,
multi-account development testing, and dev-environment resets.

- This toolkit may violate the Terms of Service of the covered vendors. Using it
  against services you do not have the right to reset is **your responsibility**.
- There is **no guarantee** of any particular outcome (including avoiding vendor
  account enforcement). The scripts change local identifiers only; they do not
  interact with vendor services.
- Do not use GHOST on machines you do not own, on shared/managed endpoints without
  authorization, or to impersonate other users or devices.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** (Security tab →
"Report a vulnerability") on this repository. Do **not** open a public issue for
security reports.

Please include: affected script, OS/PowerShell version, and a minimal description
of the issue. Redact all identifiers (see below) before sending anything.

## MANDATORY: redact before you share anything

GHOST's output is full of device-identifying material. Before attaching logs,
audit files, or screenshots to any issue, PR, or security report:

- **Never** paste `audit_*.json` contents, `storage.json` / `state.vscdb` values,
  `machineid` file contents, `telemetry.*` values, or `os_crypt` / auth keys.
- **Never** paste `.envlocal` contents — it holds your `TELEGRAM_BOT_TOKEN`.
  A leaked bot token lets anyone control your Telegram alerts; rotate it via
  @BotFather immediately if exposed.
- Replace every GUID/hex value with `REDACTED` — the *shape* of the output is
  enough to debug; the values themselves are the sensitive part.

## Supported versions

Only the current `main` branch is supported. Superseded script versions in
`archive/` are local-only fallbacks and receive no fixes.
