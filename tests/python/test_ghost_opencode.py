"""Tests for the OpenCode chat-sync core verbs (ghost/opencode.py).

The fixture dbs mirror the LIVE schema mined 2026-11-19 from
~/.local/share/opencode/opencode.db (58 sessions / 2772 messages):
session_v2 -> project FK, session_message JSON `data` payload,
session_part + blob/blob_ref (declared but empty in the observed schema),
instruction_blob/entry/state, and the never-copy app tables (account,
credential, kv, event*, job, session_inbox, automation, permission,
project_directory, worktree, migration). The FK declarations matter: the
import relies on ON DELETE CASCADE for the revert path, exactly like the
real schema (fk_session_message_session_id_session_v2_id_fk etc.).
"""

import base64
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..",
                                "src", "python"))

from ghost import opencode  # noqa: E402
from ghost.opencode import Refusal  # noqa: E402

SCHEMA = """
CREATE TABLE `account` (
          `id` text PRIMARY KEY,
          `email` text NOT NULL,
          `url` text NOT NULL,
          `access_token` text NOT NULL,
          `refresh_token` text NOT NULL,
          `token_expiry` integer,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL
        );
CREATE TABLE `blob` (
          `hash` text PRIMARY KEY,
          `mime` text NOT NULL,
          `bytes` integer NOT NULL,
          `width` integer,
          `height` integer,
          `data` blob NOT NULL,
          `time_created` integer NOT NULL
        );
CREATE TABLE `blob_ref` (
          `session_id` text NOT NULL,
          `message_id` text NOT NULL,
          `hash` text NOT NULL,
          `seq` integer NOT NULL,
          CONSTRAINT `blob_ref_pk` PRIMARY KEY(`session_id`, `message_id`, `hash`),
          CONSTRAINT `fk_blob_ref_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE,
          CONSTRAINT `fk_blob_ref_hash_blob_hash_fk` FOREIGN KEY (`hash`) REFERENCES `blob`(`hash`) ON DELETE CASCADE
        );
CREATE TABLE `instruction_blob` (
          `hash` text PRIMARY KEY,
          `value` text
        );
CREATE TABLE `instruction_entry` (
          `session_id` text NOT NULL,
          `key` text NOT NULL,
          `value` text,
          `removed` integer DEFAULT false NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          CONSTRAINT `instruction_entry_pk` PRIMARY KEY(`session_id`, `key`),
          CONSTRAINT `fk_instruction_entry_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
CREATE TABLE `instruction_state` (
          `session_id` text PRIMARY KEY,
          `epoch_start` integer NOT NULL,
          `through_seq` integer NOT NULL,
          `initial_values` text NOT NULL,
          `current_values` text NOT NULL,
          CONSTRAINT `fk_instruction_state_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
CREATE TABLE `kv` (
          `key` text PRIMARY KEY,
          `value` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL
        );
CREATE TABLE `project` (
          `id` text PRIMARY KEY,
          `worktree` text NOT NULL,
          `vcs` text,
          `name` text,
          `icon_url` text,
          `icon_url_override` text,
          `icon_color` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `time_initialized` integer,
          `time_active` integer DEFAULT 0 NOT NULL,
          `time_archived` integer,
          `sandboxes` text NOT NULL,
          `commands` text
        );
CREATE TABLE `session_inbox` (
          `id` text PRIMARY KEY,
          `session_id` text NOT NULL,
          `type` text NOT NULL,
          `payload` text NOT NULL,
          `delivery` text NOT NULL,
          `enqueued_seq` integer NOT NULL,
          `time_created` integer NOT NULL
        );
CREATE TABLE `session_message` (
          `id` text PRIMARY KEY,
          `session_id` text NOT NULL,
          `type` text NOT NULL,
          `seq` integer NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `fk_session_message_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
CREATE TABLE `session_part` (
          `message_id` text NOT NULL,
          `session_id` text NOT NULL,
          `ordinal` integer NOT NULL,
          `type` text NOT NULL,
          `call_id` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `session_part_pk` PRIMARY KEY(`message_id`, `ordinal`),
          CONSTRAINT `fk_session_part_message_id_session_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `session_message`(`id`) ON DELETE CASCADE,
          CONSTRAINT `fk_session_part_session_id_session_v2_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session_v2`(`id`) ON DELETE CASCADE
        );
CREATE TABLE `session_v2` (
          `id` text PRIMARY KEY,
          `project_id` text NOT NULL,
          `workspace_id` text,
          `parent_id` text,
          `fork_session_id` text,
          `fork_boundary` text,
          `slug` text NOT NULL,
          `directory` text NOT NULL,
          `path` text,
          `title` text,
          `version` text NOT NULL,
          `share_url` text,
          `summary_additions` integer,
          `summary_deletions` integer,
          `summary_files` integer,
          `summary_diffs` text,
          `metadata` text,
          `cost` real DEFAULT 0 NOT NULL,
          `tokens_input` integer DEFAULT 0 NOT NULL,
          `tokens_output` integer DEFAULT 0 NOT NULL,
          `tokens_reasoning` integer DEFAULT 0 NOT NULL,
          `tokens_cache_read` integer DEFAULT 0 NOT NULL,
          `tokens_cache_write` integer DEFAULT 0 NOT NULL,
          `revert` text,
          `permission` text,
          `agent` text,
          `model` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `time_idle` integer,
          `time_viewed` integer,
          `idle_outcome` text,
          `time_compacting` integer,
          `time_archived` integer,
          `time_suspended` integer,
          `resume_attempts` integer DEFAULT 0 NOT NULL,
          `time_busy` integer,
          CONSTRAINT `fk_session_v2_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
        );
"""

