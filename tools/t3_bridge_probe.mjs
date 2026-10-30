#!/usr/bin/env node
// T3 ZCode Bridge - Phase A live protocol probe (docs/T3_ZCODE_BRIDGE_SPEC.md section 6-A).
// Spawns `zcode app-server` under one clone account's env levers, drives a real
// turn, and dumps the COMPLETE session/event vocabulary + decline-tolerance
// behaviour to a transcript artifact. Its output is the source of truth the
// bridge mapping (tools/t3_zcode_bridge.mjs) is written against.
//
// Usage:
//   node tools/t3_bridge_probe.mjs [--Instance Second] [--home <dir>] [--cwd <dir>]
//        [--prompt "text"] [--timeout-seconds 180] [--out <transcript.jsonl>] [--no-cancel]
//
// Exit 0 = every core acceptance item passed; 1 = at least one failed (the
// summary names it - never silent).

import fs from 'node:fs';
import path from 'node:path';
import {
    INSTANCE_MAP,
    NdjsonConnection,
    parseArgs,
    readWireVersion,
    resolveInstanceHome,
    resolveZcodeCli,
    spawnAppServer,
    zcodeWorkspace,
} from './t3_bridge_lib.mjs';

const spec = {
    Instance: 'value', home: 'value', cwd: 'value', prompt: 'value',
    'timeout-seconds': 'value', out: 'value', 'no-cancel': 'flag', model: 'value',
};
const args = parseArgs(process.argv.slice(2), spec);
const instance = args.Instance ?? 'Second';
const cloneHome = resolveInstanceHome(instance, args.home);
const zcodeCli = resolveZcodeCli();
const cwd = path.resolve(args.cwd ?? process.env.TEMP ?? '.');
const prompt = args.prompt ?? 'Reply with exactly: OK';
const timeoutSeconds = Number(args['timeout-seconds'] ?? 180);
const outPath = path.resolve(args.out ?? path.join(
    process.env.TEMP ?? '.', `t3-bridge-probe-${new Date().toISOString().replace(/[:.]/g, '-')}.jsonl`));

const log = (...m) => process.stderr.write(`[probe] ${m.join(' ')}\n`);
const fail = (...m) => process.stderr.write(`[probe] FAIL: ${m.join(' ')}\n`);

// --- wire-version gate (spec 5.4) -------------------------------------------
const wire = readWireVersion(zcodeCli);
if (!wire.ok) {
    fail(`zcode.cjs wire version unexpected: ${JSON.stringify(wire)} - refusing to probe (spec 5.4).`);
    process.exit(1);
}
log(`wire gate OK: ZCODE_PROTOCOL_VERSION=${wire.protocolVersion} V4_WIRE=${wire.v4WireVersion}`);

// --- transcript + catalogue ---------------------------------------------------
const transcript = fs.createWriteStream(outPath, { encoding: 'utf8' });
const record = (dir, msg) => {
    transcript.write(JSON.stringify({ ts: new Date().toISOString(), dir, msg }) + '\n');
};
const eventCatalogue = new Map(); // discriminator -> {count, sample}
const catalogueKey = (params) => {
    // The event shape is Phase A's discovery target: try known candidates, else
    // fall back to the top-level key list so even unknown shapes group sensibly.
    const p = params ?? {};
    const payload = p.payload ?? {};
    for (const candidate of [payload.event, payload.kind, payload.type, p.event, p.kind, p.type]) {
        if (typeof candidate === 'string' && candidate.length > 0) return candidate;
    }
    return 'keys:' + Object.keys(p).sort().join(',');
};
const truncate = (value, max = 600) => {
    const s = JSON.stringify(value);
    if (s === undefined) return '<unserializable>';
    return s.length <= max ? s : s.slice(0, max) + `...<+${s.length - max} chars>`;
};

// --- request plumbing ----------------------------------------------------------
let nextId = 1;
const pending = new Map(); // id -> {resolve, reject, timer, method}
const serverToClientSeen = new Map(); // method -> {count, answer}
let terminalWaiter = null; // resolved by the next turn.terminal telemetry event
let latestRevision = null; // tracked from state.updated patches (authoritative)
let stateRevision = null; // last revision we KNOW (create snapshot / send result / session/read)
const availableModels = new Set(); // from state.updated model.available patches

