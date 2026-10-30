# AutoClaw multi-instance clones — design spec

Status: **IMPLEMENTED** — shipped 2026-10-15 (see CHANGELOG); §7's proposals
were extended in places by the shipped scripts (a 7-step reset vs the 6
targets listed, expanded seed exclusions, marker-keyed seed completion).
Decisions Q1–Q3 resolved 2026-10-08 (see §10).
Project: GHOST (`unban-machine-id`) · Target app: `C:\Program Files\AutoClaw\AutoClaw.exe`
Target app profile: Electron 33.4.11, `APP_VERSION 0.1.13`, `launch.json` version `1.17.8`
Revised 2026-10-17: §7.3c rewritten from a deferred v2 limitation into a REQUIRED v2 design
(separate taskbar identity per clone + per-clone icons in the taskbar and in the app
window) — implemented the same day (patch engine v11) and live-verified 2026-10-18 on
engine v12 (window-level AUMID readback on a live clone window).

This is a GHOST **spec-first** document: the design was written first, then
implemented (`src/windows/launch_autoclaw_clone.ps1`,
`src/windows/reset_autoclaw.ps1`, `tools/patch_autoclaw_ports.ps1`,
`tools/install_autoclaw_clone_shortcuts.ps1`). Every constraint quoted below was read out of the installed `AutoClaw.exe` on this host,
not inferred — see §13 for provenance.

---

## 1. Problem

AutoClaw is a single-instance Electron app. We want **4 independent AutoClaw instances** running
side by side on this host, each with its own profile, its own agent state, its own gateway process
and its own ports — and each clone carrying **its own machine identity** rather than a copied
identity.

That second half is not a nice-to-have. A verbatim profile copy produces N instances presenting one
`deviceId` to AutoClaw's backend, which is exactly the failure class this repo exists to eliminate
(§4).

## 2. Relationship to the existing ZCode work

GHOST already runs six instances of another app: ZCode Primary + Second/Third/Fourth/Fifth/Sixth, via
`src/windows/launch_zcode_second_instance.ps1 -Instance Second|Third|Fourth|Fifth|Sixth`. That script is the
direct precedent for §6b and the template for §7's design. The two problems have the same shape:

| | ZCode | AutoClaw (this spec) |
|---|---|---|
| Instances | Primary + 4 clones | primary + 4 clones (inst1..inst4) |
| Isolation lever | env vars (`ZCODE_DATA_BASE_DIR`, `HOME`, …) | `--user-data-dir` + marker files (env dies at the UAC boundary, §5.3) |
| Why not CLI flags only | app overwrites `--user-data-dir` via `app.setPath` | app honours `--user-data-dir` (§5.2) |
| Per-clone identity | seed-scrub rotates cloned IDs after copy | same pattern, different files (§8) |
| Ports | none needed | **hard blocker — 4-slot array (§5.1)** |

Two GHOST ground-truth rules are load-bearing here and are *not* restated in `AGENTS.md`'s ZCode
section in this form:

1. **Never copy identity or session rows between homes.** `AGENTS.md` already says this for ZCode
   ("a clone's own `db.sqlite` copy is dead storage nothing reads"). §8 applies it to AutoClaw.
2. **One credential = one instance.** The ZCode Telegram rule ("one Telegram bot token = ONE polling
   instance" → HTTP 409 + cross-account billing) is the precedent for the AutoClaw rules in §8.

## 3. Naming and layout

Numbered, per Q3.

```
%USERPROFILE%\AutoClawCloneHome\          <- isolated home root (NOT inside the repo)
├── inst1\
│   ├── home\     USERPROFILE/HOME for this instance
│   │   └── .openclaw-autoclaw\          per-instance agent state, logs, config
│   ├── profile\  --user-data-dir target (Electron profile)
│   └── tmp\      TMPDIR/TEMP/TMP (gateway lock files, temp output)
├── inst2\ … inst3\ … inst4\

%USERPROFILE%\.openclaw-autoclaw\         <- the PRIMARY. Never touched by any script here.
```

Instance homes live under `%USERPROFILE%`, not inside the repo, because `AGENTS.md` treats the repo
as scripts+docs while runtime state is per-user. This mirrors the ZCode clones
(`%USERPROFILE%\ZCodeSecondHome`).

Inst4's layout is generated so that starting it is a one-liner once the port patch in §5.1 is
applied.

## 4. Why identity rotation is mandatory (the R1 problem, solved properly)

An earlier standalone draft of this spec flagged shared credentials as risk R1 and proposed seeding
the primary's `auth.json` into every clone, accepting the risk. **Inside GHOST that answer is wrong.**
A verbatim profile copy is the anti-pattern this repo was built to prevent.

AutoClaw keeps **two independent device identities** on this host, and they are *not* the same value:

| Identity | File | Value on this host (abbrev.) |
|---|---|---|
| Electron device id | `%APPDATA%\AutoClaw\auth.json` → `deviceId` | `b786a56d…` |
| Gateway device identity | `~/.openclaw-autoclaw\identity\device.json` → `deviceId` | `f8c0f1b1…` |

Plus a third artifact that is effectively a **live operator credential**:
`~/.openclaw-autoclaw\devices\paired.json` holds an `operator` token (`yf-qSmX-…`, rotated
`1791452988000`) granting `operator.admin` / `operator.approvals` / `operator.pairing`.

If all instances share these:

- the backend sees one device with N concurrent sessions;
- `paired.json`'s operator token is duplicated — a real admin-scoped credential;
- concurrent `token`/`refreshToken` rotation can sign siblings out.

GHOST's answer, applied per clone: **seed** the profile (so the clone starts with the user's chats
and projects), then **scrub** — rotate every identity-bearing value while keeping the history, and
never carry a live credential across.

