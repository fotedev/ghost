#!/usr/bin/env node
// T3 Code <-> ZCode bridge (docs/T3_ZCODE_BRIDGE_SPEC.md, phase B).
//
// ONE process per T3 "Local ACP command" provider instance = one ZCode clone
// account. Speaks ACP v1 on THIS process's stdio (what T3 launches) and drives
// `zcode.cjs app-server` (ZCode Protocol, NDJSON) as a child under the four
// clone-home env levers. Stdout of THIS process carries ONLY ACP messages
// (ACP transports rule) - every log line goes to stderr.
//
// Mapping provenance: spec section 2 (ACP shapes from the t3code clone's
// generated v1 schema; ZCode shapes from bundle probes + live transcripts
// 2026-10-29). Content-delta shapes (part.delta / turn.completed payloads)
// are bundle-schema-derived; no free zen model was reachable upstream during
// the probe session, so those paths activate the first time a working model
// exists (they follow the verified envelope contract).
//
// Usage (what T3 runs):
//   node tools\t3_zcode_bridge.mjs --Instance Second
//   node tools\t3_zcode_bridge.mjs --home C:\Users\FOTE\SixthCloneHome
import fs from 'node:fs';
import path from 'node:path';
import {
    NdjsonConnection,
    ZCODE_MODES,
    parseArgs,
    readWireVersion,
    resolveInstanceHome,
    resolveZcodeCli,
    spawnAppServer,
    zcodeWorkspace,
} from './t3_bridge_lib.mjs';

const spec = { Instance: 'value', home: 'value', 'zcode-cli': 'value', mode: 'value', model: 'value' };
const args = parseArgs(process.argv.slice(2), spec);
const defaultMode = ZCODE_MODES.includes(args.mode) ? args.mode : 'build';
// Optional session model override (Ll shape): "providerId/modelId[/reasoningLevel]".
// Without it the session uses the home's default model (the standalone-login
// plan default once `zcode login zai` ran; the free zen fallback before that).
const sessionModel = args.model
    ? (() => {
          const parts = args.model.split('/');
          if (parts.length < 2) throw new Error(`--model expects providerId/modelId[/level], got "${args.model}"`);
          return {
              providerId: parts[0],
              modelId: parts[1],
              ...(parts[2] ? { options: { reasoningLevel: parts[2] } } : {}),
          };
      })()
    : undefined;

const log = (...m) => process.stderr.write(`[t3-zcode-bridge] ${m.join(' ')}\n`);
const warnOnce = new Set();
const warnOnceLog = (key, ...m) => {
    if (warnOnce.has(key)) return;
    warnOnce.add(key);
    log('WARN:', ...m);
};

// --- model catalogue (phase D) ------------------------------------------------
// T3's generic Local ACP command provider reads models from the session/new
// response's TOP-LEVEL `models` field ({currentModelId, availableModels:
// [{modelId, name}]}) — initialize _meta.modelState is Grok-only (spec 8.5).
// ACP model ids are encoded "providerId/modelId[/reasoningLevel]" (the same
// format the probe accepts) so session/set_model can unpack them back into
// ZCode's Ll modelSelection shape.
const modelCatalogue = new Map(); // acpModelId -> {modelId, name}
let currentModelAcpId = null;

function addCatalogueModel(providerId, modelId) {
    if (!providerId || !modelId) return;
    const acpId = `${providerId}/${modelId}`;
    if (!modelCatalogue.has(acpId)) modelCatalogue.set(acpId, { modelId: acpId, name: `${providerId}/${modelId}` });
}

