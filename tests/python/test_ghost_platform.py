"""Unit tests for the cross-platform store-path maps (ghost.platform)."""

import os
import unittest

from ghost import platform


class SlugResolutionTests(unittest.TestCase):
    def test_known_slug_resolves(self):
        report = platform.get_store_paths("zcode")
        self.assertIn(report["platform"], ("windows", "linux"))
        self.assertEqual(report["slug"], "zcode")
        self.assertTrue(report["paths"])
        for label, path in report["paths"].items():
            self.assertFalse(path.startswith("~"), "paths must be ~-expanded")

    def test_alias_windsurf_maps_to_devin(self):
        report = platform.get_store_paths("windsurf")
        self.assertEqual(report["slug"], "devin")

    def test_alias_opencode_maps_to_opencode_cli(self):
        report = platform.get_store_paths("opencode")
        self.assertEqual(report["slug"], "opencode-cli")

    def test_unknown_slug_raises_value_error(self):
        with self.assertRaises(ValueError):
            platform.get_store_paths("nosuchapp")

    def test_desktop_clone_suites_deliberately_unmapped(self):
        # No Linux builds discovered for these - guessing is forbidden
        # (ground truth #5); the map stays extensible instead.
        for slug in ("autoclaw2", "cline", "opencode-desktop"):
            with self.assertRaises(ValueError):
                platform.get_store_paths(slug)


class MapIntegrityTests(unittest.TestCase):
    def test_every_entry_has_both_platforms_and_verified_flag(self):
        for slug, platforms in platform.STORE_PATHS.items():
            self.assertEqual(set(platforms.keys()), {"windows", "linux"},
                             "slug '%s' must map both platforms" % slug)
            for plat, entries in platforms.items():
                self.assertTrue(entries, "slug '%s' platform '%s' empty" % (slug, plat))
                for label, entry in entries.items():
                    self.assertIn("path", entry)
                    self.assertIn("verified", entry)
                    self.assertIsInstance(entry["verified"], bool)

    def test_home_expansion_uses_current_user(self):
        report = platform.get_store_paths("zcode")
        home = os.path.expanduser("~")
        for path in report["paths"].values():
            self.assertTrue(path.startswith(home),
                            "path %r must live under %r" % (path, home))

    def test_unverified_rows_are_listed(self):
        # cursor/devin/opencode-cli are verified on BOTH platforms (existing
        # shipped scripts / live probing). trae/qoder/qoderwork carry derived
        # LINUX rows that MUST be surfaced as unverified (their Windows sides
        # are proven by the shipped reset scripts, so the assertion is on the
        # linux map, not the current platform).
        for slug in ("cursor", "devin", "opencode-cli"):
            self.assertEqual(platform.get_store_paths(slug)["unverified"], [],
                             "slug '%s' should be fully verified" % slug)
        for slug in ("trae", "qoder", "qoderwork", "zcode"):
            linux_unverified = [label for label, entry in
                                platform.STORE_PATHS[slug]["linux"].items()
                                if not entry["verified"]]
            self.assertTrue(linux_unverified,
                            "slug '%s' should carry unverified linux rows" % slug)

    def test_zcode_windows_verified_but_linux_config_unverified(self):
        win = platform.STORE_PATHS["zcode"]["windows"]
        linux = platform.STORE_PATHS["zcode"]["linux"]
        self.assertTrue(win["cli_dir"]["verified"])
        self.assertTrue(all(e["verified"] for e in win.values()))
        self.assertFalse(linux["config"]["verified"])
        # the shared CLI db path is platform-agnostic per the docs - keep it
        # flagged until a Linux host verifies it
        self.assertFalse(linux["cli_db"]["verified"])


if __name__ == "__main__":
    unittest.main()
