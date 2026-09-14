#!/usr/bin/env bash
# Cursor Machine ID Reset Script for Linux
# Resets Cursor machine identifiers by updating config files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

CURSOR_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/Cursor"
MACHINE_ID_FILE="$CURSOR_CONFIG/machineId"
GLOBAL_STORAGE="$CURSOR_CONFIG/User/globalStorage"
STORAGE_JSON="$GLOBAL_STORAGE/storage.json"
SQLITE_DB="$GLOBAL_STORAGE/state.vscdb"

generate_ids() {
    DEV_DEVICE_ID=$(generate_uuid)
    MACHINE_ID=$(generate_hex 32)
    MAC_MACHINE_ID=$(generate_hex 64)
    SQM_ID="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
}

update_storage_json() {
    if ! has_python3; then
        warn "python3 not found; skipping storage.json update."
        return 1
    fi
    python3 - "$STORAGE_JSON" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID" <<'PY'
import json, os, sys
path, dev_id, machine_id, mac_id, sqm_id = sys.argv[1:6]
data = {}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
data.update({
    "telemetry.devDeviceId": dev_id,
    "telemetry.machineId": machine_id,
    "telemetry.macMachineId": mac_id,
    "telemetry.sqmId": sqm_id,
    "storage.serviceMachineId": dev_id,
})
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

update_sqlite() {
    if [[ ! -f "$SQLITE_DB" ]]; then
        warn "SQLite database not found at: $SQLITE_DB"
        return 0
    fi
    if ! has_python3; then
        warn "python3 not found; skipping SQLite update."
        return 1
    fi
    python3 - "$SQLITE_DB" "$DEV_DEVICE_ID" "$MACHINE_ID" "$MAC_MACHINE_ID" "$SQM_ID" <<'PY'
import sqlite3, sys
db_path, dev_id, machine_id, mac_id, sqm_id = sys.argv[1:6]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT PRIMARY KEY, value TEXT)")
for key, value in [
    ("telemetry.devDeviceId", dev_id),
    ("telemetry.macMachineId", mac_id),
    ("telemetry.machineId", machine_id),
    ("telemetry.sqmId", sqm_id),
    ("storage.serviceMachineId", dev_id),
]:
    cur.execute("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", (key, value))
conn.commit()
conn.close()
print("Database updated successfully.")
PY
}

# ── main ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && warn "Tip: run with sudo to also reset /etc/machine-id."

ensure_not_running "cursor"

if [[ ! -d "$CURSOR_CONFIG" ]]; then
    err "Cursor installation not found at: $CURSOR_CONFIG"
    exit 1
fi

info "=== Cursor Machine ID Reset Tool (Linux) ==="
info "Found Cursor installation at: $CURSOR_CONFIG"

generate_ids

ok ""
ok "Generated new identifiers:"
dim "  devDeviceId:   $DEV_DEVICE_ID"
dim "  machineId:     $MACHINE_ID"
dim "  macMachineId:  $MAC_MACHINE_ID"
dim "  sqmId:         $SQM_ID"

info ""
info "[1/4] Updating machineId file..."
backup_file "$MACHINE_ID_FILE"
mkdir -p "$(dirname "$MACHINE_ID_FILE")"
printf '%s\n' "$DEV_DEVICE_ID" > "$MACHINE_ID_FILE"
ok "Updated machineId file."

info ""
info "[2/4] Updating storage.json..."
[[ -f "$STORAGE_JSON" ]] && backup_file "$STORAGE_JSON"
mkdir -p "$GLOBAL_STORAGE"
update_storage_json && ok "Updated storage.json." || warn "storage.json update skipped."

info ""
info "[3/4] Updating SQLite database..."
if [[ -f "$SQLITE_DB" ]]; then
    backup_file "$SQLITE_DB"
    update_sqlite && ok "Updated SQLite database." || warn "SQLite update failed."
fi

info ""
info "[4/4] System machine-id..."
reset_system_machine_id

ok ""
ok "=== Reset Complete ==="
info ""
info "What was done:"
echo -e "${WHITE}  1. Generated new unique identifiers${NC}"
echo -e "${WHITE}  2. Updated machineId file: $MACHINE_ID_FILE${NC}"
echo -e "${WHITE}  3. Updated storage.json:  $STORAGE_JSON${NC}"
echo -e "${WHITE}  4. Attempted SQLite update: $SQLITE_DB${NC}"
if [[ "$SYSTEM_MACHINE_ID_SKIPPED" == "true" ]]; then
    echo -e "${WHITE}  5. System machine-id skipped (re-run with sudo)${NC}"
else
    echo -e "${WHITE}  5. Updated system machine-id (/etc/machine-id)${NC}"
fi

info ""
info "Next steps:"
echo -e "${WHITE}  1. Launch Cursor and complete any initial setup${NC}"
echo -e "${WHITE}  2. To revert, restore .backup files next to the originals${NC}"
