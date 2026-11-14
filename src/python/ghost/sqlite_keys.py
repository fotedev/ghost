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

# Identity-row scrub defaults (the Trae ai-agent contract; reset_trae.ps1
# v0.2's temp-.py heredoc). Tightened matching: single-token adjacency only.
# "_" is ESCAPE'd to its literal self, so spaced human text ("how to auth
# token refresh") can never match; a no-separator variant keeps camelCase
# identity keys (deviceId) covered. Matching stays on key NAMES only --
# values (chat content) are never inspected.
IDENTITY_ROW_PATTERNS = (
    "%device\\_id%", "%deviceid%",
    "%machine\\_id%", "%machineid%",
    "%auth\\_token%", "%authtoken%",
    "%telemetry%",
)
# Prefer a column literally named "key" over name/id when several key-like
# columns exist (identity keys may live in "key" while "id" holds row
# numbers or human labels).
IDENTITY_ROW_KEY_PRIORITY = ("key", "itemkey", "k", "id", "name")


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


def delete_secrets(db_path, exact_keys=None, like_patterns=None, escape=None):
    """DELETE auth-secret keys from ItemTable and verify zero survivors via
    read-only reopen. Returns {"deleted": [...], "survivors": [...]} where
    survivors is the per-pattern/per-key COUNT(*) list (all zeros on
    success).

    exact_keys / like_patterns default to the module's Cursor constants.
    escape: an ESCAPE character for the LIKE patterns (e.g. "\\") — needed
    when a pattern contains a literal underscore, which LIKE treats as a
    single-character wildcard (the Windsurf/Devin auth patterns use
    "windsurf\\_auth-%" etc. and pass escape="\\").
    """
    if like_patterns is None:
        like_patterns = SECRETS_LIKE_PATTERNS
    if exact_keys is None:
        exact_keys = SECRETS_TARGET_KEYS
    escape_clause = " ESCAPE '\\'" if escape else ""
    deleted = []

    conn = sqlite3.connect(db_path, timeout=10)
    try:
        cursor = conn.cursor()
        for pattern in like_patterns:
            cursor.execute(
                "SELECT key FROM ItemTable WHERE key LIKE ?" + escape_clause,
                (pattern,))
            for row in cursor.fetchall():
                key = row[0]
                cursor.execute(
                    "DELETE FROM ItemTable WHERE key = ?", (key,))
                deleted.append(key)
        for key in exact_keys:
            cursor.execute("DELETE FROM ItemTable WHERE key = ?", (key,))
            deleted.append(key)
        conn.commit()
    finally:
        conn.close()

    verify_conn = _ro_connect(db_path)
    try:
        verify_cursor = verify_conn.cursor()
        survivors = []
        for pattern in like_patterns:
            verify_cursor.execute(
                "SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?" + escape_clause,
                (pattern,))
            survivors.append(verify_cursor.fetchone()[0])
        for key in exact_keys:
            verify_cursor.execute(
                "SELECT COUNT(*) FROM ItemTable WHERE key = ?", (key,))
            survivors.append(verify_cursor.fetchone()[0])
    finally:
        verify_conn.close()

    return {"deleted": deleted, "survivors": survivors}


def _pick_key_column(cursor, table, key_priority):
    """Choose the key-like column of `table` for identity-row scrubbing.

    Prefer a column named per key_priority over other key-like columns;
    untyped columns (declared type "") are scanned too: the common SQLite KV
    shape CREATE TABLE kv(key, value) declares no column types, and identity
    rows in such tables previously survived the scrub. Returns None when no
    key-like column exists.
    """
    cursor.execute("PRAGMA table_info(" + table + ")")
    cols = cursor.fetchall()
    text_cols = [c[1] for c in cols
                 if (c[2].upper() == "TEXT" or c[2] == "")
                 and c[1].replace("_", "").isalnum()]
    key_cols = [c for c in text_cols if c.lower() in key_priority]
    if len(key_cols) == 0 or len(text_cols) < 1:
        return None
    key_cols.sort(key=lambda c: key_priority.index(c.lower())
                  if c.lower() in key_priority else len(key_priority))
    return key_cols[0]


