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


def _write_raw(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def _read_raw(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return f.read()


def _maybe_backup(path, backup_root, label, report):
    backup_report = backup_to_timestamped_dir(path, backup_root, label)
    if backup_report["ok"]:
        report["backed_up_to"] = backup_report["destination"]
    elif not backup_report["skipped"]:
        report["backup_error"] = backup_report["error"]
    return bool(backup_report["ok"])


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


def set_json_path(path, dotted, value, backup_root, label, skip_if_empty=False):
    """Set a value at a dotted key path (e.g. 'devin.org_id'), creating the
    intermediate dicts. Clear-AppOrgBinding twin: with skip_if_empty=True a
    currently-absent-or-empty leaf is a SKIP without touching the file (the
    no-org-binding contract). Verify by re-read.
    """
    report = {"ok": False, "skipped": False, "before": None, "after": None,
              "backed_up_to": None, "backup_error": None, "error": None}
    if not os.path.exists(path):
        report["ok"] = True
        report["skipped"] = True
        return report

    try:
        content = _load_json(path)
    except (ValueError, OSError) as exc:
        report["error"] = "parse: " + str(exc)
        return report
    if not isinstance(content, dict):
        report["error"] = "parse: root is not an object"
        return report

    node = content
    missing = False
    for part in dotted.split(".")[:-1]:
        if not isinstance(node, dict) or part not in node:
            missing = True
            break
        node = node[part]
    leaf = dotted.split(".")[-1]
    report["before"] = node.get(leaf) if (not missing and isinstance(node, dict)) else None
    if skip_if_empty and (report["before"] is None or report["before"] == ""):
        report["ok"] = True
        report["skipped"] = True
        return report

    _maybe_backup(path, backup_root, label, report)

    node = content
    for part in dotted.split(".")[:-1]:
        if not isinstance(node.get(part), dict):
            node[part] = {}
        node = node[part]
    node[leaf] = value

    try:
        _write_json(path, content)
    except OSError as exc:
        report["error"] = "write: " + str(exc)
        return report

    try:
        verified = _load_json(path)
        walk = verified
        for part in dotted.split("."):
            if not isinstance(walk, dict) or part not in walk:
                report["error"] = "re-read"
                return report
            walk = walk[part]
        report["after"] = walk
    except (ValueError, OSError) as exc:
        report["error"] = "re-read: " + str(exc)
        return report

    if report["after"] == value:
        report["ok"] = True
    else:
        report["error"] = "verify"
    return report


def patch_argv_json(path, backup_root, label, new_id=None, username=None):
    """Update-ArgvJsonIdentity twin for Chromium argv.json (JSONC — comments
    allowed, never parsed as JSON): regex-replace only the
    "crash-reporter-id" VALUE, insert the key into the trailing object when
    absent, scrub the username out of the raw text, then verify by re-read.
    The id is generated internally (lower GUID) unless supplied.
    """
    report = {"ok": False, "skipped": False, "before": None, "after": None,
              "user_dir_scrubbed": False, "backed_up_to": None,
              "backup_error": None, "error": None}
    if not os.path.exists(path):
        report["ok"] = True
        report["skipped"] = True
        return report
    if new_id is None:
        new_id = str(secrets.token_hex(4))  # placeholder, replaced below

    raw = _read_raw(path)
    import re as _re
    before_match = _re.search(r'"crash-reporter-id"\s*:\s*"([^"]+)"', raw)
    if before_match:
        report["before"] = before_match.group(1)

    _maybe_backup(path, backup_root, label, report)

    pattern = r'"crash-reporter-id"\s*:\s*"[^"]+"'
    replacement = '"crash-reporter-id": "' + new_id + '"'
    if _re.search(pattern, raw):
        new_raw = _re.sub(pattern, replacement, raw)
    else:
        trimmed = raw.rstrip()
        if trimmed.endswith("}"):
            inner = trimmed[:-1].rstrip()
            if inner.endswith("{"):
                new_raw = inner + '\n  ' + replacement + '\n}'
            else:
                new_raw = inner.rstrip(",") + ',\n  ' + replacement + '\n}'
        else:
            report["error"] = "unparseable: no JSON object to extend"
            return report

    if username and username in new_raw:
        new_raw = new_raw.replace(username, "RESET")
        report["user_dir_scrubbed"] = True

    _write_raw(path, new_raw)

    verify_raw = _read_raw(path)
    verify_match = _re.search(r'"crash-reporter-id"\s*:\s*"([^"]+)"', verify_raw)
    report["after"] = verify_match.group(1) if verify_match else None
    if report["after"] == new_id:
        report["ok"] = True
    else:
        report["error"] = "verify"
    return report


def replace_text(path, find, replacement, backup_root, label):
    """Set-UsernameScrubbedFile twin: raw-text replace (never parsed — a
    single leaked reference must not survive a partial parse), then verify
    the `find` string is gone by re-reading. Absent file = skip-ok.
    """
    report = {"ok": False, "skipped": False, "before": "missing",
              "after": "skipped", "backed_up_to": None, "backup_error": None,
              "error": None}
    if not os.path.exists(path):
        report["ok"] = True
        report["skipped"] = True
        return report

    before_text = _read_raw(path)
    had_leak = find in before_text
    report["before"] = "leaked" if had_leak else "clean"

    if had_leak:
        _maybe_backup(path, backup_root, label, report)
        _write_raw(path, before_text.replace(find, replacement))

    re_read = _read_raw(path)
    if find in re_read:
        report["after"] = "still-leaked"
        report["error"] = "verify: find string still present"
        return report
    report["after"] = "clean"
    report["ok"] = True
    return report
