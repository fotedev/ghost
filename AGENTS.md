# AGENTS.md — GHOST (Guided Hardware & OS Scrubbing Toolkit)

## Project overview

Fresh-start toolkit for local AI-IDE identity stores — **Cursor**, **Windsurf/Devin Desktop**, **Trae**, **Qoder**, **ZCode**, **QoderWork**, **MiniMax Agent/OpenCode**, **AutoClaw2** — for privacy hygiene, multi-account testing, and dev-environment resets. Windows PowerShell (primary) and Linux Bash scripts.

## Repository layout

```
README.md  AGENTS.md  GHOST.bat/ghost.sh     # root launchers (GHOST.exe = the gitignored
                                             #   built desktop launcher hub; scripts live under src/;
                                             #   CLI cheat sheet: docs/cli.md); GHOST.bat =
                                             #   6 submenus with CONTINUOUS LOCAL numbering
                                             #   (IDE Resets [1]-[8] / ZCode Multi-Instance &
                                             #   Clones [1]-[31] / System & GHOST Maintenance
                                             #   [1]-[5] / AutoClaw2 Multi-Instance & Clones
                                             #   [1]-[13] / Cline Multi-Instance & Clones
                                             #   [1]-[9] / OpenCode Multi-Instance & Clones
                                             #   [1]-[12]) + ANSI colors + local chained input
                                             #   per submenu (e.g. "1 3 4"), main-menu sub-paths
                                             #   ("2 1 3 4" = ZCode then run its [1] [3] [4]),
                                             #   global gid jump from the main menu, and
                                             #   [U] Check for updates on the main menu
src/windows/                        # current .ps1 resetters (unversioned names) + identity_utils.ps1 + change_device_id.ps1
src/linux/                     # .sh scripts (id_reset_common.sh + per-IDE resetters)
src/python/                    # stdlib-only Python core (ghost/ package) + ghost_cli.py bootstrap —
                               #   owns the shared SQLite/JSON identity logic; the PS bridges
                               #   (Set-SqliteKeys, reset_zcode secrets + CLI-telemetry,
                               #   refresh_zcode_second_chats chat-check) invoke it by absolute
                               #   path; tested by tests/python/test_ghost_core.py (unittest)
src/desktop/                   # GHOST.exe desktop launcher sources: GhostHub.cs (single-file
                               #   WinForms hub, C# 5 ONLY for the in-box csc.exe), menu.json
                               #   (runtime-loaded GUI menu data — parity-tested against
                               #   GHOST.bat's :DispatchOne by tests/ghost_hub_menu.Tests.ps1),
                               #   app.manifest (requireAdministrator + DPI); built by
                               #   tools/build_ghost_exe.ps1 into gitignored GHOST.exe
docs/                              # IMPLEMENTATION_GUIDE/PLAN, WALKTHROUGH, research notes (local-only);
                                   #   ZCODE_CHAT_SYNC_WATCHER_PLAN.md (tracked — chat-sync root cause);
                                   #   PYTHON_HYBRID_ROADMAP.md (tracked — Phase 2 cancellation decision +
                                   #   Phase 3 thin-manifest pilot design + acceptance criteria);
                                   #   T3_LOCAL_SUPPORT.md + T3_ZCODE_BRIDGE_SPEC.md (tracked — T3 Code
                                   #   local-support matrix + the ACP<->ZCode Protocol bridge spec;
                                   #   T3 monorepo study clone at ..\t3code, never committed here)
archive/                           # superseded versions (local-only fallbacks — do not run, never committed)
assets/                            # ghost.ico + ghost-source.png (launcher icon; regenerate via
                                   #   tools/make_ghost_icon.ps1 — never hand-edit)
tools/                             # reviewed utilities (block_qoder_domains.ps1,
                                   #   watch_zcode_captcha.ps1 — captcha-stall watchdog
                                   #     (Telegram creds via params or .envlocal at repo root);
                                   #   watch_zcode_taskbar.ps1 — resident taskbar-identity
                                   #     watcher (ZCode submenu [26]; every 5s re-stamps
                                   #     System.AppUserModel.ID on each ZCode main window
                                   #     incl. Primary when missing/wrong; every ~5m self-heals
                                   #     hijacked Primary shortcuts + restores wiped icons;
                                   #     -RunOnce, -CheckPrimaryHijack, -InstallAutostart/
                                   #     -RemoveAutostart, named-mutex + startup process-scan
                                   #     single instance (scan catches a stale pre-mutex
                                   #     copy whose mutex name differs), self-titling
                                   #     console "ZCode Taskbar Watcher (pid N)", log at
                                   #     %LOCALAPPDATA%\watch-zcode-taskbar\taskbar.log);
                                   #   diagnose_zcode_freeze.ps1 — read-only freeze diagnostic
                                   #     (ZCode submenu [27]; -Days N): scans each instance's
                                   #     <home>\.zcode\v2\logs for render-process-gone /
                                   #     child-process-gone / perf_freeze events (collapses
                                   #     same-second bursts), reads .zcode\v2\crash\archive dump
                                   #     annotations (v8-oom-last-os-error 1455 = commit limit),
                                   #     prints live RAM/commit/pagefile pressure; verified the
                                   #     2026-09-25 renderer-OOM freeze root cause;
                                   #   diagnose_zcode_throttle.ps1 — read-only Start-Plan throttle
                                   #     diagnostic (-Days N): parses the SHARED agent runtime JSONL
                                   #     (~\.zcode\cli\log\zcode-*.jsonl — every instance writes there;
                                   #     the HOME override never reaches the CLI log path) for
                                   #     model.main_turn.retry_start_plan_admission_busy + turn.failed,
                                   #     walks the error cause chain (StartPlanBusyAutoRetryExhaustedError
                                   #     / model_rate_limited / providerCode 3009 "model concurrency
                                   #     limit exceeded" / maxAttempts), prints a per-day event list +
                                   #     hourly histogram (local time) + per-session rollup; the verdict
                                   #     explains "Reconnecting... x/10" = the client's 11-attempt
                                   #     recovery loop and gives the discrimination test (close all
                                   #     instances but one during an incident). Verified 2026-10-27:
                                   #     server-side Start Plan admission control, NOT a device/IP ban
                                   #     (auth + billing unaffected; started that day, bursty, different
                                   #     accounts failed in the same minute);
                                   #   patch_zcode_icon_override.ps1 (+ .mjs engine v9, shared
                                   #     tools/asar_surgery.mjs IO layer) — one-time
                                   #     app.asar patch enabling ZCODE_ICON_DIR / ZCODE_AUMID_SUFFIX /
                                   #     ZCODE_ACCENT_HEX / ZCODE_INSTANCE_NAME env overrides +
                                   #     __ZCODE_BLUE__/__ZCODE_ACCENT__/__ZCODE_TITLE__ renderer flags
                                   #     (per-clone accent color + window title); v7+ also injects
                                   #     bidi auto-direction into the chat (per-paragraph Arabic RTL /
                                   #     English LTR via unicode-bidi:plaintext + dir="auto" stamping,
                                   #     code blocks stay LTR; ZCODE_BIDI_OFF=1 opts out); v9 (2026-11-03)
                                   #     replaced the extract/repack pipeline (npx extract of the
                                   #     ~340 MB/~32k-file asar to %TEMP%, up to 4 repacks, one npx
                                   #     spawn per verify) with IN-PLACE asar surgery: ranged reads of
                                   #     only the text entries, in-memory transforms, candidate
                                   #     rebuilt in one streaming pass (untouched payload region
                                   #     copied byte-for-byte + patched contents appended at the
                                   #     tail + only patched header entries rewritten, integrity
                                   #     recomputed) + full header/region/content verify in the
                                   #     same node process; also fixed a pre-existing ~290s regex
                                   #     backtracking bug in preload-blue (literal indexOf + backward
                                   #     receiver scan, output proven byte-identical to v8); patch
                                   #     time minutes -> ~5s; the sidecar is never touched (swap
                                   #     runs -SkipUnpackedSwap); marker carries
                                   #     patchVersion so ZCode submenu [28] auto-upgrades after engine changes;
                                   #     re-run after app updates; after an app update the stale marker is
                                   #     auto-detected (asar byte-probe of the engine's signature strings) and
                                   #     the patch re-applies itself with a FRESH backup of the new pristine
                                   #     asar - no -Force needed (2026-10-24); -WaitForClose (2026-10-31,
                                   #     GHOST.bat [27] passes it) turns the running-ZCode guard into
                                   #     instruct-and-poll: prints the running PIDs, waits for every
                                   #     ZCode.exe from the install dir to exit (2 consecutive clear
                                   #     probes, 30-min default via -WaitTimeoutMinutes) and continues
                                   #     straight into the patch - the bare throw remains the default
                                   #     for direct runs without the switch (-Restore honors it too);
                                   #   zcode-blue-branding/ (blue, Second), zcode-yellow-branding/
                                   #     (yellow, Third), zcode-green-branding/ (green, Fourth),
                                   #     zcode-red-branding/ (red, Fifth — blue master +150° hue-rotate
                                   #     via make_clone_icon.ps1, accent #CA0607),
                                   #     zcode-orange-branding/ (orange, Sixth — blue master +180°
                                   #     hue-rotate, accent #CB5D06, 2026-10-24) —
                                   #     generated icon assets + shared generator (v3 pipeline: Z
                                   #     extracted per hue mask, Z rescaled to match the original
                                   #     icon's Z bbox; --mask blue|yellow|green, --out-dir);
                                   #   opencode-{blue,yellow,green,red,orange}-branding/ —
                                   #     the color suite (blue/yellow/green/red staged 2026-10-17
                                   #     from developer renders, accents #2A7CBD/#ECC31E/#37A188/
                                   #     #BD2A32) is WIRED since 2026-10-24 by the OpenCode clone
                                   #     suite + install_opencode_clone_shortcuts.ps1; orange added
                                   #     2026-10-24 (blue master +180° hue-rotate — PLACEHOLDER,
                                   #     drop developer renders there and re-run the installer).
                                   #     cline-{blue,yellow,green,red}-branding/ was staged with
                                   #     them (2026-10-17) and is WIRED since 2026-10-24 by the
                                   #     Cline clone suite + install_cline_clone_shortcuts.ps1
                                   #     (cline accents #2979B9/#EBBF1C/#39A18A/#B92932);
                                   #     cline-orange-branding/ added 2026-10-24 (tint 25/0.9
                                   #     from the blue master — hue-rotate rejected: the two-tone
                                   #     logo would produce the rejected green family);
                                   #   install_zcode_second_shortcuts.ps1 — per-user Desktop +
                                   #     Start-menu shortcuts for all five clones (AppUserModel.ID =
                                   #     base + ".2"/".3"/".4"/".5"/".6" for pin grouping; -Instance to scope;
                                   #     -Remove to uninstall; install = ZCode submenu [8],
                                   #     remove = ZCode submenu [30]);
                                   #   refresh_zcode_second_chats.ps1 — cross-instance chat
                                   #     refresh (name is historical; -Target Primary|Second|Third|
                                   #     Fourth|Fifth|Sixth|All covers every instance now). One-shot (ZCode submenu [22]
                                   #     Second-only, ZCode submenu [23] -Target All): finds shared-store
                                   #     chats missing from the
                                   #     target's tasks-index, recycles its app-server(s) (auto-respawn
                                   #     re-seeds the sidebar index), verify-after; hot-activity guard
                                   #     waits out an in-flight turn (multi-signal guard: db commit recency +
                                   #     uncompleted assistant steps + running tools + app-server CPU sample,
                                   #     up to ~90s, -Force bypasses). -Watch mode (ZCode submenu [24], -Target
                                   #     All): tails the agent JSONL logs for terminal failures (captcha
                                   #     stall / quota / rate-limit, same signatures as
                                   #     watch_zcode_captcha.ps1) and refreshes every RUNNING instance
                                   #     (not-running/not-installed skipped, guard defer + retry, 300s
                                   #     cooldown); supersedes test_live_inject.py (obsolete spike,
                                   #     now deleted — its row-copying approach was a dead end));
                                   #   sync_zcode_assets.ps1 — Primary→clone asset sync
                                   #     (ZCode submenu [18]; also auto-runs per-launch as launcher
                                   #     step 2d, pre-launch): every clone resolves its OWN
                                   #     user-scope config at <CloneHome>\.zcode\cli\config.json
                                   #     (the HOME override DOES reach the app's config resolution,
                                   #     unlike the shared CLI db — verified 2026-10-17), so the
                                   #     Sep-22 seed copies drift. Syncs MCP server DEFINITIONS
                                   #     from the Primary (per-clone 'enabled' toggles stay local;
                                   #     new servers carry the Primary's value; clone-only servers
                                   #     never removed; plugins/hooks fully local), moves the stale
                                   #     <CloneHome>\.zcode\skills copies aside (they shadow skill
                                   #     discovery) and junctions <CloneHome>\.agents → the shared
                                   #     ~\.agents store (live skills, no elevation needed), and
                                   #     robocopy /MIRs cli\plugins\cache + marketplaces +
                                   #     known_marketplaces.json when the version set drifts
                                   #     (plugins\data + cli\agents stay per-instance), and
                                   #     since 2026-11-11 syncs plugins\installed_plugins.json
                                   #     from the Primary with every installPath rewritten to
                                   #     the clone's own cache mirror (area 4 - before this
                                   #     fix clones had no file and could not activate ANY
                                   #     plugin even with the cache mirrored; backup +
                                   #     verify-after incl. per-entry installPath existence,
                                   #     skipped by -McpOnly, clone file preserved when the
                                   #     Primary has none). Running
                                   #     instance (marker match) = SKIP + WARN for skills/plugins
                                   #     (mirroring must not race a live app); the MCP definitions
                                   #     themselves need NO skip — verified 2026-10-27 (app.asar +
                                   #     all six instances' logs): the app holds no handle on
                                   #     config.json, NEVER rewrites it on exit (event-driven
                                   #     atomic writes only), and reads mcp.servers at every
                                   #     app-server spawn = every new session. -McpOnly syncs
                                   #     MCP-only and is safe against running instances; unseeded
                                   #     home = SKIP note (launcher step 2 seeds it).
                                   #     Backup + verify-after everywhere, JSONL audit at
                                   #     <CloneHome>\.zcode\asset-sync-audit.jsonl; -Target
                                   #     Second|Third|Fourth|Fifth|Sixth|All + -DryRun + -McpOnly;
                                   #     child-process only (exit codes — never dot-source));
                                   #   zcode_mcp_merge.ps1 — pure merge core extracted from
                                   #     sync_zcode_assets.ps1 (ConvertTo-DeepHashtable /
                                   #     Test-DeepEqual / Write-JsonNoBom / Invoke-McpMerge): the
                                   #     single copy of the merge invariant, unit-tested by
                                   #     tests/zcode_mcp_merge.Tests.ps1 (clone-local enabled
                                   #     survives, clone-only servers kept, new servers inherit
                                   #     Primary enabled, Primary definitions win);
                                   #   patch_zcode_exe_identity.ps1 (+ pure core
                                   #     zcode_exe_identity_lib.ps1, unit-tested by
                                   #     tests/zcode_exe_identity.Tests.ps1) — per-clone Task
                                   #     Manager identity (ZCode submenu [31] / gid 83;
                                   #     launcher step 2f is the primary path): builds
                                   #     ZCode-Blue.exe .. ZCode-Orange.exe — copies of the stock
                                   #     ZCode.exe IN the install dir (~235 MB each, support
                                   #     files shared) with the branding icon group swapped via
                                   #     Win32 UpdateResource (PS 5.1-safe P/Invoke; old RT_ICONs
                                   #     deleted, GRPICONDIR rebuilt) and VERSIONINFO
                                   #     FileDescription -> "ZCode <Color>" (full VS_VERSIONINFO
                                   #     re-serialization; round-trip byte-identity test-pinned).
                                   #     Reason: Task Manager's background groups take name+icon
                                   #     from the exe IMAGE, so every instance on the stock exe
                                   #     rendered as an identical stock "ZCode (N)" row. Drift =
                                   #     sidecar <exe>.ghost-id.json (source size+mtime+SHA256 +
                                   #     icon SHA256 + engine version); the launcher fast-checks it
                                   #     per launch and rebuilds only on drift (app update / icon
                                   #     change). Verify-after re-reads the written resources +
                                   #     version info; audit JSONL at
                                   #     %LOCALAPPDATA%\ghost-zcode-exe-identity\; -Target
                                   #     Second|Third|Fourth|Fifth|Sixth|All, -DryRun, -Force;
                                   #     skip-running (locked exe) is non-fatal. The Primary keeps
                                   #     the stock exe; copies lose Authenticode validity
                                   #     (SmartScreen caveat for AV-on machines — docs hedged);
                                   #     ~1.2 GB disk for the 5 copies. THE STANDING RULE this
                                   #     feature created: any ZCode process enumeration must match
                                   #     the whole copy family (WMI "Name LIKE 'ZCode%'" /
                                   #     Get-Process 'ZCode*'/ copy-aware cmdline regex) — a bare
                                   #     Name='ZCode.exe' makes copy-running clones invisible to
                                   #     the RAM guard, stamping, resets, sync guards, chat
                                   #     refresh and the watchdogs (all 8 sites widened 2026-11-11,
                                   #     test-tripwired); also fixed the pre-existing
                                   #     [^\s"]*-spaced-path gap in the unquoted bare-exe branch
                                   #     ([^"]* now — machine-wide installs were misclassified);
                                   #   sync_autoclaw2_mcp.ps1 — AutoClaw2 MCP
                                   #     orchestrator (AutoClaw2 [8] / gid 73;
                                   #     launcher pre-launch step [2b] is the
                                   #     primary path): applies
                                   #     tools/autoclaw2-mcp.master.json (or
                                   #     -From Primary) to CLOSED clone profiles'
                                   #     connected-sources SQLite via the Python
                                   #     core; D6 merge keeps clone-local
                                   #     enabled toggles, backup +
                                   #     -RestoreBackup, verify-after, JSONL
                                   #     audit; live acceptance pending spikes;
                                   #     2026-11-05: E5 RESOLVED — root cause
                                   #     mined from main.cjs: 'pending' is NOT
                                   #     a legal row status (strict zod parse;
                                   #     the fallback renders a hardcoded
                                   #     invalid_response and Reconnect throws
                                   #     pre-network) and the source test is
                                   #     LOCAL spawn/fetch, so the sync now
                                   #     runs the same discovery itself
                                   #     (discover_stdio/discover_http) and
                                   #     writes PRE-TESTED rows (connected +
                                   #     real tools_json / failed + legal
                                   #     error_code), migrates illegal slugs
                                   #     (chrome_devtools, supabase_masarx)
                                   #     and warns on untrusted workspaces;
                                   #     [2b] gained -SkipMcpSync + a loud
                                   #     exit-2 warning; the schema gate
                                   #     accepts the app's append-only migration
                                   #     history since 4.0.0 (80→85; intact
                                   #     baseline row + columns must hold —
                                   #     NEVER -RestoreBackup across it, the
                                   #     backups are whole-DB schema-80 copies;
                                   #     §9.1 of the spec = the corrupt-CAS
                                   #     incident that bricked every clone run
                                   #     and its heal procedure);
                                   #     2026-11-06 LIVE-VERIFIED: blue/green
                                   #     converged green (playwright ·21,
                                   #     chrome_devtools ·3, obsidian ·15,
                                   #     supabase ×2 ·20); the LAST flip
                                   #     (cloudinary) = the stored-row zod IL
                                   #     refines each tool's serialized
                                   #     inputSchema to ≤16384
                                   #     (inputSchema_too_large — cloudinary
                                   #     upload_asset 20024; one over-limit
                                   #     tool fails the WHOLE row) — the
                                   #     sanitizer now measures the CLEANED
                                   #     schema (UTF-16-exact) and drops
                                   #     over-limit tools (41/42 survive),
                                   #     strict_row_problems mirrors the
                                   #     refine; -Target Primary now works
                                   #     (was ambiguous-account: dormant
                                   #     27e33829 + live 68f7331f — explicit
                                   #     -Account hint or newest-runtime.sqlite
                                   #     picked LOUDLY, sub-60s tie refuses)
                                   #     and the gate accepts the fresh-account
                                   #     single-row stamp (FRESH_STAMP_BASELINE
                                   #     0001/85/2e8dc336); first Primary sync
                                   #     = 10 rows (6 connected + 4 honest
                                   #     OAuth auth-fails); 2026-11-06 later:
                                   #     the FULL ZCode set merged in (20
                                   #     servers, +10 enabled) and the
                                   #     credential custody replicated
                                   #     programmatically (credentials.enc =
                                   #     v10 + AES-256-GCM under a per-profile
                                   #     DPAPI'd OSCrypt key from Local State;
                                   #     key=[ownerId,"source:<ws>:<slug>",
                                   #     version], value=token string) —
                                   #     final 10 connected / 10 honest-failed
                                   #     per profile; vercel's 633KB catalog
                                   #     is 2.4× the app's 256KB discover cap
                                   #     (impossible on 4.0.0), github fails
                                   #     the startup test while the identical
                                   #     handshake replays clean (app-side
                                   #     quirk, runtime Reconnect may work);
                                   #     discover_http gained a headers param;
                                   #     spec §9.2.1/§9.2.2;
                                   #   sync_autoclaw2_chats.ps1 — AutoClaw2 chat
                                   #     inventory ([9] / gid 75) + guarded
                                   #     one-way import ([10] / gid 76; 2026-11-09
                                   #     BOTH rows were dead from birth — :Run
                                   #     forwarded only 3 args, so gid 75 lost
                                   #     "All" (missing-argument error) and gid 76
                                   #     lost -Target All AND had no -SessionId;
                                   #     :Run now forwards 8 args) + the -AllMissing
                                   #     batch (every non-IM source session each
                                   #     target lacks — the Inventory diff — dry-run
                                   #     plan + -Apply; exit 2 only when every
                                   #     target refused) + -Revert -ImportId; [import] title
                                   #     prefix (D11), IM sessions refused
                                   #     (D12), work_events copied with fresh
                                   #     UUIDv4 ids, sidecar provenance;
                                   #     2026-11-09 LIVE-VERIFIED (first real
                                   #     imports, Primary→c1): apply initially
                                   #     failed with UNIQUE constraint failed:
                                   #     work_runs.accept_order — the live 4.0.0
                                   #     schema has CREATE UNIQUE INDEX
                                   #     uniq_work_accept_order ON
                                   #     work_runs(accept_order) (globally unique
                                   #     per account DB, NOT per session; dry-run
                                   #     passed because it never touches the DB).
                                   #     chat_import now remaps accept_order from
                                   #     the target's MAX tail preserving source
                                   #     relative order (queue ordering reads
                                   #     (session_id, status, accept_order);
                                   #     content_hash excludes it so idempotency
                                   #     is unaffected); both failed applies
                                   #     rolled back cleanly = C6 held. Fixture
                                   #     carries the index + a per-profile
                                   #     accept_order counter + regression test
                                   #     (tests/python/test_ghost_autoclaw2.py,
                                   #     discover -s tests/python: 158 green);
                                   #     spec §5.5 updated. 2026-11-11: -Account
                                   #     <sha-prefix> hint ADDED (plumbs
                                   #     account_hint / source_account_hint
                                   #     through ac2-chat-inventory/-import/
                                   #     -revert — the newest-runtime.sqlite
                                   #     default silently switched the sync
                                   #     source when the Primary re-logged into
                                   #     the fresh 830c6348 account and the old
                                   #     68f7331f chats went invisible; inventory
                                   #     ok-lines + audit now carry the resolved
                                   #     account sha + how it was picked); a
                                   #     blind-shell preflight prints the
                                   #     APPDATA/USERPROFILE used when a profile
                                   #     dir does not resolve (sandboxed shells
                                   #     reported profile-missing/not-signed-in
                                   #     on healthy profiles); menu.json gid 76
                                   #     gained the missing -AllMissing and the
                                   #     hub parity test now compares ARGS
                                   #     against the .bat dispatch (was
                                   #     script+mode only); check_schema refuses
                                   #     schema-less runtime DBs instead of
                                   #     crashing. Remaining known gaps: targets
                                   #     must be closed + signed-in (c4 never
                                   #     signed in; running instances currently
                                   #     leave NO lockfile, so the target-running
                                   #     gate cannot see them — close clones
                                   #     before -Apply); re-importing an
                                   #     actively-growing source session
                                   #     duplicates it (changed content hash
                                   #     falls through by design);
                                   #   patch_autoclaw2_identity.ps1 — AutoClaw2
                                   #     window + notification-tray identity patch
                                   #     (AutoClaw2 [13] /
                                   #     gid 78; -Restore, -Force, -WaitForClose):
                                   #     colored per-clone taskbar buttons + tray
                                   #     icons for the RUNNING windows — the suite's last
                                   #     DEGRADED item (spec §7, "deferred until
                                   #     actually needed") shipped 2026-11-06 after
                                   #     the 4.0.0 bundle turned out to ship
                                   #     UNPACKED (plain-text
                                   #     resources\app\dist\main.cjs, no app.asar,
                                   #     NO runtime integrity check — bootstrap =
                                   #     bare require(); payload-verify.cjs is
                                   #     existence-only and never spawned). Splices
                                   #     FOUR byte-anchors (each verified unique
                                   #     in the 14.3MB bundle; v2 2026-11-09 adds
                                   #     the tray anchor) so the AUMID, window icon
                                   #     AND notification-tray icon read
                                   #     ZWORK_AUMID / ZWORK_CLONE_ICON:
                                   #     setAppUserModelId(Kqn),
                                   #     appId:Kqn,appIconPath:e, (inside Xqn — the
                                   #     relaunchCommand backtick literal is never
                                   #     touched), the Xqn(l,process.execPath)
                                   #     call site (+l.setIcon) and the tray
                                   #     builder's t=r(e(n.iconPath)) read (inside
                                   #     mTr — the stock bundle feeds every tray
                                   #     its own monochrome trayTemplate.png, which
                                   #     is why the five tray icons stayed
                                   #     uncolored after the 2026-11-06 window
                                   #     anchors landed). launch_autoclaw2_clone.ps1
                                   #     sets ZWORK_AUMID=com.zhipuai.autoclaw2.cN
                                   #     (matching the SHORTCUT AUMIDs so pins and
                                   #     windows group) + ZWORK_CLONE_ICON=the
                                   #     tinted tray_icon.ico; no env = stock
                                   #     behaviour (the Primary stays base-AUMID).
                                   #     Since 2026-11-09 the LAUNCHER also kicks the
                                   #     window AUMID after launch (temp `.kick` ->
                                   #     real, 1.2 s apart, read-back verified): the
                                   #     shell builds the taskbar group before
                                   #     setAppDetails runs and never rebuilds it on a
                                   #     plain write, so without the kick every clone
                                   #     sits in ONE button (the ZCode kick lesson).
                                   #     Idempotent + per-anchor resume since v2:
                                   #     an already-spliced anchor is SKIPPED and
                                   #     recorded as the marker's preDoneAnchors —
                                   #     a v1-patched bundle upgrades in place
                                   #     (fresh pre-upgrade backup) and -Restore
                                   #     verifies against that pre-upgrade state,
                                   #     sibling backup main.cjs.bak-zwork-identity-<stamp>,
                                   #     marker autoclaw2-identity-patch.marker.json
                                   #     (sha256 before/after), node --check gate
                                   #     via the app's own vendor node, verify-after
                                   #     with auto-restore, fresh-backup re-apply
                                   #     after app updates, install-scoped
                                   #     running-instance gate (throw, or
                                   #     -WaitForClose instruct-and-poll). The new
                                   #     env vars are NOT added to the bundle's
                                   #     agent-shell env allowlist (HX) —
                                   #     main-process reads only; window TITLE
                                   #     stays shared "AutoClaw" (renderer <title>
                                   #     re-override is out of scope);
                                   #   sync_mcp_registry.ps1 — MCP central registry importer
                                   #     (Maintenance [4] / gid 77; -DryRun, -Target
                                   #     cursor|windsurf|vscode|zcode|minimax|opencode|
                                   #     claude-code|codex|all — LIVE is the default
                                   #     without -DryRun): pushes the single source of
                                   #     truth tools/mcp/master-mcp.json (29 servers,
                                   #     Claude-Desktop mcpServers format; 25 + 2026-11-07
                                   #     adds supabase-My-portfolio [only:zcode], node_repl
                                   #     [only:codex], computer-use [dormant, scoped to the
                                   #     never-target copilot-computer-use]; 2026-11-08 adds
                                   #     netlify-mcp) + the gitignored
                                   #     overlay master-mcp.local.json (device values, local
                                   #     wins) into each app's own config in its own shape
                                   #     (windsurf serverUrl, minimax streamable-http, opencode
                                   #     remote/local array-command, claude-code passthrough +
                                   #     SURGICAL top-level-mcpServers-only merge of the big
                                   #     .claude.json app-state file, codex = TOML
                                   #     [mcp_servers.*] tables via the pure module
                                   #     tools/mcp/codex_toml.ps1 — line-based reader/writer,
                                   #     rest of the file verbatim, presence==enabled so
                                   #     registry-disabled and remote (url) entries are left
                                   #     untouched, startup_timeout_sec + env sub-table
                                   #     survive per-key); merge = registry definition wins,
                                   #     app-local enabled/disabled state survives, app-only
                                   #     servers never deleted; secrets = ${VAR} names only —
                                   #     the env-guard resolves them from machine env (26
                                   #     user-scope vars: 20 setx'd 2026-11-04 + SENTRY_
                                   #     ACCESS_TOKEN + SUPABASE_ACCESS_TOKEN_PORTFOLIO +
                                   #     4 SUPABASE_PROJECT_REF_* 2026-11-07 — the refs were
                                   #     also scrubbed from the whole public git history via
                                   #     filter-repo, see CHANGELOG Security), an unresolved key is omitted
                                   #     loudly, never written empty; backup ->
                                   #     MCP_Backups\<ts>\, verify-after deep-compare, JSONL
                                   #     audit at %LOCALAPPDATA%\mcp-registry-sync\; ZCode
                                   #     target = Primary only (clones converge via
                                   #     sync_zcode_assets -McpOnly / the watcher); harvest
                                   #     direction = tools/mcp/collect_mcp_inventory.ps1
                                   #     (read-only -> mcp-inventory.json; 2026-11-07 covers
                                   #     claude-code/codex/copilot-plugin/opencode-primary
                                   #     [mcp section only] too) — never auto-merges into
                                   #     the master, promotion is a per-name human decision;
                                   #     plan: docs/MCP_CENTRAL_REGISTRY_PLAN.md
                                   #     (live-verified 2026-11-04: windsurf +17, vscode +18,
                                   #     zcode +7, minimax +19 adds, second run idempotent;
                                   #     2026-11-07 full-device collect + push: windsurf/
                                   #     vscode/minimax sentry-headers formalization, zcode
                                   #     +supabase-My-portfolio, claude-code +19, codex +10
                                   #     stdio / 10 remote skipped, second run all-in-sync);
                                   #     tests: tests/mcp_registry_sync.Tests.ps1 (14));
                                   #   watch_zcode_mcp_sync.ps1 — resident MCP sync watcher
                                   #     (ZCode submenu [20] resident / [21] one-shot + live
                                   #     apply; -RunOnce, -DryRun, -IntervalSeconds, -ApplyLive,
                                   #     -Target Second|Third|Fourth|Fifth|Sixth|All,
                                   #     -InstallAutostart/-RemoveAutostart): stat-guards the
                                   #     Primary config.json (mtime+size, JSON parse-guard,
                                   #     ~1s debounce) and on every change invokes
                                   #     sync_zcode_assets.ps1 -McpOnly -Target All as a child —
                                   #     spawned console-less (CreateNoWindow: a console-less
                                   #     watcher would flash a visible cmd window on every
                                   #     5-minute deep-verify) with a 600s kill cap (a wedged
                                   #     child must never block the loop) —
                                   #     the watcher writes NOTHING itself; first pass converges
                                   #     drift, deep re-verify every 60 passes (~5 min), log at
                                   #     %LOCALAPPDATA%\watch-zcode-mcp-sync\mcp-sync.log,
                                   #     single instance via mutex ZcodeMcpSyncWatcher + startup
                                   #     process scan; -ApplyLive recycles running targets'
                                   #     app-servers after a real change (idle-guarded, never
                                   #     -Force, respawn wait ≤30s — refresh_zcode_second_chats
                                   #     mechanics); GHOST.bat gids 67/68/69 (2026-10-27));
                                   #   make_ghost_icon.ps1 — regenerates assets\ghost.ico (16..256,
                                   #     PNG-in-ICO) from the poster art: row/col background-fraction
                                   #     profiles detect the app tile in the checkerboard jpg, inset
                                   #     crop + anti-aliased rounded-corner alpha mask -> 1024 master
                                   #     saved as assets/ghost-source.png (committed — re-runs use it
                                   #     as-is and skip detection; pass -Source only on first run);
                                   #   install_ghost_shortcut.ps1 — GHOST.lnk Desktop + repo-root
                                   #     shortcuts targeting GHOST.bat with IconLocation
                                   #     assets\ghost.ico,0 (a .bat cannot carry an Explorer icon;
                                   #     .lnk files are gitignored — regenerate, never commit;
                                   #     -Remove/-DesktopOnly/-RepoOnly; Maintenance [1]);
                                   #   update_ghost.ps1 — repo self-updater (main menu [U] /
                                   #     Maintenance [2]): git fetch
                                   #     origin + compare HEAD vs the remote default branch, lists
                                   #     new commits; without -CheckOnly asks before git pull
                                   #     --ff-only; refuses on local commits / non-main or detached
                                   #     HEAD; dirty tree -> interactive stash -u -> pull -> pop
                                   #     (failed pop keeps the stash); verify-after re-reads HEAD ==
                                   #     origin + behind==0; offline fetch = warning + clean exit 0.
                                   #     Download-ZIP copy (no .git) handling, gated AFTER the
                                   #     git-on-PATH check: git missing -> direct-download update
                                   #     (archive from -ZipUrl, add/overwrite only, per-file backup +
                                   #     SHA256 verify, never deletes, defensive .git/ skip) or
                                   #     winget/git-scm guidance on a non-GHOST folder; git present
                                   #     -> in-place conversion to a clone (init + symbolic-ref main +
                                   #     local core.longpaths/core.autocrlf=false + fetch from
                                   #     -OriginUrl + reset --mixed; real local edits detected via
                                   #     --ignore-cr-at-eol re-check, EOL-only noise ignored, overwrite
                                   #     needs a second prompt) + reset --hard + upstream + verify-after
                                   #     HEAD==origin; aborted/failed setup removes the temp .git
                                   #     (Remove-GhostPathRobust: read-only clear + 3 retries);
                                   #     -CheckOnly reports without writing; -Convert answers the
                                   #     conversion/download prompt non-interactively (never the
                                   #     overwrite-edits prompt); GHOST.bat replaced by either path
                                   #     prints a close-and-relaunch note (cmd reads the .bat
                                   #     incrementally)
                                   #   patch_opencode_clone_home.ps1 (+ .mjs engine v4, shared
                                   #     tools/asar_surgery.mjs IO layer — v4 (2026-11-03) swaps the
                                   #     extract/repack pipeline for the same in-place asar surgery as
                                   #     the ZCode v9 patch: minutes -> ~2.5s, output byte-identical to
                                   #     v3, sidecar untouched via -SkipUnpackedSwap; clone-identity
                                   #     also switched from the per-position regex to a literal-indexOf
                                   #     + backward receiver scan, regex-equivalence unit-proven;
                                   #     anchors re-derived 2026-11-01 for the 2.2.5.0 bundle) — one-time
                                   #     OpenCode desktop app.asar patch (OpenCode submenu [8]):
                                   #     clone-home (packaged bootstrap hardcodes userData =
                                   #     %APPDATA%\ai.opencode.desktop — the patch swaps the
                                   #     isPackaged branch of the app's own ye() for an argv scan of
                                   #     --opencode-clone-home=<dir>; ye()'s body then mkdirs the
                                   #     subdirs, sets the four XDG_* env vars and the call site
                                   #     pins userData/sessionData per clone) + clone-identity (the
                                   #     SINGLE setAppUserModelId site wrapped to append .<cN> and
                                   #     an app-level browser-window-created listener stamping
                                   #     window AUMID/icon/"OpenCode <Color>" title — identity on
                                   #     PURE ARGV (--opencode-clone-id/-title/-icon): the main
                                   #     bundle out/main/index.js is ESM, require is undefined, so
                                   #     v1's fs-based json resolver silently no-oped; no
                                   #     BrowserWindow ctor sites exist in this app, aliased
                                   #     imports); no flag = bit-for-bit stock; marker
                                   #     opencode-clone-home-patch.marker.json + -Restore + node
                                   #     --check + zero-site abort + 2026-10-24 update-recovery
                                   #     byte-probe (core/current tiers — old-engine trees rebuild
                                   #     from the marker's pristine backup) + locked-asar in-place
                                   #     overwrite fallback (indexer-held asar: delete blocked,
                                   #     write shared; pristine-backup-gated); -WaitForClose
                                   #     (2026-10-31, GHOST.bat OpenCode [8] passes it) turns the
                                   #     running-OpenCode guard into instruct-and-poll: prints the
                                   #     running PIDs, waits for every OpenCode.exe from the install
                                   #     dir to exit (2 consecutive clear probes, 30-min default via
                                   #     -WaitTimeoutMinutes) and continues straight into the patch -
                                   #     the bare throw remains the default for direct runs without
                                   #     the switch (-Restore honors it too); re-apply after app
                                   #     updates (auto-detected);
                                   #   install_opencode_clone_shortcuts.ps1 — per-user Desktop +
                                   #     Start-menu shortcuts for c1..c5 (AppUserModel.ID =
                                   #     ai.opencode.desktop.c1..c5; base read from the stock
                                   #     OpenCode.lnk via Shell ExtendedProperty or the verified
                                   #     constant; -Instance to scope; -Remove; -RepairPrimaryAumid
                                   #     strips a hijacked .cN suffix + restores <exe>,0 icon);
                                   #     per-clone IconLocation =
                                   #     tools\opencode-<color>-branding\tray_icon.ico,0 (missing
                                   #     dir warns + falls back to the exe icon); OpenCode
                                   #     submenu [7]
                                   #   new_clone_suite.ps1 — clone-suite scaffolding generator (playbook
                                   #     phases 3-10 mechanics): intake JSON → reset/launcher/.bat/
                                   #     shortcuts/SPEC skeletons + GHOST.bat submenu anchor-edit with
                                   #     verify-after; parse-checks every emitted .ps1; Phases 0-2 stay
                                   #     with the agent as <TODO: Phase 1 discovery> slots
                                   #   make_clone_icon.ps1 — GENERIC clone-icon generator (any app,
                                   #     PS 5.1 + System.Drawing only): corner-sampled background →
                                   #     tile detection (LongestLowRun profiles, -BgTolerance, or
                                   #     -ManualCrop x,y,size) → inset crop → 1024 master +
                                   #     rounded-corner alpha mask → tray_icon.ico (16..256,
                                   #     DIB frames below 256 + PNG at 256 — the only layout the
                                   #     shell renders) + icon_windows.png + source.<ext> provenance;
                                   #     -HueRotate derives extra colors (zcode-red-branding =
                                   #     blue master +150°); re-runs reuse the transparent-corner
                                   #     master; verify-after + TEMP previews; built for the
                                   #     opencode/cline future clones — do not delete
```