def scrub_identity_rows(db_path, like_patterns=None, key_priority=None,
                        escape="\\"):
    """DELETE identity key-rows from EVERY scrub-able table in a database
    and verify zero survivors via read-only reopen.

    Port of the reset_trae.ps1 ModularData\\ai-agent scrub (v0.2's temp-.py
    heredoc): in every table with a key-like TEXT/untyped column, delete
    rows whose KEY NAME matches the identity patterns -- matching stays on
    key NAMES only, values (chat content) are never inspected or modified.
    Tables whose names fail the module's whitelist regex, or without a
    key-like column, are skipped and reported in skipped_tables (never
    silently ignored).

    like_patterns default to IDENTITY_ROW_PATTERNS, key_priority to
    IDENTITY_ROW_KEY_PRIORITY; escape defaults to "\\" for the escaped
    underscores. Returns {"deleted": N, "survivors": S, "skipped_tables":
    [...]}. Raises on any sqlite error (caller contract: non-zero exit ->
    PowerShell FAILED).
    """
    if like_patterns is None:
        like_patterns = IDENTITY_ROW_PATTERNS
    if key_priority is None:
        key_priority = IDENTITY_ROW_KEY_PRIORITY
    escape_clause = " ESCAPE '\\'" if escape else ""

    conn = sqlite3.connect(db_path, timeout=10)
    deleted = 0
    skipped_tables = []
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [row[0] for row in cursor.fetchall()]
        for table in tables:
            if not _TABLE_NAME_RE.match(table):
                skipped_tables.append(table)
                continue
            key_col = _pick_key_column(cursor, table, key_priority)
            if key_col is None:
                skipped_tables.append(table)
                continue
            for pattern in like_patterns:
                cursor.execute(
                    "SELECT COUNT(*) FROM " + table + " WHERE " + key_col
                    + " LIKE ?" + escape_clause, (pattern,))
                n = cursor.fetchone()[0]
                if n > 0:
                    cursor.execute(
                        "DELETE FROM " + table + " WHERE " + key_col
                        + " LIKE ?" + escape_clause, (pattern,))
                    deleted += n
        conn.commit()
    finally:
        conn.close()

    # Verify-after (module invariant): read-only reopen and recount every
    # matching row post-commit. Any survivor fails the step (never-silent-
    # success); an incomplete and a verified-clean scrub are no longer
    # indistinguishable.
    verify_conn = _ro_connect(db_path)
    survivors = 0
    try:
        verify_cursor = verify_conn.cursor()
        verify_cursor.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")
        verify_tables = [row[0] for row in verify_cursor.fetchall()]
        for table in verify_tables:
            if not _TABLE_NAME_RE.match(table):
                continue
            key_col = _pick_key_column(verify_cursor, table, key_priority)
            if key_col is None:
                continue
            for pattern in like_patterns:
                verify_cursor.execute(
                    "SELECT COUNT(*) FROM " + table + " WHERE " + key_col
                    + " LIKE ?" + escape_clause, (pattern,))
                survivors += verify_cursor.fetchone()[0]
    finally:
        verify_conn.close()

    return {"deleted": deleted, "survivors": survivors,
            "skipped_tables": skipped_tables}


