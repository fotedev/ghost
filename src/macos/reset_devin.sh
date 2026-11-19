#!/usr/bin/env bash
# Devin/Windsurf Desktop Machine ID Reset Script for macOS (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-19, issue #36 follow-up): the macOS store
# layout is derived from the Windows reset_devin.ps1 (v0.4 thin manifest,
# 17 steps x N auto-detected %APPDATA% roots - LIVE-VERIFIED on Windows)
# and the Linux reset_devin.sh (v0.3 - LIVE-VERIFIED on Linux), ported
# onto the macOS platform.py column (config = ~/Library/Application
# Support/Windsurf, windsurf_dir = ~/.windsurf, codeium_dir = ~/.codeium).
# The macOS ROWS themselves are provenance-flagged unverified in
# ghost/platform.py and this script prints the caveat loudly.
#
# PRESERVATION POLICY (Devin/Windsurf's, per the Windows v0.4 contract):
# Local Storage/leveldb and the Backups tree are chat/UI state and are
# NEVER touched; WebStorage + IndexedDB are deliberately out of scope;
# workspaceStorage state.vscdb files are UPSERT-only (never deleted); the
# cursorDiskKV analog does not exist here.
#
# The Windows resetter auto-detects BOTH %APPDATA% roots (Devin +
# Windsurf) because a pre-rebrand install persists under its own name.
# On macOS this probe is DELIBERATELY NOT made: a ~/Library/Application
# Support/Devin directory cannot be distinguished from the (Windows
# %LOCALAPPDATA%-equivalent) devin CLI home on a case-insensitive volume
# - touching it would guess. Only the mapped Windsurf root is reset; a
# Devin-named sibling (if it exists) is left untouched and audited as
# such below (live macOS acceptance is the item that resolves this).
#
# Covered on macOS: the machineId files (BOTH spellings - the macOS
# spelling is unverified so whichever file the app created is rotated) +
# the 5-key telemetry semantics in storage.json + state.vscdb (shared
# reset_electron_stores: telemetry.machineId/macMachineId/sqmId/
# devDeviceId + storage.serviceMachineId) + the state.vscdb auth-secret
# DELETE with the EXACT Windows v0.4 ESCAPE'd windsurf/devin LIKE
# patterns + the stale state.vscdb.backup + the Preferences
# device_id_salt + the Local State os_crypt pointer + the username scrub
# (Preferences + Local State + argv.json) + the Network transport sweep +
# DIPS + SharedStorage + Trust Tokens + the EXTENDED rebrand-era cache
# sweep (CachedData/CachedProfilesData/CachedExtensionVSIXs/
# CachedConfigurations/DawnGraphiteCache/DawnWebGPUCache/Shared Dictionary
# verified live on Windows 2026-09-21) + Crashpad + logs + the
# workspaceStorage serviceMachineId upserts + cli/installation_id +
# credentials.toml (holds windsurf_api_key) + config.json devin.org_id
# blanking (skip_if_empty) + the shared ~/.codeium/config.json device_id
# rotation + the argv.json crash-reporter-id in BOTH ~/.windsurf and
# ~/.devin + ~/.windsurf/installation_id + the updater-cache trees.
#
# NOT covered on macOS (no honest analog, or deliberately out of scope):
# Keychain "Chromium Safe Storage" (the os_crypt key itself - remove it
# manually in Keychain Access; the Local State pointer IS removed here),
# IOPlatformUUID (immutable), hostname (scutil --set is a different
# mechanism), the MAC address (no persistent override), the
# Devin-named Application Support sibling (see the no-probe rationale
# above), the devin CLI home + ~/.devin-shared (never touched, Windows
# contract), and every chat-bearing store (Local Storage, Backups,
# WebStorage, IndexedDB).
#
# The Linux v0.3 writes portal_url/inference_url back into
# ~/.codeium/config.json; that write is DELIBERATELY DROPPED here - it
# would overwrite a live user endpoint with a stale URL.
#
# Every DERIVED path is ABSENCE-TOLERANT: a store the app never created is
# a loud skip, never a guess and never a failure. The script must stay
# bash 3.2-safe (macOS still ships /bin/bash 3.2 - no ${var,,}, mapfile,
# or associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/../linux/id_reset_common.sh"