// Seed from the home's v2 config: enabled providers expose their model lists
// there (app-side keys like "builtin:zai-start-plan"). For plan-family keys we
// ALSO register the observed runtime namespace variant ("account:zai-start-plan")
// because the runtime registry materializes plan providers under it (spec Z8/§8).
function seedModelCatalogueFromHome() {
    try {
        const cfg = JSON.parse(fs.readFileSync(path.join(cloneHome, '.zcode', 'v2', 'config.json'), 'utf8'));
        const providers = cfg?.provider ?? {};
        for (const [key, entry] of Object.entries(providers)) {
            if (entry?.enabled !== true) continue;
            const models = entry.models ?? {};
            const variants = [key];
            const family = key.replace(/^builtin:/, '');
            if (/^(zai|bigmodel)-(start|coding)-plan$/.test(family)) variants.push(`account:${family}`);
            for (const modelId of Object.keys(models)) {
                for (const variant of variants) addCatalogueModel(variant, modelId);
            }
        }
    } catch (err) {
        warnOnceLog('catalogue', `config.json model seed skipped (${err.message ?? err}).`);
    }
    // Current selection: the standalone-login default when present.
    try {
        const provCfg = JSON.parse(fs.readFileSync(path.join(cloneHome, '.zcode', 'v2', 'provider_config.json'), 'utf8'));
        const sel = provCfg?.config?.defaultModelSelection;
        if (sel?.providerId && sel?.modelId) {
            currentModelAcpId = sel.options?.reasoningLevel
                ? `${sel.providerId}/${sel.modelId}/${sel.options.reasoningLevel}`
                : `${sel.providerId}/${sel.modelId}`;
        }
    } catch { /* catalogue stays without a current id */ }
    if (currentModelAcpId && !modelCatalogue.has(currentModelAcpId)) {
        addCatalogueModel(currentModelAcpId.split('/')[0], currentModelAcpId.split('/')[1]);
    }
}

function buildModelState() {
    if (modelCatalogue.size === 0) return null; // T3 falls back to Custom models
    const availableModels = [...modelCatalogue.values()];
    const currentModelId = currentModelAcpId && modelCatalogue.has(currentModelAcpId)
        ? currentModelAcpId
        : availableModels[0].modelId;
    return { currentModelId, availableModels };
}

function parseAcpModelId(acpId) {
    const parts = String(acpId ?? '').split('/');
    if (parts.length < 2) return null;
    return {
        providerId: parts[0],
        modelId: parts[1],
        ...(parts[2] ? { options: { reasoningLevel: parts[2] } } : {}),
    };
}

// --- startup: resolve, gate, spawn -------------------------------------------
const cloneHome = resolveInstanceHome(args.Instance ?? 'Second', args.home);
const zcodeCli = resolveZcodeCli(args['zcode-cli']);
const wire = readWireVersion(zcodeCli);
if (!wire.ok) {
    log(`FATAL: wire-version gate failed (${JSON.stringify(wire)}) - refusing to start (spec 5.4).`);
    process.exit(1);
}
log(`instance=${args.Instance ?? '(home)'} home=${cloneHome}`);
log(`cli=${zcodeCli} wire=${wire.protocolVersion}/v4:${wire.v4WireVersion}`);

// Standalone-login check (spec 5.5): without defaultModelSelection the child
// runs on the free opencode-zen model, not the account's Start Plan.
(() => {
    try {
        const provCfg = JSON.parse(fs.readFileSync(path.join(cloneHome, '.zcode', 'v2', 'provider_config.json'), 'utf8'));
        if (!provCfg?.config?.defaultModelSelection) {
            warnOnceLog('login', `no standalone CLI login in this home - turns will run on the FREE zen model.`);
            warnOnceLog('login', `one-time fix: set the four env levers (see docs/ZCODE_LIGHT_MODE.md) then run: node "${zcodeCli}" login zai`);
        }
    } catch { warnOnceLog('login', 'provider_config.json unreadable - login state unknown.'); }
})();

// Catalogue seed runs AFTER cloneHome exists (it reads the home's config).
seedModelCatalogueFromHome();

// --- child (zcode app-server) --------------------------------------------------
const child = spawnAppServer(zcodeCli, cloneHome);
let childExit = null;
child.on('exit', (code) => {
    childExit = code;
    log(`zcode app-server exited (code=${code}) - failing all pending ACP requests.`);
    for (const p of acpPending.values()) {
        p.reject(jsonRpcError(p.id, -32001, `zcode app-server exited (code ${code})`));
    }
    acpPending.clear();
});

// ZCode-side request plumbing
let zcNextId = 1;
const zcPending = new Map();
let storageReady = false;
let storageWaiter = null;
let latestRevision = null;

