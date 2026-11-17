#!/usr/bin/env bash
# ZCode Machine ID Reset Script for Linux (GHOST v0.1)
#
# SCOPE (2026-11-14): the default-profile identity reset (Linux has no
# multi-instance clone layer). The Electron userData path (~/.config/ZCode)
# and the Linux CLI store details are DERIVED from the Windows layout +
# Electron conventions - provenance-flagged unverified in ghost/platform.py
# and this script prints the caveat loudly. Covered on Linux: telemetry
# keys in storage.json + ItemTable upserts in state.vscdb (core verbs) +
# the system machine-id. NOT covered on Linux yet: the CLI telemetry state
# (v2\telemetry-state.json deviceMid), provider_config/credentials scrubs,
# RUM store, embedded-browser partition (all Windows-proven stores whose
# Linux layout is unverified).
#
# The shared CLI session store (~/.zcode/cli/db/db.sqlite) is deliberately
# NOT touched here: on Windows the reset script treats it the same way
# (clone resets do not scrub the shared db - reset-menu hardening plan).
#
# Usage (PR 8, 2026-11-17):
#   ./reset_zcode.sh                     # the Primary (default profile)
#   ./reset_zcode.sh --instance Second   # clone reset: roots the SAME v0.2
#       steps at the frozen clone layout (~/ZCode<Name>Home/.zcode +
#       ~/ZCode-<Name> userData, mirroring the Windows launcher), then
#       backs up + sweeps the desktop userData tree.
set -euo pipefail

RESET_INSTANCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance) RESET_INSTANCE="$2"; shift 2 ;;
        *) err "unknown argument: $1"; exit 1 ;;
    esac
done
declare -A CLONE_HOME_NAME=( [Second]=ZCodeSecondHome [Third]=ZCodeThirdHome [Fourth]=ZCodeFourthHome [Fifth]=ZCodeFifthHome [Sixth]=ZCodeSixthHome )
declare -A CLONE_USERDATA_NAME=( [Second]=ZCode-Second [Third]=ZCode-Third [Fourth]=ZCode-Fourth [Fifth]=ZCode-Fifth [Sixth]=ZCode-Sixth )
IS_CLONE=0
if [[ -n "$RESET_INSTANCE" ]]; then
    if [[ -z "${CLONE_HOME_NAME[$RESET_INSTANCE]:-}" ]]; then
        err "unknown --instance '$RESET_INSTANCE' (known: Second Third Fourth Fifth Sixth)"
        exit 1
    fi
    IS_CLONE=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "ZCode Identity Reset" "0.2"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every ZCode reset step needs it - aborting instead of silently skipping."
    exit 1
}

path_report=$(python3 "$GHOST_CLI_PATH" paths zcode)
CONFIG_ROOT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths']['config'])" "$path_report")
CLI_DIR_OVERRIDE=""
if [[ "$IS_CLONE" -eq 1 ]]; then
    # Clone reset (PR 8): the SAME v0.2 steps rooted at the frozen clone
    # layout. The desktop clone does NOT use ~/.config/ZCode - its Electron
    # store lives in ~/ZCode-<Name> (USER_DATA_DIR), so the electron-stores
    # step below re-targets the clone userData.
    CONFIG_ROOT="$HOME/${CLONE_USERDATA_NAME[$RESET_INSTANCE]}"
    CLI_DIR_OVERRIDE="$HOME/${CLONE_HOME_NAME[$RESET_INSTANCE]}/.zcode"
    ok "clone reset: $RESET_INSTANCE (userData $CONFIG_ROOT, cli $CLI_DIR_OVERRIDE)"
fi
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

ensure_not_running "zcode"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    if [[ "$IS_CLONE" -eq 1 ]]; then
        warn "clone userData dir absent ($CONFIG_ROOT) - creating (the launcher pre-creates it; a fresh clone here = the identity scrub runs on .zcode only)."
        mkdir -p "$CONFIG_ROOT"
    else
        err "ZCode installation not found at: $CONFIG_ROOT (store may live elsewhere on this distro - live verification pending)."
        exit 1
    fi
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
info "[1/2] Electron stores (storage.json + state.vscdb)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Resolve the CLI-side v2 stores (cli_dir is live-verified on Linux; the
# specific FILES are derived from the Windows layout - surfaced unverified
# by the paths verb above).
CLI_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths']['cli_dir'])" "$path_report")
if [[ "$IS_CLONE" -eq 1 ]]; then CLI_DIR="$CLI_DIR_OVERRIDE"; fi
TELEMETRY_STATE="$CLI_DIR/v2/telemetry-state.json"
CREDENTIALS_JSON="$CLI_DIR/v2/credentials.json"
SETTING_JSON="$CLI_DIR/v2/setting.json"

