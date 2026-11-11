"""unittest suite for the AutoClaw2 (zwork) sync core (src/python/ghost/autoclaw2.py).

Stdlib only. The fixture builds a schema SUBSET that is byte-honest for the
surfaces this module touches: the real CHECK constraints on
neutral_session_entries/heads, the real freeze + delete-after-tombstone
triggers, a real FTS5 table, and the UUID-shape CHECKs on work_events.

Run from repo root:
    python -m unittest discover -s tests/python -v
"""

import base64
import contextlib
import ctypes
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest import mock

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
GHOST_CLI = os.path.join(REPO_ROOT, "src", "python", "ghost_cli.py")

sys.path.insert(0, os.path.join(REPO_ROOT, "src", "python"))

from ghost import autoclaw2  # noqa: E402


def _b64(payload):
    return base64.b64encode(
        json.dumps(payload).encode("utf-8")).decode("ascii")


def _fake_test(locator, timeout=60.0):
    """Deterministic stand-in for autoclaw2.test_source_locator: stdio
    locators 'succeed' with one IL-shaped tool, everything else fails with
    authentication_failed (the D4 http-sign-in case)."""
    if locator.startswith(autoclaw2.STDIO_PREFIX):
        return {"ok": True, "error_code": None,
                "tools": [{"name": "echo_tool", "description": "Echoes.",
                           "inputSchema": {"type": "object"}}],
                "dropped": 0, "tool_count": 1}
    return {"ok": False, "error_code": "authentication_failed",
            "tools": [], "dropped": 0, "tool_count": 0}


UUID4 = lambda: str(uuid.uuid4())  # noqa: E731

FIXTURE_DDL = """
CREATE TABLE schema_migrations (migration_id TEXT, applied_at TEXT,
    sequence INTEGER, checksum TEXT);
CREATE TABLE identity_personal_principals (principal_id TEXT PRIMARY KEY);
CREATE TABLE work_workspaces (workspace_id TEXT PRIMARY KEY, owner_id TEXT,
    display_name TEXT, root_path TEXT, is_default INTEGER, lifecycle TEXT,
    created_at TEXT, updated_at TEXT, initialization_kind TEXT,
    trust_status TEXT);
CREATE TABLE work_sessions (session_id TEXT PRIMARY KEY, created_at TEXT,
    updated_at TEXT, title TEXT, draft TEXT DEFAULT '', draft_revision TEXT,
    draft_annotations_json TEXT, deleted_at TEXT, owner_id TEXT,
    workspace_id TEXT, visibility TEXT DEFAULT 'private',
    binding_origin TEXT DEFAULT 'native-create', binding_version INTEGER DEFAULT 1,
    archived_at TEXT, external_provider TEXT, external_conversation_id TEXT,
    external_actor_id TEXT, external_connection_id TEXT,
    composer_permission_mode TEXT, composer_interaction_mode TEXT,
    capability_composition_json TEXT, external_chat_type TEXT, guest_form TEXT,
    external_sender_display_name TEXT);
CREATE TABLE work_runs (run_id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
    status TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', model_context TEXT,
    answer_preview TEXT, accept_order INTEGER NOT NULL DEFAULT 0,
    connection_id TEXT, connection_provider TEXT, connection_model TEXT,
    credential_version TEXT, connection_base_url TEXT, connection_protocol TEXT,
    merged_into_run_id TEXT REFERENCES work_runs(run_id),
    retried_from_run_id TEXT REFERENCES work_runs(run_id),
    attachments_json TEXT NOT NULL DEFAULT '[]', created_at TEXT,
    updated_at TEXT);
CREATE UNIQUE INDEX uniq_work_accept_order ON work_runs(accept_order);
CREATE TABLE work_events (cursor INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT UNIQUE NOT NULL CHECK(length(event_id) = 36),
    run_id TEXT NOT NULL CHECK(length(run_id) = 36),
    session_id TEXT NOT NULL CHECK(length(session_id) = 36),
    run_seq INTEGER NOT NULL, type TEXT NOT NULL, payload_json TEXT NOT NULL,
    created_at TEXT NOT NULL);
CREATE TABLE neutral_session_entries (
    session_id TEXT NOT NULL REFERENCES work_sessions(session_id) ON DELETE CASCADE,
    entry_id TEXT NOT NULL, parent_entry_id TEXT,
    session_seq INTEGER NOT NULL CHECK(session_seq >= 1), run_id TEXT NOT NULL,
    entry_type TEXT NOT NULL CHECK(entry_type IN (
        'request', 'attachment', 'reasoning', 'assistant', 'resource',
        'tool_call', 'tool_result', 'compaction', 'answer')),
    payload TEXT NOT NULL CHECK(json_valid(payload)),
    committed_at TEXT NOT NULL,
    PRIMARY KEY (session_id, entry_id),
    UNIQUE (session_id, session_seq));
CREATE TRIGGER neutral_session_entry_freeze BEFORE UPDATE ON neutral_session_entries
    BEGIN SELECT RAISE(ABORT, 'neutral_session_entry_immutable'); END;
CREATE TRIGGER neutral_session_entry_delete_after_tombstone BEFORE DELETE
    ON neutral_session_entries WHEN EXISTS (
        SELECT 1 FROM work_sessions WHERE session_id = old.session_id
        AND deleted_at IS NULL)
    BEGIN SELECT RAISE(ABORT, 'neutral_session_entry_delete_requires_tombstone'); END;
CREATE TABLE neutral_session_heads (
    session_id TEXT PRIMARY KEY REFERENCES work_sessions(session_id) ON DELETE CASCADE,
    next_session_seq INTEGER NOT NULL DEFAULT 1 CHECK(next_session_seq >= 1),
    conversation_head_entry_id TEXT, conversation_session_seq INTEGER,
    conversation_run_id TEXT, settled_answer_entry_id TEXT,
    settled_session_seq INTEGER, settled_run_id TEXT, updated_at TEXT NOT NULL,
    entry_count INTEGER NOT NULL DEFAULT 0 CHECK(entry_count >= 0),
    CHECK ((conversation_head_entry_id IS NULL AND conversation_session_seq IS NULL
            AND conversation_run_id IS NULL)
        OR (conversation_head_entry_id IS NOT NULL AND conversation_session_seq IS NOT NULL
            AND conversation_run_id IS NOT NULL)));
CREATE TRIGGER neutral_session_head_delete_after_tombstone BEFORE DELETE
    ON neutral_session_heads WHEN EXISTS (
        SELECT 1 FROM work_sessions WHERE session_id = old.session_id
        AND deleted_at IS NULL)
    BEGIN SELECT RAISE(ABORT, 'neutral_session_head_delete_requires_tombstone'); END;
CREATE VIRTUAL TABLE neutral_session_fts USING fts5(
    session_id UNINDEXED, entry_id UNINDEXED, body, tokenize='trigram');
CREATE TABLE governed_tool_revisions (tool_id TEXT, revision TEXT,
    definition_json TEXT DEFAULT '{}', created_at TEXT,
    PRIMARY KEY (tool_id, revision));
CREATE TABLE governed_tool_artifacts (artifact_id TEXT PRIMARY KEY,
    session_id TEXT, run_id TEXT, tool_id TEXT, tool_revision TEXT,
    payload_json TEXT DEFAULT '{}', created_at TEXT);
CREATE TABLE governed_tool_artifact_custody (custody_id TEXT PRIMARY KEY,
    artifact_id TEXT, state TEXT DEFAULT 'held', created_at TEXT);
CREATE TABLE governed_connected_sources (
    owner_id TEXT NOT NULL, workspace_id TEXT NOT NULL, kind TEXT NOT NULL,
    slug TEXT NOT NULL, name TEXT NOT NULL, endpoint TEXT NOT NULL,
    enabled INTEGER NOT NULL, status TEXT NOT NULL, error_code TEXT,
    credential_version TEXT, source_permission TEXT NOT NULL,
    tool_permissions_json TEXT NOT NULL, revision TEXT NOT NULL,
    tools_json TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY (owner_id, workspace_id, slug));
"""


