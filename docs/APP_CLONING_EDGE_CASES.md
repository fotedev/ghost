# App cloning edge cases — the normative catalog every clone suite must handle

Date: 2026-10-15. Companion of [APP_CLONING_PLAYBOOK.md](APP_CLONING_PLAYBOOK.md)
(the phase checklists reference these EC ids; the playbook §2 degradation
rule and §8 report cite them).

How to read each entry: **trigger → symptom → required handling** — then the
automation level (**A** = built into the scripts, no human; **R** = re-run a
menu entry; **D** = developer action) and **provenance** (verified date +
app). Severity: **P0** = breaks the clone or corrupts identity; **P1** =
breaks a feature; **P2** = cosmetic/annoyance. Distilled from the ZCode
(2026-09) and AutoClaw (2026-10) suites — every rule is verified, none is
theory.

---

## A. App updates & patches

- **EC-A01 · P0 — App update overwrites `app.asar`** → every patch (icon /
  AUMID / accent hooks, port-array widening) is silently reverted; clones
  lose their look, inst4 loses its MCP port. **Handling:** the patch marker
  carries `patchVersion`; the launcher/shortcuts warn when it is missing;
  re-apply via the patch menu entry (ZCode [12] / AutoClaw [11]) after
  EVERY app update. **A + R.** ZCode marker design; AutoClaw risk A2.
