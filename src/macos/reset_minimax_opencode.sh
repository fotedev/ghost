#!/usr/bin/env bash
# MiniMax/OpenCode Machine ID Reset Script for macOS (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-19, issue #36 follow-up): the macOS store
# layout is derived from the Windows reset_minimax_opencode.ps1 (v1.4,
# 22 steps - LIVE-VERIFIED on Windows) and the Linux
# reset_minimax_opencode.sh (v0.2, itself DERIVED), ported onto the macOS
# platform.py column (config = ~/Library/Application Support/MiniMax,
# minimax_dir = ~/.minimax, mcode_public =
# .../MiniMax/auth/prod/en/mcode-public, session_handoff_device_id =
# ~/.minimax/v2/session-handoff/device-id). The macOS ROWS themselves are
# provenance-flagged unverified in ghost/platform.py and this script
# prints the caveat loudly.
#
# SCOPE = MiniMax-only (the Linux v0.2 decision): the OpenCode-desktop
# Electron steps (Windows [1]-[8]: ai.opencode.desktop auth.json, updater
# ids, network sweeps, window-state rotation) do NOT port - the macOS
# column has no ai.opencode.desktop rows and the "opencode" slug alias
# resolves to opencode-cli, whose stores are the XDG CLI defaults. The
# OpenCode CLI auth (~/.local/share/opencode/auth.json + ~/.config/
# opencode) belongs to the opencode-cli login and is NEVER touched here
# (loudly audited as preserved).
#
# PRESERVATION POLICY (MiniMax's, per the Windows v1.4 contract): the
# session history lives in sessions/ + sqlite.db (+wal/shm) and is NEVER
# touched; credentials/mavis/telegram.json, the .mavis junction, and
# system-ca-certs.pem are preserved. Partitions/mavis-browser sweeps its
# Local Storage ONLY (the partition itself stays).
#
# Covered on macOS: the ~/.minimax machineId files (THREE spellings
# probed - Linux machineid, Electron camelCase machineId, Windows hyphen
# machine-id; the macOS spelling is unverified so whichever exists
# rotates) + the Electron telemetry stores + the mcode-public auth
# deletions (auth.json + auth-state.json + the legacy root auth-state -
# "{}" there throws Invalid OAuth state and blocks the login page, so
# absent IS the fresh-install state) + the v2/session-handoff device-id
# rotation + local-runtime.auth.json wiped to {} + minimax-agent-config
# user/sharedUser removal (config kept) + remote-control desktop_device_id
# rotation + .updaterId + the MiniMax Chromium sweeps (network files +
# DIPS*/SharedStorage* + cache/web-storage trees + Crashpad + the Local
# State os_crypt pointer + uninstall_metrics + Preferences salt) + the
# mavis-browser Local Storage + the misc run-state trees/files.
#
# NOT covered on macOS (no honest analog, or deliberately out of scope):
# IOPlatformUUID (immutable), Keychain "Chromium Safe Storage" (remove
# manually in Keychain Access), hostname, MAC, the OpenCode-desktop steps
# (see SCOPE), the old-ID_Backups purge and watchdog re-verify (dev-host
# template convention), and the updater-id / window-state OpenCode steps.
#
# Every DERIVED path is ABSENCE-TOLERANT: a store the app never created is
# a loud skip, never a guess and never a failure. The script must stay
# bash 3.2-safe (macOS still ships /bin/bash 3.2 - no ${var,,}, mapfile,
# or associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/../linux/id_reset_common.sh"

show_banner "MiniMax/OpenCode Identity Reset (macOS)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every MiniMax/OpenCode reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth).
path_report=$(python3 "$GHOST_CLI_PATH" paths minimax)
CONFIG_ROOT=$(python3 -c "import json,sys; p=json.loads(sys.argv[1])['paths']; print(p.get('config') or p.get('roaming',''))" "$path_report")
MINIMAX_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('minimax_dir',''))" "$path_report")
MCODE_PUBLIC=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('mcode_public',''))" "$path_report")
SESSION_HANDOFF=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('session_handoff_device_id',''))" "$path_report")
UNVERIFIED=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['unverified']))" "$path_report")
# Windows-hosted python translates stdout \n -> \r\n; strip a trailing \r
# so a cross-host run never carries it into a path (a native macOS/Linux
# host never produces it, and stripping is a no-op there).
CONFIG_ROOT="${CONFIG_ROOT%$'\r'}"
MINIMAX_DIR="${MINIMAX_DIR%$'\r'}"
MCODE_PUBLIC="${MCODE_PUBLIC%$'\r'}"
SESSION_HANDOFF="${SESSION_HANDOFF%$'\r'}"
UNVERIFIED="${UNVERIFIED%$'\r'}"
if [[ -n "$UNVERIFIED" ]]; then
    warn "PROVENANCE: the following paths are DERIVED (Windows layout + macOS"
    warn "Electron conventions), NOT yet live-verified: $UNVERIFIED"
    warn "A store that moved is skipped loudly below - nothing is guessed."
