// Shared library for the T3 Code <-> ZCode bridge tooling (probe, bridge, fake client).
// stdlib-only Node >= 18. See docs/T3_ZCODE_BRIDGE_SPEC.md for the protocol
// ground truth (provenance tables) this module implements.
//
// Verified facts encoded here (2026-10-28/29, see spec section 2):
//   - `zcode.cjs app-server` speaks "ZCode Protocol": NDJSON over stdio,
//     envelope {id, method, params?} / {id, result} / {id, error:{code,...}} /
//     {method, params} notifications - NO "jsonrpc" member (spec Z2).
//   - No initialize handshake: server emits startup/* notifications, then the
//     client may call runtime/capabilities (spec Z4).
//   - The four clone-home env levers isolate each account end-to-end (spec Z8,
//     verified live in ZCODE_LIGHT_MODE.md): HOME + USERPROFILE redirect
//     os.homedir()-resolved stores, ZCODE_DATA_BASE_DIR the v2 tree,
//     ZCODE_STORAGE_DIR the cli caches.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

export const INSTANCE_MAP = {
    Second: { home: 'ZCodeSecondHome', displayName: 'Blue', accent: '#066BCB' },
    Third: { home: 'ZCodeThirdHome', displayName: 'Yellow', accent: '#D4AA10' },
    Fourth: { home: 'ZCodeFourthHome', displayName: 'Green', accent: '#13826A' },
    Fifth: { home: 'ZCodeFifthHome', displayName: 'Red', accent: '#CA0607' },
    Sixth: { home: 'ZCodeSixthHome', displayName: 'Orange', accent: '#CB5D06' },
};

// The five ZCode permission modes, advertised as ACP session modes (spec 4.2).
export const ZCODE_MODES = ['build', 'edit', 'plan', 'yolo', 'guarded'];

// session/create's workspace is an OBJECT and its validator (bundle Q0r) enforces
// workspaceKey === workspaceIdentity?.trim() || workspacePath. With no identity,
// key === path, verbatim.
export function zcodeWorkspace(cwd) {
    const resolved = path.resolve(cwd);
    return { workspacePath: resolved, workspaceKey: resolved };
}

export function resolveInstanceHome(instance, explicitHome) {
    if (explicitHome) {
        const resolved = path.resolve(explicitHome);
        if (!fs.existsSync(path.join(resolved, '.zcode', 'v2', 'credentials.json'))) {
            throw new Error(`--home ${resolved} has no .zcode\\v2\\credentials.json profile`);
        }
        return resolved;
    }
    const cfg = INSTANCE_MAP[instance];
    if (!cfg) {
        throw new Error(`unknown --Instance "${instance}" (expected one of ${Object.keys(INSTANCE_MAP).join('|')})`);
    }
    const home = path.join(process.env.USERPROFILE || process.env.HOME || '', cfg.home);
    if (!fs.existsSync(path.join(home, '.zcode', 'v2', 'credentials.json'))) {
        throw new Error(
            `clone home ${instance} has no profile yet (${home}). Launch its desktop instance once to seed it, then retry.`,
        );
    }
    return home;
}

export function resolveZcodeCli(explicitPath) {
    const candidates = explicitPath
        ? [explicitPath]
        : [
              path.join(process.env.LOCALAPPDATA || '', 'Programs', 'ZCode', 'resources', 'glm', 'zcode.cjs'),
              'C:\\Program Files\\ZCode\\resources\\glm\\zcode.cjs',
              'C:\\Program Files (x86)\\ZCode\\resources\\glm\\zcode.cjs',
          ].filter((p) => p && !p.startsWith('\\'));
    const found = candidates.find((p) => {
        try { return fs.statSync(p).isFile(); } catch { return false; }
    });
    if (!found) {
        throw new Error(`zcode.cjs not found. Checked: ${candidates.join('; ')}`);
    }
    return found;
}

