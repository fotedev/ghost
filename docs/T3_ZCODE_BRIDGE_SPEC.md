# T3 ZCode Bridge — specification (2026-10-28)

Status: **spec only — no code yet.** The phased plan in §6 is the next task.

Goal: run the ZCode accounts (Z.ai Start Plan clones) as agents inside
[T3 Code](https://github.com/pingdotgg/t3code) **locally and on our schedule**
— a stock T3 install plus one bridge process, no T3 fork, no waiting for
upstream PRs. If the bridge proves itself, parts go upstream per §7.

Companion docs: [T3_LOCAL_SUPPORT.md](T3_LOCAL_SUPPORT.md) (support matrix,
strategy), [ZCODE_LIGHT_MODE.md](ZCODE_LIGHT_MODE.md) (headless workers, env
levers, model caveats — same prerequisites apply here).

---

## 1. Goals and non-goals

**Goals**

1. A T3 Code "Local ACP command" provider instance per clone account
   (Second..Sixth, optionally Primary), each fully isolated by the four
   verified env levers.
2. A single turn works end-to-end in T3's UI: prompt in, streamed response,
   tool-call visibility, stop/cancel, permission round-trip.
3. The bridge follows the repo's mandatory conventions: verify-after, never
   silent-success, parameterized everything, stdlib-only Node.

**Non-goals**

- No first-class T3 driver / fork changes (§7 explains when that would ever
  be reconsidered).
- No fs/terminal proxying: ZCode executes its own tools inside its own
  permission model; the bridge declares **no** fs/terminal capabilities so T3
  never expects them.
- No new auth flows: sign-in stays the one-time `zcode login zai` per clone
  home (done out-of-band; the launcher prints the recipe).

## 2. Verified ground truth (with provenance)

### 2.1 ACP side (T3 Code, clone at `C:\programming\github\t3code`, HEAD `9826dbb990`)

| # | Fact | Source |
| --- | --- | --- |
| A1 | Transport: JSON-RPC 2.0 over stdio, **NDJSON**, UTF-8, no embedded newlines; the agent is a subprocess; agent stdout must carry only protocol messages; stderr is logs | agentclientprotocol.com v1 transports doc |
| A2 | T3's client sends `initialize {protocolVersion: 2, clientCapabilities, clientInfo}` | `packages/provider-acp/src/server/AcpSessionRuntime.ts` (`initializeOnce`) |
| A3 | **Negotiation is shape-based**: if the initialize *response* is v2-shaped → generation 2; otherwise → generation 1 and T3 drives v1 methods (`authenticate`, `session/load`, `session/set_mode`) | `packages/effect-acp/src/client.ts` (`isV2InitializeResponse` comment: "Antigravity, for example, reports version 2 with the v1 agentInfo/agentCapabilities response shape") |
| A4 | Local ACP command spawn: `{command, args: settings.commandArgs, cwd, env, shell: false}` — `cwd` is the workspace, `env` = the provider instance's environment overrides merged over the host environment | `packages/provider-acp-registry/src/server/AcpRegistrySupport.ts` (`resolve`, local branch) |
| A5 | v1 agent surface: `initialize`, optional `authenticate`, `session/new`, `session/prompt` (blocking; response carries the stop reason), optional `session/load`, optional `session/set_mode`, notification `session/cancel`; client side: `session/update` notifications, `session/request_permission`, optional fs/terminal/elicitation | agentclientprotocol.com v1 overview |
| A6 | Models/reasoning reach T3 from ACP (including `_meta` extensions; T3's own tests read `_meta.modelState` off the initialize response); fallback is manual "Custom models" | T3 `docs/user/providers-acp.md` + `packages/provider-acp/src/server/runtimeModel.test.ts` |
| A7 | ACP does not define account isolation; T3 prescribes isolating via the agent's own configuration. T3 launches local commands without shell expansion | T3 `docs/user/providers-acp.md` |
| A8 | Upstream bar: ACP agents start as Registry entries; a dedicated driver needs replay fixtures (`simple`, `multi_turn`, `queued_turn`, `turn_interrupt`, `message_steering`, `provider_thread_resume`, `tool_call_*`), capability honesty, and `supportedRuntimeModes`; outside PRs have limited review capacity; PRs written by Gemini models or Muse Wonder are closed | `docs/internals/adding-a-provider.md`, `CONTRIBUTING.md` |

### 2.2 ZCode side (bundle probes of `resources\glm\zcode.cjs`, 2026-10-28)

| # | Fact | Detail |
| --- | --- | --- |
| Z1 | Entry: `node zcode.cjs app-server` (synonym `agent-server`; `--stdio` accepted/ignored). Lives until stdin closes. Runs under system node | bundle `main` → `createProtocolProcessLifecycle` |
| Z2 | Framing: **NDJSON**, envelope WITHOUT a `jsonrpc` member — request `{id, method, params?, trace?}`, response `{id, result}`, error `{id, error:{code,message,data?}}`, notification `{method, params}`. String ids ≤ 256 chars, charset `[A-Za-z0-9._~-]+` | `ZCodeProtocolNdjsonConnection` class |
| Z3 | Malformed JSON → `{id:"parse-error", error:-32700}`; invalid envelope → `{id:"invalid-message", error:-32600}`; unknown method → `-32601` | dispatchLine handling |
| Z4 | No `initialize` handshake. Server emits `startup/storagePath`, `startup/storagePrepared`, `startup/storageState` (db migration phases incl. `waiting_for_lock`) while loading; client may call `runtime/capabilities {hostCapabilities:{sessionDirectorySource?}}` → `{independentPlanState, historyFirst, sessionDirectorySource}` | `runZCodeProtocolAgent` wiring |
| Z5 | Session methods: `session/create` (`{sessionId?, workspace, mode?, model?, persistence?, thoughtLevel?, mcpServers?, toolAllowlist?, toolDenylist?, importedHistory?, ...}` → session snapshot), `session/send` (`{sessionId, content, attachments?, expectedRevision, modelSelection?...}`), `session/stop`, `session/cancelBackgroundTask`, `session/list`, `session/resume`, `session/close`, `session/setModel` / `setMode` / `setThoughtLevel`; `session/event` notifications stream per-session events (`deliveryKind: "desktop-continuous"`) | protocol method maps |
| Z6 | `-32010` "A prompt is already running for this session"; revision conflicts asserted via `expectedRevision`; other codes: `-32004 sessionUnavailable`, `-32020 noClientAttached`, `-32021 cancelled`, `-32022 timedOut` | `ProtocolRequestError` |
| Z7 | Server→client **requests** (bridge must answer `{id, result}` or `{id, error}`; re-announced on a doubling 10 s timer; disconnect rejects all): `interaction/requestPermission`, `interaction/requestUserInput`, `interaction/requestProviderRuntimeHeaders`, `interaction/requestOfficialMcpAuthHeaders`, `interaction/browserList` / `browserExecute`, `automation/*`, `bot/channel/reply` | server→client map |
| Z8 | Model control: `session/setModel` (params carry `modelSelection`), `provider/updateAccountConfig`; the standalone login flow (`persistStandaloneCodingPlanConnection`) writes `defaultModelSelection` — a home without it resolves the FREE `opencode-zen` model, not the Start Plan (provider namespace `account:zai-start-plan`, model `GLM-5.3-Flash` per the Primary db's `model_usage`) | bundle + live probes, see ZCODE_LIGHT_MODE.md |
| Z9 | Version markers: CLI `--version` 0.17.0; protocol constants `ZCODE_PROTOCOL_VERSION = 1`, `ZCODE_PROTOCOL_V4_WIRE_VERSION = 3`; the embedded glm binary string says 0.13.3 — versions disagree, so every assumption re-validates against the installed build (signature probe, §5) | bundle constants |

## 3. Architecture

```
T3 Code server (ACP client, Effect-TS)
   │  spawns as Local ACP command: {command: node.exe, args, cwd, env, shell:false}   [A4]
   ▼
tools/t3_zcode_bridge.mjs   (Node ≥ 18, stdlib only; ONE process per T3 provider instance)
   │  -- speaks ACP v1 on its own stdio (NDJSON) toward T3                 [A1/A5]
   │  -- resolves the account: --Instance Second..Sixth (GHOST map) or --home <dir>
   │  -- sets the four env levers: HOME, USERPROFILE -> <CloneHome>;
   │     ZCODE_DATA_BASE_DIR -> <CloneHome>; ZCODE_STORAGE_DIR -> <CloneHome>\.zcode
   │  -- spawns: node <ZCode>\resources\glm\zcode.cjs app-server  (child)   [Z1]
   ▼
zcode app-server  (ZCode Protocol NDJSON; per-home db/config/credentials)  [Z2-Z6]
```

- One bridge process = one account = one clone home (matches A8's "instances
  own credentials"; two T3 provider instances with different `--Instance`
  args share no state).
- The bridge is the only component that knows both dialects. T3 sees a plain
  v1 ACP agent; ZCode sees a normal protocol client.
- The bridge writes ONLY ACP messages to its stdout (A1); the zcode child's
  stdout is piped into the bridge, never inherited; child stderr is prefixed
  and forwarded to the bridge's stderr (T3 logs it).

## 4. Protocol mapping

### 4.1 Lifecycle

| ACP (v1, what T3 sends) | Bridge action | ZCode Protocol |
| --- | --- | --- |
| `initialize {protocolVersion:2, clientCapabilities, clientInfo}` | Respond **v1-shaped** result: `{protocolVersion: 1, agentCapabilities:{loadSession:false, auth:{logout:false}}, authMethods: []}` (A3's shape detection then pins generation 1) | — (then `runtime/capabilities` after the child's `startup/storageState` reaches `ready`) |
| `session/new {cwd, mcpServers, ...}` | Map cwd → workspace; pass T3's MCP servers through only if Phase-B proves the param is honored (else omit and log) | `session/create {workspace, mode:"build", persistence:"persistent"}` |
| `session/prompt {sessionId, prompt}` | Store the pending ACP request id; send content; tail `session/event` until the turn-end event; stream updates as they arrive | `session/send {sessionId, content, expectedRevision}` |
| `session/prompt` response | `{stopReason}` — `end_turn` on completed, `cancelled` on stop, `error` mapping per §4.4 | turn-end event (Phase A catalogues the exact event discriminators) |
| `session/cancel` (notification) | Best-effort; handle the "cancel before the turn registered" trap (A8) by reconciling the response of the pending `session/send` | `session/stop` |
| `session/set_mode` | Map 1:1 | `session/setMode` (build / edit / plan / yolo / guarded) |
| `session/load` | Declared unavailable (`loadSession:false`) — resume is out of scope for v1 of the bridge | `session/resume` / `session/list` (future) |

### 4.2 Session mode advertisement

`session/new`'s ACP response advertises the five ZCode permission modes as
session modes (`build` default). Only modes ZCode enforces natively are
offered (A8: never imitate a missing mode). T3 runs unoffered stored modes as
Supervised on its side — acceptable.

### 4.3 Streaming updates

| ZCode `session/event` payload | ACP `session/update` |
| --- | --- |
| assistant text deltas | `agent_message_chunk` |
| thinking deltas | `agent_thought_chunk` |
| tool started / progressed / finished | `tool_call_update` (first upsert creates — v2 semantics applied early is fine; v1 tolerates `tool_call_update` as create) |
| plan / todo mutations | `plan` |
| turn terminal state | (stops the stream; drives the `session/prompt` response) |

Exact event discriminators are a **Phase-A deliverable**: the probe dumps the
full event vocabulary of a real turn before any mapping is finalized.

### 4.4 Errors

| ZCode | ACP bridge behaviour |
| --- | --- |
| `-32010` prompt already running | reject the ACP prompt with a JSON-RPC error; never queue |
| `-32021 cancelled` | `stopReason: "cancelled"` |
| Start-Plan admission control / quota signatures (3009 family) | classify as a usage-limit failure; surface `stopReason` + message (A8: usage limits are not generic failures) |
| `-32004 sessionUnavailable` | JSON-RPC error; drop the cached session id |
| parse/envelope errors from the child (Z3) | bridge-side bug alarm on stderr; the offending line is logged verbatim |

### 4.5 Server→client requests (Z7)

| ZCode request | Bridge policy |
| --- | --- |
| `interaction/requestPermission` | Forward as ACP `session/request_permission` (options pass through verbatim per A8); map the answer back; guaranteed decline path |
| `interaction/requestUserInput` | Forward as ACP `elicitation/create` if Phase-C proves it, else decline and log |
| `requestProviderRuntimeHeaders`, `requestOfficialMcpAuthHeaders`, `browserList`, `browserExecute`, `automation/*`, `bot/channel/reply` | **Default-decline**: answer `{id, error:{code:-32602,...}}` (or an empty result if ZCode tolerates only that — Phase A verifies per method); log once per method so the gap is visible, never silent |

## 5. Edge cases

1. **stdout purity (A1):** any bridge log goes to stderr. A stray `console.log`
   in the bridge corrupts the ACP stream — the mapping module gets a lint-rule
   note and the probe harness asserts stdout purity end-to-end.
2. **Same-home contention:** a clone home serves ONE writer story at a time.
   If the desktop instance for that home is running, `startup/storageState`
   shows `waiting_for_lock` (Z4) — the bridge waits it out and logs; the run
   book says: light worker (bridge or REPL) XOR desktop app per home.
3. **Provider throttle:** Start-Plan admission control (3009) still applies
   per account; T3 parallel threads on one account share its quota. Not a
   bridge bug — surfaced via §4.4 usage-limit mapping.
4. **Version churn (Z9):** every bridge start greps the installed
   `zcode.cjs` for `ZCODE_PROTOCOL_VERSION` and refuses to start a mapping
   against an unknown wire version (verify-after, never silent-success).
   The probe script revalidates assumptions after any ZCode update.
5. **Standalone login prerequisite (Z8):** bridge start checks
   `<CloneHome>\.zcode\v2\provider_config.json` for `defaultModelSelection`;
   missing → stderr warning (the account will run on the free zen model) but
   the bridge still starts.
6. **Revision discipline:** every `session/send` carries the latest
   `expectedRevision` from the create/send snapshot (Z5/Z6); a conflict is
   re-read once, then surfaced as an error.
7. **Node availability:** the bridge requires system node ≥ 18 (functional
   probe, same rule as the repo's Python convention); it spawns the child
   with the SAME node it runs on.

## 6. Phased implementation (acceptance criteria included)

- **A — Live protocol probe** (`tools/t3_bridge_probe.mjs`): spawn
  `app-server` under a chosen clone env; capture `startup/*`; call
  `runtime/capabilities`, `session/create`, `session/send "Reply with
  exactly: OK"`, `session/stop`; dump the complete `session/event` vocabulary
  of a real turn to a transcript artifact; probe each Z7 request's tolerance
  to a decline. **Accept:** a turn completes; the event catalogue and
  decline-tolerance table are recorded in this spec's addendum.
- **B — Minimal bridge** (`tools/t3_zcode_bridge.mjs`): §4.1 lifecycle +
  text/thought chunks + cancel. A fake-ACP-client script drives the bridge
  end-to-end. **Accept:** a one-turn conversation completes through the
  bridge with stopReason `end_turn`; stdout purity asserted.
- **C — Permissions and modes:** `interaction/requestPermission` ⇄
  `session/request_permission`; five modes advertised and switchable.
  **Accept:** a guarded-mode tool approval round-trips from T3's UI (manual,
  supervised run) and the decline path never hangs the turn.
- **D — Models:** advertise the account's GLM models (Phase A confirms the
  `_meta.modelState` shape or fall back to T3's "Custom models");
  `session/setModel` on switch; usage-limit classification. **Accept:**
  switching GLM-5.3 ↔ GLM-5.3-Flash mid-conversation takes effect (verified
  by the clone's `model_usage` rows).
- **E — T3 wiring + live acceptance:** register one Local ACP command per
  account (`node.exe` + bridge path + `--Instance <name>`); runbook: two
  instances (e.g. Second + Third) side by side in T3, distinct accounts,
  parallel turns, cancel storm, desktop app closed for each home used.
  **Accept:** the runbook passes on the real box and T3_LOCAL_SUPPORT.md's
  matrix row flips to "verified".

## 7. Upstream strategy (later, only after E passes)

1. **ACP Registry entry (preferred, light):** publish the bridge as a small
   package and register it as an ACP agent — A8 says ACP agents START as
   Registry entries with no per-agent handling. This is a docs+manifest PR,
   not a driver.
2. **First-class driver (only if forced):** a `packages/provider-zcode`
   driver per `docs/internals/adding-a-provider.md` is justified ONLY if the
   generic ACP surface provably loses features (e.g. `_meta.modelState`
   insufficient, native question semantics). The bar: replay fixtures for
   every scenario in A8, `ProviderAdapterV2` implementation, settings schema,
   `builtInDrivers.ts` + client registration + docs. Big; needs the T3
   replay-testkit workflow first.
3. **Mechanics:** GitHub fork of pingdotgg/t3code → branch → PR (the local
   clone at `C:\programming\github\t3code` gains a `fork` remote). Mind
   `CONTRIBUTING.md`: limited review capacity, coherent small scope, and the
   "models we do not accept" clause (nothing authored by Gemini / Muse
   Wonder; our GLM tooling is not on that list).
4. What never goes upstream: per-clone account wiring, GHOST menu entries,
   clone-home env levers.

---

## 8. Phase A/B findings addendum (2026-10-29 — live wire results)

Phases A and B are IMPLEMENTED and live-verified: `tools/t3_bridge_lib.mjs`
(shared), `tools/t3_bridge_probe.mjs` (phase A), `tools/t3_zcode_bridge.mjs`
(phase B), `tools/t3_bridge_fake_client.mjs` (acceptance harness), gated by
`tests/t3_bridge.Tests.ps1` (Pester 56/56 incl. the live run). Everything in
sections 2-5 that the wire contradicted or sharpened is corrected here.

### 8.1 Wire corrections (verified against the real server)

| Spec claim as written | What the wire actually does |
| --- | --- |
| `session/create {workspace: cwd}` | `workspace` is an OBJECT `{workspacePath, workspaceKey}` and the validator enforces `workspaceKey === workspaceIdentity?.trim() \|\| workspacePath` (bundle `Q0r`) — key = path verbatim (lib `zcodeWorkspace()`) |
| `session/prompt` blocks like ACP | `session/send` is ASYNC: it returns immediately `{accepted, sessionId, stateRevision}` and the turn runs via events |
| events stream after create | `session/subscribe {sessionId, deliveryKind: "desktop-continuous"}` is REQUIRED before any `session/event` flows |
| turn-end via session/event | terminal arrives BOTH as `session/event` (`turn.completed`/`turn.failed`) and as `v4/telemetry/event {kind:"turn.terminal", status, errorCode?}` — the bridge honours either |
| revision from snapshots only | `state.updated` notifications carry `{patch, reason, revision}` — the AUTHORITATIVE revision source; `-32009` on a stale value is healed by one `session/read` re-sync (lib rule, spec 5.6) |
| permission answer shape | each zcode option carries its own answer object (`response: {decision: "allow"\|"deny"\|"escalate"\|"modify", reason?, modifiedInput?}`) — the bridge returns the chosen option's object verbatim |
| default-decline for server→client requests | `session/requestRuntimePreferences` (scope `runtime-materialization`) is MANDATORY during create — a decline ABORTS the create; minimal valid answer: `{nativeSearchEnhancementsEnabled: false}` (bundle schema Utn: only field without a default). `interaction/requestOfficialMcpAuthHeaders` tolerates error-declines (verified 4×) |
| `--model` on create | create accepts `model {providerId, modelId, options?{reasoningLevel}}`; several zen models REQUIRE the level (`"Reasoning level is required"`) — levels come from the `state.updated` `model.available` patches (`reasoning.levels[].value`) |

### 8.2 Session event vocabulary (from `session/event` + bundle schemas)

Envelope: `{type, payload, seq, sessionId, turnId, deliveryKind, eventId,
timestamp, traceId}`. Observed live: `session.titleUpdated {payload:{title,
source}}`, `turn.started {payload:{messageId, input, queryId,...}}`,
`session.updated {payload:{messageCount, providerId, modelId, toolCount,...}}`,
`model_request_started` / `model_request_failed {payload:{baseURL, providerId,
modelId, maxAttempts,...}}`, `turn.failed {payload:{error:{type, code, message,
detail, attribution, stack}}}`. Full bundle type list (the bridge maps the
bold ones): turn.started / **turn.completed** `{response, tokenCount,
toolCallCount, duration,...}` / **turn.failed** / turn.terminal /
turn.steerQueued / turn.steerDrained / **message.upserted** `{content,
attachments?, toolCalls?}` / message.removed / **part.started** / **part.delta**
`{messageId, partId, field: "text"\|"reasoning"\|"input"\|"output", delta}` /
**part.upserted** `{part:{type:"text"\|"reasoning"\|"file"\|..., text}}` /
part.removed / model.streaming / **tool.updated** / tool.lifecycle /
**permission.requested** `{toolCallId, toolName, riskLevel, reason, input,
options:[{optionId, kind, name, response}]}` / permission.resolved /
userInput.requested `{requestId, prompt, inputType, choices?}` / todo.write /
plan.enter / plan.exit / subagent.* / workflow.* / checkpoint.created /
session.created / session.resumed / session.upserted / session.closed /
session.removed / session.persisted / streamRecovery.updated.

### 8.3 Model reality on this box (2026-10-29)

- The bare CLI's provider registry contains ONLY the free `opencode-zen-chat`
  models; `provider/refreshRegistry {reason}` runs but does NOT materialize
  the Start Plan provider — that requires the one-time standalone
  `zcode login zai` per home (spec Z8 confirmed; the desktop app pushes its
  own registry via `provider/updateAccountConfig`, which the bridge does not
  replicate).
- Every free zen model was rejecting upstream during the session
  (`invalid_model_request` at the provider; one default-model turn retried 11
  times for >150 s). Consequence: `turn.completed` text-delta paths are
  bundle-schema-derived (8.2), not yet observed live. The fake client gates
  hard on mechanics (initialize / session/new / cancel→`session/stop`
  issuance / clean exit / stdout purity) and reports MODEL-UNAVAILABLE
  instead of failing; its `end_turn` assertion becomes live automatically the
  first time a working model answers (post-login or upstream recovery).

### 8.4 Acceptance status

- Phase A (probe): PASS on every mechanical item (framing zero-violations,
  handshake, create, subscribe, event catalogue, revision sync, stop). The
  "successful turn" item awaits a working model (8.3).
- Phase B (bridge + fake client): FAKE-CLIENT PASS (v1-shape initialize,
  session/new with the five modes, prompt round-trip, cancel→stop issued,
  clean exit, stdout purity). Live T3 wiring (phase E) pending — T3 Code is
  not installed on this box yet; wiring values for that day:
  executable = `C:\Program Files\nodejs\node.exe`, arguments (one per row) =
  `<repo>\tools\t3_zcode_bridge.mjs`, `--Instance`, `Second` (repeat per
  account), display name = `ZCode Blue` (per the instance map).

---

## 9. Phase D/E wiring addendum (2026-10-29 evening)

### 9.1 What shipped

- **Phase D models**: the bridge answers `session/new` with a TOP-LEVEL
  `models: {currentModelId, availableModels}` (T3's generic acpRegistry
  provider reads models from the session-setup response — `compat.ts`
  `SessionModelState`; the initialize `_meta.modelState` path is Grok-only,
  corrected from §8.4's earlier assumption). Catalogue sources: the home's
  `v2\config.json` enabled providers (plan families also registered under
  their `account:<family>` runtime namespace) + live `state.updated`
  `model.available` patches; `currentModelId` from the standalone-login
  `defaultModelSelection`. `session/set_model {sessionId, modelId}` (v1 name
  verified in `rpc.ts`) unpacks `"providerId/modelId[/level]"` into ZCode's
  `session/setModel {modelSelection}`. Usage-limit classification keys on the
  structured `errorCode` first. Fake client asserts the catalogue
  (6 models for a clone home, current = `account:zai-start-plan/GLM-5.3-Flash`).
- **Login helper**: `launch_zcode_cli_light.ps1 -Login` (GHOST.bat ZCode
  **[28]**, gid 71) runs the one-time `zcode login zai` for the chosen clone
  home and verifies `defaultModelSelection` landed (exit 0).
- **T3 Code installed**: v0.1.4 via `winget install T3Tools.T3Code`
  (`C:\Users\FOTE\AppData\Local\Programs\T3Code\T3 Code (Beta).exe`), first
  run completed (`~/.t3/` created). The five provider instances were
  pre-seeded into `~/.t3/userdata/settings.json` (`providerInstances`:
  `zcode-second`..`zcode-sixth`, driver `acpRegistry`, `source: "local"`,
  `commandPath` = node.exe, `commandArgs` = `[bridge, --Instance, <name>]`,
  displayName "ZCode <Color>" + accent) — backup + verify-after; the server
  trace shows `zcode-second` loaded. Settings file reference:
  `~/.t3/userdata/settings.json` (T3 reads it at startup; the desktop app
  must be closed while editing it).

### 9.2 Live acceptance runbook (user-supervised; the remaining C/E gate)

Prerequisite per account: GHOST.bat ZCode **[28]** → pick the clone →
browser sign-in (one-time). Then, in T3 Code:

1. Settings → Providers: the five "ZCode <Color>" instances render.
2. New thread on ZCode Blue → prompt → **streamed reply ending normally**
   (this is the end_turn gate — unblocked by the [28] login or upstream
   model recovery).
3. Mode switch to guarded → prompt that runs a tool → the permission card
   appears → approve, then deny on a second one (both paths must settle).
4. Model picker → switch GLM-5.3-Flash ↔ GLM-5.3 → the next turn runs on the
   chosen model (verify via the clone db's `model_usage.provider_id`).
5. Stop mid-turn → stopReason `cancelled`.
6. Two accounts side by side (Blue + Red threads) run concurrently without
   cross-talk (each spawns its own bridge process + clone-home app-server).
7. Record the outcome here; flip the T3_LOCAL_SUPPORT matrix row to
   "verified" and consider the upstream ACP Registry PR (§7).

Known limitation carried from §8.3: without the per-home login the catalogue
advertises the free-zen + plan-namespace models but turns fail upstream; the
runbook's step 2 is the only item that strictly requires a working model.

### 9.3 First live incident (2026-10-29 ~23:30) — diagnosed from T3's own logs

Symptom: T3 "Failed to open acpRegistry provider session" after ~3-4 minutes
on zcode-second/zcode-fourth threads ("The ACP agent did not resolve and
create a test session within 60 seconds"). Evidence
(`~/.t3/userdata/logs/provider/events.<threadId>.log`): `initialize`
succeeded → `session/new` SUCCEEDED (with models) → `session/prompt` started
and never settled — the home had no `[28]` login, so the turn ran on the
broken free zen model and hung in its 11-attempt retry loop. The bridge was
working; the account had no working model.

Bridge hardening shipped in response:

1. **Create-with-known-model**: `session/new` now passes the home's known
   default (`defaultModelSelection`) as `model` — post-login turns run on the
   plan directly, and pre-login the registry rejects create FAST, translated
   to: "this clone home cannot run <model> yet - Run GHOST.bat ZCode [28]
   (one-time login) for this clone, then retry." (`zcodeErrorCode:
   login_required`). Non-registry failures fall back to the server default
   model with a loud stderr warning.
2. **180 s turn watchdog**: a prompt with no terminal gets `session/stop`
   plus a clean `-32001 turn_watchdog` error instead of hanging for minutes.

Verified: the fake client on an unlogged home now passes the fast-fail
branch (seconds, not minutes). The threads light up for real the moment the
per-home `[28]` login runs — that step remains the user's browser-OAuth
touchpoint.
