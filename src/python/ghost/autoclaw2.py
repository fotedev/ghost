"""AutoClaw2 (zwork) profile discovery + MCP (connected sources) sync +
chat-history inventory/copy. Spec: docs/AUTOCLAW2_SYNC_SPEC.md,
plan: docs/AUTOCLAW2_SYNC_PLAN.md (decisions D1-D13).

Rules inherited from sqlite_keys.py:
- Parameterized `?` placeholders everywhere; table names are literals from
  this file only.
- Every mutation is followed by a read-only re-open verification --
  "row written" is never assumed, it is re-read and compared.
- stdout contracts are plain JSON consumed by the PowerShell bridges
  (tools/sync_autoclaw2_mcp.ps1, tools/sync_autoclaw2_chats.ps1).
- Credentials never enter any payload: credential_version is nulled on
  copied rows and never selected into reports (D4).

Exit-code contract for the ac2-* subcommands: 0 ok, 1 error (unexpected
exception, stderr one-liner), 2 refused by a gate (Refusal, JSON verdict
on stdout with a specific remedy).
"""

import hashlib
import json
import os
import queue
import re
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

STDIO_PREFIX = "stdio+v1:"
# The app's own validators (main.cjs `By` / `IL`, mined 2026-11-05): a slug or
# tool name outside these shapes fails the app's strict row parse and the row
# renders as the hardcoded "invalid response" fallback (spec §9 E5 root cause).
SLUG_RE = re.compile(r"^[a-z][a-z0-9_]{0,39}$")
TOOL_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
# The only error_code values the app's row schema (FHr enum) accepts.
ERROR_CODES = ("authentication_failed", "connection_failed", "invalid_response")
REVISION_TOOL_CONTRACT = "connected-source-tool@2"
REVISION_PREFIX = "sync-v1:"
SIDECAR_NAME = ".autoclaw2-chat-imports.json"
BACKUP_DIR_NAME = ".autoclaw2-sync-backups"
SOURCE_TABLE = "governed_connected_sources"
MIGRATION_ID = "0001_clean_dogfood_baseline"
MIGRATION_SEQUENCE = 80
MIGRATION_CHECKSUM = "sha256:63f45a379d39b0956d8818a33d23d2f71ef4dd3d1b82bf87cbd5e1d4a2f7718c"
# The app's fresh-account bootstrap (observed on the Primary's live 68f7331f
# account, 2026-11-06) does NOT replay the migration history: it creates the
# schema directly at the current version and stamps ONE schema_migrations row
# with the baseline id, the current sequence and that schema's checksum. A
# legitimate second history encoding - accepted only at this exact tuple;
# any other shape still refuses as drift.
FRESH_STAMP_BASELINE = (
    "0001_clean_dogfood_baseline", 85,
    "sha256:2e8dc3362ea60ef6c867f530895a305345c47e14295a6dc88173f444ece1cc53")
# FTS indexes exactly these two entry types (verified: 84 rows for 2003
# entries in the Primary, all of type request|answer).
FTS_ENTRY_TYPES = ("request", "answer")
ENTRY_TYPES = (
    "request", "attachment", "reasoning", "assistant", "resource",
    "tool_call", "tool_result", "compaction", "answer",
)

_PROFILE_NAMES = ("Primary", "c1", "c2", "c3", "c4", "c5")


