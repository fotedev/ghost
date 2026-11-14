#!/usr/bin/env bash
# Trae IDE Machine ID Reset Script for Linux (GHOST v0.2)
#
# Promoted 2026-11-14 from the local-only archive copy
# (archive/reset_trae_linux-v0.1.sh, never committed) and modernized to the
# Windows-side standard: every store mutation routes through the shared
# Python core (src/python/ghost via ghost_cli.py), timestamped
# ID_Backups/<ts> dirs, JSONL audit, verify-after re-reads on every write,
# and a self-contained restore script emission.
#
# Provenance: the config paths (~/.config/Trae) carry the archived v0.1
# script's scope; the deeper Windows-side Trae stores (aha delete,
# ModularData\ckg_server\local_env.json, SharedStorage) are NOT mapped on
# Linux yet - see ghost/platform.py (unverified rows surfaced by
# `ghost_cli.py paths trae`). Live Linux verification pending.
#
# Steps:
#   1. storage.json telemetry keys (core: json-patch + verify)
#   2. state.vscdb ItemTable upserts (core: sqlite-update + verify)
#   3. system machine-id (root)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "Trae Identity Reset" "0.2"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every Trae reset step needs it - aborting instead of silently skipping."
    exit 1
}

TRAE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Trae"
GLOBAL_STORAGE="$TRAE_CONFIG/User/globalStorage"
STORAGE_JSON="$GLOBAL_STORAGE/storage.json"
SQLITE_DB="$GLOBAL_STORAGE/state.vscdb"

generate_ids() {
    DEV_DEVICE_ID=$(generate_uuid)
    MACHINE_ID=$(generate_hex 32)
    MAC_MACHINE_ID=$(generate_hex 64)
    SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
}

b64_json() {
    python3 -c "import base64, json, sys; print(base64.b64encode(json.dumps(json.loads(sys.argv[1]), separators=(',', ':')).encode()).decode())" "$1"
}

ensure_trae_closed() {
    ensure_not_running "trae"
}

# ── main ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && warn "Tip: run with sudo to also reset /etc/machine-id."

ensure_trae_closed

if [[ ! -d "$TRAE_CONFIG" ]]; then
    warn "Trae IDE directory not found at: $TRAE_CONFIG"
    warn "Creating directory structure..."
    mkdir -p "$TRAE_CONFIG" "$GLOBAL_STORAGE"
fi

BACKUP_ROOT="$TRAE_CONFIG/ID_Backups/$(timestamp)"
mkdir -p "$BACKUP_ROOT"
RESTORE_ENTRIES=()
audit_init "$BACKUP_ROOT"

PASS_COUNT=0
FAIL_COUNT=0

generate_ids
ok "Generated new identifiers:"
dim "  devDeviceId:   $DEV_DEVICE_ID"
dim "  machineId:     $MACHINE_ID"
dim "  macMachineId:  $MAC_MACHINE_ID"
dim "  sqmId:         $SQM_ID"

info ""
info "[1/3] Updating storage.json (core: json-patch)..."
if [[ ! -f "$STORAGE_JSON" ]]; then
    warn "storage.json not present - creating fresh."
    mkdir -p "$GLOBAL_STORAGE"
    printf '{}\n' > "$STORAGE_JSON"
fi
storage_backup=$(core_backup "$STORAGE_JSON" "$BACKUP_ROOT" "storage_json")
storage_updates="{\"telemetry.devDeviceId\":\"$DEV_DEVICE_ID\",\"telemetry.machineId\":\"$MACHINE_ID\",\"telemetry.macMachineId\":\"$MAC_MACHINE_ID\",\"telemetry.sqmId\":\"$SQM_ID\",\"storage.serviceMachineId\":\"$DEV_DEVICE_ID\"}"
if out=$(python3 "$GHOST_CLI_PATH" json-patch "$STORAGE_JSON" "$(printf '%s' "$storage_updates" | b64_json)"); then
    if verify_json_keys "$STORAGE_JSON" \
        "telemetry.devDeviceId=$DEV_DEVICE_ID" \
        "telemetry.machineId=$MACHINE_ID" \
        "telemetry.macMachineId=$MAC_MACHINE_ID" \
        "telemetry.sqmId=$SQM_ID" \
        "storage.serviceMachineId=$DEV_DEVICE_ID"; then
        ok "storage.json updated + verified."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "backup=$(basename "${storage_backup:-none}")" "$DEV_DEVICE_ID" 1 "core json-patch"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "storage.json VERIFY FAILED."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "verify-failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    err "json-patch core step failed: $out"
    audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "core-failed" 0
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/3] Updating SQLite database (core: sqlite-update)..."
if [[ -f "$SQLITE_DB" ]]; then
    sqlite_backup=$(core_backup "$SQLITE_DB" "$BACKUP_ROOT" "state_vscdb")
    sqlite_updates="{\"telemetry.devDeviceId\":\"$DEV_DEVICE_ID\",\"telemetry.machineId\":\"$MACHINE_ID\",\"telemetry.macMachineId\":\"$MAC_MACHINE_ID\",\"telemetry.sqmId\":\"$SQM_ID\",\"storage.serviceMachineId\":\"$DEV_DEVICE_ID\"}"
    if out=$(python3 "$GHOST_CLI_PATH" sqlite-update "$SQLITE_DB" "$(printf '%s' "$sqlite_updates" | b64_json)"); then
        if python3 - "$SQLITE_DB" "$DEV_DEVICE_ID" <<'PY' >/dev/null 2>&1; then
import sqlite3, sys
db_path, dev_id = sys.argv[1:3]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT key, value FROM ItemTable WHERE key LIKE 'telemetry.%' OR key = 'storage.serviceMachineId'")
rows = dict(cur.fetchall())
conn.close()
assert rows.get("telemetry.devDeviceId") == dev_id
assert rows.get("storage.serviceMachineId") == dev_id
PY
            ok "SQLite database updated + verified."
            audit_line "$AUDIT_FILE" "$SQLITE_DB" "backup=$(basename "${sqlite_backup:-none}")" "$DEV_DEVICE_ID" 1 "core sqlite-update"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            err "SQLite VERIFY FAILED."
            audit_line "$AUDIT_FILE" "$SQLITE_DB" "-" "verify-failed" 0
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        err "sqlite-update core step failed: $out"
        audit_line "$AUDIT_FILE" "$SQLITE_DB" "-" "core-failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "state.vscdb not found at $SQLITE_DB - skipped (first launch creates it)."
    audit_line "$AUDIT_FILE" "$SQLITE_DB" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[3/3] System machine-id..."
reset_system_machine_id
if [[ "$SYSTEM_MACHINE_ID_SKIPPED" == "true" ]]; then
    audit_line "$AUDIT_FILE" "/etc/machine-id" "-" "skipped-not-root" 1
    PASS_COUNT=$((PASS_COUNT + 1))
else
    audit_line "$AUDIT_FILE" "/etc/machine-id" "-" "reset" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

RESTORE_SCRIPT=$(emit_restore_script "$BACKUP_ROOT")

ok ""
ok "=== Reset Complete ==="
info ""
info "Summary: Pass $PASS_COUNT / Fail $FAIL_COUNT"
info "Backups: $BACKUP_ROOT"
info "Audit:   $AUDIT_FILE"
info "Restore: $RESTORE_SCRIPT"
info "Note   : Windows-side Trae stores (aha, ModularData ckg_server) are NOT"
info "         covered on Linux yet - live Linux verification is pending."

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    err "Trae reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "Trae reset completed successfully."
