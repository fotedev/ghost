# AGENTS.md — GHOST (Guided Hardware & OS Scrubbing Toolkit)

## Project overview

Fresh-start toolkit for local AI-IDE identity stores — **Cursor**, **Windsurf/Devin Desktop**, **Trae**, **Qoder**, **ZCode**, **QoderWork**, **MiniMax Agent/OpenCode** — for privacy hygiene, multi-account testing, and dev-environment resets. Windows PowerShell (primary) and Linux Bash scripts.

## Repository layout

```
README.md  AGENTS.md  GHOST.bat/ghost.sh     # root launchers (scripts live under src/;
                                             #   CLI cheat sheet: docs/cli.md)
src/windows/                        # current .ps1 resetters (unversioned names) + identity_utils.ps1 + change_device_id.ps1
src/linux/                     # .sh scripts (id_reset_common.sh + per-IDE resetters)
docs/                              # IMPLEMENTATION_GUIDE/PLAN, WALKTHROUGH, research notes (local-only);
                                   #   ZCODE_CHAT_SYNC_WATCHER_PLAN.md (tracked — chat-sync root cause)
archive/                           # superseded versions (local-only fallbacks — do not run, never committed)
assets/                            # ghost.ico + ghost-source.png (launcher icon; regenerate via
                                   #   tools/make_ghost_icon.ps1 — never hand-edit)
tools/                             # reviewed utilities (block_qoder_domains.ps1,
                                   #   watch_zcode_captcha.ps1 — captcha-stall watchdog
                                   #     (Telegram creds via params or .envlocal at repo root);
                                   #   watch_zcode_taskbar.ps1 — resident taskbar-identity
                                   #     watcher (menu [25]; every 5s re-stamps
                                   #     System.AppUserModel.ID on each ZCode main window
                                   #     incl. Primary when missing/wrong — the shell-side
                                   #     fix for the recurring taskbar merge; -RunOnce,
                                   #     -InstallAutostart/-RemoveAutostart startup-folder
                                   #     shortcut, named-mutex single instance, log at
                                   #     %LOCALAPPDATA%\watch-zcode-taskbar\taskbar.log);
                                   #   patch_zcode_icon_override.ps1 (+ .mjs engine v6) — one-time
                                   #     app.asar patch enabling ZCODE_ICON_DIR / ZCODE_AUMID_SUFFIX /
                                   #     ZCODE_ACCENT_HEX / ZCODE_INSTANCE_NAME env overrides +
                                   #     __ZCODE_BLUE__/__ZCODE_ACCENT__/__ZCODE_TITLE__ renderer flags
                                   #     (per-clone accent color + window title); marker carries
                                   #     patchVersion so menu [13] auto-upgrades after engine changes;
                                   #     re-run after app updates;
                                   #   zcode-blue-branding/ (blue, Secondary), zcode-yellow-branding/
                                   #     (yellow, Third), zcode-green-branding/ (green, Fourth) —
                                   #     generated icon assets + shared generator (v3 pipeline: Z
                                   #     extracted per hue mask, Z rescaled to match the original
                                   #     icon's Z bbox; --mask blue|yellow|green, --out-dir);
                                   #   install_zcode_second_shortcuts.ps1 — per-user Desktop +
                                   #     Start-menu shortcuts for all three clones (AppUserModel.ID =
                                   #     base + ".2"/".3"/".4" for pin grouping; -Instance to scope;
                                   #     -Remove to uninstall; menu [14]);
                                   #   refresh_zcode_second_chats.ps1 — cross-instance chat
                                   #     refresh (name is historical; -Target Primary|Second|Third|
                                   #     Fourth|All covers every instance now). One-shot (menu [15]
                                   #     Second-only, menu [23] -Target All): finds shared-store
                                   #     chats missing from the
                                   #     target's tasks-index, recycles its app-server(s) (auto-respawn
                                   #     re-seeds the sidebar index), verify-after; hot-activity guard
                                   #     waits out an in-flight turn (multi-signal guard: db commit recency +
                                   #     uncompleted assistant steps + running tools + app-server CPU sample,
                                   #     up to ~90s, -Force bypasses). -Watch mode (menu [22], -Target
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
                                   #     -Remove/-DesktopOnly/-RepoOnly; menu [24]);
                                   #   update_ghost.ps1 — repo self-updater (menu [26]): git fetch
                                   #     origin + compare HEAD vs the remote default branch, lists
                                   #     new commits; without -CheckOnly asks before git pull
                                   #     --ff-only; refuses on local commits / non-main or detached
                                   #     HEAD; dirty tree -> interactive stash -u -> pull -> pop
                                   #     (failed pop keeps the stash); verify-after re-reads HEAD ==
                                   #     origin + behind==0; offline fetch = warning + clean exit 0
```

