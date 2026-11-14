#!/usr/bin/env bash
# Devin (formerly Windsurf) Machine ID Reset Script for Linux (GHOST v0.2)
#
# Renamed 2026-11-14 from reset_windsurf.sh: Windsurf rebranded to Devin
# Desktop 2026-06-02 (the Windows reset_devin.ps1 v0.4 carries the same
# naming); the Linux side was stale at the pre-rebrand name with a
# Codeium-era waitlist URL (codeium.com/waitlist) still written into the
# Codeium config - now scrubbed.
#
# v0.2 (2026-11-14): modernized to the Windows-side standard - timestamped
# ID_Backups/<ts> dirs, JSONL audit, verify-after re-reads on every write,
# and a self-contained restore script emission. Every file mutation is
# verified by RE-READING the file; username scrubs re-read via a grep sweep.
#
# Steps (unchanged order):
#   1. machineid file (re-read verified)
#   2. Preferences username scrub (re-read verified)
#   3. Local State username scrub (re-read verified)
#   4. argv.json username scrub (re-read verified)
#   5. system machine-id (root)
#   bonus: Codeium config device_id reset (waitlist URL scrubbed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "Devin Identity Reset" "0.2"

USERNAME="${USER:-$(whoami)}"
DEVIN_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Windsurf"
DEVIN_HOME="$HOME/.windsurf"
CODEIUM_PATH="$HOME/.codeium"
BACKUP_ROOT="$DEVIN_CONFIG/ID_Backups/$(timestamp)"

generate_ids() {
    NEW_MACHINE_ID=$(generate_uuid)
    NEW_DEVICE_ID=$(generate_hex 32)
}

json_replace_username() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if ! has_python3; then
        warn "python3 not found; skipping JSON update for $file"
        return 1
    fi
    python3 - "$file" "$USERNAME" <<'PY'
import json, sys
path, username = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    raw = f.read().lstrip("\ufeff").strip()
if not raw:
    sys.exit(0)
data = json.loads(raw)
count = 0
def walk(obj):
    global count
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and username in v:
                obj[k] = v.replace(username, "RESET")
                count += 1
            else:
                walk(v)
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            if isinstance(item, str) and username in item:
                obj[i] = item.replace(username, "RESET")
                count += 1
            else:
                walk(item)
walk(data)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(count)
PY
}

verify_username_scrubbed() {
    # Re-read: the username must not appear anywhere in the file.
    local file="$1"
    if [[ ! -f "$file" ]]; then return 0; fi
    if grep -qF "$USERNAME" "$file" 2>/dev/null; then
        echo "VERIFY FAILED: $file still contains the username"
        return 1
    fi
    return 0
}