## 5. Verified ground truth (do not contradict these)

### 5.1 The MCP port is a hardcoded 4-slot array — the scope blocker

```js
const PRODUCTIVITY_MCP_CANDIDATE_PORTS = [19681, 19682, 19683, 19684];
const PRODUCTIVITY_MCP_PATH = "/mcp";
const PRODUCTIVITY_MCP_HEALTH_PATH = "/health";
const GITHUB_MCP_BRIDGE_PATH = "/github/mcp";
const FIGMA_MCP_BRIDGE_PATH = "/figma/mcp";
```

The bind loop, in the Electron **main** process:

```js
for (const candidatePort of PRODUCTIVITY_MCP_CANDIDATE_PORTS) {
  const boundPort = await new Promise((resolve2, reject) => {
    const server2 = app.listen(candidatePort, PRODUCTIVITY_MCP_HOST, () => resolve2(candidatePort));
    server2.once("error", () => { server2.close(); reject(error); });
    server2.once("listening", () => { httpServer = server2; });
  });
  setProductivityMcpActivePort(boundPort);
}
```

Consequences, all confirmed empirically:

- The MCP server is bound by the **main** process — one port per Electron instance — and cannot be
  moved by config, env or CLI.
- Exactly **4 slots**. A fifth instance has nowhere to bind. Four is this build's ceiling.
- The bind is a *fallback loop*, not a conflict: two instances do not fail, they **silently split**
  across slots. A client URL pinned to `…:19681/mcp` then points at whichever instance won the lower
  slot — wrong-instance routing, not a clean error.
- On this host `AutoClaw.exe` PID 13336 currently holds 19681.

**Resolution:** patch the installed `app.asar` to widen the array to 8 slots (§7.3). Precedent: this
repo already ships `tools/patch_zcode_icon_override.ps1` (engine v8), which patches the *installed*
ZCode `app.asar` in place, writes a marker file carrying `patchVersion`, supports `-Restore`, and
warns that an app update silently reverts it. The AutoClaw port patcher follows that shape exactly.

### 5.2 `--user-data-dir` is honoured (differs from ZCode)

```js
const allowParallelE2eInstance = isDev && process.env.AUTOCLAW_E2E_ALLOW_PARALLEL_INSTANCE === "1";
const gotSingleInstanceLock = allowParallelE2eInstance || app.requestSingleInstanceLock();
```

`requestSingleInstanceLock()` keys off the profile dir. Verified live: launching
`AutoClaw.exe --user-data-dir=<fresh dir>` alongside the running primary produced a fully separate
profile (`auth.json` with only `deviceId`, a fresh `settings.json`, its own `logs\`) and left the
primary's 19681 untouched. **No single-instance patch is needed** — unlike ZCode, which overwrites
the flag via `app.setPath`.

### 5.3 Agent state moves only via the home directory

The Electron main process sets the gateway's state dir from `os.homedir()`:

```js
const OPENCLAW_PROFILE = "autoclaw";
const OPENCLAW_HOME_DIR = `.openclaw-${OPENCLAW_PROFILE}`;
…
OPENCLAW_STATE_DIR: openclawStateDir,     // join(os.homedir(), ".openclaw-autoclaw")
OPENCLAW_CONFIG_PATH: runtimeConfigPath,
```

The gateway re-derives it from `homedir()` in several places. Verified: `node -e "os.homedir()"`
honours `USERPROFILE` or `HOME`. So per-instance `USERPROFILE` + `HOME` moves the entire state tree
in one move — `logs\`, `agents\*\sessions`, `openclaw.json`, `openclaw.runtime.json`,
`session-goals.json`, `expert-sop-last-known-good.json`, `.compile-cache`, `.hermes-runtime-receipts`.

> **CORRECTED 2026-10-16 (live-verified): this section's env-var lever DOES NOT WORK.** Two
> reasons, discovered during the first real clone launch: (1) the app's main resolves the state
> dir via `app.getPath("home")` / the Windows profile API — env-immune; the `node -e` check above
> only proved plain node honours the env, not the Electron main; (2) AutoClaw.exe's manifest
> declares `requireAdministrator`, so every launch self-elevates and the elevated process gets a
> FRESH ENVIRONMENT — even the env the launcher set is gone. Working mechanism:
> `tools/patch_autoclaw_ports.ps1` engine v10 (`home-override`) redirects the resolver to
> `<userData>\.autoclaw-home` (a marker file the launcher writes; `--user-data-dir` is an
> argument and survives elevation). See AGENTS.md "ELEVATION" bullet.

### 5.4 Gateway lock files are keyed by config path — no collision

```js
function resolveGatewayLockDir() { … return path.join(os.tmpdir(), suffix); }
function resolveGatewayLockPath(env, lockDir = resolveGatewayLockDir()) {
  const configPath = resolveConfigPath(env, resolveStateDir(env));
  const hash = createHash("sha256").update(configPath).digest("hex").slice(0, 8);
  return { lockPath: path.join(lockDir, `gateway.${hash}.lock`), configPath };
}
```

The lock name hashes the **config path**, so per-instance config paths yield per-instance lock files
inside the shared `%TEMP%\openclaw`. No `OPENCLAW_ALLOW_MULTI_GATEWAY=1` needed — and that flag is
test-only anyway (gated on `VITEST` / `NODE_ENV=test`); using it would mask a real lock conflict
instead of verifying there isn't one (§11).

### 5.5 The gateway port is overridable, but auto-shifts

```js
const GATEWAY_DEFAULT_PORT = 18789;
function getPreferredPort() {
  const envPort = Number.parseInt(process.env.AUTOCLAW_GATEWAY_PORT || "", 10);
  if (Number.isInteger(envPort) && envPort > 0 && envPort < 65536) return envPort;
  try { const p = getSettings().gateway?.port; … } catch {}
  return GATEWAY_DEFAULT_PORT;
}
const PORT_PROBE_RANGE = 10;     // findNextFreePort scans startPort..startPort+9
```

`AUTOCLAW_GATEWAY_PORT` is the supported override, read from `process.env` of the main process, so it
is settable per instance. But a busy preferred port **silently shifts up to +9**, so the bound port
must be **read back after start** and recorded — never assumed. This is the most important
verify-after-write rule in the spec: recording the requested port as the actual one is exactly the
silent-success `AGENTS.md` forbids.

> **CORRECTED 2026-10-16 (live-verified): the env lever does not survive launch.** AutoClaw.exe
> self-elevates (`requireAdministrator`), and the elevated process gets a FRESH ENVIRONMENT — an
> `AUTOCLAW_GATEWAY_PORT` set by the launcher never reaches the main process. The working lever is
> the clone's `settings.json` `gateway.port` (file-based, survives elevation); the launcher still
> reads the actually-bound port back either way (§6 drift rule). See AGENTS.md "ELEVATION" bullet.

### 5.6 `OPENCLAW_PROFILE` is not the lever

The gateway accepts `--profile <name>`, isolating under `~/.openclaw-<name>`. Tempting, but it also
renames the workspace (`workspace-<profile>`), lock names and log filenames. Given
`USERPROFILE`/`HOME` already isolates completely (§5.3), renaming gains nothing and costs a
behavioural delta. Not used.

### 5.7 Everything is loopback-only

`PRODUCTIVITY_MCP_HOST = "127.0.0.1"`; gateway client default `ws://127.0.0.1:18789`. Four instances
add no new network exposure.

### 5.8 All instances declare one AUMID today

```js
app.setAppUserModelId("com.zhipuai.autoclaw");
```

Unconditional, in every instance — stock behavior merges all four windows into one taskbar
button. The ports patch's taskbar-identity engine (§7.3c; v11 shipped 2026-10-17, v12
fixes live-verified 2026-10-18) overrides this at runtime: both
real call sites are wrapped to append `.<aumidSuffix>` from
`<userData>\.autoclaw-identity.json`, and every window additionally gets a window-level
AUMID via `setAppDetails`. A missing identity marker (Primary, bare spawns) resolves to
null and the base AUMID stands.

