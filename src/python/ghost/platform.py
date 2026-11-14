"""Cross-platform identity-store path maps for the GHOST reset scripts.

Single source of truth for WHERE each agent keeps its identity stores, per
OS. The PS reset scripts (Windows) carry their paths inline (proven live);
the .sh reset scripts (Linux) resolve theirs through this module via the
``paths`` CLI verb (``ghost_cli.py paths <slug>`` -> JSON), so a path fix
lands in ONE place.

Provenance rules (ground truth #5 - never guess silently):
- ``"verified": True``  = read-verified on a live install or covered by an
  existing shipped script (cursor/windsurf Linux scripts have been in the
  repo and CI since 2026-09; Windows paths carry the reset scripts' live
  provenance).
- ``"verified": False`` = derived from the Windows layout + the app's
  documented Linux conventions (Electron apps keep their userData under
  ~/.config/<App> on Linux, XDG_DATA_HOME for CLI data). Every unverified
  row is listed in the ``paths`` verb output so a caller can print the
  caveat loudly - live Linux verification is the follow-up.

The Windows column exists so the same verb can serve cross-platform callers
and future PS adoption; the PS scripts do NOT consume it yet (their inline
paths stay the proven source until a migration says otherwise).
"""

import os
import sys

IS_WINDOWS = sys.platform.startswith("win")


def _home(rel):
    return os.path.join("~", rel)


# Per-app path maps. Template values may start with "~" (expanded by
# get_store_paths). Each entry: label -> {"path": template, "verified": bool}.
# Windows templates use ~ expansion against USERPROFILE-equivalent semantics
# (expanduser handles it); APPDATA-style paths are expressed as
# ~/AppData/Roaming/... which matches the real layout on every GHOST host.
STORE_PATHS = {
    "cursor": {
        "windows": {
            "roaming": {"path": "~/AppData/Roaming/Cursor", "verified": True},
            "storage_json": {"path": "~/AppData/Roaming/Cursor/User/globalStorage/storage.json", "verified": True},
            "state_vscdb": {"path": "~/AppData/Roaming/Cursor/User/globalStorage/state.vscdb", "verified": True},
        },
        "linux": {
            "config": {"path": _home(".config/Cursor"), "verified": True},
            "storage_json": {"path": _home(".config/Cursor/User/globalStorage/storage.json"), "verified": True},
            "state_vscdb": {"path": _home(".config/Cursor/User/globalStorage/state.vscdb"), "verified": True},
        },
    },
    "devin": {
        "windows": {
            "roaming": {"path": "~/AppData/Roaming/Devin", "verified": True},
            "windsurf_dir": {"path": "~/.windsurf", "verified": True},
            "codeium_dir": {"path": "~/.codeium", "verified": True},
        },
        "linux": {
            "config": {"path": _home(".config/Windsurf"), "verified": True},
            "windsurf_dir": {"path": _home(".windsurf"), "verified": True},
            "codeium_dir": {"path": _home(".codeium"), "verified": True},
        },
    },
    "trae": {
        "windows": {
            "roaming": {"path": "~/AppData/Roaming/Trae", "verified": True},
            "trae_dir": {"path": "~/.trae", "verified": True},
        },
        "linux": {
            "config": {"path": _home(".config/Trae"), "verified": False},
            "trae_dir": {"path": _home(".trae"), "verified": False},
        },
    },
    "qoder": {
        "windows": {
            "roaming": {"path": "~/AppData/Roaming/Qoder", "verified": True},
            "qoder_dir": {"path": "~/.qoder", "verified": True},
        },
        "linux": {
            "config": {"path": _home(".config/Qoder"), "verified": False},
            "qoder_dir": {"path": _home(".qoder"), "verified": False},
        },
    },
    "qoderwork": {
        "windows": {
            "roaming": {"path": "~/AppData/Roaming/QoderWork", "verified": True},
            "qoderwork_dir": {"path": "~/.qoderwork", "verified": True},
        },
        "linux": {
            "config": {"path": _home(".config/QoderWork"), "verified": False},
            "qoderwork_dir": {"path": _home(".qoderwork"), "verified": False},
        },
    },
    "zcode": {
        "windows": {
            "roaming": {"path": "~/AppData/Roaming/ZCode", "verified": True},
            "cli_dir": {"path": "~/.zcode", "verified": True},
            "cli_config": {"path": "~/.zcode/cli/config.json", "verified": True},
            "cli_db": {"path": "~/.zcode/cli/db/db.sqlite", "verified": True},
        },
        "linux": {
            "config": {"path": _home(".config/ZCode"), "verified": False},
            "cli_dir": {"path": _home(".zcode"), "verified": True},
            "cli_config": {"path": _home(".zcode/cli/config.json"), "verified": False},
            "cli_db": {"path": _home(".zcode/cli/db/db.sqlite"), "verified": False},
        },
    },
    "minimax": {
        "windows": {
            "roaming": {"path": "~/AppData/Roaming/MiniMax", "verified": True},
            "minimax_dir": {"path": "~/.minimax", "verified": True},
        },
        "linux": {
            "config": {"path": _home(".config/MiniMax"), "verified": False},
            "minimax_dir": {"path": _home(".minimax"), "verified": False},
        },
    },
    "opencode-cli": {
        "windows": {
            "xdg_data": {"path": "~/.local/share/opencode", "verified": True},
            "auth_json": {"path": "~/.local/share/opencode/auth.json", "verified": True},
        },
        "linux": {
            "xdg_data": {"path": _home(".local/share/opencode"), "verified": True},
            "xdg_config": {"path": _home(".config/opencode"), "verified": True},
            "auth_json": {"path": _home(".local/share/opencode/auth.json"), "verified": True},
        },
    },
    # Desktop clone suites (AutoClaw2 / Cline / OpenCode desktop): no Linux
    # builds discovered yet - deliberately NOT mapped rather than guessed.
}

SLUG_ALIASES = {
    "windsurf": "devin",      # pre-Devin-rebrand alias
    "opencode": "opencode-cli",
}


def get_store_paths(slug):
    """Returns {"platform": "windows"|"linux", "paths": {...}, "unverified": [labels]}.

    Paths are ~-expanded against the current user's home. Raises ValueError
    on an unknown slug (loud, never an empty map)."""
    slug = SLUG_ALIASES.get(slug, slug)
    if slug not in STORE_PATHS:
        raise ValueError(
            "unknown app slug '{0}' (known: {1})".format(
                slug, ", ".join(sorted(STORE_PATHS.keys()))
            )
        )
    platform = "windows" if IS_WINDOWS else "linux"
    per_platform = STORE_PATHS[slug][platform]
    paths = {}
    unverified = []
    for label, entry in sorted(per_platform.items()):
        expanded = os.path.expanduser(entry["path"])
        paths[label] = expanded
        if not entry.get("verified", False):
            unverified.append(label)
    return {"platform": platform, "slug": slug, "paths": paths, "unverified": unverified}
