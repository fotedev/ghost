"""Unit tests for the cross-platform store-path maps (ghost.platform)."""

import os
import unittest
from unittest import mock

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
            # Every slug maps all three platforms (the macOS groundwork
            # completed the column for every slug, 2026-11-18); anything
            # else is unknown.
            self.assertEqual(
                set(platforms.keys()), {"windows", "linux", "macos"},
                "slug '%s' must map exactly windows+linux+macos" % slug)
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

    def test_deepened_linux_labels_exist_and_stay_unverified(self):
        # 2026-11-17 deepening wave: the Linux resets resolve the deeper
        # Windows-proven stores through these labels. They are DERIVED
        # (Windows layout + Electron/XDG conventions) and MUST stay flagged
        # until a live Linux host verifies them (ground truth #5).
        expected = {
            "trae": {"machineid_file", "local_env"},
            "qoder": {"installation_id", "auth_machine_id"},
            "qoderwork": {"agents_db"},
            "zcode": {"telemetry_state", "credentials", "setting_json"},
            "minimax": {"mcode_public", "session_handoff_device_id"},
        }
        for slug, labels in expected.items():
            linux = platform.STORE_PATHS[slug]["linux"]
            for label in labels:
                self.assertIn(label, linux, "slug '%s' missing label '%s'" % (slug, label))
                self.assertFalse(linux[label]["verified"],
                                 "label '%s' of '%s' must stay unverified until live-checked"
                                 % (label, slug))

    def test_deepened_linux_labels_resolve_under_home(self):
        for slug in ("trae", "qoder", "qoderwork", "zcode", "minimax"):
            report = platform.get_store_paths(slug)
            home = os.path.expanduser("~")
            for path in report["paths"].values():
                self.assertTrue(path.startswith(home))

    def test_qoder_macos_rows_exist_and_stay_derived(self):
        # 2026-11-17 macOS wave (issue #36): Electron userData on macOS lives
        # under ~/Library/Application Support/<App>; the dot-dir is
        # platform-agnostic per the Linux wave. Every row is DERIVED
        # (Windows layout + documented platform conventions) and MUST stay
        # flagged until a live Mac verifies it (ground truth #5).
        macos = platform.STORE_PATHS["qoder"]["macos"]
        self.assertEqual(set(macos.keys()),
                         {"config", "qoder_dir", "installation_id", "auth_machine_id"})
        for label, entry in macos.items():
            self.assertFalse(entry["verified"],
                             "macos label '%s' of 'qoder' must stay unverified "
                             "until a live Mac verifies it" % label)
        home = os.path.expanduser("~")
        for entry in macos.values():
            expanded = os.path.expanduser(entry["path"])
            self.assertTrue(expanded.startswith(home),
                            "macos path %r must live under %r"
                            % (expanded, home))
        self.assertIn("Library", macos["config"]["path"].replace("\\", "/"))

    def test_darwin_selects_macos_rows_and_surfaces_unverified(self):
        # The selector reads sys.platform live, so the darwin branch is
        # testable on any CI OS.
        with mock.patch.object(platform.sys, "platform", "darwin"):
            report = platform.get_store_paths("qoder")
        self.assertEqual(report["platform"], "macos")
        self.assertEqual(report["slug"], "qoder")
        self.assertTrue(report["paths"])
        self.assertTrue(report["unverified"],
                        "derived macOS rows must surface as unverified")

    def test_darwin_resolves_every_slug(self):
        # The macOS groundwork maps every slug, so a darwin host resolves
        # all of them to macos rows - never a silent linux fallback, and
        # never an "unmapped" error for a shipped slug.
        for slug in platform.STORE_PATHS:
            with mock.patch.object(platform.sys, "platform", "darwin"):
                report = platform.get_store_paths(slug)
            self.assertEqual(report["platform"], "macos",
                             "slug '%s' must resolve on darwin" % slug)
            self.assertEqual(report["slug"], slug)
            self.assertTrue(report["paths"])

    def test_all_macos_rows_exist_and_stay_derived(self):
        # 2026-11-18 macOS map groundwork: every slug carries macos rows and
        # every one of them is DERIVED (Windows layout + documented platform
        # conventions) and MUST stay flagged until a live Mac verifies it
        # (ground truth #5). No macOS resetter ships for these slugs yet -
        # a resetter landing flips its rows' provenance explicitly.
        home = os.path.expanduser("~")
        for slug, platforms in platform.STORE_PATHS.items():
            macos = platforms["macos"]
            self.assertTrue(macos, "slug '%s' has no macos rows" % slug)
            for label, entry in macos.items():
                self.assertFalse(entry["verified"],
                                 "macos label '%s' of '%s' must stay unverified "
                                 "until a live Mac verifies it" % (label, slug))
                expanded = os.path.expanduser(entry["path"])
                self.assertTrue(expanded.startswith(home),
                                "macos path %r of '%s' must live under %r"
                                % (expanded, slug, home))

    def test_linux_selector_still_resolves_after_macos_column(self):
        with mock.patch.object(platform.sys, "platform", "linux"):
            report = platform.get_store_paths("qoder")
        self.assertEqual(report["platform"], "linux")


if __name__ == "__main__":
    unittest.main()