show_banner "Devin/Windsurf Identity Reset (macOS)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every Devin/Windsurf reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth). The
# userData-root label differs per column ("config" on linux/macos,
# "roaming" on windows) - accept whichever the resolved map carries so the
# script still runs honestly if invoked off its home platform.
path_report=$(python3 "$GHOST_CLI_PATH" paths devin)
CONFIG_ROOT=$(python3 -c "import json,sys; p=json.loads(sys.argv[1])['paths']; print(p.get('config') or p.get('roaming',''))" "$path_report")
WINDSURF_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('windsurf_dir',''))" "$path_report")
CODEIUM_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('codeium_dir',''))" "$path_report")
UNVERIFIED=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['unverified']))" "$path_report")
# Windows-hosted python translates stdout \n -> \r\n; strip a trailing \r
# so a cross-host run never carries it into a path (a native macOS/Linux
# host never produces it, and stripping is a no-op there).
CONFIG_ROOT="${CONFIG_ROOT%$'\r'}"
WINDSURF_DIR="${WINDSURF_DIR%$'\r'}"
CODEIUM_DIR="${CODEIUM_DIR%$'\r'}"
UNVERIFIED="${UNVERIFIED%$'\r'}"
if [[ -n "$UNVERIFIED" ]]; then
    warn "PROVENANCE: the following paths are DERIVED (Windows layout + macOS"
    warn "Electron conventions), NOT yet live-verified: $UNVERIFIED"
    warn "A store that moved is skipped loudly below - nothing is guessed."
fi

# The username scrub target (Windows $env:USERNAME). Empty = the scrub
# steps are loud skips, never a blind write of an empty find-string.
SCRUB_USER="${USER:-}"
if [[ -z "$SCRUB_USER" ]]; then
    SCRUB_USER=$(id -un 2>/dev/null || true)
fi