class _Fixture:
    """One fake USERPROFILE holding Primary + c1 with seeded data."""

    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="ac2-test-")
        base = self._tmp.name
        self.roaming = os.path.join(base, "AppData", "Roaming")
        os.makedirs(self.roaming, exist_ok=True)
        self.owner = UUID4()
        self.db_paths = {}
        self._accept_seq = {}
        # Primary + c1 seeded; c2/c3/c5 exist but never signed in;
        # c4 does not exist at all (profile-missing).
        self._make_profile("Primary", os.path.join(self.roaming, "AutoClaw-oversea-official"))
        self._make_profile("c1", os.path.join(base, "AutoClaw2ClonesHome", "c1"))
        for name in ("c2", "c3", "c5"):
            os.makedirs(os.path.join(base, "AutoClaw2ClonesHome", name, "accounts"),
                        exist_ok=True)

    def _make_profile(self, name, pdir):
        acc_hash = uuid.uuid4().hex
        acc = os.path.join(pdir, "accounts", acc_hash)
        runtime = os.path.join(acc, "runtime")
        os.makedirs(runtime, exist_ok=True)
        db = os.path.join(runtime, "runtime.sqlite")
        self.db_paths[name] = db
        self._seed(db, ws_root=os.path.join("C:\\work", name.lower()))

    def _seed(self, db, ws_root):
        conn = sqlite3.connect(db)
        conn.executescript(FIXTURE_DDL)
        conn.execute("INSERT INTO schema_migrations VALUES (?,?,?,?)",
                     (autoclaw2.MIGRATION_ID, "2026-01-01T00:00:00.000Z",
                      autoclaw2.MIGRATION_SEQUENCE, autoclaw2.MIGRATION_CHECKSUM))
        conn.execute("INSERT INTO identity_personal_principals VALUES (?)",
                     (self.owner,))
        self.default_ws = UUID4()
        self.repo_ws = UUID4()
        for ws_id, root, is_default in (
                (self.default_ws, os.path.join(ws_root, "projects", "Default"), 1),
                (self.repo_ws, "C:\\programming\\github\\unban-machine-id", 0)):
            conn.execute(
                "INSERT INTO work_workspaces (workspace_id, owner_id,"
                " display_name, root_path, is_default, lifecycle) VALUES"
                " (?,?,?,?,?,'active')",
                (ws_id, self.owner, os.path.basename(root), root, is_default))
        # one tool revision so artifact copies have their FK target
        conn.execute(
            "INSERT INTO governed_tool_revisions VALUES (?,?,?,?)",
            ("filesystem.edit", "10", "{}", "2026-01-01T00:00:00.000Z"))
        conn.commit()
        conn.close()

    def session(self, profile, title="S", external_provider=None,
                entries=None, with_head=True, with_artifact=True):
        """Seed a minimal session tree; returns (session_id, run_id)."""
        sid, run_id = UUID4(), UUID4()
        conn = sqlite3.connect(self.db_paths[profile])
        ws = self.repo_ws if profile == "Primary" else self.repo_ws
        conn.execute(
            "INSERT INTO work_sessions (session_id, created_at, updated_at,"
            " title, owner_id, workspace_id, external_provider)"
            " VALUES (?,?,?,?,?,?,?)",
            (sid, "2026-01-01T00:00:00.000Z", "2026-01-01T00:01:00.000Z",
             title, self.owner, ws, external_provider))
        # accept_order is globally unique in the real schema
        # (uniq_work_accept_order) - the seeder hands out a per-profile
        # increasing counter instead of relying on the DEFAULT 0
        acc = self._accept_seq.get(profile, 0) + 1
        self._accept_seq[profile] = acc
        conn.execute(
            "INSERT INTO work_runs (run_id, session_id, status, text,"
            " connection_model, credential_version, accept_order)"
            " VALUES (?,?,?,?,?,?,?)",
            (run_id, sid, "completed", title, "glm-5.3", "cred-version-1", acc))
        for seq in (1, 2):
            conn.execute(
                "INSERT INTO work_events (event_id, run_id, session_id,"
                " run_seq, type, payload_json, created_at)"
                " VALUES (?,?,?,?,?,?,?)",
                (UUID4(), run_id, sid, seq,
                 "turn_started" if seq == 1 else "turn_finished",
                 json.dumps({"seq": seq}),
                 "2026-01-01T00:00:0{0}.000Z".format(seq)))
        pairs = entries or [
            (1, "request", {"data": {"text": "hello fixture question"}}),
            (2, "answer", {"data": {"text": "fixture answer body"}}),
        ]
        for seq, etype, payload in pairs:
            suffix = "request" if etype == "request" else "answer"
            conn.execute(
                "INSERT INTO neutral_session_entries (session_id, entry_id,"
                " parent_entry_id, session_seq, run_id, entry_type, payload,"
                " committed_at) VALUES (?,?,?,?,?,?,?,?)",
                (sid, "{0}:{1}".format(run_id, suffix),
                 None if seq == 1 else "{0}:request".format(run_id),
                 seq, run_id, etype, json.dumps(payload),
                 "2026-01-01T00:00:0{0}.000Z".format(seq)))
        if with_head:
            conn.execute(
                "INSERT INTO neutral_session_heads (session_id,"
                " next_session_seq, conversation_head_entry_id,"
                " conversation_session_seq, conversation_run_id,"
                " settled_answer_entry_id, settled_session_seq,"
                " settled_run_id, updated_at, entry_count)"
                " VALUES (?,?,?,?,?,?,?,?,?,?)",
                (sid, len(pairs) + 1,
                 "{0}:answer".format(run_id), len(pairs), run_id,
                 "{0}:answer".format(run_id), len(pairs), run_id,
                 "2026-01-01T00:01:00.000Z", len(pairs)))
        if with_artifact:
            art = UUID4()
            conn.execute(
                "INSERT INTO governed_tool_artifacts (artifact_id, session_id,"
                " run_id, tool_id, tool_revision) VALUES (?,?,?,?,?)",
                (art, sid, run_id, "filesystem.edit", "10"))
            conn.execute(
                "INSERT INTO governed_tool_artifact_custody VALUES (?,?,?,?)",
                (UUID4(), art, "held", "2026-01-01T00:00:00.000Z"))
        conn.commit()
        conn.close()
        return sid, run_id

    def hold_lock(self, profile):
        """Open the profile's lockfile with NO sharing; returns the handle."""
        path = os.path.join(autoclaw2.profile_path(profile), "lockfile")
        with open(path, "w"):
            pass
        handle = ctypes.windll.kernel32.CreateFileW(
            path, 0x80000000, 0, None, 3, 0x80, None)
        return handle

    @staticmethod
    def release_lock(handle):
        ctypes.windll.kernel32.CloseHandle(handle)

    def cleanup(self):
        self._tmp.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.cleanup()


class _PatchedHome(unittest.TestCase):
    """Base: point the module's home/roaming resolvers at the fixture."""

    def setUp(self):
        self.fixture = _Fixture()
        base = self.fixture._tmp.name
        self._orig = (autoclaw2._home, autoclaw2._roaming)
        autoclaw2._home = lambda: base
        autoclaw2._roaming = lambda: self.fixture.roaming

    def tearDown(self):
        autoclaw2._home, autoclaw2._roaming = self._orig
        self.fixture.cleanup()


class LocatorCodecTests(unittest.TestCase):

    def test_stdio_round_trip_without_cwd(self):
        loc = autoclaw2.canonical_locator(
            {"transport": "stdio", "slug": "s", "command": "npx",
             "args": ["-y", "pkg"]})
        self.assertEqual(loc, 'stdio+v1:{"command":"npx","args":["-y","pkg"]}')
        self.assertEqual(autoclaw2.decode_locator(loc),
                         {"transport": "stdio", "command": "npx",
                          "args": ["-y", "pkg"]})

    def test_stdio_with_cwd_keeps_key_order(self):
        loc = autoclaw2.canonical_locator(
            {"transport": "stdio", "slug": "s", "command": "node",
             "args": ["a b", "über"], "cwd": "C:\\x y"})
        self.assertTrue(loc.startswith('stdio+v1:{"command":"node","args":'))
        self.assertIn('"cwd":"C:\\\\x y"', loc)
        self.assertEqual(autoclaw2.decode_locator(loc)["cwd"], "C:\\x y")

    def test_http_verbatim_and_rejects_non_http(self):
        self.assertEqual(
            autoclaw2.canonical_locator(
                {"transport": "http", "slug": "h", "endpoint": " https://x/mcp "}),
            "https://x/mcp")
        with self.assertRaises(autoclaw2.Refusal):
            autoclaw2.canonical_locator(
                {"transport": "http", "slug": "h", "endpoint": "ftp://x"})

    def test_empty_command_refused(self):
        with self.assertRaises(autoclaw2.Refusal):
            autoclaw2.canonical_locator(
                {"transport": "stdio", "slug": "s", "command": "  ", "args": []})

    def test_decode_raw_url_is_http(self):
        self.assertEqual(autoclaw2.decode_locator("https://a/b"),
                         {"transport": "http", "endpoint": "https://a/b"})