def purge_table_rows(db_path, tables, key_table=None, keys=None):
    """DELETE every row from each whitelisted table, plus (optionally) the
    rows whose key column matches `keys` in one keyed table -- the
    QoderWork agents.db scrub twin (v0.1's temp-.py heredoc: 15 exact
    tables + 12 app_settings keys; chats/sub_chats/messages/projects are
    NOT in the list and are never touched).

    Table names (and key_table) are validated against the module whitelist
    regex -- never interpolated otherwise. Schema evolution is tolerated
    per table AND per keyed table: a missing table reports "schema-missing"
    instead of failing, matching the PS WARN contract (v0.1's heredoc
    crashed on a missing app_settings table while its PS side already had
    the schema-missing branch -- that gap is closed here). Every deletion
    is verified by a READ-ONLY REOPEN recount (module invariant): the
    after[] values are the post-commit survivor counts, so the caller's
    "after == 0" check IS the verification.

    Returns {"before": {name: count | "schema-missing"},
             "after":  {name: count | "schema-missing"}} where name is a
    table name from `tables`, or a key from `keys` for the keyed-table
    deletions. Raises on any sqlite error (caller contract: non-zero exit
    -> PowerShell FAILED).
    """
    if key_table is not None and not _TABLE_NAME_RE.match(key_table or ""):
        raise ValueError("Unsafe SQLite table name: {0!r}".format(key_table))
    for table in tables:
        _validate_table_name(table)

    conn = sqlite3.connect(db_path, timeout=10)
    before = {}
    after = {}
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
        existing = {row[0] for row in cursor.fetchall()}
        for table in tables:
            if table not in existing:
                before[table] = "schema-missing"
                after[table] = "schema-missing"
                continue
            cursor.execute("SELECT COUNT(*) FROM " + table)
            before[table] = cursor.fetchone()[0]
            cursor.execute("DELETE FROM " + table)
        if keys:
            if key_table not in existing:
                for key in keys:
                    before[key] = "schema-missing"
                    after[key] = "schema-missing"
            else:
                for key in keys:
                    cursor.execute(
                        "SELECT COUNT(*) FROM " + key_table + " WHERE key = ?",
                        (key,))
                    before[key] = cursor.fetchone()[0]
                    cursor.execute(
                        "DELETE FROM " + key_table + " WHERE key = ?", (key,))
        conn.commit()
    finally:
        conn.close()

    # Verify-after (module invariant): read-only reopen, recount survivors.
    # The after[] values ARE the verification the caller checks.
    verify_conn = _ro_connect(db_path)
    try:
        verify_cursor = verify_conn.cursor()
        verify_cursor.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")
        verify_existing = {row[0] for row in verify_cursor.fetchall()}
        for table in tables:
            if before[table] == "schema-missing":
                continue
            verify_cursor.execute("SELECT COUNT(*) FROM " + table)
            after[table] = verify_cursor.fetchone()[0]
        if keys and (key_table in verify_existing):
            for key in keys:
                if before[key] == "schema-missing":
                    continue
                verify_cursor.execute(
                    "SELECT COUNT(*) FROM " + key_table + " WHERE key = ?",
                    (key,))
                after[key] = verify_cursor.fetchone()[0]
    finally:
        verify_conn.close()

    return {"before": before, "after": after}


def purge_keys(db_path, exact_keys=None, like_patterns=None, table="ItemTable"):
    """DELETE exact-key rows + LIKE-pattern rows from one keyed table and
    verify zero survivors via read-only reopen -- the Qoder state.vscdb
    auth-secrets scrub twin (v0.4's temp-.py heredoc).

    Per-key/per-pattern before/after COUNT reports (the PS side audits each
    name individually with "count=X" -> "count=0"). A missing table raises
    (caller contract: non-zero exit -> PowerShell FAILED). Raises on any
    sqlite error. Parameterized ? placeholders for every value; only the
    whitelist-validated table name is ever interpolated.
    """
    _validate_table_name(table)
    if exact_keys is None:
        exact_keys = []
    if like_patterns is None:
        like_patterns = []

    before = {}
    after = {}
    conn = sqlite3.connect(db_path, timeout=10)
    try:
        cursor = conn.cursor()
        for k in exact_keys:
            cursor.execute(
                "SELECT COUNT(*) FROM " + table + " WHERE key = ?", (k,))
            before[k] = cursor.fetchone()[0]
        for p in like_patterns:
            cursor.execute(
                "SELECT COUNT(*) FROM " + table + " WHERE key LIKE ?", (p,))
            before[p] = cursor.fetchone()[0]
        for k in exact_keys:
            cursor.execute("DELETE FROM " + table + " WHERE key = ?", (k,))
        for p in like_patterns:
            cursor.execute("DELETE FROM " + table + " WHERE key LIKE ?", (p,))
        conn.commit()
    finally:
        conn.close()

    # Verify-after (module invariant): read-only reopen recount.
    verify_conn = _ro_connect(db_path)
    try:
        verify_cursor = verify_conn.cursor()
        for k in exact_keys:
            verify_cursor.execute(
                "SELECT COUNT(*) FROM " + table + " WHERE key = ?", (k,))
            after[k] = verify_cursor.fetchone()[0]
        for p in like_patterns:
            verify_cursor.execute(
                "SELECT COUNT(*) FROM " + table + " WHERE key LIKE ?", (p,))
            after[p] = verify_cursor.fetchone()[0]
    finally:
        verify_conn.close()

    return {"before": before, "after": after}


