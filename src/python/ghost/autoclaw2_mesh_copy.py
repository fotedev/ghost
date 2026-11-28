"""Append-only replay for AutoClaw2 mesh sync. Never starts or resumes a run."""

from collections import Counter
import json
import uuid

from ghost import autoclaw2 as core
from ghost.autoclaw2_history import _TERMINAL_RUNS, _digest


def _ordered_runs(tree):
    return sorted(tree["runs"].values(), key=lambda row: row["accept_order"])


def _historical_run(row):
    out = dict(row)
    if out["status"] not in _TERMINAL_RUNS:
        # Only offline snapshots are allowed through for nonterminal runs.
        # Preserve their history, but never seed the target's work queue.
        out["status"] = "interrupted"
    if "continuation_pending" in out:
        out["continuation_pending"] = 0
    return out


def shape(tree):
    """Compare whole history independently of local row IDs and credentials."""
    ordered = _ordered_runs(tree)
    indexes = {row["run_id"]: i for i, row in enumerate(ordered)}
    sequences = {row["entry_id"]: row["session_seq"] for row in tree["entries"]}
    ignored = {"run_id", "session_id", "accept_order", "credential_version"}
    runs = []
    for run in ordered:
        row = {key: val for key, val in _historical_run(run).items() if key not in ignored}
        for field in ("merged_into_run_id", "retried_from_run_id"):
            if field in row:
                row[field] = indexes.get(row[field])
        for field in ("request_entry_id", "answer_entry_id"):
            if field in row:
                row[field] = sequences.get(row[field])
        runs.append(_digest(row))
    events = [_digest((indexes.get(row["run_id"]), row["run_seq"], row["type"],
                       row["payload_json"], row["created_at"])) for row in tree["events"]]
    entries = [_digest((row["session_seq"], row["entry_type"], row["payload"],
                        indexes.get(row["run_id"]), sequences.get(row["parent_entry_id"]),
                        row["committed_at"]))
               for row in tree["entries"]]
    entry_ids = {row["entry_id"] for row in tree["entries"]}
    head = tree["head"] or {}
    links = [row.get(key) for row in ordered for key in ("request_entry_id", "answer_entry_id")]
    links += [head.get(key) for key in ("conversation_head_entry_id", "settled_answer_entry_id")]
    links += [row["parent_entry_id"] for row in tree["entries"]]
    healthy = (all(link is None or link in entry_ids for link in links)
               and all(row["run_id"] in indexes for row in tree["entries"] + tree["events"])
               and all(head.get(key) is None or head[key] in indexes
                       for key in ("conversation_run_id", "settled_run_id")))
    activity = [tree["session"].get("updated_at")]
    activity += [row.get("updated_at") for row in ordered]
    activity += [row["committed_at"] for row in tree["entries"]]
    activity += [row["created_at"] for row in tree["events"]]
    history = (entries, runs, events)
    return {"key": _digest(history), "history": history, "healthy": healthy,
            "settled": all(r["status"] in _TERMINAL_RUNS and not r.get("continuation_pending")
                           for r in ordered),
            "activity": max((stamp for stamp in activity if isinstance(stamp, str)), default="")}


def extends(newer, older):
    """A strict extension includes the same ordered entries, runs and events."""
    return (newer["key"] != older["key"] and newer["healthy"] and older["healthy"]
            and all(new[:len(old)] == old for new, old in zip(newer["history"], older["history"])))


def _identifier(value):
    return '"' + value.replace('"', '""') + '"'


def _insert(conn, table, row):
    columns = ','.join(_identifier(key) for key in row)
    binds = ','.join('?' for _ in row)
    conn.execute(f"INSERT INTO {_identifier(table)} ({columns}) VALUES ({binds})", tuple(row.values()))


def _save_head(conn, tree, target_id, run_map, entry_map):
    if not tree["head"]:
        return
    head = dict(tree["head"])
    head["session_id"] = target_id
    for key in ("conversation_head_entry_id", "settled_answer_entry_id"):
        head[key] = entry_map.get(head[key])
    for key in ("conversation_run_id", "settled_run_id"):
        head[key] = run_map.get(head[key])
    head["next_session_seq"] = max([row["session_seq"] for row in tree["entries"]] or [0]) + 1
    head["entry_count"] = len(tree["entries"])
    if conn.execute("SELECT 1 FROM neutral_session_heads WHERE session_id=?", (target_id,)).fetchone():
        del head["session_id"]
        fields = ','.join(f'{_identifier(key)}=?' for key in head)
        conn.execute(f"UPDATE neutral_session_heads SET {fields} WHERE session_id=?", (*head.values(), target_id))
    else:
        _insert(conn, "neutral_session_heads", head)


def _artifact_key(artifact, run_id):
    data = {key: value for key, value in artifact.items() if key not in ("artifact_id", "run_id", "session_id")}
    return _digest((run_id, data))