function zcRequest(method, params, timeoutMs = 30000) {
    if (childExit !== null) return Promise.reject(new Error(`zcode app-server already exited (code ${childExit})`));
    const id = zcNextId++;
    zc.send({ id, method, params });
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { zcPending.delete(id); reject(new Error(`timeout ${timeoutMs}ms: ${method}`)); }, timeoutMs);
        zcPending.set(id, { resolve, reject, method, timer });
    });
}

function zcRespond(id, payload) {
    zc.send({ id, ...payload });
}

async function zcSendWithRevisionSync(sessionId, content, extra = {}) {
    const attempt = () => zcRequest('session/send', {
        sessionId, content, expectedRevision: latestRevision ?? 0, ...extra,
    });
    try {
        return await attempt();
    } catch (err) {
        if (!/-32009/.test(String(err.message))) throw err;
        const read = await zcRequest('session/read', { sessionId, contentProfile: 'index' });
        if (typeof read?.runtime?.stateRevision === 'number') latestRevision = read.runtime.stateRevision;
        return await attempt();
    }
}

function answerServerToClient(msg, payload) {
    zcRespond(msg.id, payload);
}

const declineServerToClient = (msg) => {
    warnOnceLog(`decline:${msg.method}`, `declining server->client request "${msg.method}" (params: ${JSON.stringify(msg.params ?? {}).slice(0, 200)}).`);
    answerServerToClient(msg.id, { error: { code: -32602, message: `t3-zcode-bridge does not support ${msg.method}` } });
};

// --- ACP side -------------------------------------------------------------------
const acpPending = new Map(); // id -> {resolve, reject}
let acpNextId = 1;
const sessions = new Map(); // acpSessionId (= zcode sessionId) -> session state

function acpSend(msg) {
    // THE only stdout writer in this process.
    process.stdout.write(JSON.stringify(msg) + '\n');
}
function acpNotify(method, params) {
    acpSend({ method, params });
}
function jsonRpcError(id, code, message, data) {
    return { id, error: { code, message, ...(data ? { data } : {}) } };
}
function acpRespond(id, payload) {
    // Client-request responses are written inline (no pending entry needed):
    // acpPending only tracks bridge->client requests awaiting answers.
    acpSend({ id, ...payload });
}

function acpRequest(method, params, timeoutMs = 60000) {
    const id = acpNextId++;
    acpSend({ id, method, params });
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { acpPending.delete(id); reject(new Error(`client timeout ${timeoutMs}ms: ${method}`)); }, timeoutMs);
        acpPending.set(id, {
            resolve: (result) => { clearTimeout(timer); resolve(result); },
            reject: (error) => { clearTimeout(timer); reject(error); },
            id,
        });
    });
}

// --- session update streaming ---------------------------------------------------
function emitUpdate(sessionId, update) {
    acpNotify('session/update', { sessionId, update });
}

const textChunk = (text) => ({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } });
const thoughtChunk = (text) => ({ sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text } });

const TOOL_KIND_BY_NAME = (name = '') => {
    const n = name.toLowerCase();
    if (/(bash|shell|exec|command|terminal)/.test(n)) return 'execute';
    if (/(edit|write|patch|apply)/.test(n)) return 'edit';
    if (/(read|grep|glob|search|list|find)/.test(n)) return 'search';
    if (/(fetch|web|browser|http)/.test(n)) return 'fetch';
    if (/(think|plan|todo)/.test(n)) return 'think';
    return 'other';
};

const PERMISSION_KIND_BY_OPTION = (kind = '') => {
    const k = kind.toLowerCase();
    if (k.startsWith('reject') || k.startsWith('deny')) return 'reject_once';
    if (k.startsWith('allow_always') || k === 'always') return 'allow_always';
    return 'allow_once';
};

// Per-turn streaming state: keyed by zcode turnId, tracks how much of each
// part/message we already streamed so upserts never duplicate deltas.
function turnState(session, turnId) {
    let t = session.turns.get(turnId);
    if (!t) {
        t = { emittedByPart: new Map(), sawPartEvents: false, sawContent: false, cancelRequested: false };
        session.turns.set(turnId, t);
    }
    return t;
}