class Refusal(Exception):
    """A precondition gate refused the run. Carries a machine-readable code
    and a human remedy; the CLI wrapper prints it as JSON and exits 2."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message

    def as_dict(self):
        return {"refused": self.code, "message": self.message}


# --------------------------------------------------------------------------
# paths / profiles

def _home():
    return os.environ.get("USERPROFILE") or os.path.expanduser("~")


def _roaming():
    env = os.environ.get("APPDATA")
    if env:
        return env
    return os.path.join(_home(), "AppData", "Roaming")


def profile_path(name):
    """userData dir for a suite profile name (Primary, c1..c5)."""
    if (name or "").lower() == "primary":
        return os.path.join(_roaming(), "AutoClaw-oversea-official")
    if name not in _PROFILE_NAMES:
        raise Refusal("unknown-profile", "unknown profile name: {0!r}".format(name))
    return os.path.join(_home(), "AutoClaw2ClonesHome", name)


def _exclusive_open_ok(path):
    """True when the file can be opened with NO sharing (the suite's
    lockfile probe: held lockfile => PermissionError => running)."""
    if os.name != "nt":
        try:
            with open(path, "rb"):
                return True
        except OSError:
            return False
    import ctypes
    import ctypes.wintypes as wt
    GENERIC_READ = 0x80000000
    OPEN_EXISTING = 3
    FILE_ATTRIBUTE_NORMAL = 0x80
    INVALID = wt.HANDLE(-1).value if hasattr(wt, "HANDLE") else None
    k32 = ctypes.windll.kernel32
    k32.CreateFileW.restype = wt.HANDLE
    k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.LPVOID,
                                wt.DWORD, wt.DWORD, wt.HANDLE]
    h = k32.CreateFileW(path, GENERIC_READ, 0, None, OPEN_EXISTING,
                        FILE_ATTRIBUTE_NORMAL, None)
    if h == INVALID or h is None:
        return False
    k32.CloseHandle(h)
    return True


def probe_running(profile_dir):
    lockfile = os.path.join(profile_dir, "lockfile")
    if not os.path.isfile(lockfile):
        return False
    return not _exclusive_open_ok(lockfile)


_ACCOUNT_TIE_SECONDS = 60.0


def _pick_account(name, acc_root, accounts, hint):
    """Choose one account dir among several (the Primary's dormant
    27e33829 + live 68f7331f case). An explicit hint - exact 64-hex dir name
    or unique prefix - wins; without one, the account whose runtime.sqlite
    was written most recently wins (the live account is the one the running
    app keeps writing), loudly. Returns (path, how), or None when the caller
    should report ambiguous-account (no hint and the two newest runtimes
    were written within the tie window). A bad hint raises regardless of
    require_account: a wrong hint is a caller error, not a guessable state."""
    if hint:
        matches = [a for a in accounts if a == hint]
        if not matches:
            matches = [a for a in accounts if a.startswith(hint)]
        if not matches:
            raise Refusal("account-hint-no-match",
                          "{0}: no account dir matches hint {1!r}".format(
                              name, hint))
        if len(matches) > 1:
            raise Refusal("account-hint-ambiguous",
                          "{0}: hint {1!r} matches {2} account dirs".format(
                              name, hint, len(matches)))
        return os.path.join(acc_root, matches[0]), "hint"
    mtimes = []
    for acc in accounts:
        try:
            mtimes.append((os.path.getmtime(
                os.path.join(acc_root, acc, "runtime", "runtime.sqlite")), acc))
        except OSError:
            continue
    if not mtimes:
        return None
    mtimes.sort(reverse=True)
    if len(mtimes) > 1 and mtimes[0][0] - mtimes[1][0] < _ACCOUNT_TIE_SECONDS:
        return None
    print("[autoclaw2] WARN: {0}: {1} account dirs; selecting {2}... "
          "(newest runtime.sqlite)".format(
              name, len(accounts), mtimes[0][1][:12]), file=sys.stderr)
    return os.path.join(acc_root, mtimes[0][1]), "newest-mtime"


def resolve_profile(name, require_account=False, account_hint=None):
    """Resolve one profile to its account runtime DB. Returns a dict with
    status fields; raises Refusal only for hard errors (unknown name,
    ambiguous account, bad account hint) -- missing accounts come back as
    status so the caller can SKIP+WARN instead of failing a whole run."""
    pdir = profile_path(name)
    info = {
        "profile": name, "path": pdir, "exists": os.path.isdir(pdir),
        "account_dir": None, "account_status": None, "db_path": None,
        "account_selected_by": None, "running": False,
    }
    if not info["exists"]:
        info["account_status"] = "profile-missing"
        if require_account:
            # the early return must honor the gate too - falling through to
            # the bottom check is impossible from here, and a caller that
            # asked for an account would otherwise crash on db_path=None
            raise Refusal(info["account_status"],
                          "{0}: profile dir missing".format(name))
        return info
    info["running"] = probe_running(pdir)
    acc_root = os.path.join(pdir, "accounts")
    accounts = []
    if os.path.isdir(acc_root):
        accounts = sorted(
            d for d in os.listdir(acc_root)
            if os.path.isdir(os.path.join(acc_root, d)))
    if len(accounts) == 0:
        info["account_status"] = "not-signed-in"
    elif len(accounts) > 1:
        picked = _pick_account(name, acc_root, accounts, account_hint)
        if picked is None:
            info["account_status"] = "ambiguous-account"
            if require_account:
                raise Refusal("ambiguous-account",
                              "{0}: {1} account dirs, refusing to guess".format(name, len(accounts)))
        else:
            acc, how = picked
            info["account_status"] = "ok"
            info["account_dir"] = acc
            info["db_path"] = os.path.join(acc, "runtime", "runtime.sqlite")
            info["account_selected_by"] = how
    else:
        info["account_status"] = "ok"
        acc = os.path.join(acc_root, accounts[0])
        info["account_dir"] = acc
        info["db_path"] = os.path.join(acc, "runtime", "runtime.sqlite")
    if require_account and info["account_status"] != "ok":
        raise Refusal(info["account_status"],
                      "{0}: no usable account runtime ({1})".format(name, info["account_status"]))
    return info


# --------------------------------------------------------------------------
# sqlite helpers

def _uri(path):
    return "file:" + path.replace("\\", "/") + "?mode=ro"


def ro_connect(path):
    return sqlite3.connect(_uri(path), uri=True, timeout=10)


def rw_connect(path):
    return sqlite3.connect(path, timeout=30)


def check_schema(conn):
    """Schema gate (spec F3/R4): the baseline migration row this module was
    written against must still be present, and every column we touch must
    exist. schema_migrations is an APPEND-ONLY history -- since the 4.0.0
    update (2026-11-05) it holds the baseline/80 row plus forward migrations
    (0081..0085 and future 86+), so a single-row requirement is wrong and the
    max sequence is deliberately not pinned. Forward drift is acceptable as
    long as the baseline tuple survives intact and the column sets hold;
    editing or removing the baseline row itself is drift and refuses.
    EXCEPTED: a FRESH account (bootstrap-created, e.g. the Primary's live
    68f7331f) carries a single re-stamped baseline row at the current
    sequence - accepted only at the exact FRESH_STAMP_BASELINE tuple."""
    rows = conn.execute(
        "SELECT migration_id, sequence, checksum FROM schema_migrations").fetchall()
    baseline = (MIGRATION_ID, MIGRATION_SEQUENCE, MIGRATION_CHECKSUM)
    found = [{"migration_id": r[0], "sequence": r[1], "checksum": r[2]}
             for r in rows]
    tuples = [(r[0], r[1], r[2]) for r in rows]
    if baseline not in tuples:
        if tuples == [FRESH_STAMP_BASELINE]:
            return _column_gate(conn, "fresh-stamp-85")
        return {
            "ok": False,
            "expected_baseline": {"migration_id": baseline[0],
                                  "sequence": baseline[1],
                                  "checksum": baseline[2]},
            "found": found,
        }
    return _column_gate(conn, "baseline+forward")


def _column_gate(conn, history):
    """Every column the module touches must exist (see check_schema)."""
    required = {
        "work_sessions": ["session_id", "owner_id", "workspace_id", "title",
                          "deleted_at", "archived_at", "external_provider",
                          "updated_at", "created_at", "visibility"],
        "work_runs": ["run_id", "session_id", "credential_version",
                      "merged_into_run_id", "retried_from_run_id"],
        "work_events": ["event_id", "run_id", "session_id", "run_seq", "type",
                        "payload_json", "created_at"],
        "neutral_session_heads": ["session_id", "next_session_seq",
                                  "conversation_head_entry_id",
                                  "conversation_run_id",
                                  "settled_answer_entry_id", "settled_run_id",
                                  "entry_count", "updated_at"],
        "neutral_session_entries": ["session_id", "entry_id", "parent_entry_id",
                                    "session_seq", "run_id", "entry_type",
                                    "payload", "committed_at"],
        "neutral_session_fts": ["session_id", "entry_id", "body"],
        SOURCE_TABLE: ["owner_id", "workspace_id", "kind", "slug", "name",
                       "endpoint", "enabled", "status", "error_code",
                       "credential_version", "source_permission",
                       "tool_permissions_json", "revision", "tools_json",
                       "updated_at"],
        "governed_tool_artifacts": ["session_id", "run_id", "tool_id",
                                    "tool_revision"],
    }
    missing = {}
    for table, cols in required.items():
        have = {r[1] for r in conn.execute("PRAGMA table_info({0})".format(table))}
        absent = [c for c in cols if c not in have]
        if absent:
            missing[table] = absent
    if missing:
        return {"ok": False, "missing_columns": missing}
    return {"ok": True, "history": history}


def _require_schema(conn, profile):
    gate = check_schema(conn)
    if not gate["ok"]:
        raise Refusal("schema-mismatch",
                      "{0}: schema drift {1}".format(profile, json.dumps(gate)))
    return gate


# --------------------------------------------------------------------------
# MCP: connected sources

def read_workspaces(conn):
    return [{
        "workspace_id": r[0], "display_name": r[1], "root_path": r[2],
        "is_default": bool(r[3]), "trust_status": r[4],
    } for r in conn.execute(
        "SELECT workspace_id, display_name, root_path, is_default, trust_status "
        "FROM work_workspaces WHERE lifecycle = 'active' "
        "ORDER BY is_default DESC, created_at")]


def default_workspace_id(workspaces):
    for ws in workspaces:
        if ws["is_default"]:
            return ws["workspace_id"]
    if workspaces:
        return workspaces[0]["workspace_id"]
    raise Refusal("no-workspace", "profile has no active workspace")


def normalize_root(path):
    if not path:
        return ""
    p = path.replace("/", "\\")
    if os.name == "nt":
        p = p.lower()
    return p.rstrip("\\")


def canonical_locator(server):
    """Byte-exact locator per spec D5/G4: http keeps the trimmed URL, stdio
    is stdio+v1: + compact JSON with key order command, args, cwd."""
    if server["transport"] == "http":
        endpoint = (server.get("endpoint") or "").strip()
        if not endpoint.lower().startswith(("http://", "https://")):
            raise Refusal("bad-endpoint",
                          "http source {0!r} needs an absolute http(s) URL".format(server.get("slug")))
        return endpoint
    command = (server.get("command") or "").strip()
    if not command:
        raise Refusal("bad-command",
                      "stdio source {0!r} needs a command".format(server.get("slug")))
    payload = {"command": command,
               "args": [str(a) for a in (server.get("args") or [])]}
    cwd = (server.get("cwd") or "").strip()
    if cwd:
        payload["cwd"] = cwd
    return STDIO_PREFIX + json.dumps(payload, separators=(",", ":"))


def decode_locator(endpoint):
    if endpoint and endpoint.startswith(STDIO_PREFIX):
        try:
            data = json.loads(endpoint[len(STDIO_PREFIX):])
            out = {"transport": "stdio", "command": data.get("command"),
                   "args": data.get("args") or []}
            if data.get("cwd"):
                out["cwd"] = data["cwd"]
            return out
        except ValueError:
            return {"transport": "stdio", "command": None, "args": []}
    return {"transport": "http", "endpoint": endpoint}


def read_sources(conn, owner_id=None, workspace_id=None):
    sql = ("SELECT owner_id, workspace_id, kind, slug, name, endpoint, enabled, "
           "status, error_code, credential_version, source_permission, "
           "tool_permissions_json, revision, tools_json, updated_at "
           "FROM " + SOURCE_TABLE)
    args = []
    conds = []
    if owner_id is not None:
        conds.append("owner_id = ?")
        args.append(owner_id)
    if workspace_id is not None:
        conds.append("workspace_id = ?")
        args.append(workspace_id)
    if conds:
        sql += " WHERE " + " AND ".join(conds)
    sql += " ORDER BY slug"
    out = []
    for r in conn.execute(sql, args):
        out.append({
            "owner_id": r[0], "workspace_id": r[1], "kind": r[2], "slug": r[3],
            "name": r[4], "endpoint": r[5], "enabled": bool(r[6]),
            "status": r[7], "error_code": r[8],
            "has_credential": r[9] is not None,
            "source_permission": r[10], "tool_permissions_json": r[11],
            "revision": r[12], "tools_json": r[13], "updated_at": r[14],
        })
    return out


def _owner_id(conn):
    row = conn.execute(
        "SELECT principal_id FROM identity_personal_principals LIMIT 1").fetchone()
    if row:
        return row[0]
    row = conn.execute("SELECT owner_id FROM work_workspaces LIMIT 1").fetchone()
    if row:
        return row[0]
    raise Refusal("no-owner", "cannot resolve the profile owner id")


def source_revision(name, endpoint, source_permission):
    canon = json.dumps(
        {"name": name, "endpoint": endpoint,
         "source_permission": source_permission},
        sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return REVISION_PREFIX + hashlib.sha256(canon.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# MCP live discovery (the app's own local test, replicated)
#
# Mined from main.cjs 2026-11-05 (spec §9 E5 root cause): the app parses every
# governed_connected_sources row STRICTLY - status must be 'connected'|'failed'
# (a legacy 'pending' row fails the parse and renders as the hardcoded
# invalid_response fallback without any test ever running) and a source is
# only usable when tools_json holds the real discovered tools. The app's test
# is LOCAL (child_process spawn for stdio, direct fetch for http), so the sync
# can run the same discovery itself and write pre-tested rows the app accepts.

_MCP_PROTOCOL_VERSION = "2025-03-26"
_MCP_CLIENT_INFO = {"name": "ghost-sync", "version": "1.0.0"}


def _mcp_tool_name(name):
    """The app normalizes tool names with vme(): [^a-z0-9_] -> '_' + lower."""
    return re.sub(r"[^a-z0-9_]", "_", str(name or "")).lower()


# JSON-Schema boundary sanitizer - a faithful mirror of the app's gL/pme
# (mined 2026-11-05 from main.cjs, the `_L` module). The tool registry calls
# gL(parameters) UNCAUGHT during registration, so one non-conforming
# inputSchema fails the whole source at startup (registerOrFail ->
# recordFailure invalid_response). The sync therefore sanitizes every tool
# schema to this boundary BEFORE writing and drops the tool when the schema
# cannot be represented honestly. Mined rules:
# - allowed keywords ONLY (anything else -> unsupported_keyword): $defs $ref
#   additionalProperties anyOf default definitions description enum items
#   oneOf pattern properties required type minItems maxItems minLength
#   maxLength minimum maximum uniqueItems $schema
# - every node: plain object, <=256 nodes total, depth <=16, serialized
#   <=65536 chars at the registration walk; type: object|array|string|number|
#   integer|boolean|null or an array of those; a node with none of
#   type/anyOf/oneOf/$ref is "missing_type" (the killer for real-world MCP
#   schemas)
# - BINDING FOR WRITES: the stored-row zod (IL) refines the SERIALIZED
#   inputSchema to <=16384 chars (inputSchema_too_large) AFTER keyword
#   stripping - one over-size tool fails the WHOLE row parse at startup and
#   the source flips to invalid_response (live-proven 2026-11-06: cloudinary
#   upload_asset, 20024 chars). The sanitizer therefore measures the CLEANED
#   schema and drops the tool when it still exceeds 16384.
# - additionalProperties/uniqueItems: booleans only; enum: 1..64 values;
#   pattern: <=512 chars compiling as a JS RegExp with 'u'; description
#   <=2048; numeric bounds finite with |v| <= 1e9; $ref: single-level
#   "#/definitions/<name>" or "#/$defs/<name>" only
# - root: must sanitize to type=object AND carry properties
_SCHEMA_ALLOWED_KEYS = frozenset([
    "$defs", "$ref", "additionalProperties", "anyOf", "default",
    "definitions", "description", "enum", "items", "oneOf", "pattern",
    "properties", "required", "type", "minItems", "maxItems", "minLength",
    "maxLength", "minimum", "maximum", "uniqueItems", "$schema"])
_VALID_TYPES = ("object", "array", "string", "number", "integer", "boolean",
                "null")
_ANY_TYPE = list(_VALID_TYPES)
_PROTO_KEYS = ("__proto__", "prototype", "constructor")


class _SchemaRejected(Exception):
    """A schema node the app's boundary cannot accept even after repair."""