## Architecture

```
src/windows/identity_utils.ps1  # Shared library, dot-sourced by all IDE scripts
  New-IdentitySet                  #   -> { devDeviceId, machineId, macMachineId, sqmId }
  Assert-Administrator             #   -> exit 1 if not elevated
  Stop-AppProcesses                #   -> kill loop (auto-expands Windsurf->Devin+codeium, Trae->Broker)
  Backup-FileToTimestampDir        #   -> copy to <app>\ID_Backups\<ts>\<label>
  Set-JsonIdentity                 #   -> JSON patch + verify-after re-read
  Set-SqliteKeys                   #   -> Python-backed UPSERT + verify-after (uses $env:TEMP for .py)
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
reset_minimax_opencode.ps1  # MiniMax/OpenCode: 22 steps (auth.json wipe -> {} unless
                                   #          -KeepLogin, version preflight ≥1.17.0, distinct
                                   #          updater IDs, Chromium state per profile; v1.2 adds
                                   #          updater-tmp sweep, DIPS/SharedStorage suffix sweep,
                                   #          lockfile/locks delete, uninstall_metrics removal,
                                   #          windowIds rotation + per-window file delete; chat preserved)
change_device_id.ps1              # System-level: Fingerprint (self-test) / LegacyReset (registry GUIDs)
                                   #   / RepairProfiles (ProfileList .bak keys). Windows-only.
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
4. The max reliably-changeable fingerprint-signal weight is **0.19** (CPU name 0.12 + tz 0.03 + culture 0.02 + ui.language 0.02), which is below the **0.306** delta needed to flip `sameIdentity` to false. Therefore IDE storage rewrites are the **primary** unbanning mechanism, not the fingerprint self-test.
5. `IMPLEMENTATION_GUIDE.md` is the verified ground truth. Do not trust comments in old scripts — several describe behavior verified NOT to work.

## Mandatory conventions

- **Never silent-success.** Every write must be followed by a re-read and comparison. If a value doesn't match after write, emit `FAILED` and record in the audit log. This is the single most important anti-pattern to avoid.
- **Detect Python via `Get-Command`.** Fall back to `python3`. Never hardcode a Python path.
- **Write temp `.py` to `$env:TEMP`.** Never next to the database file (clutters user dirs).
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
  instance's app-server (menu [15]; Second-only today). Never copy session rows
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
  These only work because `tools/patch_zcode_icon_override.ps1` (engine v6)
  patched the installed `app.asar` — an app update silently reverts them; re-run
  the patch (menu [13]) whenever a clone loses its look. Primary never sets any
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
  handle change and final-verifies with an independent read. Launcher must
  run at the same or higher integrity level as the clone (UIPI).
- Launcher stamping alone was NOT enough (verified 2026-09-24 later the same
  day): the merge MOVED to Primary+Yellow — any window relying on the app's
  process-explicit identity can merge with any other at any time. Final fix =
  `tools/watch_zcode_taskbar.ps1` (menu [25], resident + autostart): polls all
  four instances every 5s and re-stamps Primary (`dev.zcode.app`) AND clones
  whenever a window is missing/wrong — heals new/splash-swapped windows
  automatically (live-proven: stamped a freshly launched Primary within its
  first pass). Ambiguous titles (patch missing, all "ZCode") are skipped
  loudly, never guessed.
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

## Out of scope

- Linux `.sh` scripts (separate effort)
- `.context/` directory (tool configuration — do not modify)
- `.git/` (do not modify)
- `change_device_id.ps1` (edit only per an explicit Phase-5 task)
- `identity_utils.ps1` (tested and shared — do not modify unless fixing a bug that affects all IDE scripts)

## Working preferences

- **Do NOT auto-commit.** Leave changes in the working tree for review. The user handles versioning.
- **Windows-first.** This is a Windows PowerShell project. Linux scripts exist but are out of scope for changes.
- **Run IDE scripts as Administrator** with the target app **closed first**. Each script calls `Assert-Administrator` and `Stop-AppProcesses` early.
- **Follow the Cursor pattern.** `src/windows/reset_cursor.ps1` is the canonical reference implementation (v0.1 had the BOM + rename-leaves-old-fingerprint bugs). New IDE scripts should mirror its structure, local helpers, and error handling.
- **Parse-check before declaring done.** Use `[System.Management.Automation.Language.Parser]::ParseFile` to verify syntax of every `.ps1` change.