update_codeium_config() {
    local config="$CODEIUM_PATH/config.json"
    mkdir -p "$CODEIUM_PATH"
    local new_device
    new_device=$(generate_uuid)
    local backup
    backup=$(core_backup "$config" "$BACKUP_ROOT" "codeium_config")
    if has_python3; then
        python3 - "$config" "$new_device" <<'PY'
import json, sys
path, device_id = sys.argv[1], sys.argv[2]
cfg = {
    "device_id": device_id,
    "api_key": "",
    "portal_url": "https://www.codeium.com",
    "inference_url": "https://server.codeium.com",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(device_id)
PY
        # Verify-after (the codeium.com/waitlist manager_url is DEAD - the
        # pre-Devin-era script wrote it back on every reset).
        if verify_json_keys "$config" "device_id=$new_device" "api_key="; then
            ok "Updated Codeium config with new device ID: $new_device (waitlist URL scrubbed)"
            audit_line "$AUDIT_FILE" "$config" "backup=$(basename "${backup:-none}")" "$new_device" 1 "waitlist-url scrubbed"
            return 0
        fi
        err "Codeium config VERIFY FAILED."
        audit_line "$AUDIT_FILE" "$config" "-" "verify-failed" 0
        return 1
    fi
    warn "python3 not found; could not update Codeium config."
    audit_line "$AUDIT_FILE" "$config" "-" "skipped-no-python3" 1
    return 1
}

# ── main ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && warn "Tip: run with sudo to also reset /etc/machine-id."

ensure_not_running "windsurf"

if pgrep -fi codeium >/dev/null 2>&1; then
    warn "Codeium processes detected; stopping them."
    pkill -fi codeium 2>/dev/null || true
    sleep 1
fi

if [[ ! -d "$DEVIN_CONFIG" ]]; then
    warn "Devin config not found at: $DEVIN_CONFIG"
    read -r -p "Create required directories? (y/N): " create
    if [[ "${create,,}" == "y" ]]; then
        mkdir -p "$DEVIN_CONFIG" "$DEVIN_HOME" "$CODEIUM_PATH"
    else
        exit 1
    fi
fi

mkdir -p "$BACKUP_ROOT"
RESTORE_ENTRIES=()
audit_init "$BACKUP_ROOT"

PASS_COUNT=0
FAIL_COUNT=0

generate_ids

ok ""
ok "Generated new identifiers:"
dim "  machineId: $NEW_MACHINE_ID"
dim "  deviceId:  $NEW_DEVICE_ID"

MACHINE_ID_PATH="$DEVIN_CONFIG/machineid"
PREFERENCES_PATH="$DEVIN_CONFIG/Preferences"
LOCAL_STATE_PATH="$DEVIN_CONFIG/Local State"
ARGV_PATH="$DEVIN_HOME/argv.json"

info ""
info "[1/5] Updating machineid file..."
machineid_backup=$(core_backup "$MACHINE_ID_PATH" "$BACKUP_ROOT" "machineid")
printf '%s\n' "$NEW_MACHINE_ID" > "$MACHINE_ID_PATH"
if verify_file_value "$MACHINE_ID_PATH" "$NEW_MACHINE_ID"; then
    ok "machineid file updated + verified."
    audit_line "$AUDIT_FILE" "$MACHINE_ID_PATH" "backup=$(basename "${machineid_backup:-none}")" "$NEW_MACHINE_ID" 1
    PASS_COUNT=$((PASS_COUNT + 1))
else
    err "machineid VERIFY FAILED."
    audit_line "$AUDIT_FILE" "$MACHINE_ID_PATH" "-" "verify-failed" 0
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

info ""
info "[2/5] Updating Preferences file..."
if [[ -f "$PREFERENCES_PATH" ]]; then
    pref_backup=$(core_backup "$PREFERENCES_PATH" "$BACKUP_ROOT" "Preferences")
    if out=$(json_replace_username "$PREFERENCES_PATH") && verify_username_scrubbed "$PREFERENCES_PATH"; then
        ok "Preferences scrubbed + verified ($out replacement(s))."
        audit_line "$AUDIT_FILE" "$PREFERENCES_PATH" "backup=$(basename "${pref_backup:-none}")" "$out replacements" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "Preferences update/verify FAILED."
        audit_line "$AUDIT_FILE" "$PREFERENCES_PATH" "-" "verify-failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "Preferences not present - skipped."
    audit_line "$AUDIT_FILE" "$PREFERENCES_PATH" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[3/5] Updating Local State file..."
if [[ -f "$LOCAL_STATE_PATH" ]]; then
    ls_backup=$(core_backup "$LOCAL_STATE_PATH" "$BACKUP_ROOT" "LocalState")
    if out=$(json_replace_username "$LOCAL_STATE_PATH") && verify_username_scrubbed "$LOCAL_STATE_PATH"; then
        ok "Local State scrubbed + verified ($out replacement(s))."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE_PATH" "backup=$(basename "${ls_backup:-none}")" "$out replacements" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "Local State update/verify FAILED."
        audit_line "$AUDIT_FILE" "$LOCAL_STATE_PATH" "-" "verify-failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "Local State not present - skipped."
    audit_line "$AUDIT_FILE" "$LOCAL_STATE_PATH" "missing" "skipped" 1
    PASS_COUNT=$((PASS_COUNT + 1))
fi

info ""
info "[4/5] Updating argv.json file..."
if [[ -f "$ARGV_PATH" ]]; then
    argv_backup=$(core_backup "$ARGV_PATH" "$BACKUP_ROOT" "argv")
    if out=$(json_replace_username "$ARGV_PATH") && verify_username_scrubbed "$ARGV_PATH"; then
        ok "argv.json scrubbed + verified ($out replacement(s))."
        audit_line "$AUDIT_FILE" "$ARGV_PATH" "backup=$(basename "${argv_backup:-none}")" "$out replacements" 1
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        err "argv.json update/verify FAILED."
        audit_line "$AUDIT_FILE" "$ARGV_PATH" "-" "verify-failed" 0
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
else
    warn "argv.json not present - skipped."
    audit_line "$AUDIT_FILE" "$ARGV_PATH" "missing" "skipped" 1
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

info ""
info "[Bonus] Resetting Codeium..."
if [[ -d "$CODEIUM_PATH" ]] || [[ -d "$DEVIN_CONFIG" ]]; then
    if update_codeium_config; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

RESTORE_SCRIPT=$(emit_restore_script "$BACKUP_ROOT")

info ""
ok "=== Reset Complete ==="
info ""
info "Summary: Pass $PASS_COUNT / Fail $FAIL_COUNT"
info "Backups: $BACKUP_ROOT"
info "Audit:   $AUDIT_FILE"
info "Restore: $RESTORE_SCRIPT"
info "Note   : Devin config lives at ~/.config/Windsurf (app-owned path, never renamed)."

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    err "Devin reset completed with FAILURES - review the audit JSONL."
    exit 1
fi
ok "Devin reset completed successfully."