def _sanitize_schema_node(node, depth, state):
    if depth > 16:
        raise _SchemaRejected("schema_too_deep")
    state["nodes"] += 1
    if state["nodes"] > 256:
        raise _SchemaRejected("schema_too_large")
    if not isinstance(node, dict):
        raise _SchemaRejected("schema_not_object")
    out = {}
    for key, value in node.items():
        if key in _PROTO_KEYS:
            raise _SchemaRejected("prototype_key")
        if key not in _SCHEMA_ALLOWED_KEYS:
            continue  # unsupported keyword: stripped (the app would throw)
        if key == "type":
            if isinstance(value, list):
                types = [t for t in value if t in _VALID_TYPES]
                if not types:
                    raise _SchemaRejected("invalid_type")
                if len(types) == 1:
                    out["type"] = types[0]
                else:
                    out["anyOf"] = [{"type": t} for t in types]
            elif value in _VALID_TYPES:
                out["type"] = value
            # an unknown type string is stripped; the any-repair below kicks in
        elif key in ("properties", "definitions", "$defs"):
            if not isinstance(value, dict):
                raise _SchemaRejected("schema_map_invalid")
            cleaned = {}
            for name, sub in value.items():
                if name in _PROTO_KEYS:
                    raise _SchemaRejected("prototype_key")
                cleaned[name] = _sanitize_schema_node(sub, depth + 1, state)
            out[key] = cleaned
        elif key in ("anyOf", "oneOf"):
            if not isinstance(value, list) or not 1 <= len(value) <= 32:
                raise _SchemaRejected("union_invalid")
            out[key] = [_sanitize_schema_node(sub, depth + 1, state)
                        for sub in value]
        elif key == "items":
            out["items"] = _sanitize_schema_node(value, depth + 1, state)
        elif key == "required":
            if not isinstance(value, list) or \
                    not all(isinstance(v, str) for v in value):
                raise _SchemaRejected("required_invalid")
            out["required"] = [v for v in value if v not in _PROTO_KEYS]
        elif key == "additionalProperties":
            if isinstance(value, bool):
                out["additionalProperties"] = value
            # a schema-form additionalProperties is rejected by the app;
            # stripping loosens validation honestly
        elif key == "uniqueItems":
            if isinstance(value, bool):
                out["uniqueItems"] = value
        elif key == "enum":
            if not isinstance(value, list) or not 1 <= len(value) <= 64:
                raise _SchemaRejected("enum_invalid")
            out["enum"] = value
        elif key == "pattern":
            if not isinstance(value, str) or len(value) > 512:
                raise _SchemaRejected("pattern_invalid")
            try:
                re.compile(value)
            except re.error:
                continue  # a pattern Python cannot compile is stripped
            out["pattern"] = value
        elif key == "description":
            if isinstance(value, str):
                out["description"] = value[:2048]
        elif key in ("minLength", "maxLength", "minItems", "maxItems",
                     "minimum", "maximum"):
            if isinstance(value, (int, float)) \
                    and not isinstance(value, bool) and abs(value) <= 1e9:
                out[key] = value
        elif key == "$ref":
            if isinstance(value, str) and re.match(
                    r"^#/(definitions|\$defs)/[A-Za-z0-9_.-]+$", value):
                out["$ref"] = value
            # anything else is stripped; the any-repair below covers the node
        elif key == "default":
            out["default"] = value
        # "$schema" is dropped outright (the app deletes it anyway)
    if "type" not in out and "anyOf" not in out and "oneOf" not in out \
            and "$ref" not in out:
        # the app's missing_type rule: give the node the honest "any" shape
        # (as an explicit anyOf - the stable form under re-sanitization)
        if "properties" in out:
            out["type"] = "object"
        elif "items" in out:
            out["type"] = "array"
        else:
            out["anyOf"] = [{"type": t} for t in _ANY_TYPE]
    return out


def _json_utf16_len(value):
    """Length of json.dumps(value) as the app's JSON.stringify measures it:
    UTF-16 code units (an astral char counts 2, not 1)."""
    return len(json.dumps(value, separators=(",", ":"),
                          ensure_ascii=False).encode("utf-16-le")) // 2


def _sanitize_input_schema(schema):
    """Sanitize one tool inputSchema to the app's stored-row boundary.
    Returns the sanitized schema, or None when the tool must be dropped
    (unrepresentable schema). Idempotent on already-conforming schemas."""
    try:
        state = {"nodes": 0}
        cleaned = _sanitize_schema_node(schema, 0, state)
        if cleaned.get("type") != "object":
            return None  # the app requires an object root
        if "properties" not in cleaned:
            cleaned["properties"] = {}
        # IL refines the SERIALIZED schema to <=16384 after stripping - the
        # post-clean measure is the arbiter, not the raw size (a schema
        # bloated by unsupported keys shrinks when they are stripped).
        if _json_utf16_len(cleaned) > 16384:
            return None
        return cleaned
    except _SchemaRejected:
        return None
    except (TypeError, ValueError):
        return None


def _mcp_map_tools(raw_tools):
    """Map MCP tools/list entries onto the app's IL tool shape. Returns
    (tools, dropped). Names are normalized vme-consistently so permission
    lookups match; descriptions are synthesized when missing (IL requires a
    non-empty string); the original name rides in remoteName when renamed;
    oversized inputSchemas are dropped (IL caps them at 16384 chars)."""
    mapped, dropped, seen = [], 0, set()
    for tool in raw_tools or []:
        if not isinstance(tool, dict):
            dropped += 1
            continue
        original = str(tool.get("name") or "").strip()
        if not original:
            dropped += 1
            continue
        norm = _mcp_tool_name(original)
        if not TOOL_NAME_RE.match(norm):
            dropped += 1
            continue
        base, suffix = norm, 2
        while norm in seen:
            norm = "{0}_{1}".format(base, suffix)
            suffix += 1
        seen.add(norm)
        entry = {"name": norm}
        desc = tool.get("description")
        if isinstance(desc, str) and desc.strip():
            entry["description"] = desc.strip()
        else:
            entry["description"] = ("MCP tool {0} (no description "
                                    "provided).").format(original)
        if original != norm:
            entry["remoteName"] = original[:128]
        schema = tool.get("inputSchema")
        if isinstance(schema, dict):
            cleaned = _sanitize_input_schema(schema)
            if cleaned is None:
                dropped += 1
                continue
            entry["inputSchema"] = cleaned
        mapped.append(entry)
    return mapped, dropped


def _kill_process_tree(proc):
    try:
        proc.kill()
    except OSError:
        pass
    if os.name == "nt":
        try:
            subprocess.run(["taskkill", "/pid", str(proc.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10, check=False)
        except (OSError, subprocess.SubprocessError):
            pass


def discover_stdio(command, args, timeout=60.0, cwd=None):
    """Spawn an MCP stdio server and run the same handshake the app's local
    stdio host runs (newline-delimited JSON-RPC, initialize ->
    notifications/initialized -> tools/list, 30s-equivalent generous timeout
    for cold npx/uvx installs). Returns (tools, error_code); tools is None
    unless the handshake succeeded end-to-end."""
    popen_kwargs = {}
    if os.name == "nt":
        popen_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    try:
        proc = subprocess.Popen(
            [command] + [str(a) for a in (args or [])],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, cwd=cwd or None, **popen_kwargs)
    except (OSError, ValueError):
        return None, "connection_failed"

    def _pump(handle, q):
        for line in iter(handle.readline, b""):
            q.put(line)
        q.put(None)

    lines = queue.Queue()
    threading.Thread(target=_pump, args=(proc.stdout, lines),
                     daemon=True).start()
    deadline = time.monotonic() + max(float(timeout), 5.0)
    payload = "".join([
        json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": _MCP_PROTOCOL_VERSION,
                               "capabilities": {},
                               "clientInfo": _MCP_CLIENT_INFO}}) + "\n",
        json.dumps({"jsonrpc": "2.0",
                    "method": "notifications/initialized"}) + "\n",
        json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list",
                    "params": {}}) + "\n",
    ])
    try:
        proc.stdin.write(payload.encode("utf-8"))
        proc.stdin.flush()
    except OSError:
        _kill_process_tree(proc)
        return None, "connection_failed"

    def _msg_id(msg):
        mid = msg.get("id")
        return mid if isinstance(mid, (int, str)) else None

    got_init = got_tools = False
    tools, err = None, None
    while not (got_init and got_tools):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            err = err or "connection_failed"
            break
        try:
            line = lines.get(timeout=remaining)
        except queue.Empty:
            err = err or "connection_failed"
            break
        if line is None:
            err = err or "invalid_response"
            break
        try:
            msg = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue  # banner/log noise on stdout - skip
        if not isinstance(msg, dict):
            continue
        mid = _msg_id(msg)
        if mid in (1, "1"):
            if "error" in msg or "result" not in msg:
                err = "invalid_response"
                break
            got_init = True
        elif mid in (2, "2"):
            if "error" in msg or "result" not in msg:
                err = "invalid_response"
                break
            raw = (msg.get("result") or {}).get("tools")
            if not isinstance(raw, list):
                err = "invalid_response"
                break
            tools = raw
            got_tools = True
    _kill_process_tree(proc)
    if err is not None:
        return None, err
    if not (got_init and got_tools):
        return None, "connection_failed"
    return tools, None