class ManifestValidationTests(unittest.TestCase):

    def _write(self, servers, **extra):
        path = os.path.join(tempfile.mkdtemp(), "m.json")
        data = {"schemaVersion": 1, "defaults": {}, "servers": servers}
        data.update(extra)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return path

    def test_valid_manifest_loads_and_canonicalizes(self):
        path = self._write([{"slug": "fs", "name": "FS", "transport": "stdio",
                             "command": "npx", "args": ["-y", "x"]}])
        m = autoclaw2.load_manifest(path)
        self.assertEqual(m["servers"][0]["locator"],
                         'stdio+v1:{"command":"npx","args":["-y","x"]}')

    def test_bad_slug_rejected_before_db(self):
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.load_manifest(self._write(
                [{"slug": "Bad Slug", "name": "x", "transport": "stdio",
                  "command": "npx"}]))
        self.assertEqual(ctx.exception.code, "manifest-invalid")

    def test_duplicate_slug_rejected(self):
        srv = {"slug": "a", "name": "x", "transport": "http",
               "endpoint": "https://a"}
        with self.assertRaises(autoclaw2.Refusal):
            autoclaw2.load_manifest(self._write([srv, dict(srv)]))

    def test_missing_manifest(self):
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.load_manifest(os.path.join(tempfile.mkdtemp(), "nope.json"))
        self.assertEqual(ctx.exception.code, "manifest-missing")


class ProfileResolutionTests(_PatchedHome):

    def test_missing_profile(self):
        info = autoclaw2.resolve_profile("c4")
        self.assertEqual(info["account_status"], "profile-missing")

    def test_missing_profile_refuses_when_account_required(self):
        # the early return for a missing profile dir must honor the
        # require_account gate - otherwise callers crash on db_path=None
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.resolve_profile("c4", require_account=True)
        self.assertEqual(ctx.exception.code, "profile-missing")

    def test_not_signed_in(self):
        info = autoclaw2.resolve_profile("c2")
        self.assertEqual(info["account_status"], "not-signed-in")

    def test_ambiguous_account_refuses(self):
        pdir = autoclaw2.profile_path("c5")
        for h in ("a" * 64, "b" * 64):
            os.makedirs(os.path.join(pdir, "accounts", h, "runtime"),
                        exist_ok=True)
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.resolve_profile("c5", require_account=True)
        self.assertEqual(ctx.exception.code, "ambiguous-account")

    def test_ok_account(self):
        info = autoclaw2.resolve_profile("c1")
        self.assertEqual(info["account_status"], "ok")
        self.assertTrue(os.path.isfile(info["db_path"]))

    # --- multi-account disambiguation (the Primary's dormant + live case) ---

    def _two_accounts(self, profile):
        pdir = autoclaw2.profile_path(profile)
        dirs = {}
        for h in ("a" * 64, "b" * 64):
            runtime = os.path.join(pdir, "accounts", h, "runtime")
            os.makedirs(runtime, exist_ok=True)
            db = os.path.join(runtime, "runtime.sqlite")
            with open(db, "w"):
                pass
            dirs[h] = db
        return dirs

    def test_multi_account_newest_runtime_is_selected_loudly(self):
        dirs = self._two_accounts("c5")
        past = time.time() - 3600
        os.utime(dirs["a" * 64], (past, past))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            info = autoclaw2.resolve_profile("c5")
        self.assertEqual(info["account_status"], "ok")
        self.assertEqual(info["account_selected_by"], "newest-mtime")
        self.assertTrue(info["account_dir"].endswith("b" * 64))
        self.assertIn("newest runtime.sqlite", err.getvalue())

    def test_multi_account_tie_still_refuses(self):
        dirs = self._two_accounts("c5")
        now = time.time()
        for db in dirs.values():
            os.utime(db, (now, now))
        info = autoclaw2.resolve_profile("c5")
        self.assertEqual(info["account_status"], "ambiguous-account")
        with self.assertRaises(autoclaw2.Refusal):
            autoclaw2.resolve_profile("c5", require_account=True)

    def test_multi_account_hint_exact_and_unique_prefix(self):
        dirs = self._two_accounts("c5")
        now = time.time() - 7200  # tied AND stale: only a hint can resolve
        for db in dirs.values():
            os.utime(db, (now, now))
        info = autoclaw2.resolve_profile("c5", account_hint="b" * 64)
        self.assertEqual(info["account_selected_by"], "hint")
        self.assertTrue(info["account_dir"].endswith("b" * 64))
        info = autoclaw2.resolve_profile("c5", account_hint="b")
        self.assertTrue(info["account_dir"].endswith("b" * 64))

    def test_multi_account_hint_errors(self):
        pdir = autoclaw2.profile_path("c5")
        for h in ("ab" * 32, "ac" * 32):
            os.makedirs(os.path.join(pdir, "accounts", h, "runtime"),
                        exist_ok=True)
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.resolve_profile("c5", account_hint="zz")
        self.assertEqual(ctx.exception.code, "account-hint-no-match")
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.resolve_profile("c5", account_hint="a")
        self.assertEqual(ctx.exception.code, "account-hint-ambiguous")

    @unittest.skipUnless(os.name == "nt", "Windows lockfile semantics")
    def test_lock_probe_held_and_free(self):
        handle = self.fixture.hold_lock("c1")
        try:
            self.assertTrue(autoclaw2.probe_running(
                autoclaw2.profile_path("c1")))
        finally:
            self.fixture.release_lock(handle)
        self.assertFalse(autoclaw2.probe_running(autoclaw2.profile_path("c1")))


