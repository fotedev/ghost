"""SQLite identity operations — ports of the four embedded Python bridges
that used to live as here-strings inside PowerShell scripts:

1. sqlite_update        <- identity_utils.ps1 Set-SqliteKeys temp .py
2. delete_secrets       <- reset_zcode.ps1 Clear-SecretsFromSqlite temp .py
3. clear_cli_telemetry  <- reset_zcode.ps1 [26/27] temp .py
4. chat_check           <- tools/refresh_zcode_second_chats.ps1 temp .py

Rules (repo conventions):
- Parameterized `?` placeholders for every value; only whitelisted table
  names (regex ^[A-Za-z_][A-Za-z0-9_]*$) are ever interpolated.
- Every mutation is followed by a read-only re-open verification
  (file:...?mode=ro URI) -- "file existed" is never "value changed".
- Output shapes are consumed by PowerShell callers; keep them identical.
"""

import json
import re
import sqlite3
import time

_TABLE_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

SECRETS_LIKE_PATTERNS = ("secret://aicoding.auth.%", "secret://blackbox.%")
SECRETS_TARGET_KEYS = ("gituser",)

CLI_TELEMETRY_PATTERNS = ("%telemetry%", "%machineId%", "%deviceId%")


def _validate_table_name(table):
    if not _TABLE_NAME_RE.match(table or ""):
        raise ValueError("Unsafe SQLite table name: {0!r}".format(table))


def _ro_connect(path):
    """Read-only re-open for verify-after writes. Backslashes are normalized
    for the URI form (same technique as the chat-sync bridge)."""
    uri = "file:" + path.replace("\\", "/") + "?mode=ro"
    return sqlite3.connect(uri, uri=True, timeout=10)


def sqlite_update(db_path, updates, table="ItemTable"):
    """UPSERT key/value rows + verify-after re-read.

    Returns {"before": {key: old|None}, "after": {key: new|None}}. Raises on
    any sqlite error (caller contract: non-zero exit -> PowerShell FAILED).
    """
    _validate_table_name(table)

    conn = sqlite3.connect(db_path, timeout=10)
    try:
        cursor = conn.cursor()
        # CREATE before the before-read (deliberate improvement over the
        # old embedded bridge, which crashed on a table that did not exist
        # yet; for existing tables the contract is identical).
        cursor.execute(
            "CREATE TABLE IF NOT EXISTS " + table +
            " (key TEXT PRIMARY KEY, value TEXT)")
        before = {}
        for key in updates.keys():
            cursor.execute(
                "SELECT value FROM " + table + " WHERE key = ?", (key,))
            row = cursor.fetchone()
            before[key] = None if row is None else row[0]
        for key, value in updates.items():
            cursor.execute(
                "INSERT OR REPLACE INTO " + table +
                " (key, value) VALUES (?, ?)", (key, value))
        conn.commit()
    finally:
        conn.close()

    verify_conn = _ro_connect(db_path)
    try:
        verify_cursor = verify_conn.cursor()
        after = {}
        for key in updates.keys():
            verify_cursor.execute(
                "SELECT value FROM " + table + " WHERE key = ?", (key,))
            row = verify_cursor.fetchone()
            after[key] = None if row is None else row[0]
    finally:
        verify_conn.close()

    return {"before": before, "after": after}


def delete_secrets(db_path):
    """DELETE auth-secret keys from ItemTable and verify zero survivors via
    read-only reopen. Returns {"deleted": [...], "survivors": [...]} where
    survivors is the per-pattern/per-key COUNT(*) list (all zeros on
    success)."""
    patterns = SECRETS_LIKE_PATTERNS
    target_keys = SECRETS_TARGET_KEYS
    deleted = []

    conn = sqlite3.connect(db_path, timeout=10)
    try:
        cursor = conn.cursor()
        for pattern in patterns:
            cursor.execute(
                "SELECT key FROM ItemTable WHERE key LIKE ?", (pattern,))
            for row in cursor.fetchall():
                key = row[0]
                cursor.execute(
                    "DELETE FROM ItemTable WHERE key = ?", (key,))
                deleted.append(key)
        for key in target_keys:
            cursor.execute("DELETE FROM ItemTable WHERE key = ?", (key,))
            deleted.append(key)
        conn.commit()
    finally:
        conn.close()

    verify_conn = _ro_connect(db_path)
    try:
        verify_cursor = verify_conn.cursor()
        survivors = []
        for pattern in patterns:
            verify_cursor.execute(
                "SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?",
                (pattern,))
            survivors.append(verify_cursor.fetchone()[0])
        for key in target_keys:
            verify_cursor.execute(
                "SELECT COUNT(*) FROM ItemTable WHERE key = ?", (key,))
            survivors.append(verify_cursor.fetchone()[0])
    finally:
        verify_conn.close()

    return {"deleted": deleted, "survivors": survivors}


