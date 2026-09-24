"""JSON identity patching — port of Set-JsonIdentity in identity_utils.ps1.

Read -> merge keys (create when missing) -> write UTF-8 (no BOM) -> re-read
and verify every key. Never silent-success: the returned report carries the
verification outcome per invocation.

This module is the Python-native twin for future callers; the PowerShell
Set-JsonIdentity remains the live implementation today.
"""

import json
import os


def json_identity_update(path, updates):
    """Patch `updates` (dict of key -> scalar) into the JSON object at
    `path` and verify by re-reading.

    Returns a report dict:
      {"ok": bool, "before": {key: old|None}, "after": {key: actual|None},
       "error": None|"not-found"|"parse"|"re-read"|"verify"}
    """
    report = {"ok": False, "before": {}, "after": {}, "error": None}

    if not os.path.exists(path):
        report["error"] = "not-found"
        return report

    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            content = json.load(f)
    except (ValueError, OSError):
        report["error"] = "parse"
        return report

    if not isinstance(content, dict):
        report["error"] = "parse"
        return report

    before = {}
    for key, value in updates.items():
        before[key] = content.get(key)
        content[key] = value

    try:
        with open(path, "w", encoding="utf-8", newline="") as f:
            json.dump(content, f, indent=2, ensure_ascii=False)
            f.write("\n")
    except OSError:
        report["error"] = "write"
        return report

    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            verified = json.load(f)
    except (ValueError, OSError):
        report["before"] = before
        report["error"] = "re-read"
        return report

    all_matched = True
    after = {}
    for key, expected in updates.items():
        actual = verified.get(key) if isinstance(verified, dict) else None
        after[key] = actual
        if actual != expected:
            all_matched = False

    report["before"] = before
    report["after"] = after
    report["ok"] = all_matched
    if not all_matched:
        report["error"] = "verify"
    return report
