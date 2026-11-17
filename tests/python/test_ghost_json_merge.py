"""Unit tests for the json-merge-defs core verb (ghost.json_merge) - the
Python port of the zcode_mcp_merge.ps1 invariant that the Linux MCP sync
rides. The invariant cases mirror the Windows merge-core tests (clone-local
enabled survives, clone-only kept, new entries inherit Primary, Primary
wins, Primary never mutated) plus the file-level contract (backup +
verify-after + names-only report + dry-run zero-write)."""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "src", "python"))

from ghost import json_merge  # noqa: E402


def _doc(servers):
    return {"mcp": {"servers": servers}, "plugins": {"kept": True}, "hooks": [1, 2]}


PRIMARY = _doc({
    "alpha": {"command": "a", "enabled": True, "v": 1},
    "beta": {"command": "b", "enabled": False},
    "gamma": {"command": "g", "env": {"K": "V"}},
})
CLONE = _doc({
    "alpha": {"command": "STALE", "enabled": False, "extra": "local-only"},
    "zeta": {"command": "z", "enabled": True},
})


class MergeDefsTests(unittest.TestCase):
    def test_primary_definition_wins_but_clone_enabled_survives(self):
        merged, plan = json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        self.assertEqual(merged["mcp"]["servers"]["alpha"]["command"], "a")
        self.assertEqual(merged["mcp"]["servers"]["alpha"]["v"], 1)
        # clone-local toggle survives even though Primary says True
        self.assertFalse(merged["mcp"]["servers"]["alpha"]["enabled"])
        self.assertEqual(plan["updated"], ["alpha"])

    def test_clone_local_extra_keys_are_replaced_by_primary_definition(self):
        # "Primary definitions win" is entry-granular: a Primary entry replaces
        # the clone's wholesale except the preserved keys (the zcode core does
        # not merge foreign keys back into the Primary shape).
        merged, _ = json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        self.assertNotIn("extra", merged["mcp"]["servers"]["alpha"])

    def test_new_entries_inherit_primary_wholesale(self):
        merged, plan = json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        self.assertEqual(merged["mcp"]["servers"]["beta"], PRIMARY["mcp"]["servers"]["beta"])
        self.assertIn("beta", plan["added"])

    def test_clone_only_entries_are_kept(self):
        merged, plan = json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        self.assertEqual(merged["mcp"]["servers"]["zeta"]["command"], "z")
        self.assertEqual(plan["clone_only"], ["zeta"])

    def test_non_dict_entries_take_primary_value_wholesale(self):
        primary = {"mcp": {"servers": {"scalar": 7}}}
        clone = {"mcp": {"servers": {"scalar": 3}}}
        merged, plan = json_merge.merge_defs(primary, clone, "mcp.servers", ["enabled"])
        self.assertEqual(merged["mcp"]["servers"]["scalar"], 7)
        self.assertEqual(plan["updated"], ["scalar"])

    def test_area_scoped_everything_outside_base_path_stays_clone_local(self):
        merged, _ = json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        self.assertEqual(merged["plugins"], {"kept": True})
        self.assertEqual(merged["hooks"], [1, 2])

    def test_primary_document_is_never_mutated(self):
        before = json.dumps(PRIMARY, sort_keys=True)
        json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        self.assertEqual(json.dumps(PRIMARY, sort_keys=True), before)

    def test_idempotent_second_merge_is_all_unchanged(self):
        merged1, _ = json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        merged2, plan2 = json_merge.merge_defs(PRIMARY, merged1, "mcp.servers", ["enabled"])
        self.assertEqual(plan2["added"], [])
        self.assertEqual(plan2["updated"], [])
        self.assertEqual(plan2["unchanged"], ["alpha", "beta", "gamma"])

    def test_missing_primary_base_path_is_a_no_op(self):
        merged, plan = json_merge.merge_defs({}, CLONE, "mcp.servers", ["enabled"])
        self.assertEqual(plan["added"], [])
        self.assertEqual(plan["updated"], [])
        self.assertEqual(merged["mcp"]["servers"], CLONE["mcp"]["servers"])

    def test_scalar_base_path_segment_raises(self):
        doc = {"mcp": {"servers": 5}}
        with self.assertRaises(ValueError):
            json_merge.merge_defs(doc, CLONE, "mcp.servers", ["enabled"])

    def test_dotted_preserve_key_inside_entry(self):
        primary = {"mcp": {"servers": {"a": {"opts": {"deep": "P"}, "x": 1}}}}
        clone = {"mcp": {"servers": {"a": {"opts": {"deep": "C"}, "x": 1}}}}
        merged, plan = json_merge.merge_defs(
            primary, clone, "mcp.servers", ["opts.deep"])
        self.assertEqual(merged["mcp"]["servers"]["a"]["opts"]["deep"], "C")
        self.assertEqual(merged["mcp"]["servers"]["a"]["x"], 1)
        self.assertEqual(plan["unchanged"], ["a"])


class MergeDefsFileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ghost-json-merge-")
        self.primary = os.path.join(self.tmp, "primary.json")
        self.clone = os.path.join(self.tmp, "clone.json")
        self.backup_root = os.path.join(self.tmp, "backups")
        with open(self.primary, "w", encoding="utf-8") as f:
            json.dump(PRIMARY, f)
        with open(self.clone, "w", encoding="utf-8") as f:
            json.dump(CLONE, f)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_file_merge_writes_verifies_and_reports_names_only(self):
        report = json_merge.merge_defs_file(
            self.primary, self.clone, "mcp.servers", ["enabled"],
            backup_root=self.backup_root, label="t")
        self.assertTrue(report["ok"])
        self.assertTrue(report["verified"])
        self.assertTrue(report["changed"])
        self.assertEqual(report["added"], ["beta", "gamma"])
        self.assertEqual(report["updated"], ["alpha"])
        self.assertEqual(report["clone_only"], ["zeta"])
        # values never cross the report (names only)
        blob = json.dumps(report)
        self.assertNotIn("STALE", blob)
        self.assertNotIn("local-only", blob)
        # backup landed
        self.assertIsNotNone(report["backed_up_to"])
        self.assertTrue(os.path.exists(report["backed_up_to"]))
        # no-BOM write, verified on disk
        with open(self.clone, "rb") as f:
            self.assertFalse(f.read(3) == b"\xef\xbb\xbf")

    def test_dry_run_writes_nothing(self):
        report = json_merge.merge_defs_file(
            self.primary, self.clone, "mcp.servers", ["enabled"], dry_run=True)
        self.assertTrue(report["ok"])
        self.assertTrue(report["dry_run"])
        self.assertTrue(report["changed"])
        self.assertIsNone(report["backed_up_to"])
        with open(self.clone, "r", encoding="utf-8-sig") as f:
            self.assertEqual(json.load(f), CLONE)

    def test_in_sync_clone_is_unchanged_without_write(self):
        merged, _ = json_merge.merge_defs(PRIMARY, CLONE, "mcp.servers", ["enabled"])
        with open(self.clone, "w", encoding="utf-8") as f:
            json.dump(merged, f)
        report = json_merge.merge_defs_file(
            self.primary, self.clone, "mcp.servers", ["enabled"],
            backup_root=self.backup_root)
        self.assertTrue(report["ok"])
        self.assertFalse(report["changed"])
        self.assertIsNone(report["backed_up_to"])

    def test_missing_primary_file_is_a_failure_report(self):
        report = json_merge.merge_defs_file(
            os.path.join(self.tmp, "nope.json"), self.clone,
            "mcp.servers", ["enabled"])
        self.assertFalse(report["ok"])
        self.assertIsNotNone(report["error"])

    def test_missing_clone_file_is_a_failure_report(self):
        report = json_merge.merge_defs_file(
            self.primary, os.path.join(self.tmp, "nope.json"),
            "mcp.servers", ["enabled"])
        self.assertFalse(report["ok"])

    def test_cli_verb_end_to_end(self):
        import subprocess
        cli = os.path.join(os.path.dirname(__file__), "..", "..", "src", "python", "ghost_cli.py")
        proc = subprocess.run(
            [sys.executable, cli, "json-merge-defs", self.primary, self.clone,
             "--base-path", "mcp.servers", "--preserve-keys", "enabled",
             "--backup-root", self.backup_root, "--label", "t"],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertTrue(out["ok"])
        self.assertEqual(out["added"], ["beta", "gamma"])

    def test_cli_verb_dry_run_exit_zero_without_write(self):
        import subprocess
        cli = os.path.join(os.path.dirname(__file__), "..", "..", "src", "python", "ghost_cli.py")
        before = open(self.clone, "rb").read()
        proc = subprocess.run(
            [sys.executable, cli, "json-merge-defs", self.primary, self.clone,
             "--base-path", "mcp.servers", "--dry-run"],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(open(self.clone, "rb").read(), before)


if __name__ == "__main__":
    unittest.main()
