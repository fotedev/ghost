"""Windows store JSON/text mutations — ports of the cursor identity helpers.

Ports (with their PS provenance):
- write_machineid_file  <- Set-VerifiedMachineIdFile (reset_cursor.ps1)
- rotate_device_id_salt <- Set-DeviceIdSalt (reset_cursor.ps1), key
  electron.media.device_id_salt, nested dicts created when missing
- remove_json_keys      <- Remove-OsCryptEncryptedKey (reset_cursor.ps1),
  generalized to dotted key paths

Every mutation: backup (best-effort — a locked backup is reported but does
NOT stop the mutation, the PS contract), mutate, then verify by RE-READING
the file. Never silent-success. JSON files are read utf-8-sig (BOM tolerated)
and written as BOM-less UTF-8 with indent=2, matching json_patch.

This module is the Python-native twin for the Phase 3 thin-manifest pilot
(docs/PYTHON_HYBRID_ROADMAP.md); the PS originals remain live until the
reset_cursor manifest switches over.
"""

import json
import os
import secrets

from ghost.backup import backup_to_timestamped_dir


def _load_json(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def _write_json(path, content):
    with open(path, "w", encoding="utf-8", newline="") as f:
        json.dump(content, f, indent=2, ensure_ascii=False)
        f.write("\n")


def write_machineid_file(path, value, backup_root, label):
    """Set-VerifiedMachineIdFile twin: backup (if present), write the value
    BOM-less UTF-8, then verify by re-reading and trimming.
    """
    report = {"ok": False, "skipped": False, "before": None, "after": None,
              "backed_up_to": None, "backup_error": None, "error": None}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8-sig") as f:
            report["before"] = f.read().strip()
        backup_report = backup_to_timestamped_dir(path, backup_root, label)
        if backup_report["ok"]:
            report["backed_up_to"] = backup_report["destination"]
        elif not backup_report["skipped"]:
            report["backup_error"] = backup_report["error"]

    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(value)

    with open(path, "r", encoding="utf-8-sig") as f:
        report["after"] = f.read().strip()
    if report["after"] == value:
        report["ok"] = True
    else:
        report["error"] = "verify"
    return report


def rotate_device_id_salt(path, backup_root, label, new_salt=None):
    """Set-DeviceIdSalt twin on electron.media.device_id_salt. Missing file
    -> skipped/ok. Missing electron/media dicts are created. The salt is
    generated internally (32 hex chars) unless the caller supplies one.
    """
    report = {"ok": False, "skipped": False, "before": None, "after": None,
              "backed_up_to": None, "backup_error": None, "error": None}
    if not os.path.exists(path):
        report["ok"] = True
        report["skipped"] = True
        return report

    backup_report = backup_to_timestamped_dir(path, backup_root, label)
    if backup_report["ok"]:
        report["backed_up_to"] = backup_report["destination"]
    elif not backup_report["skipped"]:
        report["backup_error"] = backup_report["error"]

    try:
        content = _load_json(path)
    except (ValueError, OSError) as exc:
        report["error"] = "parse: " + str(exc)
        return report
    if not isinstance(content, dict):
        report["error"] = "parse: root is not an object"
        return report

    if new_salt is None:
        new_salt = secrets.token_hex(16)

    electron = content.get("electron")
    media = electron.get("media") if isinstance(electron, dict) else None
    if isinstance(media, dict):
        report["before"] = media.get("device_id_salt")
    if not isinstance(electron, dict):
        electron = {}
        content["electron"] = electron
    if not isinstance(media, dict):
        media = {}
        electron["media"] = media
    media["device_id_salt"] = new_salt

    try:
        _write_json(path, content)
    except OSError as exc:
        report["error"] = "write: " + str(exc)
        return report

    try:
        verified = _load_json(path)
        report["after"] = verified["electron"]["media"]["device_id_salt"]
    except (ValueError, OSError, KeyError, TypeError) as exc:
        report["error"] = "re-read: " + str(exc)
        return report

    if report["after"] == new_salt:
        report["ok"] = True
    else:
        report["error"] = "verify"
    return report


def remove_json_keys(path, keys, backup_root, label):
    """Remove-OsCryptEncryptedKey twin, generalized to dotted key paths
    (e.g. 'os_crypt.encrypted_key'). Missing file OR missing walk -> skipped
    with ok=True (the PS contract: os_crypt absent is a SKIP, not a failure).
    Removing an already-absent leaf is also ok.
    """
    report = {"ok": False, "skipped": False, "before": {}, "removed": [],
              "backed_up_to": None, "backup_error": None, "error": None}
    if not os.path.exists(path):
        report["ok"] = True
        report["skipped"] = True
        return report

    backup_report = backup_to_timestamped_dir(path, backup_root, label)
    if backup_report["ok"]:
        report["backed_up_to"] = backup_report["destination"]
    elif not backup_report["skipped"]:
        report["backup_error"] = backup_report["error"]

    try:
        content = _load_json(path)
    except (ValueError, OSError) as exc:
        report["error"] = "parse: " + str(exc)
        return report
    if not isinstance(content, dict):
        report["error"] = "parse: root is not an object"
        return report

    for dotted in keys:
        parts = dotted.split(".")
        node = content
        missing = False
        for part in parts[:-1]:
            if not isinstance(node, dict) or part not in node:
                missing = True
                break
            node = node[part]
        if missing or not isinstance(node, dict) or parts[-1] not in node:
            report["before"][dotted] = "missing"
            continue
        report["before"][dotted] = "present"
        del node[parts[-1]]
        report["removed"].append(dotted)

    if report["removed"]:
        try:
            _write_json(path, content)
        except OSError as exc:
            report["error"] = "write: " + str(exc)
            return report

    # Verify-after: every requested key must now be absent on re-read.
    try:
        verified = _load_json(path)
    except (ValueError, OSError) as exc:
        report["error"] = "re-read: " + str(exc)
        return report
    still = []
    for dotted in keys:
        node = verified
        missing = False
        for part in dotted.split(".")[:-1]:
            if not isinstance(node, dict) or part not in node:
                missing = True
                break
            node = node[part]
        if not missing and isinstance(node, dict) and dotted.split(".")[-1] in node:
            still.append(dotted)
    if still:
        report["error"] = "verify: still present: " + ", ".join(still)
        return report
    report["ok"] = True
    return report