def _copy_artifacts(conn, source_conn, tree, old, run_map, session_id, owner, workspace, revisions):
    present = Counter(_artifact_key(row, row["run_id"]) for row in old["artifacts"])
    skipped = 0
    for artifact in tree["artifacts"]:
        local_run = run_map.get(artifact["run_id"])
        key = _artifact_key(artifact, local_run)
        if present[key]:
            present[key] -= 1
            continue
        if ((artifact["tool_id"], artifact["tool_revision"]) not in revisions
                or (artifact["run_id"] and not local_run)):
            skipped += 1
            continue
        local_id = str(uuid.uuid4())
        _insert(conn, "governed_tool_artifacts", {
            **artifact, "artifact_id": local_id, "session_id": session_id, "run_id": local_run,
        })
        custody = source_conn.execute("SELECT * FROM governed_tool_artifact_custody WHERE artifact_id=?",
                                      (artifact["artifact_id"],))
        columns = [desc[0] for desc in custody.description]
        for raw in custody.fetchall():
            row = dict(zip(columns, raw))
            replacements = {"artifact_id": local_id, "owner_id": owner, "workspace_id": workspace,
                            "session_id": session_id, "run_id": local_run, "custody_id": str(uuid.uuid4())}
            for field, value in replacements.items():
                if field in row:
                    row[field] = value
            _insert(conn, "governed_tool_artifact_custody", row)
    return skipped


def _copy_entries(conn, rows, session_id, run_map, entry_map):
    for entry in rows:
        local_id = entry_map[entry["entry_id"]]
        _insert(conn, "neutral_session_entries", {
            **entry, "session_id": session_id, "entry_id": local_id,
            "parent_entry_id": entry_map.get(entry["parent_entry_id"]), "run_id": run_map[entry["run_id"]],
        })
        if entry["entry_type"] in core.FTS_ENTRY_TYPES:
            value = json.loads(entry["payload"])
            data = value.get("data") if isinstance(value, dict) else None
            body = str(data.get("text") or "") if isinstance(data, dict) else ""
            conn.execute("INSERT INTO neutral_session_fts (session_id,entry_id,body) VALUES (?,?,?)",
                         (session_id, local_id, body))


def _allocate_entries(tree, old, run_map):
    entry_map = {row["entry_id"]: copy["entry_id"]
                 for row, copy in zip(tree["entries"], old["entries"])}
    for row in tree["entries"][len(old["entries"]):]:
        _, sep, suffix = row["entry_id"].partition(":")
        if not sep:
            suffix = "e{}".format(row["session_seq"])
        entry_map[row["entry_id"]] = f'{run_map[row["run_id"]]}:{suffix}'
    return entry_map


def replay(conn, source_conn, tree, session_id, *, append, owner, workspace, title, archived_at, revisions):
    """Materialize or extend one branch inside the caller's batch transaction."""
    wanted = shape(tree)
    if not wanted["healthy"]:
        raise core.Refusal("invalid-chat-links", "source history has unresolved run or entry links")
    old = core._session_tree(conn, session_id) if append else {"runs": {}, "events": [], "entries": [], "artifacts": []}
    if append and not extends(wanted, shape(old)):
        raise core.Refusal("not-fast-forward", "target history changed; refusing a non-append merge")

    if not append:
        row = dict(tree["session"])
        row.update(session_id=session_id, owner_id=owner, workspace_id=workspace,
                   title=title, archived_at=archived_at, deleted_at=None)
        for key in row:
            if key.startswith("external_") or key in ("draft_revision", "draft_annotations_json"):
                row[key] = None
        if "draft" in row:
            row["draft"] = ""
        _insert(conn, "work_sessions", row)
    else:
        conn.execute("UPDATE work_sessions SET updated_at=? WHERE session_id=?",
                     (tree["session"]["updated_at"], session_id))

    ordered = _ordered_runs(tree)
    prefix = _ordered_runs(old)
    run_map = {row["run_id"]: other["run_id"] for row, other in zip(ordered, prefix)}
    fresh = ordered[len(prefix):]
    run_map.update((row["run_id"], str(uuid.uuid4())) for row in fresh)
    entry_map = _allocate_entries(tree, old, run_map)
    (tail,) = conn.execute("SELECT COALESCE(MAX(accept_order),0) FROM work_runs").fetchone()
    for offset, source in enumerate(fresh, 1):
        row = _historical_run(source)
        row.update(run_id=run_map[source["run_id"]], session_id=session_id,
                   accept_order=tail + offset, credential_version=None)
        for key in ("merged_into_run_id", "retried_from_run_id"):
            if key in row:
                row[key] = run_map.get(row[key])
        for key in ("request_entry_id", "answer_entry_id"):
            if key in row:
                row[key] = entry_map.get(row[key])
        _insert(conn, "work_runs", row)
    for source in tree["events"][len(old["events"]):]:
        row = {key: val for key, val in source.items() if key not in tree["events_pk"]}
        row.update(event_id=str(uuid.uuid4()), session_id=session_id, run_id=run_map[source["run_id"]])
        _insert(conn, "work_events", row)
    _copy_entries(conn, tree["entries"][len(old["entries"]):], session_id, run_map, entry_map)
    _save_head(conn, tree, session_id, run_map, entry_map)
    skipped = _copy_artifacts(conn, source_conn, tree, old, run_map, session_id, owner, workspace, revisions)
    actual = shape(core._session_tree(conn, session_id))
    if not actual["healthy"] or actual["key"] != wanted["key"]:
        raise RuntimeError("replayed chat does not match the source revision")
    return skipped