## Architecture

```
src/windows/identity_utils.ps1  # Shared library, dot-sourced by all IDE scripts
  New-IdentitySet                  #   -> { devDeviceId, machineId, macMachineId, sqmId }
  Assert-Administrator             #   -> exit 1 if not elevated
  Backup-FileToTimestampDir        #   -> copy to <app>\ID_Backups\<ts>\<label>
  Set-JsonIdentity                 #   -> JSON patch + verify-after re-read
  Set-SqliteKeys                   #   -> Python-backed UPSERT + verify-after (invokes src/python/ghost_cli.py sqlite-update)
  Get-GhostPythonCli               #   -> absolute path to the Python core bootstrap (or $null if missing)
  Clear-BinaryIdentityStore        #   -> rename or delete; clobbers old .backup first
  Write-AuditLog                   #   -> JSON audit with {file, key, before, after, ok}
  New-RestoreScript                #   -> self-contained .ps1 that reverses all changes
  Get-NewCrashReporterId           #   -> lowercase GUID

reset_cursor.ps1     # Cursor: 15 steps (machineid, storage.json, state.vscdb,
                                   #          auth-secrets scrub, device_id_salt, os_crypt rotation,
                                   #          Cookies/NPS/sentry/DIPS/Trust Tokens/Crashpad/logs, workspace DBs)
                                   #          v0.3 THIN MANIFEST (Phase 3 pilot — docs/PYTHON_HYBRID_ROADMAP.md):
                                   #          every store mutation runs via ghost_cli.py core subcommands
                                   #          (Invoke-GhostCore = the single PS→Python point); step order,
                                   #          audit keys, restore actions + summary identical to v0.2
                                   #          (archived at archive/reset_cursor_windows-v0.2.ps1, local-only);
                                   #          step 4's legacy temp-.py heredoc replaced by the shared
                                   #          delete-secrets subcommand; Python now required for ALL steps
reset_devin.ps1       # Windsurf/Devin Desktop (rebranded 2026-06): 17 steps
                                   #            x N auto-detected %APPDATA% roots (Devin, Windsurf):
                                   #            argv.json crash-reporter-id (.windsurf + .devin),
                                   #            .codeium\config.json device_id, installation_id (.windsurf
                                   #            + cli\), credentials.toml delete, config.json org_id blank,
                                   #            extended cache sweep, LOCALAPPDATA updater sweep
                                   #            v0.4 THIN MANIFEST (Phase 3 continuation — same contract as
                                   #            reset_cursor v0.3): every mutation via ghost_cli.py core
                                   #            subcommands incl. the GENERALIZED delete-secrets (ESCAPE'd
                                   #            windsurf/devin LIKE patterns) — the repo's LAST temp-.py
                                   #            heredoc is gone; patch-argv (JSONC) / replace-text /
                                   #            json-set cover the app-specific steps; v0.3 archived at
                                   #            archive/reset_devin_windows-v0.3.ps1 (local-only);
                                   #            Python required for ALL steps
reset_trae.ps1      # Trae: 16 steps (above + aha delete,
                                   #         ModularData\ckg_server\local_env.json device_id+host_map,
                                   #         ai-agent identity-rows-only scrub (chat preserved), SharedStorage,
                                   #         Partitions\trae-webview, iCubeAuthInfo://* removal,
                                   #         has_device_id_updated_to_aha=false)
reset_qoder.ps1       # Qoder: 31 steps (main + CORS_Profile, expanded
                                   #          state.vscdb scrub incl. loginBroadcast +
                                   #          secret.local.machine.variables, .qoder
                                   #          installation_id/.auth machine_id rotation,
                                   #          webview stores, tmp/telemetry+logs, probe;
                                   #          system steps: HKCU deviceid, HKLM SQM, MAC, hostname)
reset_zcode.ps1       # ZCode: 27 steps + [6b/27] config.json provider-apiKey strip
                                   #          (Unlink-loop fix) + telemetry-state deviceMid, RUM store,
                                   #          setting.json deviceSid, embedded-browser partition;
                                   #          -Target Primary|Secondary|Third|Fourth|Fifth|Sixth|Both|All (selective
                                   #          tree-kill, per-target ID_Backups, independent IDs per child)
launch_zcode_second_instance.ps1   # ZCode multi-instance launcher -Instance Second|Third|Fourth|Fifth|Sixth
                                   #          (own window via cmd/start; first run clones+scrubs profile,
                                   #          routes Telegram bots to Primary via per-home marker;
                                   #          step 2e ensures the MCP sync + taskbar identity watchers
                                   #          are running hidden and installs their Startup .lnks once —
                                   #          mutex probe, best-effort, never blocks the launch;
                                   #          step 0 RAM guard: at -MaxConcurrent (default 3) running
                                   #          instances it prints live commit numbers and asks before
                                   #          starting another (renderer-OOM 2026-09-25 + Start Plan
                                   #          throttling); non-interactive callers warn+continue, an
                                   #          already-running clone never prompts; hidden-console
                                   #          launches (shortcuts, -WindowStyle Hidden) get a Yes/No
                                   #          dialog instead of an invisible prompt that would hang
                                   #          the launch (2026-11-01, launcher-side so installed
                                   #          shortcuts need no reinstall; -NonInteractive switch
                                   #          for unattended callers); -LowRam passes
                                   #          --disable-gpu (experimental); step 2f (2026-11-11)
                                   #          ensures the clone's ZCode-<Color>.exe Task-Manager
                                   #          identity copy is fresh (marker fast-check, child tool)
                                   #          and launches the clone FROM it (stock-exe fallback +
                                   #          loud warning; Primary always stock);
                                   #          Launch-ZCode-Blue/Yellow/Green/Red/Orange.bat wrappers)
launch_zcode_cli_light.ps1         # ZCode LIGHT headless worker -Instance Second..Sixth (GHOST.bat ZCode
                                   #          [7], gid 70; verified 2026-10-28 — docs/ZCODE_LIGHT_MODE.md):
                                   #          runs resources\glm\zcode.cjs under system node with the FIVE
                                   #          env levers (HOME+USERPROFILE -> CloneHome redirect
                                   #          cli/config.json + cli/db/db.sqlite; ZCODE_DATA_BASE_DIR ->
                                   #          v2 credentials/provider_config; ZCODE_STORAGE_DIR -> cli caches;
                                   #          ZCODE_BUILTIN_PROVIDER_CONFIG_FILE -> the bundled
                                   #          resources\config\provider\zcode-builtin.json — FIFTH lever
                                   #          added 2026-10-31 for the CLI 0.17.1 plain-node bootstrap
                                   #          regression: the bundle's own fallback climbs a dev-monorepo
                                   #          path and never finds the packaged file, and the nbs() argv
                                   #          gate requires it for -p/app-server/login; the desktop app
                                   #          injects this env into its own children so only plain-node
                                   #          spawners need it — T3 bridge spawnAppServer carries the same
                                   #          lever; bundled copy first, newest runtime-cache copy fallback)
                                   #          — ~0.9 GB commit vs ~1.6 GB+ per desktop instance; modes:
                                   #          interactive REPL (default), -Prompt one-shot (--mode, --cwd),
                                   #          -Server = foreground app-server stdio for orchestrators.
                                   #          Verified limits: the interactive TUI CANNOT run standalone
                                   #          (@zcode/tui only resolves inside the app's own Electron
                                   #          runtime — ELECTRON_RUN_AS_NODE disables asar), and a home
                                   #          without a standalone `zcode login zai` runs tasks on the FREE
                                   #          opencode-zen model, not the Start Plan (the app injects
                                   #          account:zai-start-plan adapters only into its own children;
                                   #          hand-written defaultModelSelection in provider_config.json is
                                   #          normalized away) — the launcher detects it and prints the
                                   #          one-time login recipe
reset_qoderwork.ps1   # QoderWork: 26 steps (agents.db oauth/app_settings scrub,
                                   #          chats preserved; auth.dat, MachineGuid, MAC, hostname;
                                   #          -SkipMac/-SkipHostname/-DryRun)
reset_minimax_opencode.ps1  # MiniMax/OpenCode: 22 steps (OpenCode auth.json wipe -> {} unless
                                   #          -KeepLogin, version preflight ≥1.17.0, distinct
                                   #          updater IDs, Chromium state per profile; v1.2 adds
                                   #          updater-tmp sweep, DIPS/SharedStorage suffix sweep,
                                   #          lockfile/locks delete, uninstall_metrics removal,
                                   #          windowIds rotation + per-window file delete; v1.3 DELETES
                                   #          mcode-public auth.json/auth-state.json + legacy root state —
                                   #          "{}" there throws Invalid OAuth state and blocks the login
                                   #          page — and rotates .minimax\v2\session-handoff\device-id;
                                   #          chat preserved)
change_device_id.ps1              # System-level: Fingerprint (self-test) / LegacyReset (registry GUIDs)
                                   #   / RepairProfiles (ProfileList .bak keys). Windows-only.
                                   #   IDE Resets [1] = LegacyReset behind :ConfirmRun (2026-11-10 — the old
                                   #   bare :Run dispatched the DEFAULT Fingerprint mode, a READ-ONLY
                                   #   self-test, so the menu row never changed anything). Registry GUIDs
                                   #   never flip the Fingerprint self-test (WMI signals, ground truth #4);
                                   #   per-user hive failures now SKIP that SID loudly instead of aborting
                                   #   the whole run (same class as the .bak exclusion fix; reg load's
                                   #   $LASTEXITCODE is checked — reg.exe never throws).
spoof_wmi_serials.ps1              # System-level WMI serial spoof (2026-10-27, Maintenance [3] / gid 66):
                                   #   generated .mof ([DYNPROPS], real CIM keys, escaped literals) redeclares
                                   #   Win32_BIOS/BaseBoard/ComputerSystemProduct/SystemEnclosure/
                                   #   DiskDrive/PhysicalMemory -> mofcomp, + SQMClient UserId +
                                   #   Bluetooth LocalAddress (-SkipBluetooth); backup-first
                                   #   (winmgmt /backup aborts on failure), verify-after re-query is the
                                   #   arbiter, audit + generated winmgmt /restore script; -DryRun. WMI
                                   #   layer only (docs/WMI_SERIAL_SPOOFING.md) — ported from the Hydra
                                   #   Spoofer review, technique only; CPU/GPU/volume serials excluded.
launch_cline_clone.ps1             # Cline desktop clone launcher -Instance c1..c5 + -Status
                                   #   (Tauri 2.11.1/WebView2 app; see the Cline conventions section):
                                   #   env isolation CLINE_DIR + WEBVIEW2_USER_DATA_FOLDER +
                                   #   CLINE_HUB_PORT/CLINE_SIDECAR_PORT (fixed per-clone table
                                   #   25471..25475 / 3131..3135), single-instance window
                                   #   neutralization pre+post launch (verify-after), hub-lock
                                   #   running-guard ABORTS (app-level guard is neutralized),
                                   #   post-launch checks: state dir + both ports + window gone
launch_cline_clones_all.ps1        # sequential all-five (fixed 12s stagger)
launch_opencode_clone.ps1          # OpenCode desktop clone launcher -Instance c1..c5 + -Status
                                   #   (Electron 2.0.32, asInvoker; see the OpenCode conventions
                                   #   section): argv isolation --opencode-clone-home=<home> consumed
                                   #   by the clone-home asar patch (userData/sessionData + XDG_* per
                                   #   clone), identity ALSO on argv (--opencode-clone-id/-title/-icon;
                                   #   engine v3 — the app's ESM main has no require), patch-signature
                                   #   preflight ABORTS unpatched installs (a flagged launch on a
                                   #   stock app opens the PRIMARY profile), lockfile running-guard
                                   #   informs instead of blocking (per-clone single-instance keys
                                   #   off the per-clone userData), writes .opencode-clone-identity
                                   #   .json + .opencode-clone-icon.ico fresh each launch (json =
                                   #   -Status introspection only), detached start + verify-after
                                   #   (flag-matched process via WMI; lockfile fallback when command
                                   #   lines are unreadable)
launch_opencode_clones_all.ps1     # sequential all-five (launcher verify-after + 10s settle)
```
(All .ps1 above live in src/windows/; .sh scripts in src/linux/;
superseded versions (Qoder v0.1-v0.3, ZCode v1.0-v1.3, MiniMax v1.0-v1.1,
Cursor/Windsurf/Trae v0.1 legacy, AutoClaw v1.20 suite) live in archive/ as
local-only fallbacks — never committed, do not run them.)

