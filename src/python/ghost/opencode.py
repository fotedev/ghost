"""OpenCode cross-instance CHAT import (Primary -> clone sessions).

The store evidence this module encodes (mined 2026-11-19 from the live
~/.local/share/opencode/opencode.db + a clone's <home>/data/opencode/
opencode.db, schema identical across instances):

  - Sessions live IN THE DB: session_v2 (FK -> project) with
    session_message children (the whole message payload rides the JSON
    `data` column - session_part/blob/blob_ref exist but are empty in the
    observed schema; they are imported anyway so a future app version
    that populates them ports unchanged) and per-session
    instruction_state/instruction_entry rows plus hash-addressed
    instruction_blob text blobs.
  - project ids are STABLE PER WORKTREE PATH across instances (Primary and
    clone c1 both carry e4ece93c... for C:/programming/github/unban-machine-id),
    so a project row is reused by worktree-path match, or copied verbatim
    (id included) when the target has no row for that path.
  - Auth does NOT live in the db (account/credential/control_account were
    0 rows; the CLI keeps auth.json beside it) - those tables are NEVER
    touched, nor are kv/event*/job/session_inbox/automation/permission/
    project_directory/worktree/migration (app-level or runtime state).

Import contract (the AutoClaw2 chat-import discipline adapted):
  - The session id IS the identity and is preserved (PK idempotence:
    re-import of an already-present id is a reported skip, and a reverted
    import becomes plannable again because the delete freed the id).
  - The selection expands to the full family: ancestors of every selected
    session (a subagent without its parent is broken UI) plus descendants.
  - Titles get a "[import] " tag (D11 convention) unless already tagged.
  - One transaction, foreign_keys ON (the schema declares ON DELETE
    CASCADE for messages/parts/instruction/blob_ref), backup first via the
    sqlite3 backup API (WAL-safe), verify-after recount + sampled byte
    compare, manifest sidecar per clone home drives -Revert.

Counts only are ever reported - never message bodies, never credential
columns (the account/credential/control_account tables are not even read).
"""

import json
import os
import sqlite3
import uuid
from datetime import datetime, timezone
from urllib.parse import quote

MANIFEST_NAME = "chat-sync-manifest.json"

# The session graph + its payload tables (all FK-declared onto session_v2 /
# session_message). instruction_blob is hash-addressed (no session FK).
_TREE_TABLES = ("session_v2", "session_message", "session_part",
                "blob", "blob_ref",
                "instruction_blob", "instruction_entry", "instruction_state")
_REQUIRED_TABLES = ("project",) + _TREE_TABLES
# App-level / runtime / auth tables this tool must NEVER read or copy.
_NEVER_TABLES = ("account", "account_state", "control_account", "credential",
                 "kv", "event", "event_sequence", "job", "session_inbox",
                 "automation", "permission", "project_directory", "worktree",
                 "migration")


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
# connections / schema gate

def _uri(path):
    return "file:" + quote(path.replace("\\", "/"), safe="/:") + "?mode=ro"


def ro_connect(path):
    if not os.path.isfile(path):
        raise Refusal("db-missing", "database not found: {0}".format(path))
    return sqlite3.connect(_uri(path), uri=True)


def rw_connect(path):
    if not os.path.isfile(path):
        raise Refusal("db-missing", "database not found: {0}".format(path))
    conn = sqlite3.connect(path, timeout=10.0)
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def _table_names(conn):
    return {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}


def _require_schema(conn, label):
    tables = _table_names(conn)
    missing = [t for t in _REQUIRED_TABLES if t not in tables]
    if missing:
        raise Refusal(
            "schema-mismatch",
            "{0}: required tables missing {1} - the app schema drifted "
            "from the mined 2026-11-19 layout; re-derive the contract "
            "before importing (never half-write)".format(label, missing))
    return tables


def _columns(conn, table):
    return [r[1] for r in conn.execute(
        "PRAGMA table_info({0})".format(table))]


def _row_dict(conn, table, row):
    return dict(zip(_columns(conn, table), row))


def _insert(conn, table, rec, cols):
    conn.execute(
        "INSERT INTO {0} ({1}) VALUES ({2})".format(
            table, ", ".join(cols), ", ".join(["?"] * len(cols))),
        [rec[c] for c in cols])


# --------------------------------------------------------------------------
# manifest sidecar (per clone home)