generate_ids() {
    DEV_DEVICE_ID=$(generate_uuid)
    MACHINE_ID=$(generate_hex 32)
    MAC_MACHINE_ID=$(generate_hex 64)
    SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    # The crash-reporter-id is a LOWERCASE GUID (identity_utils.ps1
    # Get-NewCrashReporterId contract, per the Windows v0.4 payload).
    NEW_CRASH_ID=$(generate_uuid | tr '[:upper:]' '[:lower:]')
    # installation_id takes its own fresh lowercase GUID (Windows [13]/[15]
    # generate a fresh one per file - two distinct files, two distinct IDs).
    NEW_ROOT_INSTALL_ID=$(generate_uuid | tr '[:upper:]' '[:lower:]')
    NEW_HOME_INSTALL_ID=$(generate_uuid | tr '[:upper:]' '[:lower:]')
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

rotate_file_value() {
    # rotate_file_value <path> <label> <value> - core machineid-file with an
    # arbitrary value (the machineId files take DEV_DEVICE_ID, the
    # installation_id files take fresh lowercase GUIDs). An ABSENT file is
    # a loud skip - never created, because on a DERIVED platform we only
    # touch what the app itself wrote.
    local path="$1" label="$2" value="$3"
    if [[ ! -f "$path" ]]; then
        warn "not present - skipped (first-launch state): $path"
        audit_line "$AUDIT_FILE" "$path" "missing" "skipped" 1
        return 0
    fi
    local payload
    payload=$(printf '{"value":"%s"}' "$value" | b64_json_stdin)
    if python3 "$GHOST_CLI_PATH" machineid-file "$path" "$BACKUP_ROOT" "$label" "$payload"; then
        ok "rotated + verified: $path"
        audit_line "$AUDIT_FILE" "$path" "-" "$value" 1
        return 0
    fi
    err "rotation FAILED: $path"
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

scrub_username() {
    # scrub_username <path> <label> - core replace-text
    # {"find": <user>, "replacement": "RESET"} on the raw text (the Linux
    # v0.3 + Windows [6] contract). Loud skip when the file is absent or
    # the username is empty (an empty find-string would match nothing and
    # report a false success).
    local path="$1" label="$2"
    if [[ ! -f "$path" ]]; then
        warn "not present - skipped (first-launch state): $path"
        audit_line "$AUDIT_FILE" "$path" "missing" "skipped" 1
        return 0
    fi
    if [[ -z "$SCRUB_USER" ]]; then
        warn "username unavailable - scrub skipped: $path"
        audit_line "$AUDIT_FILE" "$path" "no-username" "skipped" 1
        return 0
    fi
    local payload
    payload=$(python3 -c 'import base64, json, sys; print(base64.b64encode(json.dumps({"find": sys.argv[1], "replacement": "RESET"}).encode()).decode())' "$SCRUB_USER")
    if python3 "$GHOST_CLI_PATH" replace-text "$path" "$BACKUP_ROOT" "$label" "$payload"; then
        ok "username scrubbed + verified: $path"
        audit_line "$AUDIT_FILE" "$path" "-" "username-scrubbed" 1
        return 0
    fi
    err "username scrub FAILED: $path"
    audit_line "$AUDIT_FILE" "$path" "-" "failed" 0
    return 1
}

# ── main ────────────────────────────────────────────────────────────────
ensure_not_running "windsurf"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "Devin/Windsurf installation not found at: $CONFIG_ROOT (store may live elsewhere on this macOS - live verification pending)."
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
dim "  devDeviceId:     $DEV_DEVICE_ID"
dim "  machineId:       $MACHINE_ID"
dim "  macMachineId:    $MAC_MACHINE_ID"
dim "  sqmId:           $SQM_ID"
dim "  crashReporterId: $NEW_CRASH_ID"

# Payloads that embed the generated IDs - built AFTER generate_ids (an
# earlier build would embed an empty devDeviceId). The delete-secrets
# config is the EXACT Windows v0.4 config (5 exact keys + 5 ESCAPE'd LIKE
# patterns, escape = backslash); built via python3 so the backslash
# escaping is JSON-correct by construction (the PowerShell hashtable
# ConvertTo-Json equivalent).
NEW_SECRETS_CONFIG_B64=$(python3 -c '
import base64, json
cfg = {
    "exact_keys": ["codeium.windsurf-windsurf_auth", "windsurfAuthStatus",
                   "windsurf.settings.cachedPlanInfo", "devinAuthStatus",
                   "devin.settings.cachedPlanInfo"],
    "like_patterns": ["windsurf\\_auth-%", "%windsurf\\_auth%",
                      "%cachedPlanInfoData:user-%", "devin\\_auth-%",
                      "%devin\\_auth%"],
    "escape": "\\",
}
print(base64.b64encode(json.dumps(cfg).encode()).decode())
' | tr -d '\r')
OS_PAYLOAD=$(printf '{"keys":["os_crypt.encrypted_key"],"prefixes":[]}' | b64_json_stdin)
WS_UPDATES_B64=$(printf '{"storage.serviceMachineId":"%s"}' "$DEV_DEVICE_ID" | b64_json_stdin)

info ""
info "[1/17] machineId files (camelCase machineId + lowercase machineid)..."
MID_FAILED=0
if rotate_file_value "$CONFIG_ROOT/machineId" "machineId-camel" "$DEV_DEVICE_ID"; then
    :
else
    MID_FAILED=1
fi
if rotate_file_value "$CONFIG_ROOT/machineid" "machineid-lower" "$DEV_DEVICE_ID"; then
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
info "[2/17] Electron stores (storage.json + state.vscdb telemetry)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[3/17] state.vscdb auth secrets DELETE (windsurf/devin patterns)..."
if [[ -f "$STATE_VSCDB" ]]; then
    # Windows [4] contract: a pristine backup BEFORE the delete-secrets
    # mutation (the verb itself takes no backup args).
    core_backup "$STATE_VSCDB" "$BACKUP_ROOT" "state-vscdb-pre-secrets" >/dev/null || true
    if secrets_report=$(python3 "$GHOST_CLI_PATH" delete-secrets "$STATE_VSCDB" "$NEW_SECRETS_CONFIG_B64"); then
        secrets_report="${secrets_report%$'\r'}"
        secrets_ok=$(python3 -c '
import json, sys
r = json.loads(sys.argv[1])
s = r.get("survivors", [])
sys.stdout.write("0" if all(int(x) == 0 for x in s) else "1")
' "$secrets_report") || secrets_ok="0"
        secrets_ok="${secrets_ok%$'\r'}"
        if [[ "$secrets_ok" == "0" ]]; then
            ok "auth secrets deleted + zero survivors."
            audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "auth-secrets-deleted" 1
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            err "delete-secrets survivors > 0."
            audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "survivors>0" 0
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        err "delete-secrets core invocation FAILED."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "core-invoke-failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "state.vscdb absent - auth-secrets delete skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$STATE_VSCDB" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[4/17] stale state.vscdb.backup..."
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
info "[5/17] Preferences salt + Local State os_crypt pointer + username scrub..."
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
if scrub_username "$PREF_JSON" "preferences-username"; then
    :
else
    PREF_FAILED=1
fi
if scrub_username "$LOCAL_STATE" "local-state-username"; then
    :
else
    PREF_FAILED=1
fi
if [[ "$PREF_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[6/17] Network transport + tracking stores sweep..."
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
info "[7/17] EXTENDED cache sweep (rebrand-era dirs included; Local Storage + Backups preserved)..."
CACHE_FAILED=0
for tree in "Cache/Cache_Data" "Code Cache" "GPUCache" "blob_storage" \
            "Service Worker" "Session Storage" "CachedData" "CachedProfilesData" \
            "CachedExtensionVSIXs" "CachedConfigurations" "DawnGraphiteCache" \
            "DawnWebGPUCache" "Shared Dictionary"; do
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
info "[8/17] Crashpad + logs..."
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
info "[9/17] workspaceStorage state.vscdb serviceMachineId..."
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
info "[10/17] cli/installation_id rotation..."
if rotate_file_value "$CONFIG_ROOT/cli/installation_id" "cli-installation-id" "$NEW_ROOT_INSTALL_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[11/17] credentials.toml delete (holds windsurf_api_key)..."
if delete_store "$CONFIG_ROOT/credentials.toml" "credentials-toml"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[12/17] config.json devin.org_id blank (skip_if_empty)..."
ORG_CONFIG="$CONFIG_ROOT/config.json"
if [[ -f "$ORG_CONFIG" ]]; then
    ORG_PAYLOAD=$(python3 -c 'import base64, json, sys; print(base64.b64encode(json.dumps({"key": "devin.org_id", "value": "", "skip_if_empty": True}).encode()).decode())' | tr -d '\r')
    if python3 "$GHOST_CLI_PATH" json-set "$ORG_CONFIG" "$BACKUP_ROOT" "config-json" "$ORG_PAYLOAD" \
       && verify_json_keys "$ORG_CONFIG" "devin.org_id="; then
        ok "devin.org_id blanked + verified."
        audit_line "$AUDIT_FILE" "$ORG_CONFIG" "-" "org-id-blanked" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "org_id blanking FAILED."
        audit_line "$AUDIT_FILE" "$ORG_CONFIG" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "config.json absent - org_id blanking skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$ORG_CONFIG" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[13/17] ~/.codeium/config.json device_id rotation (shared file)..."
CODEIUM_CONFIG="$CODEIUM_DIR/config.json"
if [[ -f "$CODEIUM_CONFIG" ]]; then
    # Windows [15] shape (device_id only) + the Linux v0.3 api_key blank;
    # the Linux portal_url/inference_url writes are deliberately DROPPED
    # (they would overwrite a live user endpoint with a stale URL).
    CODEIUM_PAYLOAD=$(python3 -c 'import base64, json, sys; print(base64.b64encode(json.dumps({"device_id": sys.argv[1], "api_key": ""}).encode()).decode())' "$DEV_DEVICE_ID" | tr -d '\r')
    if python3 "$GHOST_CLI_PATH" json-patch "$CODEIUM_CONFIG" "$CODEIUM_PAYLOAD" \
       && verify_json_keys "$CODEIUM_CONFIG" "device_id=$DEV_DEVICE_ID" "api_key="; then
        ok "codeium device_id rotated + api_key blanked + verified."
        audit_line "$AUDIT_FILE" "$CODEIUM_CONFIG" "-" "device-id-rotated" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "codeium config.json rotation FAILED."
        audit_line "$AUDIT_FILE" "$CODEIUM_CONFIG" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "codeium config.json absent - device_id rotation skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$CODEIUM_CONFIG" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[14/17] argv.json crash-reporter-id (~/.windsurf + ~/.devin)..."
ARGV_FAILED=0
for argv_path in "$WINDSURF_DIR/argv.json" "$HOME/.devin/argv.json"; do
    if [[ -f "$argv_path" ]]; then
        if [[ -n "$SCRUB_USER" ]]; then
            ARGV_PAYLOAD=$(python3 -c 'import base64, json, sys; print(base64.b64encode(json.dumps({"new_id": sys.argv[1], "username": sys.argv[2]}).encode()).decode())' "$NEW_CRASH_ID" "$SCRUB_USER" | tr -d '\r')
        else
            ARGV_PAYLOAD=$(printf '{"new_id":"%s"}' "$NEW_CRASH_ID" | b64_json_stdin)
        fi
        if python3 "$GHOST_CLI_PATH" patch-argv "$argv_path" "$BACKUP_ROOT" "argv-json" "$ARGV_PAYLOAD"; then
            ok "argv.json crash-reporter id patched + username scrubbed: $argv_path"
            audit_line "$AUDIT_FILE" "$argv_path" "-" "$NEW_CRASH_ID" 1
        else
            err "patch-argv FAILED: $argv_path"
            audit_line "$AUDIT_FILE" "$argv_path" "-" "failed" 0
            ARGV_FAILED=1
        fi
    else
        warn "argv.json absent - crash-reporter id skipped: $argv_path"
        audit_line "$AUDIT_FILE" "$argv_path" "missing" "skipped" 1
    fi
done
if [[ "$ARGV_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[15/17] ~/.windsurf/installation_id rotation..."
if rotate_file_value "$WINDSURF_DIR/installation_id" "home-installation-id" "$NEW_HOME_INSTALL_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[16/17] updater-cache trees (DERIVED probes) + never-touch audit..."
UPD_FAILED=0
for tree in "$HOME/Library/Application Support/Devin-updater" \
            "$HOME/Library/Application Support/Windsurf-updater" \
            "$HOME/Library/Caches/Devin-updater" \
            "$HOME/Library/Caches/Windsurf-updater"; do
    if sweep_tree_audit "$tree"; then
        :
    else
        UPD_FAILED=1
    fi
done
if [[ "$UPD_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
# The never-touch block is the macOS port of the Windows contract plus the
# no-probe rationale for the rebrand sibling (see the header): a
# Devin-named Application Support dir CANNOT be told apart from the devin
# CLI home on a case-insensitive volume, so both are left untouched.
info "Never touched (policy): the Devin-named Application Support sibling"
info "(no-probe rationale), the devin CLI home, ~/.devin-shared, install"
info "dirs, WebStorage + IndexedDB."
audit_line "$AUDIT_FILE" "$HOME/Library/Application Support/Devin" "-" "not-probed-sibling" 1
audit_line "$AUDIT_FILE" "$HOME/Library/Application Support/devin" "-" "preserved-cli-home" 1
audit_line "$AUDIT_FILE" "$HOME/.devin-shared" "-" "preserved" 1

info ""
info "[17/17] Final probe (read-only) + preservation audit + system-identity skip..."
PROBE_FAILED=0
if [[ -f "$STORAGE_JSON" ]]; then
    if verify_json_keys "$STORAGE_JSON" \
            "telemetry.devDeviceId=$DEV_DEVICE_ID" \
            "telemetry.machineId=$MACHINE_ID" \
            "telemetry.macMachineId=$MAC_MACHINE_ID" \
            "telemetry.sqmId=$SQM_ID" \
            "storage.serviceMachineId=$DEV_DEVICE_ID"; then
        ok "storage.json re-verified."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "re-verified" 1
    else
        err "storage.json final verify FAILED."
        audit_line "$AUDIT_FILE" "$STORAGE_JSON" "-" "verify-failed" 0
        PROBE_FAILED=1
    fi
fi
if [[ -f "$STATE_VSCDB" ]]; then
    if verify_sqlite_kv "$STATE_VSCDB" "storage.serviceMachineId" "$DEV_DEVICE_ID"; then
        ok "state.vscdb serviceMachineId re-verified."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "re-verified" 1
    else
        err "state.vscdb final verify FAILED."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "verify-failed" 0
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
# Preservation audit: the chat/UI stores this resetter deliberately keeps.
info "Preserved (chat policy - never touched): Local Storage, Backups,"
info "workspaceStorage files, WebStorage + IndexedDB, ~/.devin-shared."
audit_line "$AUDIT_FILE" "Local Storage" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "Backups" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "User/workspaceStorage files" "-" "preserved" 1
audit_line "$AUDIT_FILE" "WebStorage + IndexedDB" "-" "out-of-scope" 1
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
    err "Devin/Windsurf reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "Devin/Windsurf reset completed successfully."
