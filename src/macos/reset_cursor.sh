#!/usr/bin/env bash
# Cursor Machine ID Reset Script for macOS (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-18, issue #36 follow-up): the macOS store
# layout is derived from the proven Windows reset_cursor.ps1 (v0.3, 15
# steps) + the live-verified Linux reset_cursor.sh (v0.2) + Electron
# conventions (~/Library/Application Support/Cursor) - rows are
# provenance-flagged unverified in ghost/platform.py and this script
# prints the caveat loudly.
#
# PRESERVATION POLICY (differs from the Qoder macOS resetter - Cursor
# keeps chat/UI state): Local Storage, the Backups tree, every file under
# User/workspaceStorage, and the cursorDiskKV table inside state.vscdb are
# NEVER touched (chat/composer data).
#
# Covered on macOS: the machineId files (BOTH spellings - the Linux script
# writes camelCase machineId, the Windows script lowercase machineid; the
# macOS spelling is unverified so whichever file the app created is
# rotated) + telemetry keys in storage.json + ItemTable upserts in
# state.vscdb (shared reset_electron_stores) + the state.vscdb auth
# secrets (core delete-secrets Cursor defaults) + the Preferences
# device_id_salt + the Local State os_crypt.encrypted_key pointer + the
# Network transport sweep + DIPS + SharedStorage + Trust Tokens + the
# sentry tree + the cache trees + Crashpad + logs + the workspaceStorage
# serviceMachineId upserts + the stale .backup sidecar purge.
#
# NOT covered on macOS (no honest analog, or deliberately out of scope):
# Keychain "Chromium Safe Storage" (the os_crypt key itself - remove it
# manually in Keychain Access; the Local State pointer IS removed here),
# IOPlatformUUID (immutable), hostname (scutil --set is a different
# mechanism), the MAC address (no persistent override), argv.json (the
# Windows Cursor resetter never touches it), and every chat-bearing store
# (cursorDiskKV, Local Storage, Backups, workspaceStorage files).
#
# Every DERIVED path is ABSENCE-TOLERANT: a store the app never created is
# a loud skip, never a guess and never a failure. The script must stay
# bash 3.2-safe (macOS still ships /bin/bash 3.2 - no ${var,,}, mapfile,
# or associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/../linux/id_reset_common.sh"

show_banner "Cursor Identity Reset (macOS)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every Cursor reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth). The
# userData-root label differs per column ("config" on linux/macos,
# "roaming" on windows) - accept whichever the resolved map carries so the
# script still runs honestly if invoked off its home platform.
path_report=$(python3 "$GHOST_CLI_PATH" paths cursor)
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

secrets_audit() {
    # secrets_audit <db> - core delete-secrets with NO config (the core's
    # Cursor defaults: secret://aicoding.auth.%, secret://blackbox.%,
    # gituser; ItemTable only - the chat-bearing cursorDiskKV table is
    # never touched). Audits each actually-deleted key and requires every
    # survivor count to be zero. Returns 0 only when zero survivors.
    local db="$1" report
    if ! report=$(python3 "$GHOST_CLI_PATH" delete-secrets "$db"); then
        err "delete-secrets core invocation FAILED: $db"
        audit_line "$AUDIT_FILE" "$db" "-" "core-invoke-failed" 0
        return 1
    fi
    while IFS='|' read -r key marker; do
        if [[ -z "$key" ]]; then continue; fi
        audit_line "$AUDIT_FILE" "$db" "present" "deleted" 1 "$key"
    done < <(python3 -c '
import json, sys
report = json.loads(sys.argv[1])
for key in report.get("deleted", []):
    print("{0}|deleted".format(key))
' "$report")
    local survivors_ok=1 summary="" survivor_lines count
    survivor_lines=$(python3 -c '
import json, sys
report = json.loads(sys.argv[1])
for c in report.get("survivors", []):
    print(c)
' "$report") || {
        err "delete-secrets survivor parse FAILED: $db"
        audit_line "$AUDIT_FILE" "$db" "-" "parse-failed" 0
        return 1
    }
    while IFS= read -r count; do
        if [[ -z "$count" ]]; then continue; fi
        count="${count%$'\r'}"
        summary="$summary$count "
        if [[ "$count" != "0" ]]; then
            survivors_ok=0
        fi
    done <<< "$survivor_lines"
    if [[ "$survivors_ok" == "1" ]]; then
        audit_line "$AUDIT_FILE" "$db" "-" "survivors=0" 1
        return 0
    fi
    err "secret survivors remain: $db (counts: $summary)"
    audit_line "$AUDIT_FILE" "$db" "-" "survivors>0" 0
    return 1
}

count_secrets_survivors() {
    # count_secrets_survivors <db> -> echoes the survivor count (0 expected).
    # READ-ONLY final probe twin of the Windows device-flow probe.
    local report survivors
    report=$(python3 "$GHOST_CLI_PATH" count-keys "$1" "$CURSOR_PROBE_B64")
    survivors=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['survivors'])" "$report")
    printf '%s\n' "${survivors%$'\r'}"
}

