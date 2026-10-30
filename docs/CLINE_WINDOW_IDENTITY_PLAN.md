# Cline Window-Level Taskbar Identity Plan (deferred option — design-ready)

Status: DEFERRED-BY-DECISION. The developer chose shortcut-AUMIDs-only
(degraded) on 2026-10-24 (CLINE_CLONES_SPEC §7). This spec captures the design
so that a later go costs exactly one session. **Do not implement without the
developer's explicit go.** Backlog ID: CS-2.

## 1. Current state (accepted degraded)

- Shortcut pins carry per-clone AUMIDs `bot.cline.app.c1..c5` + colored icons
  (`tools\cline-<color>-branding\tray_icon.ico`).
- RUNNING windows all share the base identity: one taskbar button when grouped,
  identical titles "Cline v0.0.48". No distinct window title / tray icon /
  accent (nothing patchable; the app's tray is process-internal).

## 2. Constraints (verified, spec §3/§7)

- The app is Tauri 2.11.1 (Rust + wry/WebView2) — NO asar, nothing patchable;
  the v1-AutoClaw engine route does not apply. Everything must be
  launcher-side (outside the process).
- The launcher already does proven cross-process Win32 work at the same
  integrity level: `FindWindowW` on the single-instance window (class
  `bot.cline.app-sic`, title `bot.cline.app-siw`) and `SetWindowTextW` renames
  (the neutralization). App is asInvoker, launcher is non-elevated → UIPI-safe.
- The single-instance plugin is neutralized pre+post launch; per-clone
  single-instance is enforced by the launcher via the hub lock.

## 3. Design (the AutoClaw-v2 pattern, external variant)

1. **Window resolve**: after launch, enumerate top-level windows and match the
   owning PID to the launcher's own child (the Tauri main exe). WebView2
   renders in child `msedgewebview2.exe` processes — stamp only the MAIN exe's
   top-level window.
2. **AUMID stamp**: write `System.AppUserModel.ID` = `bot.cline.app.cN` (must
   equal the shortcut AUMID, so the running button resolves the clone
   shortcut's colored icon) into the window property store. C# P/Invoke
   property-store block; import `PropVariantClear` from **ole32.dll** — NOT
   oleaut32 (ground truth #6; symptom if regressed: instant
   `EntryPointNotFoundException` death).
3. **Title**: `SetWindowTextW` → "Cline <Color> vN" (cross-process, same-IL —
   proven by the neutralizer). Distinct titles prevent the ZCode pin-collision
   class (a window titled like the Primary can hijack `Cline.lnk` on pin).
4. **Lifecycle**: re-stamp on main-window handle change during the launch poll
   (a few seconds). Tauri creates one window and no splash-swap is known —
   VERIFY in Phase 0; a `.kick` re-stamp (brief `<aumid>.kick` → final) is added
   only if a stale group is observed (ZCode 2026-09-26 lesson) — likely
   unnecessary for fresh windows.
5. **Scope of change**: `launch_cline_clone.ps1` gains the stamp step + a
   verify-after property-store readback + `-Status` reports the window AUMID;
   `launch_cline_clones_all.ps1` unchanged; shortcuts installer unchanged;
   GHOST.bat unchanged. NO resident watcher planned (Cline windows do not
   splash-swap; revisit only if a merge case ever appears — ZCode watcher
   pattern, UIPI note applies).

## 4. Phase 0 — discovery probes (read-only, must run first)

On a live clone + the Primary:
a. Does the app set a process-explicit AUMID? (property-store readback on the
   main window + check for `SetCurrentProcessExplicitAppUserModelID` strings in
   the exe). If yes: window-level stamping still wins per-window (AutoClaw v2
   precedent: process-explicit identity merged windows despite env; the
   window-level stamp is what separated them) — note it and proceed.
b. The top-level window's owning PID is the Tauri main exe (not a WebView2
   child) — verify with `GetWindowThreadProcessId`.
c. Window class/name to target (stable across launches?) and whether the
   window handle changes during boot (splash swap?).
d. Does stamping survive a clone restart / a Primary running simultaneously?

## 5. Acceptance criteria

1. 3+ clones + Primary running → separate taskbar buttons per clone, each
   resolving its colored shortcut icon, distinct titles; Primary untouched.
2. Stock Cline (no clone flags) unaffected — bare launches keep stock identity.
3. Verify-after: property-store readback returns `bot.cline.app.cN` on every
   stamped window; failure → loud WARN + exit 0 (identity is cosmetic — never
   block the launch; never silent).
4. Parse-check 0 errors; Pester green; no elevation anywhere in the path.

## 6. Risks

- A Cline update may change window anatomy or the `-sim/-sic/-siw` identifiers →
  neutralization AND stamping degrade together; Phase 0 re-runs (the launcher
  already degrades loudly; the spec §7 procedure documents the re-derive).
- If stamping races window creation, the launch poll (already up to 60s in the
  ZCode launcher for slow cold starts) covers it — mirror that budget.

## 7. Out of scope

Tray icon/accent (process-internal — impossible launcher-side), in-app
recoloring, any patching of the exe/resources, the Cline Primary reset path.
