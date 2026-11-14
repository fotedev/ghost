#!/usr/bin/env bash
# MiniMax Agent / OpenCode Machine ID Reset Script for Linux (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-14): the Linux store layout is derived from
# the proven Windows reset_minimax_opencode.ps1 + Electron/XDG conventions
# - rows are provenance-flagged unverified in ghost/platform.py and this
# script prints the caveat loudly. Covered on Linux: telemetry keys in
# storage.json + ItemTable upserts in state.vscdb (core verbs) + the
# system machine-id. NOT covered on Linux yet: the v1.3 Windows stores
# (mcode-public auth.json/auth-state.json deletion - "{}" there blocks the
# login page, session-handoff device-id rotation, updater IDs,
# DIPS/SharedStorage sweeps).
#
# The OpenCode CLI XDG stores (~/.local/share/opencode/auth.json) are
# deliberately NOT touched by this script: they belong to
# opencode-cli (see ghost.platform) and carry the CLI login.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "MiniMax/OpenCode Identity Reset" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every MiniMax/OpenCode reset step needs it - aborting instead of silently skipping."
    exit 1
}

path_report=$(python3 "$GHOST_CLI_PATH" paths minimax)
CONFIG_ROOT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths']['config'])" "$path_report")
MINIMAX_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('minimax_dir',''))" "$path_report")
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

ensure_not_running "minimax"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "MiniMax installation not found at: $CONFIG_ROOT (store may live elsewhere on this distro - live verification pending)."
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
info "[1/3] Electron stores (storage.json + state.vscdb)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/3] machineid file (~/.minimax)..."
if [[ -n "$MINIMAX_DIR" ]]; then
    MACHINE_ID_PATH="$MINIMAX_DIR/machineid"
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
    warn "~/.minimax not mapped on this platform - skipped."
    audit_line "$AUDIT_FILE" "~/.minimax/machineid" "unmapped" "skipped" 1
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

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    err "MiniMax/OpenCode reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "MiniMax/OpenCode reset completed successfully."
