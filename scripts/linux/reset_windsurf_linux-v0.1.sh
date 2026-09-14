#!/usr/bin/env bash
# Windsurf Machine ID Reset Script for Linux
# Resets Windsurf machine identifiers while preserving other settings where possible.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[1;37m'
NC='\033[0m'

info()  { echo -e "${CYAN}$*${NC}"; }
ok()    { echo -e "${GREEN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
err()   { echo -e "${RED}$*${NC}"; }
dim()   { echo -e "${GRAY}$*${NC}"; }

USERNAME="${USER:-$(whoami)}"
WINDSURF_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Windsurf"
WINDSURF_HOME="$HOME/.windsurf"
CODEIUM_PATH="$HOME/.codeium"
BACKUP_PATH="$WINDSURF_CONFIG/ID_Backups"
need_root_for_machine_id=false

generate_ids() {
    NEW_MACHINE_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    NEW_DEVICE_ID=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)
}

timestamp() {
    date +%Y%m%d_%H%M%S
}

backup_to_dir() {
    local src="$1"
    local label="$2"
    if [[ -f "$src" ]]; then
        local dest="$BACKUP_PATH/${label}_$(timestamp).backup"
        cp -f "$src" "$dest"
        warn "Created backup at: $dest"
    fi
}

ensure_windsurf_closed() {
    if pgrep -x windsurf >/dev/null 2>&1 || pgrep -f '[W]indsurf' >/dev/null 2>&1; then
        warn "Windsurf is currently running. Please close it before continuing."
        read -r -p "Forcibly close Windsurf now? (y/N): " response
        if [[ "${response,,}" == "y" ]]; then
            pkill -x windsurf 2>/dev/null || pkill -f '[W]indsurf' 2>/dev/null || true
            sleep 2
        else
            err "Please close Windsurf and run this script again."
            exit 1
        fi
    fi
    if pgrep -fi codeium >/dev/null 2>&1; then
        warn "Codeium processes are running; stopping them."
        pkill -fi codeium 2>/dev/null || true
        sleep 1
    fi
}

json_replace_username() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 not found; skipping JSON update for $file"
        return 1
    fi
    python3 - "$file" "$USERNAME" <<'PY'
import json
import sys

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
    new_device=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

    if [[ -f "$config" ]]; then
        backup_to_dir "$config" "codeium_config"
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$config" "$new_device" <<'PY'
import json
import sys

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

update_system_machine_id() {
    local etc_id="/etc/machine-id"

    if [[ $EUID -ne 0 ]]; then
        need_root_for_machine_id=true
        warn "Not running as root; skipping system machine-id update."
        warn "Re-run with: sudo $0"
        return 0
    fi

    info ""
    info "[5/5] Updating system machine-id..."
    if [[ -f "$etc_id" ]]; then
        cp -f "$etc_id" "${etc_id}.backup"
        warn "Created backup at: ${etc_id}.backup"
    fi

    if command -v systemd-machine-id-setup >/dev/null 2>&1; then
        rm -f "$etc_id"
        systemd-machine-id-setup
    elif command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen --ensure="$etc_id"
    else
        err "Neither systemd-machine-id-setup nor dbus-uuidgen found."
        return 1
    fi

    local dbus_id="/var/lib/dbus/machine-id"
    if [[ -e "$dbus_id" && ! -L "$dbus_id" ]]; then
        rm -f "$dbus_id"
    fi
    command -v dbus-uuidgen >/dev/null 2>&1 && dbus-uuidgen --ensure >/dev/null 2>&1 || true

    ok "Updated system machine-id."
}

# --- main ---
if [[ $EUID -ne 0 ]]; then
    warn "Tip: run with sudo to also reset /etc/machine-id."
fi

ensure_windsurf_closed

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
ok "Backups will be saved to: $BACKUP_PATH"

generate_ids
info ""
info "Generating new identifiers..."
ok ""
ok "Generated new identifiers:"
dim "machineId: $NEW_MACHINE_ID"
dim "deviceId: $NEW_DEVICE_ID"

MACHINE_ID_PATH="$WINDSURF_CONFIG/machineid"
PREFERENCES_PATH="$WINDSURF_CONFIG/Preferences"
LOCAL_STATE_PATH="$WINDSURF_CONFIG/Local State"
ARGV_PATH="$WINDSURF_HOME/argv.json"

info ""
info "[1/5] Updating machineId file..."
backup_to_dir "$MACHINE_ID_PATH" "machineid"
printf '%s\n' "$NEW_MACHINE_ID" >"$MACHINE_ID_PATH"
ok "Updated machineId file successfully."

info ""
info "[2/5] Updating Preferences file..."
if [[ -f "$PREFERENCES_PATH" ]]; then
    backup_to_dir "$PREFERENCES_PATH" "Preferences"
    json_replace_username "$PREFERENCES_PATH" && ok "Updated Preferences file successfully." || warn "Preferences update failed."
fi

info ""
info "[3/5] Updating Local State file..."
if [[ -f "$LOCAL_STATE_PATH" ]]; then
    backup_to_dir "$LOCAL_STATE_PATH" "LocalState"
    json_replace_username "$LOCAL_STATE_PATH" && ok "Updated Local State file successfully." || warn "Local State update failed."
fi

info ""
info "[4/5] Updating argv.json file..."
if [[ -f "$ARGV_PATH" ]]; then
    backup_to_dir "$ARGV_PATH" "argv"
    json_replace_username "$ARGV_PATH" && ok "Updated argv.json file successfully." || warn "argv.json update failed."
fi

update_system_machine_id

info ""
info "[Bonus] Resetting Codeium..."
if [[ -d "$CODEIUM_PATH" ]] || [[ -d "$WINDSURF_CONFIG" ]]; then
    update_codeium_config
fi

ok ""
ok "=== Reset Complete ==="
ok "Windsurf machine identifiers have been reset successfully."
info ""
info "What's been done:"
echo -e "${WHITE}1. Generated new unique identifiers${NC}"
echo -e "${WHITE}2. Updated machineId at: $MACHINE_ID_PATH${NC}"
echo -e "${WHITE}3. Updated Preferences / Local State / argv.json where present${NC}"
if [[ $need_root_for_machine_id == true ]]; then
    echo -e "${WHITE}4. System machine-id skipped (re-run with sudo)${NC}"
else
    echo -e "${WHITE}4. Updated system machine-id${NC}"
fi
echo -e "${WHITE}5. Reset Codeium configuration${NC}"
info ""
info "Backups created in: $BACKUP_PATH"
info ""
info "Next steps:"
echo -e "${WHITE}1. Launch Windsurf and complete any initial setup${NC}"
echo -e "${WHITE}2. To revert, use backup files in $BACKUP_PATH${NC}"