## 6. Port plan

Primary untouched. Spacing is **11**, not 10, because each instance may silently shift +9 (§5.5) and
a 10-gap would let a neighbour's window overlap the next instance's preferred port.

| Instance | MCP port | Gateway requested | Possible window | Env var |
|---|---|---|---|---|
| primary | 19681 | 18789 | 18789–18798 | (none) |
| inst1 | 19682 | 18799 | 18799–18808 | `AUTOCLAW_GATEWAY_PORT=18799` |
| inst2 | 19683 | 18810 | 18810–18819 | `AUTOCLAW_GATEWAY_PORT=18810` |
| inst3 | 19684 | 18821 | 18821–18830 | `AUTOCLAW_GATEWAY_PORT=18821` |
| inst4 | 19685 | 18832 | 18832–18841 | `AUTOCLAW_GATEWAY_PORT=18832` |

inst4's MCP port 19685 exists only because of the §5.1 patch. Without the patch, inst1–inst3 are the
maximum and inst4 has no port at all.

## 6b. Multi-instance conventions (proposed, mirroring AGENTS.md's ZCode section)

- Layout is **FROZEN**: `AutoClawCloneHome\inst1..inst4`, never renamed. An installed clone profile
  must keep working across an app update.
- Isolation levers are arguments + marker files, NOT env vars (env dies at the UAC boundary, §5.3
  CORRECTED): `--user-data-dir` isolates the Electron profile (this app honours it, §5.2), the
  patched engine's `home-override` marker (`.autoclaw-home`) redirects the whole gateway state
  tree, and the gateway port rides `settings.json` (§5.5).
- One `auth.json` credential = ONE instance. Never seed a clone with the primary's live
  `token`/`refreshToken`; never copy `devices/paired.json`.
- Classify mains by **process markers** (the clone's `--user-data-dir` string appears in the child's
  command line), not by window title — the ZCode lesson applies verbatim: title-only classification
  misclassifies splash-phase windows.
- Launch instances **sequentially**, never in parallel.
- Elevation is NOT optional (AGENTS.md ELEVATION bullet, live-verified 2026-10-16): AutoClaw.exe's
  manifest declares `requireAdministrator`, so every launch self-elevates, and the launcher elevates
  its own `cmd /c start` via `-Verb RunAs` so the arguments ride a plain CreateProcess. (The ZCode
  UIPI rule — never launch elevated — applies to ZCode only.)
- Per-clone taskbar identity is a **v2 requirement** (§7.3c): every clone window groups and pins
  separately with its color icon in the taskbar and in the app window itself. v1's shortcut-AUMID-only
  pins were the interim fallback — superseded 2026-10-17 (implemented), live-verified 2026-10-18.

## 7. Proposed deliverables

### 7.1 `src/windows/reset_autoclaw.ps1`

The GHOST-shaped reset script: dot-source utils → `Assert-Administrator` → stop AutoClaw processes →
`New-IdentitySet` → per-target `[n/N]` steps with verify-after → audit log → restore script → summary
with exit 1 on any failure.