class SchemaGateTests(_PatchedHome):

    def test_ok(self):
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            self.assertTrue(autoclaw2.check_schema(conn)["ok"])
        finally:
            conn.close()

    def test_drift_refused(self):
        conn = sqlite3.connect(self.fixture.db_paths["c1"])
        conn.execute("UPDATE schema_migrations SET sequence = 81")
        conn.commit()
        conn.close()
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            gate = autoclaw2.check_schema(conn)
        finally:
            conn.close()
        self.assertFalse(gate["ok"])
        self.assertEqual(gate["found"][0]["sequence"], 81)

    # Live 4.0.0 forward migrations (read from c1's schema_migrations on
    # 2026-11-05, the day the app went baseline/80 -> 85 and the old
    # single-row gate started refusing every profile).
    _FORWARD_MIGRATIONS = (
        ("0081_agent_default_project", 81,
         "sha256:e469e7465297d9950d02abc28b2cf6307bc29115c58202df08b54c7ce326112c"),
        ("0082_session_document_metadata", 82,
         "sha256:1f42c97a415686ea6e4a849fff2b7d4420e56b8fa94eef459b1bee8ecdb4199e"),
        ("0083_session_forks", 83,
         "sha256:94e581b85bc36767801c3a9046056392873956e516f580c5badb4eb215aaab8c"),
        ("0084_collaboration_detached_receipts", 84,
         "sha256:23a9ffbda393e9e6d76a30949a5a521a4fe37bd031b783e05a7b7073ea904e37"),
        ("0085_session_goals", 85,
         "sha256:539ea5aaa088f01f473094194d0b33c6da9906d740e6ddc172bbc508aeb80153"),
    )

    def _append_forward_migrations(self, db_path):
        conn = sqlite3.connect(db_path)
        for mid, seq, ck in self._FORWARD_MIGRATIONS:
            conn.execute(
                "INSERT INTO schema_migrations VALUES (?,?,?,?)",
                (mid, "2026-11-05T13:58:50.000Z", seq, ck))
        conn.commit()
        conn.close()

    def test_forward_migrations_accepted(self):
        # the app APPENDS migrations on top of the baseline; the gate must
        # accept the multi-row history (live 4.0.0 shape, max sequence 85)
        db_path = self.fixture.db_paths["c1"]
        self._append_forward_migrations(db_path)
        conn = autoclaw2.ro_connect(db_path)
        try:
            gate = autoclaw2.check_schema(conn)
        finally:
            conn.close()
        self.assertTrue(gate["ok"])
        self.assertEqual(gate["history"], "baseline+forward")

    def test_fresh_account_stamp_accepted(self):
        # the app's fresh-account bootstrap does NOT replay history: it
        # stamps ONE re-baselined row at the current sequence (the Primary's
        # live 68f7331f account, read 2026-11-06). Accepted at that exact
        # tuple only.
        db_path = self.fixture.db_paths["c1"]
        conn = sqlite3.connect(db_path)
        conn.execute("DELETE FROM schema_migrations")
        mid, seq, ck = autoclaw2.FRESH_STAMP_BASELINE
        conn.execute("INSERT INTO schema_migrations VALUES (?,?,?,?)",
                     (mid, "2026-11-05T14:01:52.821Z", seq, ck))
        conn.commit()
        conn.close()
        conn = autoclaw2.ro_connect(db_path)
        try:
            gate = autoclaw2.check_schema(conn)
        finally:
            conn.close()
        self.assertTrue(gate["ok"])
        self.assertEqual(gate["history"], "fresh-stamp-85")

    def test_fresh_stamp_with_wrong_checksum_refused(self):
        # a re-stamped row that does not match the observed tuple exactly is
        # unknown lineage (a future app version re-stamping) -> refuse loudly
        db_path = self.fixture.db_paths["c1"]
        conn = sqlite3.connect(db_path)
        conn.execute("DELETE FROM schema_migrations")
        mid, seq, _ = autoclaw2.FRESH_STAMP_BASELINE
        conn.execute("INSERT INTO schema_migrations VALUES (?,?,?,?)",
                     (mid, "2026-11-05T14:01:52.821Z", seq, "sha256:deadbeef"))
        conn.commit()
        conn.close()
        conn = autoclaw2.ro_connect(db_path)
        try:
            gate = autoclaw2.check_schema(conn)
        finally:
            conn.close()
        self.assertFalse(gate["ok"])

    def test_baseline_row_removed_refused(self):
        # forward rows without the baseline = unknown lineage -> refuse
        db_path = self.fixture.db_paths["c1"]
        self._append_forward_migrations(db_path)
        conn = sqlite3.connect(db_path)
        conn.execute("DELETE FROM schema_migrations WHERE sequence = ?",
                     (autoclaw2.MIGRATION_SEQUENCE,))
        conn.commit()
        conn.close()
        conn = autoclaw2.ro_connect(db_path)
        try:
            gate = autoclaw2.check_schema(conn)
        finally:
            conn.close()
        self.assertFalse(gate["ok"])
        self.assertIn("expected_baseline", gate)

    def test_baseline_checksum_edited_refused(self):
        # editing the baseline row itself (not appending) is drift
        db_path = self.fixture.db_paths["c1"]
        conn = sqlite3.connect(db_path)
        conn.execute("UPDATE schema_migrations SET checksum = 'sha256:deadbeef'")
        conn.commit()
        conn.close()
        conn = autoclaw2.ro_connect(db_path)
        try:
            gate = autoclaw2.check_schema(conn)
        finally:
            conn.close()
        self.assertFalse(gate["ok"])

    def test_missing_tables_refused(self):
        # a db holding only the baseline row (none of our tables) refuses
        # loudly with missing_columns - never write blind
        db_path = self.fixture.db_paths["c1"] + ".bare.sqlite"
        conn = sqlite3.connect(db_path)
        conn.execute(
            "CREATE TABLE schema_migrations (migration_id TEXT, applied_at TEXT,"
            " sequence INTEGER, checksum TEXT)")
        conn.execute("INSERT INTO schema_migrations VALUES (?,?,?,?)",
                     (autoclaw2.MIGRATION_ID, "2026-01-01T00:00:00.000Z",
                      autoclaw2.MIGRATION_SEQUENCE, autoclaw2.MIGRATION_CHECKSUM))
        conn.commit()
        conn.close()
        conn = autoclaw2.ro_connect(db_path)
        try:
            gate = autoclaw2.check_schema(conn)
        finally:
            conn.close()
        self.assertFalse(gate["ok"])
        self.assertIn("missing_columns", gate)
        os.unlink(db_path)


class WorkspaceMappingTests(_PatchedHome):

    def _wss(self):
        return [
            {"workspace_id": "w-def", "root_path": "C:\\w\\c1\\projects\\Default",
             "is_default": True, "display_name": "d"},
            {"workspace_id": "w-repo", "root_path": "c:\\programming\\GitHub\\unban-machine-id\\",
             "is_default": False, "display_name": "r"},
        ]

    def test_root_match_is_case_and_slash_insensitive(self):
        src = [{"root_path": "C:/programming/github/UNBAN-MACHINE-ID"}]
        pairs, warns = autoclaw2._map_target_workspaces(src, self._wss(), "default")
        matched = [p for p in pairs if p["matched_root"]]
        self.assertEqual(len(matched), 1)
        self.assertEqual(matched[0]["target_workspace"]["workspace_id"], "w-repo")
        self.assertEqual(warns, [])

    def test_unmatched_source_is_skipped_with_warn(self):
        # D3/F4: an unmatched source workspace is SKIP + WARN - it never lands
        # silently on the target's default workspace; the default workspace is
        # still part of the default target set on its own
        pairs, warns = autoclaw2._map_target_workspaces(
            [{"root_path": "C:\\elsewhere"}], self._wss(), "default")
        self.assertEqual({p["target_workspace"]["workspace_id"] for p in pairs},
                         {"w-def"})
        self.assertEqual(len(warns), 1)
        self.assertEqual(warns[0]["reason"], "no-root-match-skipped")

    def test_policy_all_expands(self):
        pairs, warns = autoclaw2._map_target_workspaces([], self._wss(), "all")
        self.assertEqual(len(pairs), 2)
        self.assertEqual(warns, [])


class MergeInvariantTests(_PatchedHome):

    def _manifest(self, enabled=True):
        return [{
            "slug": "fs", "name": "FS", "locator": "stdio+v1:" + json.dumps(
                {"command": "npx", "args": []}, separators=(",", ":")),
            "enabled": enabled, "source_permission": "allowed",
            "requires_credential": False,
        }]

    def _row(self, slug="fs", **over):
        row = {"slug": slug, "kind": "mcp", "name": "FS",
               "endpoint": self._manifest()[0]["locator"], "enabled": True,
               "status": "connected", "error_code": None,
               "source_permission": "allowed",
               "tool_permissions_json": "{}", "revision": "r1",
               "tools_json": "[]",
               "updated_at": "2026-11-05T00:00:00.000Z",
               "workspace_id": "w", "owner_id": "o", "has_credential": False}
        row.update(over)
        return row

    def test_new_server_inherits_manifest_enabled(self):
        out = autoclaw2.merge_sources(self._manifest(enabled=False), [])
        self.assertEqual(out["creates"][0]["enabled"], False)
        self.assertTrue(out["creates"][0]["revision"].startswith("sync-v1:"))

    def test_clone_local_enabled_survives_update(self):
        row = self._row(enabled=False)
        out = autoclaw2.merge_sources(self._manifest(), [row])
        self.assertEqual(len(out["updates"]), 1)
        self.assertFalse(out["updates"][0]["changed"])
        self.assertEqual(out["updates"][0]["before"]["enabled"], False)

    def test_unparseable_row_is_rewritten_even_when_definition_matches(self):
        # E5 root cause: a legacy 'pending' row fails the app's strict parse
        # and renders as invalid_response - the merge must flag it for a
        # rewrite even though name/endpoint/permission all match
        row = self._row(status="pending")
        out = autoclaw2.merge_sources(self._manifest(), [row])
        self.assertTrue(out["updates"][0]["changed"])

    def test_app_flipped_row_is_retested(self):
        # the startup registration flips a pre-tested row to
        # failed/invalid_response when a stored schema fails the app's gL
        # boundary - the flip signature must force a re-test
        row = self._row(status="failed", error_code="invalid_response",
                        revision="native.abcdef0123456789",
                        tools_json=json.dumps(
                            [{"name": "echo_tool", "description": "E."}]))
        out = autoclaw2.merge_sources(self._manifest(), [row])
        self.assertTrue(out["updates"][0]["changed"])

    def test_definition_change_detected(self):
        row = self._row(name="Old Name")
        out = autoclaw2.merge_sources(self._manifest(), [row])
        self.assertTrue(out["updates"][0]["changed"])

    def test_clone_only_rows_are_kept_never_deleted(self):
        out = autoclaw2.merge_sources(self._manifest(), [self._row(slug="mine")])
        self.assertEqual(out["manifest_absent"], ["mine"])
        self.assertEqual(len(out["creates"]), 1)

    def test_revision_deterministic(self):
        a = autoclaw2.source_revision("N", "https://x", "allowed")
        b = autoclaw2.source_revision("N", "https://x", "allowed")
        self.assertEqual(a, b)
        self.assertNotEqual(a, autoclaw2.source_revision("N", "https://y", "allowed"))


