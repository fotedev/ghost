"""unittest suite for the GHOST Python core (src/python/ghost).

Stdlib only (unittest + tempfile + subprocess) -- mirrors the Pester suite
for identity_utils.ps1 and adds real-SQLite coverage the Pester suite
cannot do without Python. Run from repo root:
    python -m unittest discover -s tests/python -v
or via the CI workflow's python-core job.
"""

import base64
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
GHOST_CLI = os.path.join(REPO_ROOT, "src", "python", "ghost_cli.py")

sys.path.insert(0, os.path.join(REPO_ROOT, "src", "python"))

from ghost import audit, backup, filesweep, identity, json_patch, restore, sqlite_keys, winstore  # noqa: E402


def _b64(payload):
    return base64.b64encode(
        json.dumps(payload).encode("utf-8")).decode("ascii")


class IdentitySetTests(unittest.TestCase):
    """Mirrors tests/identity_utils.Tests.ps1 New-IdentitySet block."""

    def test_all_four_fields_present(self):
        ids = identity.new_identity_set()
        for field in ("devDeviceId", "machineId", "macMachineId", "sqmId"):
            self.assertIn(field, ids)
            self.assertTrue(ids[field])

    def test_dev_device_id_is_lowercase_guid(self):
        value = identity.new_identity_set()["devDeviceId"]
        self.assertRegex(
            value, r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
                    r"[0-9a-f]{4}-[0-9a-f]{12}$")

    def test_machine_id_is_64_hex(self):
        self.assertRegex(identity.new_identity_set()["machineId"],
                         r"^[0-9a-f]{64}$")

    def test_mac_machine_id_is_128_hex(self):
        self.assertRegex(identity.new_identity_set()["macMachineId"],
                         r"^[0-9a-f]{128}$")

    def test_sqm_id_is_braced_uppercase_guid(self):
        value = identity.new_identity_set()["sqmId"]
        self.assertRegex(
            value, r"^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-"
                   r"[0-9A-F]{4}-[0-9A-F]{12}\}$")

    def test_sets_are_distinct(self):
        a = identity.new_identity_set()
        b = identity.new_identity_set()
        for field in ("devDeviceId", "machineId", "macMachineId", "sqmId"):
            self.assertNotEqual(a[field], b[field])

    def test_crash_reporter_id_lowercase_guid(self):
        self.assertRegex(
            identity.new_crash_reporter_id(),
            r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
            r"[0-9a-f]{4}-[0-9a-f]{12}$")


class SqliteUpdateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self._tmp.name, "state.vscdb")
        conn = sqlite3.connect(self.db)
        conn.execute(
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        conn.execute(
            "INSERT INTO ItemTable (key, value) VALUES ('old.key', 'before')")
        conn.commit()
        conn.close()

    def tearDown(self):
        self._tmp.cleanup()

    def test_upsert_reports_before_and_after(self):
        result = sqlite_keys.sqlite_update(
            self.db, {"telemetry.machineId": "aa", "old.key": "bb"})
        self.assertIsNone(result["before"]["telemetry.machineId"])
        self.assertEqual(result["before"]["old.key"], "before")
        self.assertEqual(result["after"]["telemetry.machineId"], "aa")
        self.assertEqual(result["after"]["old.key"], "bb")

    def test_verify_after_really_reads_disk(self):
        sqlite_keys.sqlite_update(self.db, {"k": "v"})
        conn = sqlite3.connect("file:" + self.db.replace("\\", "/") +
                               "?mode=ro", uri=True)
        value = conn.execute(
            "SELECT value FROM ItemTable WHERE key = 'k'").fetchone()[0]
        conn.close()
        self.assertEqual(value, "v")

    def test_creates_missing_table(self):
        result = sqlite_keys.sqlite_update(
            self.db, {"k": "v"}, table="FreshTable")
        self.assertEqual(result["after"]["k"], "v")

    def test_rejects_unsafe_table_name(self):
        with self.assertRaises(ValueError):
            sqlite_keys.sqlite_update(
                self.db, {"k": "v"}, table="Evil; DROP TABLE ItemTable")

    def test_values_go_through_placeholders(self):
        # A value that would break naive string interpolation round-trips.
        tricky = "x'; DROP TABLE ItemTable; --"
        sqlite_keys.sqlite_update(self.db, {"k": tricky})
        result = sqlite_keys.sqlite_update(
            self.db, {"k": "other", "k2": tricky})
        self.assertEqual(result["after"]["k"], "other")
        self.assertEqual(result["after"]["k2"], tricky)


class DeleteSecretsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self._tmp.name, "state.vscdb")
        conn = sqlite3.connect(self.db)
        conn.execute(
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        for key in ("secret://aicoding.auth.token",
                    "secret://blackbox.abc",
                    "gituser",
                    "innocent.key"):
            conn.execute(
                "INSERT INTO ItemTable (key, value) VALUES (?, 'x')", (key,))
        conn.commit()
        conn.close()

    def tearDown(self):
        self._tmp.cleanup()

    def test_deletes_only_secret_keys_and_verifies(self):
        result = sqlite_keys.delete_secrets(self.db)
        self.assertEqual(
            sorted(result["deleted"]),
            ["gituser", "secret://aicoding.auth.token",
             "secret://blackbox.abc"])
        self.assertEqual(result["survivors"], [0, 0, 0])
        conn = sqlite3.connect(self.db)
        remaining = [r[0] for r in conn.execute("SELECT key FROM ItemTable")]
        conn.close()
        self.assertEqual(remaining, ["innocent.key"])


class SqliteCoreHardeningTests(unittest.TestCase):
    """BS-6 fixes: URI-quoted read-only verify re-open, sqlite_update "ok"
    verdict, rowcount-gated exact-key deletes."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        # A directory with a SPACE in its name: the unquoted file: URI cut
        # the path at the space, so the verify re-open targeted the wrong
        # (nonexistent) location and every after[] came back None.
        spaced = os.path.join(self._tmp.name, "My Profile Dir")
        os.makedirs(spaced, exist_ok=True)
        self.db = os.path.join(spaced, "state.vscdb")
        conn = sqlite3.connect(self.db)
        conn.execute(
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        conn.commit()
        conn.close()

    def tearDown(self):
        self._tmp.cleanup()

    def test_ro_verify_survives_spaced_profile_path(self):
        result = sqlite_keys.sqlite_update(self.db, {"k": "v"})
        self.assertEqual(result["after"]["k"], "v")

    def test_ro_connect_quotes_specials(self):
        # Direct pin of the quote() fix: the read-only reopen must resolve
        # the spaced path (and round-trip the row).
        sqlite_keys.sqlite_update(self.db, {"k": "v2"})
        conn = sqlite_keys._ro_connect(self.db)
        try:
            value = conn.execute(
                "SELECT value FROM ItemTable WHERE key = 'k'").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(value, "v2")

    def test_ok_true_after_write(self):
        result = sqlite_keys.sqlite_update(self.db, {"k": "v"})
        self.assertTrue(result["ok"])

    def test_ok_true_when_text_affinity_rescopes_int(self):
        # The value column has TEXT affinity: an int written as 5 reads back
        # as "5" -- the str() comparison branch keeps ok True.
        result = sqlite_keys.sqlite_update(self.db, {"n": 5})
        self.assertEqual(result["after"]["n"], "5")
        self.assertTrue(result["ok"])

    def test_ok_false_when_verify_reads_a_different_store(self):
        # Force the verify re-open onto an EMPTY database: every after[]
        # comes back None, so ok must be False (the PS caller treats it as
        # FAILED). Simulates the torn/redirected-write failure mode.
        empty_db = os.path.join(self._tmp.name, "empty.vscdb")
        conn = sqlite3.connect(empty_db)
        conn.execute(
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        conn.commit()
        conn.close()
        original = sqlite_keys._ro_connect
        try:
            sqlite_keys._ro_connect = lambda path: sqlite3.connect(
                "file:" + empty_db.replace("\\", "/") + "?mode=ro", uri=True)
            result = sqlite_keys.sqlite_update(self.db, {"k": "v"})
        finally:
            sqlite_keys._ro_connect = original
        self.assertIsNone(result["after"]["k"])
        self.assertFalse(result["ok"])

    def test_absent_exact_key_not_reported_deleted(self):
        # rowcount gate: a key that matched no row is not "deleted" -- the
        # old unconditional append reported phantom removals.
        result = sqlite_keys.delete_secrets(
            self.db, exact_keys=("never-present.key",),
            like_patterns=())
        self.assertEqual(result["deleted"], [])
        self.assertEqual(result["survivors"], [0])

    def test_present_exact_key_still_reported_deleted(self):
        conn = sqlite3.connect(self.db)
        conn.execute(
            "INSERT INTO ItemTable (key, value) VALUES ('gituser', 'x')")
        conn.commit()
        conn.close()
        result = sqlite_keys.delete_secrets(
            self.db, exact_keys=("gituser",), like_patterns=())
        self.assertEqual(result["deleted"], ["gituser"])
        self.assertEqual(result["survivors"], [0])


class ScrubIdentityRowsTests(unittest.TestCase):
    """ghost.sqlite_keys.scrub_identity_rows — the Trae ai-agent scrub twin
    (v0.2's temp-.py heredoc): key-NAME matching across every scrub-able
    table; values (chat content) are never inspected or modified."""

    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="ghost_scrub_")

    def _make_db(self, path):
        conn = sqlite3.connect(path)
        cursor = conn.cursor()
        # Typed key column: identity rows + chat/user rows side by side.
        cursor.execute("CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT)")
        cursor.executemany(
            "INSERT INTO kv (key, value) VALUES (?, ?)",
            [("deviceId", "123"), ("machine_id", "abc"),
             ("authToken", "tok"), ("telemetry.enabled", "true"),
             ("chat:message:1", "hello"),
             ("chat:title", "how to auth token")])
        # Untyped columns (identity rows previously survived this shape).
        cursor.execute("CREATE TABLE loose (name, data)")
        cursor.executemany(
            "INSERT INTO loose (name, data) VALUES (?, ?)",
            [("device_id", "9"), ("user:profile", "keep me")])
        # id column preferred over name (key_priority order).
        cursor.execute("CREATE TABLE rows (id TEXT, label TEXT)")
        cursor.executemany(
            "INSERT INTO rows (id, label) VALUES (?, ?)",
            [("machineid-1", "x"), ("row-2", "keep")])
        # No key-like column -> skipped, never silently ignored.
        cursor.execute("CREATE TABLE nocolumns (value TEXT)")
        cursor.execute("INSERT INTO nocolumns (value) VALUES ('deviceId')")
        # Non-whitelisted table name -> skipped, never interpolated.
        cursor.execute('CREATE TABLE "1bad name" (key TEXT)')
        conn.commit()
        conn.close()

    def _tables(self, path):
        conn = sqlite3.connect(path)
        try:
            names = set(row[0] for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"))
            kv = set(row[0] for row in conn.execute("SELECT key FROM kv"))
            loose = set(row[0] for row in
                        conn.execute("SELECT name FROM loose"))
            ids = set(row[0] for row in conn.execute("SELECT id FROM rows"))
        finally:
            conn.close()
        return names, kv, loose, ids

    def test_scrubs_identity_rows_preserves_values_and_reports_skips(self):
        path = os.path.join(self.base, "ai.db")
        self._make_db(path)
        r = sqlite_keys.scrub_identity_rows(path)
        self.assertEqual(r["survivors"], 0, r)
        self.assertEqual(r["deleted"], 6)
        _names, kv, loose, ids = self._tables(path)
        # Identity rows gone (typed + untyped + id-priority columns).
        self.assertNotIn("deviceId", kv)
        self.assertNotIn("machine_id", kv)
        self.assertNotIn("authToken", kv)
        self.assertNotIn("telemetry.enabled", kv)
        self.assertNotIn("device_id", loose)
        self.assertNotIn("machineid-1", ids)
        # Chat/user rows preserved: spaced human text ("auth token") can
        # never match the ESCAPE'd single-token-adjacency patterns.
        self.assertIn("chat:message:1", kv)
        self.assertIn("chat:title", kv)
        self.assertIn("user:profile", loose)
        self.assertIn("row-2", ids)
        # Skips are reported, not silent.
        self.assertIn("nocolumns", r["skipped_tables"])
        self.assertIn("1bad name", r["skipped_tables"])

    def test_escape_controls_underscore_literal(self):
        path = os.path.join(self.base, "esc.db")
        conn = sqlite3.connect(path)
        cursor = conn.cursor()
        cursor.execute("CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT)")
        cursor.executemany(
            "INSERT INTO kv (key, value) VALUES (?, ?)",
            [("machine_id", "a"), ("machineXid", "b")])
        conn.commit()
        conn.close()
        # Default escape="\\": "_" is ESCAPE'd to its literal self (the
        # pattern must carry the literal backslash), so it matches ONLY the
        # literal underscore form.
        r = sqlite_keys.scrub_identity_rows(
            path, like_patterns=("%machine\\_id%",))
        self.assertEqual(r["deleted"], 1, r)
        conn = sqlite3.connect(path)
        try:
            left = set(row[0] for row in conn.execute("SELECT key FROM kv"))
        finally:
            conn.close()
        self.assertEqual(left, {"machineXid"})
        # escape="": "_" keeps its LIKE wildcard meaning -> both forms match.
        conn = sqlite3.connect(path)
        try:
            conn.execute(
                "INSERT INTO kv (key, value) VALUES ('machine_id', 'c')")
            conn.commit()
        finally:
            conn.close()
        r = sqlite_keys.scrub_identity_rows(
            path, like_patterns=("%machine_id%",), escape="")
        self.assertEqual(r["deleted"], 2, r)


class PurgeKeysTests(unittest.TestCase):
    """ghost.sqlite_keys.purge_keys — the Qoder state.vscdb secrets-scrub
    twin (v0.4's temp-.py heredoc): exact-key + LIKE-pattern DELETEs on one
    keyed table, per-name before/after counts, read-only reopen verify."""

    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="ghost_purgekeys_")

    def _make_db(self, path):
        conn = sqlite3.connect(path)
        cursor = conn.cursor()
        cursor.execute("CREATE TABLE ItemTable ("
                       "key TEXT PRIMARY KEY, value TEXT)")
        cursor.executemany(
            "INSERT INTO ItemTable VALUES (?, ?)",
            [("secret://aicoding.auth.userInfo", "tok"),
             ("aicoding.auth.loginBroadcast", "bc"),
             ("gituser", "name"),
             ("secret://blackbox.extra", "enc"),
             ('secret://{"extensionId":"aicoding.aicoding-agent",'
              '"key":"secret.local.machine.variables"}', "vars"),
             # Chat/model keys deliberately NOT matched (chat preserved).
             ("aicoding-chat-1.state.hidden", "keep"),
             ("modelConfigs", "keep")])
        conn.commit()
        conn.close()

    def test_purges_exact_and_like_keys_reports_per_name(self):
        path = os.path.join(self.base, "state.vscdb")
        self._make_db(path)
        r = sqlite_keys.purge_keys(
            path,
            exact_keys=["secret://aicoding.auth.userInfo",
                        "aicoding.auth.loginBroadcast", "gituser"],
            like_patterns=["secret://blackbox.%",
                           "%secret.local.machine.variables%"])
        for name in ("secret://aicoding.auth.userInfo",
                     "aicoding.auth.loginBroadcast", "gituser",
                     "secret://blackbox.%",
                     "%secret.local.machine.variables%"):
            self.assertEqual(r["after"][name], 0, name)
        self.assertGreaterEqual(r["before"]["gituser"], 1)
        conn = sqlite3.connect(path)
        try:
            left = set(row[0] for row in conn.execute("SELECT key FROM ItemTable"))
        finally:
            conn.close()
        self.assertEqual(left, {"aicoding-chat-1.state.hidden", "modelConfigs"})

    def test_missing_table_raises(self):
        path = os.path.join(self.base, "empty.db")
        sqlite3.connect(path).close()
        with self.assertRaises(sqlite3.OperationalError):
            sqlite_keys.purge_keys(path, exact_keys=["x"])


class CountKeysTests(unittest.TestCase):
    """ghost.sqlite_keys.count_keys — the Qoder device-flow final probe
    twin: READ-ONLY survivor count (no mutation, no table creation)."""

    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="ghost_countkeys_")

    def test_counts_survivors_read_only(self):
        path = os.path.join(self.base, "state.vscdb")
        conn = sqlite3.connect(path)
        conn.execute("CREATE TABLE ItemTable ("
                     "key TEXT PRIMARY KEY, value TEXT)")
        conn.executemany(
            "INSERT INTO ItemTable VALUES (?, ?)",
            [("secret://aicoding.auth.userInfo", "tok"),
             ("secret://blackbox.x", "enc"),
             ("chat:1", "keep")])
        conn.commit()
        conn.close()
        r = sqlite_keys.count_keys(
            path,
            exact_keys=["secret://aicoding.auth.userInfo"],
            like_patterns=["secret://blackbox.%"])
        self.assertEqual(r["survivors"], 2)
        # Read-only: the rows are still there afterwards.
        conn = sqlite3.connect(path)
        try:
            n = conn.execute("SELECT COUNT(*) FROM ItemTable").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(n, 3)

    def test_missing_table_raises(self):
        path = os.path.join(self.base, "empty.db")
        sqlite3.connect(path).close()
        with self.assertRaises(sqlite3.OperationalError):
            sqlite_keys.count_keys(path, exact_keys=["x"])


class PurgeTableRowsTests(unittest.TestCase):
    """ghost.sqlite_keys.purge_table_rows — the QoderWork agents.db scrub
    twin (v0.1's temp-.py heredoc): exact-table wipes + keyed-table exact
    key deletions, schema-missing tolerated per table, read-only reopen
    verify (after[] IS the verification)."""

    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="ghost_purge_")

    def _make_db(self, path):
        conn = sqlite3.connect(path)
        cursor = conn.cursor()
        cursor.execute("CREATE TABLE mcp_oauth_tokens (id TEXT, blob TEXT)")
        cursor.executemany(
            "INSERT INTO mcp_oauth_tokens VALUES (?, ?)",
            [("1", "enc"), ("2", "enc")])
        cursor.execute("CREATE TABLE google_oauth_tokens (id TEXT)")
        cursor.execute("INSERT INTO google_oauth_tokens VALUES ('g1')")
        # CHAT PRESERVATION table: never in the purge list.
        cursor.execute("CREATE TABLE chats (id TEXT, title TEXT)")
        cursor.execute("INSERT INTO chats VALUES ('c1', 'keep')")
        cursor.execute(
            "CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)")
        cursor.executemany(
            "INSERT INTO app_settings VALUES (?, ?)",
            [("asyncMigrationStatus", "done"), ("windowBounds", "{}"),
             ("proxy", "keep-me"), ("futureKey", "also-kept")])
        conn.commit()
        conn.close()

    def test_purges_tables_and_keys_preserves_chats_and_unlisted_keys(self):
        path = os.path.join(self.base, "agents.db")
        self._make_db(path)
        r = sqlite_keys.purge_table_rows(
            path,
            ["mcp_oauth_tokens", "google_oauth_tokens", "gone_table"],
            key_table="app_settings",
            keys=["asyncMigrationStatus", "windowBounds"])
        self.assertEqual(r["before"]["mcp_oauth_tokens"], 2)
        self.assertEqual(r["after"]["mcp_oauth_tokens"], 0)
        self.assertEqual(r["after"]["google_oauth_tokens"], 0)
        self.assertEqual(r["before"]["gone_table"], "schema-missing")
        self.assertEqual(r["after"]["gone_table"], "schema-missing")
        self.assertEqual(r["before"]["asyncMigrationStatus"], 1)
        self.assertEqual(r["after"]["asyncMigrationStatus"], 0)
        self.assertEqual(r["after"]["windowBounds"], 0)
        conn = sqlite3.connect(path)
        try:
            chats = conn.execute("SELECT COUNT(*) FROM chats").fetchone()[0]
            proxy = conn.execute(
                "SELECT COUNT(*) FROM app_settings WHERE key IN "
                "('proxy', 'futureKey')").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(chats, 1)
        self.assertEqual(proxy, 2)

    def test_missing_keyed_table_reports_schema_missing(self):
        # v0.1's heredoc crashed here (no existing-check on app_settings)
        # while its PS side already carried the schema-missing branch.
        path = os.path.join(self.base, "agents.db")
        conn = sqlite3.connect(path)
        conn.execute("CREATE TABLE mcp_oauth_tokens (id TEXT)")
        conn.commit()
        conn.close()
        r = sqlite_keys.purge_table_rows(
            path, ["mcp_oauth_tokens"],
            key_table="app_settings", keys=["windowBounds"])
        self.assertEqual(r["after"]["mcp_oauth_tokens"], 0)
        self.assertEqual(r["before"]["windowBounds"], "schema-missing")
        self.assertEqual(r["after"]["windowBounds"], "schema-missing")

    def test_rejects_unsafe_table_names(self):
        path = os.path.join(self.base, "agents.db")
        with self.assertRaises(ValueError):
            sqlite_keys.purge_table_rows(path, ["bad; DROP TABLE x"])


class ClearCliTelemetryTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self._tmp.cleanup()

    def _make_db(self):
        db = os.path.join(self._tmp.name, "db.sqlite")
        conn = sqlite3.connect(db)
        conn.execute(
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        for key in ("xtelemetry.machineId", "my.machineId.y",
                    "some.deviceId.z", "chat.session"):
            conn.execute(
                "INSERT INTO ItemTable (key, value) VALUES (?, 'v')", (key,))
        conn.commit()
        conn.close()
        return db

    def test_deletes_telemetry_like_keys_only(self):
        result = sqlite_keys.clear_cli_telemetry(self._make_db())
        self.assertEqual(result["deleted"], 3)
        self.assertEqual(result["remaining"], 0)
        self.assertNotIn("error", result)
        conn = sqlite3.connect(os.path.join(self._tmp.name, "db.sqlite"))
        remaining = [r[0] for r in conn.execute("SELECT key FROM ItemTable")]
        conn.close()
        self.assertEqual(remaining, ["chat.session"])

    def test_missing_itemtable_is_tolerated(self):
        db = os.path.join(self._tmp.name, "empty.sqlite")
        sqlite3.connect(db).close()  # creates an empty db, no tables
        result = sqlite_keys.clear_cli_telemetry(db)
        self.assertEqual(result["deleted"], 0)

    def test_corrupt_db_surfaces_error_contract(self):
        # A non-SQLite file raises "file is not a database" on first execute --
        # NOT a missing-table case, so it must reach the error dict instead of
        # being swallowed into a silent {"deleted": 0}.
        db = os.path.join(self._tmp.name, "garbage.sqlite")
        with open(db, "wb") as f:
            f.write(b"this is not a sqlite database at all")
        result = sqlite_keys.clear_cli_telemetry(db)
        self.assertEqual(result["deleted"], 0)
        self.assertIn("error", result)

    def test_connect_failure_returns_error_contract(self):
        # A directory as the db path -> sqlite3.Error on connect, which the
        # bridge contract reports as {"deleted": 0, "error": ...} exit 0.
        result = sqlite_keys.clear_cli_telemetry(self._tmp.name)
        self.assertEqual(result["deleted"], 0)
        self.assertIn("error", result)

    def test_store_without_matching_rows_is_clean(self):
        # W4-3: a store whose ItemTable holds NO telemetry-like keys (the
        # clean-box case for the shared-CLI-db scrub) reports zeroed counts
        # with no error - a scrub is not "failed" just because there was
        # nothing to delete.
        db = os.path.join(self._tmp.name, "clean.sqlite")
        conn = sqlite3.connect(db)
        conn.execute(
            "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        conn.execute(
            "INSERT INTO ItemTable (key, value) VALUES ('chat.session', 'v')")
        conn.commit()
        conn.close()
        result = sqlite_keys.clear_cli_telemetry(db)
        self.assertEqual(result["deleted"], 0)
        self.assertEqual(result["remaining"], 0)
        self.assertNotIn("error", result)

    def test_locked_db_surfaces_error_contract(self):
        # W4-3: another connection holding an EXCLUSIVE lock (a live instance
        # on the shared CLI db) -> the busy timeout expires, the mutation is
        # refused, and the bridge reports the error dict honestly (never a
        # silent {"deleted": 0} success). The lock is released in finally.
        db = self._make_db()
        holder = sqlite3.connect(db, timeout=10)
        try:
            holder.execute("BEGIN EXCLUSIVE")
            result = sqlite_keys.clear_cli_telemetry(db)
            self.assertEqual(result["deleted"], 0)
            self.assertIn("error", result)
        finally:
            holder.rollback()
            holder.close()


class ChatCheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.shared = os.path.join(self._tmp.name, "db.sqlite")
        self.index = os.path.join(self._tmp.name, "tasks-index.sqlite")

        conn = sqlite3.connect(self.shared)
        conn.execute(
            "CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, "
            "time_updated INTEGER, time_archived INTEGER, task_type TEXT)")
        conn.execute(
            "CREATE TABLE message (id INTEGER PRIMARY KEY, role TEXT, "
            "time_created INTEGER, time_updated INTEGER, data TEXT)")
        conn.execute("CREATE TABLE part (id INTEGER PRIMARY KEY, "
                     "time_updated INTEGER)")
        conn.execute(
            "CREATE TABLE tool_usage (tool_name TEXT, started_at INTEGER, "
            "completed_at INTEGER)")
        now = 1750000000000
        conn.execute(
            "INSERT INTO session VALUES "
            "('s1', 'chat one', ?, NULL, 'interactive')", (now,))
        conn.execute(
            "INSERT INTO session VALUES "
            "('s2', 'archived|chat', ?, 1, 'interactive')", (now,))
        conn.execute(
            "INSERT INTO session VALUES "
            "('s3', 'chat three', ?, NULL, 'background')", (now,))
        conn.execute(
            "INSERT INTO session VALUES "
            "('s4', 'chat four', ?, NULL, 'workflow_parent')", (now,))
        conn.commit()
        conn.close()

        tdb = sqlite3.connect(self.index)
        tdb.execute("CREATE TABLE tasks (task_id TEXT PRIMARY KEY)")
        tdb.execute("INSERT INTO tasks VALUES ('s4')")
        tdb.commit()
        tdb.close()

    def tearDown(self):
        self._tmp.cleanup()

    def test_missing_lists_unindexed_live_sessions(self):
        lines = sqlite_keys.chat_check("missing", self.shared, self.index)
        # s1 (interactive, unindexed) missing; s2 archived excluded;
        # s3 background task_type excluded; s4 indexed excluded.
        self.assertEqual(lines[0], "COUNT:1")
        self.assertTrue(lines[1].startswith("MISSING:s1|chat one"))

    def test_missing_strips_pipes_from_titles(self):
        conn = sqlite3.connect(self.shared)
        conn.execute("INSERT INTO session VALUES "
                     "('s5', 'a|b|c', 1, NULL, 'interactive')")
        conn.commit()
        conn.close()
        lines = sqlite_keys.chat_check("missing", self.shared, self.index)
        self.assertTrue(any(l.startswith("MISSING:s5|a b c") for l in lines))

    def test_hot_reports_all_four_signals(self):
        now = int(1750000000000)
        conn = sqlite3.connect(self.shared)
        conn.execute(
            "INSERT INTO message (role, time_created, time_updated, data) "
            "VALUES ('assistant', ?, ?, ?)",
            (now, now, json.dumps({"role": "assistant", "time": {}})))
        conn.execute(
            "INSERT INTO tool_usage VALUES ('Bash', ?, NULL)", (now,))
        conn.commit()
        conn.close()

        # The probe compares against wall-clock now, so make the rows recent
        # relative to the real current time.
        import time as _time
        real_now = int(_time.time() * 1000)
        conn = sqlite3.connect(self.shared)
        conn.execute("DELETE FROM message")
        conn.execute("DELETE FROM tool_usage")
        conn.execute(
            "INSERT INTO message (role, time_created, time_updated, data) "
            "VALUES ('assistant', ?, ?, ?)",
            (real_now - 1000, real_now - 1000,
             json.dumps({"role": "assistant", "time": {}})))
        conn.execute(
            "INSERT INTO tool_usage VALUES ('Bash', ?, NULL)",
            (real_now - 500,))
        conn.commit()
        conn.close()

        lines = sqlite_keys.chat_check("hot", self.shared)
        signals = dict(l.split(":", 1) for l in lines)
        self.assertIn("AGE_MS", signals)
        self.assertIn("INFLIGHT_MSG_AGE_MS", signals)
        self.assertIn("INFLIGHT_TOOL_AGE_MS", signals)
        self.assertIn("INFLIGHT_TOOL_NAME", signals)
        self.assertEqual(signals["INFLIGHT_TOOL_NAME"], "Bash")
        self.assertLess(int(signals["INFLIGHT_MSG_AGE_MS"]), 60000)
        self.assertLess(int(signals["INFLIGHT_TOOL_AGE_MS"]), 60000)

    def test_hot_with_idle_db_reports_minus_one(self):
        lines = sqlite_keys.chat_check("hot", self.shared)
        signals = dict(l.split(":", 1) for l in lines)
        self.assertEqual(signals["INFLIGHT_MSG_AGE_MS"], "-1")
        self.assertEqual(signals["INFLIGHT_TOOL_AGE_MS"], "-1")
        self.assertEqual(signals["INFLIGHT_TOOL_NAME"], "")


class JsonPatchTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self._tmp.name, "storage.json")
        with open(self.path, "w", encoding="utf-8") as f:
            json.dump({"keep": 1, "telemetry.machineId": "old"}, f)

    def tearDown(self):
        self._tmp.cleanup()

    def test_patches_existing_and_new_keys(self):
        report = json_patch.json_identity_update(
            self.path, {"telemetry.machineId": "new", "fresh.key": "v"})
        self.assertTrue(report["ok"])
        self.assertEqual(report["before"]["telemetry.machineId"], "old")
        self.assertIsNone(report["before"]["fresh.key"])
        with open(self.path, "r", encoding="utf-8") as f:
            content = json.load(f)
        self.assertEqual(content["keep"], 1)  # unrelated keys preserved
        self.assertEqual(content["telemetry.machineId"], "new")
        self.assertEqual(content["fresh.key"], "v")

    def test_missing_file_reports_not_found(self):
        report = json_patch.json_identity_update(
            os.path.join(self._tmp.name, "nope.json"), {"k": "v"})
        self.assertFalse(report["ok"])
        self.assertEqual(report["error"], "not-found")

    def test_invalid_json_reports_parse_error(self):
        bad = os.path.join(self._tmp.name, "bad.json")
        with open(bad, "w", encoding="utf-8") as f:
            f.write("{not json")
        report = json_patch.json_identity_update(bad, {"k": "v"})
        self.assertFalse(report["ok"])
        self.assertEqual(report["error"], "parse")


class AuditAndRestoreTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self._tmp.cleanup()

    def test_audit_log_writes_json_array(self):
        path = os.path.join(self._tmp.name, "sub", "audit_20260101.json")
        entries = [
            audit.audit_entry("f.json", "k", None, "v", True),
            audit.audit_entry("f.json", "k2", "old", "new", False),
        ]
        audit.write_audit_log(entries, path)
        with open(path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        self.assertEqual(len(loaded), 2)
        self.assertEqual(
            list(loaded[0].keys()), ["file", "key", "before", "after", "ok"])

    def test_restore_script_shape(self):
        backup_root = os.path.join(self._tmp.name, "20260101_000000")
        os.makedirs(backup_root)
        actions = [
            {"action": "copy", "originalPath": r"C:\a\storage.json",
             "backupPath": os.path.join(backup_root, "storage.json"),
             "renamedPath": None},
            {"action": "rename", "originalPath": r"C:\a\cookies",
             "backupPath": None, "renamedPath": r"C:\a\cookies.backup"},
        ]
        path = restore.new_restore_script(backup_root, "ZCode", actions)
        self.assertTrue(path.endswith(
            os.path.join(backup_root, "restore_ZCode_20260101_000000.ps1")))
        # PS 5.1 reads BOM-less files as ANSI, so the restore script must
        # carry a UTF-8 BOM for non-ASCII profile paths to survive.
        with open(path, "rb") as f:
            self.assertEqual(f.read(3), b"\xef\xbb\xbf")
        with open(path, "r", encoding="utf-8-sig") as f:
            body = f.read()
        self.assertIn("function Restore-Entry", body)
        self.assertIn("$manifestJson = @'", body)
        self.assertIn("'@", body)
        # Paths appear JSON-escaped inside the embedded manifest.
        self.assertIn(json.dumps(r"C:\a\cookies.backup")[1:-1], body)
        self.assertIn("[SKIP] backup missing for", body)


class CliSmokeTests(unittest.TestCase):
    """End-to-end through ghost_cli.py exactly the way the PowerShell
    bridges invoke it (base64 payloads, stdout contracts)."""

    def _run(self, *argv):
        proc = subprocess.run(
            [sys.executable, GHOST_CLI] + list(argv),
            capture_output=True, text=True)
        return proc

    def test_identity_command(self):
        proc = self._run("identity")
        self.assertEqual(proc.returncode, 0)
        ids = json.loads(proc.stdout)
        self.assertRegex(ids["machineId"], r"^[0-9a-f]{64}$")

    def test_sqlite_update_command_bridge_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "state.vscdb")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE ItemTable ("
                         "key TEXT PRIMARY KEY, value TEXT)")
            conn.commit()
            conn.close()
            updates_b64 = _b64({"telemetry.machineId": "abc"})
            proc = self._run("sqlite-update", db, updates_b64)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["before"]["telemetry.machineId"], None)
            self.assertEqual(result["after"]["telemetry.machineId"], "abc")

    def test_delete_secrets_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "state.vscdb")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE ItemTable ("
                         "key TEXT PRIMARY KEY, value TEXT)")
            conn.execute("INSERT INTO ItemTable VALUES "
                         "('secret://aicoding.auth.t', 'x')")
            conn.commit()
            conn.close()
            proc = self._run("delete-secrets", db)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["survivors"], [0, 0, 0])

    def test_chat_check_unknown_mode_function_contract(self):
        # Function level: prints UNKNOWN-MODE and exits 2 (original bridge
        # contract). The CLI argparse layer rejects unknown modes earlier
        # with the same exit code (next test).
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            with self.assertRaises(SystemExit) as cm:
                sqlite_keys.chat_check("bogus", "whatever.db")
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("UNKNOWN-MODE", buf.getvalue())

    def test_chat_check_unknown_mode_cli_exit_code(self):
        proc = self._run("chat-check", "bogus", "whatever.db")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("invalid choice", proc.stderr)

    def test_machineid_file_command_bridge_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "machineid")
            root = os.path.join(tmp, "ID_Backups", "ts")
            payload_b64 = _b64({"value": "NEW-ID"})
            proc = self._run("machineid-file", path, root, "machineid",
                             payload_b64)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertEqual(report["after"], "NEW-ID")
            # BOM-less UTF-8: the PS Set-VerifiedMachineIdFile regression.
            with open(path, "rb") as f:
                self.assertEqual(f.read(), b"NEW-ID")

    def test_sweep_file_and_backup_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "Cookies")
            with open(src, "wb") as f:
                f.write(b"data")
            root = os.path.join(tmp, "ID_Backups", "ts")
            proc = self._run("backup", src, root, "Cookies")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertTrue(report["ok"])
            self.assertTrue(os.path.exists(report["destination"]))
            proc = self._run("sweep-file", src)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["after"], "deleted")
            self.assertFalse(os.path.exists(src))

    def test_store_delete_command_rename_bridge(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = os.path.join(tmp, "Cookies")
            with open(store, "wb") as f:
                f.write(b"data")
            root = os.path.join(tmp, "ID_Backups", "ts")
            proc = self._run("store-delete", store, root, "Cookies",
                             "--action", "rename")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertEqual(report["renamed_to"], store + ".backup")
            self.assertFalse(os.path.exists(store))

    def test_sweep_tree_command_reports_remaining(self):
        with tempfile.TemporaryDirectory() as tmp:
            tree = os.path.join(tmp, "sentry")
            os.makedirs(tree)
            with open(os.path.join(tree, "a.log"), "w", encoding="utf-8") as f:
                f.write("x")
            root = os.path.join(tmp, "ID_Backups", "ts")
            proc = self._run("sweep-tree", tree, root, "sentry")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertTrue(report["ok"])
            self.assertEqual(report["deleted"], 1)
            self.assertEqual(report["remaining"], 0)

    def test_purge_keys_and_count_keys_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "state.vscdb")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE ItemTable ("
                         "key TEXT PRIMARY KEY, value TEXT)")
            conn.execute("INSERT INTO ItemTable VALUES ('gituser', 'n')")
            conn.execute("INSERT INTO ItemTable VALUES ('secret://blackbox.1', 'e')")
            conn.execute("INSERT INTO ItemTable VALUES ('chat:1', 'keep')")
            conn.commit()
            conn.close()
            cfg_b64 = _b64({"exact_keys": ["gituser"],
                            "like_patterns": ["secret://blackbox.%"]})
            proc = self._run("count-keys", db, cfg_b64)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["survivors"], 2)
            proc = self._run("purge-keys", db, cfg_b64)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["after"]["gituser"], 0)
            self.assertEqual(result["after"]["secret://blackbox.%"], 0)
            proc = self._run("count-keys", db, cfg_b64)
            self.assertEqual(json.loads(proc.stdout)["survivors"], 0)

    def test_purge_tables_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "agents.db")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE mcp_oauth_tokens (id TEXT)")
            conn.execute("INSERT INTO mcp_oauth_tokens VALUES ('1')")
            conn.execute("CREATE TABLE app_settings (key TEXT, value TEXT)")
            conn.execute(
                "INSERT INTO app_settings VALUES ('windowBounds', '{}')")
            conn.commit()
            conn.close()
            cfg_b64 = _b64({"tables": ["mcp_oauth_tokens"],
                            "key_table": "app_settings",
                            "keys": ["windowBounds"]})
            proc = self._run("purge-tables", db, cfg_b64)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["after"]["mcp_oauth_tokens"], 0)
            self.assertEqual(result["after"]["windowBounds"], 0)

    def test_scrub_rows_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = os.path.join(tmp, "ai.db")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT)")
            conn.execute("INSERT INTO kv VALUES ('deviceId', 'x')")
            conn.execute("INSERT INTO kv VALUES ('chat:1', 'keep')")
            conn.commit()
            conn.close()
            proc = self._run("scrub-rows", db)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["survivors"], 0)
            self.assertEqual(result["deleted"], 1)
            self.assertEqual(result["skipped_tables"], [])

    def test_json_remove_prefixes_command(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "storage.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write(json.dumps({
                    "iCubeAuthInfo://auth.trae.ai?token=1": "tok",
                    "xiCubeAuthInfo://decoy": "keep",
                    "telemetry.machineId": "abc"}))
            root = os.path.join(tmp, "ID_Backups", "ts")
            payload_b64 = _b64({"keys": [],
                                "prefixes": ["iCubeAuthInfo://"]})
            proc = self._run("json-remove", path, root, "storage.json",
                             payload_b64)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertTrue(report["ok"])
            self.assertEqual(
                report["removed_prefixes"]["iCubeAuthInfo://"], 1)
            with open(path, "r", encoding="utf-8-sig") as f:
                content = json.load(f)
            self.assertNotIn("iCubeAuthInfo://auth.trae.ai?token=1", content)
            self.assertIn("xiCubeAuthInfo://decoy", content)
            self.assertEqual(content["telemetry.machineId"], "abc")


class BackupToTimestampedDirTests(unittest.TestCase):
    """ghost.backup — port of Backup-FileToTimestampDir with verify-after."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = self._tmp.name
        self.src_dir = os.path.join(base, "store")
        os.makedirs(self.src_dir)
        with open(os.path.join(self.src_dir, "storage.json"), "w",
                  encoding="utf-8") as f:
            f.write('{"telemetry.machineId": "OLD"}')
        with open(os.path.join(self.src_dir, "nested.log"), "w",
                  encoding="utf-8") as f:
            f.write("log line" * 10)
        self.src_file = os.path.join(base, "state.vscdb")
        with open(self.src_file, "wb") as f:
            f.write(b"sqlite-bytes" * 64)
        self.backup_root = os.path.join(base, "ID_Backups", "20261017-120000")
        self._sleeps = []
        self._orig_sleep = backup.time.sleep
        backup.time.sleep = self._sleeps.append
        self._orig_copy = backup._copy_once

    def tearDown(self):
        backup.time.sleep = self._orig_sleep
        backup._copy_once = self._orig_copy
        self._tmp.cleanup()

    def test_file_backup_ok_and_content_identical(self):
        r = backup.backup_to_timestamped_dir(
            self.src_file, self.backup_root, "state.vscdb")
        self.assertTrue(r["ok"], r)
        self.assertFalse(r["skipped"])
        self.assertIsNone(r["error"])
        dst = os.path.join(self.backup_root, "state.vscdb")
        self.assertEqual(r["destination"], dst)
        with open(self.src_file, "rb") as a, open(dst, "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_tree_backup_ok_and_entries_match(self):
        r = backup.backup_to_timestamped_dir(
            self.src_dir, self.backup_root, "store")
        self.assertTrue(r["ok"], r)
        dst = os.path.join(self.backup_root, "store")
        self.assertTrue(os.path.isfile(os.path.join(dst, "storage.json")))
        self.assertTrue(os.path.isfile(os.path.join(dst, "nested.log")))

    def test_missing_source_reports_skip(self):
        r = backup.backup_to_timestamped_dir(
            os.path.join(self._tmp.name, "nope.json"),
            self.backup_root, "nope.json")
        self.assertFalse(r["ok"])
        self.assertTrue(r["skipped"])
        self.assertIsNone(r["destination"])

    def test_label_may_carry_a_subdirectory(self):
        r = backup.backup_to_timestamped_dir(
            self.src_file, self.backup_root, os.path.join("sub", "state.vscdb"))
        self.assertTrue(r["ok"], r)
        self.assertTrue(os.path.isfile(
            os.path.join(self.backup_root, "sub", "state.vscdb")))

    def test_existing_destination_is_uniquified_not_clobbered(self):
        # 4f308f8 changed the contract: an existing same-label destination is
        # NEVER overwritten (that destroyed pristine pre-run copies); the new
        # backup uniquifies with a -2 suffix instead. The old copy must
        # survive untouched and the report must point at the unique path.
        dst = os.path.join(self.backup_root, "state.vscdb")
        os.makedirs(self.backup_root, exist_ok=True)
        with open(dst, "wb") as f:
            f.write(b"stale-backup-bytes")
        r = backup.backup_to_timestamped_dir(
            self.src_file, self.backup_root, "state.vscdb")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["destination"], dst + "-2")
        with open(dst, "rb") as f:
            self.assertEqual(f.read(), b"stale-backup-bytes")
        with open(dst + "-2", "rb") as f:
            self.assertEqual(f.read(), b"sqlite-bytes" * 64)
        # A third run keeps walking the suffix chain (-3), never touching -1.
        r2 = backup.backup_to_timestamped_dir(
            self.src_file, self.backup_root, "state.vscdb")
        self.assertTrue(r2["ok"], r2)
        self.assertEqual(r2["destination"], dst + "-3")
        with open(dst, "rb") as f:
            self.assertEqual(f.read(), b"stale-backup-bytes")

    def test_transient_lock_retries_then_succeeds(self):
        calls = []

        def flaky(source, destination):
            calls.append(destination)
            if len(calls) < 3:
                raise PermissionError("file in use")
            self._orig_copy(source, destination)

        backup._copy_once = flaky
        r = backup.backup_to_timestamped_dir(
            self.src_file, self.backup_root, "state.vscdb")
        self.assertTrue(r["ok"], r)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(self._sleeps), 2)

    def test_permanent_lock_reports_locked_after_all_attempts(self):
        def locked(source, destination):
            raise PermissionError("being held by another process")

        backup._copy_once = locked
        r = backup.backup_to_timestamped_dir(
            self.src_file, self.backup_root, "state.vscdb", attempts=4,
            backoff_ms=1)
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "locked")
        self.assertIn("locked", r["detail"])
        self.assertEqual(len(self._sleeps), 3)

    def test_verify_mismatch_removes_the_partial_copy(self):
        real_stats = backup._tree_stats

        def lying_stats(path):
            if path.endswith("state.vscdb") and self.backup_root in path:
                return (1, 1)  # lie about the copy
            return real_stats(path)

        backup._tree_stats = lying_stats
        try:
            r = backup.backup_to_timestamped_dir(
                self.src_file, self.backup_root, "state.vscdb")
        finally:
            backup._tree_stats = real_stats
        self.assertFalse(r["ok"])
        self.assertEqual(r["error"], "verify")
        self.assertIn("mismatch", r["detail"])
        self.assertFalse(os.path.exists(
            os.path.join(self.backup_root, "state.vscdb")))


class FilesweepTests(unittest.TestCase):
    """ghost.filesweep — ports of the cursor file-identity helpers."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = self._tmp.name
        self.store = os.path.join(base, "Cookies")
        with open(self.store, "wb") as f:
            f.write(b"binary-store-bytes" * 8)
        self.tree = os.path.join(base, "sentry")
        os.makedirs(os.path.join(self.tree, "sub"))
        for name in ("a.log", "b.log", os.path.join("sub", "c.log")):
            with open(os.path.join(self.tree, name), "w", encoding="utf-8") as f:
                f.write("log" * 10)
        self.backup_root = os.path.join(base, "ID_Backups", "20261017-130000")
        self._sleeps = []
        self._orig_sleep = filesweep.time.sleep
        filesweep.time.sleep = self._sleeps.append

    def tearDown(self):
        filesweep.time.sleep = self._orig_sleep
        self._tmp.cleanup()

    def test_remove_verified_present_and_missing(self):
        r = filesweep.remove_verified(self.store)
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["before"], r["after"]), ("present", "deleted"))
        self.assertFalse(os.path.exists(self.store))
        r2 = filesweep.remove_verified(self.store)
        self.assertTrue(r2["ok"])
        self.assertTrue(r2["skipped"])
        self.assertEqual((r2["before"], r2["after"]), ("missing", "skipped"))

    def test_identity_store_delete_mode_with_backup(self):
        r = filesweep.remove_identity_store(
            self.store, "delete", self.backup_root)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["after"], "deleted")
        self.assertTrue(r["backed_up_to"])
        self.assertFalse(os.path.exists(self.store))
        self.assertTrue(os.path.exists(r["backed_up_to"]))

    def test_identity_store_rename_mode_clobbers_stale_backup(self):
        stale = self.store + ".backup"
        with open(stale, "wb") as f:
            f.write(b"stale")
        r = filesweep.remove_identity_store(
            self.store, "rename", self.backup_root)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["renamed_to"], stale)
        self.assertFalse(os.path.exists(self.store))
        with open(stale, "rb") as f:
            self.assertEqual(f.read(), b"binary-store-bytes" * 8)

    def test_identity_store_missing_is_skip_ok(self):
        r = filesweep.remove_identity_store(
            os.path.join(self._tmp.name, "nope"), "delete", self.backup_root)
        self.assertTrue(r["ok"])
        self.assertTrue(r["skipped"])

    def test_identity_store_relative_label_from_root_path(self):
        root = self._tmp.name
        r = filesweep.remove_identity_store(
            self.store, "delete", self.backup_root, root_path=root)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["backed_up_to"],
                         os.path.join(self.backup_root, "Cookies"))

    def test_sweep_tree_deletes_every_file_and_verifies(self):
        r = filesweep.sweep_tree(self.tree, self.backup_root, "sentry")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["deleted"], 3)
        self.assertEqual(r["failed"], 0)
        self.assertEqual(r["remaining"], 0)
        self.assertTrue(r["backed_up_to"])
        # The PS original removes the emptied dirs and the tree root itself -
        # no trace of the tree may survive the sweep.
        self.assertFalse(os.path.exists(self.tree))

    def test_sweep_tree_missing_is_skip_ok(self):
        r = filesweep.sweep_tree(
            os.path.join(self._tmp.name, "no-tree"),
            self.backup_root, "no-tree")
        self.assertTrue(r["ok"])
        self.assertTrue(r["skipped"])


class WinstoreTests(unittest.TestCase):
    """ghost.winstore — ports of the cursor JSON/text identity helpers."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = self._tmp.name
        self.backup_root = os.path.join(self.base, "ID_Backups", "ts")

    def tearDown(self):
        self._tmp.cleanup()

    def test_machineid_file_write_and_verify(self):
        path = os.path.join(self.base, "machineid")
        with open(path, "w", encoding="utf-8") as f:
            f.write("OLD-ID\n")
        r = winstore.write_machineid_file(
            path, "NEW-ID", self.backup_root, "machineid")
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["before"], r["after"]), ("OLD-ID", "NEW-ID"))
        self.assertTrue(r["backed_up_to"])
        with open(path, "r", encoding="utf-8") as f:
            self.assertEqual(f.read(), "NEW-ID")

    def test_machineid_file_creates_missing(self):
        path = os.path.join(self.base, "Cursor", "machineid")
        r = winstore.write_machineid_file(
            path, "NEW-ID", self.backup_root, "machineid")
        self.assertTrue(r["ok"], r)
        self.assertIsNone(r["before"])
        self.assertIsNone(r["backed_up_to"])

    def test_salt_rotation_creates_nested_dicts(self):
        path = os.path.join(self.base, "Preferences")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"other": 1}')
        r = winstore.rotate_device_id_salt(path, self.backup_root, "Preferences")
        self.assertTrue(r["ok"], r)
        self.assertIsNone(r["before"])
        self.assertRegex(r["after"], r"^[0-9a-f]{32}$")
        with open(path, "r", encoding="utf-8-sig") as f:
            content = json.load(f)
        self.assertEqual(content["electron"]["media"]["device_id_salt"],
                         r["after"])

    def test_salt_rotation_replaces_existing_and_verifies(self):
        path = os.path.join(self.base, "Preferences")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"electron": {"media": {"device_id_salt": "OLD"}}}')
        r = winstore.rotate_device_id_salt(
            path, self.backup_root, "Preferences", new_salt="a" * 32)
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["before"], r["after"]), ("OLD", "a" * 32))
        self.assertTrue(r["backed_up_to"])

    def test_salt_rotation_missing_file_is_skip_ok(self):
        r = winstore.rotate_device_id_salt(
            os.path.join(self.base, "nope"), self.backup_root, "nope")
        self.assertTrue(r["ok"])
        self.assertTrue(r["skipped"])

    def test_remove_json_keys_dotted_path(self):
        path = os.path.join(self.base, "Local State")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"os_crypt": {"encrypted_key": "SECRET"}, "keep": 1}')
        r = winstore.remove_json_keys(
            path, ["os_crypt.encrypted_key"], self.backup_root, "Local State")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["before"], {"os_crypt.encrypted_key": "present"})
        self.assertEqual(r["removed"], ["os_crypt.encrypted_key"])
        with open(path, "r", encoding="utf-8-sig") as f:
            content = json.load(f)
        self.assertNotIn("encrypted_key", content["os_crypt"])
        self.assertEqual(content["keep"], 1)

    def test_remove_json_keys_missing_walk_is_skip_ok(self):
        path = os.path.join(self.base, "Local State")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"keep": 1}')
        r = winstore.remove_json_keys(
            path, ["os_crypt.encrypted_key"], self.backup_root, "Local State")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["before"], {"os_crypt.encrypted_key": "missing"})

    def test_remove_json_keys_missing_file_is_skip_ok(self):
        r = winstore.remove_json_keys(
            os.path.join(self.base, "nope"), ["a.b"],
            self.backup_root, "nope")
        self.assertTrue(r["ok"])
        self.assertTrue(r["skipped"])