Targets, in order. Every step is `backup → mutate → verify`.

1. `%APPDATA%\AutoClaw\auth.json` — rotate `deviceId` to fresh 64-hex.
2. `%APPDATA%\AutoClaw\identity\device.json` — regenerate the ed25519 keypair and `deviceId`.
3. `%APPDATA%\AutoClaw\settings.json` — write this instance's `gateway.port`.
4. `%APPDATA%\AutoClaw\settings.json` — enforce `update.checkOnStart: false` so a clone can never
   race an app update against the patched `app.asar` (§5.1, §7.3).
5. `AutoClawCloneHome\instN\home\.openclaw-autoclaw\openclaw.json` — verify `gateway.mode` and
   `update.checkOnStart: false`.
6. Probe: delete `~/.openclaw-autoclaw\devices\paired.json` for the target instance so its own
   gateway regenerates a fresh one, then verify after start that only its own key is present.

Steps 1–2 are the identity rotation proper; step 6 is the credential-hygiene pass.

### 7.2 `src/windows/launch_autoclaw_clone.ps1`

`[ValidateSet('inst1','inst2','inst3','inst4')] [string]$Instance = 'inst1'`

Phases, in order:

1. **Resolve** the instance table row: home, profile dir, MCP port, gateway port, process markers.
2. **Ensure directories**: `home\`, `profile\`, `tmp\`.
3. **First-run seed** — robocopy the primary's `%APPDATA%\AutoClaw` profile, excluding `logs\`,
   `*.log`, `Cache`, `Code Cache`, `GPUCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, and
   `lockfile`. Robocopy exit codes 0–7 are success; ≥8 must abort the launch rather than proceed on a
   half-built profile (the ZCode launcher's rule). Copy `auth.json` **and then scrub it in phase 4** —
   it is copied only so `userInfo` survives, never for its tokens.
4. **First-run seed-scrub** — rotate, with verify-after re-read on each:
   - `auth.json.deviceId` → fresh 64-hex
   - `identity/device.json` → fresh ed25519 keypair + `deviceId` (the existing
     `MCowBQYDK2VwAyEA` PEM prefix confirms ed25519, generated via `node:crypto`
     `generateKeyPairSync('ed25519')`)
   - `.updaterId` → fresh GUID
   - `auth.json.token` / `.refreshToken` → **removed**, leaving `userInfo` so the clone opens on the
     account and prompts for login
   - `settings.json` → this instance's `gateway.port`, `update.checkOnStart: false`
5. **Marker-guarded one-time reconciliation** — the AutoClaw analogue of the ZCode launcher's
   `[telegram-route]` step: runs once ever per instance, idempotent, never reverts a deliberate
   later re-enable. Guards that a second instance never inherits a shared credential.
6. **Launch** detached: `cmd /c start "" <exe> --user-data-dir=<profile>`. Never inline — `AGENTS.md`
   records that `AttachConsole` apps hijack the launching console with log floods.
7. **Verify-after-launch** — the no-silent-success core:
   - process tree exists and is stable for 5 s
   - clone's MCP port answers `GET /health` → `{"ok":true,…}` (verified on the primary)
   - clone's gateway port answers `GET /health` → `{"ok":true,"status":"live"}` (also verified)
   - read the **actual** bound gateway port back; on drift from requested, log
     `mcp/gateway port drift` and write the real value into the instance's record
   - clone's `devices/paired.json` contains **only** its own device key → otherwise `FAILED`
   - the primary's `~/.openclaw-autoclaw\openclaw.json` hash is unchanged (isolation proof)

### 7.2b. `Launch-AutoClaw-Clone.bat`

Double-click wrapper mirroring `Launch-ZCode-Second.bat`. Must obey the `.bat` rules in `AGENTS.md`:
**no bare parentheses** in any `echo` line inside a parenthesised block (CMD treats `)` as the block
terminator and aborts the script silently), and launch detached via `cmd /c start ""`.

### 7.3 `tools/patch_autoclaw_ports.ps1` (+ `.mjs` engine)

`app.asar` patch widening `PRODUCTIVITY_MCP_CANDIDATE_PORTS` from 4 to 8 slots. Mirrors the ZCode
patcher: marker file carrying `patchVersion`, `-Restore`, warning that an app update reverts it, and
a hard requirement that AutoClaw is closed while patching. Verifies the patched constant by
re-reading it from the written `app.asar`.

### 7.3b. `tools/install_autoclaw_clone_shortcuts.ps1`

Per-user Desktop + Start-menu shortcuts for inst1–inst4 with distinct `System.AppUserModel.ID`
(`com.zhipuai.autoclaw.inst1` … `.inst4`), so taskbar buttons and pins stay separate. Base AUMID
`com.zhipuai.autoclaw` is read from the app itself (§5.8).

`AGENTS.md` records that pinning a clone window can rewrite the Primary's `.lnk` AUMID *and* wipe its
`IconLocation`. Same hazard applies here, so this script needs a `-RepairPrimaryAumid` switch
mirroring `install_zcode_second_shortcuts.ps1 -RepairPrimaryAumid`. Diagnostic rule copied too: read
`.lnk` AUMIDs via `Shell.Application` `ExtendedProperty('System.AppUserModel.ID')` — decoding the
`.lnk` as UTF-16 and regexing misaligns on odd byte offsets and reports false `<none>`.

Per-clone shortcut icons (2026-10-17, developer-supplied): each clone `.lnk` sets
`IconLocation = tools\autoclaw-<color>-branding\tray_icon.ico,0` — blue/yellow/green for inst1–3
cropped from developer renders, red for inst4 derived as a +150° hue-rotate of the blue master
(`tools\make_clone_icon.ps1`, the generic generator reusable by future app clones). A missing
branding dir warns and falls back to the `AutoClaw.exe` icon (never a set-but-absent icon path —
playbook §5 / EC-B02). The Primary `AutoClaw.lnk` keeps the stock exe icon; `-RepairPrimaryAumid`
restores exactly that, so the two behaviors do not conflict. Since patch engine v12 (§7.3c;
v11 shipped 2026-10-17, v12 live-verified 2026-10-18) the running windows carry the same
per-clone AUMID + icon identity — shortcut and window share one identity string.

### 7.3c. Taskbar identity v2 — separate taskbar buttons per clone + per-clone icons (IMPLEMENTED 2026-10-17, live-verified 2026-10-18 on engine v12)

> **Implementation status: IMPLEMENTED 2026-10-17 (engine v11), live-verified
> 2026-10-18 (engine v12)** — `tools/patch_autoclaw_ports.ps1` engine v11
> gained the `aumid-suffix` + `window-identity` families and
> `launch_autoclaw_clone.ps1` writes the identity markers (step 4c); engine
> v12 fixed the three findings of the first live relaunch (§12). The v1
> shortcut-only degradation is superseded: running windows now carry per-clone AUMIDs,
> icons and titles. An AutoClaw app update reverts the patch — re-apply via AutoClaw
> menu [11] (row retired 2026-10-29 with the v1.20 app — run
> tools\patch_autoclaw_ports.ps1 directly; the marker auto-upgrades, same rule
> as the ports patch).

**Contract (v2, unchanged):** every clone (inst1..inst4) presents its own taskbar
identity — a separate taskbar button/window group per clone, the clone's color icon
visible BOTH on that taskbar button (+ its pin) AND in the app window itself
(title-bar/window icon), and a forced distinct window title "AutoClaw <Color>". The
§5.8 ground truth (`app.setAppUserModelId("com.zhipuai.autoclaw")`, unconditional in
every instance) is exactly what the v2 design overrides.

Mechanism — the branding patch is **part of the EXISTING
`tools/patch_autoclaw_ports.ps1`** (engine v11 at ship; v12 today), not a sibling tool: one marker, one backup, one
`-Restore` per installed asar (a second patch owner would race the first on the swap).
Two new families, same conventions (idempotent self-guarding passes, per-file marker
verify, `node --check` gate, candidate re-extract):

1. **`aumid-suffix` — per-clone process AUMID.** Wraps BOTH real
   `setAppUserModelId("com.zhipuai.autoclaw")` call sites in the 0.1.13 bundle to append
   `.<aumidSuffix>` resolved at runtime (the remaining string occurrences — the macOS
   bundle-id const and a deep-link URL — are untouched). The resolved string equals the
   shortcut AUMID already written by `install_autoclaw_clone_shortcuts.ps1`, so the
   shell resolves the running button's icon from the clone shortcut's
   `tools\autoclaw-<color>-branding\tray_icon.ico` `IconLocation`, and pins keep working
   because shortcut and window share one identity string.
2. **`window-identity` — window-level identity, set IN-APP.** Routes every
   `new X.BrowserWindow(` through a cached subclass that (a) sets the window icon
   option from `<userData>\.autoclaw-icon.ico` when the file exists (EC-B02: never a
   set-but-absent path; fallback = the stock exe icon + report), (b) stamps the
   WINDOW-level AppUserModelID via `win.setAppDetails({appId})` — Electron 33's option
   key is `appId`; `appUserModelId` silently no-ops (the engine-v12 fix) — re-stamped
   on `show` and on every title re-assert so the stamp survives HWND recreation, and (c) forces
   the "AutoClaw <Color>" title by intercepting `page-title-updated`
   (preventDefault + setTitle), so renderer `document.title` updates cannot fold the
   title back to the generic "AutoClaw" — the ZCode pin-collision class, prevented at
   the source.

Config channel — **marker files, NOT env vars** (unchanged finding): the launcher writes
`<userData>\.autoclaw-identity.json` (`{aumidSuffix, title, iconPath?}`) and copies
`tray_icon.ico` → `<userData>\.autoclaw-icon.ico` fresh on every launch (step 4c,
verify-after both). Colors inst1=blue, inst2=yellow, inst3=green, inst4=red — in sync
with the shortcut installer's `$InstanceDefs`. This is forced by the elevation finding
in §5.3 (CORRECTED note): AutoClaw.exe self-elevates (`requireAdministrator`) and the
elevated process gets a fresh environment, so an `AUTOCLAW_AUMID_SUFFIX`-style env
override (the old v2 candidate (a), mirroring `ZCODE_AUMID_SUFFIX`) would silently
never fire. `--user-data-dir` is an argument and survives the UAC boundary; the patched
identity resolver scans it exactly like the `.autoclaw-home` reader.

Why NO external watcher/window-stamp is needed (better than the ZCode shape): the ZCode
launcher/watcher had to stamp windows EXTERNALLY and LATE — after the window was
already grouped — which is what forced the `.kick` re-stamp and a resident watcher
(verified 2026-09-24/26). Here the window-level identity is set inside the app at
window creation, BEFORE the window is shown/grouped, so the shell builds each group
correctly from the start and there is no stale group to heal. The forced unique title
also gives any future external tooling a reliable title-resolve handle (WMI omits
AutoClaw.exe entirely — live-verified 2026-10-16, recorded in `AGENTS.md`).
Contingency, should a merge case ever appear in the field: adapt the
`tools/watch_zcode_taskbar.ps1` pattern (title-resolve + `IPropertyStore` stamp +
kick); clone windows run elevated, so that watcher must run elevated too (UIPI;
EC-C08). Extracting the inline C# helper into `identity_utils.ps1` remains out of
scope (§11).

Verification: patch-level — engine markers re-read from the patched tree AND from the
repacked candidate asar, `node --check` on every patched file. Runtime (after relaunch
via the launcher): a clone running alone shows its own color title-bar icon, the
"AutoClaw <Color>" title, and a separate taskbar button resolved through
`com.zhipuai.autoclaw.instN` (EC-C07: verify via the property store, never UIA); the
Primary and any bare spawn (browser native host) keep stock identity — the identity
resolver finds no marker without `--user-data-dir` + `.autoclaw-identity.json` and
every injected site no-ops; EC-C01 hijack repair (`-RepairPrimaryAumid`) applies
unchanged.

## 8. Identity rotation matrix (AutoClaw)

AutoClaw keeps two device identities and one live operator credential. What each clone does with each
file:

| File | Primary value | Clone action | Method |
|---|---|---|---|
| `%APPDATA%\AutoClaw\auth.json` `.deviceId` | `b786a56d…` | **rotate** | fresh 64-hex |
| `%APPDATA%\AutoClaw\auth.json` `.token` / `.refreshToken` | live | **remove** | absent → clone prompts login |
| `%APPDATA%\AutoClaw\auth.json` `.userInfo` | account | **copy** | gives the clone the account |
| `%APPDATA%\AutoClaw\identity\device.json` | `f8c0f1b1…` + ed25519 keypair | **rotate** | fresh keypair + id |
| `%APPDATA%\AutoClaw\settings.json` `.gateway.port` | 18789 | **overwrite** | per-instance port |
| `%APPDATA%\AutoClaw\settings.json` `.update.checkOnStart` | false | **enforce** | already false on the primary |
| `%APPDATA%\AutoClaw\.updaterId` | updater GUID | **rotate** | fresh GUID |
| `~/.openclaw-autoclaw\devices\paired.json` | operator token `yf-qSmX-…` | **never copy** | clone's gateway regenerates |
| `~/.openclaw-autoclaw\identity\device.json` | `f8c0f1b1…` | **never copy** | fresh per clone |

Rationale per row:

- **rotate `deviceId`** — the whole point of the clones. A clone presenting the primary's device id is
  precisely what this repo exists to prevent.
- **remove tokens** — ZCode's "one credential, one instance" rule generalises. A token is bound to a
  device; a clone carrying a foreign `deviceId` plus the primary's token is an incoherent state. Copy
  `userInfo` only, so the clone opens on the account without a live credential.
- **rotate the ed25519 keypair** — the public key is what the backend pins for pairing. Regenerating it
  is what makes a clone a distinct device rather than a lookalike.
- **never copy `paired.json`** — it is a live operator credential with `operator.admin` scope. Copying
  it duplicates an admin token across instances. Absent, the clone's own gateway generates its own.
- **rotate `.updaterId`** — `electron-updater` uses it as the install telemetry identity; identical
  values across clones make update telemetry look like one machine.

**Accepted consequence:** because tokens are never copied, each clone needs **one manual login** on
first run. This supersedes the standalone draft's Q1 answer (seed the shared `auth.json` and accept
the risk), which was made before this repo's conventions were known. Flagging it explicitly because it
changes operator effort: three logins for inst1–inst3, once each.

