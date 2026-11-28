"""Regression tests for AutoClaw2 re-sync and non-destructive cleanup."""

from contextlib import closing
import os
from pathlib import Path
import sqlite3
from unittest import skipUnless

from test_ghost_autoclaw2 import UUID4, _PatchedHome
from ghost import autoclaw2 as core, autoclaw2_history as history


def _append_entry(db_path, sid, text):
    with closing(sqlite3.connect(db_path)) as conn, conn:
        (run_id,) = conn.execute("SELECT run_id FROM work_runs WHERE session_id = ?", (sid,)).fetchone()
        conn.execute(
            "INSERT INTO neutral_session_entries (session_id, entry_id, parent_entry_id,"
            " session_seq, run_id, entry_type, payload, committed_at) VALUES (?,?,?,?,?,?,?,?)",
            (sid, run_id + ":continuation", run_id + ":answer", 3, run_id, "assistant", text,
             "2026-01-01T00:02:00.000Z"))


class LineageSyncTests(_PatchedHome):
    def test_round_trip_and_second_pass_do_not_create_another_copy(self):
        sid, _ = self.fixture.session("Primary", title="/goal")
        payload = {"source": "Primary", "target": "c1", "session_id": sid}
        copied = core.chat_import(payload)
        self.assertEqual(copied["status"], "ok")
        back = {"source": "c1", "target": "Primary", "session_id": copied["new_session_id"]}
        for _ in range(2):
            result = core.chat_import(back)
            self.assertEqual((result["reason"], result["new_session_id"]), ("already-imported", sid))
            self.assertEqual(core.chat_import(payload)["reason"], "already-imported")
        self.assertEqual(core.chat_inventory_for_profile({"profile": "Primary"})["session_count"], 1)
        self.assertEqual(core.chat_inventory_for_profile({"profile": "c1"})["session_count"], 1)

    def test_continued_copy_is_preserved_and_default_sync_does_not_export_it(self):
        sid, _ = self.fixture.session("Primary", title="/goal")
        copy = core.chat_import({"source": "Primary", "target": "c1", "session_id": sid})
        copy_id = copy["new_session_id"]
        _append_entry(self.fixture.db_paths["c1"], copy_id, '{"data":{"text":"Blue branch"}}')
        back = {"source": "c1", "target": "Primary", "session_id": copy_id}
        self.assertEqual(core.chat_import(back)["reason"], "lineage-present")
        branch = core.chat_import({**back, "allow_branch": True})
        self.assertEqual(branch["status"], "ok")
        self.assertIn("branch c1, 3 entries", branch["title"])
        self.assertNotIn("[import] [import]", branch["title"])
        self.assertEqual(core.chat_import({**back, "allow_branch": True})["reason"], "already-imported")
        self.assertEqual(core.chat_inventory_for_profile({"profile": "Primary"})["session_count"], 2)

    def test_old_account_sidecar_does_not_block_active_account(self):
        sid, _ = self.fixture.session("Primary")
        payload = {"source": "Primary", "target": "c1", "session_id": sid}
        first = core.chat_import(payload)
        previous_db = Path(self.fixture.db_paths["c1"])
        old_bytes = previous_db.read_bytes()
        self.fixture._make_profile("c1", core.profile_path("c1"))
        self.assertEqual(core.chat_inventory_for_profile({"profile": "c1"})["source_imports"], [])
        second = core.chat_import(payload)
        self.assertEqual(second["status"], "ok")
        self.assertNotEqual(first["new_session_id"], second["new_session_id"])
        self.assertEqual(previous_db.read_bytes(), old_bytes)
        self.assertEqual(core.chat_import(payload)["reason"], "already-imported")
        with self.assertRaises(core.Refusal) as ctx:
            core.chat_revert({"target": "c1", "import_id": first["import_id"]})
        self.assertEqual(ctx.exception.code, "import-account-mismatch")

    def test_signed_out_with_leftover_db_does_not_get_imported_into(self):
        sid, _ = self.fixture.session("Primary")
        os.unlink(Path(core.profile_path("c1")) / "device/active-product-account.json")
        with self.assertRaises(core.Refusal) as ctx:
            core.chat_import({"source": "Primary", "target": "c1", "session_id": sid})
        self.assertEqual(ctx.exception.code, "active-account-missing")

    def test_archived_target_counts_as_present_but_cannot_be_a_source(self):
        sid, _ = self.fixture.session("Primary")
        payload = {"source": "Primary", "target": "c1", "session_id": sid}
        copied = core.chat_import(payload)["new_session_id"]
        with closing(sqlite3.connect(self.fixture.db_paths["c1"])) as conn, conn:
            conn.execute("UPDATE work_sessions SET archived_at = ? WHERE session_id = ?", (core._iso_now(), copied))
        self.assertEqual(core.chat_import(payload)["reason"], "already-imported")
        with self.assertRaises(core.Refusal) as ctx:
            core.chat_import({"source": "c1", "target": "Primary", "session_id": copied})
        self.assertEqual(ctx.exception.code, "inactive-session")