class DevinPrepTests(unittest.TestCase):
    """The Phase 3 devin-migration core additions: generalized delete_secrets,
    JSONC argv patcher, raw-text scrubber, dotted JSON set."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = self._tmp.name
        self.backup_root = os.path.join(self.base, "ID_Backups", "ts")
        self._sleeps = []
        self._orig_sleep = filesweep.time.sleep
        filesweep.time.sleep = self._sleeps.append

    def tearDown(self):
        filesweep.time.sleep = self._orig_sleep
        self._tmp.cleanup()

    def _secret_db(self, rows):
        db = os.path.join(self.base, "state.vscdb")
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)")
        for k, v in rows:
            conn.execute("INSERT INTO ItemTable VALUES (?, ?)", (k, v))
        conn.commit()
        conn.close()
        return db

    def test_delete_secrets_generalized_with_escape(self):
        db = self._secret_db([
            ("codeium.windsurf-windsurf_auth", "TOKEN"),
            ("windsurf_auth-extra", "TOKEN2"),
            ("windsurfXauth-keep", "NOT-SECRET"),  # X is NOT a literal _
            ("keep-me", "x"),
        ])
        r = sqlite_keys.delete_secrets(
            db,
            exact_keys=["codeium.windsurf-windsurf_auth"],
            like_patterns=["windsurf\\_auth-%"],
            escape="\\")
        self.assertEqual(r["survivors"], [0, 0])
        self.assertIn("windsurf_auth-extra", r["deleted"])
        self.assertNotIn("windsurfXauth-keep", r["deleted"])
        conn = sqlite3.connect(db)
        remaining = conn.execute(
            "SELECT key FROM ItemTable ORDER BY key").fetchall()
        conn.close()
        self.assertEqual([row[0] for row in remaining],
                         ["keep-me", "windsurfXauth-keep"])

    def test_delete_secrets_defaults_unchanged(self):
        db = self._secret_db([
            ("secret://aicoding.auth.t", "x"),
            ("gituser", "u"),
        ])
        r = sqlite_keys.delete_secrets(db)
        self.assertEqual(r["survivors"], [0, 0, 0])

    def _argv(self):
        path = os.path.join(self.base, "argv.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write('// comments must survive\n{\n  '
                    '"crash-reporter-id": "OLD-ID",\n'
                    '  "user-data-dir": "C:\\\\Users\\\\FOTE\\\\x"\n}')
        return path

    def test_patch_argv_json_replaces_and_scrubs(self):
        path = self._argv()
        r = winstore.patch_argv_json(
            path, self.backup_root, "argv.json",
            new_id="NEW-ID", username="FOTE")
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["before"], r["after"]), ("OLD-ID", "NEW-ID"))
        self.assertTrue(r["user_dir_scrubbed"])
        raw = open(path, encoding="utf-8-sig").read()
        self.assertIn("// comments must survive", raw)  # JSONC preserved
        self.assertNotIn("FOTE", raw)
        self.assertIn("RESET", raw)

    def test_patch_argv_json_inserts_missing_key(self):
        path = os.path.join(self.base, "argv.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{\n  "disable-hardware-acceleration": true\n}')
        r = winstore.patch_argv_json(path, self.backup_root, "argv.json",
                                     new_id="NEW-ID")
        self.assertTrue(r["ok"], r)
        self.assertIsNone(r["before"])
        self.assertEqual(r["after"], "NEW-ID")

    def test_patch_argv_json_missing_file_is_skip_ok(self):
        r = winstore.patch_argv_json(
            os.path.join(self.base, "nope"), self.backup_root, "nope")
        self.assertTrue(r["ok"])
        self.assertTrue(r["skipped"])

    def test_replace_text_scrubs_and_verifies(self):
        path = os.path.join(self.base, "Preferences")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"profile": "C:\\\\Users\\\\FOTE\\\\Cursor"}')
        r = winstore.replace_text(path, "FOTE", "RESET",
                                  self.backup_root, "Preferences")
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["before"], r["after"]), ("leaked", "clean"))
        self.assertTrue(r["backed_up_to"])

    def test_replace_text_clean_file_needs_no_backup(self):
        path = os.path.join(self.base, "Preferences")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"profile": "clean"}')
        r = winstore.replace_text(path, "FOTE", "RESET",
                                  self.backup_root, "Preferences")
        self.assertTrue(r["ok"], r)
        self.assertEqual((r["before"], r["after"]), ("clean", "clean"))
        self.assertIsNone(r["backed_up_to"])

    def test_set_json_path_dotted(self):
        path = os.path.join(self.base, "config.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"devin": {"org_id": "ORG-123"}}')
        r = winstore.set_json_path(path, "devin.org_id", "",
                                   self.backup_root, "config.json")
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["before"], "ORG-123")
        with open(path, "r", encoding="utf-8-sig") as f:
            self.assertEqual(json.load(f)["devin"]["org_id"], "")

    def test_set_json_path_skip_if_empty(self):
        path = os.path.join(self.base, "config.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"devin": {"org_id": ""}}')
        r = winstore.set_json_path(path, "devin.org_id", "NEW",
                                   self.backup_root, "config.json",
                                   skip_if_empty=True)
        self.assertTrue(r["ok"], r)
        self.assertTrue(r["skipped"])
        with open(path, "r", encoding="utf-8-sig") as f:
            self.assertEqual(json.load(f)["devin"]["org_id"], "")


class RemoveJsonKeysPrefixTests(unittest.TestCase):
    """remove_json_keys prefix removal — the Trae 'iCubeAuthInfo://*' auth
    keys (URLs inside key names cannot be addressed as dotted paths)."""

    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="ghost_prefix_")
        self.backup_root = os.path.join(self.base, "ID_Backups", "ts")

    def test_prefix_removes_top_level_keys_only(self):
        path = os.path.join(self.base, "storage.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps({
                "iCubeAuthInfo://a.b": "tok",
                "xiCubeAuthInfo://decoy": "keep",
                "nested": {"iCubeAuthInfo://inner": "keep too"}}))
        r = winstore.remove_json_keys(path, [], self.backup_root,
                                      "storage.json",
                                      prefixes=["iCubeAuthInfo://"])
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["removed_prefixes"], {"iCubeAuthInfo://": 1})
        with open(path, "r", encoding="utf-8-sig") as f:
            content = json.load(f)
        self.assertNotIn("iCubeAuthInfo://a.b", content)
        self.assertIn("xiCubeAuthInfo://decoy", content)
        self.assertEqual(
            content["nested"]["iCubeAuthInfo://inner"], "keep too")

    def test_absent_prefix_is_ok_without_write(self):
        path = os.path.join(self.base, "storage.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write('{"other": 1}')
        r = winstore.remove_json_keys(path, [], self.backup_root,
                                      "storage.json",
                                      prefixes=["iCubeAuthInfo://"])
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["removed_prefixes"], {"iCubeAuthInfo://": 0})


if __name__ == "__main__":
    unittest.main()
