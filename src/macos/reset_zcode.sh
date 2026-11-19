#!/usr/bin/env bash
# ZCode Machine ID Reset Script for macOS (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-19, issue #36 follow-up - the seventh and
# last macOS resetter): the macOS store layout is derived from the proven
# Windows reset_zcode.ps1 (v1.5, 27 steps) + the Linux reset_zcode.sh
# (v0.2) step map + Electron conventions
# (~/Library/Application Support/ZCode) - rows are provenance-flagged
# unverified in ghost/platform.py and this script prints the caveat
# loudly. The CLI dot-dir ~/.zcode is platform-agnostic in platform.py
# (the linux cli_dir row is live-verified there; the macOS files under it
# are the same DERIVED layout).
#
# PRESERVATION POLICY (matches the Windows + Linux ZCode resets): the
# SHARED CLI session store (~/.zcode/cli/db/db.sqlite - read by every
# instance, holds the cross-instance chat trail) is deliberately NOT
# scrubbed, and cli/config.json (provider definitions + MCP) is never
# touched by a reset. A clone-reset variant does not exist on macOS yet
# (the Linux --instance clone layout is a Linux-launcher concept; macOS
# clone support has no launch layer).
#
# Covered on macOS (the Linux v0.2 map verbatim - no invented steps):
# the Electron identity stores (storage.json telemetry keys +
# storage.serviceMachineId + state.vscdb ItemTable upserts via the shared
# reset_electron_stores) + the CLI telemetry-state deviceMid + the
# credentials.json OAuth clear (zcodejwttoken exact + every oauth:-
# prefixed key) + the setting.json webRemoteControlExternalRelayDevice
# deviceSid + the ~/Library cache/log/plist sweep.
#
# NOT covered on macOS (no honest analog, or deliberately out of scope):
# the shared CLI db (preservation policy above), the RUM store + the
# embedded-browser partition + the provider_config scrubs (Windows-proven
# stores whose macOS layout is unverified - same NOT-covered list as the
# Linux v0.2 map), Keychain (no macOS equivalent of the Windows DPAPI
# os_crypt story for ZCode is proven), IOPlatformUUID (immutable),
# hostname (scutil --set is a different mechanism), the MAC address (no
# persistent override), and machineId files at the userData root
# (platform.py has NO zcode machineid_file row - unlike cursor/qoder, no
# such file is part of ZCode's proven store map, so none is touched; the
# Electron identity rides storage.json/state.vscdb above).
#
# Every DERIVED path is ABSENCE-TOLERANT: a store the app never created is
# a loud skip, never a guess and never a failure. The script must stay
# bash 3.2-safe (macOS still ships /bin/bash 3.2 - no ${var,,}, mapfile,
# or associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/../linux/id_reset_common.sh"

show_banner "ZCode Identity Reset (macOS)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every ZCode reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth). The
# userData-root label is "config" in the macos column but "roaming" on
# windows - accept whichever the resolved map carries so the script still
# runs honestly if invoked off its home platform.
path_report=$(python3 "$GHOST_CLI_PATH" paths zcode)
CONFIG_ROOT=$(python3 -c "import json,sys; p=json.loads(sys.argv[1])['paths']; print(p.get('config') or p.get('roaming',''))" "$path_report")
CLI_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths']['cli_dir'])" "$path_report")
UNVERIFIED=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['unverified']))" "$path_report")
# Windows-hosted python translates stdout \n -> \r\n; strip a trailing \r
# so a cross-host run never carries it into a path (a native macOS/Linux
# host never produces it, and stripping is a no-op there).
CONFIG_ROOT="${CONFIG_ROOT%$'\r'}"
CLI_DIR="${CLI_DIR%$'\r'}"
UNVERIFIED="${UNVERIFIED%$'\r'}"
if [[ -n "$UNVERIFIED" ]]; then
    warn "PROVENANCE: the following paths are DERIVED (Windows layout + macOS"
    warn "conventions), NOT yet live-verified: $UNVERIFIED"
    warn "A store that moved is skipped loudly below - nothing is guessed."
fi

generate_ids() {
    DEV_DEVICE_ID=$(generate_uuid)
    MACHINE_ID=$(generate_hex 32)
    MAC_MACHINE_ID=$(generate_hex 64)
    SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
}

