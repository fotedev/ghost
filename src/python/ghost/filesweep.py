"""File sweep operations — ports of the cursor file-identity helpers.

Ports (with their PS provenance):
- remove_verified          <- Remove-VerifiedFileNoBackup (reset_cursor.ps1)
- remove_identity_store    <- Clear-BinaryIdentityStore (identity_utils.ps1),
                              one path per call (the PS iterates a list)
- sweep_tree               <- Clear-TreeFilesIndividually (reset_cursor.ps1)

Never silent-success: every function returns a report whose ok flag is
decided by a re-read of the filesystem, never by "the call did not throw".
Missing sources report skipped=True with ok=True (the caller's [SKIP] path),
mirroring the PS audit convention (before="missing", after="skipped").

This module is the Python-native twin for the Phase 3 thin-manifest pilot
(docs/PYTHON_HYBRID_ROADMAP.md); the PS originals remain live until the
reset_cursor manifest switches over.
"""

import contextlib
import os
import shutil
import time

from ghost.backup import backup_to_timestamped_dir

_DELETE_ATTEMPTS = 6      # matches Clear-BinaryIdentityStore's retry curve
_SWEEP_ATTEMPTS = 4       # matches Clear-TreeFilesIndividually
_BACKOFF_MS = 500


def _sleep_backoff(attempt):
    time.sleep(_BACKOFF_MS * (attempt + 1) / 1000.0)


def _delete_path(path):
    """One delete attempt for a file or tree; raises OSError on failure."""
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.remove(path)


def _backup_label_for(path, root_path):
    """Get-PathBackupLabel twin: drive-prefixed relative path, or paths/<name>."""
    root = os.path.splitdrive(path)[0] + os.sep if os.path.splitdrive(path)[0] else ""
    if root_path:
        norm_root = root_path.rstrip("\\/") + os.sep
        if path.lower().startswith(norm_root.lower()):
            return path[len(norm_root):]
    if not root:
        return os.path.join("paths", os.path.basename(path))
    drive = root.rstrip("\\/").replace(":", "")
    relative = path[len(root):].lstrip("\\/")
    if not relative:
        return os.path.join("paths", drive)
    return os.path.join(drive, relative)


def remove_verified(path):
    """Delete a file (no backup) and verify by re-reading.

    One attempt, silent-failure semantics — the PS original relies on
    Remove-Item -ErrorAction SilentlyContinue then re-checks; so do we.
    """
    report = {"ok": False, "skipped": False, "before": "missing",
              "after": "skipped", "path": path, "error": None}
    if not os.path.exists(path) and not os.path.islink(path):
        report["ok"] = True
        report["skipped"] = True
        return report
    report["before"] = "present"
    with contextlib.suppress(OSError):
        _delete_path(path)
    if not os.path.exists(path) and not os.path.islink(path):
        report["ok"] = True
        report["after"] = "deleted"
        return report
    report["after"] = "delete-failed"
    report["error"] = "path still present after delete"
    return report


def remove_identity_store(path, action, backup_root, backup_label=None,
                          root_path=None, attempts=_DELETE_ATTEMPTS):
    """Clear-BinaryIdentityStore twin for one path: backup, then rename to
    '<path>.backup' (clobbering a stale one first) or delete, with the same
    6-attempt backoff. A failed/locked backup does NOT stop the operation —
    the PS contract note verbatim (the caller may still delete a file whose
    copy could not be read).

    action: "rename" | "delete".
    """
    report = {"ok": False, "skipped": False, "action": action, "path": path,
              "before": "missing", "after": "skipped", "backed_up_to": None,
              "backup_error": None, "renamed_to": None, "error": None,
              "detail": ""}
    if not os.path.exists(path) and not os.path.islink(path):
        report["ok"] = True
        report["skipped"] = True
        return report
    report["before"] = "present"

    label = backup_label or _backup_label_for(path, root_path)
    backup_report = backup_to_timestamped_dir(path, backup_root, label)
    if backup_report["ok"]:
        report["backed_up_to"] = backup_report["destination"]
    elif not backup_report["skipped"]:
        report["backup_error"] = backup_report["error"]

    if action == "rename":
        renamed = path + ".backup"
        with contextlib.suppress(OSError):
            _delete_path(renamed)
        last_error = ""
        for attempt in range(attempts):
            try:
                os.rename(path, renamed)
                if os.path.exists(path) or not os.path.exists(renamed):
                    raise OSError("rename did not take effect")
                report["ok"] = True
                report["after"] = "renamed to " + renamed
                report["renamed_to"] = renamed
                return report
            except OSError as exc:
                last_error = str(exc)
                if attempt + 1 < attempts:
                    _sleep_backoff(attempt)
        report["after"] = "rename-failed: " + last_error
        report["error"] = last_error
        return report

    last_error = ""
    for attempt in range(attempts):
        try:
            _delete_path(path)
            if not os.path.exists(path) and not os.path.islink(path):
                report["ok"] = True
                report["after"] = "deleted"
                return report
            last_error = "path still present after delete"
        except OSError as exc:
            last_error = str(exc)
        if attempt + 1 < attempts:
            _sleep_backoff(attempt)
    report["after"] = "delete-failed: " + last_error
    report["error"] = last_error
    return report


def sweep_tree(path, backup_root, backup_label, attempts=_SWEEP_ATTEMPTS):
    """Clear-TreeFilesIndividually twin: back up the whole tree (best-effort),
    then delete every file inside it one by one with a per-file retry curve.
    Directories are left in place (the PS original removes files only).
    """
    report = {"ok": False, "skipped": False, "path": path, "before": "missing",
              "after": "skipped", "deleted": 0, "failed": 0, "remaining": 0,
              "failed_paths": [], "backed_up_to": None, "error": None}
    if not os.path.isdir(path):
        report["ok"] = True
        report["skipped"] = True
        return report
    report["before"] = "present"

    backup_report = backup_to_timestamped_dir(path, backup_root, backup_label)
    if backup_report["ok"]:
        report["backed_up_to"] = backup_report["destination"]

    files = []
    for root, _dirs, names in os.walk(path):
        for name in names:
            files.append(os.path.join(root, name))

    for file_path in files:
        last_error = ""
        for attempt in range(attempts):
            try:
                os.remove(file_path)
                last_error = ""
                break
            except OSError as exc:
                last_error = str(exc)
                if attempt + 1 < attempts:
                    _sleep_backoff(attempt)
        if last_error:
            report["failed"] += 1
            report["failed_paths"].append(file_path)
        else:
            report["deleted"] += 1

    remaining = 0
    for root, _dirs, names in os.walk(path):
        remaining += len(names)
    report["remaining"] = remaining
    if report["failed"] == 0 and remaining == 0:
        report["ok"] = True
        report["after"] = "swept"
    else:
        report["after"] = "sweep-incomplete"
        report["error"] = "{} file(s) failed, {} remained".format(
            report["failed"], remaining)
    return report
