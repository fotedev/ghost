#!/usr/bin/env bash
# Interactive launcher for device ID reset tools.
# Run: bash how-to-run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$SCRIPT_DIR/scripts/linux"
source "$LINUX_DIR/id_reset_common.sh"

while true; do
    echo ""
    ok "═══════════════════════════════════════════════"
    ok "  Device ID Reset Tools (Linux)"
    ok "═══════════════════════════════════════════════"
    echo ""
    echo "  1) Generate hardware fingerprint (JSON)"
    echo "  2) Reset Cursor machine IDs"
    echo "  3) Reset Windsurf machine IDs"
    echo "  4) Reset system machine-id only (requires root)"
    echo "  0) Exit"
    echo ""
    read -r -p "Select an option [0-4]: " choice
    case "$choice" in
        1) bash "$LINUX_DIR/change_device_id_linux.sh" Fingerprint    ;;
        2) bash "$LINUX_DIR/reset_cursor_linux.sh"                    ;;
        3) bash "$LINUX_DIR/reset_windsurf_linux.sh"                  ;;
        4) bash "$LINUX_DIR/change_device_id_linux.sh" ResetMachineId ;;
        0) info "Goodbye."; exit 0                                     ;;
        *) err "Invalid option: $choice"                               ;;
    esac
    echo ""
    read -r -p "Press Enter to continue..." _dummy
done