## 9. Risks

| ID | Risk | Severity | Mitigation |
|---|---|---|---|
| A1 | Live operator token in `devices/paired.json` duplicated if seeded | **high** | Never seeded; post-start verify-after asserts only the clone's own key (§7.2 step 7) |
| A2 | `app.asar` port patch wiped by any AutoClaw update | high | Marker + `patchVersion`; `-Restore`; status reports "unpatched" when marker missing/stale |
| A3 | Patching a shipped Electron `app.asar` is outside GHOST's normal per-IDE scope | high | Justified here; called out explicitly — without it the max is 3 clones, not 4 |
| A4 | One manual login per clone on first run | medium | Expected and documented; one time, then independent |
| A5 | Gateway silently shifts up to +9 ports | medium | Read the bound port back; log drift; never record requested as actual |
| A6 | All instances share one taskbar button (§5.8) | low (was medium) | RESOLVED 2026-10-17, live-verified 2026-10-18 (§7.3c): engine v11 (now v12) wraps both AUMID call sites + stamps the window-level AUMID from the marker-file identity; an app update reverts it — re-apply via AutoClaw menu [11] (row retired 2026-10-29; run the patch script directly) |
| A7 | 4 Electron instances + 4 gateways is RAM/commit heavy | medium | `AGENTS.md` already records a ZCode commit-limit OOM at 4 instances (`v8-oom-last-os-error 1455`); same exposure. Monitor, and drop instance count if it recurs |

