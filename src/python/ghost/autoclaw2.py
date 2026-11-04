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
import re
import shutil
import sqlite3
import uuid
from datetime import datetime, timezone

STDIO_PREFIX = "stdio+v1:"
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
REVISION_PREFIX = "sync-v1:"
SIDECAR_NAME = ".autoclaw2-chat-imports.json"
BACKUP_DIR_NAME = ".autoclaw2-sync-backups"
SOURCE_TABLE = "governed_connected_sources"
MIGRATION_ID = "0001_clean_dogfood_baseline"
MIGRATION_SEQUENCE = 80
MIGRATION_CHECKSUM = "sha256:63f45a379d39b0956d8818a33d23d2f71ef4dd3d1b82bf87cbd5e1d4a2f7718c"
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


def resolve_profile(name, require_account=False):
    """Resolve one profile to its account runtime DB. Returns a dict with
    status fields; raises Refusal only for hard errors (unknown name,
    ambiguous account) -- missing accounts come back as status so the
    caller can SKIP+WARN instead of failing a whole run."""
    pdir = profile_path(name)
    info = {
        "profile": name, "path": pdir, "exists": os.path.isdir(pdir),
        "account_dir": None, "account_status": None, "db_path": None,
        "running": False,
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
        info["account_status"] = "ambiguous-account"
        if require_account:
            raise Refusal("ambiguous-account",
                          "{0}: {1} account dirs, refusing to guess".format(name, len(accounts)))
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
    """Schema gate (spec F3/R4): the migration row must match the version
    this module was written against, and every column we touch must exist."""
    rows = conn.execute(
        "SELECT migration_id, sequence, checksum FROM schema_migrations").fetchall()
    expected = (MIGRATION_ID, MIGRATION_SEQUENCE, MIGRATION_CHECKSUM)
    if len(rows) != 1 or (rows[0][0], rows[0][1], rows[0][2]) != expected:
        return {
            "ok": False,
            "expected": {"migration_id": expected[0], "sequence": expected[1],
                         "checksum": expected[2]},
            "found": [{"migration_id": r[0], "sequence": r[1], "checksum": r[2]}
                      for r in rows],
        }
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
    return {"ok": True}


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
        "is_default": bool(r[3]),
    } for r in conn.execute(
        "SELECT workspace_id, display_name, root_path, is_default "
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
            "command": raw.get("command"),
            "args": raw.get("args") or [],
            "cwd": raw.get("cwd") or "",
            "endpoint": raw.get("endpoint"),
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
            changed = (row["name"] != server["name"]
                       or row["endpoint"] != locator
                       or row["source_permission"] != server["source_permission"])
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


def mcp_plan(payload):
    """No writes. Per profile: resolved workspaces + create/update actions."""
    targets = payload.get("targets") or ["c1", "c2", "c3", "c4", "c5"]
    source = payload.get("from", "master")
    policy = payload.get("policy", "default")
    if source == "master":
        manifest = load_manifest(payload["manifest_path"])
        servers = manifest["servers"]
        src_ws_list = None
    elif source == "primary":
        primary = resolve_profile("Primary", require_account=True)
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
        info = resolve_profile(name)
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
                existing = [r for r in existing_all
                            if r["workspace_id"] == pair["target_workspace"]["workspace_id"]]
                merged = merge_sources(servers, existing)
                plan_ws.append({
                    "workspace_id": pair["target_workspace"]["workspace_id"],
                    "root_path": pair["target_workspace"]["root_path"],
                    "matched_root": pair["matched_root"],
                    "creates": merged["creates"],
                    "updates": merged["updates"],
                    "kept_local": len(merged["manifest_absent"]),
                    "manifest_absent": merged["manifest_absent"],
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
    """One transaction per profile, verify-after re-read, clean backup first."""
    plan = mcp_plan(payload)
    dry_run = bool(payload.get("dry_run"))
    results = []
    for entry in plan["profiles"]:
        result = dict(entry)
        if entry["status"] == "skipped":
            results.append(result)
            continue
        info = resolve_profile(entry["profile"])
        result["status"] = "unchanged"
        actions = []
        for ws in entry.get("workspaces") or []:
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
        backup_path = _backup_db(info["db_path"], info["path"], "mcp-sync")
        conn = rw_connect(info["db_path"])
        try:
            conn.execute("BEGIN IMMEDIATE")
            now = _iso_now()
            owner = _owner_id(conn)
            for kind, workspace_id, action in actions:
                if kind == "create":
                    conn.execute(
                        "INSERT INTO " + SOURCE_TABLE + " (owner_id, workspace_id,"
                        " kind, slug, name, endpoint, enabled, status, error_code,"
                        " credential_version, source_permission,"
                        " tool_permissions_json, revision, tools_json, updated_at)"
                        " VALUES (?, ?, 'mcp', ?, ?, ?, ?, 'pending', NULL,"
                        " NULL, ?, '{}', ?, '[]', ?)",
                        (owner, workspace_id, action["slug"], action["name"],
                         action["endpoint"], 1 if action["enabled"] else 0,
                         action["source_permission"], action["revision"], now))
                elif kind == "update":
                    conn.execute(
                        "UPDATE " + SOURCE_TABLE + " SET name = ?, endpoint = ?,"
                        " source_permission = ?, revision = ?, updated_at = ?"
                        " WHERE owner_id = ? AND workspace_id = ? AND slug = ?",
                        (action["name"], action["endpoint"],
                         action["source_permission"], action["revision"], now,
                         owner, workspace_id, action["slug"]))
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        # verify-after: re-read and compare the written definition fields
        mismatches = []
        written = 0
        conn = ro_connect(info["db_path"])
        try:
            for kind, workspace_id, action in actions:
                if kind == "kept-local":
                    continue
                row = conn.execute(
                    "SELECT name, endpoint, source_permission, revision FROM "
                    + SOURCE_TABLE + " WHERE owner_id = ? AND workspace_id = ?"
                    " AND slug = ?", (owner, workspace_id, action["slug"])).fetchone()
                if row is None:
                    mismatches.append({"slug": action["slug"], "error": "missing"})
                    continue
                if (row[0], row[1], row[2], row[3]) != (
                        action["name"], action["endpoint"],
                        action["source_permission"], action["revision"]):
                    mismatches.append({"slug": action["slug"], "row": list(row)})
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
