#!/usr/bin/env bash
# Qoder Machine ID Reset Script for Linux (GHOST v0.2)
#
# DERIVED-PATH SCOPE (2026-11-14): the Linux store layout is derived from
# the proven Windows reset_qoder.ps1 + Electron conventions (~/.config/Qoder)
# - rows are provenance-flagged unverified in ghost/platform.py and this
# script prints the caveat loudly. Covered on Linux (deepened 2026-11-17):
# telemetry keys in storage.json + ItemTable upserts in state.vscdb (core
# verbs) + the machineid file + the ~/.qoder installation_id /
# .auth/machine_id rotations + the .credential-transaction lock sentinel
# delete + the system machine-id. NOT covered on Linux yet: loginBroadcast,
# secret.local.machine.variables, webview stores, CORS_Profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "Qoder Identity Reset" "0.2"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every Qoder reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth).
path_report=$(python3 "$GHOST_CLI_PATH" paths qoder)
CONFIG_ROOT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths']['config'])" "$path_report")
QODER_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('qoder_dir',''))" "$path_report")
UNVERIFIED=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['unverified']))" "$path_report")
if [[ -n "$UNVERIFIED" ]]; then
    warn "PROVENANCE: the following paths are DERIVED (Windows layout + Linux"
    warn "conventions), NOT yet live-verified: $UNVERIFIED"
    warn "A store that moved is skipped loudly below - nothing is guessed."
fi

generate_ids() {
    DEV_DEVICE_ID=$(generate_uuid)
    MACHINE_ID=$(generate_hex 32)
    MAC_MACHINE_ID=$(generate_hex 64)
    SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
}

# ── main ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && warn "Tip: run with sudo to also reset /etc/machine-id."

ensure_not_running "qoder"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "Qoder installation not found at: $CONFIG_ROOT (store may live elsewhere on this distro - live verification pending)."
    exit 1
fi

BACKUP_ROOT="$CONFIG_ROOT/ID_Backups/$(timestamp)"
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
info "[1/4] Electron stores (storage.json + state.vscdb)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/3] machineid file (~/.qoder)..."
if [[ -n "$QODER_DIR" ]]; then
    MACHINE_ID_PATH="$QODER_DIR/machineid"
    machineid_backup=$(core_backup "$MACHINE_ID_PATH" "$BACKUP_ROOT" "machineid")
    printf '%s\n' "$DEV_DEVICE_ID" > "$MACHINE_ID_PATH"
    if verify_file_value "$MACHINE_ID_PATH" "$DEV_DEVICE_ID"; then
        ok "machineid file updated + verified."
        audit_line "$AUDIT_FILE" "$MACHINE_ID_PATH" "backup=$(basename "${machineid_backup:-none}")" "$DEV_DEVICE_ID" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "machineid VERIFY FAILED."
        audit_line "$AUDIT_FILE" "$MACHINE_ID_PATH" "-" "verify-failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    # SC2088 intentional: the tilde is a DISPLAY label (the path is not
    # mapped on this platform, nothing touches the filesystem).
    # shellcheck disable=SC2088
    warn "~/.qoder not mapped on this platform - skipped."
    # shellcheck disable=SC2088
    audit_line "$AUDIT_FILE" "~/.qoder/machineid" "unmapped" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[3/4] installation_id + .auth/machine_id rotation (36B GUIDs)..."
if [[ -n "$QODER_DIR" ]]; then
    INSTALLATION_ID="$QODER_DIR/installation_id"
    AUTH_MACHINE_ID="$QODER_DIR/.auth/machine_id"
    if rotate_text_file "$INSTALLATION_ID" "installation_id" "$DEV_DEVICE_ID"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if rotate_text_file "$AUTH_MACHINE_ID" "auth-machine-id" "$MACHINE_ID"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    # The 0-byte credential-transaction lock sentinel: delete with backup
    # (core store-delete), loudly skipped when absent.
    if [[ -f "$QODER_DIR/.auth/.credential-transaction" ]]; then
        if python3 "$GHOST_CLI_PATH" store-delete "$QODER_DIR/.auth/.credential-transaction"             "$BACKUP_ROOT" "credential-transaction" --action delete; then
            ok "credential-transaction sentinel deleted."
            audit_line "$AUDIT_FILE" "$QODER_DIR/.auth/.credential-transaction" "-" "deleted" 1
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            err "credential-transaction delete FAILED."
            audit_line "$AUDIT_FILE" "$QODER_DIR/.auth/.credential-transaction" "-" "failed" 0
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        warn "credential-transaction sentinel absent - skipped."
        audit_line "$AUDIT_FILE" "$QODER_DIR/.auth/.credential-transaction" "missing" "skipped" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
else
    warn "~/.qoder not mapped on this platform - rotations skipped."
    audit_line "$AUDIT_FILE" "~/.qoder/installation_id" "unmapped" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[4/4] System machine-id..."
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

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    err "Qoder reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "Qoder reset completed successfully."