fi
# The mcode_public / session_handoff_device_id rows exist ONLY in the
# linux/macos platform columns (the Windows script carries them inline).
# When the resolved map lacks them, derive from the mapped roots with the
# SAME relative structure those rows encode - loudly, never silently.
if [[ -z "$MCODE_PUBLIC" && -n "$CONFIG_ROOT" ]]; then
    MCODE_PUBLIC="$CONFIG_ROOT/auth/prod/en/mcode-public"
    warn "PROVENANCE: mcode_public row unmapped on this host - derived from the config root: $MCODE_PUBLIC"
fi
if [[ -z "$SESSION_HANDOFF" && -n "$MINIMAX_DIR" ]]; then
    SESSION_HANDOFF="$MINIMAX_DIR/v2/session-handoff/device-id"
    warn "PROVENANCE: session_handoff_device_id row unmapped on this host - derived from the minimax_dir root: $SESSION_HANDOFF"
fi

generate_ids() {
    DEV_DEVICE_ID=$(generate_uuid)
    MACHINE_ID=$(generate_hex 32)
    MAC_MACHINE_ID=$(generate_hex 64)
    SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    NEW_UPDATER_ID=$(generate_uuid | tr '[:upper:]' '[:lower:]')
    NEW_DESKTOP_DEVICE_ID=$(generate_uuid | tr '[:upper:]' '[:lower:]')
}

# ── macOS-side store helpers (built on the shared lib + core verbs) ─────

