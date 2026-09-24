# ZCode Cross-Instance Chat Sync — Findings & Watcher Plan

Date: 2026-09-23. Status: **mechanism proven end-to-end; one-shot refresh
AND error-triggered watcher IMPLEMENTED** as
`tools/refresh_zcode_second_chats.ps1` (one-shot = menu [15], watcher =
`-Watch -Target All` = menu [22]). The signature-poll watcher draft in §4 is
kept for reference; the shipped watcher triggers on failure events instead
(see §4 note).

## 1. Root cause (verified live, not theory)

Both ZCode instances share **one** session store:

- CLI session DB path = `~/.zcode/cli/db/db.sqlite`, resolved via the **real** user
  profile (`packages/adapters/src/storage/session-store/paths.ts`:
  `join(homedir(), ".zcode", "cli", "db", "db.sqlite")`; config default
  `storage.sessionDbPath = "~/.zcode/cli/db/db.sqlite"`).
- The launcher sets `HOME=%USERPROFILE%\ZCodeSecondHome`, but on Windows the CLI
  runtime resolves `~`/homedir from the real profile — the override does NOT reach
  the CLI. So **Primary and Secondary both read/write
  `%USERPROFILE%\.zcode\cli\db\db.sqlite`**.
- Per-instance state is only the **sidebar index**:
  `<home>\.zcode\v2\tasks-index.sqlite` (Primary home vs `ZCodeSecondHome`).

Proofs collected 2026-09-23:

1. Probe `sess_probe_7987707d2077` seeded into the Secondary's DB copy
   (`ZCodeSecondHome\.zcode\cli\db\db.sqlite`) never surfaced in the Secondary's
   tasks-index, even after app-server kills/respawns → that DB file is dead
   storage; the app never reads it for sessions.
2. Title marker written into the Secondary's DB copy was invisible; the resumed
   session came back with the **old** title that only exists in the Primary-path
   DB → the app-server reads the shared store.
3. Probe `sess_probe_fa3d4f22826e` seeded into the **shared** store
   (`%USERPROFILE%\.zcode\cli\db\db.sqlite`) + kill of the Secondary's
   app-server(s) → row with title `WATCHER-PROBE-LIVE` appeared in the
   **Secondary's** tasks-index within seconds of the auto-respawn → full
   no-restart sync chain works.

Conclusion: **chats created in the Primary are already in the Secondary's store.
The problem is visibility, not data.** No cross-home DB copying is needed; the
earlier "copy session/message/part rows between homes" watcher design is obsolete.

## 2. Why chats don't appear live (pipeline truth)

- `zcodeTaskIndexSyncer.ts` subscribes to the app-server session index and
  mirrors it into the instance's own `tasks-index.sqlite`. It applies
  **incremental frames after a baseline** and does **no snapshot backfill** on
  app-server respawn for rows its baseline never saw.
- The app-server's publisher seeds its baseline from the session store **at
  spawn**. External changes (i.e., sessions created by the *other* instance)
  after spawn are invisible to that app-server.
- Therefore: a chat created in the Primary while the Secondary runs appears in
  the Secondary only after the Secondary's app-server is **restarted** (which
  the process manager does automatically when the process dies — verified:
  respawn within ~3 s after kill, cold-resume/draft-gate path).

## 3. Proven refresh mechanism

```
kill Secondary's workspace app-server process(es)
  -> process manager auto-respawns them (~3 s)
  -> new publisher seeds baseline from the SHARED session store
  -> syncer diff: session not in old baseline => becameVisibleTask
  -> readSession -> row upserted into Secondary tasks-index -> broadcast
  -> chat appears in the Secondary sidebar LIVE (no app restart)
```

## 4. Watcher design — `tools/watch_zcode_chat_sync.ps1` (new)

