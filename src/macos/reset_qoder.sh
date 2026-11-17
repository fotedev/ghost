#!/usr/bin/env bash
# Qoder Machine ID Reset Script for macOS (GHOST v0.1)
#
# DERIVED-PATH SCOPE (2026-11-17, issue #36): the macOS store layout is
# derived from the proven Windows reset_qoder.ps1 + Electron conventions
# (~/Library/Application Support/Qoder) - rows are provenance-flagged
# unverified in ghost/platform.py and this script prints the caveat loudly.
#
# Covered on macOS (issue #36 full attempt): telemetry keys in storage.json +
# ItemTable upserts in state.vscdb (core verbs) + the state.vscdb secret
# purge (the exact Windows [3b] list) + the Preferences device_id_salt + the
# machineid files + the ~/.qoder installation_id / .auth/machine_id
# rotations + the credential-transaction sentinel + the argv.json
# crash-reporter id + the workspaceStorage serviceMachineId upserts + the
# ~/Library cache/log/plist sweep + the webview partitions + the Chromium
# network/cache stores inside the userData + the .qoder tmp/telemetry + logs
# run-state trees.
#
# NOT covered on macOS (no honest analog, or deliberately out of scope):
# Keychain "Chromium Safe Storage" (the os_crypt key - remove it manually in
# Keychain Access), IOPlatformUUID (immutable), hostname (scutil --set is a
# different mechanism), the MAC address (no persistent override), and the
# memories/canvas/knowledges/extensions stores (chat-bearing user content -
# never touched, same chat-preservation stance as the Linux wave).
#
# Every DERIVED path is ABSENCE-TOLERANT: a store the app never created is a
# loud skip, never a guess and never a failure. The script must stay bash
# 3.2-safe (macOS still ships /bin/bash 3.2 - no ${var,,}, mapfile, or
# associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/../linux/id_reset_common.sh"

show_banner "Qoder Identity Reset (macOS)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "Every Qoder reset step needs it - aborting instead of silently skipping."
    exit 1
}

# Resolve paths through the platform layer (single source of truth).
# The userData-root label differs per column ("config" on linux/macos,
# "roaming" on windows) - accept whichever the resolved map carries so the
# script still runs honestly if invoked off its home platform.
path_report=$(python3 "$GHOST_CLI_PATH" paths qoder)
CONFIG_ROOT=$(python3 -c "import json,sys; p=json.loads(sys.argv[1])['paths']; print(p.get('config') or p.get('roaming',''))" "$path_report")
QODER_DIR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['paths'].get('qoder_dir',''))" "$path_report")
UNVERIFIED=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['unverified']))" "$path_report")
# Windows-hosted python translates stdout \n -> \r\n; strip a trailing \r so
# a cross-host run never carries it into a path or an IFS-read field (a
# native macOS/Linux host never produces it, and stripping is a no-op there).
CONFIG_ROOT="${CONFIG_ROOT%$'\r'}"
QODER_DIR="${QODER_DIR%$'\r'}"
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
    # rotate_machineid_file <path> - core machineid-file (backup if present,
    # write, re-read verify). An ABSENT file is a loud skip - never created,
    # because on a DERIVED platform we only touch what the app itself wrote.
    local path="$1"
    if [[ ! -f "$path" ]]; then
        warn "not present - skipped (first-launch state): $path"
        audit_line "$AUDIT_FILE" "$path" "missing" "skipped" 1
        return 0
    fi
    local payload
    payload=$(printf '{"value":"%s"}' "$DEV_DEVICE_ID" | b64_json_stdin)
    if python3 "$GHOST_CLI_PATH" machineid-file "$path" "$BACKUP_ROOT" "machineid" "$payload"; then
        ok "machineid rotated + verified: $path"
        audit_line "$AUDIT_FILE" "$path" "-" "$DEV_DEVICE_ID" 1
        return 0
    fi
    err "machineid rotation FAILED: $path"
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

