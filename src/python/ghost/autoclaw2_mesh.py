"""Local, account-scoped all-to-all AutoClaw2 history convergence."""

from __future__ import annotations

from collections import Counter, defaultdict
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import uuid

from ghost import autoclaw2 as core
from ghost.autoclaw2_chat_lock import chat_writer
from ghost.autoclaw2_history import _digest
from ghost.autoclaw2_mesh_copy import extends, replay, shape


PROFILES = ("Primary", "c1", "c2", "c3", "c4", "c5")


@dataclass(frozen=True)
class Version:
    profile: str
    account: str
    db: str
    sid: str
    origin: tuple
    workspace_id: str
    workspace_root: str | None
    title: str
    archived: bool
    draft: bool
    snapshot: dict
    artifacts: int
    publishable: bool
    display_title: str | None = None
    normalized_title: str | None = None

    @property
    def key(self):
        return self.snapshot["key"]

    @property
    def location(self):
        return self.profile, self.account, self.sid


@dataclass(frozen=True)
class Action:
    kind: str
    source: Version | None = None
    local: Version | None = None

    def stamp(self):
        return (self.kind,
                (self.source.location, self.source.key) if self.source else None,
                (self.local.location, self.local.key) if self.local else None,
                (self.local.display_title, self.local.normalized_title) if self.kind == "normalize-title" else None)


