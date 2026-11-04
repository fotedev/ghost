"""unittest suite for the AutoClaw2 (zwork) sync core (src/python/ghost/autoclaw2.py).

Stdlib only. The fixture builds a schema SUBSET that is byte-honest for the
surfaces this module touches: the real CHECK constraints on
neutral_session_entries/heads, the real freeze + delete-after-tombstone
triggers, a real FTS5 table, and the UUID-shape CHECKs on work_events.

Run from repo root:
    python -m unittest discover -s tests/python -v
"""

import base64
import ctypes
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))))
GHOST_CLI = os.path.join(REPO_ROOT, "src", "python", "ghost_cli.py")

sys.path.insert(0, os.path.join(REPO_ROOT, "src", "python"))

from ghost import autoclaw2  # noqa: E402


def _b64(payload):
    return base64.b64encode(
        json.dumps(payload).encode("utf-8")).decode("ascii")


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
        conn.execute(
            "INSERT INTO work_runs (run_id, session_id, status, text,"
            " connection_model, credential_version) VALUES (?,?,?,?,?,?)",
            (run_id, sid, "completed", title, "glm-5.3", "cred-version-1"))
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
               "status": "pending", "source_permission": "allowed",
               "tool_permissions_json": "{}", "revision": "r1",
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

    def test_apply_creates_pending_rows_and_verifies(self):
        payload = self._payload(manifest_path=self._manifest_with_one_server())
        result = autoclaw2.mcp_apply(payload)
        entry = result["profiles"][0]
        self.assertEqual(entry["status"], "ok")
        self.assertEqual(entry["written"], 1)
        conn = autoclaw2.ro_connect(self.fixture.db_paths["c1"])
        try:
            row = conn.execute(
                "SELECT status, tools_json, credential_version, enabled FROM"
                " governed_connected_sources WHERE slug = 'fs'").fetchone()
        finally:
            conn.close()
        self.assertEqual((row[0], row[1], row[2], row[3]),
                         ("pending", "[]", None, 1))

    def test_reapply_is_unchanged(self):
        payload = self._payload(manifest_path=self._manifest_with_one_server())
        self.assertEqual(autoclaw2.mcp_apply(payload)["profiles"][0]["status"], "ok")
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


if __name__ == "__main__":
    unittest.main()
