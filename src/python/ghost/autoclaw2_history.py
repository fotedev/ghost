"""Account-scoped, reversible cleanup for AutoClaw2 imported chat history."""

from collections import Counter, defaultdict
from contextlib import closing
import hashlib
import json
import os
import sqlite3

from ghost import autoclaw2 as core
from ghost.autoclaw2_chat_lock import chat_writer


_TERMINAL_RUNS = {
    "completed", "failed", "cancelled", "canceled", "interrupted", "succeeded", "stopped", "merged",
}


def _json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      default=lambda buf: {"bytes": buf.hex()})


def _digest(value):
    return hashlib.sha256(_json(value).encode("utf-8")).hexdigest()


def _run_ref(value, indexes):
    return indexes.get(value, value)


def _entry_ref(value, indexes):
    if not value:
        return value
    run, sep, suffix = value.partition(":")
    return (_run_ref(run, indexes), suffix) if sep else value


def _snapshot(conn, session_id):
    """Compare snapshots despite the importer's remapped run/event row IDs."""
    tree = core._session_tree(conn, session_id)
    ordered = sorted(tree["runs"].values(), key=lambda row: row["accept_order"])
    indexes = {row["run_id"]: index for index, row in enumerate(ordered)}
    runs = []
    stable_fields = {"run_id", "session_id", "accept_order", "credential_version"}
    for row in ordered:
        run = {key: value for key, value in row.items() if key not in stable_fields}
        for field in ("retried_from_run_id", "merged_into_run_id"):
            if field in run:
                run[field] = _run_ref(run[field], indexes)
        for field in ("request_entry_id", "answer_entry_id"):
            if field in run:
                run[field] = _entry_ref(run[field], indexes)
        runs.append(_digest(run))
    events = [_digest((_run_ref(ev["run_id"], indexes), ev["run_seq"],
                       ev["type"], ev["payload_json"], ev["created_at"])) for ev in tree["events"]]
    artifacts = Counter()
    for artifact in tree["artifacts"]:
        artifact_key = {k: v for k, v in artifact.items()
                        if k not in ("artifact_id", "session_id", "run_id")}
        custody = []
        for row in conn.execute("SELECT * FROM governed_tool_artifact_custody WHERE artifact_id = ?",
                                (artifact["artifact_id"],)):
            item = {k: row[k] for k in row.keys() if k not in ("artifact_id", "custody_id")}
            if "run_id" in item:
                item["run_id"] = _run_ref(item["run_id"], indexes)
            if item.get("session_id") == session_id:
                item["session_id"] = "(self)"
            custody.append(_digest(item))
        run_id = _run_ref(artifact.get("run_id"), indexes)
        artifacts[_digest((artifact_key, run_id, sorted(custody)))] += 1
    entries = [_digest((entry["session_seq"], entry["entry_type"], entry["payload"],
                        _run_ref(entry["run_id"], indexes),
                        _entry_ref(entry["parent_entry_id"], indexes), entry["committed_at"]))
               for entry in tree["entries"]]
    entry_ids = {row["entry_id"] for row in tree["entries"]}
    head = tree["head"] or {}
    links = [run.get(key) for run in ordered for key in ("request_entry_id", "answer_entry_id")]
    links += [head.get(key) for key in ("conversation_head_entry_id", "settled_answer_entry_id")]
    return {
        "entries": entries, "runs": runs, "events": events, "artifacts": artifacts,
        "terminal": all(row["status"] in _TERMINAL_RUNS for row in ordered),
        "healthy": all(link is None or link in entry_ids for link in links),
    }


def _covers(keeper, candidate):
    if keeper["workspace_id"] != candidate["workspace_id"]:
        return False
    kept, old = keeper["snapshot"], candidate["snapshot"]
    return (kept["healthy"] and kept["terminal"] and old["terminal"]
            and all(kept[key][:len(old[key])] == old[key] for key in ("entries", "runs", "events"))
            and all(kept["artifacts"][key] >= count for key, count in old["artifacts"].items()))


def _tool_title(record, title):
    if record is None or record.get("reverted"):
        return False
    expected = record.get("imported_title")
    if expected is None:
        expected = (record.get("title_tag") or "") + (record.get("original_title") or "")
    return title == expected