// Optional --model "providerId/modelId[/reasoningLevel]" -> the Ll modelSelection
// shape that session/create accepts (options.reasoningLevel required by some
// models, e.g. nemotron). Without it the bare CLI falls back to the free
// opencode-zen default (spec Z8) whose turns fail upstream today.
const modelSelection = args.model
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

function request(method, params, timeoutMs = 30000) {
    const id = nextId++;
    const msg = { id, method, params };
    record('out', msg);
    conn.send(msg);
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            pending.delete(id);
            reject(new Error(`timeout after ${timeoutMs}ms waiting for ${method} (id ${id})`));
        }, timeoutMs);
        pending.set(id, { resolve, reject, method });
    });
}

function notify(method, params) {
    const msg = { method, params };
    record('out', msg);
    conn.send(msg);
}

function respond(id, payload) {
    const msg = { id, ...payload };
    record('out', msg);
    conn.send(msg);
}

function waitForTerminal(timeoutMs) {
    return new Promise((resolve, reject) => {
        if (terminalWaiter) return reject(new Error('another terminal wait is active'));
        const timer = setTimeout(() => { terminalWaiter = null; reject(new Error(`no turn.terminal within ${timeoutMs}ms`)); }, timeoutMs);
        terminalWaiter = (params) => { clearTimeout(timer); terminalWaiter = null; resolve(params); };
    });
}

// session/send with the spec's revision discipline (5.6): on -32009 mismatch,
// re-read the authoritative revision once, then retry; a second mismatch surfaces.
async function sendWithRevisionSync(sessionId, content, extra = {}) {
    try {
        return await request('session/send', { sessionId, content, expectedRevision: latestRevision ?? stateRevision, ...extra }, 30000);
    } catch (err) {
        if (!String(err.message).includes('-32009')) throw err;
        const read = await request('session/read', { sessionId, contentProfile: 'index' }, 15000);
        if (typeof read?.runtime?.stateRevision === 'number') {
            stateRevision = read.runtime.stateRevision;
            latestRevision = stateRevision;
        }
        return await request('session/send', { sessionId, content, expectedRevision: latestRevision ?? stateRevision, ...extra }, 30000);
    }
}

// --- child + connection ----------------------------------------------------------
log(`instance=${instance} home=${cloneHome}`);
log(`cli=${zcodeCli}`);
const child = spawnAppServer(zcodeCli, cloneHome);
let nonProtocolLines = 0;
let storageReady = false;
let storageReadyWaiter = null;

const conn = new NdjsonConnection({
    input: child.stdout,
    output: child.stdin,
    onMessage: (msg) => {
        record('in', msg);
        if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
            const p = pending.get(msg.id);
            if (p) {
                clearTimeout(p.timer);
                pending.delete(msg.id);
                if (msg.error !== undefined) p.reject(Object.assign(new Error(`zcode error ${msg.error.code}: ${msg.error.message}`), { zcode: msg.error }));
                else p.resolve(msg.result);
            }
            return;
        }
        if (msg.method !== undefined && msg.id !== undefined) {
            // server->client REQUEST (spec Z7). requestRuntimePreferences is
            // MANDATORY during session/create (scope runtime-materialization):
            // a decline aborts the create, so answer its minimal valid shape
            // (bundle schema Utn: nativeSearchEnhancementsEnabled is the only
            // field without a default). Everything else: decline by default.
            const entry = serverToClientSeen.get(msg.method) ?? { count: 0, answer: null };
            entry.count += 1;
            if (msg.method === 'session/requestRuntimePreferences') {
                entry.answer = 'minimal-prefs';
                respond(msg.id, { result: { nativeSearchEnhancementsEnabled: false } });
            } else {
                entry.answer = 'declined-error';
                respond(msg.id, { error: { code: -32602, message: 'probe decline' } });
            }
            serverToClientSeen.set(msg.method, entry);
            return;
        }
        if (msg.method !== undefined) {
            const method = msg.method;
            if (method === 'startup/storageState') {
                const phase = msg.params?.phase ?? msg.params?.payload?.phase;
                if (phase === 'ready') {
                    storageReady = true;
                    if (storageReadyWaiter) { const w = storageReadyWaiter; storageReadyWaiter = null; w(); }
                }
            }
            if (method === 'session/event') {
                const key = catalogueKey(msg.params);
                const entry = eventCatalogue.get(key) ?? { count: 0, samples: [] };
                entry.count += 1;
                if (entry.samples.length < 2) entry.samples.push(truncate(msg.params));
                eventCatalogue.set(key, entry);
                return;
            }
            if (method === 'state.updated') {
                if (typeof msg.params?.revision === 'number') latestRevision = msg.params.revision;
                const available = msg.params?.patch?.model?.available;
                if (Array.isArray(available) && available.length > 0) {
                    for (const entry of available) {
                        const ref = entry?.ref;
                        if (ref?.providerId && ref?.modelId) {
                            availableModels.add(`${ref.providerId}/${ref.modelId}`);
                        }
                    }
                }
                return;
            }
            if (method === 'v4/telemetry/event' && msg.params?.kind === 'turn.terminal') {
                const w = terminalWaiter;
                if (w) w(msg.params);
            }
            return;
        }
    },
    onParseError: (line, err) => {
        nonProtocolLines += 1;
        record('parse-error', { line: String(line).slice(0, 300), error: err.message });
        fail(`non-protocol stdout line (#${nonProtocolLines}): ${String(line).slice(0, 200)}`);
    },
    onClose: (reason) => log(`child transport closed: ${reason}`),
});