function streamPartText(session, turnId, partId, fullText, field) {
    if (typeof fullText !== 'string' || fullText.length === 0) return;
    const t = turnState(session, turnId);
    const prev = t.emittedByPart.get(partId) ?? '';
    if (fullText.length <= prev.length) return;
    const delta = fullText.slice(prev.length);
    t.emittedByPart.set(partId, fullText);
    t.sawPartEvents = true;
    t.sawContent = true;
    emitUpdate(session.id, field === 'reasoning' ? thoughtChunk(delta) : textChunk(delta));
}

function mapStopError(zcodeError) {
    const message = zcodeError?.message ?? zcodeError?.underlyingErrorMessage ?? 'turn failed';
    const code = String(zcodeError?.code ?? '');
    // Spec 4.4/§8: classify on the structured errorCode FIRST, then the
    // message — quota/admission/model-availability failures are usage-limit
    // class, everything else passes through verbatim.
    const modelClass = /(invalid_model_request|model_unavailable|quota|rate.?limit|3009|admission|concurrency|throttl)/i;
    const usageLimit = modelClass.test(code) || modelClass.test(message);
    return jsonRpcError(null, -32001, usageLimit ? `usage-limit/model-unavailable: ${message}` : message, {
        zcodeErrorCode: code || undefined,
    }).error;
}

// --- zcode event pump -------------------------------------------------------------
const zc = new NdjsonConnection({
    input: child.stdout,
    output: child.stdin,
    onMessage: (msg) => {
        // server->client REQUEST (must be answered; spec Z7)
        if (msg.id !== undefined && msg.method !== undefined) {
            handleServerToClientRequest(msg);
            return;
        }
        // response to OUR request
        if (msg.id !== undefined) {
            const p = zcPending.get(msg.id);
            if (p) {
                clearTimeout(p.timer);
                zcPending.delete(msg.id);
                if (msg.error !== undefined) p.reject(Object.assign(new Error(`zcode error ${msg.error.code}: ${msg.error.message}`), { zcode: msg.error }));
                else p.resolve(msg.result);
            }
            return;
        }
        // notification
        if (msg.method === 'startup/storageState' && msg.params?.phase === 'ready') {
            storageReady = true;
            if (storageWaiter) { const w = storageWaiter; storageWaiter = null; w(); }
            return;
        }
        if (msg.method === 'state.updated') {
            if (typeof msg.params?.revision === 'number') latestRevision = msg.params.revision;
            // Live model catalogue augmentation: runtime registry truth wins.
            const available = msg.params?.patch?.model?.available;
            if (Array.isArray(available)) {
                for (const entry of available) {
                    const ref = entry?.ref;
                    if (ref?.providerId && ref?.modelId) {
                        addCatalogueModel(ref.providerId, ref.modelId);
                        if (!currentModelAcpId) currentModelAcpId = `${ref.providerId}/${ref.modelId}`;
                    }
                }
            }
            return;
        }
        if (msg.method === 'session/event') {
            handleSessionEvent(msg.params ?? {});
            return;
        }
        if (msg.method === 'v4/telemetry/event' && msg.params?.kind === 'turn.terminal') {
            settleTurnByTelemetry(msg.params);
            return;
        }
        // startup/* and other informational notifications: ignored by design.
    },
    onParseError: (line, err) => {
        warnOnceLog('child-parse', `non-protocol line from zcode child: ${String(line).slice(0, 160)} (${err.message})`);
    },
    onClose: (reason) => log(`zcode transport closed: ${reason}`),
});

child.stderr.setEncoding('utf8');
child.stderr.on('data', (chunk) => {
    for (const line of String(chunk).split('\n')) {
        if (line.trim()) log(`child: ${line.slice(0, 240)}`);
    }
});

function handleServerToClientRequest(msg) {
    switch (msg.method) {
        case 'session/requestRuntimePreferences': {
            // MANDATORY during session/create (bundle schema Utn: this boolean
            // is the only field without a default) - a decline aborts create.
            answerServerToClient(msg, { result: { nativeSearchEnhancementsEnabled: false } });
            return;
        }
        case 'interaction/requestPermission': {
            forwardPermissionRequest(msg);
            return;
        }
        case 'interaction/requestUserInput': {
            // Phase-C refinement target; for now use the legal decline path.
            warnOnceLog('user-input', `userInput.requested declined (interactive questions not bridged yet).`);
            answerServerToClient(msg, { result: { cancelled: true } });
            return;
        }
        default:
            declineServerToClient(msg);
    }
}