# ── macOS-side store helpers (built on the shared lib + core verbs) ─────

delete_store() {
    # delete_store <path> <label> - core store-delete (backup/rename into
    # the ID_Backups root, then remove; a same-volume rename on the default
    # single-volume mac layout). An absent path is a loud skip.
    # Returns 0 ok/skip, 1 failed - the caller counts.
    local path="$1" label="$2"
    if [[ ! -e "$path" ]]; then
        warn "not present - skipped (first-launch state): $path"
        audit_line "$AUDIT_FILE" "$path" "missing" "skipped" 1
        return 0
    fi
    if python3 "$GHOST_CLI_PATH" store-delete "$path" "$BACKUP_ROOT" "$label" --action delete; then
        ok "deleted (backed up): $path"
        audit_line "$AUDIT_FILE" "$path" "-" "deleted" 1
        return 0
    fi
    err "delete FAILED: $path"
    audit_line "$AUDIT_FILE" "$path" "-" "failed" 0
    return 1
}

sweep_tree_audit() {
    # sweep_tree_audit <path> - core sweep-tree (backup-first, per-file
    # delete with a retry curve). An absent tree is a loud skip.
    # Returns 0 ok/skip, 1 failed - the caller counts.
    local path="$1"
    if [[ ! -d "$path" ]]; then
        warn "not present - skipped (first-launch state): $path"
        audit_line "$AUDIT_FILE" "$path" "missing" "skipped" 1
        return 0
    fi
    if python3 "$GHOST_CLI_PATH" sweep-tree "$path" "$BACKUP_ROOT" "$(basename "$path")"; then
        ok "swept: $path"
        audit_line "$AUDIT_FILE" "$path" "-" "swept" 1
        return 0
    fi
    err "sweep-tree FAILED: $path"
    audit_line "$AUDIT_FILE" "$path" "-" "failed" 0
    return 1
}

# ── main ────────────────────────────────────────────────────────────────
ensure_not_running "zcode"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "ZCode installation not found at: $CONFIG_ROOT (store may live elsewhere on this macOS - live verification pending)."
    exit 1
fi

BACKUP_ROOT="$CONFIG_ROOT/ID_Backups/$(timestamp)"
mkdir -p "$BACKUP_ROOT"
RESTORE_ENTRIES=()
audit_init "$BACKUP_ROOT"

STORAGE_JSON="$CONFIG_ROOT/User/globalStorage/storage.json"
STATE_VSCDB="$CONFIG_ROOT/User/globalStorage/state.vscdb"
# The CLI-side v2 stores (cli_dir is platform-agnostic in platform.py; the
# specific FILES are derived from the Windows layout - surfaced unverified
# by the paths verb above). Built inline from cli_dir, matching the Linux
# v0.2 script - the per-file labels exist only in some platform columns.
TELEMETRY_STATE="$CLI_DIR/v2/telemetry-state.json"
CREDENTIALS_JSON="$CLI_DIR/v2/credentials.json"
SETTING_JSON="$CLI_DIR/v2/setting.json"

PASS_COUNT=0
FAIL_COUNT=0

generate_ids
ok "Generated new identifiers:"
dim "  devDeviceId:   $DEV_DEVICE_ID"
dim "  machineId:     $MACHINE_ID"
dim "  macMachineId:  $MAC_MACHINE_ID"
dim "  sqmId:         $SQM_ID"

