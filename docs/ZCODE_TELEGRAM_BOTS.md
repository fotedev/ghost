# ZCode per-clone Telegram bots (UI-assisted model)

Date: 2026-10-16. Status: ACTIVE.

## 1. Why UI-assisted

`bot-config.json` / `bot-config.v3.json` hold only `{ id, credentialRef }`.
The secret lives encrypted as `credentials.json -> "bot:<id>:credential" =
"enc:v1:..."`. This repo has no `enc:v1:` cipher, so no script writes raw
BotFather tokens. The operator pastes each token ONCE in that clone's ZCode
UI; the app mints a fresh `bot-<guid>`, encrypts to `enc:v1:`, updates
`bot-config.v3.json`. Tooling below acts as guardian/synchronizer.

## 2. Rules (EC-D03: one credential = one instance)

- One token = one poller. Two pollers on one token = HTTP 409 + random
  cross-account billing.
- Every check covers BOTH `bot-config.json` AND `bot-config.v3.json`
  (the 2026-10-16 Fourth `v2=False / v3=True` split looked disabled while
  polling).
- Fingerprint = `sha8(credentials.json bot:<id>:credential)` + bot `id`.
  Values are never printed or logged, hashes only.
- Primary owns `Zane` (`enabled=true` in both files). A clone with a
  duplicate sha8/id must be `enabled=false` in both files. A clone with a
  UNIQUE sha8+id may stay `enabled=true` in both files.

## 3. Tooling

- `tools/set_zcode_bot.ps1 -VerifyOnly` — read-only audit across all 6
  homes, exit 1 on v2/v3 mismatch or duplicate-while-enabled.
- `tools/set_zcode_bot.ps1 -Target <name> -Fix` — backup-first
  (`ID_Backups\telegram_guardian_<ts>` + audit + restore script via
  `identity_utils.ps1`), syncs v2/v3, disables duplicates, writes the
  `.telegram-routed` v2 marker (`v2 unique-bot sha8=... id=...`) for unique
  clone bots, verify-after re-read.
- `src/windows/launch_zcode_second_instance.ps1 [2c]` — v2 logic: on a
  first launch without a marker, sha8-compare against Primary (duplicate ->
  disable both files; unique -> preserve + v2 marker). A `v2 unique-bot*`
  marker is never reverted. Legacy empty markers keep old skip behavior.
  Polling-lock cleanup runs only when a duplicate was disabled AND the
  clone is not running (a live poller owns its lock).

## 4. Bring-up (one bot per clone)

1. `@BotFather` -> 5 new bots (keep `Zane` on Primary).
2. For each clone: open that clone's ZCode window, paste its token in the
   Telegram integration UI, confirm it polls.
3. Run `tools/set_zcode_bot.ps1 -VerifyOnly` — expect OK.
4. Run `tools/set_zcode_bot.ps1 -Target <clone> -Fix` once to sync v2/v3
   and write the v2 marker.
5. Restart the clone once. Verify 6 pollers, 6 bot usernames, zero 409.

## 5. Quota note (2026-10-16 decision: Option C)

Fourth keeps its big quota isolated (`credentials.json` OAuth +
`account-provider` keys are per-home). Sharing = same ZAI account via UI
in multiple homes (same pool, drains together); surgical key copies are
rejected (refresh race + `[6b/27]` unlink loop).