Each IDE script is a **thin target manifest**: dot-source utils -> Assert-Admin -> Stop-App -> New-IdentitySet -> per-target [n/N] steps with verify-after -> audit log -> restore script -> summary.

## Verified ground truth (do not contradict these)

1. All covered IDEs derive **shared** telemetry IDs (`telemetry.machineId`, `.sqmId`, `.devDeviceId`, `.macMachineId`) from the same Windows registry source at first launch. Resetting one but not the others leaves a cross-IDE correlation trail.
2. SQLite must use **Python** (`Get-Command python` / `python3`). .NET SQLite assemblies are NOT registered on this box. `Set-SqliteKeys` in `identity_utils.ps1` handles Python detection + graceful skip.
3. Registry GUID changes (`HKLM:\...\Cryptography\MachineGuid` etc.) do **NOT** affect the fingerprint self-test — the algorithm reads WMI hardware/OS signals (CPU, BIOS, motherboard, RAM, timezone), not those registry keys.
4. The max reliably-changeable fingerprint-signal weight is **0.19** (CPU name 0.12 + tz 0.03 + culture 0.02 + ui.language 0.02), which is below the **0.306** delta needed to flip `sameIdentity` to false. Therefore IDE storage rewrites are the **primary** identity-reset mechanism, not the fingerprint self-test.
5. `IMPLEMENTATION_GUIDE.md` is the verified ground truth. Do not trust comments in old scripts — several describe behavior verified NOT to work.
6. **`oleaut32.dll` no longer exports `PropVariantClear`** (Win10 19041.7548, July 2026 CU — verified by GetProcAddress 2026-10-17: `VariantClear`/`SysFreeString` still there, `PropVariantClear` gone; `propsys.dll` lacks it too). Import it from **`ole32.dll`** — both window-stamping C# blocks (watcher + launcher) do. Symptom if regressed: watcher/launcher die instantly ("watcher started" → "watcher stopped" same second) with `EntryPointNotFoundException`.