info ""
info "[2/5] CLI telemetry state deviceMid (core: json-set)..."
if [[ -f "$TELEMETRY_STATE" ]]; then
    if core_json_set_kv "$TELEMETRY_STATE" "telemetry-state" "deviceMid" "\"$DEV_DEVICE_ID\""        && verify_json_keys "$TELEMETRY_STATE" "deviceMid=$DEV_DEVICE_ID"; then
        ok "telemetry-state.json deviceMid updated + verified."
        audit_line "$AUDIT_FILE" "$TELEMETRY_STATE" "-" "$DEV_DEVICE_ID" 1 "core json-set"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "telemetry-state deviceMid update/verify FAILED."
        audit_line "$AUDIT_FILE" "$TELEMETRY_STATE" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "telemetry-state.json not present - skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$TELEMETRY_STATE" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[3/5] Credentials OAuth clear (core: json-remove oauth: prefix + zcodejwttoken)..."
if [[ -f "$CREDENTIALS_JSON" ]]; then
    cred_backup=$(core_backup "$CREDENTIALS_JSON" "$BACKUP_ROOT" "credentials")
    if python3 "$GHOST_CLI_PATH" json-remove "$CREDENTIALS_JSON" "$BACKUP_ROOT" "credentials-oauth"         "$(b64_remove_payload '["zcodejwttoken"]' '["oauth:"]')"; then
        ok "credentials.json OAuth entries removed + core-verified."
        audit_line "$AUDIT_FILE" "$CREDENTIALS_JSON" "backup=$(basename "${cred_backup:-none}")" "oauth-cleared" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "credentials OAuth clear FAILED."
        audit_line "$AUDIT_FILE" "$CREDENTIALS_JSON" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "credentials.json not present - skipped (fresh-install state)."
    audit_line "$AUDIT_FILE" "$CREDENTIALS_JSON" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[4/5] setting.json deviceSid (core: json-set dotted)..."
if [[ -f "$SETTING_JSON" ]]; then
    if core_json_set_kv "$SETTING_JSON" "setting-json"         "webRemoteControlExternalRelayDevice.deviceSid" "\"$DEV_DEVICE_ID\""        && verify_json_keys "$SETTING_JSON" "webRemoteControlExternalRelayDevice.deviceSid=$DEV_DEVICE_ID"; then
        ok "setting.json deviceSid updated + verified."
        audit_line "$AUDIT_FILE" "$SETTING_JSON" "-" "$DEV_DEVICE_ID" 1 "core json-set"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "setting.json deviceSid update/verify FAILED."
        audit_line "$AUDIT_FILE" "$SETTING_JSON" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "setting.json not present - skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$SETTING_JSON" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[5/5] System machine-id..."
reset_system_machine_id
if [[ "$SYSTEM_MACHINE_ID_SKIPPED" == "true" ]]; then
    audit_line "$AUDIT_FILE" "/etc/machine-id" "-" "skipped-not-root" 1
    PASS_COUNT=$((PASS_COUNT + 1))
else
    audit_line "$AUDIT_FILE" "/etc/machine-id" "-" "reset" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# Clone-only: back up + sweep the desktop userData tree (config/session) -
# the Windows clone-reset contract (a fresh relaunch rebuilds it).
if [[ "$IS_CLONE" -eq 1 ]]; then
    info ""
    info "[6/6] Clone userData cleanup (backup-first)..."
    USERDATA_ROOT="$HOME/${CLONE_USERDATA_NAME[$RESET_INSTANCE]}"
    for SUB in config session; do
        SUB_DIR="$USERDATA_ROOT/$SUB"
        if [[ -d "$SUB_DIR" ]]; then
            if python3 "$GHOST_CLI_PATH" sweep-tree "$SUB_DIR" "$BACKUP_ROOT" "userdata-$SUB"; then
                ok "userData/$SUB cleared (backed up)."
                audit_line "$AUDIT_FILE" "$SUB_DIR" "-" "swept" 1
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                err "userData/$SUB sweep FAILED."
                audit_line "$AUDIT_FILE" "$SUB_DIR" "-" "failed" 0
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            warn "userData/$SUB absent - skipped."
            audit_line "$AUDIT_FILE" "$SUB_DIR" "missing" "skipped" 1
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
    done
fi

RESTORE_SCRIPT=$(emit_restore_script "$BACKUP_ROOT")

ok ""
ok "=== Reset Complete ==="
info ""
info "Summary: Pass $PASS_COUNT / Fail $FAIL_COUNT"
info "Backups: $BACKUP_ROOT"
info "Audit:   $AUDIT_FILE"
info "Restore: $RESTORE_SCRIPT"
info "Note   : the shared CLI session store (~/.zcode/cli/db/db.sqlite) is"
info "         deliberately not scrubbed here - matches the Windows reset."

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    err "ZCode reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "ZCode reset completed successfully."