async function forwardPermissionRequest(msg) {
    const params = msg.params ?? {};
    const sessionId = params.sessionId;
    const options = Array.isArray(params.options) ? params.options : [];
    try {
        if (!sessionId || !sessions.has(sessionId) || options.length === 0) {
            // No ACP session to ask: pick the first deny-ish option, else deny.
            const deny = options.find((o) => /deny|reject/i.test(String(o.kind))) ?? null;
            answerServerToClient(msg.id, { result: deny ? deny.response : { decision: 'deny' } });
            return;
        }
        const acpOptions = options.map((o) => ({
            optionId: o.optionId,
            name: String(o.name ?? o.optionId),
            kind: PERMISSION_KIND_BY_OPTION(String(o.kind ?? '')),
        }));
        const outcome = await acpRequest('session/request_permission', {
            sessionId,
            toolCall: {
                toolCallId: String(params.toolCallId ?? `perm-${params.requestId ?? 'unknown'}`),
                title: String(params.toolName ?? 'tool'),
                kind: TOOL_KIND_BY_NAME(String(params.toolName ?? '')),
            },
            options: acpOptions,
        }, 300000);
        const chosenId = outcome?.outcome?.optionId;
        const chosen = options.find((o) => o.optionId === chosenId);
        if (outcome?.outcome?.outcome === 'cancelled' || !chosen) {
            const deny = options.find((o) => /deny|reject/i.test(String(o.kind))) ?? null;
            answerServerToClient(msg.id, { result: deny ? deny.response : { decision: 'deny', reason: 'cancelled in client' } });
            return;
        }
        // Each zcode option carries its own MF-shaped response - pass verbatim.
        answerServerToClient(msg.id, { result: chosen.response ?? { decision: 'deny' } });
    } catch (err) {
        log(`permission forward failed (${err.message ?? err}) - denying.`);
        answerServerToClient(msg.id, { result: { decision: 'deny', reason: `bridge error: ${err.message ?? err}` } });
    }
}

function sessionByZcodeId(sessionId) {
    return sessions.get(sessionId) ?? null;
}

function handleSessionEvent(params) {
    const sessionId = params.sessionId;
    const session = sessionByZcodeId(sessionId);
    if (!session) return; // events for sessions T3 did not open - ignore
    const turnId = params.turnId ?? '(no-turn)';
    const payload = params.payload ?? {};
    switch (params.type) {
        case 'part.delta': {
            const field = payload.field ?? 'text';
            if (field === 'text' || field === 'reasoning') {
                streamDelta(session, turnId, payload.messageId, payload.partId, payload.delta, field);
            }
            return;
        }
        case 'part.started':
        case 'part.upserted': {
            const part = payload.part ?? {};
            const kind = part.type;
            if (kind === 'text') streamPartText(session, turnId, part.id ?? part.partId ?? '(part)', part.text, 'text');
            else if (kind === 'reasoning') streamPartText(session, turnId, part.id ?? part.partId ?? '(part)', part.text, 'reasoning');
            else if (kind === 'tool') emitToolUpdate(session, turnId, part);
            return;
        }
        case 'message.upserted': {
            const t = turnState(session, turnId);
            if (!t.sawPartEvents && typeof payload.content === 'string' && payload.content.length > 0) {
                t.sawContent = true;
                emitUpdate(sessionId, textChunk(payload.content));
            }
            return;
        }
        case 'tool.updated': {
            emitToolUpdate(session, turnId, payload);
            return;
        }
        case 'turn.completed': {
            const t = turnState(session, turnId);
            if (!t.sawContent && typeof payload.response === 'string' && payload.response.length > 0) {
                emitUpdate(sessionId, textChunk(payload.response));
                t.sawContent = true;
            }
            settleTurn(session, turnId, { status: 'completed' });
            return;
        }
        case 'turn.failed': {
            settleTurn(session, turnId, { status: 'failed', error: payload.error });
            return;
        }
        default:
            // session.titleUpdated / session.updated / model_* / todo / plan /
            // subagent / workflow events: no ACP v1 counterpart in this bridge.
            return;
    }
}