class McpApplyTests(_PatchedHome):

    def _payload(self, **over):
        payload = {
            "targets": ["c1"], "from": "master",
            "manifest_path": os.path.join(REPO_ROOT, "tools",
                                          "autoclaw2-mcp.master.json"),
            "policy": "default",
        }
        payload.update(over)
        return payload

    def _manifest_with_one_server(self):
        path = os.path.join(tempfile.mkdtemp(), "m.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"schemaVersion": 1, "defaults": {}, "servers": [
                {"slug": "fs", "name": "FS", "transport": "stdio",
                 "command": "npx", "args": ["-y", "x"]}]}, fh)
        return path

    def test_dry_run_writes_nothing(self):
        payload = self._payload(manifest_path=self._manifest_with_one_server(),
                                dry_run=True)
        before = open(self.fixture.db_paths["c1"], "rb").read()
        result = autoclaw2.mcp_apply(payload)
        self.assertEqual(result["profiles"][0]["status"], "dry-run")
        self.assertEqual(result["profiles"][0]["totals"]["creates"], 1)
        self.assertEqual(open(self.fixture.db_paths["c1"], "rb").read(), before)

    def test_apply_writes_pretested_rows_and_verifies(self):
        payload = self._payload(manifest_path=self._manifest_with_one_server())
        with mock.patch.object(autoclaw2, "test_source_locator", _fake_test):
            result = autoclaw2.mcp_apply(payload)
        entry = result["profiles"][0]
        self.assertEqual(entry["status"], "ok")
        self.assertEqual(entry["written"], 1)
        self.assertEqual(entry["sources"][0]["status"], "connected")
        self.assertEqual(entry["sources"][0]["test"]["tool_count"], 1)
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            row = conn.execute(
                "SELECT slug, name, endpoint, source_permission, revision,"
                " status, error_code, tools_json, updated_at, enabled,"
                " credential_version FROM governed_connected_sources"
                " WHERE slug = 'fs'").fetchone()
        finally:
            conn.close()
        readd = {"slug": row[0], "name": row[1], "endpoint": row[2],
                 "source_permission": row[3], "revision": row[4],
                 "status": row[5], "error_code": row[6],
                 "tools_json": row[7], "updated_at": row[8]}
        self.assertEqual(row[5], "connected")
        self.assertIsNone(row[6])
        self.assertIn("echo_tool", row[7])
        self.assertTrue(row[4].startswith("native."))
        self.assertEqual(row[9], 1)
        self.assertIsNone(row[10])
        # the written row must pass the app's own strict shape
        self.assertEqual(autoclaw2.strict_row_problems(readd), [])

    def test_apply_failed_discovery_writes_failed_legally(self):
        payload = self._payload(manifest_path=self._manifest_with_one_server())
        with mock.patch.object(autoclaw2, "test_source_locator",
                               lambda locator, timeout=60.0: {
                                   "ok": False, "error_code": "connection_failed",
                                   "tools": [], "dropped": 0, "tool_count": 0}):
            result = autoclaw2.mcp_apply(payload)
        entry = result["profiles"][0]
        self.assertEqual(entry["status"], "ok")
        self.assertEqual(entry["sources"][0]["status"], "failed")
        self.assertEqual(entry["sources"][0]["test"]["error_code"],
                         "connection_failed")
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            row = conn.execute(
                "SELECT status, error_code, tools_json, revision FROM"
                " governed_connected_sources WHERE slug = 'fs'").fetchone()
        finally:
            conn.close()
        self.assertEqual(row[0], "failed")
        self.assertEqual(row[1], "connection_failed")
        self.assertEqual(row[2], "[]")
        self.assertTrue(row[3].startswith("sync-v1:"))

    def test_apply_drops_il_oversized_tool_but_stays_connected(self):
        # one over-16384 schema used to flip the whole source at startup
        # (cloudinary upload_asset, 20024 chars, live 2026-11-06) - the real
        # mapper must drop the tool so the written row stays strict-valid
        payload = self._payload(manifest_path=self._manifest_with_one_server())
        raw = [
            {"name": "ok_tool", "description": "Fine.",
             "inputSchema": {"type": "object", "properties": {}}},
            {"name": "fat_tool", "description": "Fat.",
             "inputSchema": {"type": "object", "properties": {
                 "q": {"type": "string", "enum": ["v" * 20000]}}}}]
        with mock.patch.object(autoclaw2, "discover_stdio",
                               lambda *a, **k: (raw, None)):
            result = autoclaw2.mcp_apply(payload)
        entry = result["profiles"][0]
        self.assertEqual(entry["status"], "ok")
        self.assertEqual(entry["sources"][0]["status"], "connected")
        self.assertEqual(entry["sources"][0]["test"]["tool_count"], 1)
        self.assertEqual(entry["sources"][0]["test"]["dropped"], 1)
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            row = conn.execute(
                "SELECT slug, endpoint, source_permission, status,"
                " error_code, tools_json, updated_at FROM"
                " governed_connected_sources WHERE slug = 'fs'").fetchone()
        finally:
            conn.close()
        readd = dict(zip(("slug", "endpoint", "source_permission", "status",
                          "error_code", "tools_json", "updated_at"), row))
        self.assertEqual([t["name"] for t in json.loads(readd["tools_json"])],
                         ["ok_tool"])
        self.assertEqual(autoclaw2.strict_row_problems(readd), [])

    def test_legacy_pending_row_is_rewritten(self):
        # seed a row exactly like the pre-E5-fix sync wrote it: definition
        # current, status 'pending' - the app renders it invalid_response and
        # its Reconnect throws, so the apply must rewrite it pre-tested
        conn = sqlite3.connect(self.fixture.db_paths["c1"])
        conn.execute(
            "INSERT INTO governed_connected_sources (owner_id, workspace_id,"
            " kind, slug, name, endpoint, enabled, status, error_code,"
            " credential_version, source_permission, tool_permissions_json,"
            " revision, tools_json, updated_at)"
            " VALUES ((SELECT principal_id FROM identity_personal_principals"
            " LIMIT 1), (SELECT workspace_id FROM work_workspaces"
            " WHERE lifecycle = 'active' ORDER BY is_default DESC LIMIT 1),"
            " 'mcp', 'fs', 'FS', ?, 1, 'pending', NULL, NULL, 'allowed',"
            " '{}', ?, '[]', ?)",
            ("stdio+v1:" + json.dumps({"command": "npx", "args": ["-y", "x"]},
                                      separators=(",", ":")),
             "sync-v1:legacy", "2026-11-04T00:00:00.000Z"))
        conn.commit()
        conn.close()
        with mock.patch.object(autoclaw2, "test_source_locator", _fake_test):
            result = autoclaw2.mcp_apply(
                self._payload(manifest_path=self._manifest_with_one_server()))
        self.assertEqual(result["profiles"][0]["status"], "ok")
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            row = conn.execute(
                "SELECT status, error_code, tools_json FROM"
                " governed_connected_sources WHERE slug = 'fs'").fetchone()
        finally:
            conn.close()
        self.assertEqual(row[0], "connected")
        self.assertIsNone(row[1])
        self.assertIn("echo_tool", row[2])

    def test_reapply_is_unchanged(self):
        payload = self._payload(manifest_path=self._manifest_with_one_server())
        with mock.patch.object(autoclaw2, "test_source_locator", _fake_test):
            self.assertEqual(
                autoclaw2.mcp_apply(payload)["profiles"][0]["status"], "ok")
            second = autoclaw2.mcp_apply(payload)["profiles"][0]
        self.assertEqual(second["status"], "unchanged")
        self.assertEqual(second["action_count"], 0)

    def test_running_target_is_skipped(self):
        handle = self.fixture.hold_lock("c1")
        try:
            result = autoclaw2.mcp_apply(
                self._payload(manifest_path=self._manifest_with_one_server()))
        finally:
            self.fixture.release_lock(handle)
        self.assertEqual(result["profiles"][0]["status"], "skipped")
        self.assertEqual(result["profiles"][0]["reason"], "running")

    def test_not_signed_in_is_skipped(self):
        result = autoclaw2.mcp_apply(
            self._payload(targets=["c2"],
                          manifest_path=self._manifest_with_one_server()))
        self.assertEqual(result["profiles"][0]["reason"], "not-signed-in")