def discover_http(endpoint, timeout=60.0, headers=None):
    """Run the app's local Streamable-HTTP discover against an MCP endpoint:
    POST initialize, notifications/initialized, then tools/list, honoring
    mcp-session-id. JSON and SSE responses both handled. `headers` carries
    extra request headers (e.g. Authorization) merged into every POST - how
    credentialed http sources are pre-tested. Returns (tools, error_code)."""
    def _post(body, session=None):
        hdrs = {"Content-Type": "application/json",
                "Accept": "application/json, text/event-stream"}
        if headers:
            hdrs.update(headers)
        if session:
            hdrs["mcp-session-id"] = session
        req = Request(endpoint, data=json.dumps(body).encode("utf-8"),
                      headers=hdrs, method="POST")
        with urlopen(req, timeout=timeout) as resp:
            return (resp.headers.get("mcp-session-id"),
                    resp.read().decode("utf-8", "replace"),
                    resp.headers.get("Content-Type") or "")

    def _parse(body, ctype):
        body = (body or "").strip()
        if not body:
            return None
        if "text/event-stream" in ctype or "data:" in body:
            frames = [line[5:].strip() for line in body.splitlines()
                      if line.startswith("data:")]
            candidates = frames or [body]
        else:
            candidates = [body]
        for cand in candidates:
            try:
                msg = json.loads(cand)
            except ValueError:
                continue
            if isinstance(msg, dict) and ("result" in msg or "error" in msg):
                return msg
        return None

    def _map_http_error(exc):
        return ("authentication_failed"
                if getattr(exc, "code", None) in (401, 403)
                else "connection_failed")

    session = None
    try:
        session, body, ctype = _post(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": _MCP_PROTOCOL_VERSION,
                        "capabilities": {}, "clientInfo": _MCP_CLIENT_INFO}})
    except HTTPError as exc:
        return None, _map_http_error(exc)
    except (URLError, OSError, ValueError):
        return None, "connection_failed"
    if not isinstance(_parse(body, ctype), dict):
        return None, "invalid_response"
    try:
        _post({"jsonrpc": "2.0", "method": "notifications/initialized"},
              session)
    except Exception:
        pass  # a 202/empty or refused notification must not fail the discover
    try:
        _, body, ctype = _post(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            session)
    except HTTPError as exc:
        return None, _map_http_error(exc)
    except (URLError, OSError, ValueError):
        return None, "connection_failed"
    listing = _parse(body, ctype)
    if not isinstance(listing, dict) or "error" in listing:
        return None, "invalid_response"
    raw = (listing.get("result") or {}).get("tools")
    if not isinstance(raw, list):
        return None, "invalid_response"
    return raw, None


def test_source_locator(locator, timeout=60.0):
    """Live local discover - exactly what the app's test() runs on this
    machine (spawn the stdio command or fetch the http endpoint). Returns
    {"ok", "error_code", "tools" (IL-mapped), "dropped", "tool_count"}."""
    info = decode_locator(locator)
    if info["transport"] == "stdio":
        command = info.get("command")
        if not command:
            return {"ok": False, "error_code": "connection_failed",
                    "tools": [], "dropped": 0, "tool_count": 0}
        raw, err = discover_stdio(command, info.get("args") or [], timeout,
                                  info.get("cwd"))
    else:
        raw, err = discover_http(info["endpoint"], timeout)
    if err is not None:
        return {"ok": False, "error_code": err, "tools": [], "dropped": 0,
                "tool_count": 0}
    tools, dropped = _mcp_map_tools(raw)
    return {"ok": True, "error_code": None, "tools": tools, "dropped": dropped,
            "tool_count": len(tools)}


def tool_revision(name, endpoint, source_permission, tools):
    """Replica of the app's T5 revision (contract connected-source-tool@2):
    'native.' + first 16 hex chars of sha256 over the compact canonical JSON
    with the app's exact key order."""
    canon = json.dumps(
        {"contract": REVISION_TOOL_CONTRACT, "name": name, "kind": "mcp",
         "endpoint": endpoint, "credentialVersion": None,
         "sourcePermission": source_permission, "toolPermissions": {},
         "tools": tools},
        separators=(",", ":"), ensure_ascii=False)
    return "native." + hashlib.sha256(canon.encode("utf-8")).hexdigest()[:16]


def strict_row_problems(row):
    """Mirror of the app's strict row parse (Gxn -> A_): an empty list means
    the app renders this row natively; any problem means it falls back to the
    hardcoded invalid_response renderer. Used as the verify-after gate so a
    written row is never assumed usable."""
    problems = []
    if not SLUG_RE.match(str(row.get("slug") or "")):
        problems.append("slug")
    if row.get("status") not in ("connected", "failed"):
        problems.append("status")
    err = row.get("error_code")
    if err is not None and err not in ERROR_CODES:
        problems.append("error_code")
    if row.get("source_permission") not in ("allowed", "approval_required",
                                            "blocked"):
        problems.append("source_permission")
    info = decode_locator(str(row.get("endpoint") or ""))
    if info["transport"] == "stdio":
        command = str(info.get("command") or "")
        args = info.get("args") or []
        if not (1 <= len(command) <= 256):
            problems.append("command")
        if len(args) > 32 or any(len(str(a)) > 512 for a in args):
            problems.append("args")
    else:
        endpoint = str(info.get("endpoint") or "")
        if not endpoint.startswith(("http://", "https://")):
            problems.append("endpoint")
    try:
        tools = json.loads(row.get("tools_json") or "[]")
        if not isinstance(tools, list):
            raise ValueError("not a list")
        for tool in tools:
            if not isinstance(tool, dict):
                raise ValueError("not an object")
            if not TOOL_NAME_RE.match(str(tool.get("name") or "")):
                raise ValueError("bad tool name")
            desc = tool.get("description")
            if not isinstance(desc, str) or not desc:
                raise ValueError("missing description")
            remote = tool.get("remoteName")
            if remote is not None and not (isinstance(remote, str) and
                                           1 <= len(remote.strip()) <= 128):
                raise ValueError("bad remoteName")
            schema = tool.get("inputSchema")
            if schema is not None:
                if not isinstance(schema, dict):
                    raise ValueError("schema not object")
                # the IL refine: serialized <=16384 (JSON.stringify units) -
                # one over-size tool fails the WHOLE row parse (cloudinary
                # upload_asset, live-proven 2026-11-06)
                if _json_utf16_len(schema) > 16384:
                    raise ValueError("inputSchema_too_large")
    except (ValueError, TypeError):
        problems.append("tools_json")
    if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$",
                    str(row.get("updated_at") or "")):
        problems.append("updated_at")
    return problems


_ENV_PLACEHOLDER_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def expand_env_value(value):
    """Expand ${VAR} placeholders from the environment.

    Machine values (supabase project refs and friends) live in user-scope env
    vars so no literal lands in the tracked master file. An unresolved
    placeholder is left AS-IS and reported loudly on stderr instead of
    silently collapsing (the PS env-guard equivalent: never write empty).
    """
    if not isinstance(value, str):
        return value

    def _sub(match):
        name = match.group(1)
        resolved = os.environ.get(name)
        if not resolved:
            print("[autoclaw2] WARN: manifest placeholder {0} unresolved "
                  "- left as-is".format(name), file=sys.stderr)
            return match.group(0)
        return resolved

    return _ENV_PLACEHOLDER_RE.sub(_sub, value)


def load_manifest(path):
    if not os.path.isfile(path):
        raise Refusal("manifest-missing", "manifest not found: {0}".format(path))
    with open(path, "r", encoding="utf-8-sig") as handle:
        manifest = json.load(handle)
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 1:
        raise Refusal("manifest-invalid", "manifest schemaVersion must be 1")
    defaults = manifest.get("defaults") or {}
    servers = manifest.get("servers")
    if not isinstance(servers, list):
        raise Refusal("manifest-invalid", "manifest needs a servers array")
    seen = set()
    normalized = []
    for raw in servers:
        if not isinstance(raw, dict):
            raise Refusal("manifest-invalid", "each server must be an object")
        slug = (raw.get("slug") or "").strip()
        if not SLUG_RE.match(slug):
            raise Refusal("manifest-invalid",
                          "bad slug {0!r} (lowercase [a-z0-9_-], <=64)".format(slug))
        if slug in seen:
            raise Refusal("manifest-invalid", "duplicate slug {0!r}".format(slug))
        seen.add(slug)
        transport = raw.get("transport")
        if transport not in ("stdio", "http"):
            raise Refusal("manifest-invalid",
                          "server {0!r}: transport must be stdio|http".format(slug))
        server = {
            "slug": slug,
            "name": (raw.get("name") or slug).strip(),
            "transport": transport,
            "command": expand_env_value(raw.get("command")),
            "args": [expand_env_value(a) for a in (raw.get("args") or [])],
            "cwd": expand_env_value(raw.get("cwd") or ""),
            "endpoint": expand_env_value(raw.get("endpoint")),
            "enabled": bool(raw.get("enabled", defaults.get("enabled", True))),
            "source_permission": raw.get("sourcePermission",
                                         defaults.get("sourcePermission", "allowed")),
            "requires_credential": bool(raw.get("requiresCredential", False)),
            "credential_hint": raw.get("credentialHint"),
            "notes": raw.get("notes"),
            "env_keys": [str(k) for k in (raw.get("envKeys") or [])],
        }
        if server["source_permission"] not in ("allowed", "approval_required", "blocked"):
            raise Refusal("manifest-invalid",
                          "server {0!r}: bad sourcePermission".format(slug))
        # locator validation happens here so a bad manifest is rejected
        # before any database is opened (spec F9)
        server["locator"] = canonical_locator(server)
        normalized.append(server)
    return {"schemaVersion": 1, "defaults": defaults, "servers": normalized}


def merge_sources(servers, existing_rows):
    """The D6 invariant: clone-local enabled + tool_permissions_json survive,
    clone-only rows are kept (never deleted), new rows inherit the manifest's
    enabled, the manifest wins on name/endpoint/source_permission."""
    existing = {row["slug"]: row for row in existing_rows}
    creates, updates, manifest_absent = [], [], []
    for server in servers:
        row = existing.get(server["slug"])
        locator = server["locator"]
        revision = source_revision(server["name"], locator,
                                   server["source_permission"])
        if row is None:
            creates.append({
                "slug": server["slug"], "name": server["name"],
                "endpoint": locator, "enabled": server["enabled"],
                "source_permission": server["source_permission"],
                "requires_credential": server["requires_credential"],
                "revision": revision,
            })
        else:
            # A row the app cannot strictly parse (e.g. the legacy 'pending'
            # rows) renders as the generic invalid_response fallback and its
            # Reconnect throws before any test - it must be rewritten even
            # when the definition itself is unchanged (spec §9 E5 root cause).
            shape_broken = bool(strict_row_problems({
                "slug": row.get("slug"), "status": row.get("status"),
                "error_code": row.get("error_code"),
                "source_permission": row.get("source_permission"),
                "endpoint": row.get("endpoint"),
                "tools_json": row.get("tools_json"),
                "updated_at": row.get("updated_at"),
            }))
            # The app's startup registration flips a pre-tested row to
            # failed/invalid_response when a stored schema fails its boundary
            # (gL). Signature: our native revision + failed + non-empty
            # tools_json - such rows must be re-tested, or they stay red
            # forever because the definition alone never changes.
            app_flipped = (row.get("status") == "failed"
                           and row.get("error_code") == "invalid_response"
                           and str(row.get("revision") or "").startswith("native.")
                           and row.get("tools_json") not in (None, "", "[]"))
            changed = (row["name"] != server["name"]
                       or row["endpoint"] != locator
                       or row["source_permission"] != server["source_permission"]
                       or shape_broken
                       or app_flipped)
            updates.append({
                "slug": server["slug"], "name": server["name"],
                "endpoint": locator,
                "source_permission": server["source_permission"],
                "revision": revision,
                "changed": changed,
                "before": {"name": row["name"], "endpoint": row["endpoint"],
                           "source_permission": row["source_permission"],
                           "enabled": row["enabled"]},
            })
    manifest_slugs = {s["slug"] for s in servers}
    for slug in sorted(existing):
        if slug not in manifest_slugs:
            manifest_absent.append(slug)
    return {"creates": creates, "updates": updates,
            "manifest_absent": manifest_absent}


