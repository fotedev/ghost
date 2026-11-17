"""json-merge-defs: the Primary -> clone DEFINITIONS-merge invariant as a
core verb (2026-11-17 Linux MCP sync).

This is the Python port of the merge invariant the PowerShell cores own on
Windows (tools/zcode_mcp_merge.ps1, and its CS-1/Cline adaptations):

  - Primary definitions WIN: an entry present on both sides takes the
    Primary's full definition.
  - Clone-local PRESERVE-KEYS survive: the clone's value for each preserved
    per-entry key (e.g. the per-clone `enabled` toggle) is copied back over
    the merged entry, so syncing never flips a clone-local switch.
  - Clone-only entries are KEPT (never removed).
  - The Primary document is NEVER mutated (read-only by contract).

Scope: only the --base-path subtree (e.g. `mcp.servers`) is touched; every
other part of the clone document (plugins, hooks, ...) passes through
untouched, matching the Windows area-scoped syncs. Reports carry KEY NAMES
only - values never leave the process on stdout (the audit discipline every
sync tool in this repo follows).

The verb is generic (any base path, any preserve keys) so the other suites'
Linux sync ports can reuse it instead of growing a third merge
implementation.
"""

import copy
import json
import os

from ghost.backup import backup_to_timestamped_dir

_MISSING = object()


def _load_doc(path):
    # utf-8-sig tolerant (a BOM must never break a merge); missing file is
    # the caller's decision (the .sh layer skips config-less clones loudly).
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def _write_doc(path, content):
    # BOM-less UTF-8, indent 2 + trailing newline - the winstore._write_json
    # convention (LF endings via newline="").
    with open(path, "w", encoding="utf-8", newline="") as f:
        json.dump(content, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _get_dotted(doc, dotted):
    node = doc
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return _MISSING
        node = node[part]
    return node


def _ensure_container(doc, dotted):
    # Walk/create every dict container along the dotted path; a non-dict on
    # the way is a hard error (never overwrite a scalar with a dict).
    node = doc
    for part in dotted.split("."):
        if part not in node:
            node[part] = {}
        elif not isinstance(node[part], dict):
            raise ValueError("base-path segment is not an object: %r in %r" % (part, dotted))
        node = node[part]
    return node


def _entry_get_dotted(entry, dotted):
    node = entry
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return _MISSING
        node = node[part]
    return node


def _entry_set_dotted(entry, dotted, value):
    parts = dotted.split(".")
    node = entry
    for part in parts[:-1]:
        if not isinstance(node.get(part), dict):
            node[part] = {}
        node = node[part]
    node[parts[-1]] = value


def merge_defs(primary_doc, clone_doc, base_path, preserve_keys):
    """Pure merge: returns (merged_clone_doc, plan) without touching either
    input. plan lists key NAMES only."""
    plan = {"added": [], "updated": [], "unchanged": [], "clone_only": [], "removed": []}
    merged = copy.deepcopy(clone_doc)

    primary_node = _get_dotted(primary_doc, base_path)
    if primary_node is _MISSING:
        primary_node = {}
    if not isinstance(primary_node, dict):
        raise ValueError("primary base-path is not an object: %r" % base_path)
    if not isinstance(merged, dict):
        raise ValueError("clone document root is not an object")

    clone_node = _ensure_container(merged, base_path)
    if not isinstance(clone_node, dict):
        raise ValueError("clone base-path is not an object: %r" % base_path)

    for key, primary_entry in primary_node.items():
        if key not in clone_node:
            clone_node[key] = copy.deepcopy(primary_entry)
            plan["added"].append(key)
            continue
        clone_entry = clone_node[key]
        merged_entry = copy.deepcopy(primary_entry)
        # Clone-local preserve-keys survive the Primary definition.
        if isinstance(merged_entry, dict):
            for dotted in preserve_keys:
                local = _entry_get_dotted(clone_entry, dotted)
                if local is not _MISSING:
                    _entry_set_dotted(merged_entry, dotted, copy.deepcopy(local))
        if merged_entry == clone_entry:
            plan["unchanged"].append(key)
        else:
            clone_node[key] = merged_entry
            plan["updated"].append(key)

    for key in clone_node:
        if key not in primary_node:
            plan["clone_only"].append(key)

    return merged, plan


def merge_defs_file(primary_path, clone_path, base_path, preserve_keys,
                    backup_root=None, label="mcp-sync", dry_run=False):
    """File-level verb: backup (unless dry-run), merge, write, verify-after.
    Returns a report dict (names only) - the _cmd_* wrapper prints it."""
    report = {
        "ok": False, "error": None, "dry_run": bool(dry_run),
        "base_path": base_path, "preserve_keys": list(preserve_keys),
        "added": [], "updated": [], "unchanged": [], "clone_only": [],
        "changed": False, "backed_up_to": None, "verified": False,
    }
    try:
        primary_doc = _load_doc(primary_path)
        clone_doc = _load_doc(clone_path)
        merged, plan = merge_defs(primary_doc, clone_doc, base_path, preserve_keys)
        for k, v in plan.items():
            report[k] = v
        report["changed"] = bool(plan["added"] or plan["updated"])
        if not report["changed"] or dry_run:
            report["ok"] = True
            report["verified"] = not report["changed"] or dry_run
            return report

        if backup_root and os.path.exists(clone_path):
            backup_report = backup_to_timestamped_dir(clone_path, backup_root, label)
            if backup_report["ok"]:
                report["backed_up_to"] = backup_report["destination"]
            elif not backup_report["skipped"]:
                report["error"] = "backup failed: %s" % backup_report.get("error")
                return report

        _write_doc(clone_path, merged)

        # Verify-after: re-read from disk and deep-compare the base-path
        # subtree against the intended merge (the repo's write contract).
        reread = _load_doc(clone_path)
        reread_node = _get_dotted(reread, base_path)
        intended_node = _get_dotted(merged, base_path)
        report["verified"] = (reread_node is not _MISSING and reread_node == intended_node)
        if not report["verified"]:
            report["error"] = "verify-after mismatch on %s" % base_path
            return report
        report["ok"] = True
        return report
    except Exception as exc:  # noqa: BLE001 - the .sh layer consumes the JSON
        report["error"] = str(exc)
        return report