purge_and_audit() {
    # purge_and_audit <db> - core purge-keys (the exact Windows [3b] list)
    # with one audit line per key/pattern (count=X -> count=0). Returns 0
    # only when every survivor count is zero.
    local db="$1" report verdict=0
    if ! report=$(python3 "$GHOST_CLI_PATH" purge-keys "$db" "$PURGE_CONFIG_B64"); then
        err "purge-keys core invocation FAILED: $db"
        audit_line "$AUDIT_FILE" "$db" "-" "core-invoke-failed" 0
        return 1
    fi
    while IFS='|' read -r key before after; do
        # Strip a trailing \r (Windows-hosted python emits CRLF lines; the
        # LAST IFS field keeps it - a native macOS/Linux host is unaffected).
        key="${key%$'\r'}"; before="${before%$'\r'}"; after="${after%$'\r'}"
        if [[ -z "$key" ]]; then continue; fi
        if [[ "$after" == "0" ]]; then
            audit_line "$AUDIT_FILE" "$db" "count=$before" "count=$after" 1 "$key"
        else
            err "secret survivor: $key (count=$after)"
            audit_line "$AUDIT_FILE" "$db" "count=$before" "count=$after" 0 "$key"
            verdict=1
        fi
    done < <(python3 -c '
import json, sys
report = json.loads(sys.argv[1])
before = report.get("before", {})
after = report.get("after", {})
for key in sorted(set(before) | set(after)):
    print("{0}|{1}|{2}".format(key, before.get(key, 0), after.get(key, 0)))
' "$report")
    return $verdict
}

count_survivors() {
    # count_survivors <db> -> echoes the survivor count (0 expected).
    # READ-ONLY final probe twin of the Windows device-flow probe.
    local report survivors
    report=$(python3 "$GHOST_CLI_PATH" count-keys "$1" "$PURGE_CONFIG_B64")
    survivors=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['survivors'])" "$report")
    printf '%s\n' "${survivors%$'\r'}"
}

# ── main ────────────────────────────────────────────────────────────────
ensure_not_running "qoder"

if [[ ! -d "$CONFIG_ROOT" ]]; then
    err "Qoder installation not found at: $CONFIG_ROOT (store may live elsewhere on this macOS - live verification pending)."
    exit 1
fi

BACKUP_ROOT="$CONFIG_ROOT/ID_Backups/$(timestamp)"
mkdir -p "$BACKUP_ROOT"
RESTORE_ENTRIES=()
audit_init "$BACKUP_ROOT"

# The exact Windows Clear-QoderSecrets list (reset_qoder.ps1 [3b/31]).
PURGE_CONFIG='{"exact_keys":["secret://aicoding.auth.userInfo","secret://aicoding.auth.userPlan","secret://aicoding.auth.creditUsage","aicoding.auth.loginBroadcast","gituser"],"like_patterns":["secret://blackbox.%","secret://aicoding.auth.%","%secret.local.machine.variables%"],"table":"ItemTable"}'
PURGE_CONFIG_B64=$(printf '%s' "$PURGE_CONFIG" | b64_json_stdin)

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
WS_UPDATES_B64=$(printf '{"storage.serviceMachineId":"%s"}' "$DEV_DEVICE_ID" | b64_json_stdin)

info ""
info "[1/9] Electron stores (storage.json + state.vscdb)..."
if reset_electron_stores "$CONFIG_ROOT" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/9] state.vscdb secret purge (exact Windows [3b] list)..."
STATE_VSCDB="$CONFIG_ROOT/User/globalStorage/state.vscdb"
if [[ -f "$STATE_VSCDB" ]]; then
    if purge_and_audit "$STATE_VSCDB"; then
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
info "[3/9] Preferences device_id_salt..."
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
info "[4/9] machineid files (userData root + ~/.qoder)..."
if rotate_machineid_file "$CONFIG_ROOT/machineid"; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi
if [[ -n "$QODER_DIR" ]]; then
    if rotate_machineid_file "$QODER_DIR/machineid"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
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
info "[5/9] ~/.qoder rotations (installation_id, .auth/machine_id, sentinel, argv.json)..."
if [[ -n "$QODER_DIR" && -d "$QODER_DIR" ]]; then
    if rotate_text_file "$QODER_DIR/installation_id" "installation_id" "$DEV_DEVICE_ID"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if rotate_text_file "$QODER_DIR/.auth/machine_id" "auth-machine-id" "$MACHINE_ID"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    if delete_store "$QODER_DIR/.auth/.credential-transaction" "credential-transaction"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    ARGV_JSON="$QODER_DIR/argv.json"
    if [[ -f "$ARGV_JSON" ]]; then
        ARGV_PAYLOAD=$(printf '{"new_id":"%s"}' "$DEV_DEVICE_ID" | b64_json_stdin)
        if python3 "$GHOST_CLI_PATH" patch-argv "$ARGV_JSON" "$BACKUP_ROOT" "argv-json" "$ARGV_PAYLOAD"; then
            ok "argv.json crash-reporter id patched."
            audit_line "$AUDIT_FILE" "$ARGV_JSON" "-" "$DEV_DEVICE_ID" 1
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            err "patch-argv FAILED."
            audit_line "$AUDIT_FILE" "$ARGV_JSON" "-" "failed" 0
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        warn "argv.json absent - crash-reporter id skipped."
        audit_line "$AUDIT_FILE" "$ARGV_JSON" "missing" "skipped" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