> **Shipped differently (2026-09-23):** the continuous watcher is the
> `-Watch` mode of `tools/refresh_zcode_second_chats.ps1` (menu [22],
> `-Target All`; no separate file). It does NOT poll the store signature
> below — per request it tails the agent runtime JSONL logs
> (`~/.zcode/cli/log/zcode-*.jsonl`, offset-based incremental reader) and
> triggers on **terminal failure events only**: captcha stall ("Captcha
> instance timed out" / "captcha verify failed") and quota / rate-limit
> exhaustion (terminal `turn.failed` with rate_limited / 529 / 1305 / 3009 /
> model_rate_limited cause chain or quota/insufficient wording — same
> signatures as `tools/watch_zcode_captcha.ps1`). On a fresh failure it
> refreshes chats in **every RUNNING instance** (Primary + clones;
> not-installed / not-running / no-workspace instances are skipped and
> self-seed on next launch). The multi-signal hot guard defers the recycle
> while any turn streams anywhere and the watcher retries on later polls
> (never kills mid-turn); `-CooldownSeconds` (default 300) is the
> anti-thrash, `-InitialLookbackSeconds` (default 300) also catches errors
> that happened just before the watcher started. The signature-poll draft
> below is kept for reference only.

Goal: hands-free "chats created in one instance show up in the other instance's
sidebar within a minute, without restarting the app."

### Detection (cheap poll, default every 15 s)

Signature query against the shared store
`%USERPROFILE%\.zcode\cli\db\db.sqlite` (read-only, WAL-safe):

```sql
SELECT (SELECT COALESCE(MAX(time_updated),0) FROM session)
     + (SELECT COALESCE(MAX(rowid),0)        FROM message)
     + (SELECT COALESCE(MAX(rowid),0)        FROM part);
```

Monotonic signature; any new/edited chat in EITHER instance bumps it.

### Action (on signature change, debounced)

1. Identify the **Secondary** main process: bare-exe `ZCode.exe` whose
   `MainWindowTitle` is `ZCode Blue` (the icon patch, engine v6, guarantees
   this title; Primary's is `ZCode`).
2. Enumerate its descendant processes (`zcode.cjs app-server` children) via
   parent-PID tree walk.
3. **Guards — skip recycle this cycle if any is true:**
   - any session in the shared store has `time_updated` within the last
     `-HotWindowSeconds` (default 10 s) → a turn is likely streaming; retry next
     cycle instead of interrupting;
   - last recycle was less than `-CooldownSeconds` ago (default 120 s) →
     anti-thrash;
   - `-DryRun` set → log only.
4. `Stop-Process` the Secondary's app-server PID(s). Do NOT touch the Primary.
5. **Verify-after (never silent-success):** poll the Secondary's
   `ZCodeSecondHome\.zcode\v2\tasks-index.sqlite` until the newest session id
   from the shared store appears (timeout 30 s) → log `OK` / `FAILED` with the
   session id, and append a JSON audit line to
   `tools\logs\watch_zcode_chat_sync-YYYYMMDD.log`.

### Parameters

| Param | Default | Notes |
|---|---|---|
| `-IntervalSeconds` | 15 | poll cadence |
| `-CooldownSeconds` | 120 | min time between recycles |
| `-HotWindowSeconds` | 10 | activity guard window |
| `-Target` | `Secondary` | `Secondary` only for v1 (`Both` later) |
| `-DryRun` | off | detect + log, never kill |

### Launcher integration (IMPLEMENTED)

- Menu `[15]` runs the one-shot variant `tools/refresh_zcode_second_chats.ps1`
  (detect missing chats → recycle Secondary app-server(s) → verify-after).
  The hot-activity guard does **wait-and-retry** (up to ~90 s, two
  consecutive idle passes required) instead of hard-failing when a turn is
  streaming; `-Force` bypasses. It is **multi-signal** — any one hot blocks
  the recycle: (A) shared-store commit activity < 15 s, (B) an assistant
  step row created < 120 s ago with `data.time.completed` still unset
  (created at step start, completed at step end — covers long "Thought"
  phases that produce no db commits; a `MAX(time_updated)`-only guard
  missed exactly this on 2026-09-23 and stopped a live turn), (C) a
  `tool_usage` row still `running` started < 300 s ago (covers long tool
  executions; killed-turn orphans expire via the recency window), and
  (D) CPU delta > 0.25 s over a 3 s sample on the exact app-server PID(s)
  about to be killed (SSE token streaming burns CPU with zero db writes).
  The continuous watcher is ALSO shipped: same script with `-Watch -Target
  All` (menu `[22]`, launched detached via `start` per the .bat
  console-hijack rule) — error-triggered, see the note at the top of §4.
- Not auto-started with the Secondary launcher: the app-server recycle is a
  deliberate, slightly disruptive action; user opts in per run.

## 5. Limitations / known costs

- **Not push-realtime.** Refresh granularity = poll interval + ~3 s respawn.
  True live push is impossible without patching the app (no snapshot backfill;
  baseline frozen at spawn). Recycle is the only working trigger.
- Interrupting a Secondary in-flight turn is guarded but not impossible (a turn
  that goes quiet longer than `HotWindowSeconds` mid-run can still be recycled;
  the session resumes afterward).
- If the branding patch is missing/reverted (app update), the Secondary window
  title falls back to `ZCode` and the watcher **cannot** distinguish instances →
  must abort with a loud error rather than guess (never recycle the wrong
  instance). Re-run menu `[13]` patch to restore.
- Windows-only, PowerShell 5.1-compatible (no `?.`/ternary/`$Input`,
  `Get-Command python` for sqlite access exactly like `identity_utils.ps1`).

## 6. Test plan (mirrors today's probes)

1. Start Primary + Secondary, watcher running with `-DryRun` → create chat in
   Primary → assert watcher logs detection and *would-recycle*.
2. Re-run without `-DryRun` → assert new chat title appears in Secondary's
   `tasks-index.sqlite` and sidebar within ~60 s.
3. Negative: stream a long turn in the Secondary while creating a Primary chat →
   assert no recycle happens until the turn ends.
4. `tools\watch_zcode_chat_sync.ps1` parse-checked via
   `[System.Management.Automation.Language.Parser]::ParseFile` before done.

## 7. Probe artifacts (cleaned up 2026-09-23)

- Removed `sess_probe_fa3d4f22826e` (shared store), `sess_probe_7987707d2077`
  (Secondary dead-store copy), its tasks-index row, and reverted the
  `LIVE-PROBE-20260923-1207` marker title on `sess_c5318557-...`.
- Temp scripts (kept in `%TEMP%`, not the repo): `live_reload_probe.py`,
  `check_probe_row.py`, `cleanup_probe.py`.
- Pre-probe backup kept:
  `ZCodeSecondHome\.zcode\v2\ID_Backups\tasks-index.before-live-probe-*.sqlite`.


Sessions survive app-server restarts by design (draft runtime rebuild gate /
cold resume). Cost: an in-flight agent turn **in the Secondary** would be
interrupted (resumable, but a real cost) — hence the guards below.
