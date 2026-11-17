#!/usr/bin/env bash
# QoderWork Machine ID Reset Script for Linux (GHOST v0.2)
#
# DERIVED-PATH SCOPE (2026-11-14): the Linux store layout is derived from
# the proven Windows reset_qoderwork.ps1 + Electron conventions
# (~/.config/QoderWork) - rows are provenance-flagged unverified in
# ghost/platform.py and this script prints the caveat loudly. Covered on
# Linux: telemetry keys in storage.json + ItemTable upserts in state.vscdb
# (core verbs) + the machineid file + the agents.db oauth/app_settings
# scrub (core purge-tables: the EXACT Windows v0.2 table whitelist + keyed
# app_settings deletions; chats NEVER deleted) + the system machine-id
# (deepened 2026-11-17). NOT covered on Linux yet: auth.dat, MachineGuid
# (system-level, Windows registry-owned), the status/preferences JSONs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "QoderWork Identity Reset" "0.2"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every QoderWork reset step needs it - aborting instead of silently skipping."
    exit 1
}

path_report=$(python3 "$GHOST_CLI_PATH" paths qoderwork)
CONFIG_ROOT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths']['config'])" "$path_report")
QODERWORK_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('qoderwork_dir',''))" "$path_report")
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

ensure_not_running "QoderWork"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "QoderWork installation not found at: $CONFIG_ROOT (store may live elsewhere on this distro - live verification pending)."
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
info "[2/3] machineid file (~/.qoderwork)..."
if [[ -n "$QODERWORK_DIR" ]]; then
    MACHINE_ID_PATH="$QODERWORK_DIR/machineid"
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
    warn "~/.qoderwork not mapped on this platform - skipped."
    # shellcheck disable=SC2088
    audit_line "$AUDIT_FILE" "~/.qoderwork/machineid" "unmapped" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[3/4] agents.db oauth/app_settings scrub (core: purge-tables; chats preserved)..."
# The EXACT Windows v0.2 whitelist (reset_qoderwork.ps1 [19/26]): oauth
# token tables + identity-bearing rows purged; chats/sub_chats/messages/
# projects are NEVER in the list (chat preservation policy). app_settings
# is the keyed table: only identity-bearing keys deleted, "proxy" preserved.
AGENTS_DB="$CONFIG_ROOT/data/agents.db"
if [[ -f "$AGENTS_DB" ]]; then
    agents_backup=$(core_backup "$AGENTS_DB" "$BACKUP_ROOT" "agents_db")
    PURGE_PAYLOAD=$(python3 -c 'import base64, json; print(base64.b64encode(json.dumps({
        "tables": ["mcp_oauth_tokens", "mcp_oauth_tokens_by_user", "google_oauth_tokens",
                   "ms365_auth_states", "byok_custom_models", "rc_session_mappings",
                   "channel_pairings", "channel_pairings_v2", "knowledge_bases",
                   "voice_input_hotwords", "voice_input_history", "scheduled_tasks",
                   "task_run_logs", "nudge_logs", "skill_evolution_suggestions"],
        "key_table": "app_settings",
        "keys": ["asyncMigrationStatus", "asyncMigrationProgress", "windowBounds",
                 "channel:xiaoq", "channel:msteams", "channel:slack", "channel:line",
                 "channel:figma", "channel:google-calendar", "channel:google-maps",
                 "msConnectorEnabled", "ms365AuthFileMigrationV1"]
    }).encode()).decode())')
    if python3 "$GHOST_CLI_PATH" purge-tables "$AGENTS_DB" "$PURGE_PAYLOAD"; then
        ok "agents.db scrubbed + core-verified (read-only reopen)."
        audit_line "$AUDIT_FILE" "$AGENTS_DB" "backup=$(basename "${agents_backup:-none}")" "oauth+app_settings purged" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "agents.db purge FAILED."
        audit_line "$AUDIT_FILE" "$AGENTS_DB" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "agents.db not present - skipped (first-launch state): $AGENTS_DB"
    audit_line "$AUDIT_FILE" "$AGENTS_DB" "missing" "skipped" 1
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
    err "QoderWork reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "QoderWork reset completed successfully."
