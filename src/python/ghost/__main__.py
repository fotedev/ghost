"""CLI entry — `python -m ghost <command>` or via the ghost_cli.py
bootstrap. Subcommands map 1:1 onto the PowerShell bridges:

  sqlite-update <db> <updates_b64> [table]   Set-SqliteKeys bridge
  delete-secrets <db>                        Clear-SecretsFromSqlite bridge
  clear-cli-telemetry <db>                   reset_zcode [26/27] bridge
  chat-check <mode> <db> [tasks_index]       refresh_zcode_second_chats bridge
  json-patch <path> <updates_b64>            Set-JsonIdentity twin (future)
  identity                                   New-IdentitySet one-shot

Print contracts are consumed by PowerShell (ConvertFrom-Json / line
matching) -- see ghost/sqlite_keys.py docstrings before changing output.
Updates travel base64-encoded to sidestep PowerShell 5.1 native-argument
quoting entirely (same technique the old temp-.py bridge used).
"""

import argparse
import base64
import json
import sys

from ghost import audit, backup, filesweep, identity, json_patch, restore, sqlite_keys, winstore


def _decode_updates(b64):
    return json.loads(base64.b64decode(b64).decode("utf-8"))


def _cmd_sqlite_update(args):
    updates = _decode_updates(args.updates_b64)
    result = sqlite_keys.sqlite_update(args.db, updates, args.table)
    print(json.dumps(result))
    return 0


def _cmd_delete_secrets(args):
    result = sqlite_keys.delete_secrets(args.db)
    print(json.dumps(result))
    return 0


def _cmd_clear_cli_telemetry(args):
    result = sqlite_keys.clear_cli_telemetry(args.db)
    print(json.dumps(result))
    return 0


def _cmd_chat_check(args):
    lines = sqlite_keys.chat_check(args.mode, args.db, args.tasks_index)
    for line in lines:
        print(line)
    return 0


def _cmd_json_patch(args):
    updates = _decode_updates(args.updates_b64)
    report = json_patch.json_identity_update(args.path, updates)
    print(json.dumps(report))
    return 0 if report["ok"] else 1


def _cmd_identity(_args):
    print(json.dumps(identity.new_identity_set()))
    return 0


def _cmd_restore_script(args):
    with open(args.manifest, "r", encoding="utf-8-sig") as f:
        actions = json.load(f)
    path = restore.new_restore_script(args.backup_root, args.app, actions)
    print(path)
    return 0


def _cmd_audit_log(args):
    entries = []
    if args.entries:
        with open(args.entries, "r", encoding="utf-8-sig") as f:
            entries = json.load(f)
    print(audit.write_audit_log(entries, args.out))
    return 0


def _cmd_backup(args):
    report = backup.backup_to_timestamped_dir(
        args.source, args.backup_root, args.label)
    print(json.dumps(report))
    return 0 if (report["ok"] or report["skipped"]) else 1


def _cmd_machineid_file(args):
    payload = _decode_updates(args.payload_b64)
    report = winstore.write_machineid_file(
        args.path, payload["value"], args.backup_root, args.label)
    print(json.dumps(report))
    return 0 if report["ok"] else 1


def _cmd_salt_rotate(args):
    report = winstore.rotate_device_id_salt(
        args.path, args.backup_root, args.label)
    print(json.dumps(report))
    return 0 if report["ok"] else 1


def _cmd_json_remove(args):
    payload = _decode_updates(args.payload_b64)
    report = winstore.remove_json_keys(
        args.path, payload["keys"], args.backup_root, args.label)
    print(json.dumps(report))
    return 0 if report["ok"] else 1


def _cmd_store_delete(args):
    report = filesweep.remove_identity_store(
        args.path, args.action, args.backup_root, args.label,
        root_path=args.root_path)
    print(json.dumps(report))
    return 0 if report["ok"] else 1


def _cmd_sweep_file(args):
    report = filesweep.remove_verified(args.path)
    print(json.dumps(report))
    return 0 if report["ok"] else 1


def _cmd_sweep_tree(args):
    report = filesweep.sweep_tree(args.path, args.backup_root, args.label)
    print(json.dumps(report))
    return 0 if report["ok"] else 1