// Spec 5.4 wire-version gate: refuse to run against an unknown bundle. The
// constants are exported through a minified indirection chain
// (`ZCODE_PROTOCOL_VERSION:()=>mnt` + `,mnt=1`), so resolve NAME -> var -> literal.
export function readWireVersion(zcodeCli) {
    const raw = fs.readFileSync(zcodeCli, 'utf8');
    const resolveConst = (name) => {
        const direct = raw.match(new RegExp(`${name}\\s*=\\s*(\\d+)`));
        if (direct) return Number(direct[1]);
        const ref = raw.match(new RegExp(`${name}\\s*:\\s*\\(\\)\\s*=>\\s*([A-Za-z0-9_$]+)`));
        if (ref) {
            const varName = ref[1].replace(/\$/g, '\\$');
            const literal = raw.match(new RegExp(`[,;{(]\\s*${varName}\\s*=\\s*(\\d+)`));
            if (literal) return Number(literal[1]);
        }
        return null;
    };
    const protocolVersion = resolveConst('ZCODE_PROTOCOL_VERSION');
    const v4WireVersion = resolveConst('ZCODE_PROTOCOL_V4_WIRE_VERSION');
    if (protocolVersion === null) return { ok: false, protocolVersion: null, v4WireVersion };
    return { ok: protocolVersion === 1, protocolVersion, v4WireVersion };
}

export function buildChildEnv(cloneHome) {
    return {
        ...process.env,
        HOME: cloneHome,
        USERPROFILE: cloneHome,
        ZCODE_DATA_BASE_DIR: cloneHome,
        ZCODE_STORAGE_DIR: path.join(cloneHome, '.zcode'),
    };
}

// Spawn `zcode.cjs app-server` for one account. The caller owns the lifecycle:
// kill the whole tree on exit (the CLI spawns plugin-host children, which
// node's child.kill does not reap on Windows).
export function spawnAppServer(zcodeCli, cloneHome, { nodePath = process.execPath, stdio } = {}) {
    const child = spawn(nodePath, [zcodeCli, 'app-server'], {
        env: buildChildEnv(cloneHome),
        stdio: stdio ?? ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
    });
    child.killTree = () => {
        // node's kill() leaves the plugin-host grandchildren alive on Windows;
        // taskkill /T takes the whole tree.
        try {
            spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true });
        } catch {
            try { child.kill(); } catch { /* already gone */ }
        }
    };
    return child;
}

// NDJSON connection over any {readable, writable} pair. Parses each line; the
// onMessage callback receives parsed envelopes; malformed lines go to onParseError
// and are NEVER forwarded (ACP forbids non-protocol output on the peer's stdout).
export class NdjsonConnection {
    constructor({ input, output, onMessage, onParseError, onClose }) {
        this.output = output;
        this.onMessage = onMessage;
        this.onParseError = onParseError;
        this.onClose = onClose;
        this.closed = false;
        this.buffer = '';
        this.lineCount = 0;
        input.setEncoding('utf8');
        input.on('data', (chunk) => this.#ingest(chunk));
        input.on('end', () => this.#close('input-end'));
        input.on('error', (err) => this.#close(`input-error: ${err.message}`));
        output.on('error', (err) => this.#close(`output-error: ${err.message}`));
    }

    #ingest(chunk) {
        this.buffer += chunk;
        let idx;
        while ((idx = this.buffer.indexOf('\n')) >= 0) {
            const line = this.buffer.slice(0, idx).trim();
            this.buffer = this.buffer.slice(idx + 1);
            if (!line) continue;
            this.lineCount += 1;
            let msg;
            try {
                msg = JSON.parse(line);
            } catch (err) {
                if (this.onParseError) this.onParseError(line, err);
                continue;
            }
            try {
                this.onMessage(msg);
            } catch (err) {
                // A handler bug must not kill the reader loop; surface loudly.
                if (this.onParseError) this.onParseError(line, err);
            }
        }
    }

    #close(reason) {
        if (this.closed) return;
        this.closed = true;
        if (this.onClose) this.onClose(reason);
    }

    send(obj) {
        if (this.closed) return false;
        this.output.write(JSON.stringify(obj) + '\n');
        return true;
    }
}

export function parseArgs(argv, spec) {
    const out = { _: [] };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (!arg.startsWith('--')) { out._.push(arg); continue; }
        const key = arg.slice(2);
        if (!Object.prototype.hasOwnProperty.call(spec, key)) {
            throw new Error(`unknown flag --${key} (expected: ${Object.keys(spec).join(', ')})`);
        }
        if (spec[key] === 'flag') { out[key] = true; continue; }
        const value = argv[i + 1];
        if (value === undefined || value.startsWith('--')) {
            throw new Error(`--${key} requires a value`);
        }
        out[key] = value;
        i += 1;
    }
    return out;
}