def _backup_db(db_path, profile_dir, tag):
    """Clean single-file backup via the sqlite3 backup API (WAL-safe)."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest_dir = os.path.join(profile_dir, BACKUP_DIR_NAME, stamp + "-" + tag)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, "runtime.sqlite")
    src = rw_connect(db_path)
    try:
        dst = sqlite3.connect(dest)
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    return dest


def _map_target_workspaces(src_ws_list, tgt_workspaces, policy):
    """D3: default target = default workspace + root_path matches. An
    unmatched source workspace is SKIP + WARN (F4) - it never lands silently
    on the target's default workspace. Returns (pairs, warnings)."""
    tgt_by_root = {}
    for ws in tgt_workspaces:
        tgt_by_root.setdefault(normalize_root(ws["root_path"]), ws)
    tgt_default = default_workspace_id(tgt_workspaces)
    default_ws = next(w for w in tgt_workspaces
                      if w["workspace_id"] == tgt_default)
    pairs = []
    warns = []
    seen = set()

    def add(src_ws, tgt_ws, matched):
        key = tgt_ws["workspace_id"]
        if key in seen:
            return
        seen.add(key)
        pairs.append({"source_workspace": src_ws, "target_workspace": tgt_ws,
                      "matched_root": matched})

    if policy == "all":
        for ws in tgt_workspaces:
            add(None, ws, None)
        return pairs, warns
    # policy == 'default': root matches + the default workspace (D3); an
    # unmatched source workspace is skipped loudly, never mis-targeted
    for src in src_ws_list or []:
        match = tgt_by_root.get(normalize_root(src.get("root_path")))
        if match is not None:
            add(src, match, match["root_path"])
        else:
            warns.append({"source_root": src.get("root_path"),
                          "reason": "no-root-match-skipped"})
    add(None, default_ws, None)
    return pairs, warns


def _plan_slug_migrations(existing_rows):
    """The app's slug validator (By: ^[a-z][a-z0-9_]{0,39}$) forbids '-', so a
    sync-authored row with an illegal slug can never render natively. Migrate
    it in place (UPDATE slug) when the normalized slug is free and the row is
    provably ours (revision sync-v1:*). Returns (migrations, rows-with-new-slugs)."""
    taken = {row["slug"] for row in existing_rows}
    migrations, rows = [], []
    for row in existing_rows:
        slug = row["slug"]
        if SLUG_RE.match(slug):
            rows.append(row)
            continue
        if not str(row.get("revision") or "").startswith(REVISION_PREFIX):
            rows.append(row)  # app-authored row with an odd slug - leave alone
            continue
        new_slug = _mcp_tool_name(slug)
        if not SLUG_RE.match(new_slug) or new_slug in taken:
            rows.append(row)  # cannot migrate cleanly - stays kept-local
            continue
        taken.add(new_slug)
        migrated = dict(row)
        migrated["slug"] = new_slug
        rows.append(migrated)
        migrations.append({"from": slug, "to": new_slug})
    return migrations, rows


def mcp_plan(payload):
    """No writes. Per profile: resolved workspaces + create/update actions."""
    targets = payload.get("targets") or ["c1", "c2", "c3", "c4", "c5"]
    hint = payload.get("account_hint")
    source = payload.get("from", "master")
    policy = payload.get("policy", "default")
    if source == "master":
        manifest = load_manifest(payload["manifest_path"])
        servers = manifest["servers"]
        src_ws_list = None
    elif source == "primary":
        primary = resolve_profile("Primary", require_account=True,
                                  account_hint=hint)
        if primary["running"] and not payload.get("allow_running_source"):
            # reading a WAL db of a running app is safe; only flag it
            pass
        conn = ro_connect(primary["db_path"])
        try:
            _require_schema(conn, "Primary")
            owner = _owner_id(conn)
            servers = []
            src_ws_list = read_workspaces(conn)
            ws_by_id = {w["workspace_id"]: w for w in src_ws_list}
            for row in read_sources(conn, owner_id=owner):
                if row["kind"] != "mcp":
                    continue
                servers.append({
                    "slug": row["slug"], "name": row["name"],
                    "transport": decode_locator(row["endpoint"]).get("transport", "http"),
                    "endpoint": row["endpoint"],
                    "enabled": row["enabled"],
                    "source_permission": row["source_permission"],
                    "requires_credential": row["has_credential"],
                    "source_workspace": ws_by_id.get(row["workspace_id"]),
                    # Primary endpoint strings pass through verbatim (D5)
                    "locator": row["endpoint"],
                })
        finally:
            conn.close()
    else:
        raise Refusal("bad-source", "-From must be master|primary")

    results = []
    for name in targets:
        info = resolve_profile(name, account_hint=hint)
        entry = {"profile": name, "status": None}
        if info["account_status"] != "ok":
            entry["status"] = "skipped"
            entry["reason"] = info["account_status"]
            results.append(entry)
            continue
        if info["running"]:
            entry["status"] = "skipped"
            entry["reason"] = "running"
            results.append(entry)
            continue
        conn = ro_connect(info["db_path"])
        try:
            _require_schema(conn, name)
            owner = _owner_id(conn)
            tgt_workspaces = read_workspaces(conn)
            existing_all = read_sources(conn, owner_id=owner)
            pairs, ws_warns = _map_target_workspaces(
                src_ws_list, tgt_workspaces, policy)
            plan_ws = []
            for pair in pairs:
                ws_id = pair["target_workspace"]["workspace_id"]
                existing = [r for r in existing_all if r["workspace_id"] == ws_id]
                migrations, existing = _plan_slug_migrations(existing)
                merged = merge_sources(servers, existing)
                plan_ws.append({
                    "workspace_id": ws_id,
                    "root_path": pair["target_workspace"]["root_path"],
                    "matched_root": pair["matched_root"],
                    "trust_status": pair["target_workspace"].get("trust_status"),
                    "slug_migrations": migrations,
                    "creates": merged["creates"],
                    "updates": merged["updates"],
                    "kept_local": len(merged["manifest_absent"]),
                    "manifest_absent": merged["manifest_absent"],
                })
                if pair["target_workspace"].get("trust_status") != "trusted":
                    ws_warns.append({
                        "reason": "workspace-not-trusted",
                        "root_path": pair["target_workspace"]["root_path"],
                        "note": "source tools will not be offered in new runs "
                                "until the workspace is trusted in the GUI",
                    })
            entry["status"] = "planned"
            entry["workspaces"] = plan_ws
            entry["workspace_warnings"] = ws_warns
            entry["totals"] = {
                "creates": sum(len(w["creates"]) for w in plan_ws),
                "updates": sum(1 for w in plan_ws for u in w["updates"] if u["changed"]),
                "unchanged_updates": sum(1 for w in plan_ws for u in w["updates"]
                                         if not u["changed"]),
            }
            results.append(entry)
        finally:
            conn.close()
    return {"source": source, "policy": policy, "profiles": results}