class ReconcileTests(_PatchedHome):
    def _legacy_group(self, first_has_extra_artifact=False):
        root_sid = UUID4()
        base, _ = self.fixture.session("c1", title="[import] /goal", with_artifact=first_has_extra_artifact)
        branch_a, _ = self.fixture.session("c1", title="[import] /goal", with_artifact=False)
        branch_b, _ = self.fixture.session("c1", title="[import] /goal", with_artifact=False)
        for index, sid in enumerate((branch_a, branch_b)):
            _append_entry(self.fixture.db_paths["c1"], sid, '{"branch":%d}' % index)
        unrelated, _ = self.fixture.session("c1", title="[import] /goal")
        core._write_sidecar(core.profile_path("c1"), {"imports": [
            {"source_profile": "Primary", "source_session_id": root_sid, "new_session_id": sid,
             "import_id": UUID4(), "original_title": "/goal", "title_tag": "[import] "}
            for sid in (base, branch_a, branch_b)
        ]})
        return base, branch_a, branch_b, unrelated

    def test_archives_only_covered_copy_and_labels_unique_branches(self):
        base, branch_a, branch_b, unrelated = self._legacy_group()
        db_path = Path(self.fixture.db_paths["c1"])
        before = db_path.read_bytes()
        preview = history.reconcile({"target": "c1"})
        self.assertEqual(preview["status"], "dry-run")
        self.assertEqual(db_path.read_bytes(), before)
        self.assertFalse((Path(core.profile_path("c1")) / core.BACKUP_DIR_NAME).exists())
        targets = {row["session_id"]: row["kind"] for row in preview["actions"]}
        self.assertEqual(targets, {base: "archive", branch_a: "rename", branch_b: "rename"})
        apply = history.reconcile({"target": "c1", "apply": True, "plan_id": preview["plan_id"]})
        self.assertEqual(apply["status"], "ok")
        self.assertTrue(Path(apply["backup"]).is_file())
        with closing(sqlite3.connect(db_path)) as conn:
            rows = dict(conn.execute("SELECT session_id, archived_at FROM work_sessions WHERE deleted_at IS NULL"))
            self.assertEqual(len(rows), 4)
            self.assertIsNotNone(rows[base])
            self.assertTrue(all(rows[sid] is None for sid in (branch_a, branch_b, unrelated)))
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM neutral_session_entries").fetchone()[0], 10)
        self.assertEqual(history.reconcile({"target": "c1"})["actions"], [])

    def test_snapshot_with_unique_artifact_is_not_archived(self):
        base, *_ = self._legacy_group(first_has_extra_artifact=True)
        actions = history.reconcile({"target": "c1"})["actions"]
        self.assertTrue(actions)
        self.assertEqual({action["kind"] for action in actions}, {"rename"})
        self.assertTrue(any(action["session_id"] == base for action in actions))

    def test_stale_preview_refuses_before_backup(self):
        base, *_ = self._legacy_group()
        preview = history.reconcile({"target": "c1"})
        with closing(sqlite3.connect(self.fixture.db_paths["c1"])) as conn, conn:
            conn.execute("UPDATE work_sessions SET title = ? WHERE session_id = ?", ("User title", base))
        with self.assertRaises(core.Refusal) as ctx:
            history.reconcile({"target": "c1", "apply": True, "plan_id": preview["plan_id"]})
        self.assertEqual(ctx.exception.code, "chat-plan-changed")
        self.assertFalse((Path(core.profile_path("c1")) / core.BACKUP_DIR_NAME).exists())

    @skipUnless(os.name == "nt", "Windows profile lockfile fixture")
    def test_running_target_can_preview_but_cannot_apply(self):
        self._legacy_group()
        handle = self.fixture.hold_lock("c1")
        try:
            preview = history.reconcile({"target": "c1"})
            with self.assertRaises(core.Refusal) as ctx:
                history.reconcile({"target": "c1", "apply": True, "plan_id": preview["plan_id"]})
            self.assertEqual(ctx.exception.code, "target-running")
        finally:
            self.fixture.release_lock(handle)