## Mandatory conventions

- **Never silent-success.** Every write must be followed by a re-read and comparison. If a value doesn't match after write, emit `FAILED` and record in the audit log. This is the single most important anti-pattern to avoid.
- **Python detection = functional probe, never a bare `Get-Command`.** `Get-PythonCommandInfo` accepts a candidate (`python` / `python3` / `py` + per-user install paths) only when `--version` exits 0 reporting Python 3 — the Microsoft Store app-execution stubs (exit 9009, no interpreter) and stale Python 2 must never pass. It returns the interpreter executable PATH as a string; callers set `[Console]::OutputEncoding = UTF8` via `Set-GhostConsoleUtf8` before invoking (PS 5.1 decodes native stdout with it). Never hardcode a Python path.
- **SQLite logic lives in `src/python/ghost` — never re-embed Python in PS.** The four old per-call temp `.py` here-strings were de-duplicated into the stdlib-only package; PS invokes `ghost_cli.py <command>` (base64 payloads in, JSON/line contracts out). If a future change genuinely needs an embedded script, write the temp `.py` to `$env:TEMP` — never next to the database file — and fold the logic into the core instead when possible.
- **Parameterize SQL.** Never f-string/interpolate values into SQL. Use `?` placeholders.
- **"File existed" is not "value changed".** A backup existing does not mean the new ID is in place. Always verify.
- **Clobber old `.backup` before renaming.** If `target.backup` already exists, remove it first — otherwise `Rename-Item` fails.
- **Never re-add dead SMBIOS/build registry writes.** `SystemManufacturer`, `SystemProductName`, `BIOSVersion`, `CurrentBuild`, `CurrentBuildNumber` — WMI ignores them. See `IMPLEMENTATION_GUIDE.md §5`.
- **The dev machine is best-case (no Defender, Windows Update off, firewall off, cleaned temp).** Design for typical users: AV on, slower disks, locked files, low RAM. Never treat timings measured on this box as proof of acceptable performance — hedge public numbers as estimates (the asar-surgery CHANGELOG entry is the model to follow).

