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

from ghost import audit, identity, json_patch, restore, sqlite_keys  # noqa: E402


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

    def test_connect_failure_returns_error_contract(self):
        # A directory as the db path -> sqlite3.Error on connect, which the
        # bridge contract reports as {"deleted": 0, "error": ...} exit 0.
        result = sqlite_keys.clear_cli_telemetry(self._tmp.name)
        self.assertEqual(result["deleted"], 0)
        self.assertIn("error", result)


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
        with open(path, "r", encoding="utf-8") as f:
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


if __name__ == "__main__":
    unittest.main()