class _FakeMcpServerSource:
    """Minimal MCP stdio server used by DiscoverTests: answers initialize +
    tools/list with a tool set that exercises the IL mapping (clean name,
    hyphen rename + missing description, regex-failing name, oversized
    inputSchema)."""

    SCRIPT = (
        "import json, sys\n"
        "for line in sys.stdin:\n"
        "    line = line.strip()\n"
        "    if not line:\n"
        "        continue\n"
        "    try:\n"
        "        msg = json.loads(line)\n"
        "    except ValueError:\n"
        "        continue\n"
        "    if msg.get('method') == 'initialize':\n"
        "        print(json.dumps({'jsonrpc': '2.0', 'id': msg['id'],"
        " 'result': {'protocolVersion': '2025-03-26', 'capabilities': {},"
        " 'serverInfo': {'name': 'fake', 'version': '0'}}}), flush=True)\n"
        "    elif msg.get('method') == 'tools/list':\n"
        "        print(json.dumps({'jsonrpc': '2.0', 'id': msg['id'],"
        " 'result': {'tools': ["
        " {'name': 'echo_tool', 'description': 'Echoes input.',"
        " 'inputSchema': {'type': 'object'}},"
        " {'name': 'my-tool', 'inputSchema': {'type': 'object'}},"
        " {'name': 'bad name!', 'description': 'x'},"
        " {'name': '', 'description': 'x'},"
        " {'name': 'big_schema', 'description': 'x',"
        " 'inputSchema': {'type': 'object', 'x': 'y'*20000}}]}}),"
        " flush=True)\n"
    )


class DiscoverTests(unittest.TestCase):

    def _server_path(self):
        path = os.path.join(tempfile.mkdtemp(), "fake_mcp_server.py")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(_FakeMcpServerSource.SCRIPT)
        return path

    def test_discover_stdio_maps_tools_to_il_shape(self):
        tools, err = autoclaw2.discover_stdio(
            sys.executable, [self._server_path()], timeout=20)
        self.assertIsNone(err)
        mapped, dropped = autoclaw2._mcp_map_tools(tools)
        # 'bad name!' normalizes vme-style to bad_name_ (consistent with the
        # app's own permission lookups); only the empty name is dropped
        self.assertEqual([t["name"] for t in mapped],
                         ["echo_tool", "my_tool", "bad_name_", "big_schema"])
        self.assertEqual(dropped, 1)
        by_name = {t["name"]: t for t in mapped}
        self.assertEqual(by_name["my_tool"]["remoteName"], "my-tool")
        self.assertTrue(by_name["my_tool"]["description"])
        # the oversized junk-key schema is SANITIZED, not dropped (the junk
        # key is stripped and the object root gets its empty properties)
        self.assertEqual(by_name["big_schema"]["inputSchema"],
                         {"type": "object", "properties": {}})
        self.assertIn("inputSchema", by_name["echo_tool"])

    def test_discovered_tools_fit_the_strict_row(self):
        tools, err = autoclaw2.discover_stdio(
            sys.executable, [self._server_path()], timeout=20)
        self.assertIsNone(err)
        mapped, _ = autoclaw2._mcp_map_tools(tools)
        row = {"slug": "fake", "status": "connected", "error_code": None,
               "source_permission": "allowed",
               "endpoint": autoclaw2.STDIO_PREFIX + json.dumps(
                   {"command": "npx", "args": []}, separators=(",", ":")),
               "tools_json": json.dumps(mapped, separators=(",", ":")),
               "updated_at": "2026-11-05T00:00:00.000Z"}
        self.assertEqual(autoclaw2.strict_row_problems(row), [])

    def test_discover_stdio_missing_binary_fails(self):
        tools, err = autoclaw2.discover_stdio(
            "definitely-missing-exe-xyz", [], timeout=5)
        self.assertIsNone(tools)
        self.assertEqual(err, "connection_failed")

    def test_test_source_locator_stdio_roundtrip(self):
        locator = autoclaw2.STDIO_PREFIX + json.dumps(
            {"command": sys.executable,
             "args": [self._server_path()]}, separators=(",", ":"))
        out = autoclaw2.test_source_locator(locator, timeout=20)
        self.assertTrue(out["ok"])
        self.assertEqual(out["tool_count"], 4)
        self.assertEqual(out["dropped"], 1)

    def test_discover_http_401_maps_to_authentication_failed(self):
        import http.server
        import threading as _threading

        class _H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                # drain the request body first: closing without reading it
                # resets the connection before the client sees the 401
                length = int(self.headers.get("Content-Length") or 0)
                if length:
                    self.rfile.read(length)
                self.send_response(401)
                self.end_headers()

            def log_message(self, *args):
                pass

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _H)
        _threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            tools, err = autoclaw2.discover_http(
                "http://127.0.0.1:{0}/mcp".format(srv.server_address[1]),
                timeout=10)
        finally:
            srv.shutdown()
        self.assertIsNone(tools)
        self.assertEqual(err, "authentication_failed")


class StrictRowTests(unittest.TestCase):

    def _good_row(self, **over):
        row = {"slug": "playwright", "status": "connected",
               "error_code": None, "source_permission": "allowed",
               "endpoint": "https://mcp.vercel.com",
               "tools_json": json.dumps(
                   [{"name": "list_projects", "description": "Lists."}]),
               "updated_at": "2026-11-05T20:00:00.000Z"}
        row.update(over)
        return row

    def test_good_row_has_no_problems(self):
        self.assertEqual(autoclaw2.strict_row_problems(self._good_row()), [])

    def test_pending_status_is_a_problem(self):
        self.assertEqual(
            autoclaw2.strict_row_problems(self._good_row(status="pending")),
            ["status"])

    def test_hyphen_slug_is_a_problem(self):
        self.assertEqual(autoclaw2.strict_row_problems(
            self._good_row(slug="chrome-devtools")), ["slug"])

    def test_illegal_error_code_is_a_problem(self):
        self.assertEqual(autoclaw2.strict_row_problems(
            self._good_row(error_code="mystery")), ["error_code"])

    def test_empty_tool_description_is_a_problem(self):
        row = self._good_row(
            tools_json=json.dumps([{"name": "t", "description": ""}]))
        self.assertEqual(autoclaw2.strict_row_problems(row), ["tools_json"])

    def test_oversized_input_schema_is_a_problem(self):
        # the IL refine: one tool with a serialized schema over 16384 fails
        # the WHOLE row parse (cloudinary upload_asset, 20024 chars, live
        # 2026-11-06) - the verify-after gate must never wave it through
        row = self._good_row(tools_json=json.dumps([
            {"name": "ok_tool", "description": "Fine.",
             "inputSchema": {"type": "object", "properties": {}}},
            {"name": "fat_tool", "description": "Fat.",
             "inputSchema": {"type": "object",
                             "properties": {"q": {"type": "string",
                                                  "enum": ["v" * 20000]}}}}]))
        self.assertEqual(autoclaw2.strict_row_problems(row), ["tools_json"])

    def test_bad_remote_name_is_a_problem(self):
        row = self._good_row(tools_json=json.dumps([
            {"name": "t", "description": "d", "remoteName": "r" * 129}]))
        self.assertEqual(autoclaw2.strict_row_problems(row), ["tools_json"])

    def test_non_z_timestamp_is_a_problem(self):
        self.assertEqual(autoclaw2.strict_row_problems(
            self._good_row(updated_at="2026-11-05T20:00:00+02:00")),
            ["updated_at"])