def clear_cli_telemetry(db_path):
    """DELETE telemetry-like keys from the ZCode CLI db.sqlite ItemTable.

    Contract carried over verbatim from the reset_zcode.ps1 bridge: a
    connection failure is NOT an error exit -- it prints
    {"deleted": 0, "error": "..."} and exits 0 so the caller keeps its own
    audit wording. A missing ItemTable table is tolerated per-pattern
    (OperationalError -> continue). Returns {"deleted": N} or
    {"deleted": 0, "error": str}."""
    deleted = 0
    patterns = CLI_TELEMETRY_PATTERNS

    try:
        conn = sqlite3.connect(db_path, timeout=10)
    except sqlite3.Error as exc:
        return {"deleted": 0, "error": str(exc)}

    try:
        cursor = conn.cursor()
        for pattern in patterns:
            try:
                cursor.execute(
                    "SELECT key FROM ItemTable WHERE key LIKE ?", (pattern,))
            except sqlite3.OperationalError:
                continue
            for row in cursor.fetchall():
                cursor.execute(
                    "DELETE FROM ItemTable WHERE key = ?", (row[0],))
                deleted += 1
        conn.commit()
    finally:
        conn.close()

    return {"deleted": deleted}


def chat_check(mode, shared_db, tasks_index=None):
    """Cross-instance chat visibility probe — port of zcode_chat_sync_check.

    mode "missing": sessions present in the shared store but absent from the
      target instance's tasks-index. Emits lines:
        COUNT:<n>
        MISSING:<session_id>|<title up to 80 chars, pipes stripped>
    mode "hot": multi-signal in-flight-turn detection. Emits lines:
        AGE_MS:<n>                (ms since newest commit across session/
                                  message/part)
        INFLIGHT_MSG_AGE_MS:<n>   (-1 = none; youngest uncompleted assistant
                                  step created within the last 125s)
        INFLIGHT_TOOL_AGE_MS:<n>  (-1 = none; youngest running tool started
                                  within the last 305s)
        INFLIGHT_TOOL_NAME:<name> (pipes stripped, 40 chars)
    Unknown mode raises SystemExit(2) after printing UNKNOWN-MODE (kept for
    CLI parity; callers match the literal exit contract).
    Returns the list of output lines (without trailing newlines)."""
    if mode == "missing":
        db = _ro_connect(shared_db)
        try:
            rows = db.execute(
                "SELECT id, title, time_updated FROM session "
                "WHERE time_archived IS NULL "
                "AND task_type IN ('interactive','fork','workflow_parent')"
            ).fetchall()
        finally:
            db.close()
        tdb = _ro_connect(tasks_index)
        try:
            have = set(r[0] for r in tdb.execute("SELECT task_id FROM tasks"))
        finally:
            tdb.close()
        miss = sorted(
            (r for r in rows if r[0] not in have),
            key=lambda r: r[2] or 0,
            reverse=True,
        )
        lines = ["COUNT:%d" % len(miss)]
        for r in miss:
            lines.append("MISSING:%s|%s" % (
                r[0], (r[1] or "").replace("|", " ")[:80]))
        return lines

    if mode == "hot":
        db = _ro_connect(shared_db)
        try:
            now_ms = int(time.time() * 1000)
            # A: global commit activity (commits happen at step/tool
            # boundaries)
            mx = 0
            for t in ("session", "message", "part"):
                v = db.execute(
                    "SELECT COALESCE(MAX(time_updated),0) FROM %s" % t
                ).fetchone()[0]
                if v and v > mx:
                    mx = v
            age_line = "AGE_MS:%d" % (now_ms - mx)

            # B: youngest in-flight assistant step. The row is CREATED when
            # a step starts and data.time.completed is filled when it ends,
            # so an uncompleted recent row == a turn is streaming right now
            # (covers long "Thought" phases that produce no commits).
            # Killed turns orphan such rows, hence the hard 125s window.
            msg_age = -1
            rows = db.execute(
                "SELECT time_created, data FROM message WHERE time_created > ?"
                " ORDER BY time_created DESC LIMIT 40",
                (now_ms - 125000,)).fetchall()
            for created, data in rows:
                try:
                    d = json.loads(data)
                except Exception:
                    continue
                if d.get("role") != "assistant":
                    continue
                if not (d.get("time") or {}).get("completed"):
                    a = now_ms - (created or 0)
                    if msg_age < 0 or a < msg_age:
                        msg_age = a
            msg_line = "INFLIGHT_MSG_AGE_MS:%d" % msg_age

            # C: youngest running tool (row committed at tool START; covers
            # long tool executions with no other db writes). Orphans expire
            # after 305s.
            tool_age = -1
            tool_name = ""
            rows = db.execute(
                "SELECT tool_name, started_at FROM tool_usage "
                "WHERE (completed_at IS NULL OR completed_at = 0) "
                "AND started_at > ? "
                "ORDER BY started_at DESC LIMIT 5",
                (now_ms - 305000,)).fetchall()
            for name, started in rows:
                a = now_ms - (started or 0)
                if tool_age < 0 or a < tool_age:
                    tool_age = a
                    tool_name = name or ""
            tool_line = "INFLIGHT_TOOL_AGE_MS:%d" % tool_age
            name_line = "INFLIGHT_TOOL_NAME:%s" % (
                tool_name.replace("|", " ")[:40])
            return [age_line, msg_line, tool_line, name_line]
        finally:
            db.close()

    # Unknown mode: mirror the original bridge's stdout + exit contract.
    print("UNKNOWN-MODE")
    raise SystemExit(2)