else
    warn "$HOME/.qoder not present - rotations skipped (first-launch state)."
    audit_line "$AUDIT_FILE" "$HOME/.qoder/installation_id" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[6/9] workspaceStorage state.vscdb serviceMachineId..."
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
info "[7/9] ~/Library sweep (Caches, Logs, Preferences, Saved Application State, HTTPStorages)..."
LIB_FAILED=0
for p in "$HOME/Library/Caches/Qoder" "$HOME/Library/Logs/Qoder"; do
    if delete_store "$p" "library-$(basename "$p")"; then
        :
    else
        LIB_FAILED=1
    fi
done
shopt -s nullglob
for p in "$HOME/Library/Preferences/"com.qoder* \
         "$HOME/Library/Saved Application State/"*[Qq]oder*.savedState \
         "$HOME/Library/HTTPStorages/"*[Qq]oder*; do
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
info "[8/9] userData stores (webview partitions, Chromium network/cache, SharedClientCache) + .qoder run-state trees..."
CH_FAILED=0
# Direct macOS mirrors of the proven Windows steps [5]-[15]/[18]/[25]/[29]
# (relative names inside the userData root; every one absent-tolerant).
# Whole-path store-delete by choice - small cache dirs with honest unit
# failures (the Windows [13]-[18] convention).
for p in "IndexedDB" "Partitions" "Storage" \
         "Local State" "SharedClientCache" \
         "Network/Cookies" "Network Persistent State" "Trust Tokens" \
         "DIPS" "DIPS-wal" "SharedStorage" "SharedStorage-wal" \
         "WebStorage" "Session Storage" "Local Storage" \
         "Cache" "Code Cache" "GPUCache" "Service Worker" "blob_storage" \
         "Crashpad" "CrashFeedback" "logs" \
         "state.vscdb.backup" "state.vscdb.backup-shm" "state.vscdb.backup-wal"; do
    if delete_store "$CONFIG_ROOT/$p" "store-$(basename "$p")"; then
        :
    else
        CH_FAILED=1
    fi
done
# .qoder CLI run state: per-FILE backup-first delete via sweep-tree (the
# BS-7 shape - one locked log must not leave 99% of the tree on disk).
if [[ -n "$QODER_DIR" && -d "$QODER_DIR" ]]; then
    for tree in "$QODER_DIR/tmp/telemetry" "$QODER_DIR/logs"; do
        if [[ -d "$tree" ]]; then
            if python3 "$GHOST_CLI_PATH" sweep-tree "$tree" "$BACKUP_ROOT" "$(basename "$tree")"; then
                ok "swept: $tree"
                audit_line "$AUDIT_FILE" "$tree" "-" "swept" 1
            else
                err "sweep-tree FAILED: $tree"
                audit_line "$AUDIT_FILE" "$tree" "-" "failed" 0
                CH_FAILED=1
            fi
        else
            warn "not present - skipped (first-launch state): $tree"
            audit_line "$AUDIT_FILE" "$tree" "missing" "skipped" 1
        fi
    done
fi
if [[ "$CH_FAILED" == "0" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
else
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[9/9] Final probe (read-only) + system-identity skip audit..."
PROBE_FAILED=0
STORAGE_JSON="$CONFIG_ROOT/User/globalStorage/storage.json"
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
if [[ -f "$STATE_VSCDB" ]]; then
    if SURVIVORS=$(count_survivors "$STATE_VSCDB") && [[ "$SURVIVORS" == "0" ]]; then
        ok "secret purge probe: zero survivors."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "survivors=0" 1
    else
        err "secret purge probe found survivors (or the probe failed)."
        audit_line "$AUDIT_FILE" "$STATE_VSCDB" "-" "survivors=${SURVIVORS:-probe-failed}" 0
        PROBE_FAILED=1
    fi
fi
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
    err "Qoder reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "Qoder reset completed successfully."