def build_parser():
    parser = argparse.ArgumentParser(
        prog="ghost", description="GHOST Python core CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser(
        "sqlite-update",
        help="UPSERT key/value rows + verify-after (Set-SqliteKeys bridge)")
    p.add_argument("db", help="path to the SQLite database")
    p.add_argument("updates_b64",
                   help="base64 of compact JSON {key: value}")
    p.add_argument("table", nargs="?", default="ItemTable",
                   help="target table (default ItemTable)")
    p.set_defaults(func=_cmd_sqlite_update)

    p = sub.add_parser(
        "delete-secrets",
        help="DELETE auth-secret keys + survivor verification")
    p.add_argument("db")
    p.set_defaults(func=_cmd_delete_secrets)

    p = sub.add_parser(
        "clear-cli-telemetry",
        help="DELETE telemetry-like keys from ZCode CLI db.sqlite")
    p.add_argument("db")
    p.set_defaults(func=_cmd_clear_cli_telemetry)

    p = sub.add_parser(
        "chat-check",
        help="cross-instance chat visibility / hot-activity probe")
    p.add_argument("mode", choices=["missing", "hot"])
    p.add_argument("db", help="shared session store db.sqlite")
    p.add_argument("tasks_index", nargs="?",
                   help="tasks-index.sqlite (mode=missing)")
    p.set_defaults(func=_cmd_chat_check)

    p = sub.add_parser(
        "json-patch",
        help="patch identity keys into a JSON file + verify")
    p.add_argument("path")
    p.add_argument("updates_b64")
    p.set_defaults(func=_cmd_json_patch)

    p = sub.add_parser(
        "identity", help="print a fresh 4-field identity set as JSON")
    p.set_defaults(func=_cmd_identity)

    p = sub.add_parser(
        "restore-script",
        help="generate a self-contained PowerShell restore script from a "
             "JSON actions manifest")
    p.add_argument("backup_root")
    p.add_argument("app")
    p.add_argument("manifest", help="JSON file with the actions array")
    p.set_defaults(func=_cmd_restore_script)

    p = sub.add_parser(
        "audit-log", help="write a JSON actions manifest as an audit log")
    p.add_argument("out", help="output audit JSON path")
    p.add_argument("entries", nargs="?",
                   help="JSON file with the entries array (default [])")
    p.set_defaults(func=_cmd_audit_log)

    p = sub.add_parser(
        "backup",
        help="copy a file/tree into a backup dir with lock retries + "
             "verify-after (Backup-FileToTimestampDir twin)")
    p.add_argument("source")
    p.add_argument("backup_root")
    p.add_argument("label")
    p.set_defaults(func=_cmd_backup)

    p = sub.add_parser(
        "machineid-file",
        help="backup + rewrite a machine-id text file + re-read verify "
             "(Set-VerifiedMachineIdFile twin)")
    p.add_argument("path")
    p.add_argument("backup_root")
    p.add_argument("label")
    p.add_argument("payload_b64", help="base64 of {\"value\": \"<id>\"}")
    p.set_defaults(func=_cmd_machineid_file)

    p = sub.add_parser(
        "salt-rotate",
        help="rotate electron.media.device_id_salt in a Preferences JSON + "
             "verify (Set-DeviceIdSalt twin)")
    p.add_argument("path")
    p.add_argument("backup_root")
    p.add_argument("label")
    p.set_defaults(func=_cmd_salt_rotate)

    p = sub.add_parser(
        "json-remove",
        help="remove dotted JSON key paths + re-read verify "
             "(Remove-OsCryptEncryptedKey twin)")
    p.add_argument("path")
    p.add_argument("backup_root")
    p.add_argument("label")
    p.add_argument("payload_b64", help="base64 of {\"keys\": [\"a.b\", ...]}")
    p.set_defaults(func=_cmd_json_remove)

    p = sub.add_parser(
        "store-delete",
        help="backup then rename-or-delete a binary identity store with "
             "retries (Clear-BinaryIdentityStore twin, one path)")
    p.add_argument("path")
    p.add_argument("backup_root")
    p.add_argument("label")
    p.add_argument("--action", choices=["rename", "delete"], default="delete")
    p.add_argument("--root-path", default=None,
                   help="paths under this root get relative backup labels")
    p.set_defaults(func=_cmd_store_delete)

    p = sub.add_parser(
        "sweep-file",
        help="delete one file (no backup) + re-read verify "
             "(Remove-VerifiedFileNoBackup twin)")
    p.add_argument("path")
    p.set_defaults(func=_cmd_sweep_file)

    p = sub.add_parser(
        "sweep-tree",
        help="backup a tree then delete every file inside it individually "
             "(Clear-TreeFilesIndividually twin)")
    p.add_argument("path")
    p.add_argument("backup_root")
    p.add_argument("label")
    p.set_defaults(func=_cmd_sweep_tree)

    return parser


def main(argv=None):
    # Force UTF-8 stdout so non-ASCII payloads (chat titles in chat-check
    # lines) survive pipes regardless of the Windows console code page; the
    # PowerShell callers set [Console]::OutputEncoding to match.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
