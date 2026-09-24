"""Audit log writer — shape-compatible port of Write-AuditLog in
identity_utils.ps1.

Entries are dicts {file, key, before, after, ok}; the log is a UTF-8 JSON
array written next to the caller's backups (callers place it at
<BackupRoot>/audit_<timestamp>.json). Consumers read it with either
ConvertFrom-Json or json.load -- both handle this output.
"""

import json
import os


def write_audit_log(audit_entries, path):
    """Write the audit entries (list of dicts) as a JSON array to `path`,
    creating parent directories as needed. Returns the path."""
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)

    with open(path, "w", encoding="utf-8", newline="") as f:
        json.dump(list(audit_entries), f, indent=2, ensure_ascii=False,
                  default=str)
        f.write("\n")
    return path


def audit_entry(file, key, before, after, ok):
    """Build one entry dict in the canonical key order (mirrors
    Add-AuditEntry's ordered hashtable)."""
    return {
        "file": file,
        "key": key,
        "before": before,
        "after": after,
        "ok": bool(ok),
    }