# ── main ────────────────────────────────────────────────────────────────
ensure_not_running "cursor"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "Cursor installation not found at: $CONFIG_ROOT (store may live elsewhere on this macOS - live verification pending)."
    exit 1
fi

BACKUP_ROOT="$CONFIG_ROOT/ID_Backups/$(timestamp)"
mkdir -p "$BACKUP_ROOT"
RESTORE_ENTRIES=()
audit_init "$BACKUP_ROOT"

STORAGE_JSON="$CONFIG_ROOT/User/globalStorage/storage.json"
STATE_VSCDB="$CONFIG_ROOT/User/globalStorage/state.vscdb"

PASS_COUNT=0
FAIL_COUNT=0

generate_ids
ok "Generated new identifiers:"
dim "  devDeviceId:   $DEV_DEVICE_ID"
dim "  machineId:     $MACHINE_ID"
dim "  macMachineId:  $MAC_MACHINE_ID"
dim "  sqmId:         $SQM_ID"

# Payloads that embed the generated IDs - built AFTER generate_ids (an
# earlier build would embed an empty devDeviceId).
CURSOR_PROBE_CONFIG='{"exact_keys":["gituser"],"like_patterns":["secret://aicoding.auth.%","secret://blackbox.%"],"table":"ItemTable"}'
CURSOR_PROBE_B64=$(printf '%s' "$CURSOR_PROBE_CONFIG" | b64_json_stdin)
WS_UPDATES_B64=$(printf '{"storage.serviceMachineId":"%s"}' "$DEV_DEVICE_ID" | b64_json_stdin)

info ""
info "[1/13] machineId files (camelCase machineId + lowercase machineid)..."
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
info "[2/13] Electron stores (storage.json + state.vscdb)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[3/13] state.vscdb auth secrets (delete-secrets Cursor defaults)..."
if [[ -f "$STATE_VSCDB" ]]; then
    if secrets_audit "$STATE_VSCDB"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "state.vscdb absent - secret purge skipped."
    audit_line "$AUDIT_FILE" "$STATE_VSCDB" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[4/13] Preferences device_id_salt..."
PREF_JSON="$CONFIG_ROOT/Preferences"
if [[ -f "$PREF_JSON" ]]; then
    if python3 "$GHOST_CLI_PATH" salt-rotate "$PREF_JSON" "$BACKUP_ROOT" "preferences-salt"; then
        ok "device_id_salt rotated + verified."
        audit_line "$AUDIT_FILE" "$PREF_JSON" "-" "salt-rotated" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "salt-rotate FAILED."
        audit_line "$AUDIT_FILE" "$PREF_JSON" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "Preferences absent - salt rotation skipped."
    audit_line "$AUDIT_FILE" "$PREF_JSON" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[5/13] Local State os_crypt.encrypted_key pointer..."
