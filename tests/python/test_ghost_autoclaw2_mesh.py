"""AutoClaw2 mesh fixtures use real SQLite and never write to real profiles."""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
from unittest import mock

from test_ghost_autoclaw2 import UUID4, _PatchedHome
from ghost import autoclaw2 as core, autoclaw2_mesh as mesh


def _append(db, sid, text, stamp, status="completed"):
    with closing(sqlite3.connect(db)) as conn, conn:
        seq = conn.execute("SELECT MAX(session_seq) FROM neutral_session_entries WHERE session_id=?", (sid,)).fetchone()[0]
        parent = conn.execute("SELECT entry_id FROM neutral_session_entries WHERE session_id=? AND session_seq=?",
                              (sid, seq)).fetchone()[0]
        accept = conn.execute("SELECT MAX(accept_order) FROM work_runs").fetchone()[0]
        run = UUID4()
        request, answer = f"{run}:request", f"{run}:answer"
        conn.execute("INSERT INTO work_runs(run_id,session_id,status,text,accept_order,request_entry_id,answer_entry_id,"
                     "created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)",
                     (run, sid, status, text, accept + 1, request, answer, stamp, stamp))
        for offset, (kind, entry_id, previous) in enumerate((("request", request, parent), ("answer", answer, request)), 1):
            conn.execute("INSERT INTO neutral_session_entries VALUES (?,?,?,?,?,?,?,?)",
                         (sid, entry_id, previous, seq + offset, run, kind,
                          json.dumps({"data": {"text": text + " " + kind}}), stamp))
        conn.execute("INSERT INTO work_events(event_id,run_id,session_id,run_seq,type,payload_json,created_at)"
                     " VALUES (?,?,?,?,?,?,?)", (UUID4(), run, sid, 1, "turn_finished", "{}", stamp))
        conn.execute("UPDATE neutral_session_heads SET next_session_seq=?,conversation_head_entry_id=?,"
                     " conversation_session_seq=?,conversation_run_id=?, settled_answer_entry_id=?,"
                     " settled_session_seq=?,settled_run_id=?,entry_count=?,updated_at=? WHERE session_id=?",
                     (seq + 3, answer, seq + 2, run, answer, seq + 2, run, seq + 2, stamp, sid))
        conn.execute("UPDATE work_sessions SET updated_at=? WHERE session_id=?", (stamp, sid))


