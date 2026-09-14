#!/usr/bin/env bash
# Windsurf Machine ID Reset Script for Linux
# Resets Windsurf machine identifiers while preserving other settings where possible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

USERNAME="${USER:-$(whoami)}"
WINDSURF_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Windsurf"
WINDSURF_HOME="$HOME/.windsurf"
CODEIUM_PATH="$HOME/.codeium"
BACKUP_PATH="$WINDSURF_CONFIG/ID_Backups"

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
def walk(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str) and username in v:
                obj[k] = v.replace(username, "RESET")
            else:
                walk(v)
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            if isinstance(item, str) and username in item:
                obj[i] = item.replace(username, "RESET")
            else:
                walk(item)
walk(data)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

update_codeium_config() {
    local config="$CODEIUM_PATH/config.json"
    mkdir -p "$CODEIUM_PATH"
    local new_device
    new_device=$(generate_uuid)
    [[ -f "$config" ]] && backup_to_dir "$config" "$BACKUP_PATH" "codeium_config"
    if has_python3; then
        python3 - "$config" "$new_device" <<'PY'
import json, sys
path, device_id = sys.argv[1], sys.argv[2]
cfg = {
    "device_id": device_id,
    "api_key": "",
    "portal_url": "https://www.codeium.com",
    "manager_url": "https://codeium.com/waitlist",
    "inference_url": "https://server.codeium.com",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(device_id)
PY
        ok "Updated Codeium config with new device ID: $new_device"
    else
        warn "python3 not found; could not update Codeium config."
    fi
}

# ── main ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && warn "Tip: run with sudo to also reset /etc/machine-id."

ensure_not_running "windsurf"

if pgrep -fi codeium >/dev/null 2>&1; then
    warn "Codeium processes detected; stopping them."
    pkill -fi codeium 2>/dev/null || true
    sleep 1
fi

if [[ ! -d "$WINDSURF_CONFIG" ]]; then
    warn "Windsurf config not found at: $WINDSURF_CONFIG"
    read -r -p "Create required directories? (y/N): " create
    if [[ "${create,,}" == "y" ]]; then
        mkdir -p "$WINDSURF_CONFIG" "$WINDSURF_HOME" "$CODEIUM_PATH"
    else
        exit 1
    fi
fi

mkdir -p "$BACKUP_PATH"
info "=== Windsurf Machine ID Reset Tool (Linux) ==="
info "Found Windsurf installation at: $WINDSURF_CONFIG"
ok "Backups saved to: $BACKUP_PATH"

generate_ids

ok ""
ok "Generated new identifiers:"
dim "  machineId: $NEW_MACHINE_ID"
dim "  deviceId:  $NEW_DEVICE_ID"

MACHINE_ID_PATH="$WINDSURF_CONFIG/machineid"
PREFERENCES_PATH="$WINDSURF_CONFIG/Preferences"
LOCAL_STATE_PATH="$WINDSURF_CONFIG/Local State"
ARGV_PATH="$WINDSURF_HOME/argv.json"

info ""
info "[1/5] Updating machineId file..."
backup_to_dir "$MACHINE_ID_PATH" "$BACKUP_PATH" "machineid"
printf '%s\n' "$NEW_MACHINE_ID" > "$MACHINE_ID_PATH"
ok "Updated machineId file."

info ""
info "[2/5] Updating Preferences file..."
if [[ -f "$PREFERENCES_PATH" ]]; then
    backup_to_dir "$PREFERENCES_PATH" "$BACKUP_PATH" "Preferences"
    json_replace_username "$PREFERENCES_PATH" && ok "Updated Preferences." || warn "Preferences update failed."
fi

info ""
info "[3/5] Updating Local State file..."
if [[ -f "$LOCAL_STATE_PATH" ]]; then
    backup_to_dir "$LOCAL_STATE_PATH" "$BACKUP_PATH" "LocalState"
    json_replace_username "$LOCAL_STATE_PATH" && ok "Updated Local State." || warn "Local State update failed."
fi

info ""
info "[4/5] Updating argv.json file..."
if [[ -f "$ARGV_PATH" ]]; then
    backup_to_dir "$ARGV_PATH" "$BACKUP_PATH" "argv"
    json_replace_username "$ARGV_PATH" && ok "Updated argv.json." || warn "argv.json update failed."
fi

info ""
info "[5/5] System machine-id..."
reset_system_machine_id

info ""
info "[Bonus] Resetting Codeium..."
if [[ -d "$CODEIUM_PATH" ]] || [[ -d "$WINDSURF_CONFIG" ]]; then
    update_codeium_config
fi

ok ""
ok "=== Reset Complete ==="
info ""
info "What was done:"
echo -e "${WHITE}  1. Generated new unique identifiers${NC}"
echo -e "${WHITE}  2. Updated machineId: $MACHINE_ID_PATH${NC}"
echo -e "${WHITE}  3. Updated Preferences / Local State / argv.json where present${NC}"
if [[ "$SYSTEM_MACHINE_ID_SKIPPED" == "true" ]]; then
    echo -e "${WHITE}  4. System machine-id skipped (re-run with sudo)${NC}"
else
    echo -e "${WHITE}  4. Updated system machine-id${NC}"
fi
echo -e "${WHITE}  5. Reset Codeium configuration${NC}"

info ""
info "Backups: $BACKUP_PATH"
info ""
info "Next steps:"
echo -e "${WHITE}  1. Launch Windsurf and complete any initial setup${NC}"
echo -e "${WHITE}  2. To revert, use backup files in $BACKUP_PATH${NC}"