LOCAL_STATE="$CONFIG_ROOT/Local State"
if [[ -f "$LOCAL_STATE" ]]; then
    OS_PAYLOAD=$(printf '{"keys":["os_crypt.encrypted_key"],"prefixes":[]}' | b64_json_stdin)
    if python3 "$GHOST_CLI_PATH" json-remove "$LOCAL_STATE" "$BACKUP_ROOT" "local-state-os-crypt" "$OS_PAYLOAD"; then
        ok "os_crypt.encrypted_key removed + verified."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "os-crypt-cleared" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "json-remove FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "Local State absent - os_crypt pointer skipped."
    audit_line "$AUDIT_FILE" "$LOCAL_STATE" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi
warn "Keychain 'Chromium Safe Storage' NOT touched - remove it manually in"
warn "Keychain Access (the Local State pointer above IS removed)."
audit_line "$AUDIT_FILE" "Keychain Chromium Safe Storage" "-" "skipped-manual" 1

info ""
info "[6/13] Network transport sweep..."
NET_FAILED=0
for p in "Network/Cookies" "Network/Cookies-journal" "Network/Network Persistent State" \
         "Network/TransportSecurity" "Network/NetworkDataMigrated"; do
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
info "[7/13] DIPS + SharedStorage + Trust Tokens..."
TRK_FAILED=0
for p in "DIPS" "DIPS-wal" "SharedStorage" "SharedStorage-wal" \
         "Network/Trust Tokens" "Network/Trust Tokens-journal"; do
    if delete_store "$CONFIG_ROOT/$p" "store-$(basename "$p")"; then
        :
    else
        TRK_FAILED=1
    fi
done
if [[ "$TRK_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[8/13] sentry tree (scope_v3.json embeds email + fingerprint)..."
if sweep_tree_audit "$CONFIG_ROOT/sentry"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[9/13] cache trees (Local Storage + Backups preserved)..."
CACHE_FAILED=0
for tree in "Cache/Cache_Data" "Code Cache" "GPUCache" "blob_storage" \
            "Service Worker" "Session Storage"; do
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
info "[10/13] Crashpad + logs..."
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
info "[11/13] workspaceStorage state.vscdb serviceMachineId..."
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
info "[12/13] stale .backup sidecar purge..."
BAK_FAILED=0
BAK_HITS=0
shopt -s nullglob
for bak in "$CONFIG_ROOT"/*.backup "$CONFIG_ROOT/User/globalStorage"/*.backup; do
    BAK_HITS=$((BAK_HITS + 1))
    if rm -f "$bak"; then
        ok "stale sidecar removed: $bak"
        audit_line "$AUDIT_FILE" "$bak" "-" "removed" 1
    else
        err "sidecar removal FAILED: $bak"
        audit_line "$AUDIT_FILE" "$bak" "-" "failed" 0
        BAK_FAILED=1
    fi
done
shopt -u nullglob
if [[ "$BAK_HITS" == "0" ]]; then
    info "no stale .backup sidecars found - skipped."
    audit_line "$AUDIT_FILE" "$CONFIG_ROOT/*.backup" "missing" "skipped" 1
fi
if [[ "$BAK_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[13/13] Final probe (read-only) + preservation audit + system-identity skip..."
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
if [[ -f "$STATE_VSCDB" ]]; then
    if SURVIVORS=$(count_secrets_survivors "$STATE_VSCDB") && [[ "$SURVIVORS" == "0" ]]; then
        ok "secret purge probe: zero survivors."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "survivors=0" 1
    else
        err "secret purge probe found survivors (or the probe failed)."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "survivors=${SURVIVORS:-probe-failed}" 0
        PROBE_FAILED=1
    fi
fi
# Preservation audit: the chat/UI stores this resetter deliberately keeps.
info "Preserved (chat policy - never touched): Local Storage, Backups,"
info "workspaceStorage files, cursorDiskKV."
audit_line "$AUDIT_FILE" "Local Storage" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "Backups" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "cursorDiskKV" "-" "preserved-for-chat" 1
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
    err "Cursor reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "Cursor reset completed successfully."