- **EC-A02 · P0 — An in-clone built-in updater runs `quitAndInstall`** → it
  wipes the SHARED patched asar mid-session for all instances. **Handling:**
  `system.autoUpdate=false` forced into every clone's settings by both the
  reset and the seed-scrub; an asar-level updater disable for clones where a
  hook exists (ZCode's `updater-secondary` patch guards on the icon env var);
  the Primary may keep updating. **A.** Verified 2026-09-24 (ZCode).
- **EC-A03 · P2 — Patch engine version bumped after the marker was written**
  → an old marker silently skips the new engine. **Handling:**
  `marker.patchVersion < EngineVersion` triggers auto re-patch on the next
  run; the ORIGINAL first-run backup is reused so `-Restore` never returns
  to an intermediate patched state. **A.** ZCode engine v6→v7.
- **EC-A04 · P1 — Corrupt / truncated asar swap** → a half-written asar
  bricks the app. **Handling:** size floor (≥ half the original bytes)
  before the swap; `.old` rollback on failure; `-Restore` uses a staged copy
  so the backup stays intact. **A.** ZCode + AutoClaw patch wrappers.
- **EC-A05 · P1 — The engine matches ZERO patch sites** (an update changed
  the code shape) → silently patching nothing looks like success.
  **Handling:** zero patch sites = exit 1 with the tree untouched;
  idempotence anchors prevent double-application. **A.**
- **EC-A06 · P1 — App running during the patch** → open handles corrupt the
  swap. **Handling:** closed-app check scoped to that install dir before
  starting. **A.**
- **EC-A07 · P2 — Node missing for the `node --check` gate / keygen** →
  **Handling:** functional probe (`--version` must report `v*`) of PATH
  node, fallback to the app-bundled `resources\node\node.exe` (AutoClaw
  ships one; ed25519 via node:crypto — PS 5.1 cannot generate it; PEM
  shapes verified: SPKI 113, PKCS8 119 chars). **A.** Verified 2026-10-15.

## B. Branding & icons

- **EC-B01 · P1 — Icon files missing at clone time** → **Handling:** playbook
  §5 decision tree — improvise tinted variants + report (default, 2026-10-15
  developer decision) or stock-default + report the exact drop paths; the
  clone NEVER fails or silently guesses over icons. **A + D.**
- **EC-B02 · P1 — Icon env var set while the file is absent** → the app
  shows a broken/blank icon. **Handling:** set the `ZCODE_ICON_DIR`-style
  var ONLY when the icon files exist (launcher check); report the degraded
  identity. **A.** Verified 2026-09-24 (ZCode).
- **EC-B03 · P2 — Developer replaces placeholder icons later** → **Handling:**
  drop the files at the reported paths → re-run the branding + shortcuts
  menu entries (idempotent); never a re-clone. **R + D.**
- **EC-B04 · P1 — Accent color unsupported by the app** (no recolor hook) →
  **Handling:** degradation ladder — drop the accent, keep title/icon/AUMID;
  report degraded. **A.**
- **EC-B05 · P2 — Generated branding assets hand-edited** → **Handling:**
  never hand-edit generated assets; the generator scripts own them (ZCode
  `generate_branding.py` v3 pipeline; `assets/ghost.ico` rule). **R.**
- **EC-B06 · P2 — Icon paths with spaces/brackets break quoting** →
  **Handling:** quote `IconLocation "<path>,0"`; verify-after re-read every
  lnk field. **A.**

## C. Taskbar & window identity

- **EC-C01 · P0 — Pinning a clone window (or Windows pin maintenance)
  rewrites the Primary's .lnk** with a clone AUMID AND wipes its icon field
  → when that clone later runs alone, the shell resolves its AUMID to the
  icon-less Primary shortcut and falls back to the exe default icon.
  **Handling:** `install_<app>_clone_shortcuts.ps1 -RepairPrimaryAumid`
  (strip the suffix + restore `<exe>,0` across Desktop + both Start-menu
  copies); the resident watcher re-checks every ~5m and auto-invokes the
  repair on hijack detection. **R + A.** Verified 2026-09-28 (ZCode;
  recurred ×3 on 09-24/26 — also AutoClaw, same rule).
- **EC-C02 · P1 — Stale taskbar group/icon**: a re-stamped window keeps the
  WRONG icon until the shell rebuilds the group — a plain stamp does not
  rebuild a pre-grouped window's group. **Handling:** every stamp is a KICK
  (brief `<aumid>.kick` identity → final) and first-seen windows get one
  kick even when their store is already correct. **A.** Verified
  2026-09-26 (ZCode green clone kept the Primary's icon).
- **EC-C03 · P1 — Process-level AUMID unreliable per-instance**: clones
  merge into one button despite a correct env block and a correct patched
  `setAppUserModelId`. **Handling:** stamp the WINDOW property store (top
  shell precedence) in the launcher; keep the process env as
  belt-and-braces. **A.** Verified 2026-09-24 (ZCode Primary+Second).
- **EC-C04 · P1 — Splash phase**: the window is titled plain "ZCode" while
  resolving → a transient relauncher window or the wrong window eats the
  stamp. **Handling:** resolve by the final branded title; wait loops
  (60s resolve, 30s re-stamp on hwnd change); ambiguous titles skipped
  loudly, never guessed. **A.** Verified 2026-09-24.
- **EC-C05 · P0 — Title-only classification stamps a clone as Primary** when
  it launches alone (its splash title matches the Primary row). **Handling:**
  classify by PROCESS MARKERS first (roaming/home dir strings in the
  command lines), titles only as a guarded fallback; a clone's branded
  title overrides a spurious Primary marker read. **A.** Verified
  2026-09-24 (ZCode green-clone default-icon bug).
- **EC-C06 · P1 — The app sets its base AUMID unconditionally** → all
  running windows share one taskbar button (AutoClaw v1 interim — historical:
  v2 shipped 2026-10-17 as engine v11 and was live-verified 2026-10-18 on
  engine v12, so new suites get the full fix). **Handling:** the fix = the
  asar branding patch (per-clone process AUMID + in-app window icon) on a
  --user-data-dir marker-file channel — env hooks die at the UAC
  boundary for self-elevating apps — with the window-level stamp as the
  elevation-gated fallback (spec §7.3c); shortcut AUMIDs remain the interim
  degradation when the patch cannot ship, reported as degraded. **A + report.**
- **EC-C07 · P2 — UIA cannot read Win10 taskbar buttons** (incl. the
  vertical taskbar) → do not build verification on UIA; trust the watcher
  logs. **A.** Verified 2026-09-26.
- **EC-C08 · P1 — Launcher at LOWER integrity than the clone** → UIPI
  silently blocks the window stamp. **Handling:** launcher must run at the
  same or higher IL; FAIL with a hint when the stamp read-back mismatches;
  never launch clones elevated (elevation also breaks drag-drop: UIPI
  strips drop data into a high-IL window while the overlay still lights).
  **A.** Verified 2026-09-24.
- **EC-C09 · P1 — Reading a .lnk AUMID by UTF-16-decoding the file**
  misaligns on odd byte offsets → false `<none>` conclusions. **Handling:**
  read via `Shell.Application` `ExtendedProperty('System.AppUserModel.ID')`
  ONLY. **A.** Verified 2026-09-26 (cost one wrong conclusion).

## D. Launch & isolation

- **EC-D01 · P2 — Relaunching a running clone** → the single-instance lock
  focuses the existing window instead of a second copy (expected, not an
  error). **Handling:** the launcher detects the running subtree, reports
  "already running", exits 0. **A.**
- **EC-D02 · P0 — The app overwrites `--user-data-dir`** via `app.setPath`
  (ZCode) → the profile leaks into the Primary. **Handling:** env levers
  FIRST (`ZCODE_DATA_BASE_DIR` / `ZCODE_DESKTOP_USER_DATA_DIR` /
  `ZCODE_DESKTOP_SESSION_DATA_DIR` / `ZCODE_DESKTOP_HOME_DIR` / `HOME`);
  `--user-data-dir` only as a second layer when honoured (AutoClaw honours
  it). **A.** Verified 2026-09-23.
- **EC-D03 · P0 — One credential used by two instances** → polling conflict
  (Telegram HTTP 409) + random cross-account billing; `paired.json` admin
  token duplication. **Handling:** one credential = one instance; the seed
  EXCLUDES every credential store (`token-cache.json` excluded, not
  scrubbed; `auth.json` tokens stripped keeping `userInfo`; the gateway
  state tree never copied); verify-after-launch asserts own-key-only.
  **A.** ZCode 2026-09-23; AutoClaw 2026-10-15.
- **EC-D04 · P1 — An older seed had copied a now-excluded credential file**
  → **Handling:** post-copy double-check deletes excluded files; a
  marker-guarded one-time reconcile re-strips copied tokens (idempotent; a
  deliberate later login is never reverted). **A.** Verified 2026-10-15.
- **EC-D05 · P0 — Identity/session rows copied between homes** → dead
  storage / cross-instance contamination. **Handling:** NEVER copy session
  rows between homes (the ZCode shared CLI db lesson); cross-instance sync
  is done by recycling the target's app-server, not by copying. **A.**
- **EC-D06 · P1 — Primary config changed by a clone launch** → **Handling:**
  hash the Primary's gateway config before launch, compare after; any
  change = FAILED isolation breach. **A.** Verified 2026-10-15.

## E. First-run seed

- **EC-E01 · P1 — Primary running during the first seed** → robocopy fails
  on locked leveldb/DBs (exit 9). **Handling:** wait ≤180s for the Primary
  to close, then abort with an instruction; 3s settle for file-handle
  release; later launches skip the gate entirely. **A + D.** Verified
  2026-10-15.
- **EC-E02 · P0 — Seed completion keyed on a profile file alone** → an
  aborted robocopy's PARTIAL profile passed as seeded; the app launched on
  inconsistent stores and died within seconds. **Handling:** the
  `.autoclaw-seeded`-style marker is written ONLY after the full seed +
  scrub verify; needsSeed keys on the marker; a partial profile is cleared
  + re-seeded automatically. **A.** Verified 2026-10-15.
- **EC-E03 · P1 — robocopy exit ≥ 8** → **Handling:** abort + remove the
  partial profile; never proceed with a half-built seed. **A.**
- **EC-E04 · P2 — SQLite `-shm`/`-wal` journals copied** → inconsistent
  checkpoint. **Handling:** remove journals after the copy. **A.**

## F. Resources

- **EC-F01 · P0 — N Electron instances exhaust the Windows commit limit** →
  renderer OOM death (`render-process-gone reason:"oom"`,
  `v8-oom-last-os-error 1455` = ERROR_COMMITMENT_LIMIT); the window
  "freezes" (drags dead) and the splash-then-close relaunch loop is the
  post-crash quit path — NOT a hang or a lock. **Handling:** diagnose via
  the freeze diagnostic (ZCode [17]); mitigation = larger pagefile / fewer
  concurrent instances; relaunching after the quit is safe. **R + D.**
  Verified 2026-09-25 (Primary+Second died the same second; JS heap only
  ~478MB → OS commit starvation, not an app leak).
- **EC-F02 · P2 — Port-array ceiling without the patch** → inst4 has no MCP
  port; 3 clones is the cap. **Handling:** widen the array by patch; the
  launcher warns when the patch marker is missing. **A + R.** Verified
  2026-10-15 (AutoClaw).

## G. Ports

- **EC-G01 · P0 — Two instances silently SPLIT a hardcoded 4-slot
  candidate-port array** → wrong-instance MCP routing with NO error
  surfaced. **Handling:** widen the array by asar patch; space the
  instances' preferred ports beyond the drift window (AutoClaw: 11 for a
  +9 drift). **A.** Verified 2026-10-15.
- **EC-G02 · P1 — Gateway port silently drifts +N when the preferred port
  is busy** → recording the REQUESTED port lies. **Handling:** discover the
  real listening ports by scanning expected..expected+drift against the
  clone's OWN process subtree; health-check DISCOVERED ports; write
  requested vs actual to `instance-record.json`. **A.** Verified
  2026-10-15.
- **EC-G03 · P2 — Instances grab the first free slots in start order** →
  the expected table ≠ actual. **Handling:** `instance-record.json` is the
  truth (`-Status` reads it); docs mark the table "EXPECTED only". **A.**

## H. Scripting platform (PS 5.1 / .bat / Python)

- **EC-H01 · P0 — PS 7-only syntax breaks on the shipping PS 5.1** →
  **Handling:** `RandomNumberGenerator.Create().GetBytes()` (never
  `.Fill()`); no ternary; never a variable named `$Input`;
  `ConvertFrom-Json` returns PSCustomObject — normalize with
  `ConvertTo-Hashtable`. **A.**
- **EC-H02 · P0 — PS 5.1 default-encoding writes add a BOM** → corrupts
  JSON/SQLite-adjacent files. **Handling:** no-BOM UTF-8 writes
  everywhere. **A.**
- **EC-H03 · P0 — Bare `(` `)` in an echo inside a parenthesized .bat
  block** → CMD aborts the whole script silently, even inside double
  quotes. **Handling:** reword or escape `^( ^)`. Verified via the
  GHOST.bat [9] incident.
- **EC-H04 · P1 — GUI apps calling `AttachConsole` hijack the launching
  console** with log floods. **Handling:** launch detached
  (`cmd /c start "" <exe>` / the `:Detached` helper), never inline.
  Verified via the GHOST.bat [10] incident.
- **EC-H05 · P1 — Unescaped `&` `|` in echo/labels** → **Handling:** escape
  as `^&` `^|`. **A.**
- **EC-H06 · P1 — Microsoft Store python stub passes a bare `Get-Command`**
  → **Handling:** functional probe (`--version` exits 0 reporting Python 3;
  the exit-9009 stubs and stale Python 2 must never pass); set
  `[Console]::OutputEncoding = UTF8` before invoking. **A.**
- **EC-H07 · P0 — SQL interpolation** → **Handling:** parameterized `?`
  placeholders only; SQLite logic lives in `src/python/ghost` — never
  re-embed Python in PS. **A.**
- **EC-H08 · P2 — LF vs CRLF in edited .bat** → MSYS tools lie about
  CRLF/stdin. **Handling:** edit .bat files through PowerShell-safe paths;
  test via a stdin-free harness. **A.**

## I. Windows shell & shortcuts

- **EC-I01 · P1 — A .lnk cannot set env vars** → isolation must ride the
  launcher. **Handling:** lnk target = `powershell -File launcher
  -Instance X`. **A.**
- **EC-I02 · P2 — Machine-wide shortcuts** collide between users →
  **Handling:** per-user Desktop + Start Menu only; shortcut install needs
  no admin. **A.**
- **EC-I03 · P1 — The AUMID base poisoned by a prior hijack** → writing
  clones on top stacks suffixes (`...inst1.inst2`). **Handling:** self-heal
  the Primary base BEFORE writing clone AUMIDs. **A.**
- **EC-I04 · P2 — Start-menu dedupe hides entries** when lnk AUMIDs
  collide → **Handling:** distinct per-clone AUMIDs + EC-C01 repair. **A.**

## J. Diagnostics, watchers, runtime

- **EC-J01 · P1 — WMI race: fresh processes have an empty CommandLine** →
  misclassification. **Handling:** empty CommandLine stays a candidate;
  the subtree walk still classifies; never hard-fail on it. **A.**
- **EC-J02 · P1 — A stale pre-mutex watcher copy** (its mutex name
  differs) runs alongside the new one → **Handling:** named mutex PLUS a
  startup process scan for the same script leaf name. **A.** Verified
  2026-09-26.
- **EC-J03 · P2 — The watcher console is closed** → resident work dies
  silently. **Handling:** hidden autostart deployment; a self-titled
  console ("<App> Taskbar Watcher (pid N)"); log rotation; a silent log
  with healthy pass CPU is NORMAL (stores correct), not a zombie. **A.**
  Verified 2026-09-26.
- **EC-J04 · P1 — Refresh/watcher mutates state while an agent turn is in
  flight** → **Handling:** hot-activity guard (db commit recency +
  uncompleted assistant steps + running tools + app-server CPU sample, up
  to ~90s, `-Force` bypasses; probe failure treated as hot). **A.**
- **EC-J05 · P2 — Transient probe failures** (respawn timing, partial
  JSONL lines) → **Handling:** verify-after loops with timeouts (30s
  respawn, 45s verify) + cooldowns; tolerate partial-line tails. **A.**

## K. Process classification & concurrency

- **EC-K01 · P0 — `--type` filtering alone misclassifies helpers** →
  **Handling:** classify mains by bare-exe CommandLine (quoted or unquoted
  full path only); helpers/gateway children via a parent walk from
  marker-matched mains. **A.**
- **EC-K02 · P0 — Killing "all <App> processes" kills every clone** →
  **Handling:** selective kill per target subtree; abort with a diagnostic
  dump when 2+ mains run and none classify as a clone. **A.**
- **EC-K03 · P2 — Concurrent agent sessions mutate state** (lnk hijacks,
  live state changes) → **Handling:** trust the watcher STAMP logs over
  ad-hoc probes; re-read state before concluding; hijack repair is
  idempotent. **A.**

## L. Repo gates & governance

- **EC-L01 · P1 — repo-integrity Pester assertions**: any tracked text file
  containing a `scripts/` + windows/linux path string fails CI; every
  GHOST.bat-referenced .ps1 must exist; every `src/windows/*.ps1` must
  literally appear in README.md. **Handling:** run the suite before
  declaring done. **A.**
- **EC-L02 · P0 — Editing out-of-scope files** (`identity_utils.ps1`,
  `change_device_id.ps1`, `.context/`, `archive/`, `.git/`) → **Handling:**
  do not modify; `archive/` scripts are never run and never committed.
  **A.**
- **EC-L03 · P1 — Unversioned script-name drift** (old `-vN` names in
  docs) → **Handling:** scripts live unversioned under `src/`; README must
  not match `reset_[a-z_]+_windows-v\d`. **A.**
- **EC-L04 · P2 — Menu-reference drift after renumbering** → **Handling:**
  cite menu positions as `<submenu> [n]` everywhere (e.g. `ZCode [12]`);
  a renumber sweep stays mechanical only if the style is followed. **A.**
- **EC-L05 · P1 — Secrets committed** (Telegram creds, tokens) →
  **Handling:** gitignored `.envlocal` at the repo root; watchdogs read
  params or `.envlocal`; never hardcode. **A.**