## PowerShell 5.1 compatibility

- Use `RandomNumberGenerator.Create()` + `.GetBytes()` — NOT `.Fill()` (which is .NET Core / .NET 5+ only).
- Never name a variable `$Input` — it's a reserved automatic variable in PS 5.1.
- Never use ternary operator `? :` — it's PS 7+ only. Use `if/else`.
- `ConvertFrom-Json` returns `PSCustomObject`, not `[hashtable]`. Normalize with `ConvertTo-Hashtable` before passing to `[hashtable]`-typed parameters.

## Batch (.bat) launcher rules

- Never use bare `(` / `)` in an `echo` (or any) line inside a parenthesized
  `if (...) (...)` block — CMD treats `)` as the block terminator even inside
  double quotes, aborting the whole script silently. Reword to avoid parens
  (e.g. `a separate window - leave it open`) or escape as `^( ^)`.
  (Bit us in `GHOST.bat` option [9]: the parent menu vanished instantly.)
- Never pass a bare `&` through a `call :Div` / `:Hdr` / `:Opt` label
  argument or a `:RunWith` note argument — those subroutines echo `%~N`
  UNQUOTED, so CMD splits on the `&` and executes the tail as a command.
  Reword labels with `+` or `-` (row style); direct `echo` lines escape as
  `^&`. The harness guards it (S0b static scan + a global no-CMD-error
  assertion inherited by every scenario).
  (Bit us in `GHOST.bat` ZCode rows [17]/[24] 2026-10-30: `call :Div "Sync
  & Chat Refresh"` printed `-- Sync` then `'Chat' is not recognized...`;
  reworded to `Sync + Chat Refresh`.)
- GUI apps that call `AttachConsole(ATTACH_PARENT_PROCESS)` (verified: ZCode)
  hijack the launching console with log floods. Launch them detached
  (`cmd /c start "" <exe>`, new window via `start` in the .bat) — never inline.
  (Bit us in `GHOST.bat` option [10]: the menu drowned in `[pid:*]` logs.)
- **Submenu ids are display-ordered (renumbered 2026-10-29).** Every submenu's
  local ids run strictly ascending 1..N in visual order, grouped by `:Div`
  sections — ZCode: Launch Clones [1]-[9] (Blue/Yellow/Green/Red/Orange,
  ALL, light worker, shortcuts, Primary) / Reset Clones [10]-[17] (Blue..Orange,
  Primary, Both, ALL SIX) / Sync + Chat Refresh [18]-[24] / Watchers +
  Diagnostics [25]-[27] / Maintenance [28]-[31] (patch, login helper,
  shortcuts remove, [31] gid 83 = the clone Task-Manager exe-identity
  rebuild — appended 2026-11-11 in display order, no renumber); AutoClaw2: Launch Clones [1]-[7]
  (Blue..Orange, ALL, shortcuts) / Sync + Chat Import [8]-[10] (Import MCPs
  gid 73, Chat inventory gid 75, Import chats gid 76 — the MCP watcher row is
  deferred to the follow-up PR and keeps its reserved gid 74) / Maintenance
  [11]-[13] (status, remove-shortcuts, [13] gid 78 = the window identity
  patch — colored taskbar buttons, 2026-11-06); Cline: Launch Clones [1]-[7]
  (Blue..Orange, ALL, shortcuts) / Maintenance [8]-[9]; OpenCode: Launch Clones
  [1]-[9] (Blue..Orange, ALL, [7] light worker gid 79, [8] login clone
  account gid 80 — 2026-11-07, ZCode LIGHT pattern; shortcuts shifted to
  [9]) / Maintenance [10]-[12] (patch, status, remove — 2026-10-31: shortcuts
  moved into Launch and the patch row into Maintenance, locals [7]/[8]
  swapped, gids unchanged). **Gids NEVER
  renumber** — specs, wiring history and repo-integrity cite them; a
  renumber touches only the submenu echo block + its resolver ladder. Add
  future rows in display order inside their section — never a higher id out
  of sequence (the .bat harness asserts ascending ids per submenu).
  **Row pattern (2026-11-03, supersedes the 2026-10-31 rule): the label
  carries the action + COLOR name ONLY** (`Reset Red clone` +
  `- survivors kept running`) — qualifiers live in the tail, never a
  `- descriptor` inside a label, and the frozen keys (Second..Sixth / c1..cN)
  are never user-visible in menu rows, window titles or script console
  output; they survive only in CLI params, dirs, AUMIDs and log filenames,
  and in identification lines as `Color (key)` / `Color / key`.
  **Naming scheme (2026-11-01 display unification):** the shortcut
  FILE names use the color vocabulary shared by all four suites —
  `<Suite> <Color>.lnk` (`ZCode Blue.lnk` .. `ZCode Orange.lnk`, matching the
  `ZCode <Color>` window titles); the pre-unification ordinal/cN names are
  LEGACY and every installer cleans them up on each run. The technical keys
  stay FROZEN: ZCode instance keys Second..Sixth (clone dirs `ZCode<Name>Home`
  / roaming `ZCode-<Name>`, AUMID suffixes `2..6` — the Primary carries the
  bare base), newer suites `c1..cN` (dirs `<Home>\cN`, AUMID `.cN`); window
  titles are app-driven and frozen. Alias map (position ↔ key ↔ display ↔
  FROZEN plumbing dirs): Second↔c1↔Blue `#066BCB`↔`ZCodeSecondHome` +
  `ZCode-Second`, Third↔c2↔Yellow `#D4AA10`↔`ZCodeThirdHome` + `ZCode-Third`,
  Fourth↔c3↔Green `#13826A`↔`ZCodeFourthHome` + `ZCode-Fourth`, Fifth↔c4↔Red
  `#CA0607`↔`ZCodeFifthHome` + `ZCode-Fifth`, Sixth↔c5↔Orange
  `#CB5D06`↔`ZCodeSixthHome` + `ZCode-Sixth`; the newer suites keep
  `ClineClonesHome\c1..c5` / `OpenCodeClonesHome\c1..c5` /
  `AutoClaw2ClonesHome\c1..c5`. **Directory names are FROZEN plumbing, NOT
  part of the display layer and never renamed** (2026-11-01 decision — a dir
  rename would orphan installed profiles; the alias map above bridges them to
  the color display vocabulary); `clone` is the unified docs term.
  ZCode renumber 2026-11-10 ("Launch ZCode Primary" gid 82 inserted as local
  [9]; gids unchanged): old→new [9]-[29] → [10]-[30] — resets [9,10,11,12,13,
  14,15,16]→[10,11,12,13,14,15,16,17], sync [17,18,19,20,21,22,23]→
  [18,19,20,21,22,23,24], watchers [24,25,26]→[25,26,27], maintenance
  [27,28,29]→[28,29,30]; [1]-[8] unchanged. gid 82 = the Primary launcher
  (src/windows/launch_zcode_primary.ps1, explorer spawn = never elevated).
  Old→new for citations written before 2026-10-29:
  ZCode launches [1,3,4,18,22]→[1,2,3,4,5], ALL [5]→[6], light [27]→[7],
  shortcuts [2]→[8], resets [6,8,9,19,23,21,7,10]→
  [9,10,11,12,13,14,15,16], sync [20,24]→[17,18], MCP watcher [25,26]→[19,20],
  chats [13,15,14]→[21,22,23], watchers [11,16,17]→[24,25,26], patch [12]→[27];
  Cline [3,4,6,7,5,2]→[2,3,4,5,6,7]; OpenCode 2026-10-31 patch [7]→[8],
  shortcuts [8]→[7]. (The AutoClaw v1.20 rows were not renumbered — they
  were retired outright the same day; see the AutoClaw2 rewiring entry.)

## Multi-instance conventions (ZCode: Primary + 5 clones)

- Layout: Primary (default profile) + clones **Second** (blue), **Third**
  (yellow), **Fourth** (green), **Fifth** (red, added 2026-10-17), **Sixth**
  (orange, added 2026-10-24). Clone
  homes: `%USERPROFILE%\ZCodeSecondHome` /
  `ZCodeThirdHome` / `ZCodeFourthHome` / `ZCodeFifthHome` / `ZCodeSixthHome`;
  clone roaming:
  `%APPDATA%\ZCode-Second`
  / `ZCode-Third` / `ZCode-Fourth` / `ZCode-Fifth` / `ZCode-Sixth`; AUMID suffixes
  `2`/`3`/`4`/`5`/`6`. The Second row
  is FROZEN (never rename its dirs — an installed profile must keep working);
  the 2026-11-01 display unification deliberately stopped at the shortcut/
  title layer and left every dir name untouched for the same reason.
- Isolation lever is **env vars, never CLI flags**: the app overwrites
  `--user-data-dir` via `app.setPath`, so `ZCODE_DATA_BASE_DIR` /
  `ZCODE_DESKTOP_USER_DATA_DIR` / `ZCODE_DESKTOP_SESSION_DATA_DIR` /
  `ZCODE_DESKTOP_HOME_DIR` / `HOME` are the only working mechanism.
- All instances share **ONE CLI session store** at
  `%USERPROFILE%\.zcode\cli\db\db.sqlite` — the CLI resolves `~` via the real
  user profile and the `HOME` override never reaches it on Windows (verified
  2026-09-23). Only `.zcode\v2\tasks-index.sqlite` (sidebar index) is
  per-instance. The app-server seeds its index baseline at spawn with no
  snapshot backfill, so cross-instance chat visibility = recycle the target
  instance's app-server (ZCode submenu [22]; Second-only today). Never copy session rows
  between homes — a clone's own `db.sqlite` copy is dead storage nothing reads.
  See `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md`.
