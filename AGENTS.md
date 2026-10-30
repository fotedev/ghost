# AGENTS.md — GHOST (Guided Hardware & OS Scrubbing Toolkit)

## Project overview

Fresh-start toolkit for local AI-IDE identity stores — **Cursor**, **Windsurf/Devin Desktop**, **Trae**, **Qoder**, **ZCode**, **QoderWork**, **MiniMax Agent/OpenCode**, **AutoClaw** — for privacy hygiene, multi-account testing, and dev-environment resets. Windows PowerShell (primary) and Linux Bash scripts.

## Repository layout

```
README.md  AGENTS.md  GHOST.bat/ghost.sh     # root launchers (scripts live under src/;
                                             #   CLI cheat sheet: docs/cli.md); GHOST.bat =
                                             #   6 submenus with CONTINUOUS LOCAL numbering
                                             #   (IDE resets [1]-[8] / ZCode Multi-Instance &
                                             #   Clones [1]-[28] / System & GHOST Maintenance
                                             #   [1]-[3] / AutoClaw2 Multi-Instance & Clones
                                             #   [1]-[9] / Cline Multi-Instance & Clones
                                             #   [1]-[9] / OpenCode Multi-Instance & Clones
                                             #   [1]-[10]) + ANSI colors + local chained input
                                             #   per submenu (e.g. "1 3 4"), main-menu sub-paths
                                             #   ("2 1 3 4" = ZCode then run its [1] [3] [4]),
                                             #   global gid jump from the main menu, and
                                             #   [U] Check for updates on the main menu
src/windows/                        # current .ps1 resetters (unversioned names) + identity_utils.ps1 + change_device_id.ps1
                                    #   + launch_autoclaw_clone.ps1 (AutoClaw clone launcher,
                                    #     -Instance inst1..inst4 + -Status) + Launch-AutoClaw-Clone.bat
                                    #   + reset_autoclaw.ps1 (-Target Primary|inst1..4|All)
src/linux/                     # .sh scripts (id_reset_common.sh + per-IDE resetters)
src/python/                    # stdlib-only Python core (ghost/ package) + ghost_cli.py bootstrap —
                               #   owns the shared SQLite/JSON identity logic; the PS bridges
                               #   (Set-SqliteKeys, reset_zcode secrets + CLI-telemetry,
                               #   refresh_zcode_second_chats chat-check) invoke it by absolute
                               #   path; tested by tests/python/test_ghost_core.py (unittest)
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
                                   #     watcher (ZCode submenu [25]; every 5s re-stamps
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
                                   #     (ZCode submenu [26]; -Days N): scans each instance's
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
                                   #   patch_zcode_icon_override.ps1 (+ .mjs engine v8) — one-time
                                   #     app.asar patch enabling ZCODE_ICON_DIR / ZCODE_AUMID_SUFFIX /
                                   #     ZCODE_ACCENT_HEX / ZCODE_INSTANCE_NAME env overrides +
                                   #     __ZCODE_BLUE__/__ZCODE_ACCENT__/__ZCODE_TITLE__ renderer flags
                                   #     (per-clone accent color + window title); v7+ also injects
                                   #     bidi auto-direction into the chat (per-paragraph Arabic RTL /
                                   #     English LTR via unicode-bidi:plaintext + dir="auto" stamping,
                                   #     code blocks stay LTR; ZCODE_BIDI_OFF=1 opts out); marker carries
                                   #     patchVersion so ZCode submenu [27] auto-upgrades after engine changes;
                                   #     re-run after app updates; after an app update the stale marker is
                                   #     auto-detected (asar byte-probe of the engine's signature strings) and
                                   #     the patch re-applies itself with a FRESH backup of the new pristine
                                   #     asar - no -Force needed (2026-10-24);
                                   #   zcode-blue-branding/ (blue, Secondary), zcode-yellow-branding/
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
                                   #     -Remove to uninstall; ZCode submenu [8]);
                                   #   refresh_zcode_second_chats.ps1 — cross-instance chat
                                   #     refresh (name is historical; -Target Primary|Second|Third|
                                   #     Fourth|Fifth|Sixth|All covers every instance now). One-shot (ZCode submenu [21]
                                   #     Second-only, ZCode submenu [22] -Target All): finds shared-store
                                   #     chats missing from the
                                   #     target's tasks-index, recycles its app-server(s) (auto-respawn
                                   #     re-seeds the sidebar index), verify-after; hot-activity guard
                                   #     waits out an in-flight turn (multi-signal guard: db commit recency +
                                   #     uncompleted assistant steps + running tools + app-server CPU sample,
                                   #     up to ~90s, -Force bypasses). -Watch mode (ZCode submenu [23], -Target
                                   #     All): tails the agent JSONL logs for terminal failures (captcha
                                   #     stall / quota / rate-limit, same signatures as
                                   #     watch_zcode_captcha.ps1) and refreshes every RUNNING instance
                                   #     (not-running/not-installed skipped, guard defer + retry, 300s
                                   #     cooldown); supersedes test_live_inject.py (obsolete spike,
                                   #     now deleted — its row-copying approach was a dead end));
                                   #   sync_zcode_assets.ps1 — Primary→clone asset sync
                                   #     (ZCode submenu [17]; also auto-runs per-launch as launcher
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
                                   #     (plugins\data + cli\agents stay per-instance). Running
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
                                   #   watch_zcode_mcp_sync.ps1 — resident MCP sync watcher
                                   #     (ZCode submenu [19] resident / [20] one-shot + live
                                   #     apply; -RunOnce, -DryRun, -IntervalSeconds, -ApplyLive,
                                   #     -Target Second|Third|Fourth|Fifth|Sixth|All,
                                   #     -InstallAutostart/-RemoveAutostart): stat-guards the
                                   #     Primary config.json (mtime+size, JSON parse-guard,
                                   #     ~1s debounce) and on every change invokes
                                   #     sync_zcode_assets.ps1 -McpOnly -Target All as a child —
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
                                   #   patch_autoclaw_ports.ps1 (+ .mjs engine v12; update-recovery 2026-10-24:
#     byte-probes app.asar for the engine's signature strings before the
#     marker gate - after an app update wipes marker+backups it re-patches
#     automatically with a FRESH backup, no -Force; -Force pristine-extract
#     only when the live asar is still patched, else extracts the new asar)
#     — one-time app.asar
                                   #     patch widening AutoClaw's hardcoded MCP candidate-port array
                                   #     [19681..19684] -> [19681..19688] + home-override (the state-dir
#     isolation marker .autoclaw-home; see the ELEVATION bullet below)
                                   #     multi-instance ceiling; inst4 has no port without it)
                                   #     + taskbar identity (spec §7.3c v2, 2026-10-17): families
                                   #     aumid-suffix (wraps BOTH real setAppUserModelId call sites to
                                   #     append .<aumidSuffix>) + window-identity (routes every
                                   #     new BrowserWindow through a cached subclass that sets the
                                   #     window icon from <userData>\.autoclaw-icon.ico, stamps the
                                   #     WINDOW-level AUMID via setAppDetails at creation time, and
                                   #     forces the "AutoClaw <Color>" title via page-title-updated
                                   #     interception; v12: setAppDetails takes `appId` (not
                                   #     appUserModelId) and RE-STAMPS on show + title re-assert —
                                   #     ctor stamps die with HWND recreation; -Force re-patches
                                   #     extract the pristine backup asar or the engine skips its
                                   #     own wrapped anchors and silently ships old code); identity
                                   #     source = <userData>\.autoclaw-identity.json
                                   #     written by launch_autoclaw_clone.ps1 step 4c (missing marker =>
                                   #     stock behavior — Primary and bare spawns untouched; env vars
                                   #     die at the UAC boundary, marker files do not);
                                   #     backup + marker (autoclaw-ports-patch.marker.json) + -Restore
                                   #     + node --check gate; AutoClaw must be
                                   #     closed; an app update reverts it (all instances run with
                                   #     system.autoUpdate=false as the guard); run directly - the
                                   #     v1.20 menu entry was retired 2026-10-29 with the v1.20 app;
                                   #   install_autoclaw_clone_shortcuts.ps1 — per-user Desktop +
                                   #     Start-menu shortcuts for inst1..inst4 (AppUserModel.ID =
                                   #     com.zhipuai.autoclaw.inst1..4; base read from the Primary .lnk
                                   #     or the verified app constant; -Instance to scope; -Remove;
                                   #     -RepairPrimaryAumid strips a hijacked .instN suffix + restores
                                   #     <exe>,0 icon; .lnk AUMIDs read ONLY via Shell.Application
                                   #     ExtendedProperty); per-clone IconLocation =
                                   #     tools\autoclaw-<color>-branding\tray_icon.ico,0 (blue/yellow/
                                   #     green/red ← inst1..4; missing dir warns + falls back to the
                                   #     exe icon); run directly - the v1.20 menu entry was retired
                                   #     2026-10-29 with the v1.20 app
                                   #   patch_opencode_clone_home.ps1 (+ .mjs engine v2) — one-time
                                   #     OpenCode desktop app.asar patch (OpenCode submenu [7]):
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
                                   #     write shared; pristine-backup-gated); OpenCode must be
                                   #     closed; re-apply after app updates (auto-detected);
                                   #   install_opencode_clone_shortcuts.ps1 — per-user Desktop +
                                   #     Start-menu shortcuts for c1..c5 (AppUserModel.ID =
                                   #     ai.opencode.desktop.c1..5; base read from the stock
                                   #     OpenCode.lnk via Shell ExtendedProperty or the verified
                                   #     constant; -Instance to scope; -Remove; -RepairPrimaryAumid
                                   #     strips a hijacked .cN suffix + restores <exe>,0 icon);
                                   #     per-clone IconLocation =
                                   #     tools\opencode-<color>-branding\tray_icon.ico,0 (missing
                                   #     dir warns + falls back to the exe icon); OpenCode
                                   #     submenu [8]
                                   #   new_clone_suite.ps1 — clone-suite scaffolding generator (playbook
                                   #     phases 3-10 mechanics): intake JSON → reset/launcher/.bat/
                                   #     shortcuts/SPEC skeletons + GHOST.bat submenu anchor-edit with
                                   #     verify-after; parse-checks every emitted .ps1; Phases 0-2 stay
                                   #     with the agent as <TODO: Phase 1 discovery> slots
                                   #   make_clone_icon.ps1 — GENERIC clone-icon generator (any app,
                                   #     PS 5.1 + System.Drawing only): corner-sampled background →
                                   #     tile detection (LongestLowRun profiles, -BgTolerance, or
                                   #     -ManualCrop x,y,size) → inset crop → 1024 master +
                                   #     rounded-corner alpha mask → tray_icon.ico (16..256
                                   #     PNG-in-ICO) + icon_windows.png + source.<ext> provenance;
                                   #     -HueRotate derives extra colors (autoclaw-red-branding =
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
                                   #          already-running clone never prompts; -LowRam passes
                                   #          --disable-gpu (experimental);
                                   #          Launch-ZCode-Second/Third/Fourth/Fifth/Sixth.bat wrappers)
launch_zcode_cli_light.ps1         # ZCode LIGHT headless worker -Instance Second..Sixth (GHOST.bat ZCode
                                   #          [7], gid 70; verified 2026-10-28 — docs/ZCODE_LIGHT_MODE.md):
                                   #          runs resources\glm\zcode.cjs under system node with the four
                                   #          env levers (HOME+USERPROFILE -> CloneHome redirect
                                   #          cli/config.json + cli/db/db.sqlite; ZCODE_DATA_BASE_DIR ->
                                   #          v2 credentials/provider_config; ZCODE_STORAGE_DIR -> cli caches)
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
spoof_wmi_serials.ps1              # System-level WMI serial spoof (2026-10-27, Maintenance [3] / gid 66):
                                   #   generated .mof ([DYNPROPS], real CIM keys, escaped literals) redeclares
                                   #   Win32_BIOS/BaseBoard/ComputerSystemProduct/SystemEnclosure/
                                   #   DiskDrive/PhysicalMemory -> mofcomp, + SQMClient UserId +
                                   #   Bluetooth LocalAddress (-SkipBluetooth); backup-first
                                   #   (winmgmt /backup aborts on failure), verify-after re-query is the
                                   #   arbiter, audit + generated winmgmt /restore script; -DryRun. WMI
                                   #   layer only (docs/WMI_SERIAL_SPOOFING.md) — ported from the Hydra
                                   #   Spoofer review, technique only; CPU/GPU/volume serials excluded.
reset_autoclaw.ps1                # AutoClaw: 7 steps (auth.json deviceId rotate,
                                   #          identity\device.json ed25519 keypair regen via node:crypto
                                   #          (system node or the app-bundled node.exe), settings.json
                                   #          gateway.port+url + system.autoUpdate=false (asar-patch
                                   #          guard), .updaterId rotate, openclaw.json mode/checkOnStart,
                                   #          devices\paired.json delete — live operator credential,
                                   #          gateway regenerates; final re-verify; -Target
                                   #          Primary|inst1|inst2|inst3|inst4|All + -DryRun;
                                   #          All = clones first, Primary last)
launch_autoclaw_clone.ps1         # AutoClaw multi-instance launcher -Instance inst1|inst2|inst3|inst4
                                   #          + -Status: env levers USERPROFILE/HOME/TEMP/TMP/TMPDIR +
                                   #          AUTOCLAW_GATEWAY_PORT (drift +9 read back, recorded to
                                   #          instance-record.json) + --user-data-dir (this app HONOURS it,
                                   #          lock keys off the profile dir); step 4c writes the taskbar
                                   #          identity markers (.autoclaw-identity.json + .autoclaw-icon.ico,
                                   #          verify-after; consumed by patch engine v12 — see tools/ notes);
                                   #          first run seeds the Primary
                                   #          profile EXCLUDING credential stores (token-cache.json,
                                   #          *.backup, auth.json tokens stripped — userInfo kept, ONE
                                   #          manual login per clone) + rotates device identity + ed25519
                                   #          keypair; marker-guarded one-time primary-token reconciliation;
                                   #          verify-after-launch: subtree stable 5s, MCP/gateway /health on
                                   #          DISCOVERED ports (never the requested one), paired.json holds
                                   #          only the clone's own key, Primary openclaw.json hash unchanged.
                                   #          Launch sequentially, never elevated.
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
                                   #   engine v2 — the app's ESM main has no require), patch-signature
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
Cursor/Windsurf/Trae v0.1 legacy) live in archive/ as local-only fallbacks —
never committed, do not run them.)

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
- GUI apps that call `AttachConsole(ATTACH_PARENT_PROCESS)` (verified: ZCode)
  hijack the launching console with log floods. Launch them detached
  (`cmd /c start "" <exe>`, new window via `start` in the .bat) — never inline.
  (Bit us in `GHOST.bat` option [10]: the menu drowned in `[pid:*]` logs.)
- **Submenu ids are display-ordered (renumbered 2026-10-29).** Every submenu's
  local ids run strictly ascending 1..N in visual order, grouped by `:Div`
  sections — ZCode: Launch Clones [1]-[8] (Second/Third/Fourth/Fifth/Sixth,
  ALL, light worker, shortcuts) / Reset Clones [9]-[16] (Second..Sixth,
  Primary, Both, ALL SIX) / Sync & Chat Refresh [17]-[23] / Watchers &
  Diagnostics [24]-[26] / Maintenance [27]-[28] (login helper); AutoClaw2: Launch Clones [1]-[7]
  (c1..c5, ALL, shortcuts) / Maintenance [8]-[9] (rewired to the AutoClaw2
  suite the same day — born display-ordered); Cline: Launch Clones [1]-[7]
  (c1..c5, ALL, shortcuts) / Maintenance [8]-[9]. **Gids NEVER renumber** —
  specs, wiring history and repo-integrity cite them; a renumber touches only
  the submenu echo block + its resolver ladder. Add future rows in display
  order inside their section — never a higher id out of sequence (the .bat
  harness asserts ascending ids per submenu). Old→new for citations written
  before 2026-10-29: ZCode launches [1,3,4,18,22]→[1,2,3,4,5], ALL [5]→[6],
  light [27]→[7], shortcuts [2]→[8], resets [6,8,9,19,23,21,7,10]→
  [9,10,11,12,13,14,15,16], sync [20,24]→[17,18], MCP watcher [25,26]→[19,20],
  chats [13,15,14]→[21,22,23], watchers [11,16,17]→[24,25,26], patch [12]→[27];
  Cline [3,4,6,7,5,2]→[2,3,4,5,6,7]. (The AutoClaw v1.20 rows were not
  renumbered — they were retired outright the same day; see the AutoClaw2
  rewiring entry.)

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
  is FROZEN (never rename its dirs — an installed profile must keep working).
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
  instance's app-server (ZCode submenu [21]; Second-only today). Never copy session rows
  between homes — a clone's own `db.sqlite` copy is dead storage nothing reads.
  See `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md`.
- User-scope config is the OPPOSITE: each clone reads its OWN
  `<CloneHome>\.zcode\cli\config.json` (the HOME override reaches the app's
  config resolution — verified 2026-10-17), so MCP/plugin/skill edits made in
  the Primary never reach the clones and the one-time seed copies drift.
  `tools/sync_zcode_assets.ps1` (ZCode submenu [17]; launcher step 2d) syncs
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
  home dir name (`ZCodeSecondHome`…); unmatched mains are Primary.
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
  These only work because `tools/patch_zcode_icon_override.ps1` (engine v8)
  patched the installed `app.asar` — an app update silently reverts them; re-run
  the patch (ZCode submenu [27]) whenever a clone loses its look. Primary never sets any
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
  quitAndInstall. Launch clones ONLY via their "ZCode Second/Third/Fourth"
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
  `tools/watch_zcode_taskbar.ps1` (ZCode submenu [25], resident + autostart): polls all
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
  on demand via `-CheckPrimaryHijack`. Diagnostic rule: read lnk AUMIDs via
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
  ZCode submenu [26] (`tools/diagnose_zcode_freeze.ps1`). Mitigation: larger
  pagefile / fewer concurrent instances. Ruled out that day: GPU caches, the
  icon asar patch, the captcha watchdog (idle since 09-17), db.sqlite locks.
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
  non-interactive callers warn+continue; focus-relaunches never prompt; an
  experimental `-LowRam` passes `--disable-gpu`) and ZCode [7] launches
  `launch_zcode_cli_light.ps1` — a per-account HEADLESS worker (~0.9 GB vs
  ~1.6 GB+). Verified limits recorded in the launcher header: standalone TUI
  impossible (@zcode/tui is asar-locked) and headless runs default to the free
  opencode-zen model until a one-time `zcode login zai` per clone home (the
  working plan provider namespace is `account:zai-start-plan`, discovered from
  the Primary db's model_usage). T3 Code (pingdotgg) — the local support path
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
  (GHOST.bat ZCode [28], gid 71) does the per-home `zcode login zai` with
  verify-after, T3 Code v0.1.4 is INSTALLED (winget T3Tools.T3Code,
  `~/.t3/userdata/settings.json` holds the five pre-seeded acpRegistry
  instances — edit only with the app closed), and the user-supervised
  live-acceptance runbook lives in spec §9.2.

## Multi-instance conventions (AutoClaw: Primary + 4 clone slots)

- Layout (FROZEN, never rename): `%USERPROFILE%\AutoClawCloneHome\instN\`
  with `home\` (USERPROFILE/HOME → gateway state `.openclaw-autoclaw`),
  `profile\` (--user-data-dir), `tmp\` (TEMP/TMP/TMPDIR). The Primary
  (`%APPDATA%\AutoClaw` + `~\.openclaw-autoclaw`) is never touched by any
  clone script beyond reading it for the seed. Spec:
  `docs/AUTOCLAW_CLONES_SPEC.md` (all §5 ground truth read from the
  installed app, provenance §13).
- Isolation levers: env vars FIRST (`USERPROFILE`/`HOME` move the whole
  gateway state tree; `AUTOCLAW_GATEWAY_PORT` per instance), and
  `--user-data-dir` as a SECOND layer — this app HONOURS it (unlike ZCode);
  the single-instance lock keys off the profile dir, so re-launching a
  running clone just focuses it.
- The MCP HTTP server binds a hardcoded 4-slot port array
  (`PRODUCTIVITY_MCP_CANDIDATE_PORTS = [19681..19684]`) in the Electron main
  process — 4 is the stock ceiling and two instances silently SPLIT across
  slots (wrong-instance routing, not an error). `tools/patch_autoclaw_ports.ps1`
  widens it to 8; inst4 has NO MCP port without that patch. An AutoClaw
  update reverts it — therefore EVERY instance's settings.json carries
  `system.autoUpdate: false` (set by reset + seed-scrub) and the patch is
  re-applied after any manual update (AutoClaw submenu [11] — row retired
  2026-10-29 with the v1.20 app; run the patch script directly on hosts that
  still run v1.20).
- The gateway port silently shifts up to +9 when the preferred port is busy
  (`PORT_PROBE_RANGE`) — never record the REQUESTED port as the actual one:
  the launcher discovers the clone's real listening ports by scanning
  19681..19688 / requested..requested+9 against the clone's own process
  subtree and writes them to `instance-record.json` (`-Status` reads it).
- One credential = one instance (ZCode Telegram rule generalized): AutoClaw
  keeps TWO device identities — `auth.json.deviceId` (backend id) and
  `identity\device.json` (ed25519 keypair; the pubkey is what the backend
  pins for pairing) — plus `devices\paired.json`, a LIVE operator token with
  admin scope. The seed copies the Primary profile EXCLUDING every
  credential store (`token-cache.json` holds live token/refreshToken too —
  it is excluded, not scrubbed), strips `auth.json` tokens keeping
  `userInfo` (clone opens on the account, ONE manual login per clone),
  rotates the identities, and NEVER seeds the gateway state tree (fresh per
  clone; its gateway regenerates `paired.json`). Verify-after-launch
  asserts the clone's `paired.json` holds only its own device key.
- Classify clone processes by PROCESS MARKERS (the `--user-data-dir` /
  home-dir strings in the command line), never by window title (ZCode
  splash-phase lesson applies verbatim); helpers/gateway children hang off
  the marker-matched main via a parent walk.
- Launch clones SEQUENTIALLY, never in parallel, and never elevated (UIPI;
  the ZCode drag-drop rule applies). The launcher itself needs NO admin.
- The FIRST-RUN seed requires the Primary CLOSED — a live Chromium profile
  cannot be robocopied (leveldb LOCK files + open DBs; verified 2026-10-15:
  robocopy exit 9 with the Primary running). The launcher waits up to 180s
  then aborts; later launches never need this. Seed completion is
  marker-guarded (`.autoclaw-seeded` written only after scrub verified):
  needsSeed keyed on `auth.json` alone let an aborted robocopy's PARTIAL
  profile pass as seeded — the app launched on inconsistent stores and died
  within seconds (live-verified). A partial profile is cleared + re-seeded
  automatically on the next run.
- Taskbar identity v2 IMPLEMENTED 2026-10-17, live-verified 2026-10-18 (spec
  §7.3c, patch engine v12 + launcher step 4c): the launcher writes
  `<CloneProfile>\.autoclaw-identity.json`
  (`{aumidSuffix, title, iconPath?}` — inst1=blue, inst2=yellow, inst3=green,
  inst4=red, synced with the shortcut installer's `$InstanceDefs`) and copies
  `tools\autoclaw-<color>-branding\tray_icon.ico` → `<CloneProfile>\.autoclaw-icon.ico`
  fresh on every launch. The patched app (engine v12) resolves the identity from
  `--user-data-dir` argv (env dies at the UAC boundary, args do not) and: wraps BOTH
  `setAppUserModelId("com.zhipuai.autoclaw")` call sites to declare
  `com.zhipuai.autoclaw.instN` (equal to the shortcut AUMIDs, so the running button
  resolves the clone shortcut's icon), routes every `new BrowserWindow` through a
  subclass that stamps the WINDOW-level AUMID via `setAppDetails` at creation time
  (BEFORE show/grouping — no stale-group kick needed; the ZCode `.kick`/watcher existed
  for LATE external re-stamping) and sets the colored window icon, and forces the
  "AutoClaw <Color>" title via `page-title-updated` interception (renderer
  `document.title` cannot fold it back — the pin-collision class prevented at source).
  Missing marker (Primary, bare native-host spawns) => resolver null => stock behavior.
  Contingency if a merge case ever appears: adapt the watch_zcode_taskbar.ps1 pattern
  elevated (clone windows are elevated, UIPI). The SHORTCUTS carry the matching
  per-clone AUMIDs (`com.zhipuai.autoclaw.inst1..4`) and ICONS
  (`tools\autoclaw-<color>-branding\tray_icon.ico` — blue/yellow/green for
  inst1..3 from developer-supplied renders 2026-10-17, red for inst4 as a
  +150° hue-rotate of the blue master via `tools\make_clone_icon.ps1`;
  `bad-green` rejected by the developer). A pinned clone can hijack the
  Primary's `AutoClaw.lnk` AUMID + wipe its icon — same as ZCode: repair with
  `install_autoclaw_clone_shortcuts.ps1 -RepairPrimaryAumid` (the Primary
  keeps the stock exe icon; only clone .lnk icons are custom).
- Electron fuses verified patchable (no asar-integrity validation, no
  integrity.json) — the ZCode asar-patch mechanism works on AutoClaw as-is.
  AutoClaw also bundles `resources\node\node.exe` — the keygen fallback when
  system node is missing (ed25519 via node:crypto; PS 5.1 cannot generate
  ed25519; PEM shapes verified: SPKI 113, PKCS8 119 chars).
- **ELEVATION (verified live 2026-10-16, changes everything above):**
  AutoClaw.exe's manifest declares `requestedExecutionLevel
  level="requireAdministrator"` — EVERY launch self-elevates (UAC silent for
  admin accounts with ConsentPromptBehaviorAdmin=0), and the elevated process
  gets a FRESH ENVIRONMENT: the launcher's env levers (USERPROFILE/HOME/
  AUTOCLAW_GATEWAY_PORT) never survive. `--user-data-dir` (an argument)
  survives ONLY when the launching cmd itself is elevated first — a
  non-elevated `start` hits the ERROR_ELEVATION_REQUIRED ShellExecute
  fallback, which launches the elevated process with a bare command line
  (verified via PEB reads: every AutoClaw.exe ran with NO arguments).
  Therefore: (a) the launcher elevates its own `cmd /c start` via
  `-Verb RunAs` so the args ride a plain CreateProcess; (b) the gateway-port
  lever is the clone's settings.json `gateway.port` (file-based, survives
  elevation), not the env var; (c) the state dir is isolated by
  `tools/patch_autoclaw_ports.ps1` engine v10 (`home-override`): the patched
  app reads `<userData>\.autoclaw-home` (written by the launcher each launch,
  trim-tolerant — the app's argv carries a trailing space after the quoted
  path) and redirects the whole `~/.openclaw-autoclaw` tree; the resolver is
  `app.getPath("home")`-based (Chromium known-folder, env-immune), NOT
  `os.homedir()` — the spec's section 5.3 env-var claim was verified against
  plain node only and does NOT hold for the app. The scan is
  argv-driven (reads --user-data-dir from process.argv — getPath("userData")
  is NOT yet applied at resolver time) and caches into
  `globalThis.__autoclawHomeOverride`.
- **WMI (Win32_Process) is unusable for AutoClaw classification**: it omits
  AutoClaw.exe processes ENTIRELY (healthy mains invisible minutes after
  start) and CommandLine is permanently empty for the ones it shows (the app
  effectively scrubs its PEB command line — PEB reads confirm args were
  passed while WMI/PEB show none). Classification uses Get-Process
  (toolhelp32) pid-diff + the profile lockfile exclusive-open probe
  (`Test-ProfileLockHeld`); port ownership falls back to an unattributed
  advisory scan. `taskkill /F` may report "Access is denied" for same-user
  processes misleadingly — use .NET `Process.Kill()`.
- Every patched app start appends one diagnostic record to
  `%TEMP%\ac-argv-debug.txt` (argv + resolved override + error) — the field
  tool for diagnosing clone isolation; remove from
  `tools/patch_autoclaw_ports.mjs` `ARGV_SCAN_CACHED`/`homeOverrideIife` if
  it ever needs to go silent.
- Full live-verified clone cycle 2026-10-16: inst1 launched beside the
  Primary with `gateway :18799 /health OK {"ok":true,"status":"live"}`,
  `paired.json` holding only the clone's device key, Primary openclaw.json
  hash unchanged, and the whole `.openclaw-autoclaw` tree materializing in
  the clone home. One manual login remains per clone.
- **First-run seed gate = the PRIMARY's profile lockfile, never "any
  AutoClaw.exe process"** (live bug 2026-10-17): the gate used
  `Get-Process -Name AutoClaw`, so inst1 RUNNING blocked inst2/3/4's first
  launch for the full 180s wait and then aborted — user-visible as a cmd
  window that flashes and closes with nothing opening. Clones are named
  AutoClaw.exe too and never lock the Primary's files; the correct gate is
  `Test-ProfileLockHeld` on `%APPDATA%\AutoClaw` (clean Primary exit leaves
  no lockfile; a running instance holds it exclusively — semantics
  verified on a live clone the same day). Running-clone detection also
  needs the lockfile probe: WMI cannot see the clone, so the marker-based
  subtree match alone misses it.
- **Sign-in gate on the gateway (asar-verified 2026-10-17):** the embedded
  gateway auto-starts only via `shouldLaunchGatewayAtColdStart =
  isCloudMode || hasAcceptedRiskAgreement()` → `triggerGatewayLaunch()`,
  whose start is parked on the renderer's `APP_MAIN_UI_READY`
  (`markGatewayMainUiReady`); the handler re-checks via
  `ensureEmbeddedGatewayLaunchedAfterRiskAgreement`. An instance sitting on
  the SIGN-IN screen never sends it — NO gateway/MCP ports until the ONE
  manual login completes and the main UI mounts (inst2 live case: seeded +
  isolated + running, gateway absent while `auth.json` had no token; after
  the user's inst1 login 02:13 its gateway bound 18799). The launcher
  treats a missing gateway as WARN when the profile has no token (login
  pending) and FAIL only when a token IS present.
- **Browser-extension native host spawns bare Primary instances**
  (live-verified 2026-10-17): `%APPDATA%\AutoClaw\chrome-ext\0.1.6\com.autoclaw.native_host_stub.json`
  points at `C:\Program Files\AutoClaw\AutoClaw.exe` with NO arguments —
  whenever the AutoClaw extension reconnects in Chrome/Edge it spawns a
  bare AutoClaw.exe that opens the PRIMARY profile and rewrites its
  `openclaw.json` (bare pid 12612 spawned 43s into inst2's launch; this is
  also the source of the "openclaw.json modified externally" dialogs). The
  launcher therefore attributes Primary-hash changes via the Primary
  lockfile before/after (held during the window → WARN out-of-band, not a
  clone breach); a clone's FIRST launch needs every Primary-profile window
  closed — including that stray spawn.

## Multi-instance conventions (Cline: Primary + 5 clone slots)

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
- The app is **Electron (electron-builder NSIS) 2.0.32, asInvoker** — and
  UNLIKE AutoClaw2/Cline its packaged build has NO env lever for the
  userData: `OPENCODE_DESKTOP_TEST_ROOT` is unpackaged-only,
  `OPENCODE_TEST_ONBOARDING` rmSync-wipes its root every boot, and the
  channel map only has beta/prod. Isolation therefore needs the ONE-TIME
  **clone-home asar patch** (`tools/patch_opencode_clone_home.ps1` +
  `.mjs`, engine v2): the argv flag `--opencode-clone-home=<dir>` feeds
  the app's OWN `ye()` test-mode branch → `userData=<home>\desktop`,
  `sessionData=<home>\session`, and the four `XDG_*` env vars set from
  the home's subdirs BEFORE the v2 background-service spawn (the app's
  own redirection surface, read unconditionally in production). No flag =
  bit-for-bit stock. Backup + marker (`opencode-clone-home-patch.marker.json`,
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
  OpenCode [7] (or the launcher's abort message) after any manual update.
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
  "OpenCode <Color>" title. **Identity rides PURE ARGV (engine v2, live
  finding): the main bundle `out/main/index.js` is ESM — `require` is
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
  profile. GHOST.bat OpenCode submenu [1]-[10] (gids 53-62).

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
palette). Current suites: ZCode (gold standard, full identity) and AutoClaw
(v1 shipped: shortcut AUMIDs + per-clone icons; taskbar identity v2
IMPLEMENTED 2026-10-17, live-verified 2026-10-18 — patch engine v12 +
launcher step 4c per its spec §7.3c; window AUMID readback observed live);
AutoClaw2 (2026-10-23, c1..c5, env-lever-only, no patching) and Cline
(2026-10-24, c1..c5, env levers + single-instance window neutralization,
no patching — its spec documents the Tauri guard anatomy). OpenCode
desktop (2026-10-24, c1..c5, clone-home asar patch — packaged builds
hardcode userData so the patch feeds the app's own TEST_ROOT/XDG
redirection from an argv flag; native per-userData single-instance lock;
single setAppUserModelId site wrapped + browser-window-created stamper
with argv identity (ESM main); LIVE-VERIFIED 2026-10-24/25 — coexistence,
ephemeral service ports, Primary snapshot diff = 0 clone-attributable
changes; spec docs/OPENCODE_CLONES_SPEC.md).

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