## 10. Decisions — RESOLVED 2026-10-08

- **Q1 — credentials: RESOLVED → seed profile, rotate identity, carry no live tokens.** Supersedes the
  standalone-draft answer of seeding the shared `auth.json`. Rotation is what this repo's conventions
  demand, and it eliminates R1/A1 outright rather than accepting it. Cost: one manual login per clone.
- **Q2 — the 4th port: RESOLVED → patch `app.asar` to widen the port array.** Supersedes "3 clones,
  leave the 4th slot free". Within GHOST an installed-app patch is conventional and the patcher already
  exists as a pattern. Consequence: inst4 becomes a real, startable instance.
- **Q3 — naming: RESOLVED → numbered `inst1`–`inst4`.**

## 11. Explicitly not doing

- Modifying `identity_utils.ps1`. Extracting the `IPropertyStore` AUMID helper so both launchers share
  one implementation (§7.3c) is desirable but `AGENTS.md` marks the file out of scope absent a
  cross-cutting bug fix, so it is flagged as separate work rather than bundled here.
- Using `OPENCLAW_ALLOW_MULTI_GATEWAY=1` — test-only (gated on `VITEST`/`NODE_ENV=test`) and it would
  mask a genuine lock conflict instead of verifying there isn't one (§5.4).
- Using `OPENCLAW_PROFILE` / `--profile <name>`: it renames workspace, locks and logs for no gain
  (§5.6).