class SlugMigrationTests(unittest.TestCase):

    def _row(self, slug, revision="sync-v1:abc"):
        return {"slug": slug, "kind": "mcp", "name": "X",
                "endpoint": "https://x", "enabled": True,
                "status": "connected", "error_code": None,
                "source_permission": "allowed",
                "tool_permissions_json": "{}", "revision": revision,
                "tools_json": "[]",
                "updated_at": "2026-11-05T00:00:00.000Z",
                "workspace_id": "w", "owner_id": "o", "has_credential": False}

    def test_sync_authored_hyphen_slug_migrates(self):
        migrations, rows = autoclaw2._plan_slug_migrations(
            [self._row("chrome-devtools")])
        self.assertEqual(migrations, [{"from": "chrome-devtools",
                                       "to": "chrome_devtools"}])
        self.assertEqual(rows[0]["slug"], "chrome_devtools")

    def test_app_authored_odd_slug_is_left_alone(self):
        migrations, rows = autoclaw2._plan_slug_migrations(
            [self._row("chrome-devtools",
                       revision="native.abcdef0123456789")])
        self.assertEqual(migrations, [])
        self.assertEqual(rows[0]["slug"], "chrome-devtools")

    def test_migration_skips_when_target_taken(self):
        migrations, rows = autoclaw2._plan_slug_migrations(
            [self._row("chrome-devtools"), self._row("chrome_devtools")])
        self.assertEqual(migrations, [])
        self.assertEqual([r["slug"] for r in rows],
                         ["chrome-devtools", "chrome_devtools"])


class ToolRevisionTests(unittest.TestCase):

    def test_deterministic_native_shape(self):
        a = autoclaw2.tool_revision("FS", "stdio+v1:x", "allowed",
                                    [{"name": "echo_tool",
                                      "description": "Echoes."}])
        b = autoclaw2.tool_revision("FS", "stdio+v1:x", "allowed",
                                    [{"name": "echo_tool",
                                      "description": "Echoes."}])
        self.assertEqual(a, b)
        self.assertTrue(a.startswith("native."))
        self.assertRegex(a[7:], r"^[0-9a-f]{16}$")
        self.assertNotEqual(a, autoclaw2.tool_revision(
            "FS", "stdio+v1:x", "allowed",
            [{"name": "other_tool", "description": "E."}]))


class SchemaBoundaryTests(unittest.TestCase):
    """The app's registration boundary (gL mirror): a stored schema that
    fails it flips the whole source to failed/invalid_response at startup."""

    def test_unsupported_keyword_is_stripped(self):
        cleaned = autoclaw2._sanitize_input_schema(
            {"type": "object",
             "properties": {"a": {"type": "string", "format": "date"}},
             "required": ["a"]})
        self.assertEqual(cleaned["properties"]["a"], {"type": "string"})

    def test_untyped_node_gets_explicit_any(self):
        cleaned = autoclaw2._sanitize_input_schema(
            {"type": "object", "properties": {"x": {}}})
        self.assertEqual(cleaned["properties"]["x"]["anyOf"],
                         [{"type": t} for t in autoclaw2._ANY_TYPE])

    def test_properties_node_becomes_object(self):
        cleaned = autoclaw2._sanitize_input_schema(
            {"type": "object", "properties": {
                "x": {"properties": {"y": {"type": "string"}}}}})
        self.assertEqual(cleaned["properties"]["x"]["type"], "object")

    def test_schema_form_additional_properties_is_stripped(self):
        cleaned = autoclaw2._sanitize_input_schema(
            {"type": "object", "properties": {},
             "additionalProperties": {"type": "string"}})
        self.assertNotIn("additionalProperties", cleaned)

    def test_root_without_properties_gets_empty_ones(self):
        self.assertEqual(autoclaw2._sanitize_input_schema({"type": "object"}),
                         {"type": "object", "properties": {}})

    def test_non_object_root_drops_the_tool(self):
        self.assertIsNone(autoclaw2._sanitize_input_schema({"type": "string"}))

    def test_oversized_schema_drops_the_tool(self):
        # description is truncated to 2048 by the walk, so the post-clean
        # 16384 arbiter is exercised through a channel that survives it:
        # enum values ride verbatim (the cloudinary upload_asset shape -
        # one over-limit schema fails the WHOLE row at startup)
        self.assertIsNone(autoclaw2._sanitize_input_schema(
            {"type": "object",
             "properties": {"x": {"type": "string",
                                  "enum": ["v" * 20000]}}}))

    def test_exact_16384_boundary(self):
        def build(n):
            return {"type": "object", "properties": {
                "q": {"type": "string", "enum": ["v" * n]}}}
        fixed = autoclaw2._json_utf16_len(
            autoclaw2._sanitize_input_schema(build(10))) - 10
        target = 16384 - fixed
        at_limit = autoclaw2._sanitize_input_schema(build(target))
        self.assertEqual(autoclaw2._json_utf16_len(at_limit), 16384)
        self.assertIsNotNone(at_limit)
        self.assertIsNone(autoclaw2._sanitize_input_schema(build(target + 1)))

    def test_bloat_from_stripped_keys_shrinks_below_limit(self):
        # 30KB of junk keys vanishes in the walk - the RAW size is not the
        # arbiter, the CLEANED one is
        cleaned = autoclaw2._sanitize_input_schema(
            {"type": "object", "junk": "z" * 30000, "properties": {}})
        self.assertIsNotNone(cleaned)
        self.assertEqual(autoclaw2._json_utf16_len(cleaned),
                         len('{"type":"object","properties":{}}'))

    def test_sanitization_is_idempotent(self):
        schema = {"type": "object", "properties": {
            "a": {"type": "string", "format": "date"},
            "b": {}, "c": {"items": {"description": "d"}}}}
        once = autoclaw2._sanitize_input_schema(schema)
        self.assertEqual(autoclaw2._sanitize_input_schema(once), once)

    def test_map_tools_uses_sanitized_schemas(self):
        mapped, dropped = autoclaw2._mcp_map_tools([
            {"name": "t1", "description": "d",
             "inputSchema": {"type": "object", "properties": {
                 "a": {"type": "string", "title": "A"}}}},
            {"name": "t2", "description": "d",
             "inputSchema": {"type": "string"}},
        ])
        self.assertEqual(dropped, 1)  # non-object root drops the tool
        self.assertNotIn("title", mapped[0]["inputSchema"]["properties"]["a"])


