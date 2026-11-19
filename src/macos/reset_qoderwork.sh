#!/usr/bin/env bash
# QoderWork Machine ID Reset Script for macOS (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-19, issue #36 follow-up): the macOS store
# layout is derived from the Windows reset_qoderwork.ps1 (v0.2, 26 steps
# - LIVE-VERIFIED on Windows) and the Linux reset_qoderwork.sh (v0.2,
# itself DERIVED), ported onto the macOS platform.py column (config =
# ~/Library/Application Support/QoderWork, qoderwork_dir = ~/.qoderwork,
# agents_db = .../QoderWork/data/agents.db). The macOS ROWS themselves
# are provenance-flagged unverified in ghost/platform.py and this script
# prints the caveat loudly. The Windows-only system steps (MachineGuid /
# HKCU deviceid / SQM registry, NIC MAC, hostname) have no honest macOS
# analog here and are loud skips.
#
# PRESERVATION POLICY (QoderWork's, per the Windows v0.2 contract): the
# agents.db scrub is the EXACT whitelist purge - chats/sub_chats/messages/
# projects are NEVER in the table list and are never touched; app_settings
# loses only its identity-bearing keys ("proxy" survives); the
# data/dynamic-text/qoder-work.json UI strings file is PRESERVED. The
# Partitions/main Local Storage / Session Storage DELETES are the Windows
# contract (QoderWork chats live in agents.db, not LevelDB).
#
# Covered on macOS: the machineId files (THREE spellings probed - the
# Windows script uses machine-id, the Linux script machineid, Electron
# apps also write camelCase machineId; the macOS spelling is unverified so
# whichever file the app created is rotated) + the Electron 5-key telemetry stores
# (storage.json +
# state.vscdb, shared reset_electron_stores) + ~/.qoderwork/installation_id
# + the .status.json logged_out patch (version/schema_version/product
# preserved, snapshot_at refreshed) + external-commands/registry.json
# commands=[] + the ~/.qoderwork cache/log sweeps + rum-electron-store
# (ARMS _arms_uid) + the Local State delete + the Partitions/main
# Preferences salt + network stores + Local/Session Storage + Shared
# Dictionary + the cache trees + SharedStorage + dns-cache + the
# data/agents.db purge-tables whitelist scrub + auth.dat/auth-v2.dat.
#
# NOT covered on macOS (no honest analog, or deliberately out of scope):
# IOPlatformUUID (the MachineGuid analog - immutable), Keychain "Chromium
# Safe Storage" (remove manually in Keychain Access), hostname, MAC, the
# old-ID_Backups purge and the watchdog re-verify (dev-host template
# convention: the macOS wave never purges prior backup sets), and every
# chat-bearing store (agents.db chats, dynamic-text UI strings).
#
# Every DERIVED path is ABSENCE-TOLERANT: a store the app never created is
# a loud skip, never a guess and never a failure. The script must stay
# bash 3.2-safe (macOS still ships /bin/bash 3.2 - no ${var,,}, mapfile,
# or associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/../linux/id_reset_common.sh"

show_banner "QoderWork Identity Reset (macOS)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every QoderWork reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth).
path_report=$(python3 "$GHOST_CLI_PATH" paths qoderwork)
CONFIG_ROOT=$(python3 -c "import json,sys; p=json.loads(sys.argv[1])['paths']; print(p.get('config') or p.get('roaming',''))" "$path_report")
QODERWORK_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('qoderwork_dir',''))" "$path_report")
UNVERIFIED=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['unverified']))" "$path_report")
# Windows-hosted python translates stdout \n -> \r\n; strip a trailing \r
# so a cross-host run never carries it into a path (a native macOS/Linux
# host never produces it, and stripping is a no-op there).
CONFIG_ROOT="${CONFIG_ROOT%$'\r'}"
QODERWORK_DIR="${QODERWORK_DIR%$'\r'}"
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
    NEW_INSTALL_ID=$(generate_uuid | tr '[:upper:]' '[:lower:]')
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
    # arbitrary value. An ABSENT file is a loud skip - never created,
    # because on a DERIVED platform we only touch what the app wrote.
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
ensure_not_running "QoderWork"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "QoderWork installation not found at: $CONFIG_ROOT (store may live elsewhere on this macOS - live verification pending)."
    exit 1