def _read_manifest(path):
    if not os.path.isfile(path):
        return {"schemaVersion": 1, "imports": []}
    with open(path, "r", encoding="utf-8-sig") as handle:
        data = json.load(handle)
    data.setdefault("schemaVersion", 1)
    data.setdefault("imports", [])
    return data


def _write_manifest(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
    os.replace(tmp, path)
    return path


def _iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        "{0:03d}Z".format(datetime.now(timezone.utc).microsecond // 1000)


def _backup_db(db_path, backup_root, label):
    """Clean single-file backup via the sqlite3 backup API (WAL-safe)."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    dest_dir = os.path.join(backup_root, stamp + "-" + label)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(db_path))
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


# --------------------------------------------------------------------------
# session graph helpers

def _family_closure(conn, session_ids):
    """Expand a selection to ancestors + descendants (a subagent without
    its parent is broken UI; the reverse drops a run's children). Missing
    ids are reported by the caller; unknown ids here raise."""
    known = {r[0] for r in conn.execute("SELECT id FROM session_v2")}
    unknown = [s for s in session_ids if s not in known]
    if unknown:
        raise Refusal("session-missing",
                      "source session(s) not found: {0}".format(unknown))
    parent_of = {r[0]: r[1] for r in conn.execute(
        "SELECT id, parent_id FROM session_v2 WHERE parent_id IS NOT NULL")}
    family = set()
    for sid in session_ids:
        # ancestors (each parent up the chain, topmost included)
        cur = parent_of.get(sid)
        seen = set()
        while cur is not None and cur not in seen:
            seen.add(cur)
            family.add(cur)
            cur = parent_of.get(cur)
        # descendants
        stack, seen = [sid], set()
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            family.add(cur)
            stack.extend(r[0] for r in conn.execute(
                "SELECT id FROM session_v2 WHERE parent_id = ?", (cur,)))
    return family


def _family_order(conn, family):
    """Parents before children (topological by chain depth, then
    time_created) so foreign keys resolve without deferral."""
    parent_of = {r[0]: r[1] for r in conn.execute(
        "SELECT id, parent_id FROM session_v2 WHERE parent_id IS NOT NULL")}
    depth = {}
    for sid in family:
        cur, d, seen = sid, 0, set()
        while cur in parent_of and cur in family and cur not in seen:
            seen.add(cur)
            cur = parent_of[cur]
            d += 1
        depth[sid] = d
    created = {r[0]: r[1] for r in conn.execute(
        "SELECT id, time_created FROM session_v2")}
    return sorted(family, key=lambda s: (depth.get(s, 0), created.get(s, 0)))


def _session_tree(conn, session_id):
    """Everything one session owns - the copy set. Counts + rows only."""
    cols = _columns(conn, "session_v2")
    row = conn.execute(
        "SELECT * FROM session_v2 WHERE id = ?", (session_id,)).fetchone()
    if row is None:
        raise Refusal("session-missing",
                      "source session not found: {0}".format(session_id))
    session = _row_dict(conn, "session_v2", row)
    messages = []
    for mrow in conn.execute(
            "SELECT * FROM session_message WHERE session_id = ?"
            " ORDER BY seq, time_created, id", (session_id,)):
        messages.append(_row_dict(conn, "session_message", mrow))
    parts = []
    for prow in conn.execute(
            "SELECT * FROM session_part WHERE session_id = ?"
            " ORDER BY message_id, ordinal", (session_id,)):
        parts.append(_row_dict(conn, "session_part", prow))
    blob_refs = []
    for brow in conn.execute(
            "SELECT * FROM blob_ref WHERE session_id = ?", (session_id,)):
        blob_refs.append(_row_dict(conn, "blob_ref", brow))
    inst_state = [ _row_dict(conn, "instruction_state", r) for r in
        conn.execute("SELECT * FROM instruction_state WHERE session_id = ?",
                     (session_id,))]
    inst_entry = [ _row_dict(conn, "instruction_entry", r) for r in
        conn.execute("SELECT * FROM instruction_entry WHERE session_id = ?",
                     (session_id,))]
    return {"session": session, "messages": messages, "parts": parts,
            "blob_refs": blob_refs, "instruction_state": inst_state,
            "instruction_entry": inst_entry,
            "cols": {t: _columns(conn, t) for t in _TREE_TABLES}}


def _project_worktrees(conn):
    return {r[0]: r[1] for r in conn.execute("SELECT id, worktree FROM project")}


# --------------------------------------------------------------------------
# verbs

def oc_chat_inventory(payload):
    """Read-only inventory of one OpenCode db - session list with counts,
    imported flags from the manifest. Never message bodies."""
    db_path = payload.get("db_path")
    manifest_path = payload.get("manifest_path")
    if not db_path:
        raise Refusal("bad-payload", 'payload needs {"db_path": ...}')
    manifest = _read_manifest(manifest_path) if manifest_path else \
        {"imports": []}
    imported = {}
    for rec in manifest["imports"]:
        if not rec.get("reverted"):
            for sid in rec.get("session_ids", []):
                imported[sid] = rec["import_id"]
    conn = ro_connect(db_path)
    try:
        _require_schema(conn, db_path)
        worktrees = _project_worktrees(conn)
        sessions = []
        for r in conn.execute(
                "SELECT s.id, s.project_id, s.parent_id, s.title,"
                " s.directory, s.time_created, s.time_updated"
                " FROM session_v2 s ORDER BY s.time_updated DESC"):
            sid = r[0]
            sessions.append({
                "session_id": sid,
                "project_id": r[1],
                "project_worktree": worktrees.get(r[1]),
                "parent_id": r[2],
                "title": r[3],
                "directory": r[4],
                "time_created": r[5],
                "time_updated": r[6],
                "messages": conn.execute(
                    "SELECT COUNT(*) FROM session_message WHERE session_id = ?",
                    (sid,)).fetchone()[0],
                "parts": conn.execute(
                    "SELECT COUNT(*) FROM session_part WHERE session_id = ?",
                    (sid,)).fetchone()[0],
                "imported": sid in imported,
                "import_id": imported.get(sid),
            })
        return {"status": "ok", "session_count": len(sessions),
                "sessions": sessions,
                "imported_count": sum(1 for s in sessions if s["imported"]),
                "source_imports": [
                    {"import_id": rec.get("import_id"),
                     "session_ids": rec.get("session_ids", [])}
                    for rec in manifest["imports"] if not rec.get("reverted")]}
    finally:
        conn.close()


def oc_chat_import(payload):
    """Copy source sessions into a target OpenCode db as the SAME ids
    (PK idempotence). One transaction, backup first, verify-after,
    manifest record last."""
    source_db = payload.get("source_db")
    target_db = payload.get("target_db")
    manifest_path = payload.get("manifest_path")
    backup_root = payload.get("backup_root")
    label = payload.get("label") or "oc-chat-import"
    if not (source_db and target_db and manifest_path and backup_root):
        raise Refusal("bad-payload",
                      'payload needs {"source_db", "target_db", '
                      '"manifest_path", "backup_root"}')
    if os.path.abspath(source_db) == os.path.abspath(target_db):
        raise Refusal("same-db", "source and target db are the same file")
    title_tag = payload.get("title_tag")
    if title_tag is None:
        title_tag = "[import] "

    src = ro_connect(source_db)
    try:
        _require_schema(src, source_db)
        selected = payload.get("session_ids") or []
        if not selected:
            raise Refusal("no-selection",
                          "session_ids is empty - nothing to import")
        family = _family_closure(src, selected)
        ordered = _family_order(src, family)
        trees = {}
        for sid in ordered:
            trees[sid] = _session_tree(src, sid)
        src_projects = _project_worktrees(src)
    finally:
        src.close()

    tgt = ro_connect(target_db)
    try:
        _require_schema(tgt, target_db)
        existing = {r[0] for r in tgt.execute("SELECT id FROM session_v2")}
        tgt_projects_by_id = _project_worktrees(tgt)
        tgt_projects_by_wt = {}
        for pid, wt in tgt_projects_by_id.items():
            tgt_projects_by_wt.setdefault(wt, pid)
    finally:
        tgt.close()

    skipped = sorted(family & existing)
    todo = [s for s in ordered if s not in existing]
    if not todo:
        return {"status": "skipped", "reason": "all-selected-present",
                "skipped_existing": skipped}

    # project remap: reuse by id, then by worktree, else copy verbatim
    project_remap = {}
    projects_insert = {}
    for sid in todo:
        src_pid = trees[sid]["session"]["project_id"]
        if src_pid in project_remap:
            continue
        src_wt = src_projects.get(src_pid)
        if src_pid in tgt_projects_by_id:
            project_remap[src_pid] = src_pid  # same id in target: reuse
        elif src_wt in tgt_projects_by_wt:
            project_remap[src_pid] = tgt_projects_by_wt[src_wt]
        else:
            project_remap[src_pid] = src_pid
            projects_insert[src_pid] = True

    def _count_family():
        return {
            "sessions": len(todo),
            "messages": sum(len(t["messages"]) for t in
                            (trees[s] for s in todo)),
            "parts": sum(len(t["parts"]) for t in
                         (trees[s] for s in todo)),
            "blob_refs": sum(len(t["blob_refs"]) for t in
                             (trees[s] for s in todo)),
            "instruction_state": sum(len(t["instruction_state"]) for t in
                                     (trees[s] for s in todo)),
            "instruction_entry": sum(len(t["instruction_entry"]) for t in
                                     (trees[s] for s in todo)),
            "projects": len(projects_insert),
        }

    counts = _count_family()
    if payload.get("dry_run"):
        return {"status": "dry-run",
                "session_ids": todo,
                "skipped_existing": skipped,
                "expanded_from": sorted(family),
                "projects_inserted": sorted(projects_insert),
                "project_remap": project_remap,
                "counts": counts}

    # read the verbatim project rows up front (one transaction on target)
    src = ro_connect(source_db)
    project_rows = {}
    try:
        for pid in projects_insert:
            row = src.execute(
                "SELECT * FROM project WHERE id = ?", (pid,)).fetchone()
            project_rows[pid] = _row_dict(src, "project", row)
    finally:
        src.close()

    # instruction_blob is hash-addressed: copy any hashes the target lacks
    needed_hashes = {r["hash"] for t in (trees[s] for s in todo)
                     for r in t["blob_refs"]}
    tgt = ro_connect(target_db)
    try:
        tgt_hashes = {r[0] for r in tgt.execute("SELECT hash FROM blob")}
        tgt_inst_hashes = {r[0] for r in tgt.execute(
            "SELECT hash FROM instruction_blob")}
    finally:
        tgt.close()
    missing_blob_refs_needed = needed_hashes - tgt_hashes
    src = ro_connect(source_db)
    blob_rows = {}
    try:
        for h in missing_blob_refs_needed:
            row = src.execute(
                "SELECT * FROM blob WHERE hash = ?", (h,)).fetchone()
            if row is not None:
                blob_rows[h] = _row_dict(src, "blob", row)
        inst_blob_rows = {}
        for r in src.execute("SELECT * FROM instruction_blob"):
            rec = _row_dict(src, "instruction_blob", r)
            if rec["hash"] not in tgt_inst_hashes:
                inst_blob_rows[rec["hash"]] = rec
    finally:
        src.close()

    backup_path = _backup_db(target_db, backup_root, label)
    conn = rw_connect(target_db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        for pid in projects_insert:
            _insert(conn, "project", project_rows[pid],
                    _columns(conn, "project"))
        for sid in todo:
            rec = dict(trees[sid]["session"])
            rec["project_id"] = project_remap[rec["project_id"]]
            if title_tag and not (rec.get("title") or "").startswith(title_tag):
                rec["title"] = title_tag + (rec.get("title") or "")
            _insert(conn, "session_v2", rec, _columns(conn, "session_v2"))
        for h, rec in blob_rows.items():
            _insert(conn, "blob", rec, _columns(conn, "blob"))
        for sid in todo:
            for rec in trees[sid]["blob_refs"]:
                _insert(conn, "blob_ref", rec, _columns(conn, "blob_ref"))
        for sid in todo:
            for rec in trees[sid]["messages"]:
                _insert(conn, "session_message", rec,
                        _columns(conn, "session_message"))
        for sid in todo:
            for rec in trees[sid]["parts"]:
                _insert(conn, "session_part", rec,
                        _columns(conn, "session_part"))
        for h, rec in inst_blob_rows.items():
            _insert(conn, "instruction_blob", rec,
                    _columns(conn, "instruction_blob"))
        for sid in todo:
            for rec in trees[sid]["instruction_state"]:
                _insert(conn, "instruction_state", rec,
                        _columns(conn, "instruction_state"))
        for sid in todo:
            for rec in trees[sid]["instruction_entry"]:
                _insert(conn, "instruction_entry", rec,
                        _columns(conn, "instruction_entry"))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    # verify-after: recount + byte-compare one sampled message
    chk = ro_connect(target_db)
    try:
        verified = {}
        for sid in todo:
            n = chk.execute(
                "SELECT COUNT(*) FROM session_v2 WHERE id = ?",
                (sid,)).fetchone()[0]
            verified[sid] = n
        sample_ok = True
        first = todo[0]
        for mrec in trees[first]["messages"][:1]:
            row = chk.execute(
                "SELECT data FROM session_message WHERE id = ?",
                (mrec["id"],)).fetchone()
            sample_ok = row is not None and row[0] == mrec["data"]
        survivor_msgs = sum(
            chk.execute("SELECT COUNT(*) FROM session_message WHERE session_id = ?",
                        (sid,)).fetchone()[0] for sid in todo)
    finally:
        chk.close()
    all_present = all(v == 1 for v in verified.values())

    import_id = str(uuid.uuid4())
    manifest = _read_manifest(manifest_path)
    manifest["imports"].append({
        "import_id": import_id,
        "ts": _iso_now(),
        "source_db": os.path.basename(source_db),
        "session_ids": todo,
        "skipped_existing": skipped,
        "project_remap": project_remap,
        "counts": counts,
        "title_tag": title_tag,
        "backup": backup_path,
    })
    os.makedirs(os.path.dirname(manifest_path) or ".", exist_ok=True)
    _write_manifest(manifest_path, manifest)

    return {"status": "ok" if (all_present and sample_ok) else "failed",
            "import_id": import_id,
            "session_ids": todo,
            "skipped_existing": skipped,
            "project_remap": project_remap,
            "counts": counts,
            "messages_in_target": survivor_msgs,
            "verify": {"sessions_present": all_present,
                       "sample_message_equal": sample_ok},
            "backup": backup_path,
            "manifest": manifest_path}


def oc_chat_revert(payload):
    """Delete exactly the sessions one import created (FK cascades wipe
    messages/parts/instruction/blob_ref) + tombstone the manifest record.
    instruction_blob rows are hash-addressed and intentionally left
    (content-addressed orphans are harmless and tiny), and so are project
    rows the import inserted (the app creates exactly such rows whenever
    a directory is opened - a reverted import leaves the same shape)."""
    target_db = payload.get("target_db")
    manifest_path = payload.get("manifest_path")
    backup_root = payload.get("backup_root")
    label = payload.get("label") or "oc-chat-revert"
    if not (target_db and manifest_path and backup_root):
        raise Refusal("bad-payload",
                      'payload needs {"target_db", "manifest_path", '
                      '"backup_root"}')
    manifest = _read_manifest(manifest_path)
    record = None
    for rec in manifest["imports"]:
        if rec.get("import_id") == payload.get("import_id") \
                and not rec.get("reverted"):
            record = rec
            break
    if record is None:
        raise Refusal("import-not-found",
                      "no active import {0!r} in the manifest".format(
                          payload.get("import_id")))
    sids = record.get("session_ids", [])
    if payload.get("dry_run"):
        return {"status": "dry-run", "session_ids": sids,
                "import_id": record["import_id"]}
    backup_path = _backup_db(target_db, backup_root, label)
    conn = rw_connect(target_db)
    try:
        conn.execute("BEGIN IMMEDIATE")
        for sid in sids:
            conn.execute("DELETE FROM session_v2 WHERE id = ?", (sid,))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    chk = ro_connect(target_db)
    try:
        left = 0
        for sid in sids:
            left += chk.execute(
                "SELECT COUNT(*) FROM session_v2 WHERE id = ?",
                (sid,)).fetchone()[0]
            for table in ("session_message", "session_part",
                          "instruction_state", "instruction_entry"):
                left += chk.execute(
                    "SELECT COUNT(*) FROM {0} WHERE session_id = ?".format(
                        table), (sid,)).fetchone()[0]
    finally:
        chk.close()
    record["reverted"] = True
    record["reverted_at"] = _iso_now()
    _write_manifest(manifest_path, manifest)
    return {"status": "ok" if left == 0 else "failed",
            "rows_left": left, "session_ids": sids,
            "backup": backup_path}