def mcp_apply(payload):
    """One transaction per profile, verify-after re-read, clean backup first.
    Every create/update action is PRE-TESTED with a live local MCP discover
    (the app's own test semantics: spawn the stdio command or fetch the http
    endpoint) and written in the app's strict row shape - connected with the
    real tools_json on success, failed with a legal error_code on failure.
    'pending' is never written: the app cannot parse it (spec §9 E5)."""
    plan = mcp_plan(payload)
    dry_run = bool(payload.get("dry_run"))
    discover_timeout = payload.get("discover_timeout", 60)
    test_cache = {}

    def _tested(action):
        locator = action["endpoint"]
        if locator not in test_cache:
            test_cache[locator] = test_source_locator(locator, discover_timeout)
        return test_cache[locator]

    results = []
    for entry in plan["profiles"]:
        result = dict(entry)
        if entry["status"] == "skipped":
            results.append(result)
            continue
        info = resolve_profile(entry["profile"],
                               account_hint=payload.get("account_hint"))
        result["status"] = "unchanged"
        actions = []
        for ws in entry.get("workspaces") or []:
            for mig in ws.get("slug_migrations") or []:
                actions.append(("slug-migrate", ws["workspace_id"], dict(mig)))
            creates = ws.get("creates") or []
            updates = [u for u in (ws.get("updates") or []) if u.get("changed")]
            for create in creates:
                actions.append(("create", ws["workspace_id"], create))
            for update in updates:
                actions.append(("update", ws["workspace_id"], update))
            for slug in ws.get("manifest_absent") or []:
                actions.append(("kept-local", ws["workspace_id"], {"slug": slug}))
        result["action_count"] = len(actions)
        if not actions:
            results.append(result)
            continue
        if dry_run:
            result["status"] = "dry-run"
            results.append(result)
            continue
        # Pre-test every distinct locator once (live local discover), then
        # carry the tested row shape on the action.
        source_tests = []
        for kind, _, action in actions:
            if kind in ("kept-local", "slug-migrate"):
                continue
            test = _tested(action)
            action["test"] = {"ok": test["ok"], "error_code": test["error_code"],
                              "tool_count": test["tool_count"],
                              "dropped": test["dropped"]}
            if test["ok"]:
                action["status"] = "connected"
                action["error_code"] = None
                action["tools_json"] = json.dumps(
                    test["tools"], separators=(",", ":"), ensure_ascii=False)
                action["revision"] = tool_revision(
                    action["name"], action["endpoint"],
                    action["source_permission"], test["tools"])
            else:
                action["status"] = "failed"
                action["error_code"] = test["error_code"]
                action["tools_json"] = "[]"
                # keep the definition revision: the app's own recordFailure
                # also leaves the revision untouched when its test fails
            source_tests.append({"slug": action["slug"], "test": action["test"],
                                 "status": action["status"]})
        result["sources"] = source_tests
        backup_path = _backup_db(info["db_path"], info["path"], "mcp-sync")
        conn = rw_connect(info["db_path"])
        try:
            conn.execute("BEGIN IMMEDIATE")
            now = _iso_now()
            owner = _owner_id(conn)
            for kind, workspace_id, action in actions:
                if kind == "slug-migrate":
                    conn.execute(
                        "UPDATE " + SOURCE_TABLE + " SET slug = ?, updated_at = ?"
                        " WHERE owner_id = ? AND workspace_id = ? AND slug = ?",
                        (action["to"], now, owner, workspace_id, action["from"]))
                elif kind == "create":
                    conn.execute(
                        "INSERT INTO " + SOURCE_TABLE + " (owner_id, workspace_id,"
                        " kind, slug, name, endpoint, enabled, status, error_code,"
                        " credential_version, source_permission,"
                        " tool_permissions_json, revision, tools_json, updated_at)"
                        " VALUES (?, ?, 'mcp', ?, ?, ?, ?, ?, ?, NULL,"
                        " ?, '{}', ?, ?, ?)",
                        (owner, workspace_id, action["slug"], action["name"],
                         action["endpoint"], 1 if action["enabled"] else 0,
                         action["status"], action["error_code"],
                         action["source_permission"], action["revision"],
                         action["tools_json"], now))
                elif kind == "update":
                    conn.execute(
                        "UPDATE " + SOURCE_TABLE + " SET name = ?, endpoint = ?,"
                        " source_permission = ?, revision = ?, status = ?,"
                        " error_code = ?, tools_json = ?, updated_at = ?"
                        " WHERE owner_id = ? AND workspace_id = ? AND slug = ?",
                        (action["name"], action["endpoint"],
                         action["source_permission"], action["revision"],
                         action["status"], action["error_code"],
                         action["tools_json"], now,
                         owner, workspace_id, action["slug"]))
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        # verify-after: re-read every written row and require the app's own
        # strict row shape - "row written" is not "row usable"
        mismatches = []
        written = 0
        conn = ro_connect(info["db_path"])
        try:
            for kind, workspace_id, action in actions:
                if kind == "kept-local":
                    continue
                if kind == "slug-migrate":
                    new = conn.execute(
                        "SELECT 1 FROM " + SOURCE_TABLE +
                        " WHERE owner_id = ? AND workspace_id = ? AND slug = ?",
                        (owner, workspace_id, action["to"])).fetchone()
                    old = conn.execute(
                        "SELECT 1 FROM " + SOURCE_TABLE +
                        " WHERE owner_id = ? AND workspace_id = ? AND slug = ?",
                        (owner, workspace_id, action["from"])).fetchone()
                    if new is None or old is not None:
                        mismatches.append({"slug": action["from"],
                                           "error": "slug-migration-unverified"})
                    else:
                        written += 1
                    continue
                row = conn.execute(
                    "SELECT name, endpoint, source_permission, revision, status,"
                    " error_code, tools_json, updated_at, slug FROM "
                    + SOURCE_TABLE + " WHERE owner_id = ? AND workspace_id = ?"
                    " AND slug = ?", (owner, workspace_id, action["slug"])).fetchone()
                if row is None:
                    mismatches.append({"slug": action["slug"], "error": "missing"})
                    continue
                readd = {"slug": row[8], "name": row[0], "endpoint": row[1],
                         "source_permission": row[2], "revision": row[3],
                         "status": row[4], "error_code": row[5],
                         "tools_json": row[6], "updated_at": row[7]}
                expected = (action["name"], action["endpoint"],
                            action["source_permission"], action["revision"],
                            action["status"], action["error_code"],
                            action["tools_json"], now)
                got = (readd["name"], readd["endpoint"],
                       readd["source_permission"], readd["revision"],
                       readd["status"], readd["error_code"],
                       readd["tools_json"], readd["updated_at"])
                problems = strict_row_problems(readd)
                if got != expected or problems:
                    mismatches.append({"slug": action["slug"],
                                       "problems": problems, "row": list(row)})
                written += 1
        finally:
            conn.close()
        result["written"] = written
        result["backup"] = backup_path
        if mismatches:
            result["status"] = "failed"
            result["mismatches"] = mismatches
        else:
            result["status"] = "ok"
        results.append(result)
    failed = [r for r in results if r.get("status") == "failed"]
    return {"source": plan["source"], "policy": plan["policy"],
            "profiles": results, "ok": not failed}


# --------------------------------------------------------------------------
# chat history: inventory / import / revert

def _sidecar_path(profile_dir):
    return os.path.join(profile_dir, SIDECAR_NAME)


def _read_sidecar(profile_dir):
    path = _sidecar_path(profile_dir)
    if not os.path.isfile(path):
        return {"schemaVersion": 1, "imports": []}
    with open(path, "r", encoding="utf-8-sig") as handle:
        data = json.load(handle)
    data.setdefault("schemaVersion", 1)
    data.setdefault("imports", [])
    return data


def _write_sidecar(profile_dir, data):
    path = _sidecar_path(profile_dir)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
    os.replace(tmp, path)
    return path


