#!/usr/bin/env bash
# Trae IDE Machine ID Reset Script for Linux
# Resets Trae IDE machine identifiers by updating config files only (no external apps).

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

need_root_for_machine_id=false

generate_ids() {
    DEV_DEVICE_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    MACHINE_ID=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 32)
    MAC_MACHINE_ID=$(openssl rand -hex 64 2>/dev/null || head -c 64 /dev/urandom | xxd -p -c 64)
    SQM_ID="{$(uuidgen 2>/dev/null | tr '[:lower:]' '[:upper:]' || echo "$(cat /proc/sys/kernel/random/uuid)" | tr '[:lower:]' '[:upper:]')}"
}

ensure_trae_closed() {
    if pgrep -x trae >/dev/null 2>&1 || pgrep -f '[T]rae' >/dev/null 2>&1; then
        warn "Trae IDE is currently running. Please close it before continuing."
        read -r -p "Forcibly close Trae IDE now? (y/N): " response
        if [[ "${response,,}" == "y" ]; then
            pkill -x trae 2>/dev/null || pkill -f '[T]rae' 2>/dev/null || true
            sleep 2
        else
            err "Please close Trae IDE and run this script again."
            exit 1
        fi
    fi
}

TRAE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Trae"
GLOBAL_STORAGE="$TRAE_CONFIG/User/globalStorage"
STORAGE_JSON="$GLOBAL_STORAGE/storage.json"
SQLITE_DB="$GLOBAL_STORAGE/state.vscdb"
MODULAR_DATA="$TRAE_CONFIG/ModularData"

backup_file() {
    local src="$1"
    if [[ -f "$src" ]]; then
        cp -f "$src" "${src}.backup"
        warn "Created backup at: ${src}.backup"
    fi
}

update_storage_json() {
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 not found; skipping storage.json update."
        return 1
    fi
    python3 - "$STORAGE_JSON" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID" <<'PY'
import json
import os
import sys

path, dev_id, machine_id, mac_id, sqm_id = sys.argv[1:6]
data = {}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

updates = {
    "telemetry.devDeviceId": dev_id,
    "telemetry.machineId": machine_id,
    "telemetry.macMachineId": mac_id,
    "telemetry.sqmId": sqm_id,
    "storage.serviceMachineId": dev_id,
}
data.update(updates)

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

update_sqlite() {
    if [[ ! -f "$SQLITE_DB" ]]; then
        warn "SQLite database not found at: $SQLITE_DB"
        warn "This is normal if you have not used Trae IDE before."
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 not found; skipping SQLite update."
        return 1
    fi
    python3 - "$SQLITE_DB" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID" <<'PY'
import sqlite3
import sys

db_path, dev_id, machine_id, mac_id, sqm_id = sys.argv[1:6]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("""
    CREATE TABLE IF NOT EXISTS ItemTable (
        key TEXT PRIMARY KEY,
        value TEXT
    )
""")
for key, value in [
    ("telemetry.devDeviceId", dev_id),
    ("telemetry.macMachineId", mac_id),
    ("telemetry.machineId", machine_id),
    ("telemetry.sqmId", sqm_id),
    ("storage.serviceMachineId", dev_id),
]:
    cur.execute(
        "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
        (key, value),
    )
conn.commit()
conn.close()
print("Database updated successfully.")
PY
}

update_system_machine_id() {
    local etc_id="/etc/machine-id"
    local dbus_id="/var/lib/dbus/machine-id"

    if [[ $EUID -ne 0 ]]; then
        need_root_for_machine_id=true
        warn "Not running as root; skipping system machine-id update."
        warn "Re-run with: sudo $0"
        return 0
    fi

    info ""
    info "[4/4] Updating system machine-id..."
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

    if [[ -e "$dbus_id" && ! -L "$dbus_id" ]]; then
        cp -f "$dbus_id" "${dbus_id}.backup" 2>/dev/null || true
        rm -f "$dbus_id"
    fi
    if command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen --ensure >/dev/null 2>&1 || true
    fi

    ok "Updated system machine-id."
    if [[ -f "$etc_id" ]]; then
        dim "New machine-id: $(cat "$etc_id")"
    fi
}

# --- main ---
if [[ $EUID -ne 0 ]]; then
    warn "Tip: run with sudo to also reset /etc/machine-id (Linux system identifier)."
fi

ensure_trae_closed

if [[ ! -d "$TRAE_CONFIG" ]]; then
    warn "Trae IDE directory not found at: $TRAE_CONFIG"
    warn "Creating directory structure..."
    mkdir -p "$TRAE_CONFIG" "$GLOBAL_STORAGE"
fi

info "=== Trae IDE Machine ID Reset Tool (Linux) ==="
info "Trae IDE config path: $TRAE_CONFIG"
ok ""

generate_ids
info "Generating new identifiers..."
ok ""
ok "Generated new identifiers:"
dim "devDeviceId: $DEV_DEVICE_ID"
dim "machineId: $MACHINE_ID"
dim "macMachineId: $MAC_MACHINE_ID"
dim "sqmId: $SQM_ID"

info ""
info "[1/4] Updating storage.json..."
if [[ -f "$STORAGE_JSON" ]]; then
    backup_file "$STORAGE_JSON"
fi
mkdir -p "$GLOBAL_STORAGE"
if update_storage_json; then
    ok "Updated storage.json successfully."
else
    warn "storage.json update skipped or failed."
fi

info ""
info "[2/4] Updating SQLite database..."
if [[ -f "$SQLITE_DB" ]]; then
    backup_file "$SQLITE_DB"
    update_sqlite && ok "Updated SQLite database successfully." || warn "SQLite update failed."
fi

info ""
info "[3/4] Clearing ModularData directory..."
if [[ -d "$MODULAR_DATA" ]]; then
    mv -f "$MODULAR_DATA" "${MODULAR_DATA}.backup"
    ok "Moved ModularData to ModularData.backup"
else
    warn "ModularData directory not found"
fi

update_system_machine_id

ok ""
ok "=== Reset Complete ==="
ok "Trae IDE machine identifiers have been reset successfully."
info ""
info "What's been done:"
echo -e "${WHITE}1. Generated new unique identifiers${NC}"
echo -e "${WHITE}2. Updated storage.json at: $STORAGE_JSON${NC}"
echo -e "${WHITE}3. Attempted SQLite update at: $SQLITE_DB${NC}"
echo -e "${WHITE}4. Cleared ModularData directory${NC}"
if [[ $need_root_for_machine_id == true ]]; then
    echo -e "${WHITE}5. System machine-id skipped (re-run with sudo)${NC}"
else
    echo -e "${WHITE}5. Updated system machine-id (/etc/machine-id)${NC}"
fi

info ""
info "Next steps:"
echo -e "${WHITE}1. Launch Trae IDE and log in again${NC}"
echo -e "${WHITE}2. To revert, restore .backup files next to the originals${NC}"
if [[ $need_root_for_machine_id == true ]]; then
    echo -e "${WHITE}3. Optional: sudo $0 to reset system machine-id${NC}"
fi