def _busy_profiles():
    """Unknown Windows process ownership blocks writes, including without lockfiles."""
    busy = {name for name in PROFILES if core.probe_running(core.profile_path(name))}
    if os.name != "nt":
        return busy
    shell = Path(os.environ["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    probe = Path(__file__).resolve().parents[3] / "tools/inspect_autoclaw2_chat_runtime.ps1"
    try:
        out = subprocess.run([str(shell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                              "-File", str(probe)], check=True, capture_output=True, timeout=12,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        found = json.loads(out.stdout)
        if not isinstance(found, list) or any(name not in PROFILES for name in found):
            raise ValueError("unexpected runtime probe result")
        return busy | set(found)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise core.Refusal("runtime-state-unknown", "could not verify which AutoClaw2 profiles are open") from exc


def _reconcile_renames(profile_dir):
    """Only labels with the exact profile/account/session evidence are ours."""
    audit_path = Path(profile_dir) / ".autoclaw2-sync-audit.jsonl"
    renames = set()
    if not audit_path.is_file():
        return renames
    with audit_path.open(encoding="utf-8-sig", errors="replace") as handle:
        for line in handle:
            try:
                record = json.loads(line.lstrip("\ufeff"))
            except ValueError:
                continue  # old audit files can include an incomplete last line
            if (not isinstance(record, dict) or record.get("script") != "sync_autoclaw2_chats"
                    or record.get("status") != "reconciled" or not isinstance(record.get("account_dir"), str)
                    or not isinstance(record.get("actions"), list)):
                continue
            for action in record["actions"]:
                if (isinstance(action, dict) and action.get("kind") == "rename"
                        and isinstance(action.get("session_id"), str)):
                    renames.add((record["account_dir"], action["session_id"]))
    return renames


def _normalized_title(row, record, account, renames):
    title = row.get("title")
    sid = row["session_id"]
    if not isinstance(title, str) or record.get("reverted"):
        return None
    if (account, sid) in renames:
        prefix = "[import] "
        if title.startswith(prefix) and re.fullmatch(
                re.escape(title[len(prefix):].rsplit(" (", 1)[0]) + rf" \(\d+ entries(?:, {re.escape(sid[:8])})?\)",
                title[len(prefix):]):
            return prefix + title[len(prefix):].rsplit(" (", 1)[0]
    if not record:
        return None
    if record.get("target_account", account) != account:
        return None
    original = record.get("original_title")
    tag = record.get("title_tag") or ""
    if not isinstance(original, str) or not isinstance(tag, str) or not original:
        return None
    if tag != "[import] ":
        return None
    base = record.get("imported_title") or tag + original
    if not isinstance(base, str):
        return None
    if (account, sid) in renames:
        suffix = re.escape(sid[:8])
        if re.fullmatch(re.escape(base[:120]) + rf" \(\d+ entries(?:, {suffix})?\)", title):
            # Strip the exact label created by Reconcile, not user-entered titles.
            title = base
    untagged = original
    if tag == "[import] " and untagged.startswith(tag):
        untagged = untagged[len(tag):]
    source = record.get("source_profile")
    if (title == record.get("imported_title") and source in PROFILES
            and re.fullmatch(re.escape(tag + untagged) + rf" \(branch {re.escape(source)}, \d+ entries\)", title)):
        title = tag + untagged
    return title if title != row["title"] else None


def _version(profile, account, db, tree, origin, record, workspace_root, is_open, renames=()):
    row = tree["session"]
    signature = shape(tree)
    title = (record.get("original_title") or row["title"] or "Untitled")
    while title.startswith("[import] "):
        title = title[len("[import] "):]
    return Version(profile, account, db, row["session_id"], origin, row["workspace_id"], workspace_root, title,
                   row.get("archived_at") is not None, bool(row.get("draft")), signature,
                   len(tree["artifacts"]), signature["healthy"] and (not is_open or signature["settled"]),
                   row["title"], _normalized_title(row, record, account, renames))


def _scan_db(profile, db, is_open, lineage, records, renames):
    account = Path(db).parents[1].name
    rows, deleted, im = [], set(), 0
    with closing(core.ro_connect(db)) as conn:
        conn.execute("BEGIN")
        core._require_schema(conn, profile)
        ids = conn.execute(
            "SELECT s.session_id,s.deleted_at,s.external_provider,w.root_path FROM work_sessions s"
            " LEFT JOIN work_workspaces w ON w.workspace_id=s.workspace_id ORDER BY s.session_id").fetchall()
        for sid, gone, external, root in ids:
            if external:
                im += not bool(gone)
                continue
            origin = lineage.origin(profile, sid)
            if gone:
                deleted.add(origin)
                continue
            tree = core._session_tree(conn, sid)
            rows.append(_version(profile, account, db, tree, origin, records.get(sid, {}), root, is_open, renames))
    return rows, deleted, im


def catalog(busy):
    lineage = core.ChatLineage()
    by_origin = defaultdict(list)
    accounts, active_rows, tombstones, skipped = {}, {}, {}, []
    im = 0
    for profile in PROFILES:
        try:
            info = core.resolve_profile(profile, for_chat=True)
        except core.Refusal as exc:
            info = {"path": core.profile_path(profile), "account_status": exc.code, "db_path": None}
        accounts[profile] = info
        active = info.get("db_path")
        records = lineage.records(profile)
        renames = _reconcile_renames(info["path"])
        for db_path in sorted((Path(info["path"]) / "accounts").glob("*/runtime/runtime.sqlite")):
            db = str(db_path)
            is_active = active is not None and os.path.normcase(db) == os.path.normcase(active)
            try:
                # With a torn/missing account pointer, a provably open profile
                # may be writing any of its accounts. Treat all as live.
                rows, gone, bound = _scan_db(profile, db, profile in busy and (is_active or not active),
                                              lineage, records, renames)
            except (sqlite3.Error, core.Refusal) as exc:
                skipped.append({"profile": profile, "active": is_active,
                                "reason": getattr(exc, "code", "database-unreadable")})
                continue
            im += bound
            if is_active:
                active_rows[profile] = rows
                tombstones[profile] = gone
            for revision in rows:
                by_origin[revision.origin].append(revision)
    return accounts, active_rows, tombstones, by_origin, skipped, im


def _representatives(versions):
    """For equal histories prefer the copy with the most stored artifacts."""
    result = {}
    for ver in versions:
        if not ver.publishable:
            continue
        old = result.get(ver.key)
        if old is None or (ver.artifacts, ver.location) > (old.artifacts, old.location):
            result[ver.key] = ver
    return result


def _maximal(versions):
    return [ver for ver in versions if not any(extends(other.snapshot, ver.snapshot) for other in versions)]


def _choices(grouped):
    choices = {}
    for origin, group in grouped.items():
        copies = _representatives(group)
        visible_keys = {ver.key for ver in group if not ver.archived and ver.publishable}
        # An intentionally archived-only conversation must not reappear.
        visible = _maximal([copies[key] for key in sorted(visible_keys)])
        if not visible:
            continue
        winner = max(visible, key=lambda ver: (ver.snapshot["activity"], ver.key))
        forks = [ver for ver in _maximal(list(copies.values())) if ver.key != winner.key
                 and not extends(ver.snapshot, winner.snapshot)
                 and not extends(winner.snapshot, ver.snapshot)]
        choices[origin] = (winner, sorted(forks, key=lambda ver: ver.key))
    return choices


def _target_plan(local_rows, deleted, choices):
    by_origin = defaultdict(list)
    for ver in local_rows:
        by_origin[ver.origin].append(ver)
    actions, protected = [], 0
    for origin, (winner, forks) in sorted(choices.items()):
        local = by_origin.get(origin, [])
        live = [ver for ver in local if not ver.archived]
        # Preserve local archive/deletion choices and avoid hiding drafts.
        if (not live and (local or origin in deleted)) or any(ver.draft for ver in live):
            protected += 1
            continue
        matches = [ver for ver in local if ver.key == winner.key and ver.snapshot["healthy"]]
        keeper = next((ver for ver in matches if not ver.archived), None)
        choice_index = len(actions)
        if keeper is None:
            if matches:
                keeper = matches[0]
                actions.append(Action("unarchive", winner, keeper))
            else:
                prefix = [ver for ver in live if extends(winner.snapshot, ver.snapshot)]
                keeper = max(prefix, key=lambda ver: (tuple(map(len, ver.snapshot["history"])), ver.sid), default=None)
                actions.append(Action("append" if keeper else "create", winner, keeper))
        if keeper and keeper.normalized_title:
            actions.insert(choice_index, Action("normalize-title", local=keeper))
        actions.extend(Action("archive", local=ver) for ver in live if ver != keeper)
        seen = {ver.key for ver in local if ver.snapshot["healthy"]}
        actions.extend(Action("save-fork", ver) for ver in forks if ver.key not in seen)
    return actions, protected


def _ensure_closed(info):
    core._require_closed_chat_target(info)
    if info["profile"] in _busy_profiles():
        raise core.Refusal("target-running", "target opened during sync; no changes committed")


def _workspace(conn, root_path):
    roots = [{"root_path": root_path}] if root_path else []
    pairs, _ = core._map_target_workspaces(roots, core.read_workspaces(conn), "default")
    return pairs[0]["target_workspace"]["workspace_id"]


def _fresh_source(source, conn):
    tree = core._session_tree(conn, source.sid)
    snap = shape(tree)
    if tree["session"]["deleted_at"] or tree["session"].get("external_provider") or snap["key"] != source.key:
        raise core.Refusal("source-changed", "source version changed during the pass; will replan")
    if not snap["settled"]:
        current = core.resolve_profile(source.profile, for_chat=True)
        if (not current.get("db_path") or current["db_path"] == source.db) and source.profile in _busy_profiles():
            raise core.Refusal("source-in-progress", "source has a live turn; will replan")
    return tree


def _archive_state(conn, sid, expected):
    row = conn.execute("SELECT archived_at,deleted_at FROM work_sessions WHERE session_id=?", (sid,)).fetchone()
    if row != (expected, None):
        raise RuntimeError("chat archive state did not verify")


def _verify_local(conn, local):
    tree = core._session_tree(conn, local.sid)
    row = tree["session"]
    if (row["deleted_at"] or (row.get("archived_at") is not None) != local.archived
            or bool(row.get("draft")) != local.draft or shape(tree)["key"] != local.key):
        raise core.Refusal("target-changed", "target history changed during planning; will replan")


def _transfer(conn, info, action, owner, revisions, stamp):
    src = action.source
    sid = action.local.sid if action.local else str(uuid.uuid4())
    archive = stamp if action.kind == "save-fork" else None
    title = "[import] " + src.title
    if archive:
        title += f" (version {src.key[:8]})"
    workspace = action.local.workspace_id if action.local else _workspace(conn, src.workspace_root)
    with closing(core.ro_connect(src.db)) as source_conn:
        source_conn.execute("BEGIN")
        tree = _fresh_source(src, source_conn)
        skipped = replay(conn, source_conn, tree, sid, append=action.kind == "append", owner=owner,
                         workspace=workspace, title=title, archived_at=archive, revisions=revisions)
    _archive_state(conn, sid, archive)
    record = None if action.local else {
        "import_id": str(uuid.uuid4()), "source_profile": src.profile, "source_account": src.account,
        "target_profile": info["profile"], "target_account": Path(info["account_dir"]).name,
        "source_session_id": src.sid, "new_session_id": sid, "origin_profile": src.origin[0],
        "origin_session_id": src.origin[1], "original_title": src.title, "imported_title": title,
        "title_tag": "[import] ", "created_at": stamp, "mesh_revision": src.key,
    }
    return sid, archive, src.key, record, skipped


def _mesh_backup(info):
    db = Path(info["db_path"])
    if shutil.disk_usage(db.parent).free < max(1 << 30, 3 * db.stat().st_size):
        raise core.Refusal("disk-low", "not enough free space for a verified rollback backup")
    backup = Path(core._backup_db(str(db), info["path"], "chat-mesh-" + uuid.uuid4().hex[:8]))
    with closing(core.ro_connect(str(backup))) as conn:
        if conn.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise RuntimeError("mesh backup did not pass SQLite quick_check")
    sidecar = Path(core._sidecar_path(info["path"]))
    if sidecar.is_file():
        data = sidecar.read_bytes()
        copy = backup.with_name("provenance-before.json")
        copy.write_bytes(data)
        if copy.read_bytes() != data:
            raise RuntimeError("mesh provenance backup did not verify")
    return backup


def _log_verified_backup(backup, account):
    """Retain one verified mesh backup per account; leave all other backups alone."""
    marker = backup.with_name("mesh-verified.json")
    record = {"format": "ghost-autoclaw2-mesh-v1", "account": account}
    marker.write_text(json.dumps(record), encoding="utf-8")
    if json.loads(marker.read_text(encoding="utf-8")) != record:
        raise RuntimeError("mesh backup marker did not verify")
    removed, warnings = 0, 0
    for old in backup.parent.parent.glob("????????-??????-chat-mesh-????????"):
        old_marker = old / marker.name
        if old == backup.parent or old.is_symlink() or getattr(old, "is_junction", lambda: False)():
            continue
        if not old_marker.is_file() or old_marker.is_symlink():
            continue
        try:
            if json.loads(old_marker.read_text(encoding="utf-8")) != record:
                continue
            files = set(p.name for p in old.iterdir())
            if files - {"runtime.sqlite", "provenance-before.json", marker.name}:
                continue
            shutil.rmtree(old)
            if old.exists():
                raise RuntimeError("old mesh backup still exists")
            removed += 1
        except (OSError, ValueError, RuntimeError):
            warnings += 1
    return removed, warnings


def _verify_title(conn, sid, title):
    row = conn.execute("SELECT title FROM work_sessions WHERE session_id=?", (sid,)).fetchone()
    if row != (title,):
        raise RuntimeError("normalized chat title did not verify")


def _normalize_title(conn, version):
    row = conn.execute("SELECT title FROM work_sessions WHERE session_id=?", (version.sid,)).fetchone()
    if row != (version.display_title,):
        raise core.Refusal("target-changed", "chat title changed after planning; leaving it untouched")
    conn.execute("UPDATE work_sessions SET title=? WHERE session_id=?",
                 (version.normalized_title, version.sid))
    _verify_title(conn, version.sid, version.normalized_title)


def _apply(info, actions):
    _ensure_closed(info)
    backup = _mesh_backup(info)
    check, renamed, records, skipped = [], [], [], 0
    stamp = core._iso_now()
    with closing(core.rw_connect(info["db_path"])) as conn, conn:
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("PRAGMA defer_foreign_keys=ON")
        core._require_closed_chat_target(info)
        core._require_schema(conn, info["profile"])
        owner = core._owner_id(conn)
        revisions = set(conn.execute("SELECT tool_id,revision FROM governed_tool_revisions"))
        for action in actions:
            if action.local:
                _verify_local(conn, action.local)
            if action.kind == "normalize-title":
                _normalize_title(conn, action.local)
                renamed.append((action.local.sid, action.local.normalized_title))
                continue
            if action.kind in ("archive", "unarchive"):
                archived_at = stamp if action.kind == "archive" else None
                sid = action.local.sid
                conn.execute("UPDATE work_sessions SET archived_at=? WHERE session_id=?", (archived_at, sid))
                _archive_state(conn, sid, archived_at)
                check.append((sid, archived_at, action.local.key))
                continue
            sid, archived_at, key, record, omitted = _transfer(conn, info, action, owner, revisions, stamp)
            check.append((sid, archived_at, key))
            skipped += omitted
            if record:
                records.append(record)
        # Recheck process attribution immediately before the commit, including
        # an app launch that has not created its lockfile yet.
        _ensure_closed(info)
        if records:
            sidecar = core._read_sidecar(info["path"])
            sidecar["imports"].extend(records)
            # Write provenance BEFORE SQLite commits. A crash can leave an
            # unused record, never a committed copy without its lineage.
            core._write_sidecar(info["path"], sidecar)
            if core._read_sidecar(info["path"])["imports"][-len(records):] != records:
                raise RuntimeError("mesh provenance did not verify")
    with closing(core.ro_connect(info["db_path"])) as conn:
        conn.execute("BEGIN")
        for sid, archived, key in check:
            _archive_state(conn, sid, archived)
            if shape(core._session_tree(conn, sid))["key"] != key:
                raise RuntimeError("committed chat version did not verify")
        for sid, title in renamed:
            _verify_title(conn, sid, title)
    removed, warnings = _log_verified_backup(backup, Path(info["account_dir"]).name)
    return {"backup": str(backup), "artifacts_skipped": skipped, "old_mesh_backups_removed": removed,
            "retention_warnings": warnings}


def _run(payload, targets):
    busy = _busy_profiles()
    accounts, local, gone, grouped, skipped, im = catalog(busy)
    choices = _choices(grouped)
    plans, results = {}, {}
    for name in targets:
        info = accounts[name]
        is_open = name in busy
        if name not in local:
            reason = info["account_status"] if info["account_status"] != "ok" else "active-db-unreadable"
            results[name] = {"status": "skipped", "reason": reason, "open": is_open, "ready": False}
            continue
        actions, protected = _target_plan(local[name], gone[name], choices)
        plans[name] = actions
        results[name] = {"status": "queued" if is_open and actions else "planned" if actions else "up-to-date",
                         "account": Path(info["account_dir"]).name[:8], "actions": dict(Counter(a.kind for a in actions)),
                         "protected": protected, "open": is_open, "ready": not is_open and not actions}
        if is_open and actions:
            results[name]["reason"] = "target-running"
    # Preview pins only batches it can actually write. A queued profile's
    # live draft/turn may keep changing without affecting those batches.
    plan_id = _digest([[name, accounts[name].get("account_dir"), [a.stamp() for a in actions]]
                       for name, actions in plans.items() if name not in busy and actions])
    result = {"status": "preview", "plan_id": plan_id, "lineages": len(choices), "im_excluded": im,
              "unsettled_or_invalid_sources": sum(not v.publishable for group in grouped.values() for v in group),
              "unreadable_databases": skipped, "targets": results}
    if payload.get("apply") is not True:
        return result
    if payload.get("plan_id") and payload["plan_id"] != plan_id:
        raise core.Refusal("mesh-plan-changed", "accounts or revisions changed; preview again")
    result["status"] = "ok"
    if any(db["active"] for db in skipped) or any(
            info["account_status"] == "ok" and name not in local for name, info in accounts.items()):
        result["status"] = "queued"
        for name in plans:
            if name not in busy:
                results[name].update(status="queued", reason="active-source-unreadable", ready=False)
        return result
    for name, actions in plans.items():
        if not actions or name in busy:
            continue
        try:
            results[name].update(_apply(accounts[name], actions), status="applied", ready=True)
        except core.Refusal as exc:
            results[name].update(status="queued", reason=exc.code, ready=False)
            if exc.code == "target-running":
                results[name]["open"] = True
        except (sqlite3.Error, OSError, RuntimeError) as exc:
            results[name].update(status="failed", reason=type(exc).__name__)
            print(f"[autoclaw2-mesh] {name}: batch failed: {exc}", file=sys.stderr)
            result["status"] = "partial"
            result["ok"] = False
    return result


def sync(payload):
    targets = payload.get("targets", list(PROFILES))
    if not isinstance(targets, list) or not targets or any(name not in PROFILES for name in targets):
        raise core.Refusal("bad-targets", "targets must be a nonempty list of AutoClaw2 profiles")
    if payload.get("apply") is True:
        with chat_writer(core._home()):
            return _run(payload, list(dict.fromkeys(targets)))
    return _run(payload, list(dict.fromkeys(targets)))