class MeshTests(_PatchedHome):
    def setUp(self):
        super().setUp()
        probe = mock.patch.object(mesh, "_busy_profiles", return_value=set())
        self.busy = probe.start()
        self.addCleanup(probe.stop)

    def _sync(self, apply=True, targets=("Primary", "c1")):
        return mesh.sync({"apply": apply, "targets": list(targets)})

    def _rows(self, profile):
        with closing(sqlite3.connect(self.fixture.db_paths[profile])) as conn:
            return conn.execute("SELECT session_id,archived_at FROM work_sessions ORDER BY session_id").fetchall()

    def _digest(self, profile, sid):
        with closing(core.ro_connect(self.fixture.db_paths[profile])) as conn:
            return mesh.shape(core._session_tree(conn, sid))["key"]

    def test_clone_continuation_fast_forwards_the_same_original_and_second_pass_is_noop(self):
        original, _ = self.fixture.session("Primary", title="/goal")
        initial = self._sync()
        self.assertEqual(initial["targets"]["c1"]["actions"], {"create": 1})
        copy_id = self._rows("c1")[0][0]
        _append(self.fixture.db_paths["c1"], copy_id, "from Blue", "2026-01-03T00:00:00.000Z")
        result = self._sync()
        self.assertEqual(result["targets"]["Primary"]["actions"], {"append": 1})
        self.assertEqual(result["targets"]["Primary"]["status"], "applied")
        self.assertEqual(self._rows("Primary"), [(original, None)])
        self.assertEqual(self._digest("Primary", original), self._digest("c1", copy_id))
        before = {p: Path(self.fixture.db_paths[p]).read_bytes() for p in ("Primary", "c1")}
        again = self._sync()
        for profile in before:
            self.assertEqual(again["targets"][profile]["status"], "up-to-date")
            self.assertEqual(Path(self.fixture.db_paths[profile]).read_bytes(), before[profile])

    def test_real_forks_remain_recoverable_and_only_latest_is_visible(self):
        original, _ = self.fixture.session("Primary", title="same /goal")
        self._sync()
        clone_id = self._rows("c1")[0][0]
        _append(self.fixture.db_paths["Primary"], original, "one fork", "2026-01-03T00:00:00.000Z")
        _append(self.fixture.db_paths["c1"], clone_id, "other fork", "2026-01-04T00:00:00.000Z")
        older = self._digest("Primary", original)
        newest = self._digest("c1", clone_id)
        r = self._sync()
        self.assertEqual(r["status"], "ok")
        for profile in ("Primary", "c1"):
            rows = [(self._digest(profile, sid), bool(archived)) for sid, archived in self._rows(profile)]
            self.assertCountEqual(rows, [(older, True), (newest, False)])
            self.assertEqual(self._sync(apply=False)["targets"][profile]["actions"], {})

    def test_open_target_queues_without_writing_even_when_lockfile_absent(self):
        self.fixture.session("Primary")
        self.busy.return_value = {"c1"}
        path = Path(self.fixture.db_paths["c1"])
        original = path.read_bytes()
        r = self._sync()
        self.assertEqual(r["targets"]["c1"]["status"], "queued")
        self.assertEqual(r["targets"]["c1"]["reason"], "target-running")
        self.assertTrue(r["targets"]["c1"]["open"])
        self.assertFalse(r["targets"]["c1"]["ready"])
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse((Path(core.profile_path("c1")) / core.BACKUP_DIR_NAME).exists())
        self.busy.return_value = set()
        self.assertEqual(self._sync()["targets"]["c1"]["status"], "applied")

    def test_app_opening_during_write_rolls_back(self):
        self.fixture.session("Primary")
        self.busy.side_effect = [set(), set(), {"c1"}]
        r = self._sync(targets=("c1",))
        self.assertEqual(r["targets"]["c1"]["status"], "queued")
        self.assertEqual(self._rows("c1"), [])

    def test_working_source_is_not_published_until_settled(self):
        original, run = self.fixture.session("Primary")
        self._sync()
        with closing(sqlite3.connect(self.fixture.db_paths["Primary"])) as conn, conn:
            conn.execute("UPDATE work_runs SET status='running' WHERE run_id=?", (run,))
        self.busy.return_value = {"Primary"}
        preview = self._sync(apply=False)
        self.assertGreater(preview["unsettled_or_invalid_sources"], 0)
        self.assertEqual(preview["targets"]["c1"]["actions"], {})

    def test_dormant_account_is_read_only_and_two_new_chats_use_one_backup(self):
        self.fixture.session("Primary", title="same title")
        self.fixture.session("Primary", title="same title")
        self.fixture.session("Primary", external_provider="telegram")
        old = Path(self.fixture.db_paths["Primary"])
        old_before = old.read_bytes()
        self.fixture._make_profile("Primary", core.profile_path("Primary"))
        preview = self._sync(apply=False)
        self.assertEqual(preview["lineages"], 2)
        self.assertEqual(preview["im_excluded"], 1)
        result = self._sync()
        for profile in ("c1", "Primary"):
            self.assertEqual(result["targets"][profile]["actions"], {"create": 2})
            self.assertEqual(len(self._rows(profile)), 2)
            root = Path(core.profile_path(profile)) / core.BACKUP_DIR_NAME
            self.assertEqual(len(list(root.glob("*-chat-mesh-*/runtime.sqlite"))), 1)
        self.assertEqual(old_before, old.read_bytes())

    def test_open_current_profile_is_not_ready_for_a_new_launch(self):
        self.fixture.session("Primary")
        self._sync()
        self.busy.return_value = {"Primary"}
        report = self._sync()["targets"]
        self.assertEqual(report["Primary"]["status"], "up-to-date")
        self.assertFalse(report["Primary"]["ready"])
        self.assertTrue(report["c1"]["ready"])

    def test_old_counts_are_removed_only_from_tool_titles_and_only_when_closed(self):
        self.fixture.session("Primary", title="/goal")
        native_sid, _ = self.fixture.session("c1", title="Native title (12 entries)")
        self._sync()
        profile = Path(core.profile_path("c1"))
        record = core._read_sidecar(str(profile))["imports"][0]
        sid = record["new_session_id"]
        prefix = "[import] /goal"
        old_title = prefix + " (603 entries, " + sid[:8] + ")"
        path = self.fixture.db_paths["c1"]
        with closing(sqlite3.connect(path)) as conn, conn:
            conn.execute("UPDATE work_sessions SET title=? WHERE session_id=?", (old_title, sid))
            updated_at = conn.execute("SELECT updated_at FROM work_sessions WHERE session_id=?", (sid,)).fetchone()[0]
        entry_key = self._digest("c1", sid)
        self.assertEqual(self._sync(apply=False)["targets"]["c1"]["actions"], {})
        audit_path = profile / ".autoclaw2-sync-audit.jsonl"
        event = {"script": "sync_autoclaw2_chats", "status": "reconciled", "account_dir": "old-account",
                 "actions": [{"kind": "rename", "session_id": sid}]}
        audit_path.write_text(json.dumps(event) + "\n", encoding="utf-8-sig")
        self.assertEqual(self._sync(apply=False)["targets"]["c1"]["actions"], {})
        event["account_dir"] = record["target_account"]
        audit_path.write_text(json.dumps(event) + "\n", encoding="utf-8-sig")
        self.busy.return_value = {"c1"}
        self.assertEqual(self._sync()["targets"]["c1"]["status"], "queued")
        self.busy.return_value = set()
        self.assertEqual(self._sync()["targets"]["c1"]["actions"], {"normalize-title": 1})
        with closing(sqlite3.connect(path)) as conn:
            self.assertEqual(conn.execute("SELECT title,updated_at FROM work_sessions WHERE session_id=?", (sid,)).fetchone(),
                             (prefix, updated_at))
            self.assertEqual(conn.execute("SELECT title FROM work_sessions WHERE session_id=?", (native_sid,)).fetchone(),
                             ("Native title (12 entries)",))
        self.assertEqual(self._digest("c1", sid), entry_key)
        self.assertEqual(self._sync()["targets"]["c1"]["status"], "up-to-date")

    def test_user_renamed_import_is_not_changed_by_old_reconcile_evidence(self):
        self.fixture.session("Primary", title="/goal")
        self._sync()
        root = Path(core.profile_path("c1"))
        rec = core._read_sidecar(str(root))["imports"][0]
        sid = rec["new_session_id"]
        with closing(sqlite3.connect(self.fixture.db_paths["c1"])) as conn, conn:
            conn.execute("UPDATE work_sessions SET title=? WHERE session_id=?", ("My title (603 entries)", sid))
        (root / ".autoclaw2-sync-audit.jsonl").write_text(json.dumps({
            "script": "sync_autoclaw2_chats", "status": "reconciled", "account_dir": rec["target_account"],
            "actions": [{"kind": "rename", "session_id": sid}],
        }) + "\n", encoding="utf-8-sig")
        self.assertEqual(self._sync()["targets"]["c1"]["actions"], {})

    def test_user_archived_conversation_is_not_resurrected(self):
        self.fixture.session("Primary")
        self._sync()
        clone_id = self._rows("c1")[0][0]
        with closing(sqlite3.connect(self.fixture.db_paths["c1"])) as conn, conn:
            conn.execute("UPDATE work_sessions SET archived_at=? WHERE session_id=?", ("local-archive", clone_id))
        r = self._sync()
        self.assertEqual(r["targets"]["c1"]["status"], "up-to-date")
        self.assertEqual(self._rows("c1"), [(clone_id, "local-archive")])