delete_store() {
    # delete_store <path> <label> - core store-delete (backup/rename into
    # the ID_Backups root, then remove). An absent path is a loud skip.
    # Returns 0 ok/skip, 1 failed - the caller counts.
    local path="$1" label="$2"
    if [[ ! -e "$path" ]]; then
        warn "not present - skipped (fresh-install parity): $path"
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
ensure_not_running "minimax"

if [[ ! -d "$CONFIG_ROOT" && ! -d "$MINIMAX_DIR" ]]; then
    err "MiniMax installation not found (config: $CONFIG_ROOT, home: $MINIMAX_DIR) - store may live elsewhere on this macOS, live verification pending."
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
dim "  devDeviceId:         $DEV_DEVICE_ID"
dim "  machineId:           $MACHINE_ID"
dim "  macMachineId:        $MAC_MACHINE_ID"
dim "  sqmId:               $SQM_ID"
dim "  updaterId:           $NEW_UPDATER_ID"
dim "  desktop_device_id:   $NEW_DESKTOP_DEVICE_ID"

info ""
info "[1/13] ~/.minimax machineId files (machineid + machineId + machine-id spellings)..."
MID_FAILED=0
for mid_path in "$MINIMAX_DIR/machineid" "$MINIMAX_DIR/machineId" "$MINIMAX_DIR/machine-id"; do
    if rotate_file_value "$mid_path" "minimax-machineid" "$DEV_DEVICE_ID"; then
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
info "[2/13] Electron stores (storage.json + state.vscdb telemetry)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[3/13] mcode-public auth deletions (absent = fresh-install parity)..."
AUTH_FAILED=0
for auth_file in "$MCODE_PUBLIC/auth.json" "$MCODE_PUBLIC/auth-state.json" \
                 "$MINIMAX_DIR/auth/auth-state.json"; do
    if delete_store "$auth_file" "auth-state"; then
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
info "[4/13] v2/session-handoff device-id rotation..."
if rotate_text_file "$SESSION_HANDOFF" "session-handoff-device-id" "$DEV_DEVICE_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[5/13] local-runtime.auth.json wiped to {}..."
LOCAL_RUNTIME="$MINIMAX_DIR/local-runtime.auth.json"
if [[ -f "$LOCAL_RUNTIME" ]]; then
    # Windows [11] contract: "{}" is PROVEN SAFE for this store (separate
    # from the mcode-public files whose "{}" breaks OAuth) - the wipe uses
    # the json-remove empty-prefix form that collapses the file to {}.
    if python3 "$GHOST_CLI_PATH" json-remove "$LOCAL_RUNTIME" "$BACKUP_ROOT" "local-runtime-wipe" "$(printf '{"keys":[],"prefixes":[""]}' | b64_json_stdin)" \
       && python3 - "$LOCAL_RUNTIME" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
assert d == {}, "local-runtime.auth.json not empty: %r" % d
PY
    then
        ok "local-runtime.auth.json emptied + verified."
        audit_line "$AUDIT_FILE" "$LOCAL_RUNTIME" "-" "wiped-to-empty" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "local-runtime wipe FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_RUNTIME" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "local-runtime.auth.json absent - wipe skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$LOCAL_RUNTIME" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[6/13] minimax-agent-config.json user/sharedUser removal..."
AGENT_CONFIG="$CONFIG_ROOT/minimax-agent-config.json"
if [[ -f "$AGENT_CONFIG" ]]; then
    # Windows [12] contract: remove the user + sharedUser nodes only; the
    # config node MUST survive (json-remove reports absent keys as skips).
    if core_json_remove "$AGENT_CONFIG" "agent-config-user" '["user","sharedUser"]' '[]' \
       && python3 - "$AGENT_CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
assert "user" not in d, "user node survived"
assert "sharedUser" not in d, "sharedUser node survived"
assert "config" in d, "config node LOST (must-keep violated)"
PY
    then
        ok "agent-config user/sharedUser removed + config kept."
        audit_line "$AUDIT_FILE" "$AGENT_CONFIG" "-" "user-nodes-removed" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "agent-config node removal FAILED."
        audit_line "$AUDIT_FILE" "$AGENT_CONFIG" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "minimax-agent-config.json absent - removal skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$AGENT_CONFIG" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[7/13] remote-control/state.json desktop_device_id..."
RC_STATE="$CONFIG_ROOT/remote-control/state.json"
if [[ -f "$RC_STATE" ]]; then
    RC_PAYLOAD=$(printf '{"desktop_device_id":"%s"}' "$NEW_DESKTOP_DEVICE_ID" | b64_json_stdin)
    if python3 "$GHOST_CLI_PATH" json-patch "$RC_STATE" "$RC_PAYLOAD" \
       && verify_json_keys "$RC_STATE" "desktop_device_id=$NEW_DESKTOP_DEVICE_ID"; then
        ok "desktop_device_id rotated + verified."
        audit_line "$AUDIT_FILE" "$RC_STATE" "-" "$NEW_DESKTOP_DEVICE_ID" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "desktop_device_id rotation FAILED."
        audit_line "$AUDIT_FILE" "$RC_STATE" "-" "failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "remote-control/state.json absent - rotation skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$RC_STATE" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[8/13] config-root .updaterId..."
if rotate_file_value "$CONFIG_ROOT/.updaterId" "updater-id" "$NEW_UPDATER_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[9/13] MiniMax Chromium network + tracking sweeps..."
NET_FAILED=0
for p in "Network/Cookies" "Network/Cookies-journal" "DIPS" "DIPS-wal" "DIPS-journal" \
         "DIPS-shm" "SharedStorage" "SharedStorage-wal" "SharedStorage-shm" \
         "SharedStorage-journal" "Network/Trust Tokens" "Network/Trust Tokens-journal" \
         "Network/Network Persistent State" "Network/TransportSecurity" \
         "NetworkDataMigrated"; do
    if delete_store "$CONFIG_ROOT/$p" "store-$(basename "$p")"; then
        :
    else
        NET_FAILED=1
    fi
done
# Prefix stragglers (the Windows DIPS*/SharedStorage* sweep), loud + audited.
shopt -s nullglob
for straggler in "$CONFIG_ROOT"/DIPS* "$CONFIG_ROOT"/SharedStorage*; do
    if [[ -e "$straggler" ]]; then
        if delete_store "$straggler" "store-straggler"; then
            :
        else
            NET_FAILED=1
        fi
    fi
done
shopt -u nullglob
if [[ "$NET_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[10/13] web-storage trees + caches + Crashpad..."
TREE_FAILED=0
for tree in "Local Storage" "IndexedDB" "Session Storage" "WebStorage" \
            "Shared Dictionary" "VideoDecodeStats" "blob_storage" "browser-cache" \
            "Cache/Cache_Data" "Code Cache" "GPUCache" "DawnGraphiteCache" \
            "DawnWebGPUCache" "Crashpad" "logs" \
            "Partitions/mavis-browser/Local Storage"; do
    if sweep_tree_audit "$CONFIG_ROOT/$tree"; then
        :
    else
        TREE_FAILED=1
    fi
done
if [[ "$TREE_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[11/13] Local State os_crypt + uninstall_metrics + Preferences salt..."
CH_FAILED=0
LOCAL_STATE="$CONFIG_ROOT/Local State"
OS_PAYLOAD=$(printf '{"keys":["os_crypt.encrypted_key"],"prefixes":[]}' | b64_json_stdin)
if [[ -f "$LOCAL_STATE" ]]; then
    if python3 "$GHOST_CLI_PATH" json-remove "$LOCAL_STATE" "$BACKUP_ROOT" "local-state-os-crypt" "$OS_PAYLOAD"; then
        ok "os_crypt.encrypted_key removed + verified."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "os-crypt-cleared" 1
    else
        err "os_crypt json-remove FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "failed" 0
        CH_FAILED=1
    fi
    if python3 "$GHOST_CLI_PATH" json-remove "$LOCAL_STATE" "$BACKUP_ROOT" "local-state-uninstall-metrics" "$(printf '{"keys":["uninstall_metrics"],"prefixes":[]}' | b64_json_stdin)"; then
        ok "uninstall_metrics removed + verified."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "uninstall-metrics-cleared" 1
    else
        err "uninstall_metrics json-remove FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE" "-" "failed" 0
        CH_FAILED=1
    fi
else
    warn "Local State absent - os_crypt + uninstall_metrics skipped."
    audit_line "$AUDIT_FILE" "$LOCAL_STATE" "missing" "skipped" 1
fi
warn "Keychain 'Chromium Safe Storage' NOT touched - remove it manually in"
warn "Keychain Access (the Local State pointer above IS removed)."
audit_line "$AUDIT_FILE" "Keychain Chromium Safe Storage" "-" "skipped-manual" 1
PREF_JSON="$CONFIG_ROOT/Preferences"
if [[ -f "$PREF_JSON" ]]; then
    if python3 "$GHOST_CLI_PATH" salt-rotate "$PREF_JSON" "$BACKUP_ROOT" "preferences-salt"; then
        ok "device_id_salt rotated + verified."
        audit_line "$AUDIT_FILE" "$PREF_JSON" "-" "salt-rotated" 1
    else
        err "salt-rotate FAILED."
        audit_line "$AUDIT_FILE" "$PREF_JSON" "-" "failed" 0
        CH_FAILED=1
    fi
else
    warn "Preferences absent - salt rotation skipped."
    audit_line "$AUDIT_FILE" "$PREF_JSON" "missing" "skipped" 1
fi
if [[ "$CH_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[12/13] misc run-state + preservation audit + system-identity skip..."
MISC_FAILED=0
for p in "shared_proto_db" "hot-update" "observability-outbox.jsonl" \
         "embedded-browser-tabs.json" "crash-evidence-session.json"; do
    if delete_store "$CONFIG_ROOT/$p" "misc-$(basename "$p")"; then
        :
    else
        MISC_FAILED=1
    fi
done
for tree in "$MINIMAX_DIR/tmp" "$MINIMAX_DIR/run" "$MINIMAX_DIR/logs"; do
    if sweep_tree_audit "$tree"; then
        :
    else
        MISC_FAILED=1
    fi
done
for lock in "$MINIMAX_DIR/daemon.lock" "$MINIMAX_DIR/auth/auth.lock" \
            "$MCODE_PUBLIC/auth.lock"; do
    if delete_store "$lock" "lock-$(basename "$lock")"; then
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
# Preservation audit: the chat/credential stores this resetter keeps.
info "Preserved (chat policy - never touched): sessions/, sqlite.db(+wal/shm),"
info "credentials/mavis/telegram.json, .mavis junction, system-ca-certs.pem,"
info "and the OpenCode CLI stores (opencode-cli slug - XDG auth untouched)."
audit_line "$AUDIT_FILE" "$CONFIG_ROOT/sessions" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "$CONFIG_ROOT/sqlite.db (+wal/shm)" "-" "preserved-for-chat" 1
audit_line "$AUDIT_FILE" "$CONFIG_ROOT/credentials/mavis/telegram.json" "-" "preserved" 1
audit_line "$AUDIT_FILE" "$HOME/.mavis junction" "-" "link-only-preserved" 1
audit_line "$AUDIT_FILE" "$CONFIG_ROOT/system-ca-certs.pem" "-" "preserved" 1
audit_line "$AUDIT_FILE" "$HOME/.local/share/opencode/auth.json" "-" "preserved-opencode-cli" 1
audit_line "$AUDIT_FILE" "$HOME/.config/opencode" "-" "preserved-opencode-cli" 1
audit_line "$AUDIT_FILE" "OpenCode-desktop Electron stores (ai.opencode.desktop)" "-" "not-probed-no-map" 1
# macOS system identity: a loud, audited skip (no honest userspace analog).
warn "System identity NOT reset on macOS (see the header NOT-covered list):"
warn "  IOPlatformUUID (immutable) | Keychain 'Chromium Safe Storage' (remove manually) | hostname | MAC"
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
    err "MiniMax/OpenCode reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "MiniMax/OpenCode reset completed successfully."