- User-scope config is the OPPOSITE: each clone reads its OWN
  `<CloneHome>\.zcode\cli\config.json` (the HOME override reaches the app's
  config resolution — verified 2026-10-17), so MCP/plugin/skill edits made in
  the Primary never reach the clones and the one-time seed copies drift.
  `tools/sync_zcode_assets.ps1` (ZCode submenu [18]; launcher step 2d) syncs
  MCP server DEFINITIONS from the Primary (per-clone on/off toggles stay
  local), replaces stale `.zcode\skills` copies with a shared `.agents`
  junction, and mirrors the plugin cache — definitions only; never session
  rows, never the Primary's files. MCP sync needs NO running-instance skip
  (verified 2026-10-27: the app holds no handle on config.json, NEVER
  rewrites it on exit — the old "may rewrite on exit" rationale was a
  citation-loop myth, never an observed event — and reads mcp.servers at
  every app-server spawn, one per new session): `sync -McpOnly` is safe
  against RUNNING instances and `tools/watch_zcode_mcp_sync.ps1` (ZCode
  [19]/[20], gids 68/69; [18] gid 67 = one-shot `-McpOnly`) keeps every
  clone converged on every Primary change; a synced definition lands on
  each instance's next chat with no restart. `tools/zcode_mcp_merge.ps1`
  is the single (unit-tested) copy of the merge logic. Install-and-forget:
  launcher step 2e (2026-10-27) ensures the MCP sync + taskbar identity
  watchers are RUNNING (hidden) and installs their Startup .lnks once on
  every clone launch — mutex-probe guard, best-effort, never blocks the
  launch; the captcha watchdog stays manual ([24]).
- Classify mains by **bare-exe CommandLine** (quoted or unquoted full path only);
  `--type` filtering alone misclassifies helpers as helpers. Empty CommandLine is
  a WMI race — keep as candidate, subtree walk still classifies correctly.
  Subtree marker strings per clone = its roaming dir name (`ZCode-Second`…) or
  home dir name (`ZCodeSecondHome`…); unmatched mains are Primary. Since the
  2026-11-11 Task-Manager identity copies there is a STRONGER first signal: a
  main whose command line is the clone's exe copy (`ZCode-Blue.exe` → Second …)
  IS that clone outright — deterministic even mid-splash — and every ZCode
  process enumeration must cover the whole copy family (`Name LIKE 'ZCode%'` /
  `'ZCode*'`); see the patch_zcode_exe_identity entry in tools/ for the rule.
- Task Manager identity (2026-11-11): TM's background-process groups take
  name + icon from the executable IMAGE (icon resource + VERSIONINFO
  FileDescription), NOT from AUMID shortcuts or window properties — the whole
  taskbar stack never reached them. Fix = per-clone exe copies
  (`ZCode-<Color>.exe` in the install dir, launcher step 2f, ZCode [31] / gid
  83) + copy-family classifier widening in 8 scripts. Copies lose
  Authenticode (SmartScreen caveat, docs hedged); the Primary stays stock;
  resident watchers keep old code until restarted (relaunch ZCode [26] or any
  clone launch's step 2e).
- One Telegram bot token means ONE polling instance. Never clone an enabled bot into
  a clone profile (HTTP 409 + random cross-account billing). Launcher enforces
  Primary-only via per-home marker-guarded disable (`.telegram-routed` in each
  clone home); a deliberate re-enable is never reverted.
- Both/All-mode resets generate **independent ID sets per child** — never
  duplicate. `Both` = Secondary+Primary (back-compat); `All` = Third+Fourth+
  Fifth+Sixth+Secondary+Primary (clones first, Primary last with the Qoder steps).
- Backups, watchdog probes and final validation are scoped **per-target**.
- Clone visual identity rides on `ZCODE_ICON_DIR` + `ZCODE_AUMID_SUFFIX` +
  `ZCODE_ACCENT_HEX` + `ZCODE_INSTANCE_NAME` (branded window/tray icon +
  separate taskbar button + accent recolor + "ZCode <Color>" window title).
  These only work because `tools/patch_zcode_icon_override.ps1` (engine v9,
  asar surgery) patched the installed `app.asar` — an app update silently reverts them; re-run
  the patch (ZCode submenu [28]) whenever a clone loses its look. Primary never sets any
  of the four vars. The patched main derives a `--zcode-blue` flag
  (additionalArguments → contextBridge `__ZCODE_BLUE__`) that switches the
  in-app recolor on, with the color taken from `__ZCODE_ACCENT__` (fallback
  `#066BCB`) and the title from `__ZCODE_TITLE__`: recolors the clone's startup
  splash + sidebar logos, renames its window title to "ZCode Blue"/"ZCode
  Yellow"/"ZCode Green" (taskbar/Alt-Tab/pins — prevents pin collisions with
  the Primary's ZCode.lnk: pinning from a window titled "ZCode" makes Windows
  rewrite ZCode.lnk with the clone's AUMID, which stole the Primary's Start pin
  and broke taskbar icon resolution), and disables the clone's auto-updater
  (`ZCODE_ICON_DIR` guard) so it can never wipe the shared patch via
  quitAndInstall. Launch clones ONLY via their "ZCode Blue/Yellow/Green/Red/Orange"
  shortcuts / the launcher — a bare ZCode.exe launch gets the Primary's
  profile, AUMID and button.
- Do NOT run ZCode instances elevated (verified 2026-09-24: Primary launched
  from explorer.exe still ran elevated — its shortcut had "Run as
  administrator" set; clones inherit elevation when launched from an elevated
  GHOST menu via [4]). Windows UIPI silently strips drop data from a
  non-elevated Explorer into a high-IL window: the "Drop to add attachments"
  overlay still lights (window-level dragover) but `dataTransfer.files`
  arrives empty and the drop handler no-ops — while the "+" picker works
  (native dialog inside the process). Fix: clear the shortcut's
  Compatibility-tab admin flag and launch instances non-elevated; launch-only
  menu entries (launch-only gids [10]/[16]/[17]/[18]) do not need the menu itself elevated.