def count_keys(db_path, exact_keys=None, like_patterns=None, table="ItemTable"):
    """READ-ONLY survivor count for identity-key patterns in one keyed
    table -- the Qoder device-flow final probe twin (v0.4's temp-.py
    heredoc). No mutation, no table creation: a missing table raises
    (caller contract: non-zero exit -> PowerShell FAILED).

    Returns {"survivors": N}.
    """
    _validate_table_name(table)
    if exact_keys is None:
        exact_keys = []
    if like_patterns is None:
        like_patterns = []

    conn = _ro_connect(db_path)
    survivors = 0
    try:
        cursor = conn.cursor()
        for k in exact_keys:
            cursor.execute(
                "SELECT COUNT(*) FROM " + table + " WHERE key = ?", (k,))
            survivors += cursor.fetchone()[0]
        for p in like_patterns:
            cursor.execute(
                "SELECT COUNT(*) FROM " + table + " WHERE key LIKE ?", (p,))
            survivors += cursor.fetchone()[0]
    finally:
        conn.close()
    return {"survivors": survivors}


def clear_cli_telemetry(db_path):
    """DELETE telemetry-like keys from the ZCode CLI db.sqlite ItemTable.

    Contract carried over verbatim from the reset_zcode.ps1 bridge: sqlite
    failures are NOT error exits -- they print {"deleted": 0, "error": "..."}
    and exit 0 so the caller keeps its own audit wording (reset_zcode marks
    the step FAILED when "error" is present). A missing ItemTable table is
    tolerated per-pattern; every other sqlite error (locked db, corruption)
    surfaces via the error dict instead of being silently swallowed.
    Returns {"deleted": N, "remaining": 0} on success, or an "error" dict
    when sqlite fails (pre-mutation failures keep deleted=0) or the
    verify-after re-open still finds matching keys."""
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
            except sqlite3.OperationalError as exc:
                if "no such table" not in str(exc):
                    raise
                continue
            for row in cursor.fetchall():
                cursor.execute(
                    "DELETE FROM ItemTable WHERE key = ?", (row[0],))
                deleted += 1
        conn.commit()
    except sqlite3.Error as exc:
        return {"deleted": 0, "error": str(exc)}
    finally:
        conn.close()

    # Verify-after (module invariant): re-open read-only and count what still
    # matches. "remaining" is additive; anything left is surfaced through the
    # error dict so reset_zcode marks the step FAILED instead of trusting a
    # delete that did not stick.
    try:
        verify_conn = _ro_connect(db_path)
        try:
            verify_cursor = verify_conn.cursor()
            remaining = 0
            for pattern in patterns:
                try:
                    verify_cursor.execute(
                        "SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?",
                        (pattern,))
                except sqlite3.OperationalError as exc:
                    if "no such table" not in str(exc):
                        raise
                    continue
                remaining += verify_cursor.fetchone()[0]
        finally:
            verify_conn.close()
    except sqlite3.Error as exc:
        return {"deleted": deleted, "remaining": 0,
                "error": "verify-after failed: " + str(exc)}

    if remaining:
        return {"deleted": deleted, "remaining": remaining,
                "error": "{0} telemetry key(s) still match after commit".format(
                    remaining)}
    return {"deleted": deleted, "remaining": 0}


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
