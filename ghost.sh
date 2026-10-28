#!/usr/bin/env bash
# GHOST — interactive launcher for device ID reset tools.
# Run: bash ghost.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$SCRIPT_DIR/src/linux"
# shellcheck source=src/linux/id_reset_common.sh
source "$LINUX_DIR/id_reset_common.sh"

while true; do
    show_banner "Interactive Menu"
    echo "  1) Generate hardware fingerprint (JSON)"
    echo "  2) Reset Cursor machine IDs"
    echo "  3) Reset Windsurf machine IDs"
    echo "  4) Reset system machine-id only (requires root)"
    echo "  0) Exit"
    echo ""
    read -r -p "Select an option [0-4]: " choice
    case "$choice" in
        # || true: a child exiting non-zero (declined kill, non-root
        # ResetMachineId, failed reset) must not kill the menu via set -e.
        1) bash "$LINUX_DIR/change_device_id.sh" Fingerprint    || true ;;
        2) bash "$LINUX_DIR/reset_cursor.sh"                    || true ;;
        3) bash "$LINUX_DIR/reset_windsurf.sh"                  || true ;;
        4) bash "$LINUX_DIR/change_device_id.sh" ResetMachineId || true ;;
        0) info "Goodbye."; exit 0                                     ;;
        *) err "Invalid option: $choice"                               ;;
    esac
    echo ""
    read -r -p "Press Enter to continue..." _dummy
done
