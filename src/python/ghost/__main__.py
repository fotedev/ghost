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

from ghost import audit, identity, json_patch, restore, sqlite_keys


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

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