function streamDelta(session, turnId, messageId, partId, delta, field) {
    if (typeof delta !== 'string' || delta.length === 0) return;
    const t = turnState(session, turnId);
    t.sawPartEvents = true;
    t.sawContent = true;
    emitUpdate(session.id, field === 'reasoning' ? thoughtChunk(delta) : textChunk(delta));
    void messageId; void partId; // deltas are append-only; upserts track their own full text
}

function emitToolUpdate(session, turnId, payload) {
    const toolCallId = String(payload.toolCallId ?? payload.id ?? `tool-${turnId}-${payload.toolName ?? 'unknown'}`);
    const known = session.tools.get(toolCallId) ?? { emitted: false };
    const rawOutput = payload.result ?? payload.output;
    const failed = payload.error !== undefined || /error/i.test(String(payload.state ?? payload.status ?? ''));
    const status = failed ? 'failed'
        : (rawOutput !== undefined || /complete|result|done/i.test(String(payload.state ?? payload.status ?? ''))) ? 'completed'
            : known.emitted ? 'in_progress' : 'pending';
    const update = {
        sessionUpdate: known.emitted ? 'tool_call_update' : 'tool_call',
        toolCallId,
        title: String(payload.title ?? payload.description ?? payload.toolName ?? 'tool'),
        kind: TOOL_KIND_BY_NAME(String(payload.toolName ?? payload.title ?? '')),
        status,
    };
    if (payload.input !== undefined) update.rawInput = payload.input;
    if (rawOutput !== undefined) update.rawOutput = rawOutput;
    session.tools.set(toolCallId, { emitted: true });
    emitUpdate(session.id, update);
}

// Turn settlement: an ACP session/prompt resolves exactly once per turn.
function settleTurn(session, turnId, { status, error }) {
    const pendingPrompt = session.pendingPrompt;
    if (!pendingPrompt || pendingPrompt.turnId !== turnId) return;
    session.pendingPrompt = null;
    clearTimeout(pendingPrompt.watchdog);
    if (pendingPrompt.cancelRequested) {
        pendingPrompt.resolve({ stopReason: 'cancelled' });
        return;
    }
    if (status === 'completed') {
        pendingPrompt.resolve({ stopReason: 'end_turn' });
        return;
    }
    pendingPrompt.reject(error ? mapStopError(error) : jsonRpcError(null, -32001, `turn ${status}`).error);
}

function settleTurnByTelemetry(params) {
    const session = sessionByZcodeId(params.sessionId);
    if (!session) return;
    const pendingPrompt = session.pendingPrompt;
    if (!pendingPrompt) return;
    // Belt-and-braces: the explicit turn.completed/failed events normally win;
    // this catches terminals whose session/event form was never delivered.
    if (pendingPrompt.turnId && params.turnId && pendingPrompt.turnId !== params.turnId) return;
    settleTurn(session, pendingPrompt.turnId, { status: params.status ?? 'completed', error: params.errorCode ? { code: params.errorCode, message: params.errorMessage } : undefined });
}

// --- ACP method handlers ----------------------------------------------------------
async function waitForStorageReady(timeoutMs = 90000) {
    if (storageReady) return;
    await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`zcode storage not ready after ${timeoutMs}ms`)), timeoutMs);
        storageWaiter = () => { clearTimeout(timer); resolve(); };
    });
}

async function handleInitialize(params) {
    // Respond v1-SHAPED: T3's negotiation pins generation 1 from the response
    // shape (spec A3), so no fs/terminal/mcp capabilities are ever expected.
    return {
        protocolVersion: 1,
        agentCapabilities: {
            loadSession: false,
            promptCapabilities: { image: false, audio: false, embeddedContext: false },
            mcpCapabilities: { http: false, sse: false, acp: false },
        },
    };
}