child.stderr.setEncoding('utf8');
child.stderr.on('data', (chunk) => {
    for (const line of String(chunk).split('\n')) {
        if (line.trim()) record('child-stderr', { line: line.slice(0, 400) });
    }
});
child.on('exit', (code) => log(`child exited code=${code}`));

const waitStorageReady = (timeoutMs) => new Promise((resolve, reject) => {
    if (storageReady) return resolve();
    const timer = setTimeout(() => reject(new Error(`storage not ready after ${timeoutMs}ms`)), timeoutMs);
    storageReadyWaiter = () => { clearTimeout(timer); resolve(); };
});

const waitForQuiet = async (ms) => new Promise((r) => setTimeout(r, ms));

// --- the probe sequence ------------------------------------------------------------
const summary = {
    instance, cloneHome, zcodeCli, wire,
    framingOk: null, storageReady: false, capabilitiesOk: false,
    createOk: false, turnCompleted: false, sendResult: null,
    snapshotKeys: [], revisionFieldsSeen: [],
    eventCatalogue: {}, serverToClientRequests: {},
    cancelTest: { attempted: false },
    nonProtocolLines: 0,
};

try {
    log('waiting for storage ready...');
    await waitStorageReady(90000);
    summary.storageReady = true;
    log('storage ready. capabilities handshake...');
    const caps = await request('runtime/capabilities', { hostCapabilities: {} });
    summary.capabilitiesOk = true;
    summary.capabilitiesResult = truncate(caps);

    log('provider/refreshRegistry (scan credentials for plan providers)...');
    try {
        const refresh = await request('provider/refreshRegistry', { reason: 't3-bridge-probe' }, 30000);
        summary.refreshRegistryResult = truncate(refresh);
    } catch (err) {
        summary.refreshRegistryError = String(err.message);
    }

    log(`session/create (workspace=${cwd}, default model)...)`);
    let snapshot;
    snapshot = await request('session/create', { workspace: zcodeWorkspace(cwd) }, 60000);
    summary.createWithModel = false;
    summary.createOk = true;
    summary.snapshotKeys = Object.keys(snapshot ?? {});
    for (const key of Object.keys(snapshot ?? {})) {
        if (/revision/i.test(key)) summary.revisionFieldsSeen.push(key);
    }
    if (snapshot?.value) {
        for (const key of Object.keys(snapshot.value)) {
            if (/revision/i.test(key)) summary.revisionFieldsSeen.push(`value.${key}`);
        }
    }
    log(`snapshot keys: ${summary.snapshotKeys.join(', ')}; revision candidates: ${summary.revisionFieldsSeen.join(', ') || '<none>'}`);
    const sessionId = snapshot?.session?.sessionId ?? snapshot?.sessionId ?? snapshot?.value?.sessionId;
    if (!sessionId) throw new Error(`no sessionId in snapshot: ${truncate(snapshot, 400)}`);
    stateRevision = snapshot?.runtime?.stateRevision ?? 0;
    summary.revisionFieldsSeen.push(`runtime.stateRevision=${stateRevision}`);
    log(`sessionId=${sessionId} stateRevision=${stateRevision}`);

    log('subscribing to session events (deliveryKind=desktop-continuous)...');
    const subResult = await request('session/subscribe', { sessionId, deliveryKind: 'desktop-continuous' }, 15000);
    summary.subscribeResult = truncate(subResult);

    log(`turn 1: session/send "${prompt}"${modelSelection ? ` (model=${modelSelection.providerId}/${modelSelection.modelId})` : ''}...`);
    const terminalPromise = waitForTerminal(timeoutSeconds * 1000);
    const sendResult = await sendWithRevisionSync(sessionId, prompt, modelSelection ? { modelSelection } : {});
    summary.sendResult = truncate(sendResult);
    if (typeof sendResult?.stateRevision === 'number') stateRevision = sendResult.stateRevision;
    const terminal = await terminalPromise;
    summary.turnTerminal = truncate(terminal);
    summary.turnCompleted = true;
    log(`turn 1 terminal: ${summary.turnTerminal}`);

    if (!args['no-cancel']) {
        log('turn 2 + cancel test...');
        summary.cancelTest.attempted = true;
        try {
            // Re-sync the authoritative revision after turn 1's terminal: the
            // terminal itself moves it and -32009 punishes a stale value.
            const read = await request('session/read', { sessionId, contentProfile: 'index' }, 15000);
            if (typeof read?.runtime?.stateRevision === 'number') {
                stateRevision = read.runtime.stateRevision;
                latestRevision = stateRevision;
                summary.cancelTest.revisionResync = stateRevision;
            }
            const terminal2Promise = waitForTerminal(timeoutSeconds * 1000);
            const send2 = sendWithRevisionSync(sessionId, 'Count slowly from 1 to 40, one number per line, no other text.').then(
                (r) => {
                    summary.cancelTest.sendResult = truncate(r);
                    if (typeof r?.stateRevision === 'number') stateRevision = r.stateRevision;
                },
                (e) => { summary.cancelTest.sendError = String(e.message); },
            );
            await send2;
            await waitForQuiet(2500);
            const stopResult = await request('session/stop', { sessionId }, 15000).then(
                (r) => { summary.cancelTest.stopResult = truncate(r); },
                (e) => { summary.cancelTest.stopError = String(e.message); },
            );
            void stopResult;
            summary.cancelTest.terminal = truncate(await terminal2Promise);
        } catch (err) {
            summary.cancelTest.error = String(err.message);
        }
        log(`cancel test: ${truncate(summary.cancelTest)}`);
    }

    summary.eventCatalogue = Object.fromEntries([...eventCatalogue.entries()].map(([k, v]) => [k, v]));
    summary.serverToClientRequests = Object.fromEntries([...serverToClientSeen.entries()].map(([k, v]) => [k, v]));
    summary.availableModels = [...availableModels].sort();
    summary.nonProtocolLines = nonProtocolLines;
    summary.framingOk = nonProtocolLines === 0;

    const coreOk = summary.framingOk && summary.storageReady && summary.capabilitiesOk
        && summary.createOk && summary.turnCompleted
        && (summary.turnTerminal ? !/"status":"failed"/.test(summary.turnTerminal) || Boolean(process.env.PROBE_ALLOW_FAILED_TURNS) : false);
    log('--- SUMMARY ---');
    log(truncate(summary, 4000));
    fs.writeFileSync(outPath.replace(/\.jsonl$/, '-summary.json'), JSON.stringify(summary, null, 2));
    if (coreOk) {
        log(`PROBE PASS - transcript at ${outPath}`);
        process.exitCode = 0;
    } else {
        fail(`PROBE FAIL - see summary above; transcript at ${outPath}`);
        process.exitCode = 1;
    }
} catch (err) {
    fail(String(err.message ?? err));
    summary.fatal = String(err.message ?? err);
    fs.writeFileSync(outPath.replace(/\.jsonl$/, '-summary.json'), JSON.stringify(summary, null, 2));
    process.exitCode = 1;
} finally {
    transcript.end();
    child.killTree();
    // give taskkill a beat before the process exits
    setTimeout(() => process.exit(process.exitCode ?? 0), 500);
}
void INSTANCE_MAP;