- Sharing one state dir between clones — it would share sessions, locks and logs.
- Reusing the ZCode patcher's engine for AutoClaw — separate concerns, separate markers.
- Touching the primary's processes, config or ports.
- Modifying `change_device_id.ps1` or anything under `.context/` (both out of scope per `AGENTS.md`).

## 12. Definition of done

> Re-baselined 2026-10-18: this v1 checklist had gone stale — the suite shipped
> and was live-verified (AGENTS.md multi-instance section) without the boxes
> being ticked. Static gates re-run today: Pester 36/36 incl.
> `repo-integrity.Tests.ps1`, PSScriptAnalyzer Error-clean on src/tools/tests,
> PS 5.1 parse-clean. The remaining open items are the multi-instance LIVE
> verifications beyond inst1 (inst2 seeded, its one manual login pending;
> inst3/inst4 not yet launched). The v2 taskbar live check completed
> 2026-10-18 — see the v2 checklist below.

- [x] `tools/patch_autoclaw_ports.ps1` widens the port array to 8, writes its marker, supports
      `-Restore`, and verifies the constant by re-reading the patched `app.asar`
      (shipped as engine v11 2026-10-17 — ports + taskbar families; now engine v12)
- [ ] `inst1`–`inst4` each hold their own `home\.openclaw-autoclaw` with own `openclaw.json`/`logs`
      (inst1 live-verified 2026-10-16; inst2 seeded 2026-10-17, login pending; inst3/4 unlaunched)
- [ ] each clone's `auth.json.deviceId` and `identity\device.json.deviceId` differ from the primary
      **and** from each other (inst1 verified 2026-10-16; rest pending first launches)
- [ ] no clone's `paired.json` contains the primary's device key or operator token (inst1 verified)
- [ ] all four MCP `/health` endpoints answer ok on distinct ports (inst4 needs the ports patch — shipped)
- [ ] all four gateway `/health` endpoints answer `{"ok":true,"status":"live"}`
      (inst1 verified on :18799; inst2 waits for its manual login per §7.3 sign-in gate)
- [ ] each clone's **actual** gateway port recorded, with drift logged when it differs from requested
      (instance-record.json mechanism live for inst1)
- [x] the primary's `~/.openclaw-autoclaw\openclaw.json` hash unchanged across a full clone cycle
      (inst1, 2026-10-16)
- [x] every new `.ps1` declares `#Requires -Version 5.1` within the first 3 lines (repo-integrity gate)
      (Pester 36/36, 2026-10-18)
- [x] every new `.ps1` passes `[System.Management.Automation.Language.Parser]::ParseFile` with 0 errors
      (Pester 36/36, 2026-10-18)
- [x] `Invoke-ScriptAnalyzer -Path src,tools,tests -Recurse -Settings ./tests/PSScriptAnalyzerSettings.psd1 -Severity Error` clean
      (2026-10-18)
- [x] `Invoke-Pester -CI -Output Detailed` green, including `repo-integrity.Tests.ps1` (README
      documents every `src` script) (36/36, 2026-10-18)
- [x] no `$Input` variable, no ternary `? :`, no `RandomNumberGenerator.Fill()` — PS 5.1 rules
      (2026-10-18: PS 5.1 parser parse-clean proves no ternary; grep clean for bare `$Input` and `Fill()`)
- [x] instances launch and stop via `launch_autoclaw_clone.ps1` and `Launch-AutoClaw-Clone.bat`
      (inst1 launched live 2026-10-16 via the launcher)
- [x] `README.md` / `AGENTS.md` updated for the new scripts; `CHANGELOG.md` entry added
      (README/AGENTS updated; the CHANGELOG entry rides the next release batch, per the
      no-auto-commit rule)
- [x] changes left uncommitted in the working tree for review (AGENTS.md: do not auto-commit)

v2 (§7.3c) — IMPLEMENTED 2026-10-17 (engine v11), live-verified 2026-10-18 (engine v12):

- [x] the app.asar branding patch ships with marker/`patchVersion`, `-Restore`, and verify-by-reread
      (families `aumid-suffix` + `window-identity` inside the existing ports patcher)
- [x] each clone's process/window AUMID resolves to `com.zhipuai.autoclaw.instN`
      (process-level wrapped call sites + window-level `setAppDetails`; the EC-C07 property-store
      readback observed live at the first relaunch, 2026-10-18)
- [x] the in-app window icon is wired with the EC-B02 guard (never a set-but-absent path)
- [x] taskbar groups verified separate while running, each with its color icon (first live relaunch
      2026-10-18: window-level AUMID readback `com.zhipuai.autoclaw.inst1` observed live (EC-C07),
      title "AutoClaw Blue" live, per-clone icon wired — full multi-instance group visual check
      pending more clones running simultaneously)

Engine v12 fix-up (2026-10-18, found by the first live relaunch):