def _group_changes(conn, group, used_titles):
    for session in group:
        session["snapshot"] = _snapshot(conn, session["session_id"])
    group.sort(key=lambda row: (
        len(row["snapshot"]["entries"]), len(row["snapshot"]["runs"]),
        len(row["snapshot"]["events"]), sum(row["snapshot"]["artifacts"].values()),
        not row["editable"], row["session_id"]), reverse=True)

    actions, keep = [], []
    for session in group:
        keeper = next((other for other in keep if _covers(other, session)), None) if session["editable"] else None
        if keeper is None:
            keep.append(session)
            continue
        actions.append({"kind": "archive", "session_id": session["session_id"],
                        "title": session["title"], "covered_by": keeper["session_id"]})

    titles = Counter(row["title"] for row in keep)
    for session in keep:
        title = session["title"]
        if not session["editable"] or titles[title] < 2:
            continue
        sid = session["session_id"]
        total = len(session["snapshot"]["entries"])
        new_title = "{0} ({1} entries)".format(title[:120], total)
        if new_title in used_titles:
            new_title = "{0} ({1} entries, {2})".format(title[:120], total, sid[:8])
        if new_title in used_titles:
            continue
        used_titles.add(new_title)
        actions.append({"kind": "rename", "session_id": sid, "title": title, "new_title": new_title})
    return actions


def _plan(conn, info):
    target = info["profile"]
    account = os.path.basename(info["account_dir"])
    core._require_schema(conn, target)
    lineage = core.ChatLineage()
    records = lineage.records(target)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT session_id, title, workspace_id FROM work_sessions"
        " WHERE archived_at IS NULL AND deleted_at IS NULL AND COALESCE(external_provider, '') = ''"
        " ORDER BY session_id").fetchall()
    by_origin = defaultdict(list)
    for raw in rows:
        row = dict(raw)
        sid = row["session_id"]
        row["editable"] = _tool_title(records.get(sid), row["title"])
        by_origin[lineage.origin(target, sid)].append(row)
    used_titles = {row["title"] for row in rows}
    actions, snapshots = [], []
    for group in by_origin.values():
        if len(group) < 2:
            continue
        changes = _group_changes(conn, group, used_titles)
        actions.extend(changes)
        if changes:
            snapshots.extend((row["session_id"], _digest(row["snapshot"])) for row in group)
    conn.row_factory = None
    return {"target": target, "account_dir": account, "actions": actions,
            "plan_id": _digest([target, account, actions, sorted(snapshots)])}


def _verify(conn, actions, stamp):
    for action in actions:
        expected = (action.get("new_title", action["title"]),
                    stamp if action["kind"] == "archive" else None, None)
        actual = conn.execute("SELECT title, archived_at, deleted_at FROM work_sessions WHERE session_id = ?",
                              (action["session_id"],)).fetchone()
        if actual != expected:
            raise RuntimeError("chat metadata verification failed for " + action["session_id"])


def reconcile(payload):
    """Preview first; apply only that exact plan to a closed, active account."""
    if payload.get("apply") is True:
        with chat_writer(core._home()):
            return _reconcile(payload)
    return _reconcile(payload)


def _reconcile(payload):
    info = core.resolve_profile(payload["target"], require_account=True, for_chat=True)
    db_path = info["db_path"]
    applying = payload.get("apply") is True
    if applying:
        core._require_closed_chat_target(info)
    with closing(core.ro_connect(db_path)) as conn:
        conn.execute("BEGIN")
        plan = _plan(conn, info)
    if not applying:
        return {"status": "dry-run", **plan}
    if payload.get("plan_id") != plan["plan_id"]:
        raise core.Refusal("chat-plan-changed", "preview this target again before applying")
    actions = plan["actions"]
    if not actions:
        return {"status": "noop", **plan}

    core._require_closed_chat_target(info)
    backup = core._backup_db(db_path, info["path"], "chat-reconcile")
    with closing(core.ro_connect(backup)) as conn:
        if conn.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise RuntimeError("chat reconciliation backup did not verify")
    stamp = core._iso_now()
    with closing(core.rw_connect(db_path)) as conn, conn:
        conn.execute("BEGIN IMMEDIATE")
        core._require_closed_chat_target(info)
        if _plan(conn, info)["plan_id"] != plan["plan_id"]:
            raise core.Refusal("chat-plan-changed", "chat data changed after preview; nothing was applied")
        for action in actions:
            sid = action["session_id"]
            if action["kind"] == "archive":
                conn.execute("UPDATE work_sessions SET archived_at = ? WHERE session_id = ?", (stamp, sid))
            else:
                conn.execute("UPDATE work_sessions SET title = ? WHERE session_id = ?", (action["new_title"], sid))
        _verify(conn, actions, stamp)
    with closing(core.ro_connect(db_path)) as conn:
        _verify(conn, actions, stamp)
    return {"status": "ok", "backup": backup, **plan}
