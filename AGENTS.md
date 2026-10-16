# AGENTS.md — GHOST (Guided Hardware & OS Scrubbing Toolkit)

## Project overview

Fresh-start toolkit for local AI-IDE identity stores — **Cursor**, **Windsurf/Devin Desktop**, **Trae**, **Qoder**, **ZCode**, **QoderWork**, **MiniMax Agent/OpenCode**, **AutoClaw** — for privacy hygiene, multi-account testing, and dev-environment resets. Windows PowerShell (primary) and Linux Bash scripts.

## Repository layout

```
README.md  AGENTS.md  GHOST.bat/ghost.sh     # root launchers (scripts live under src/;
                                             #   CLI cheat sheet: docs/cli.md); GHOST.bat =
                                             #   4 submenus with CONTINUOUS LOCAL numbering
                                             #   (IDE resets [1]-[9] / ZCode Multi-Instance &
                                             #   Clones [1]-[17] / System & GHOST Maintenance
                                             #   [1]-[2] / AutoClaw Multi-Instance & Clones
                                             #   [1]-[12]) + ANSI colors + local chained input
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
                                   #   ZCODE_CHAT_SYNC_WATCHER_PLAN.md (tracked — chat-sync root cause)
archive/                           # superseded versions (local-only fallbacks — do not run, never committed)
assets/                            # ghost.ico + ghost-source.png (launcher icon; regenerate via
                                   #   tools/make_ghost_icon.ps1 — never hand-edit)
tools/                             # reviewed utilities (block_qoder_domains.ps1,
                                   #   watch_zcode_captcha.ps1 — captcha-stall watchdog
                                   #     (Telegram creds via params or .envlocal at repo root);
                                   #   watch_zcode_taskbar.ps1 — resident taskbar-identity
                                   #     watcher (ZCode submenu [16]; every 5s re-stamps
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
                                   #     (ZCode submenu [17]; -Days N): scans each instance's
                                   #     <home>\.zcode\v2\logs for render-process-gone /
                                   #     child-process-gone / perf_freeze events (collapses
                                   #     same-second bursts), reads .zcode\v2\crash\archive dump
                                   #     annotations (v8-oom-last-os-error 1455 = commit limit),
                                   #     prints live RAM/commit/pagefile pressure; verified the
                                   #     2026-09-25 renderer-OOM freeze root cause;
                                   #   patch_zcode_icon_override.ps1 (+ .mjs engine v7) — one-time
                                   #     app.asar patch enabling ZCODE_ICON_DIR / ZCODE_AUMID_SUFFIX /
                                   #     ZCODE_ACCENT_HEX / ZCODE_INSTANCE_NAME env overrides +
                                   #     __ZCODE_BLUE__/__ZCODE_ACCENT__/__ZCODE_TITLE__ renderer flags
                                   #     (per-clone accent color + window title); v7 also injects
                                   #     bidi auto-direction into the chat (per-paragraph Arabic RTL /
                                   #     English LTR via unicode-bidi:plaintext + dir="auto" stamping,
                                   #     code blocks stay LTR; ZCODE_BIDI_OFF=1 opts out); marker carries
                                   #     patchVersion so ZCode submenu [12] auto-upgrades after engine changes;
                                   #     re-run after app updates;
                                   #   zcode-blue-branding/ (blue, Secondary), zcode-yellow-branding/
                                   #     (yellow, Third), zcode-green-branding/ (green, Fourth) —
                                   #     generated icon assets + shared generator (v3 pipeline: Z
                                   #     extracted per hue mask, Z rescaled to match the original
                                   #     icon's Z bbox; --mask blue|yellow|green, --out-dir);
                                   #   install_zcode_second_shortcuts.ps1 — per-user Desktop +
                                   #     Start-menu shortcuts for all three clones (AppUserModel.ID =
                                   #     base + ".2"/".3"/".4" for pin grouping; -Instance to scope;
                                   #     -Remove to uninstall; ZCode submenu [2]);
                                   #   refresh_zcode_second_chats.ps1 — cross-instance chat
                                   #     refresh (name is historical; -Target Primary|Second|Third|
                                   #     Fourth|All covers every instance now). One-shot (ZCode submenu [13]
                                   #     Second-only, ZCode submenu [15] -Target All): finds shared-store
                                   #     chats missing from the
                                   #     target's tasks-index, recycles its app-server(s) (auto-respawn
                                   #     re-seeds the sidebar index), verify-after; hot-activity guard
                                   #     waits out an in-flight turn (multi-signal guard: db commit recency +
                                   #     uncompleted assistant steps + running tools + app-server CPU sample,
                                   #     up to ~90s, -Force bypasses). -Watch mode (ZCode submenu [14], -Target
                                   #     All): tails the agent JSONL logs for terminal failures (captcha
                                   #     stall / quota / rate-limit, same signatures as
                                   #     watch_zcode_captcha.ps1) and refreshes every RUNNING instance
                                   #     (not-running/not-installed skipped, guard defer + retry, 300s
                                   #     cooldown); supersedes test_live_inject.py (obsolete spike,
                                   #     now deleted — its row-copying approach was a dead end));
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
                                   #   patch_autoclaw_ports.ps1 (+ .mjs engine v10) — one-time app.asar
                                   #     patch widening AutoClaw's hardcoded MCP candidate-port array
                                   #     [19681..19684] -> [19681..19688] + home-override (the state-dir
#     isolation marker .autoclaw-home; see the ELEVATION bullet below)
                                   #     multi-instance ceiling; inst4 has no port without it);
                                   #     backup + marker (autoclaw-ports-patch.marker.json) + -Restore
                                   #     (verified byte-identical) + node --check gate; AutoClaw must be
                                   #     closed; an app update reverts it (all instances run with
                                   #     system.autoUpdate=false as the guard); AutoClaw submenu [11];
                                   #   install_autoclaw_clone_shortcuts.ps1 — per-user Desktop +
                                   #     Start-menu shortcuts for inst1..inst4 (AppUserModel.ID =
                                   #     com.zhipuai.autoclaw.inst1..4; base read from the Primary .lnk
                                   #     or the verified app constant; -Instance to scope; -Remove;
                                   #     -RepairPrimaryAumid strips a hijacked .instN suffix + restores
                                   #     <exe>,0 icon; .lnk AUMIDs read ONLY via Shell.Application
                                   #     ExtendedProperty); per-clone IconLocation =
                                   #     tools\autoclaw-<color>-branding\tray_icon.ico,0 (blue/yellow/
                                   #     green/red ← inst1..4; missing dir warns + falls back to the
                                   #     exe icon); AutoClaw submenu [2]
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
reset_devin.ps1       # Windsurf/Devin Desktop (rebranded 2026-06): 17 steps
                                   #            x N auto-detected %APPDATA% roots (Devin, Windsurf):
                                   #            argv.json crash-reporter-id (.windsurf + .devin),
                                   #            .codeium\config.json device_id, installation_id (.windsurf
                                   #            + cli\), credentials.toml delete, config.json org_id blank,
                                   #            extended cache sweep, LOCALAPPDATA updater sweep
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
                                   #          -Target Primary|Secondary|Third|Fourth|Both|All (selective
                                   #          tree-kill, per-target ID_Backups, independent IDs per child)
launch_zcode_second_instance.ps1   # ZCode multi-instance launcher -Instance Second|Third|Fourth
                                   #          (own window via cmd/start; first run clones+scrubs profile,
                                   #          routes Telegram bots to Primary via per-home marker;
                                   #          Launch-ZCode-Second/Third/Fourth.bat wrappers)
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
                                   #          lock keys off the profile dir); first run seeds the Primary
                                   #          profile EXCLUDING credential stores (token-cache.json,
                                   #          *.backup, auth.json tokens stripped — userInfo kept, ONE
                                   #          manual login per clone) + rotates device identity + ed25519
                                   #          keypair; marker-guarded one-time primary-token reconciliation;
                                   #          verify-after-launch: subtree stable 5s, MCP/gateway /health on
                                   #          DISCOVERED ports (never the requested one), paired.json holds
                                   #          only the clone's own key, Primary openclaw.json hash unchanged.
                                   #          Launch sequentially, never elevated.
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

## Multi-instance conventions (ZCode: Primary + 3 clones)

- Layout: Primary (default profile) + clones **Second** (blue), **Third**
  (yellow), **Fourth** (green). Clone homes: `%USERPROFILE%\ZCodeSecondHome` /
  `ZCodeThirdHome` / `ZCodeFourthHome`; clone roaming: `%APPDATA%\ZCode-Second`
  / `ZCode-Third` / `ZCode-Fourth`; AUMID suffixes `2`/`3`/`4`. The Second row
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
  instance's app-server (ZCode submenu [13]; Second-only today). Never copy session rows
  between homes — a clone's own `db.sqlite` copy is dead storage nothing reads.
  See `docs/ZCODE_CHAT_SYNC_WATCHER_PLAN.md`.
- Classify mains by **bare-exe CommandLine** (quoted or unquoted full path only);
  `--type` filtering alone misclassifies helpers as helpers. Empty CommandLine is
  a WMI race — keep as candidate, subtree walk still classifies correctly.
  Subtree marker strings per clone = its roaming dir name (`ZCode-Second`…) or
  home dir name (`ZCodeSecondHome`…); unmatched mains are Primary.
- One Telegram bot token = ONE polling instance. Never clone an enabled bot into
  a clone profile (HTTP 409 + random cross-account billing). Launcher enforces
  Primary-only via per-home marker-guarded disable (`.telegram-routed` in each
  clone home); a deliberate re-enable is never reverted.
- Both/All-mode resets generate **independent ID sets per child** — never
  duplicate. `Both` = Secondary+Primary (back-compat); `All` = Third+Fourth+
  Secondary+Primary (clones first, Primary last with the Qoder steps).
- Backups, watchdog probes and final validation are scoped **per-target**.
- Clone visual identity rides on `ZCODE_ICON_DIR` + `ZCODE_AUMID_SUFFIX` +
  `ZCODE_ACCENT_HEX` + `ZCODE_INSTANCE_NAME` (branded window/tray icon +
  separate taskbar button + accent recolor + "ZCode <Color>" window title).
  These only work because `tools/patch_zcode_icon_override.ps1` (engine v7)
  patched the installed `app.asar` — an app update silently reverts them; re-run
  the patch (ZCode submenu [12]) whenever a clone loses its look. Primary never sets any
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
  GHOST menu via [18]). Windows UIPI silently strips drop data from a
  non-elevated Explorer into a high-IL window: the "Drop to add attachments"
  overlay still lights (window-level dragover) but `dataTransfer.files`
  arrives empty and the drop handler no-ops — while the "+" picker works
  (native dialog inside the process). Fix: clear the shortcut's
  Compatibility-tab admin flag and launch instances non-elevated; launch-only
  menu entries ([10]/[16]/[17]/[18]) do not need the menu itself elevated.
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
  `tools/watch_zcode_taskbar.ps1` (ZCode submenu [16], resident + autostart): polls all
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
  ZCode submenu [17] (`tools/diagnose_zcode_freeze.ps1`). Mitigation: larger
  pagefile / fewer concurrent instances. Ruled out that day: GPU caches, the
  icon asar patch, the captcha watchdog (idle since 09-17), db.sqlite locks.

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
  re-applied after any manual update (AutoClaw submenu [11]).
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
- Running windows all declare the BASE AUMID `com.zhipuai.autoclaw` (set
  unconditionally in the app) — v1 known limitation: shared taskbar button;
  the SHORTCUTS still carry per-clone AUMIDs (`com.zhipuai.autoclaw.inst1..4`)
  for pin grouping and per-clone ICONS
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
(v1, shared-taskbar limitation documented in its spec §7.3c).

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