- [x] `setAppDetails` was called with the WRONG option key (`appUserModelId` — Electron 33 takes
      `appId`; binary-verified) → the window AUMID was never stamped. Fixed + verified.
- [x] ctor-time stamping alone does not survive HWND recreation (the ZCode lesson again): the wrap
      now re-stamps on `show` and on every title re-assert. Readback sticks after relaunch.
- [x] `-Force` re-patch extracted the LIVE (already-patched) asar and the engine skipped its own
      wrapped anchors — old injected code survived two re-runs with a fresh marker timestamp. The
      tool now extracts the PRISTINE backup asar whenever the live file carries the wrap marker.
- [x] `launch_autoclaw_clone.ps1` looked for the tray icon under `src\tools\...` (`$RepoRoot` was
      one level short of the repo root) — identity shipped without a window icon. Fixed.
- [x] TEMP DEBUG: `ac-aumid-debug.txt` (user TEMP) traces the window lifecycle (wrap-installed /
      ctor / ready-to-show / shown / reassert / closed) — same removal rule as `ac-argv-debug.txt`.
- [x] `AGENTS.md` updated at implementation time (`CHANGELOG.md` entry goes out with the next
      release batch, per the no-auto-commit rule)

## 13. Provenance

Every claim in §5 came from these reads on this host:

- `C:\Program Files\AutoClaw\resources\app.asar` — byte-level regex scan for
  `PRODUCTIVITY_MCP_CANDIDATE_PORTS`, `PRODUCTIVITY_MCP_HOST`, `GATEWAY_DEFAULT_PORT`,
  `getPreferredPort`, `PORT_PROBE_RANGE`, `requestSingleInstanceLock`,
  `AUTOCLAW_E2E_ALLOW_PARALLEL_INSTANCE`, `OPENCLAW_HOME_DIR`, `OPENCLAW_PROFILE`,
  `setAppUserModelId("com.zhipuai.autoclaw")`, `setProductivityMcpActivePort`,
  `PATH: buildGatewayPathEnv()`, `OPENCLAW_STATE_DIR:` in the gateway-spawn env, `APP_VERSION`
- `C:\Program Files\AutoClaw\resources\gateway\openclaw\gateway-bundle.mjs` — `resolveGatewayLockPath`,
  `resolveGatewayLockDir`, `OPENCLAW_ALLOW_MULTI_GATEWAY`, `resolveGatewayPort`, `applyCliProfileEnv`,
  `--profile <name>`, `--dev`
- `C:\Program Files\AutoClaw\resources\gateway\openclaw\openclaw.mjs` — Node ≥22.19 version gate
- `C:\Users\FOTE\.openclaw-autoclaw\{identity\device.json, devices\paired.json, client-sign.json}`
- `C:\Users\FOTE\AppData\Roaming\AutoClaw\{auth.json, settings.json, launch.json, identity\device.json}`
- `C:\Users\FOTE\AppData\Local\hermes\config.yaml` lines 2464–2466 — Hermes' single `autoclaw` entry,
  `http://127.0.0.1:19681/mcp`
- Live probe: `AutoClaw.exe --user-data-dir=<fresh dir>` alongside the running primary — separate
  profile created, primary's 19681 untouched, `/health` ok on both 18789 and 19681, and
  `os.homedir()` confirmed to honour `USERPROFILE`/`HOME`
- GHOST precedent: `src/windows/launch_zcode_second_instance.ps1` (all 459 lines),
  `AGENTS.md` "Multi-instance conventions (ZCode: Primary + 5 clones)" [renamed since: Fifth/Sixth added] and "Mandatory conventions",
  `docs/architecture.md` "Multi-instance isolation (ZCode: Primary + 5 clones)" [renamed since: Fifth/Sixth added],
  `tests/repo-integrity.Tests.ps1`, `tests/PSScriptAnalyzerSettings.psd1`
- 2026-10-17 (§7.3c v2 implementation probes, app 0.1.13 asar at engine v10): grep —
  `setAppUserModelId("com.zhipuai.autoclaw")` at exactly 2 real call sites (byte offsets
  242472440 and 242488814; the other 5 `setAppUserModelId` hits are the bundled helper lib
  definitions + TS declarations, which take the AUMID as a parameter and are untouched);
  4 minified `new require$$1$5.BrowserWindow(` sites (240945262, 240950100, 241801925,
  242479224); `APP_VERSION = "0.1.13"`; zero pre-existing `AUTOCLAW_AUMID_SUFFIX` /
  `AUTOCLAW_ICON_DIR` / `AUTOCLAW_INSTANCE_NAME` hooks. Engine v11 anchors unit-tested
  against a synthetic tree (macOS const / deep-link URL / helper definition untouched;
  patched output passes `node --check`; re-run idempotent) and dry-run against the
  extracted installed asar.

## 14. Hermes integration

Once the clones are up, add one entry per clone so each is individually addressable in Hermes'
`config.yaml` under `mcp_servers`:

```yaml
  autoclaw-1:
    url: http://127.0.0.1:19682/mcp
    enabled: true
  autoclaw-2:
    url: http://127.0.0.1:19683/mcp
    enabled: true
  autoclaw-3:
    url: http://127.0.0.1:19684/mcp
    enabled: true
  autoclaw-4:
    url: http://127.0.0.1:19685/mcp
    enabled: true
```

Enabling all five puts five AutoClaw tool sets into every Hermes turn's context — enable the one you
need and leave the rest `enabled: false`. It also makes the §5.1 silent-split failure mode far more
visible, since a pinned URL resolving to the wrong instance becomes immediately obvious.