async function handleSessionNew(params) {
    await waitForStorageReady();
    // Prefer the home's KNOWN default model (the standalone-login selection):
    // with it, turns run on the plan; without it, the registry rejects create
    // FAST with a clear login-guidance error instead of a turn that hangs in
    // the free-model retry loop for minutes (spec 9.3 incident, 2026-10-29).
    const createModel = sessionModel ?? parseAcpModelId(currentModelAcpId ?? '');
    let snapshot;
    try {
        snapshot = await zcRequest('session/create', {
            workspace: zcodeWorkspace(params.cwd),
            mode: defaultMode,
            ...(createModel ? { model: createModel } : {}),
        }, 60000);
    } catch (err) {
        const message = String(err?.message ?? err);
        if (createModel && /Provider Registry|-32603/i.test(message)) {
            throw jsonRpcError(null, -32001,
                `this clone home cannot run "${currentModelAcpId}" yet - its provider is not materialized. Run GHOST.bat ZCode [28] (one-time login) for this clone, then retry.`,
                { zcodeErrorCode: 'login_required' });
        }
        if (!createModel || sessionModel) throw err;
        // The home default failed for a NON-registry reason: fall back to the
        // server default (loudly) rather than dead-ending the provider.
        warnOnceLog('create-fallback', `session/create with the home default failed (${message.slice(0, 140)}) - falling back to the server default model.`);
        snapshot = await zcRequest('session/create', {
            workspace: zcodeWorkspace(params.cwd),
            mode: defaultMode,
        }, 60000);
    }
    const sessionId = snapshot?.session?.sessionId;
    if (!sessionId) throw jsonRpcError(null, -32001, 'session/create returned no sessionId');
    latestRevision = snapshot?.runtime?.stateRevision ?? 0;
    const session = {
        id: sessionId,
        turns: new Map(),
        tools: new Map(),
        pendingPrompt: null,
    };
    sessions.set(sessionId, session);
    await zcRequest('session/subscribe', { sessionId, deliveryKind: 'desktop-continuous' }, 15000);
    const models = buildModelState();
    return {
        sessionId,
        modes: {
            currentModeId: defaultMode,
            availableModes: ZCODE_MODES.map((id) => ({ id, name: id })),
        },
        // T3's model picker gate: setup.models != null enables switching.
        ...(models ? { models } : {}),
    };
}

async function handleSetModel(params) {
    const session = sessions.get(params.sessionId);
    if (!session) throw jsonRpcError(null, -32004, `unknown session ${params.sessionId}`);
    const selection = parseAcpModelId(params.modelId);
    if (!selection) throw jsonRpcError(null, -32602, `modelId must be "providerId/modelId[/level]", got "${params.modelId}"`);
    await zcRequest('session/setModel', { sessionId: session.id, modelSelection: selection }, 15000);
    currentModelAcpId = params.modelId;
    return {};
}

// Turn watchdog (spec 9.3): a prompt with NO terminal within this window gets
// stopped and answered with a clear error - T3's provider window is 60 s and
// a broken/unavailable model can otherwise hang the turn for minutes.
const TURN_WATCHDOG_MS = 180000;

async function handleSessionPrompt(params) {
    const session = sessions.get(params.sessionId);
    if (!session) throw jsonRpcError(null, -32004, `unknown session ${params.sessionId}`);
    if (session.pendingPrompt) throw jsonRpcError(null, -32010, 'a prompt is already running for this session');
    const blocks = Array.isArray(params.prompt) ? params.prompt : [];
    const text = blocks
        .filter((b) => b?.type === 'text' && typeof b.text === 'string')
        .map((b) => b.text)
        .join('\n');
    if (!text) throw jsonRpcError(null, -32602, 'only text prompts are supported by this bridge');
    const turnId = `t3-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`; // real turnId arrives via turn.started
    const pendingPrompt = { turnId, resolve: null, reject: null, cancelRequested: false, watchdog: null };
    const result = await new Promise((resolve, reject) => {
        pendingPrompt.resolve = resolve;
        pendingPrompt.reject = reject;
        session.pendingPrompt = pendingPrompt;
        pendingPrompt.watchdog = setTimeout(() => {
            if (session.pendingPrompt !== pendingPrompt) return;
            session.pendingPrompt = null;
            log('turn watchdog fired - stopping the turn (no terminal within 180s).');
            zcRequest('session/stop', { sessionId: session.id }, 15000).catch(() => { /* best effort */ });
            reject(jsonRpcError(null, -32001,
                'turn exceeded 180s without a terminal - stopped by the bridge (likely a broken or unavailable model; run GHOST.bat ZCode [28] login for this clone).',
                { zcodeErrorCode: 'turn_watchdog' }).error);
        }, TURN_WATCHDOG_MS);
        zcSendWithRevisionSync(session.id, text).then(
            (sendResult) => {
                if (typeof sendResult?.stateRevision === 'number') latestRevision = sendResult.stateRevision;
            },
            (err) => {
                if (session.pendingPrompt === pendingPrompt) {
                    session.pendingPrompt = null;
                    clearTimeout(pendingPrompt.watchdog);
                    reject(err.zcode ? mapStopError(err.zcode) : jsonRpcError(null, -32001, String(err.message)).error);
                }
            },
        );
    });
    return result;
}