info ""
info "[1/6] Electron stores (storage.json + state.vscdb)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/6] CLI telemetry state deviceMid (core: json-set)..."
if [[ -f "$TELEMETRY_STATE" ]]; then
    if core_json_set_kv "$TELEMETRY_STATE" "telemetry-state" "deviceMid" "\"$DEV_DEVICE_ID\"" \
       && verify_json_keys "$TELEMETRY_STATE" "deviceMid=$DEV_DEVICE_ID"; then
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
info "[3/6] Credentials OAuth clear (core: json-remove oauth: prefix + zcodejwttoken)..."
if [[ -f "$CREDENTIALS_JSON" ]]; then
    cred_backup=$(core_backup "$CREDENTIALS_JSON" "$BACKUP_ROOT" "credentials")
    if python3 "$GHOST_CLI_PATH" json-remove "$CREDENTIALS_JSON" "$BACKUP_ROOT" "credentials-oauth" \
       "$(b64_remove_payload '["zcodejwttoken"]' '["oauth:"]')"; then
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
info "[4/6] setting.json deviceSid (core: json-set dotted)..."
if [[ -f "$SETTING_JSON" ]]; then
    if core_json_set_kv "$SETTING_JSON" "setting-json" \
       "webRemoteControlExternalRelayDevice.deviceSid" "\"$DEV_DEVICE_ID\"" \
       && verify_json_keys "$SETTING_JSON" "webRemoteControlExternalRelayDevice.deviceSid=$DEV_DEVICE_ID"; then
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
info "[5/6] ~/Library sweep (Caches, Logs, Preferences, Saved Application State, HTTPStorages - DERIVED)..."
LIB_FAILED=0
for p in "$HOME/Library/Caches/ZCode" "$HOME/Library/Logs/ZCode"; do
    if delete_store "$p" "library-$(basename "$p")"; then
        :
    else
        LIB_FAILED=1
    fi
done
shopt -s nullglob
for p in "$HOME/Library/Preferences/"com.zhipuai* \
         "$HOME/Library/Saved Application State/"*[Zz][Cc]ode*.savedState \
         "$HOME/Library/HTTPStorages/"*[Zz][Cc]ode*; do
    if delete_store "$p" "library-entry"; then
        :
    else
        LIB_FAILED=1
    fi
done
shopt -u nullglob
if [[ "$LIB_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[6/6] Final probe (read-only) + preservation audit + system-identity skip..."
PROBE_FAILED=0
if [[ -f "$STORAGE_JSON" ]]; then
    if verify_json_keys "$STORAGE_JSON" \
            "telemetry.devDeviceId=$DEV_DEVICE_ID" \
            "storage.serviceMachineId=$DEV_DEVICE_ID"; then
        ok "storage.json re-verified."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "re-verified" 1
    else
        err "storage.json final verify FAILED."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "verify-failed" 0
        PROBE_FAILED=1
    fi
fi
if [[ -f "$TELEMETRY_STATE" ]]; then
    if verify_json_keys "$TELEMETRY_STATE" "deviceMid=$DEV_DEVICE_ID"; then
        ok "telemetry-state.json re-verified."
        audit_line "$AUDIT_FILE" "$TELEMETRY_STATE" "-" "re-verified" 1
    else
        err "telemetry-state final verify FAILED."
        audit_line "$AUDIT_FILE" "$TELEMETRY_STATE" "-" "verify-failed" 0
        PROBE_FAILED=1
    fi
fi
if [[ -f "$SETTING_JSON" ]]; then
    if verify_json_keys "$SETTING_JSON" "webRemoteControlExternalRelayDevice.deviceSid=$DEV_DEVICE_ID"; then
        ok "setting.json re-verified."
        audit_line "$AUDIT_FILE" "$SETTING_JSON" "-" "re-verified" 1
    else
        err "setting.json final verify FAILED."
        audit_line "$AUDIT_FILE" "$SETTING_JSON" "-" "verify-failed" 0
        PROBE_FAILED=1
    fi
fi
# Preservation audit: the stores this resetter deliberately keeps (the
# same contract as the Windows + Linux ZCode resets).
info "Preserved (never touched): the shared CLI session db (~/.zcode/cli/db/db.sqlite),"
info "cli/config.json (provider definitions + MCP), cli/tasks-index."
audit_line "$AUDIT_FILE" "~/.zcode/cli/db/db.sqlite (shared CLI session store)" "-" "preserved" 1
audit_line "$AUDIT_FILE" "~/.zcode/cli/config.json (provider definitions + MCP)" "-" "preserved" 1
# macOS system identity: a loud, audited skip (no honest userspace analog).
warn "System identity NOT reset on macOS (see the header NOT-covered list):"
warn "  IOPlatformUUID (immutable) | hostname | MAC"
audit_line "$AUDIT_FILE" "system-identity (IOPlatformUUID/hostname/MAC)" "-" "skipped-no-analog" 1
if [[ "$PROBE_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
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