- Taskbar identity is stamped at the WINDOW level by the launcher
  (launch_zcode_second_instance.ps1 step [4]): after launch it resolves the
  clone's main window by its v6 title and writes System.AppUserModel.ID =
  `dev.zcode.app.<suffix>` into the window property store (top shell
  precedence, regroups live; base kept in sync with
  install_zcode_second_shortcuts.ps1). Reason (verified 2026-09-24): the
  app's process-explicit setAppUserModelId left Primary+Second merged in one
  taskbar button despite a correct env block (ZCODE_AUMID_SUFFIX=2 read back
  from the live process) and a correct patched expression, while
  Third/Fourth separated. The launcher targets the window by TITLE, never by
  the fresh PID alone — the single-instance focus path spawns a transient
  relauncher process whose brief window otherwise eats the stamp
  (false-positive read-back on a doomed hwnd); it re-stamps on main-window
  handle change and final-verifies with an independent read, then KICKS the
  shell group once (brief `dev.zcode.app.<n>.kick` identity, then the final
  one — the shell does not rebuild a pre-grouped window's group on a plain
  stamp, and a stale group keeps the WRONG icon: verified 2026-09-26, a
  green clone kept the Primary's icon until an Explorer refresh). Launcher
  must run at the same or higher integrity level as the clone (UIPI).
- Launcher stamping alone was NOT enough (verified 2026-09-24 later the same
  day): the merge MOVED to Primary+Yellow — any window relying on the app's
  process-explicit identity can merge with any other at any time. Final fix =
  `tools/watch_zcode_taskbar.ps1` (ZCode submenu [26], resident + autostart): polls all
  four instances every 5s and re-stamps Primary (`dev.zcode.app`) AND clones
  whenever a window is missing/wrong — heals new/splash-swapped windows
  automatically (live-proven: stamped a freshly launched Primary within its
  first pass). Every stamp is a KICK (`.kick` → final) and first-seen
  windows get one kick even when their store is already correct — the
  stale-group/stale-icon guard (verified 2026-09-26). Ambiguous titles
  (patch missing, all "ZCode") are skipped loudly, never guessed.
- Watcher classification is by PROCESS MARKERS first, titles only as the
  WMI-failure fallback (verified 2026-09-24, green-clone default-icon bug): a
  clone's window is titled plain "ZCode" during the splash phase, so the old
  title-only Primary row claimed it whenever the clone launched while no
  other instance ran (with Primary running the same window was merely
  "ambiguous") — it stamped `dev.zcode.app` on the clone, and when the
  launcher's title-resolve loop (then 15s) had already expired on the slow
  cold start, the window held no window-level identity and the taskbar button
  fell back to the default icon. The watcher now takes ONE Win32_Process
  snapshot per pass, walks each window's process tree to its root ZCode.exe
  and matches the clone markers (roaming/home dir names in child
  `--user-data-dir` cmdlines — same markers as the launcher rule above),
  stamping the correct identity even mid-splash; a clone v6-title overrides a
  spurious "Primary" marker read, and unknown pids fall back to the v6-title
  rules. The launcher's title-resolve/stamp loops were extended to 60s/30s
  for the same reason.
- Start-menu / Desktop `ZCode.lnk` hijack repair & self-heal (verified
  2026-09-28): pinning a clone window or Windows taskbar pin maintenance can
  rewrite the Primary's `ZCode.lnk` with a clone AUMID (e.g. `dev.zcode.app.4`)
  and simultaneously wipe its `IconLocation` (`",0"`). When the affected clone
  subsequently runs alone, the shell resolves its AUMID to the icon-less
  Primary shortcut and falls back to the exe's default icon. Fix:
  `tools/install_zcode_second_shortcuts.ps1 -RepairPrimaryAumid` strips clone
  suffixes and restores the icon location back to `<ZCode.exe>,0` across
  Desktop and Start Menu locations. The resident watcher
  (`tools/watch_zcode_taskbar.ps1`) runs a periodic (~5m, every 60 passes)
  read-only check and automatically invokes the repair on hijack detection, or
  on demand via `-CheckPrimaryHijack`. 2026-11-11 lesson (live-verified): the
  pin rewrite can ALSO drift the lnk's TARGET onto a per-color exe copy
  (`ZCode-Orange.exe`) — the step-2f exe copies made the pinned clone window's
  process exe colored, and the old repair kept the drifted target ("the lnk's
  own target wins") then set the icon FROM it, permanently blessing the
  clone's orange icon behind a clean AUMID the AUMID-only guard called
  healthy. The repair now restores target → stock `ZCode.exe` FIRST (shared
  pure core `tools/zcode_primary_lnk_lib.ps1`, unit-tested), resolves the
  icon from the stock exe, and the guard detects all three shapes (AUMID
  suffix, clone-exe target, wrong/wiped icon) — target/icon checks stay
  silent when no stock exe resolves, so the guard never demands a repair it
  cannot complete. Diagnostic rule: read lnk AUMIDs via
  `Shell.Application` `ExtendedProperty('System.AppUserModel.ID')` — decoding
  the whole .lnk as UTF-16 and regexing MISALIGNS on odd byte offsets and
  reports false `<none>` (cost a false "clone shortcuts lost their AUMID"
  conclusion on 2026-09-26). A silent watcher log with healthy pass CPU is
  NORMAL (stores correct) — not a zombie.
- A "frozen" ZCode window (drags, content dead) is a RENDERER DEATH, not a
  hang, and the splash-then-close relaunch is a post-crash quit path, not a
  lock (verified 2026-09-25): Primary and Second renderers died with
  `render-process-gone reason:"oom"` in the same second (12:54:06), Fourth
  had died that morning (09:01), and the archived dump annotation
  `v8-oom-last-os-error: 1455` = ERROR_COMMITMENT_LIMIT — the Windows commit
  limit (RAM ~16GB + pagefile ~16GB) was exhausted with 4 instances running
  (msedge/git WER dumps the same minute corroborate; JS heap was only
  ~478MB, so it is OS commit starvation, not an app leak). After the
  tray-click quit, launching the instance again is safe and works. Diagnosis:
  ZCode submenu [27] (`tools/diagnose_zcode_freeze.ps1`). Mitigation: larger
  pagefile / fewer concurrent instances. Ruled out that day: GPU caches, the
  icon asar patch, the captcha watchdog (idle since 09-17), db.sqlite locks.
- A chat section crashing with "Minified React error #185" (the app's
  "This section ran into a problem" boundary panel) is an APP-INTERNAL React
  update-depth bug, content-triggered by huge sessions — NOT the asar patch
  (the bidi injection is preload-only: one stylesheet + a childList-only
  dir="auto" MutationObserver, no React-state path, no observer feedback;
  verified 2026-11-10, capture dated Nov 9) and it writes NOTHING to disk
  (the renderer survives — no render-process-gone, no dump, no diagnostics
  file; the UI's "View component stack" capture is the only evidence).
  RECURRED 2026-11-11 on a second session + different account and persists
  across the 2026-11-10 update (not fixed upstream in latest). Source-mined
  from the vendored checkout + upstream v3.17.2: the panel = the app's
  workspace-chat ScopedErrorBoundary around the WHOLE chat pane
  (ErrorBoundary.tsx / WorkspaceShellLayout.tsx); the pptxElementReference
  chunk maps to packages/ui/src/lib/pptxElementReference.ts + its React
  importers; the reset-effect suspect (usePptxElementReferences.ts, dup in
  useWebElementContexts.ts) is benign through v3.17.2 (stable string deps)
  — the regression lives in the v3.15.x-3.17.2 ~190-file v4 chat rewrite;
  only the live component stack pins it. Remedies + ZCODE_BIDI_OFF=1
  discrimination test: docs/troubleshooting.md.
- Reset-menu hardening shipped 2026-10-23 (PARTIAL: the reset_zcode.ps1 v1.5
  script-side items are PENDING — blocked by a workspace write-guard false
  positive on [6b]'s apiKey-blanking assignment; user deferred — see
  docs/ZCODE_RESET_EDGE_CASES_PLAN.md). Shipped: GHOST.bat confirms before the
  destructive multi-instance resets (gids 12 Both / 21 All-five) via
  `:ConfirmReset` (`choice` reads the console, so chains and the .bat harness
  are unaffected); every reset_zcode dispatch goes through `:RunZcodeReset`,
  which prints the post-reset relaunch warning (bare ZCode.exe = Primary
  profile); ZCode [6] label pluralized. The captcha watchdog snapshots running
  instances by PROCESS MARKERS before its kill and relaunches clones via the
  launcher, Primary bare — the old blanket bare ZCode.exe relaunch repopulated
  only the Primary profile and silently voided every "survivors kept running"
  claim. STILL OPEN (plan not applied): clone resets do NOT scrub the shared
  `~\.zcode\cli\db\db.sqlite`; single-target clone runs still execute the
  shared Qoder steps (reset_zcode.ps1's "clone targets never touch Qoder"
  comment is still aspirational); backups are still best-effort; no -DryRun;
  no Python preflight; [27] purge still deletes prior restore scripts.
- Sixth menu wiring (2026-10-24): ZCode submenu [22] "Launch Sixth
  instance" → gid 64 (`launch_zcode_second_instance.ps1 -Instance Sixth`)
  and [23] "Reset Sixth instance - Orange" → gid 65
  (`reset_zcode.ps1 -Target Sixth`); `:DispatchOne` cases 64/65 sit
  between gids 43 and 44 and gid 63 is unused.
- MCP sync menu wiring (2026-10-27): ZCode submenu [24] "Sync MCPs to all
  clones" → gid 67 (`sync_zcode_assets.ps1 -McpOnly -Target All`), [25]
  "MCP sync watcher" → gid 68 (`:Detached watch_zcode_mcp_sync.ps1`),
  [26] "Sync MCPs + apply live now" → gid 69
  (`watch_zcode_mcp_sync.ps1 -RunOnce -ApplyLive -Target All`); cases
  67-69 sit after gid 65 (before the Cline block); dispatch header range
  widened to 1-69 (63 still unused); repo-integrity asserts the range and
  the .bat harness scenario R asserts the three rows render.
- Light mode + RAM guard (2026-10-28, spike-verified — docs/ZCODE_LIGHT_MODE.md):
  the commit limit (16 GB RAM + pagefile) is the hard ceiling that produced the
  2026-09-25 renderer-OOM freeze, and the Start Plan provider throttles above
  ~3 concurrent instances anyway, so `launch_zcode_second_instance.ps1` now
  carries a soft `-MaxConcurrent 3` guard (live commit numbers + confirm;
  non-interactive callers warn+continue; hidden-console shortcut launches get
  a Yes/No dialog — fixed 2026-11-01: the old invisible Read-Host hung the
  launch so the app looked dead; focus-relaunches never prompt; an
  experimental `-LowRam` passes `--disable-gpu`) and ZCode [7] launches
  `launch_zcode_cli_light.ps1` — a per-account HEADLESS worker (~0.9 GB vs
  ~1.6 GB+). Verified limits recorded in the launcher header: standalone TUI
  impossible (@zcode/tui is asar-locked) and headless runs default to the free
  opencode-zen model until a one-time `zcode login zai` per clone home (the
  working plan provider namespace is `account:zai-start-plan`, discovered from
  the Primary db's model_usage). **2026-10-31: CLI 0.17.1 broke every
  plain-node launch** (`无法定位 CLI ZCode Built-in Provider Config` — the
  bundle's builtin-config fallback climbs a dev-monorepo path from
  `process.argv[1]` and never finds the packaged
  `resources\config\provider\zcode-builtin.json`; the `nbs()` argv gate demands
  it for `-p`/`app-server`/`login`) — fixed with the FIFTH env lever
  `ZCODE_BUILTIN_PROVIDER_CONFIG_FILE` in the light launcher AND the T3
  bridge's `spawnAppServer` (`tools/t3_bridge_lib.mjs`
  resolveBuiltinProviderConfig: bundled copy first, newest
  `<home>\.zcode\v2\runtime\provider` runtime-cache copy fallback, clear
  fail-fast when neither exists; desktop children are immune — the app
  injects the env into its own children). T3 Code (pingdotgg) — the local support path
  is SPECCED AND PHASES A-B IMPLEMENTED 2026-10-28/29 (docs/T3_LOCAL_SUPPORT.md +
  docs/T3_ZCODE_BRIDGE_SPEC.md §8 addendum; monorepo study clone at ..\t3code,
  1016 MB, never committed here): `tools/t3_zcode_bridge.mjs` is the ACP v1 ⇄
  ZCode Protocol NDJSON translator run as a T3 "Local ACP command" (both sides
  are NDJSON; T3's v1/v2 negotiation is response-SHAPE based per effect-acp
  client.ts so the v1-shaped initialize pins generation 1; fs/terminal
  capabilities stay unadvertised — ZCode executes its own tools), no T3 fork
  needed. `tools/t3_bridge_probe.mjs` + `tools/t3_bridge_fake_client.mjs`
  (fake ACP client, phase-B acceptance) + tests/t3_bridge.Tests.ps1 (Pester
  56/56 incl. the live-gated run). Wire truths in the spec §8: workspace =
  `{workspacePath, workspaceKey}` object, session/send ASYNC,
  session/subscribe REQUIRED, state.updated carries the authoritative
  revision, requestRuntimePreferences mandatory (decline aborts create),
  permission answers = the chosen option's own MF decision object, and the
  plan provider materializes ONLY via standalone `zcode login zai`
  (refreshRegistry does not); every free zen model rejected upstream on
  2026-10-29 so text-delta paths are bundle-schema-derived. Upstream PRs
  (ACP Registry entry first, a full driver only if forced — replay-fixture
  bar in docs/internals/adding-a-provider.md) are gated on the spec's
  Phase-E live acceptance. **Phases D-E LANDED 2026-10-29 evening**: models
  ride the session/new TOP-LEVEL `models` field (generic acpRegistry path;
  initialize `_meta.modelState` is Grok-only), `session/set_model` unpacks
  `"providerId/modelId[/level]"`, `launch_zcode_cli_light.ps1 -Login`
  (GHOST.bat ZCode [29], gid 71) does the per-home `zcode login zai` with
  verify-after, T3 Code v0.1.4 is INSTALLED (winget T3Tools.T3Code,
  `~/.t3/userdata/settings.json` holds the five pre-seeded acpRegistry
  instances — edit only with the app closed), and the user-supervised
  live-acceptance runbook lives in spec §9.2.

## Multi-instance conventions (AutoClaw v1.20: SUNSET — superseded by AutoClaw2)

The AutoClaw v1.20 suite (Primary + inst1..4 clones, `C:\Program Files\AutoClaw`
+ `~\.openclaw-autoclaw`) was RETIRED: the app was uninstalled from the dev
host 2026-10-29 (AutoClaw2 v2.1.1 "zwork" is the active successor — its own
section above in the AutoClaw2 suite docs), and the suite's scripts
(`launch_autoclaw_clone.ps1`, `reset_autoclaw.ps1`, `patch_autoclaw_ports.ps1`
+ engine v12, `install_autoclaw_clone_shortcuts.ps1`), v1 branding dirs and
`docs/AUTOCLAW_CLONES_SPEC.md` were removed from the tracked repo
2026-10-31. Nothing in the current tree can run them. Recover from git
history (last full presence: commit 874346f and its descendants) or the
gitignored local copy at `archive/autoclaw-v1.20/` if a v1.20 host ever
needs the machinery again. The cross-suite lessons that outlived it — one
credential = one instance, classify by process markers never titles,
sequential non-elevated launches, UIPI drag-drop, the sign-in-gate pattern —
are already stated in the live suites' sections where they apply.

## Multi-instance conventions (Cline: Primary + 5 clones)

- Layout: `%USERPROFILE%\ClineClonesHome\c1..c5\` (each = `CLINE_DIR`,
  whole state tree incl. `data\` db/locks/logs/settings/secrets) +
  `cN\webview\` (`WEBVIEW2_USER_DATA_FOLDER`, the accounts.cline.app web
  login profile — stock lives at `%LOCALAPPDATA%\bot.cline.app`). Primary
  `~\.cline` is NEVER written by any clone script. Spec:
  `docs/CLINE_CLONES_SPEC.md` (all §5 provenance live-verified 2026-10-24).
- The app is **Tauri 2.11.1 (Rust + wry/WebView2), NOT Electron — no asar,
  nothing patchable**; asInvoker (env survives launch). Its
  tauri-plugin-single-instance guard = fixed-key mutex `bot.cline.app-sim`
  (session-Local namespace) + hidden WM_COPYDATA window (class
  `bot.cline.app-sic`, title `bot.cline.app-siw`); **a second copy only
  exits when FindWindowW FINDS that window** — the launcher renames the
  title to `bot.cline.app-siw.neutralized` (SetWindowTextW cross-process,
  same-IL works) pre+post every launch with verify, so N copies coexist
  (3 verified live). A stock Cline keeps working beside clones for the
  same reason; a stock boot that recreates the window is re-neutralized
  by the next launcher run (pre-launch step). If a future app update
  changes the identifier or the -sim/-sic/-siw names, neutralization
  stops matching → stock single-instance behavior returns (clones exit
  while another runs); re-derive from the new exe per spec §3.2.
- Because the app-level guard is neutralized, **the launcher enforces
  per-clone single-instance itself**: ABORT (exit 1) when the clone's own
  hub lock `<CLINE_DIR>\data\locks\hub\production.json.instance.lock` is
  held (exclusive-open probe; two writers on one SQLite/hub tree is the
  failure this prevents). Never bypass with a bare cline-app.exe launch —
  it would open the PRIMARY profile anyway (no env).
- Ports are a FIXED per-clone table (never the stock defaults, never the
  stock hub probe range): c1..c5 = hub 25471..25475 / sidecar 3131..3135;
  stock Primary keeps 25463..25466 + 3126. `CLINE_HUB_PORT` /
  `CLINE_SIDECAR_PORT` honored live (clone cline-cli children observed
  owning exactly their assigned ports).
- Identity: machineId = HKLM MachineGuid via `@cline/core`
  getMachineId-win (shared, GHOST ground truth #1); account identity only
  in the state tree (`data\secrets.json` clineAccountId + userInfo,
  `data\settings\providers.json` OAuth). Fresh clone = no secrets at all —
  ONE manual sign-in per clone (one credential = one instance).
- NO seeding, NO reset script in this suite (developer decision
  2026-10-24): clone reset = stop instance + delete
  `ClineClonesHome\<cN>` + launch again; Primary reset out of scope.
- NO patching anywhere → app updates break nothing (launchers only set
  env + rename a window); `CLINE_NO_AUTO_UPDATE` deliberately NOT set.
- Taskbar identity: shortcut-AUMIDs-only (DEGRADED, developer decision
  2026-10-24): pins distinct via `bot.cline.app.c1..c5` + per-color icons
  (`tools\cline-<color>-branding\tray_icon.ico`); RUNNING windows share
  the base identity (identical titles "Cline v0.0.48") — no patchable
  surface, window-stamp helper is a future option (ZCode pattern).
- Launch SEQUENTIALLY, never in parallel (racing boots vs window
  creation can make a later launch exit), never elevated (UIPI). All via
  the launcher / "Cline cN" shortcuts — a bare cline-app.exe always
  opens the PRIMARY profile. GHOST.bat Cline submenu [1]-[9] (gids
  44-52).

## Multi-instance conventions (OpenCode desktop: Primary + 5 clones)

- Layout: `%USERPROFILE%\OpenCodeClonesHome\c1..c5\` (each = `desktop\`
  Electron userData + `session\` sessionData + `data\`/`config\`/`cache\`/
  `state\` = the four `XDG_*` homes). Primary = `%APPDATA%\ai.opencode.desktop`
  + `~\.local\share\opencode` + `~\.config\opencode` (holds LIVE provider
  API keys — never copied). Spec: `docs/OPENCODE_CLONES_SPEC.md`
  (implemented + LIVE-VERIFIED 2026-10-24/25).
- The app is **Electron (electron-builder NSIS), asInvoker** (2.0.32 shipped
  the suite; 2.2.5.0 live-patched 2026-11-01) — and
  UNLIKE AutoClaw2/Cline its packaged build has NO env lever for the
  userData: `OPENCODE_DESKTOP_TEST_ROOT` is unpackaged-only,
  `OPENCODE_TEST_ONBOARDING` rmSync-wipes its root every boot, and the
  channel map only has beta/prod. Isolation therefore needs the ONE-TIME
  **clone-home asar patch** (`tools/patch_opencode_clone_home.ps1` +
  `.mjs`, engine v4 — asar surgery since 2026-11-03; anchors re-derived
  2026-11-01 for the 2.2.5.0 bundle after
  the updater replaced app.asar wholesale on 2026-10-31): the argv flag
  `--opencode-clone-home=<dir>` slots into the app's OWN test-root read
  (the bootstrap `ue()` — was the `ye()` ternary tail in 2.0.32) →
  `userData=<home>\desktop`, `sessionData=<home>\session`, and the four
  `XDG_*` env vars set from the home's subdirs BEFORE the background-service
  spawn (the app's own redirection surface, read unconditionally in
  production). No flag = bit-for-bit stock. Backup + marker
  (`opencode-clone-home-patch.marker.json`,
  patchVersion) + `-Restore` + `node --check` + zero-site abort +
  update-recovery byte-probe with TWO tiers — CORE signatures
  (`__opencodeCloneHome`/`__opencodeCloneIdentity`/`--opencode-clone-home`,
  engine-stable) vs CURRENT (`--opencode-clone-id`): a core-only tree is
  an OLD-ENGINE patch and rebuilds from the marker's pristine backup
  (extracting the live tree lets the done-anchors skip — caught live
  during the v1→v2 upgrade). Plus the locked-asar IN-PLACE swap fallback
  (this box's IDE indexer held app.asar read-only WITHOUT share-delete
  for a whole session: delete blocked but WRITE shared → overwrite in
  place, allowed only with a verified pristine backup; locked unpacked
  dir kept-with-verify — the engine changes no unpacked bytes). An app
  update reverts the patch — the byte-probe re-patches automatically; run
  OpenCode [8] (or the launcher's abort message) after any manual update.
  Patch with OpenCode CLOSED.
- Single-instance = Chromium's userData-keyed lock (`requestSingleInstanceLock`
  with NO custom key, count=1) — per-clone homes coexist NATIVELY
  (AutoClaw2 model; live-verified: 4-5 clones + a user-launched stock
  Primary simultaneously). The launcher's running guard = the clone's own
  `desktop\lockfile` exclusive-open probe (held = running → inform +
  exit 0, relaunch focuses it).
- Taskbar identity rides the same patch: the app's SINGLE
  `setAppUserModelId` call site (count=1) is wrapped to append
  `.<aumidSuffix>` + an app-level `browser-window-created` listener
  stamps every window's WINDOW-level AUMID via `setAppDetails` at
  creation, sets the per-color window icon and forces the
  "OpenCode <Color>" title. **Identity rides PURE ARGV (the argv-only
  finding landed in engine v2, live 2026-10-24, and carries through v3):
  the main bundle `out/main/index.js` is ESM — `require` is
  undefined — so v1's fs-based identity json resolver silently no-oped
  (caught error → null → stock identity; isolation unaffected, caught by
  the launcher's title check). The launcher passes
  `--opencode-clone-id/-title/-icon` alongside the home flag; the
  injected parser never touches fs. NOTE: this app has NO
  `new X.BrowserWindow(` sites (imports aliased `BrowserWindow as L/J/i`)
  — the AutoClaw-v12 constructor-subclass wrap does NOT apply; the
  browser-window-created event is the equivalent hook. Live-verified:
  "OpenCode Blue"/"OpenCode Orange" window titles. Shortcuts carry
  matching AUMIDs `ai.opencode.desktop.c1..c5` +
  `tools\opencode-{blue,yellow,green,red,orange}-branding\tray_icon.ico`
  (orange = generated PLACEHOLDER 2026-10-24, blue master +180° hue-rotate
  via make_clone_icon.ps1 — drop developer renders and re-run the
  shortcuts installer). Primary-hijack repair:
  `install_opencode_clone_shortcuts.ps1 -RepairPrimaryAumid`.
- Identity: everything identity-bearing is per-clone automatically once
  userData + the XDG data home differ (`gh\device-id`, `.updaterId`,
  `windowIds`, Chromium stores, `auth.json`); fresh clone = anonymous →
  ONE manual sign-in per clone. `MachineGuid` shared (ground truth #1).
  No seeding, NO reset script — clone reset = stop instance + delete
  `OpenCodeClonesHome\<cN>` + launch again; Primary reset stays IDE
  Resets [8].
- NO seeding and NO credential copying ever: the Primary's
  `~\.config\opencode\opencode.jsonc` holds live API keys and is never
  read by clone scripts (a definitions-only sync is future work).
  Primary isolation live-proven: snapshot diff (path+mtime+size, 3 trees)
  across the whole clone session showed only the live user session's own
  artifacts — 0 clone-breach signatures.
- Windows updater: STAGES new versions silently (2.1.4 sat in pending\)
  but never installs on Windows (autoInstallOnAppQuit darwin-only in the
  asar; live-observed) — no updater-disable needed; clones stay current
  with the installed app. Service ports are EPHEMERAL per instance
  (each clone's v2 CLI service bound its own OS-assigned port, e.g. 45278
  — no fixed-port collision possible); the `opencode-cli.exe` service
  child can outlive a closed main (kill it when stopping a clone).
- Launch SEQUENTIALLY, never in parallel, never elevated (UIPI; the app
  itself is asInvoker). All via the launcher / "OpenCode cN" shortcuts —
  a bare OpenCode.exe (or protocol launch) always opens the PRIMARY
  profile. GHOST.bat OpenCode submenu [1]-[12] (gids 53-62 + 79/80).
- Light worker (2026-11-07, spike-verified + LIVE-ACCEPTED — spec §3.9):
  OpenCode submenu [7] gid 79 = `src/windows/launch_opencode_cli_light.ps1`
  runs the v2 CLI (`<install>\resources\opencode-cli.exe`) headless on a
  clone's own state — the four XDG env vars are the ONLY state levers
  (verified via `debug paths`: data/cache/config/state all follow XDG_*;
  `home` stays the real profile, so unlike ZCode light NO HOME/USERPROFILE
  redirect). Modes: interactive prompt loop (default), `-Prompt` one-shot
  (`run`), `-Server` foreground `serve [--port]`, `-StopService` (kills the
  clone's background service — the §3.8 orphan), `-Login` (submenu [8] gid
  80, one-time `auth login` per clone home; verify-after =
  `<data>\opencode\auth.json` non-{}). Anonymous homes WORK but run the
  FREE model (iceman-free) — the OpenCode analogue of the opencode-zen
  caveat; machine-env creds in `auth list` (source "environment") are NOT
  logins. `run` auto-starts the clone's background service; `service.json`
  in the clone's config home is the registry. Two live-acceptance-caught
  launcher truths (both fixed + test-pinned): PowerShell children inherit a
  STALE `$env:PWD` and the CLI resolves its project from it (must set
  `$env:PWD = $Cwd`), and assigning the launcher function's output swallows
  the CLI's entire stdout (bare statement + `$LASTEXITCODE` only); scripted
  consumers must use `-Json` (`--format json` — the default renderer's
  final answer is not guaranteed on non-TTY stdout). Acceptance done:
  one-shot `-Json` turn, single + dual-instance serve coexistence,
  orphan-free shutdown; `-Login` browser flow remains user-supervised
  (§3.9.1).
- T3 Code wiring (2026-11-07, spec §3.10): the light worker gained `-Acp`
  (foreground `opencode acp` on stdio; handshake live-verified —
  protocolVersion 1 + a real session/new under c2's env), and
  `tools/install_t3_opencode_instances.ps1` seeds five `acpRegistry`
  instances (`opencode-c1..c5`, displayName "OpenCode <Color>", accents =
  the four staged suite colors + orange placeholder #C8620A) into
  `~/.t3/userdata/settings.json` — commandArgs launch OUR launcher
  (`powershell -File ... -Instance cN -Acp`) so isolation rides the script's
  XDG levers with NO T3 env field (same shape as the ZCode bridge entries);
  backup-first + merge-never-overwrite + verify-after + idempotent +
  `-Remove` + a loud running-T3 guard. Pester 8/8 on TEMP fixtures. T3-UI
  acceptance user-supervised.

## App cloning playbook (any new app)

When asked to clone ANY app into multi-instance ("clone <app>"), follow
`docs/APP_CLONING_PLAYBOOK.md` — phases 0–10, the identity suite
(MANDATORY vs DEGRADABLE features + the never-silently-degrade rule), the
automation contract (what the agent does unasked vs the Developer's only
touchpoints), and the fixed final-report format. Fill
`docs/APP_CLONING_INTAKE_TEMPLATE.md` first (developer values or documented
defaults — every default is reported). `docs/APP_CLONING_EDGE_CASES.md` is
normative: its EC-xx handling rules apply to every suite. Icon policy
(2026-10-15): developer-supplied icons are wired as-is; missing icons
default to IMPROVISE (generate tinted placeholder variants from the stock
icon) + report, with stock-default + report as the allowed fallback — both
branches are ALWAYS reported, never silent (playbook §5). Colors are
developer-specified per clone (defaults: the ZCode blue/yellow/green
palette). Current suites: ZCode (gold standard, full identity) and AutoClaw2
(2026-10-23, c1..c5, env-lever-only; window-level taskbar identity added
2026-11-06 via the unpacked main.cjs identity patch — see
docs/AUTOCLAW2_CLONES_SPEC.md §7) and Cline
(2026-10-24, c1..c5, env levers + single-instance window neutralization,
no patching — its spec documents the Tauri guard anatomy). OpenCode
desktop (2026-10-24, c1..c5, clone-home asar patch — packaged builds
hardcode userData so the patch feeds the app's own TEST_ROOT/XDG
redirection from an argv flag; native per-userData single-instance lock;
single setAppUserModelId site wrapped + browser-window-created stamper
with argv identity (ESM main); LIVE-VERIFIED 2026-10-24/25 — coexistence,
ephemeral service ports, Primary snapshot diff = 0 clone-attributable
changes; spec docs/OPENCODE_CLONES_SPEC.md). The older AutoClaw v1.20
suite (shortcut AUMIDs + per-clone icons + taskbar identity v2 via patch
engine v12) was RETIRED 2026-10-31 with the v1.20 app — its spec and
scripts live in git history + archive/autoclaw-v1.20/ (see the sunset
note in the AutoClaw conventions section).

## Desktop launcher (GHOST.exe)

- The desktop app is a THIN WinForms hub over the SAME scripts GHOST.bat
  dispatches to — every action spawns powershell.exe in its own console
  window, so all interactive prompts keep working. No script logic lives in
  the exe.
- Sources: `src/desktop/GhostHub.cs` (single file, C# 5 ONLY — the in-box
  `Framework64\v4.0.30319` csc.exe rejects newer syntax; no SDK/NuGet),
  `menu.json` (runtime-loaded menu data) and `app.manifest`
  (requireAdministrator + DPI). Build via `tools/build_ghost_exe.ps1`
  (Maintenance [5] / gid 81) — version stamped from the first released
  `## [X.Y.Z]` in CHANGELOG.md, verify-after on compile exit code + PE magic
  + size floor + ProductVersion == CHANGELOG + requireAdministrator-in-bytes
  + SHA256.
- GHOST.exe is gitignored (like `*.lnk`) and MUST stay next to GHOST.bat —
  it resolves the repo root from its own location and reads
  `src\desktop\menu.json` at runtime (menu edits need NO rebuild; engine
  edits do). update_ghost.ps1's add/overwrite-only sync never deletes it, so
  a stale build warns in the header (exe version vs CHANGELOG version).
- Menu parity is TEST-ENFORCED (`tests/ghost_hub_menu.Tests.ps1`): it parses
  GHOST.bat's `:DispatchOne` single-line cases + block cases (gids
  18/35/51/61) and asserts bidirectional gid coverage, per-gid script
  equality and wrapper→mode compatibility (Run→inline, RunWith→inline-note,
  RunZcodeReset→zcode-reset, ConfirmReset→confirm-reset, ConfirmRun→
  confirm-run, Detached→detached). A GHOST.bat row without a menu.json row
  (or vice versa) fails Pester — add both sides together. Gids 37-40/63/74
  are retired/unused/reserved and must stay absent from menu.json.
- `install_ghost_shortcut.ps1` prefers GHOST.exe as the `.lnk` target when
  built (its own icon + UAC manifest); falls back to the .bat +
  `assets\ghost.ico`. CI compiles the exe every run (ci.yml "GHOST.exe
  compile check") so the C# can never rot silently.
- GUI confirm dialogs default to No (the .bat choice gates default to Y — a
  GUI click is deliberate, destructive resets get the safer default).

## Out of scope

- Linux `.sh` scripts (separate effort)
- `.context/` directory (tool configuration — do not modify)
- `.git/` (do not modify)
- `change_device_id.ps1` (edit only per an explicit Phase-5 task)
- `identity_utils.ps1` (tested and shared — do not modify unless fixing a bug that affects all IDE scripts)

## Working preferences

- **Do NOT auto-commit.** Leave changes in the working tree for review. The user handles versioning.
- **Windows-first.** This is a Windows PowerShell project. Linux scripts exist but are out of scope for changes.
- **Run IDE scripts as Administrator** with the target app **closed first**. Each script calls `Assert-Administrator` early, then runs its own aggressive process-kill loop (`Stop-<App>ProcessesAggressive`).
- **Follow the Cursor pattern.** `src/windows/reset_cursor.ps1` is the canonical reference implementation (v0.1 had the BOM + rename-leaves-old-fingerprint bugs). New IDE scripts should mirror its structure, local helpers, and error handling.
- **Parse-check before declaring done.** Use `[System.Management.Automation.Language.Parser]::ParseFile` to verify syntax of every `.ps1` change.