function handleSessionCancel(params) {
    const session = sessions.get(params.sessionId);
    if (!session?.pendingPrompt) return {};
    session.pendingPrompt.cancelRequested = true;
    // ACP: after session/cancel the prompt response MUST be stopReason
    // "cancelled" even if the underlying turn errors out (spec 4.1 trap).
    // The terminal settles the prompt whenever zcode delivers it - with a
    // misbehaving upstream model the retry loop can delay that for minutes,
    // so callers must not assume a fast answer (fake client gates on THIS
    // log line, not on the terminal).
    log(`cancel -> session/stop (session ${session.id})`);
    zcRequest('session/stop', { sessionId: session.id }, 15000).catch(() => { /* stop races are fine */ });
    return {};
}

async function handleSetMode(params) {
    const session = sessions.get(params.sessionId);
    if (!session) throw jsonRpcError(null, -32004, `unknown session ${params.sessionId}`);
    if (!ZCODE_MODES.includes(params.modeId)) throw jsonRpcError(null, -32602, `unknown mode ${params.modeId}`);
    await zcRequest('session/setMode', { sessionId: session.id, mode: params.modeId }, 15000);
    return {};
}

const acpMethods = {
    initialize: handleInitialize,
    'session/new': handleSessionNew,
    'session/prompt': handleSessionPrompt,
    'session/cancel': (params) => handleSessionCancel(params), // notification-style, still answerable
    'session/set_mode': handleSetMode,
    'session/set_model': handleSetModel,
};

const acpConn = new NdjsonConnection({
    input: process.stdin,
    output: process.stdout,
    onMessage: async (msg) => {
        // Notifications carry no id: ACP v1 session/cancel arrives this way.
        if (msg.id === undefined) {
            if (msg.method === 'session/cancel') handleSessionCancel(msg.params ?? {});
            else warnOnceLog(`notify:${msg.method}`, `ignoring client notification ${msg.method}.`);
            return;
        }
        const handler = acpMethods[msg.method];
        if (!handler) {
            acpRespond(msg.id, { error: { code: -32601, message: `method not found: ${msg.method}` } });
            return;
        }
        try {
            const result = await handler(msg.params ?? {});
            acpRespond(msg.id, { result });
        } catch (err) {
            // Handlers throw either a pre-shaped JSON-RPC error object
            // ({error:{code,message}} from jsonRpcError) or a plain Error.
            const error = (err && err.error !== undefined && typeof err.error?.code === 'number')
                ? err.error
                : (err && typeof err.code === 'number' && typeof err.message === 'string' && err.error === undefined && err.result === undefined)
                    ? err
                    : jsonRpcError(null, -32001, String(err?.message ?? err)).error;
            acpRespond(msg.id, { error });
        }
    },
    onParseError: (line, err) => {
        // ACP client sent garbage - log to stderr, never echo stdout.
        warnOnceLog('acp-parse', `unparseable line from ACP client: ${String(line).slice(0, 120)} (${err.message})`);
    },
    onClose: (reason) => {
        log(`ACP client disconnected (${reason}) - shutting down.`);
        child.killTree();
        setTimeout(() => process.exit(0), 400);
    },
});

process.stdin.on('end', () => {
    // NdjsonConnection also fires onClose; this guards non-piped invocations.
    if (!acpConn.closed) {
        log('stdin ended.');
        child.killTree();
        setTimeout(() => process.exit(0), 400);
    }
});
process.on('SIGINT', () => {
    log('SIGINT - killing zcode child tree.');
    child.killTree();
    setTimeout(() => process.exit(0), 400);
});
void acpConn; // the connection lives for the process lifetime
