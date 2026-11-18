#!/usr/bin/env bash
# Trae IDE Machine ID Reset Script for macOS (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-19, issue #36 follow-up): the macOS store
# layout is derived from the Windows reset_trae.ps1 (v0.3 thin manifest,
# 16 steps) + the Linux reset_trae.sh (v0.3) recipes + Electron
# conventions (~/Library/Application Support/Trae) - BOTH templates are
# themselves DERIVED (no live host has verified trae rows off Windows);
# rows are provenance-flagged unverified in ghost/platform.py and this
# script prints the caveat loudly.
#
# PRESERVATION POLICY (Trae's, louder than qoder's): the ModularData/
# ai-agent scrub is IDENTITY-ROWS-ONLY - core scrub-rows matches key
# NAMES only (never values), so chat rows survive untouched; Local
# Storage/leveldb, the Backups tree, and every workspaceStorage file are
# NEVER deleted (workspace state.vscdb files are UPSERT-only).
#
# Covered on macOS: the machineId files (BOTH spellings - the Linux/
# platform rows say camelCase machineId, the Windows script lowercase
# machineid; the macOS spelling is unverified so whichever file the app
# created is rotated) + telemetry keys in storage.json + state.vscdb
# (shared reset_electron_stores) + the iCubeAuthInfo://* top-level-prefix
# removal + the has_device_id_updated_to_aha=false flag in BOTH stores +
# the aha tree delete + the ModularData/ckg_server local_env.json 19-digit
# device_id rotation (CSPRNG, first digit non-zero) + host_map removal +
# the env_codekg.db delete + the ai-agent identity-rows-only scrub + the
# Preferences device_id_salt + the Local State os_crypt pointer + the
# Network transport sweep + DIPS + SharedStorage + Trust Tokens + the
# webview/cache trees + Crashpad + logs + the workspaceStorage
# serviceMachineId upserts.
#
# NOT covered on macOS (no honest analog, or deliberately out of scope):
# Keychain "Chromium Safe Storage" (the os_crypt key itself - remove it
# manually in Keychain Access; the Local State pointer IS removed here),
# IOPlatformUUID (immutable), hostname (scutil --set is a different
# mechanism), the MAC address (no persistent override), argv.json (the
# Windows Trae resetter never touches it), and every chat-bearing store
# (ai-agent chat rows, Local Storage, Backups, workspaceStorage files).
#
# Every DERIVED path is ABSENCE-TOLERANT: a store the app never created is
# a loud skip, never a guess and never a failure. The script must stay
# bash 3.2-safe (macOS still ships /bin/bash 3.2 - no ${var,,}, mapfile,
# or associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/../linux/id_reset_common.sh"

show_banner "Trae Identity Reset (macOS)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every Trae reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth). The
# userData-root label differs per column ("config" on linux/macos,
# "roaming" on windows) - accept whichever the resolved map carries so the
# script still runs honestly if invoked off its home platform.
path_report=$(python3 "$GHOST_CLI_PATH" paths trae)
CONFIG_ROOT=$(python3 -c "import json,sys; p=json.loads(sys.argv[1])['paths']; print(p.get('config') or p.get('roaming',''))" "$path_report")
UNVERIFIED=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['unverified']))" "$path_report")
# Windows-hosted python translates stdout \n -> \r\n; strip a trailing \r
# so a cross-host run never carries it into a path (a native macOS/Linux
# host never produces it, and stripping is a no-op there).
CONFIG_ROOT="${CONFIG_ROOT%$'\r'}"
UNVERIFIED="${UNVERIFIED%$'\r'}"
if [[ -n "$UNVERIFIED" ]]; then
    warn "PROVENANCE: the following paths are DERIVED (Windows layout + macOS"
    warn "Electron conventions), NOT yet live-verified: $UNVERIFIED"
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
    # the ID_Backups root, then remove). An absent path is a loud skip.
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