PROJECT_ID = "e4ece93c6ad0a379021428cc024f1e4a5d911ba4"  # live-mined shape
WORKTREE = "C:/programming/github/unban-machine-id"


def _b64(obj):
    return base64.b64encode(json.dumps(obj).encode("utf-8")).decode("ascii")


def _mk_db(path, with_project=True, sessions=(), messages=(), parts=(),
           blob_refs=(), blobs=(), inst_state=(), inst_entry=(),
           inst_blobs=(), kv_rows=(), accounts=()):
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    if with_project:
        conn.execute(
            "INSERT INTO project (id, worktree, vcs, sandboxes,"
            " time_created, time_updated, time_active) VALUES"
            " (?, ?, 'git', '[]', 1, 1, 0)", (PROJECT_ID, WORKTREE))
    for s in sessions:
        conn.execute(
            "INSERT INTO session_v2 (id, project_id, slug, directory,"
            " version, title, agent, time_created, time_updated)"
            " VALUES (?, ?, ?, ?, '1', ?, 'build', ?, ?)",
            (s["id"], s.get("project_id", PROJECT_ID), s["slug"],
             s.get("directory", WORKTREE), s.get("title"),
             s.get("time_created", 1), s.get("time_updated", 1)))
        if s.get("parent_id"):
            # parent may be inserted after the child in this helper; fix up
            pass
    for s in sessions:
        if s.get("parent_id"):
            conn.execute("UPDATE session_v2 SET parent_id = ? WHERE id = ?",
                         (s["parent_id"], s["id"]))
    for m in messages:
        conn.execute(
            "INSERT INTO session_message (id, session_id, type, seq,"
            " time_created, time_updated, data) VALUES (?, ?, ?, ?, 1, 1, ?)",
            (m["id"], m["session_id"], m["type"], m["seq"], m["data"]))
    for p in parts:
        conn.execute(
            "INSERT INTO session_part (message_id, session_id, ordinal,"
            " type, time_created, time_updated, data) VALUES"
            " (?, ?, ?, 'text', 1, 1, ?)",
            (p["message_id"], p["session_id"], p["ordinal"], p["data"]))
    for b in blobs:
        conn.execute(
            "INSERT INTO blob (hash, mime, bytes, data, time_created)"
            " VALUES (?, 'image/png', 4, ?, 1)", (b["hash"], b["data"]))
    for r in blob_refs:
        conn.execute(
            "INSERT INTO blob_ref (session_id, message_id, hash, seq)"
            " VALUES (?, ?, ?, ?)",
            (r["session_id"], r["message_id"], r["hash"], r["seq"]))
    for i in inst_state:
        conn.execute(
            "INSERT INTO instruction_state (session_id, epoch_start,"
            " through_seq, initial_values, current_values) VALUES"
            " (?, 1, 1, '{}', '{}')", (i["session_id"],))
    for i in inst_entry:
        conn.execute(
            "INSERT INTO instruction_entry (session_id, key, value, removed,"
            " time_created, time_updated) VALUES (?, ?, ?, 0, 1, 1)",
            (i["session_id"], i["key"], i.get("value")))
    for b in inst_blobs:
        conn.execute(
            "INSERT INTO instruction_blob (hash, value) VALUES (?, ?)",
            (b["hash"], b["value"]))
    for k in kv_rows:
        conn.execute(
            "INSERT INTO kv (key, value, time_created, time_updated)"
            " VALUES (?, 'v', 1, 1)", (k,))
    for a in accounts:
        conn.execute(
            "INSERT INTO account (id, email, url, access_token,"
            " refresh_token, time_created, time_updated) VALUES"
            " (?, 'x@y', 'u', 'SECRET-TOKEN', 'SECRET-REFRESH', 1, 1)",
            (a,))
    conn.commit()
    conn.close()


class OcChatCoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ghost-oc-chat-")
        self.source_db = os.path.join(self.tmp, "source", "opencode.db")
        self.target_db = os.path.join(self.tmp, "target", "opencode.db")
        self.manifest = os.path.join(self.tmp, "target-home",
                                     "chat-sync-manifest.json")
        self.backup_root = os.path.join(self.tmp, "backups")
        os.makedirs(os.path.dirname(self.source_db))
        os.makedirs(os.path.dirname(self.target_db))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- fixtures -----------------------------------------------------------

    def seed_source(self):
        """Parent + child session, 3 messages, 1 part, 1 blob, instruction
        rows, plus an account row that must NEVER move."""
        _mk_db(
            self.source_db,
            sessions=[
                {"id": "ses_parent", "slug": "parent", "title": "Parent"},
                {"id": "ses_child", "slug": "child", "title": "Child",
                 "parent_id": "ses_parent", "time_created": 2},
            ],
            messages=[
                {"id": "msg_p1", "session_id": "ses_parent", "type": "user",
                 "seq": 1, "data": json.dumps({"text": "hello parent"})},
                {"id": "msg_p2", "session_id": "ses_parent", "type": "assistant",
                 "seq": 2, "data": json.dumps({"content": "hi"})},
                {"id": "msg_c1", "session_id": "ses_child", "type": "user",
                 "seq": 1, "data": json.dumps({"text": "hello child"})},
            ],
            parts=[{"message_id": "msg_p2", "session_id": "ses_parent",
                    "ordinal": 0, "data": "{}"}],
            blobs=[{"hash": "hash_img", "data": b"\x89PNG"}],
            blob_refs=[{"session_id": "ses_parent", "message_id": "msg_p1",
                        "hash": "hash_img", "seq": 0}],
            inst_state=[{"session_id": "ses_parent"}],
            inst_entry=[{"session_id": "ses_child", "key": "rules",
                         "value": "be brief"}],
            inst_blobs=[{"hash": "hash_inst", "value": "instructions"}],
            accounts=["acc_primary"],
        )

    def seed_target(self):
        _mk_db(self.target_db, sessions=[], accounts=["acc_clone"])

    # -- inventory ----------------------------------------------------------

    def test_inventory_lists_counts_and_project_path(self):
        self.seed_source()
        result = opencode.oc_chat_inventory(
            {"db_path": self.source_db, "manifest_path": self.manifest})
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["session_count"], 2)
        by_id = {s["session_id"]: s for s in result["sessions"]}
        self.assertEqual(by_id["ses_parent"]["messages"], 2)
        self.assertEqual(by_id["ses_child"]["messages"], 1)
        self.assertEqual(by_id["ses_parent"]["project_worktree"], WORKTREE)
        self.assertFalse(by_id["ses_parent"]["imported"])

    def test_inventory_missing_db_refuses(self):
        with self.assertRaises(Refusal) as ctx:
            opencode.oc_chat_inventory({"db_path": "nope.db"})
        self.assertEqual(ctx.exception.code, "db-missing")

    # -- import -------------------------------------------------------------

    def _import(self, session_ids, **extra):
        payload = {
            "source_db": self.source_db,
            "target_db": self.target_db,
            "manifest_path": self.manifest,
            "backup_root": self.backup_root,
            "session_ids": session_ids,
        }
        payload.update(extra)
        return opencode.oc_chat_import(payload)

    def test_dry_run_writes_nothing(self):
        self.seed_source()
        self.seed_target()
        result = self._import(["ses_child"], dry_run=True)
        self.assertEqual(result["status"], "dry-run")
        # the child selection expanded to its parent
        self.assertEqual(result["session_ids"], ["ses_parent", "ses_child"])
        self.assertEqual(result["counts"]["messages"], 3)
        # the target already carries the same-id project row for the
        # worktree path -> reused, nothing inserted
        self.assertEqual(result["counts"]["projects"], 0)
        # zero writes anywhere
        conn = sqlite3.connect(self.target_db)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM session_v2").fetchone()[0], 0)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM project").fetchone()[0], 1)
        conn.close()
        self.assertFalse(os.path.exists(self.manifest))
        # no backup dir was ever created (the dry-run wrote nothing)
        self.assertFalse(os.path.exists(self.backup_root))

    def test_import_copies_family_and_payload(self):
        self.seed_source()
        self.seed_target()
        result = self._import(["ses_child"])
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["session_ids"], ["ses_parent", "ses_child"])
        self.assertTrue(result["verify"]["sessions_present"])
        self.assertTrue(result["verify"]["sample_message_equal"])
        conn = sqlite3.connect(self.target_db)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM session_message").fetchone()[0], 3)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM session_part").fetchone()[0], 1)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM blob").fetchone()[0], 1)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM blob_ref").fetchone()[0], 1)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM instruction_state").fetchone()[0], 1)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM instruction_entry").fetchone()[0], 1)
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM instruction_blob").fetchone()[0], 1)
        # project reused by worktree path (same deterministic id), so no
        # second project row and the sessions point at the target's own row
        self.assertEqual(conn.execute(
            "SELECT COUNT(*) FROM project").fetchone()[0], 1)
        self.assertEqual(conn.execute(
            "SELECT project_id FROM session_v2 WHERE id = 'ses_parent'"
        ).fetchone()[0], PROJECT_ID)
        conn.close()

    def test_import_titles_get_tag(self):
        self.seed_source()
        self.seed_target()
        self._import(["ses_parent"])
        conn = sqlite3.connect(self.target_db)
        title = conn.execute(
            "SELECT title FROM session_v2 WHERE id = 'ses_parent'"
        ).fetchone()[0]
        conn.close()
        self.assertTrue(title.startswith("[import] "))

    def test_import_idempotent_by_id(self):
        self.seed_source()
        self.seed_target()
        first = self._import(["ses_parent"])
        second = self._import(["ses_parent"])
        self.assertEqual(second["status"], "skipped")
        self.assertEqual(second["reason"], "all-selected-present")
        # the first import expanded to the parent + its child
        self.assertEqual(second["skipped_existing"],
                         ["ses_child", "ses_parent"])
        # and the manifest records exactly one import
        with open(self.manifest, encoding="utf-8") as handle:
            manifest = json.load(handle)
        self.assertEqual(len(manifest["imports"]), 1)
        self.assertEqual(manifest["imports"][0]["import_id"],
                         first["import_id"])

    def test_import_missing_project_row_copies_verbatim(self):
        self.seed_source()
        # target WITHOUT the project row for that worktree
        _mk_db(self.target_db, with_project=False, sessions=[])
        result = self._import(["ses_parent"])
        self.assertEqual(result["status"], "ok")
        conn = sqlite3.connect(self.target_db)
        wt = conn.execute(
            "SELECT worktree FROM project WHERE id = ?",
            (PROJECT_ID,)).fetchone()[0]
        conn.close()
        self.assertEqual(wt, WORKTREE)
        self.assertEqual(result["project_remap"][PROJECT_ID], PROJECT_ID)

    def test_import_never_moves_accounts(self):
        self.seed_source()
        self.seed_target()
        self._import(["ses_parent"])
        conn = sqlite3.connect(self.target_db)
        rows = conn.execute("SELECT id, access_token FROM account").fetchall()
        conn.close()
        self.assertEqual(rows, [("acc_clone", "SECRET-TOKEN")])

    def test_import_same_db_refuses(self):
        with self.assertRaises(Refusal) as ctx:
            self._import(["x"], target_db=self.source_db)
        self.assertEqual(ctx.exception.code, "same-db")

    def test_import_unknown_session_refuses(self):
        self.seed_source()
        self.seed_target()
        with self.assertRaises(Refusal) as ctx:
            self._import(["ses_nope"])
        self.assertEqual(ctx.exception.code, "session-missing")

    def test_import_schema_mismatch_refuses(self):
        self.seed_source()
        bad = os.path.join(self.tmp, "bad.db")
        conn = sqlite3.connect(bad)
        conn.execute("CREATE TABLE session_v2 (id text)")
        conn.commit()
        conn.close()
        with self.assertRaises(Refusal) as ctx:
            self._import(["ses_parent"], target_db=bad)
        self.assertEqual(ctx.exception.code, "schema-mismatch")

    # -- revert ---------------------------------------------------------------

    def test_revert_deletes_cascades_and_tombstones(self):
        self.seed_source()
        self.seed_target()
        result = self._import(["ses_child"])
        manifest_before = json.load(open(self.manifest, encoding="utf-8"))
        self.assertEqual(len(manifest_before["imports"]), 1)
        revert = opencode.oc_chat_revert({
            "target_db": self.target_db,
            "manifest_path": self.manifest,
            "backup_root": self.backup_root,
            "import_id": result["import_id"],
        })
        self.assertEqual(revert["status"], "ok")
        self.assertEqual(revert["rows_left"], 0)
        conn = sqlite3.connect(self.target_db)
        counts = [conn.execute(
            "SELECT COUNT(*) FROM {0}".format(t)).fetchone()[0]
            for t in ("session_v2", "session_message", "session_part",
                      "blob_ref", "instruction_state", "instruction_entry")]
        conn.close()
        self.assertEqual(counts, [0, 0, 0, 0, 0, 0])
        manifest_after = json.load(open(self.manifest, encoding="utf-8"))
        self.assertTrue(manifest_after["imports"][0]["reverted"])

    def test_revert_unknown_import_refuses(self):
        self.seed_target()
        with self.assertRaises(Refusal) as ctx:
            opencode.oc_chat_revert({
                "target_db": self.target_db,
                "manifest_path": self.manifest,
                "backup_root": self.backup_root,
                "import_id": "nope",
            })
        self.assertEqual(ctx.exception.code, "import-not-found")

    def test_reverted_import_becomes_plannable_again(self):
        self.seed_source()
        self.seed_target()
        result = self._import(["ses_parent"])
        opencode.oc_chat_revert({
            "target_db": self.target_db,
            "manifest_path": self.manifest,
            "backup_root": self.backup_root,
            "import_id": result["import_id"],
        })
        again = self._import(["ses_parent"])
        self.assertEqual(again["status"], "ok")
        self.assertEqual(again["session_ids"], ["ses_parent", "ses_child"])

    # -- CLI end-to-end -------------------------------------------------------

    def test_cli_end_to_end(self):
        self.seed_source()
        self.seed_target()
        repo_root = os.path.join(os.path.dirname(__file__), "..", "..")
        env = dict(os.environ)
        env["PYTHONPATH"] = os.path.join(repo_root, "src", "python")
        proc = self._run_cli(
            ["-c",
             "import sys; sys.path.insert(0, sys.argv[1]); "
             "sys.argv = ['ghost_cli.py'] + sys.argv[2:]; "
             "from ghost.__main__ import main; sys.exit(main())"],
            [os.path.join(repo_root, "src", "python"),
             "oc-chat-inventory",
             _b64({"db_path": self.source_db,
                   "manifest_path": self.manifest})],
            env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        verdict = json.loads(proc.stdout)
        self.assertEqual(verdict["session_count"], 2)

    def _run_cli(self, py_args, cli_args, env):
        import subprocess
        return subprocess.run(
            [sys.executable, "-I"] + py_args + cli_args,
            capture_output=True, text=True, encoding="utf-8", env=env)


if __name__ == "__main__":
    unittest.main()