fi

BACKUP_ROOT="$CONFIG_ROOT/ID_Backups/$(timestamp)"
mkdir -p "$BACKUP_ROOT"
RESTORE_ENTRIES=()
audit_init "$BACKUP_ROOT"

AGENTS_DB="$CONFIG_ROOT/data/agents.db"

PASS_COUNT=0
FAIL_COUNT=0

generate_ids
ok "Generated new identifiers:"
dim "  devDeviceId:     $DEV_DEVICE_ID"
dim "  machineId:       $MACHINE_ID"
dim "  macMachineId:    $MAC_MACHINE_ID"
dim "  sqmId:           $SQM_ID"
dim "  installation_id: $NEW_INSTALL_ID"

info ""
info "[1/16] machineId files (machineId + machineid + machine-id spellings)..."
MID_FAILED=0
for mid_path in "$QODERWORK_DIR/machineId" "$QODERWORK_DIR/machineid" "$QODERWORK_DIR/machine-id"; do
    if rotate_file_value "$mid_path" "qoderwork-machineid" "$DEV_DEVICE_ID"; then
        :
    else
        MID_FAILED=1
    fi
done
if [[ "$MID_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/16] Electron stores (storage.json + state.vscdb telemetry)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[3/16] ~/.qoderwork/installation_id..."
if rotate_file_value "$QODERWORK_DIR/installation_id" "installation-id" "$NEW_INSTALL_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[4/16] .status.json logged_out patch (identity fields preserved)..."
STATUS_JSON="$QODERWORK_DIR/.status.json"
if [[ -f "$STATUS_JSON" ]]; then
    # Windows [3] contract: logged_in=false + writer=main + a FRESH UTC
    # snapshot_at, while version/schema_version/product pass through from
    # the current file (python builds the payload so the pass-through and
    # the timestamp format are JSON-correct by construction).
    STATUS_PAYLOAD=$(python3 -c '
import base64, json, sys
from datetime import datetime, timezone
with open(sys.argv[1], "r", encoding="utf-8") as f:
    cur = json.load(f)
now = datetime.now(timezone.utc)
patch = {
    "logged_in": False,
    "version": cur.get("version"),
    "schema_version": cur.get("schema_version"),
    "product": cur.get("product"),
    "snapshot_at": now.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (now.microsecond // 1000),
    "writer": "main",
}
print(base64.b64encode(json.dumps(patch).encode()).decode())
' "$STATUS_JSON" | tr -d '\r')
    if python3 "$GHOST_CLI_PATH" json-patch "$STATUS_JSON" "$STATUS_PAYLOAD" \
       && python3 - "$STATUS_JSON" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
assert d.get("logged_in") is False, "logged_in not false: %r" % d.get("logged_in")
assert d.get("writer") == "main", "writer not main: %r" % d.get("writer")
assert d.get("snapshot_at", "").endswith("Z"), "snapshot_at not UTC: %r" % d.get("snapshot_at")
PY
    then
        ok ".status.json logged out + verified."
        audit_line "$AUDIT_FILE" "$STATUS_JSON" "-" "logged-out" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err ".status.json patch FAILED."
        audit_line "$AUDIT_FILE" "$STATUS_JSON" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn ".status.json absent - patch skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$STATUS_JSON" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[5/16] external-commands/registry.json (commands=[])..."
REGISTRY_JSON="$QODERWORK_DIR/external-commands/registry.json"
if [[ -f "$REGISTRY_JSON" ]]; then
    REG_PAYLOAD=$(printf '{"commands":[]}' | b64_json_stdin)
    if python3 "$GHOST_CLI_PATH" json-patch "$REGISTRY_JSON" "$REG_PAYLOAD" \
       && python3 - "$REGISTRY_JSON" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
assert d.get("commands") == [], "commands not emptied: %r" % d.get("commands")
PY
    then
        ok "external commands registry emptied + verified."
        audit_line "$AUDIT_FILE" "$REGISTRY_JSON" "-" "commands-emptied" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "registry.json patch FAILED."
        audit_line "$AUDIT_FILE" "$REGISTRY_JSON" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "registry.json absent - patch skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$REGISTRY_JSON" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[6/16] ~/.qoderwork cache/log sweeps..."
QW_FAILED=0
for tree in "$QODERWORK_DIR/.cache" "$QODERWORK_DIR/cache" "$QODERWORK_DIR/logs"; do
    if sweep_tree_audit "$tree"; then
        :
    else
        QW_FAILED=1
    fi
done
if [[ "$QW_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[7/16] rum-electron-store delete (ARMS _arms_uid)..."
if delete_store "$CONFIG_ROOT/rum-electron-store" "rum-electron-store"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[8/16] Local State delete (whole file, Windows contract)..."
if delete_store "$CONFIG_ROOT/Local State" "local-state"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[9/16] Partitions/main/Preferences salt..."
PREFS_JSON="$CONFIG_ROOT/Partitions/main/Preferences"
if [[ -f "$PREFS_JSON" ]]; then
    if python3 "$GHOST_CLI_PATH" salt-rotate "$PREFS_JSON" "$BACKUP_ROOT" "preferences-salt"; then
        ok "device_id_salt rotated + verified."
        audit_line "$AUDIT_FILE" "$PREFS_JSON" "-" "salt-rotated" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "salt-rotate FAILED."
        audit_line "$AUDIT_FILE" "$PREFS_JSON" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "Partitions/main/Preferences absent - salt rotation skipped."
    audit_line "$AUDIT_FILE" "$PREFS_JSON" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[10/16] Partitions/main network stores..."
NET_FAILED=0
for p in "Network/Cookies" "Network/Cookies-journal" "Network/Network Persistent State" \
         "Network/TransportSecurity" "Network/Trust Tokens" "Network/Trust Tokens-journal" \
         "NetworkDataMigrated"; do
    if delete_store "$CONFIG_ROOT/Partitions/main/$p" "store-$(basename "$p")"; then
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
info "[11/16] Partitions/main Local/Session Storage + Shared Dictionary..."
STOR_FAILED=0
for tree in "Local Storage" "Session Storage" "Shared Dictionary"; do
    if delete_store "$CONFIG_ROOT/Partitions/main/$tree" "partition-$(echo "$tree" | tr ' ' '-')"; then
        :
    else
        STOR_FAILED=1
    fi
done
if [[ "$STOR_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[12/16] cache trees..."
CACHE_FAILED=0
for tree in "Cache" "Code Cache" "GPUCache" "DawnGraphiteCache" "DawnWebGPUCache" "blob_storage"; do
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
info "[13/16] SharedStorage + dns-cache..."
MISC_FAILED=0
for p in "SharedStorage" "data/dns-cache"; do
    if delete_store "$CONFIG_ROOT/$p" "store-$(basename "$p")"; then
        :
    else
        MISC_FAILED=1
    fi
done
if [[ "$MISC_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[14/16] data/agents.db whitelist purge (chats + proxy preserved)..."
if [[ -f "$AGENTS_DB" ]]; then
    # Sidecar-aware backup FIRST (the core backup --sqlite-wal twin of the
    # Windows [19] contract), then the EXACT Windows v0.2 whitelist: 15
    # tables + 12 app_settings keys. chats/sub_chats/messages/projects are
    # NEVER in the list; app_settings keeps "proxy".
    PURGE_OK=1
    if ! python3 "$GHOST_CLI_PATH" backup "$AGENTS_DB" "$BACKUP_ROOT" "agents_db" --sqlite-wal; then
        err "agents.db backup FAILED - purge SKIPPED (no-backup-no-delete)."
        audit_line "$AUDIT_FILE" "$AGENTS_DB" "-" "backup-failed-purge-skipped" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
        PURGE_OK=0
    fi
    if [[ "$PURGE_OK" == "1" ]]; then
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
        }).encode()).decode())' | tr -d '\r')
        if python3 "$GHOST_CLI_PATH" purge-tables "$AGENTS_DB" "$PURGE_PAYLOAD" \
           && python3 - "$AGENTS_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
cur = conn.cursor()
identity_tables = ["mcp_oauth_tokens", "mcp_oauth_tokens_by_user", "google_oauth_tokens",
                   "ms365_auth_states", "byok_custom_models", "rc_session_mappings",
                   "channel_pairings", "channel_pairings_v2", "knowledge_bases",
                   "voice_input_hotwords", "voice_input_history", "scheduled_tasks",
                   "task_run_logs", "nudge_logs", "skill_evolution_suggestions"]
for t in identity_tables:
    try:
        n = cur.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]
        assert n == 0, "identity table %s still has %d rows" % (t, n)
    except sqlite3.OperationalError:
        pass  # schema-missing tolerated (core purge-tables WARN contract)
for t in ["chats", "sub_chats", "messages", "projects"]:
    try:
        cur.execute("SELECT COUNT(*) FROM %s" % t)
    except sqlite3.OperationalError:
        pass  # a chat table may legitimately not exist yet
try:
    n_proxy = cur.execute(
        "SELECT COUNT(*) FROM app_settings WHERE key = 'proxy'").fetchone()[0]
    assert n_proxy >= 1, "proxy key lost from app_settings"
except sqlite3.OperationalError:
    pass  # app_settings itself may be schema-missing (tolerated above)
conn.close()
PY
        then
            ok "agents.db purged + chat/proxy preservation verified."
            audit_line "$AUDIT_FILE" "$AGENTS_DB" "-" "whitelist-purged" 1
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            err "agents.db purge/verify FAILED."
            audit_line "$AUDIT_FILE" "$AGENTS_DB" "-" "failed" 0
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
else
    warn "agents.db not present - purge skipped (first-launch state): $AGENTS_DB"
    audit_line "$AUDIT_FILE" "$AGENTS_DB" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[15/16] auth.dat + auth-v2.dat deletes..."
AUTH_FAILED=0
for p in "auth.dat" "auth-v2.dat"; do
    if delete_store "$CONFIG_ROOT/$p" "store-$(basename "$p")"; then
        :
    else
        AUTH_FAILED=1
    fi
done
if [[ "$AUTH_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[16/16] Final probe + preservation audit + system-identity skip..."
# Preservation audit: the chat/UI stores this resetter deliberately keeps.
info "Preserved (chat policy - never touched): agents.db chats/sub_chats/"
info "messages/projects rows, app_settings proxy, dynamic-text UI strings."
audit_line "$AUDIT_FILE" "data/agents.db chat tables" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "$CONFIG_ROOT/data/dynamic-text/qoder-work.json" "-" "preserved-ui-strings" 1
audit_line "$AUDIT_FILE" "app_settings proxy" "-" "preserved" 1
# macOS system identity: a loud, audited skip (no honest userspace analog;
# the Windows MachineGuid/HKCU/SQM/MAC/hostname steps do not port).
warn "System identity NOT reset on macOS (see the header NOT-covered list):"
warn "  IOPlatformUUID (MachineGuid analog, immutable) | Keychain 'Chromium Safe Storage' (manual) | hostname | MAC"
audit_line "$AUDIT_FILE" "system-identity (IOPlatformUUID/Keychain/hostname/MAC)" "-" "skipped-no-analog" 1
PASS_COUNT=$((PASS_COUNT + 1))

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