class ChatImportTests(_PatchedHome):

    def _import_payload(self, session_id, **over):
        payload = {"source": "Primary", "target": "c1",
                   "session_id": session_id}
        payload.update(over)
        return payload

    def test_im_session_refused(self):
        sid, _ = self.fixture.session("Primary", external_provider="telegram")
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.chat_import(self._import_payload(sid))
        self.assertEqual(ctx.exception.code, "im-session")

    def test_dry_run_writes_nothing(self):
        sid, _ = self.fixture.session("Primary")
        before = open(self.fixture.db_paths["c1"], "rb").read()
        result = autoclaw2.chat_import(self._import_payload(sid, dry_run=True))
        self.assertEqual(result["status"], "dry-run")
        self.assertEqual(result["entries"], 2)
        self.assertEqual(result["events"], 2)
        self.assertEqual(open(self.fixture.db_paths["c1"], "rb").read(), before)

    def test_running_target_refused(self):
        sid, _ = self.fixture.session("Primary")
        handle = self.fixture.hold_lock("c1")
        try:
            with self.assertRaises(autoclaw2.Refusal) as ctx:
                autoclaw2.chat_import(self._import_payload(sid))
            self.assertEqual(ctx.exception.code, "target-running")
        finally:
            self.fixture.release_lock(handle)

    def test_apply_copies_with_remap_and_nulls_credentials(self):
        sid, run_id = self.fixture.session("Primary")
        result = autoclaw2.chat_import(self._import_payload(sid))
        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["new_session_id"] != sid)
        self.assertTrue(result["title"].startswith("[import] "))
        self.assertEqual(result["verify"],
                         {"sessions": 1, "entries": 2, "runs": 1, "events": 2,
                          "heads": 1, "fts": 2, "artifacts": 1})
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            run = conn.execute(
                "SELECT credential_version, merged_into_run_id FROM work_runs"
                " WHERE session_id = ?", (result["new_session_id"],)).fetchone()
            head = conn.execute(
                "SELECT conversation_run_id, entry_count, next_session_seq"
                " FROM neutral_session_heads WHERE session_id = ?",
                (result["new_session_id"],)).fetchone()
            fts = conn.execute(
                "SELECT entry_id, body FROM neutral_session_fts"
                " WHERE session_id = ?", (result["new_session_id"],)).fetchall()
            events = conn.execute(
                "SELECT event_id, run_id, payload_json FROM work_events"
                " WHERE session_id = ?", (result["new_session_id"],)).fetchall()
            self.assertEqual(conn.execute(
                "SELECT COUNT(*) FROM governed_tool_artifact_custody"
                " WHERE artifact_id IN (SELECT artifact_id FROM"
                " governed_tool_artifacts WHERE session_id = ?)",
                (result["new_session_id"],)).fetchone()[0], 1)
        finally:
            conn.close()
        self.assertEqual(run[0], None)          # credential_version nulled (D4)
        self.assertNotEqual(head[0], run_id)    # head run id remapped
        self.assertEqual((head[1], head[2]), (2, 3))
        self.assertEqual(len(fts), 2)
        self.assertTrue(all(eid.startswith(head[0]) for eid, _ in fts))
        bodies = {b for _, b in fts}
        self.assertIn("hello fixture question", bodies)
        self.assertEqual(len(events), 2)
        self.assertTrue(all(e[1] == head[0] for e in events))  # run remapped
        self.assertEqual(sorted(json.loads(e[2])["seq"] for e in events), [1, 2])

    def test_accept_order_remapped_not_copied(self):
        # live-schema regression (2026-11-09): the real schema carries
        # CREATE UNIQUE INDEX uniq_work_accept_order ON work_runs(accept_order)
        # - globally unique per account DB - so verbatim copies collide with
        # the target's existing runs. The import must assign fresh values
        # from the target's tail while preserving relative order.
        self.fixture.session("c1", title="local")            # accept_order 1
        sid, _ = self.fixture.session("Primary")             # accept_order 1
        conn = sqlite3.connect(self.fixture.db_paths["Primary"])
        conn.execute(
            "INSERT INTO work_runs (run_id, session_id, status, text,"
            " accept_order, created_at, updated_at) VALUES (?,?,?,?,?,?,?)",
            (UUID4(), sid, "completed", "second run", 7,
             "2026-01-01T00:02:00.000Z", "2026-01-01T00:02:00.000Z"))
        conn.commit()
        conn.close()
        result = autoclaw2.chat_import(self._import_payload(sid))
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["verify"]["runs"], 2)
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            rows = conn.execute(
                "SELECT session_id, accept_order FROM work_runs"
                " ORDER BY accept_order").fetchall()
        finally:
            conn.close()
        orders = [o for _, o in rows]
        self.assertEqual(len(orders), len(set(orders)))   # uniqueness holds
        imp = [o for s, o in rows if s == result["new_session_id"]]
        self.assertEqual(sorted(imp), [2, 3])             # target tail, not 1/7
        self.assertNotIn(1, imp)                          # collision avoided
        self.assertLess(imp[0], imp[1])                   # relative order kept

    def test_reimport_skips_on_same_content(self):
        sid, _ = self.fixture.session("Primary")
        first = autoclaw2.chat_import(self._import_payload(sid))
        second = autoclaw2.chat_import(self._import_payload(sid))
        self.assertEqual(first["status"], "ok")
        self.assertEqual(second["status"], "skipped")
        self.assertEqual(second["reason"], "already-imported")

    def test_revert_removes_exactly_the_import(self):
        keep_sid, _ = self.fixture.session("c1", title="local")
        sid, _ = self.fixture.session("Primary")
        result = autoclaw2.chat_import(self._import_payload(sid))
        reverted = autoclaw2.chat_revert(
            {"target": "c1", "import_id": result["import_id"]})
        self.assertEqual(reverted["status"], "ok")
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            left = conn.execute(
                "SELECT COUNT(*) FROM work_sessions WHERE title = 'local'"
                " AND deleted_at IS NULL").fetchone()[0]
            imported_left = conn.execute(
                "SELECT COUNT(*) FROM work_sessions WHERE session_id = ?",
                (result["new_session_id"],)).fetchone()[0]
            events_left = conn.execute(
                "SELECT COUNT(*) FROM work_events WHERE session_id = ?",
                (result["new_session_id"],)).fetchone()[0]
        finally:
            conn.close()
        self.assertEqual((left, imported_left, events_left), (1, 0, 0))

    def test_unresolved_threshold_aborts(self):
        # an entry whose run is missing from the tree cannot happen via the
        # session seeder, so simulate with a session that has an entry in a
        # foreign run
        sid, run_id = self.fixture.session("Primary", with_head=False)
        conn = sqlite3.connect(self.fixture.db_paths["Primary"])
        conn.execute(
            "INSERT INTO neutral_session_entries (session_id, entry_id,"
            " session_seq, run_id, entry_type, payload, committed_at)"
            " VALUES (?,?,?,?,?,?,?)",
            (sid, "{0}:request".format(UUID4()), 3, UUID4(), "tool_result",
             "{}", "2026-01-01T00:00:02.000Z"))
        conn.commit()
        conn.close()
        with self.assertRaises(autoclaw2.Refusal) as ctx:
            autoclaw2.chat_import(self._import_payload(sid, max_unresolved_pct=0))
        self.assertEqual(ctx.exception.code, "unresolved-threshold")


class RedactionTests(_PatchedHome):

    def test_inventory_never_carries_bodies_or_credentials(self):
        self.fixture.session("Primary", title="secret-title-marker")
        payload = autoclaw2.profile_inventory({"targets": ["Primary"]})
        blob = json.dumps(payload)
        self.assertNotIn("secret-title-marker", blob)
        self.assertNotIn("credential_version", blob)


class CliContractTests(_PatchedHome):

    def test_inventory_cli_exit_zero(self):
        proc = subprocess.run(
            [sys.executable, GHOST_CLI, "ac2-inventory", _b64({"targets": ["c1"]})],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout)
        self.assertEqual(data["profiles"][0]["profile"], "c1")

    def test_chat_import_refusal_exit_two(self):
        sid, _ = self.fixture.session("Primary", external_provider="telegram")
        proc = subprocess.run(
            [sys.executable, GHOST_CLI, "ac2-chat-import",
             _b64({"source": "Primary", "target": "c1", "session_id": sid})],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("refused", proc.stdout)


class ExpandEnvValueTests(unittest.TestCase):
    """expand_env_value: ${VAR} placeholders resolve from the environment so no
    literal ref/token lands in the tracked master file (2026-11-07 scrub)."""

    def test_resolves_known_placeholder(self):
        with mock.patch.dict(os.environ, {"SUPABASE_PROJECT_REF_TEST": "abc123"}):
            self.assertEqual(
                [autoclaw2.expand_env_value(a)
                 for a in ["--project-ref", "${SUPABASE_PROJECT_REF_TEST}"]],
                ["--project-ref", "abc123"])

    def test_unresolved_placeholder_left_as_is(self):
        os.environ.pop("GHOST_DEFINITELY_UNSET_XYZ", None)
        self.assertEqual(autoclaw2.expand_env_value("${GHOST_DEFINITELY_UNSET_XYZ}"),
                         "${GHOST_DEFINITELY_UNSET_XYZ}")

    def test_non_string_passthrough(self):
        self.assertEqual(autoclaw2.expand_env_value(42), 42)
        self.assertIsNone(autoclaw2.expand_env_value(None))

    def test_load_manifest_expands_args(self):
        # End-to-end through load_manifest: a placeholder in args resolves and
        # the canonical locator is built from the EXPANDED values.
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "master.json")
            with open(p, "w", encoding="utf-8") as fh:
                json.dump({"schemaVersion": 1,
                           "defaults": {"enabled": True,
                                        "sourcePermission": "allowed"},
                           "servers": [{"slug": "supabase", "name": "Supabase",
                                        "transport": "stdio", "command": "node",
                                        "args": ["cli.js", "--project-ref",
                                                 "${SUPABASE_PROJECT_REF_TEST2}"],
                                        "enabled": True}]}, fh)
            with mock.patch.dict(os.environ,
                                 {"SUPABASE_PROJECT_REF_TEST2": "ref12345"}):
                m = autoclaw2.load_manifest(p)
            self.assertEqual(m["servers"][0]["args"],
                             ["cli.js", "--project-ref", "ref12345"])


if __name__ == "__main__":
    unittest.main()
