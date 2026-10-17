"""Backup-to-timestamped-dir — port of Backup-FileToTimestampDir.

Copies a file OR directory tree to <backup_root>/<label>, retrying through
transient Windows file locks (extension-host processes release their handles
a few seconds after the parent IDE exits; the PS port uses 6 attempts with
500/1000/.../3000 ms backoff, ~10.5 s total). Adds the invariant the PS
version lacks: verify-after — a successful copy is re-measured (byte size for
files, entry count + total size for trees) before the report says ok. A copy
that fails verification is removed so a partial backup can never masquerade
as good. Never silent-success: the report carries the outcome explicitly.

This module is the Python-native twin for the Phase 3 thin-manifest pilot
(docs/PYTHON_HYBRID_ROADMAP.md); Backup-FileToTimestampDir remains the live
implementation today.
"""

import os
import shutil
import time


def _tree_stats(path):
    """Total bytes + file entry count for a file or a directory tree."""
    if os.path.isfile(path):
        return os.path.getsize(path), 1
    total = 0
    count = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            entry = os.path.join(root, name)
            total += os.path.getsize(entry)
            count += 1
    return total, count


def _copy_once(source, destination):
    if os.path.isdir(source):
        shutil.copytree(source, destination, dirs_exist_ok=True)
    else:
        dest_parent = os.path.dirname(destination)
        if dest_parent:
            os.makedirs(dest_parent, exist_ok=True)
        shutil.copy2(source, destination)


def backup_to_timestamped_dir(source, backup_root, label, attempts=6, backoff_ms=500):
    """Copy `source` (file or tree) to backup_root/label with lock retries.

    The backup root and label mirror the PS contract: the CALLER owns the
    timestamp (<app>\\ID_Backups\\<ts>\\<label>); this function only ensures
    the destination parent exists and never clobbers semantics beyond -Force
    (an existing destination is overwritten, matching Copy-Item -Force).

    Returns a report dict:
      {"ok": bool, "skipped": bool, "destination": str|None,
       "error": None|"not-found"|"locked"|"verify"|"io", "detail": str}
    skipped=True means the source was absent — the caller's [SKIP] path.
    "locked" means every attempt hit a lock: the caller may proceed with the
    deletion it was backing up for (the file may be deletable even though the
    copy could not read it — the PS contract note verbatim).
    """
    report = {"ok": False, "skipped": False, "destination": None,
              "error": None, "detail": ""}

    if not os.path.exists(source):
        report["skipped"] = True
        report["detail"] = "source not present"
        return report

    destination = os.path.join(backup_root, label)
    dest_parent = os.path.dirname(destination)
    if dest_parent:
        os.makedirs(dest_parent, exist_ok=True)

    last_error = ""
    for attempt in range(attempts):
        try:
            _copy_once(source, destination)
            src_bytes, src_entries = _tree_stats(source)
            dst_bytes, dst_entries = _tree_stats(destination)
            if (src_bytes, src_entries) != (dst_bytes, dst_entries):
                shutil.rmtree(destination, ignore_errors=True) \
                    if os.path.isdir(destination) else \
                    (os.remove(destination) if os.path.exists(destination) else None)
                report["error"] = "verify"
                report["detail"] = (
                    "copied bytes/entries mismatch: src {!r} dst {!r}"
                    .format((src_bytes, src_entries), (dst_bytes, dst_entries)))
                return report
            report["ok"] = True
            report["destination"] = destination
            return report
        except OSError as exc:
            last_error = str(exc)
            if attempt + 1 < attempts:
                time.sleep(backoff_ms * (attempt + 1) / 1000.0)

    report["error"] = "locked"
    report["detail"] = "backup skipped after {} retries (file locked?): {} -- {}".format(
        attempts, source, last_error)
    return report
