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
  documented platform conventions (Electron apps keep their userData under
  ~/.config/<App> on Linux and ~/Library/Application Support/<App> on
  macOS; XDG_DATA_HOME for CLI data). Every unverified row is listed in
  the ``paths`` verb output so a caller can print the caveat loudly -
  live Linux/macOS verification is the follow-up.

A ``"macos"`` column is opt-in per slug (2026-11-17, issue #36): only apps
with a shipped macOS resetter map it, and a darwin host asking for an
unmapped slug is a LOUD error - never a silent linux fallback.

The Windows column exists so the same verb can serve cross-platform callers
and future PS adoption; the PS scripts do NOT consume it yet (their inline
paths stay the proven source until a migration says otherwise).
"""

import os
import sys


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
            "machineid_file": {"path": _home(".config/Trae/machineId"), "verified": False},
            "local_env": {
                "path": _home(".config/Trae/ModularData/ckg_server/local_env.json"),
                "verified": False,
            },
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
            "installation_id": {"path": _home(".qoder/installation_id"), "verified": False},
            "auth_machine_id": {"path": _home(".qoder/.auth/machine_id"), "verified": False},
        },
        "macos": {
            # DERIVED (2026-11-17, issue #36): Electron userData lives under
            # ~/Library/Application Support/<App> on macOS; the dot-dir is
            # platform-agnostic per the Linux wave. All rows stay unverified
            # until a live Mac verifies them (reset_qoder.sh under src/macos).
            "config": {"path": _home("Library/Application Support/Qoder"), "verified": False},
            "qoder_dir": {"path": _home(".qoder"), "verified": False},
            "installation_id": {"path": _home(".qoder/installation_id"), "verified": False},
            "auth_machine_id": {"path": _home(".qoder/.auth/machine_id"), "verified": False},
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
            "agents_db": {"path": _home(".config/QoderWork/data/agents.db"), "verified": False},
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
            "telemetry_state": {"path": _home(".zcode/v2/telemetry-state.json"), "verified": False},
            "credentials": {"path": _home(".zcode/v2/credentials.json"), "verified": False},
            "setting_json": {"path": _home(".zcode/v2/setting.json"), "verified": False},
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
            "mcode_public": {
                "path": _home(".config/MiniMax/auth/prod/en/mcode-public"),
                "verified": False,
            },
            "session_handoff_device_id": {
                "path": _home(".minimax/v2/session-handoff/device-id"),
                "verified": False,
            },
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
    """Returns {"platform": "windows"|"linux"|"macos", "paths": {...}, "unverified": [labels]}.

    Paths are ~-expanded against the current user's home. Raises ValueError
    on an unknown slug, or on a platform column the slug does not map
    (loud, never an empty map or a silent fallback to another platform)."""
    slug = SLUG_ALIASES.get(slug, slug)
    if slug not in STORE_PATHS:
        raise ValueError(
            "unknown app slug '{0}' (known: {1})".format(
                slug, ", ".join(sorted(STORE_PATHS.keys()))
            )
        )
    if sys.platform.startswith("win"):
        platform = "windows"
    elif sys.platform == "darwin":
        platform = "macos"
    else:
        platform = "linux"
    per_platform = STORE_PATHS[slug].get(platform)
    if per_platform is None:
        raise ValueError(
            "no {0} store map for app slug '{1}' (mapped: {2})".format(
                platform, slug, ", ".join(sorted(STORE_PATHS[slug].keys()))
            )
        )
    paths = {}
    unverified = []
    for label, entry in sorted(per_platform.items()):
        expanded = os.path.expanduser(entry["path"])
        paths[label] = expanded
        if not entry.get("verified", False):
            unverified.append(label)
    return {"platform": platform, "slug": slug, "paths": paths, "unverified": unverified}