def _iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        "{0:03d}Z".format(datetime.now(timezone.utc).microsecond // 1000)


def profile_inventory(payload):
    """Read-only suite inventory: per profile account/schema/workspace/
    source/chat counts (no bodies, no credential columns)."""
    targets = payload.get("targets") or list(_PROFILE_NAMES)
    out = []
    for name in targets:
        info = resolve_profile(name)
        entry = {
            "profile": name, "path": info["path"],
            "exists": info["exists"], "running": info["running"],
            "account_status": info["account_status"],
        }
        if info["account_status"] == "ok":
            try:
                conn = ro_connect(info["db_path"])
                try:
                    entry["schema"] = check_schema(conn)["ok"]
                    entry["workspaces"] = conn.execute(
                        "SELECT COUNT(*) FROM work_workspaces").fetchone()[0]
                    entry["sources"] = conn.execute(
                        "SELECT COUNT(*) FROM " + SOURCE_TABLE).fetchone()[0]
                    entry["sessions"] = conn.execute(
                        "SELECT COUNT(*) FROM work_sessions"
                        " WHERE deleted_at IS NULL").fetchone()[0]
                    entry["entries"] = conn.execute(
                        "SELECT COUNT(*) FROM neutral_session_entries").fetchone()[0]
                    entry["events"] = conn.execute(
                        "SELECT COUNT(*) FROM work_events").fetchone()[0]
                    entry["artifacts"] = conn.execute(
                        "SELECT COUNT(*) FROM governed_tool_artifacts").fetchone()[0]
                    entry["imported"] = sum(
                        1 for rec in _read_sidecar(info["path"])["imports"]
                        if not rec.get("reverted"))
                finally:
                    conn.close()
            except sqlite3.Error as exc:
                entry["db_error"] = str(exc)
        out.append(entry)
    return {"profiles": out}


def chat_inventory_for_profile(payload):
    """Bridge wrapper: resolve one profile, then inventory its chats.
    Read-only; safe against a running instance (WAL readers coexist)."""
    name = payload.get("profile") or payload.get("target")
    if not name:
        raise Refusal("bad-payload", 'payload needs {"profile": "c1"}')
    info = resolve_profile(name)
    if info["account_status"] != "ok":
        return {"profile": name, "status": "skipped",
                "reason": info["account_status"], "session_count": 0,
                "sessions": [], "imported_count": 0}
    result = chat_inventory(info["db_path"], info["path"])
    result["profile"] = name
    result["status"] = "ok"
    result["running"] = info["running"]
    return result


def chat_inventory(db_path, profile_dir):
    """Counts only -- never message bodies, never credential columns."""
    conn = ro_connect(db_path)
    try:
        _require_schema(conn, os.path.basename(os.path.dirname(
            os.path.dirname(os.path.dirname(db_path)))))
        imports = _read_sidecar(profile_dir)["imports"]
        imported = {rec["new_session_id"]: rec for rec in imports}
        sessions = []
        rows = conn.execute(
            "SELECT s.session_id, s.title, s.created_at, s.updated_at,"
            " s.external_provider, s.workspace_id, w.root_path"
            " FROM work_sessions s LEFT JOIN work_workspaces w"
            " ON w.workspace_id = s.workspace_id"
            " WHERE s.deleted_at IS NULL ORDER BY s.updated_at DESC").fetchall()
        for r in rows:
            sid = r[0]
            sessions.append({
                "session_id": sid,
                "title": r[1],
                "created_at": r[2], "updated_at": r[3],
                "external_provider": r[4],
                "workspace_root": r[6],
                "entries": conn.execute(
                    "SELECT COUNT(*) FROM neutral_session_entries"
                    " WHERE session_id = ?", (sid,)).fetchone()[0],
                "events": conn.execute(
                    "SELECT COUNT(*) FROM work_events WHERE session_id = ?",
                    (sid,)).fetchone()[0],
                "runs": conn.execute(
                    "SELECT COUNT(*) FROM work_runs WHERE session_id = ?",
                    (sid,)).fetchone()[0],
                "artifacts": conn.execute(
                    "SELECT COUNT(*) FROM governed_tool_artifacts"
                    " WHERE session_id = ?", (sid,)).fetchone()[0],
                "imported": sid in imported,
                "import_id": imported.get(sid, {}).get("import_id"),
            })
        return {
            "session_count": len(sessions),
            "sessions": sessions,
            "imported_count": sum(1 for s in sessions if s["imported"]),
            # provenance ids only (no titles/bodies) - the PS wrapper's
            # cross-profile diff (AC2S-040) matches source sessions against
            # these to report missing / already-imported / refused-im
            "source_imports": [
                {"source_session_id": r.get("source_session_id"),
                 "new_session_id": r.get("new_session_id"),
                 "import_id": r.get("import_id")}
                for r in imports],
        }
    finally:
        conn.close()


def _session_tree(conn, session_id):
    session = conn.execute(
        "SELECT * FROM work_sessions WHERE session_id = ?", (session_id,)).fetchone()
    if session is None:
        raise Refusal("session-missing",
                      "source session not found: {0}".format(session_id))
    cols = [d[1] for d in conn.execute("PRAGMA table_info(work_sessions)")]
    session_row = dict(zip(cols, session))
    runs = {}
    run_cols = [d[1] for d in conn.execute("PRAGMA table_info(work_runs)")]
    for row in conn.execute(
            "SELECT * FROM work_runs WHERE session_id = ?", (session_id,)):
        rec = dict(zip(run_cols, row))
        runs[rec["run_id"]] = rec
    entry_cols = [d[1] for d in conn.execute("PRAGMA table_info(neutral_session_entries)")]
    entries = []
    for row in conn.execute(
            "SELECT * FROM neutral_session_entries WHERE session_id = ?"
            " ORDER BY session_seq", (session_id,)):
        entries.append(dict(zip(entry_cols, row)))
    ev_info = list(conn.execute("PRAGMA table_info(work_events)"))
    event_cols = [c[1] for c in ev_info]
    # single-col INTEGER PK (the autoincrement cursor) is skipped on insert -
    # the target assigns fresh cursors; ORDER BY it to preserve the sequence
    ev_pk = [c[1] for c in ev_info if c[5] and (c[2] or "").upper() == "INTEGER"]
    events = []
    for row in conn.execute(
            "SELECT * FROM work_events WHERE session_id = ?" + (
                " ORDER BY " + ev_pk[0] if ev_pk else ""),
            (session_id,)):
        events.append(dict(zip(event_cols, row)))
    head = None
    head_cols = [d[1] for d in conn.execute("PRAGMA table_info(neutral_session_heads)")]
    row = conn.execute(
        "SELECT * FROM neutral_session_heads WHERE session_id = ?",
        (session_id,)).fetchone()
    if row:
        head = dict(zip(head_cols, row))
    artifacts = []
    art_cols = [d[1] for d in conn.execute("PRAGMA table_info(governed_tool_artifacts)")]
    for row in conn.execute(
            "SELECT * FROM governed_tool_artifacts WHERE session_id = ?",
            (session_id,)):
        artifacts.append(dict(zip(art_cols, row)))
    return {
        "session": session_row, "runs": runs, "entries": entries,
        "events": events, "events_pk": ev_pk,
        "head": head, "artifacts": artifacts,
        "cols": {"work_sessions": cols, "work_runs": run_cols,
                 "work_events": event_cols,
                 "neutral_session_entries": entry_cols,
                 "neutral_session_heads": head_cols,
                 "governed_tool_artifacts": art_cols},
    }


def _content_hash(tree):
    payload = {
        "title": tree["session"].get("title"),
        "entries": [[e["session_seq"], e["entry_type"], e["payload"]]
                    for e in tree["entries"]],
    }
    canon = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


def chat_import(payload):
    """Copy one source session into one target profile as a NEW local
    session (D8/D10/D11/D12). Refuses IM-bound sessions; nuls the copied
    runs' credential_version; drops (and counts) entries whose artifact
    revision is missing in the target."""
    src = resolve_profile(payload["source"], require_account=True)
    tgt = resolve_profile(payload["target"], require_account=True)
    if tgt["running"]:
        raise Refusal("target-running",
                      "{0} is running - close it first (D7)".format(payload["target"]))
    src_conn = ro_connect(src["db_path"])
    try:
        _require_schema(src_conn, payload["source"])
        tree = _session_tree(src_conn, payload["session_id"])
        source_ws_root = None
        ws_row = src_conn.execute(
            "SELECT root_path FROM work_workspaces WHERE workspace_id = ?",
            (tree["session"]["workspace_id"],)).fetchone()
        if ws_row:
            source_ws_root = ws_row[0]
    finally:
        src_conn.close()

    if tree["session"].get("external_provider"):
        raise Refusal("im-session",
                      "session {0} is IM-bound ({1}) - never copied (D12)".format(
                          payload["session_id"], tree["session"]["external_provider"]))

    content_hash = _content_hash(tree)
    sidecar = _read_sidecar(tgt["path"])
    for rec in sidecar["imports"]:
        if (rec.get("source_profile") == payload["source"]
                and rec.get("source_session_id") == payload["session_id"]):
            if rec.get("content_hash") == content_hash:
                return {"status": "skipped", "reason": "already-imported",
                        "import_id": rec["import_id"],
                        "new_session_id": rec["new_session_id"]}
            break  # same session, changed content: fall through and re-import

    tgt_conn = ro_connect(tgt["db_path"])
    try:
        _require_schema(tgt_conn, payload["target"])
        tgt_workspaces = read_workspaces(tgt_conn)
        pairs, _ = _map_target_workspaces(
            [{"root_path": source_ws_root}] if source_ws_root else [],
            tgt_workspaces, "default")
        target_ws = pairs[0]["target_workspace"]
        target_owner = _owner_id(tgt_conn)
        # tool revisions present in the target (artifact FK requirement)
        have_tool_rev = {
            (r[0], r[1]) for r in tgt_conn.execute(
                "SELECT tool_id, revision FROM governed_tool_revisions")}
    finally:
        tgt_conn.close()

    new_session_id = str(uuid.uuid4())
    run_map = {old: str(uuid.uuid4()) for old in tree["runs"]}
    events_kept, events_dropped = [], []
    for ev in tree["events"]:
        if ev["run_id"] in run_map:
            events_kept.append(ev)
        else:
            events_dropped.append({"event_id": ev["event_id"],
                                   "reason": "event-run-missing"})
    # fresh UUIDv4 ids - the work_events CHECKs demand real uuid4 shape (§5.3)
    event_map = {ev["event_id"]: str(uuid.uuid4()) for ev in events_kept}
    title_tag = payload.get("title_tag")
    if title_tag is None:
        title_tag = "[import] "
    new_title = (title_tag + (tree["session"].get("title") or "")) if title_tag else \
        (tree["session"].get("title") or "")

    dropped = []
    kept_entries = []
    for entry in tree["entries"]:
        suffix = entry["entry_id"].split(":", 1)[1] if ":" in entry["entry_id"] \
            else "e{0}".format(entry["session_seq"])
        new_run = run_map.get(entry["run_id"])
        if new_run is None:
            dropped.append({"entry_id": entry["entry_id"], "reason": "run-missing"})
            continue
        rec = dict(entry)
        rec["session_id"] = new_session_id
        rec["entry_id"] = "{0}:{1}".format(new_run, suffix)
        rec["run_id"] = new_run
        if entry["parent_entry_id"]:
            prefix, _, psuffix = entry["parent_entry_id"].partition(":")
            parent_run = run_map.get(prefix)
            if parent_run is None:
                dropped.append({"entry_id": entry["entry_id"],
                                "reason": "parent-run-missing"})
                continue
            rec["parent_entry_id"] = "{0}:{1}".format(parent_run, psuffix)
        else:
            rec["parent_entry_id"] = None
        kept_entries.append(rec)

    artifact_map = {}
    artifacts_copied, artifacts_skipped = [], []
    for artifact in tree["artifacts"]:
        if (artifact.get("tool_id"), artifact.get("tool_revision")) not in have_tool_rev:
            artifacts_skipped.append({"artifact": artifact.get("artifact_id"),
                                      "reason": "tool-revision-missing"})
            continue
        artifact_map[artifact["artifact_id"]] = str(uuid.uuid4())

    unresolved_pct = 0.0
    total_entries = len(tree["entries"])
    if total_entries:
        unresolved_pct = round(100.0 * len(dropped) / total_entries, 2)
    max_pct = float(payload.get("max_unresolved_pct", 5))
    if unresolved_pct > max_pct:
        raise Refusal("unresolved-threshold",
                      "{0}% of entries unresolved (limit {1}%)".format(
                          unresolved_pct, max_pct))

    if payload.get("dry_run"):
        return {"status": "dry-run",
                "new_session_id": new_session_id,
                "entries": len(kept_entries), "dropped": len(dropped),
                "runs": len(run_map), "events": len(events_kept),
                "artifacts": len(artifact_map),
                "artifacts_skipped": len(artifacts_skipped),
                "target_workspace": target_ws["root_path"],
                "title": new_title, "content_hash": content_hash}

    # custody rows are read up front so the whole copy is ONE transaction
    src_conn = ro_connect(src["db_path"])
    custody_by_artifact = {}
    try:
        custody_cols = [d[1] for d in src_conn.execute(
            "PRAGMA table_info(governed_tool_artifact_custody)")]
        for artifact in tree["artifacts"]:
            if artifact["artifact_id"] not in artifact_map:
                continue
            rows = []
            for row in src_conn.execute(
                    "SELECT * FROM governed_tool_artifact_custody"
                    " WHERE artifact_id = ?", (artifact["artifact_id"],)):
                rows.append(dict(zip(custody_cols, row)))
            custody_by_artifact[artifact["artifact_id"]] = rows
    finally:
        src_conn.close()

    backup_path = _backup_db(tgt["db_path"], tgt["path"], "chat-import")
    conn = rw_connect(tgt["db_path"])
    try:
        conn.execute("BEGIN IMMEDIATE")
        # 1. session (verbatim row, overridden identity columns)
        sess = dict(tree["session"])
        sess["session_id"] = new_session_id
        sess["owner_id"] = target_owner
        sess["workspace_id"] = target_ws["workspace_id"]
        sess["title"] = new_title
        sess["deleted_at"] = None
        sess["archived_at"] = None
        for col in list(sess):
            if col.startswith("external_"):
                sess[col] = None
        cols = tree["cols"]["work_sessions"]
        conn.execute(
            "INSERT INTO work_sessions ({0}) VALUES ({1})".format(
                ", ".join(cols), ", ".join(["?"] * len(cols))),
            [sess[c] for c in cols])
        # 2. runs (credential_version nulled, self-refs remapped-or-nulled)
        run_cols = tree["cols"]["work_runs"]
        for old_id, run in tree["runs"].items():
            rec = dict(run)
            rec["run_id"] = run_map[old_id]
            rec["session_id"] = new_session_id
            rec["credential_version"] = None
            for ref in ("merged_into_run_id", "retried_from_run_id"):
                if rec.get(ref):
                    rec[ref] = run_map.get(rec[ref])
            conn.execute(
                "INSERT INTO work_runs ({0}) VALUES ({1})".format(
                    ", ".join(run_cols), ", ".join(["?"] * len(run_cols))),
                [rec[c] for c in run_cols])
        # 2b. events (SPEC §5.5: identity columns remapped, payload verbatim)
        ev_skip = set(tree["events_pk"])
        ev_cols = [c for c in tree["cols"]["work_events"] if c not in ev_skip]
        for ev in events_kept:
            rec = dict(ev)
            rec["event_id"] = event_map[ev["event_id"]]
            rec["run_id"] = run_map[ev["run_id"]]
            rec["session_id"] = new_session_id
            conn.execute(
                "INSERT INTO work_events ({0}) VALUES ({1})".format(
                    ", ".join(ev_cols), ", ".join(["?"] * len(ev_cols))),
                [rec[c] for c in ev_cols])
        # 3. entries (INSERT only - the freeze trigger forbids UPDATE)
        entry_cols = tree["cols"]["neutral_session_entries"]
        for rec in kept_entries:
            conn.execute(
                "INSERT INTO neutral_session_entries ({0}) VALUES ({1})".format(
                    ", ".join(entry_cols), ", ".join(["?"] * len(entry_cols))),
                [rec[c] for c in entry_cols])
        # 4. head (remap the four id columns, recompute counters)
        if tree["head"]:
            head = dict(tree["head"])
            head["session_id"] = new_session_id
            for idcol in ("conversation_head_entry_id", "settled_answer_entry_id"):
                if head.get(idcol):
                    prefix, _, suffix = head[idcol].partition(":")
                    head[idcol] = "{0}:{1}".format(run_map.get(prefix), suffix) \
                        if run_map.get(prefix) else None
            for runcol in ("conversation_run_id", "settled_run_id"):
                if head.get(runcol):
                    head[runcol] = run_map.get(head[runcol])
            head["next_session_seq"] = (max(
                [e["session_seq"] for e in kept_entries] or [0])) + 1
            head["entry_count"] = len(kept_entries)
            head_cols = tree["cols"]["neutral_session_heads"]
            conn.execute(
                "INSERT INTO neutral_session_heads ({0}) VALUES ({1})".format(
                    ", ".join(head_cols), ", ".join(["?"] * len(head_cols))),
                [head[c] for c in head_cols])
        # 5. FTS rows (only request|answer, body recomputed from payload)
        for rec in kept_entries:
            if rec["entry_type"] not in FTS_ENTRY_TYPES:
                continue
            try:
                body = json.loads(rec["payload"]).get("data", {}).get("text") or ""
            except ValueError:
                body = ""
            if not isinstance(body, str):
                body = str(body)
            conn.execute(
                "INSERT INTO neutral_session_fts (session_id, entry_id, body)"
                " VALUES (?, ?, ?)", (new_session_id, rec["entry_id"], body))
        # 6. artifacts + custody
        art_cols = tree["cols"]["governed_tool_artifacts"]
        art_by_id = {a["artifact_id"]: a for a in tree["artifacts"]}
        for artifact in tree["artifacts"]:
            new_id = artifact_map.get(artifact["artifact_id"])
            if new_id is None:
                continue
            rec = dict(artifact)
            rec["artifact_id"] = new_id
            rec["session_id"] = new_session_id
            if rec.get("run_id"):
                rec["run_id"] = run_map.get(rec["run_id"])
            conn.execute(
                "INSERT INTO governed_tool_artifacts ({0}) VALUES ({1})".format(
                    ", ".join(art_cols), ", ".join(["?"] * len(art_cols))),
                [rec[c] for c in art_cols])
            for rec in custody_by_artifact.get(artifact["artifact_id"], []):
                crec = dict(rec)
                crec["artifact_id"] = artifact_map[artifact["artifact_id"]]
                if crec.get("custody_id"):
                    crec["custody_id"] = str(uuid.uuid4())
                conn.execute(
                    "INSERT OR REPLACE INTO governed_tool_artifact_custody"
                    " ({0}) VALUES ({1})".format(
                        ", ".join(custody_cols), ", ".join(["?"] * len(custody_cols))),
                    [crec[c] for c in custody_cols])
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    # verify-after: counts on a fresh read-only connection
    conn = ro_connect(tgt["db_path"])
    try:
        verify = {
            "sessions": conn.execute(
                "SELECT COUNT(*) FROM work_sessions WHERE session_id = ?",
                (new_session_id,)).fetchone()[0],
            "entries": conn.execute(
                "SELECT COUNT(*) FROM neutral_session_entries"
                " WHERE session_id = ?", (new_session_id,)).fetchone()[0],
            "runs": conn.execute(
                "SELECT COUNT(*) FROM work_runs WHERE session_id = ?",
                (new_session_id,)).fetchone()[0],
            "events": conn.execute(
                "SELECT COUNT(*) FROM work_events WHERE session_id = ?",
                (new_session_id,)).fetchone()[0],
            "heads": conn.execute(
                "SELECT COUNT(*) FROM neutral_session_heads"
                " WHERE session_id = ?", (new_session_id,)).fetchone()[0],
            "fts": conn.execute(
                "SELECT COUNT(*) FROM neutral_session_fts WHERE session_id = ?",
                (new_session_id,)).fetchone()[0],
            "artifacts": conn.execute(
                "SELECT COUNT(*) FROM governed_tool_artifacts"
                " WHERE session_id = ?", (new_session_id,)).fetchone()[0],
        }
    finally:
        conn.close()
    expected = {"sessions": 1, "entries": len(kept_entries), "runs": len(run_map),
                "events": len(events_kept),
                "heads": 1 if tree["head"] else 0,
                "fts": sum(1 for e in kept_entries
                           if e["entry_type"] in FTS_ENTRY_TYPES),
                "artifacts": len(artifact_map)}
    ok = all(verify[k] == expected[k] for k in expected)

    import_id = str(uuid.uuid4())
    record = {
        "import_id": import_id,
        "source_profile": payload["source"],
        "target_profile": payload["target"],
        "source_session_id": payload["session_id"],
        "new_session_id": new_session_id,
        "content_hash": content_hash,
        "created_at": _iso_now(),
        "title_tag": title_tag,
        "original_title": tree["session"].get("title"),
        "target_workspace": target_ws["root_path"],
        "counts": {"entries": len(kept_entries), "dropped": len(dropped),
                   "runs": len(run_map), "events": len(events_kept),
                   "artifacts": len(artifact_map)},
        "backup": backup_path,
    }
    sidecar["imports"].append(record)
    _write_sidecar(tgt["path"], sidecar)
    return {"status": "ok" if ok else "failed", "import_id": import_id,
            "new_session_id": new_session_id, "verify": verify,
            "expected": expected, "dropped": dropped,
            "events_dropped": events_dropped,
            "artifacts_skipped": artifacts_skipped, "backup": backup_path,
            "title": new_title}


def chat_revert(payload):
    """Tombstone + delete exactly the rows one import created (plan §7)."""
    tgt = resolve_profile(payload["target"], require_account=True)
    if tgt["running"]:
        raise Refusal("target-running",
                      "{0} is running - close it first".format(payload["target"]))
    sidecar = _read_sidecar(tgt["path"])
    record = None
    for rec in sidecar["imports"]:
        if rec.get("import_id") == payload["import_id"] and not rec.get("reverted"):
            record = rec
            break
    if record is None:
        raise Refusal("import-not-found",
                      "no active import {0!r} in the sidecar".format(payload["import_id"]))
    new_sid = record["new_session_id"]
    backup_path = _backup_db(tgt["db_path"], tgt["path"], "chat-revert")
    conn = rw_connect(tgt["db_path"])
    try:
        conn.execute("BEGIN IMMEDIATE")
        # tombstone first - the delete triggers demand it (G6)
        conn.execute(
            "UPDATE work_sessions SET deleted_at = ? WHERE session_id = ?"
            " AND deleted_at IS NULL", (_iso_now(), new_sid))
        for sql in (
                "DELETE FROM neutral_session_fts WHERE session_id = ?",
                "DELETE FROM work_events WHERE session_id = ?",
                "DELETE FROM governed_tool_artifact_custody WHERE artifact_id IN"
                " (SELECT artifact_id FROM governed_tool_artifacts"
                "  WHERE session_id = ?)",
                "DELETE FROM governed_tool_artifacts WHERE session_id = ?",
                "DELETE FROM neutral_session_entries WHERE session_id = ?",
                "DELETE FROM neutral_session_heads WHERE session_id = ?",
                "DELETE FROM work_runs WHERE session_id = ?",
                "DELETE FROM work_sessions WHERE session_id = ?"):
            conn.execute(sql, (new_sid,))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    conn = ro_connect(tgt["db_path"])
    try:
        left = conn.execute(
            "SELECT (SELECT COUNT(*) FROM work_sessions WHERE session_id = ?)"
            " + (SELECT COUNT(*) FROM neutral_session_entries"
            "     WHERE session_id = ?)"
            " + (SELECT COUNT(*) FROM work_runs WHERE session_id = ?)"
            " + (SELECT COUNT(*) FROM work_events WHERE session_id = ?)"
            " + (SELECT COUNT(*) FROM neutral_session_heads"
            "     WHERE session_id = ?)"
            " + (SELECT COUNT(*) FROM neutral_session_fts"
            "     WHERE session_id = ?)"
            " + (SELECT COUNT(*) FROM governed_tool_artifacts"
            "     WHERE session_id = ?)",
            (new_sid,) * 7).fetchone()[0]
    finally:
        conn.close()
    record["reverted"] = True
    record["reverted_at"] = _iso_now()
    _write_sidecar(tgt["path"], sidecar)
    return {"status": "ok" if left == 0 else "failed",
            "rows_left": left, "backup": backup_path}