rotate_machineid_file() {
    # rotate_machineid_file <path> <label> - core machineid-file (backup if
    # present, write, re-read verify). An ABSENT file is a loud skip -
    # never created, because on a DERIVED platform we only touch what the
    # app itself wrote.
    local path="$1" label="$2"
    if [[ ! -f "$path" ]]; then
        warn "not present - skipped (first-launch state): $path"
        audit_line "$AUDIT_FILE" "$path" "missing" "skipped" 1
        return 0
    fi
    local payload
    payload=$(printf '{"value":"%s"}' "$DEV_DEVICE_ID" | b64_json_stdin)
    if python3 "$GHOST_CLI_PATH" machineid-file "$path" "$BACKUP_ROOT" "$label" "$payload"; then
        ok "machineId rotated + verified: $path"
        audit_line "$AUDIT_FILE" "$path" "-" "$DEV_DEVICE_ID" 1
        return 0
    fi
    err "machineId rotation FAILED: $path"
    audit_line "$AUDIT_FILE" "$path" "-" "failed" 0
    return 1
}

verify_sqlite_kv() {
    # verify_sqlite_kv <db> <key> <expected> - read-only reopen compare.
    python3 - "$1" "$2" "$3" <<'PY'
import sqlite3, sys
db_path, key, expected = sys.argv[1:4]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("SELECT value FROM ItemTable WHERE key = ?", (key,))
row = cur.fetchone()
conn.close()
assert row is not None, "key missing after write: %s" % key
assert row[0] == expected, "value drifted for %s" % key
PY
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
ensure_not_running "trae"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "Trae installation not found at: $CONFIG_ROOT (store may live elsewhere on this macOS - live verification pending)."
    exit 1
fi

BACKUP_ROOT="$CONFIG_ROOT/ID_Backups/$(timestamp)"
mkdir -p "$BACKUP_ROOT"
RESTORE_ENTRIES=()
audit_init "$BACKUP_ROOT"

STORAGE_JSON="$CONFIG_ROOT/User/globalStorage/storage.json"
STATE_VSCDB="$CONFIG_ROOT/User/globalStorage/state.vscdb"
LOCAL_ENV="$CONFIG_ROOT/ModularData/ckg_server/local_env.json"

PASS_COUNT=0
FAIL_COUNT=0

generate_ids
ok "Generated new identifiers:"
dim "  devDeviceId:   $DEV_DEVICE_ID"
dim "  machineId:     $MACHINE_ID"
dim "  macMachineId:  $MAC_MACHINE_ID"
dim "  sqmId:         $SQM_ID"

# Payloads that embed the generated IDs - built AFTER generate_ids (an
# earlier build would embed an empty devDeviceId). The ckg_server
# device_id is a 19-DIGIT number (the format Trae's ckg_server stores,
# e.g. "7647529847245473300"); the CSPRNG twin keeps the first digit
# non-zero (the Windows reset_trae.ps1 generation contract, ported to the
# python3 secrets module per the Linux v0.3 recipe).
NEW_CKG_ID=$(python3 -c 'import secrets; print(secrets.randbelow(9 * 10**18) + 10**18)')
WS_UPDATES_B64=$(printf '{"storage.serviceMachineId":"%s"}' "$DEV_DEVICE_ID" | b64_json_stdin)
AHA_DB_UPDATES_B64=$(printf '{"has_device_id_updated_to_aha":"false"}' | b64_json_stdin)
OS_PAYLOAD=$(printf '{"keys":["os_crypt.encrypted_key"],"prefixes":[]}' | b64_json_stdin)

info ""
info "[1/15] machineId files (camelCase machineId + lowercase machineid)..."
MID_FAILED=0
if rotate_machineid_file "$CONFIG_ROOT/machineId" "machineId-camel"; then
    :
else
    MID_FAILED=1
fi
if rotate_machineid_file "$CONFIG_ROOT/machineid" "machineid-lower"; then
    :
else
    MID_FAILED=1
fi
if [[ "$MID_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/15] iCubeAuthInfo:// top-level-prefix removal (storage.json)..."
if [[ -f "$STORAGE_JSON" ]]; then
    # Windows [2] order: the removal FIRST - its backup is the pre-run
    # restore point for the whole storage.json mutation chain.
    if core_json_remove "$STORAGE_JSON" "storage-icube-auth" "[]" '["iCubeAuthInfo://"]'; then
        ok "iCubeAuthInfo://* keys removed + verified."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "icube-prefixes-removed" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "iCube prefix removal FAILED."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "storage.json absent - iCube removal skipped (first launch creates it)."
    audit_line "$AUDIT_FILE" "$STORAGE_JSON" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[3/15] Electron stores (storage.json + state.vscdb telemetry)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[4/15] aha flag has_device_id_updated_to_aha=false (BOTH stores)..."
AHA_FAILED=0
if [[ -f "$STORAGE_JSON" ]]; then
    # JSON STRING "false" (not the boolean) - matches the Windows payload
    # semantics and keeps the verify-after comparison deterministic.
    if core_json_set_kv "$STORAGE_JSON" "storage-aha-flag" "has_device_id_updated_to_aha" '"false"' \
       && verify_json_keys "$STORAGE_JSON" "has_device_id_updated_to_aha=false"; then
        ok "storage.json aha flag set + verified."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "aha-flag=false" 1
    else
        err "storage.json aha flag FAILED."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "failed" 0
        AHA_FAILED=1
    fi
else
    warn "storage.json absent - aha flag skipped."
    audit_line "$AUDIT_FILE" "$STORAGE_JSON" "missing" "skipped" 1
fi
if [[ -f "$STATE_VSCDB" ]]; then
    if python3 "$GHOST_CLI_PATH" sqlite-update "$STATE_VSCDB" "$AHA_DB_UPDATES_B64" \
       && verify_sqlite_kv "$STATE_VSCDB" "has_device_id_updated_to_aha" "false"; then
        ok "state.vscdb aha flag set + verified."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "aha-flag=false" 1
    else
        err "state.vscdb aha flag FAILED."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "failed" 0
        AHA_FAILED=1
    fi
else
    warn "state.vscdb absent - aha flag skipped."
    audit_line "$AUDIT_FILE" "$STATE_VSCDB" "missing" "skipped" 1
fi
if [[ "$AHA_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[5/15] stale state.vscdb.backup..."
BAK_PATH="$CONFIG_ROOT/User/globalStorage/state.vscdb.backup"
if [[ -f "$BAK_PATH" ]]; then
    if python3 "$GHOST_CLI_PATH" sweep-file "$BAK_PATH"; then
        ok "stale sidecar removed: $BAK_PATH"
        audit_line "$AUDIT_FILE" "$BAK_PATH" "-" "removed" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "sweep-file FAILED: $BAK_PATH"
        audit_line "$AUDIT_FILE" "$BAK_PATH" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "not present - skipped (first-launch state): $BAK_PATH"
    audit_line "$AUDIT_FILE" "$BAK_PATH" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[6/15] aha tree delete..."
if sweep_tree_audit "$CONFIG_ROOT/aha"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[7/15] ckg_server local_env.json (19-digit device_id + host_map removal)..."
if [[ -f "$LOCAL_ENV" ]]; then
    if core_json_set_kv "$LOCAL_ENV" "ckg-local-env" "device_id" "\"$NEW_CKG_ID\"" \
       && core_json_remove "$LOCAL_ENV" "ckg-host-map" '["host_map"]' '[]' \
       && verify_json_keys "$LOCAL_ENV" "device_id=$NEW_CKG_ID"; then
        ok "ckg device_id rotated + host_map removed + verified."
        audit_line "$AUDIT_FILE" "$LOCAL_ENV" "-" "$NEW_CKG_ID" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "ckg local_env rotation FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_ENV" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "ckg_server local_env.json absent - rotation skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$LOCAL_ENV" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[8/15] env_codekg.db delete..."
if delete_store "$CONFIG_ROOT/ModularData/ckg_server/env_codekg.db" "env-codekg"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[9/15] ai-agent identity-rows-only scrub (chat rows never inspected)..."
AGENT_DIR="$CONFIG_ROOT/ModularData/ai-agent"
if [[ -d "$AGENT_DIR" ]]; then
    # The Windows [8] contract: backup the whole tree first (one pristine
    # pre-run copy), then scrub every *.db inside it.
    core_backup "$AGENT_DIR" "$BACKUP_ROOT" "ai-agent-tree" >/dev/null || true
    AGENT_FAILED=0
    AGENT_HITS=0
    agent_dbs=$(find "$AGENT_DIR" -type f -name "*.db" 2>/dev/null || true)
    while IFS= read -r agent_db; do
        if [[ -z "$agent_db" ]]; then continue; fi
        AGENT_HITS=$((AGENT_HITS + 1))
        if agent_report=$(python3 "$GHOST_CLI_PATH" scrub-rows "$agent_db"); then
            agent_ok=$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print("1" if int(r["survivors"]) == 0 else "0")' "$agent_report") || agent_ok="0"
            agent_ok="${agent_ok%$'\r'}"
            if [[ "$agent_ok" == "1" ]]; then
                ok "ai-agent DB scrubbed + verified: $agent_db"
                audit_line "$AUDIT_FILE" "$agent_db" "-" "identity-rows-scrubbed" 1
            else
                err "ai-agent scrub survivors > 0: $agent_db"
                audit_line "$AUDIT_FILE" "$agent_db" "-" "survivors>0" 0
                AGENT_FAILED=1
            fi
        else
            err "scrub-rows core invocation FAILED: $agent_db"
            audit_line "$AUDIT_FILE" "$agent_db" "-" "core-invoke-failed" 0
            AGENT_FAILED=1
        fi
    done <<< "$agent_dbs"
    if [[ "$AGENT_HITS" == "0" ]]; then
        info "no ai-agent *.db files found - preserved (first-launch state)."
        audit_line "$AUDIT_FILE" "$AGENT_DIR" "no-db-files" "preserved" 1
    fi
    if [[ "$AGENT_FAILED" == "0" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "ModularData/ai-agent absent - scrub skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$AGENT_DIR" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[10/15] Preferences device_id_salt + Local State os_crypt pointer..."
PREF_FAILED=0
PREF_JSON="$CONFIG_ROOT/Preferences"
if [[ -f "$PREF_JSON" ]]; then
    if python3 "$GHOST_CLI_PATH" salt-rotate "$PREF_JSON" "$BACKUP_ROOT" "preferences-salt"; then
        ok "device_id_salt rotated + verified."
        audit_line "$AUDIT_FILE" "$PREF_JSON" "-" "salt-rotated" 1
    else
        err "salt-rotate FAILED."
        audit_line "$AUDIT_FILE" "$PREF_JSON" "-" "failed" 0
        PREF_FAILED=1
    fi
else
    warn "Preferences absent - salt rotation skipped."
    audit_line "$AUDIT_FILE" "$PREF_JSON" "missing" "skipped" 1
fi
LOCAL_STATE="$CONFIG_ROOT/Local State"
if [[ -f "$LOCAL_STATE" ]]; then
    if python3 "$GHOST_CLI_PATH" json-remove "$LOCAL_STATE" "$BACKUP_ROOT" "local-state-os-crypt" "$OS_PAYLOAD"; then
        ok "os_crypt.encrypted_key removed + verified."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "os-crypt-cleared" 1
    else
        err "json-remove FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "failed" 0
        PREF_FAILED=1
    fi
else
    warn "Local State absent - os_crypt pointer skipped."
    audit_line "$AUDIT_FILE" "$LOCAL_STATE" "missing" "skipped" 1
fi
warn "Keychain 'Chromium Safe Storage' NOT touched - remove it manually in"
warn "Keychain Access (the Local State pointer above IS removed)."
audit_line "$AUDIT_FILE" "Keychain Chromium Safe Storage" "-" "skipped-manual" 1
if [[ "$PREF_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[11/15] Network transport + tracking stores sweep..."
NET_FAILED=0
for p in "Network/Cookies" "Network/Cookies-journal" "Network/Network Persistent State" \
         "Network/TransportSecurity" "DIPS" "DIPS-wal" \
         "SharedStorage" "SharedStorage-wal" \
         "Network/Trust Tokens" "Network/Trust Tokens-journal"; do
    if delete_store "$CONFIG_ROOT/$p" "store-$(basename "$p")"; then
        :
    else
        NET_FAILED=1
    fi
done
if [[ "$NET_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[12/15] webview + cache trees (Local Storage + Backups preserved)..."
CACHE_FAILED=0
for tree in "Partitions/trae-webview" "Cache/Cache_Data" "Code Cache" "GPUCache" \
            "blob_storage" "Service Worker" "Session Storage" "WebStorage" \
            "Shared Dictionary"; do
    if sweep_tree_audit "$CONFIG_ROOT/$tree"; then
        :
    else
        CACHE_FAILED=1
    fi
done
if [[ "$CACHE_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[13/15] Crashpad + logs..."
CRASH_FAILED=0
for tree in "Crashpad" "logs"; do
    if sweep_tree_audit "$CONFIG_ROOT/$tree"; then
        :
    else
        CRASH_FAILED=1
    fi
done
if [[ "$CRASH_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[14/15] workspaceStorage state.vscdb serviceMachineId..."
WS_FAILED=0
WS_HITS=0
shopt -s nullglob
for wsdb in "$CONFIG_ROOT/User/workspaceStorage/"*/state.vscdb; do
    WS_HITS=$((WS_HITS + 1))
    ws_b=$(core_backup "$wsdb" "$BACKUP_ROOT" "workspace-state-vscdb")
    if python3 "$GHOST_CLI_PATH" sqlite-update "$wsdb" "$WS_UPDATES_B64" \
       && verify_sqlite_kv "$wsdb" "storage.serviceMachineId" "$DEV_DEVICE_ID"; then
        ok "workspaceStorage updated + verified."
        audit_line "$AUDIT_FILE" "$wsdb" "backup=$(basename "${ws_b:-none}")" "$DEV_DEVICE_ID" 1
    else
        err "workspaceStorage update/verify FAILED: $wsdb"
        audit_line "$AUDIT_FILE" "$wsdb" "-" "failed" 0
        WS_FAILED=1
    fi
done
shopt -u nullglob
if [[ "$WS_HITS" == "0" ]]; then
    info "no workspaceStorage databases found - skipped."
    audit_line "$AUDIT_FILE" "$CONFIG_ROOT/User/workspaceStorage" "missing" "skipped" 1
fi
if [[ "$WS_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[15/15] Final probe (read-only) + preservation audit + system-identity skip..."
PROBE_FAILED=0
if [[ -f "$STORAGE_JSON" ]]; then
    if verify_json_keys "$STORAGE_JSON" \
            "telemetry.devDeviceId=$DEV_DEVICE_ID" \
            "storage.serviceMachineId=$DEV_DEVICE_ID" \
            "has_device_id_updated_to_aha=false"; then
        ok "storage.json re-verified."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "re-verified" 1
    else
        err "storage.json final verify FAILED."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "verify-failed" 0
        PROBE_FAILED=1
    fi
fi
for mid in "$CONFIG_ROOT/machineId" "$CONFIG_ROOT/machineid"; do
    if [[ -f "$mid" ]]; then
        if verify_file_value "$mid" "$DEV_DEVICE_ID"; then
            ok "machineId re-verified: $mid"
            audit_line "$AUDIT_FILE" "$mid" "-" "re-verified" 1
        else
            err "machineId final verify FAILED: $mid"
            audit_line "$AUDIT_FILE" "$mid" "-" "verify-failed" 0
            PROBE_FAILED=1
        fi
    fi
done
if [[ -f "$LOCAL_ENV" ]]; then
    if verify_json_keys "$LOCAL_ENV" "device_id=$NEW_CKG_ID"; then
        ok "ckg device_id re-verified."
        audit_line "$AUDIT_FILE" "$LOCAL_ENV" "-" "re-verified" 1
    else
        err "ckg device_id final verify FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_ENV" "-" "verify-failed" 0
        PROBE_FAILED=1
    fi
fi
# Preservation audit: the chat/UI stores this resetter deliberately keeps.
info "Preserved (chat policy - never touched): Local Storage, Backups,"
info "workspaceStorage files, ai-agent chat rows."
audit_line "$AUDIT_FILE" "Local Storage" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "Backups" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "ai-agent chat rows" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "User/workspaceStorage files" "-" "preserved" 1
# macOS system identity: a loud, audited skip (no honest userspace analog).
warn "System identity NOT reset on macOS (see the header NOT-covered list):"
warn "  IOPlatformUUID (immutable) | Keychain 'Chromium Safe Storage' (remove manually) | hostname | MAC"
audit_line "$AUDIT_FILE" "system-identity (IOPlatformUUID/Keychain/hostname/MAC)" "-" "skipped-no-analog" 1
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

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    err "Trae reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "Trae reset completed successfully."
