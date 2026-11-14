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
    echo "  --- IDE Resets ---"
    echo "  1) Reset Cursor machine IDs"
    echo "  2) Reset Devin machine IDs (formerly Windsurf)"
    echo "  3) Reset Trae machine IDs (derived paths - see note in script)"
    echo "  4) Reset Qoder machine IDs (derived paths - see note in script)"
    echo "  5) Reset QoderWork machine IDs (derived paths - see note in script)"
    echo "  6) Reset ZCode machine IDs (derived paths - see note in script)"
    echo "  7) Reset MiniMax/OpenCode machine IDs (derived paths - see note in script)"
    echo "  --- System ---"
    echo "  8) Generate hardware fingerprint (JSON)"
    echo "  9) Reset system machine-id only (requires root)"
    echo "  0) Exit"
    echo ""
    read -r -p "Select an option [0-9]: " choice
    case "$choice" in
        # || true: a child exiting non-zero (declined kill, non-root
        # ResetMachineId, failed reset) must not kill the menu via set -e.
        1) bash "$LINUX_DIR/reset_cursor.sh"                    || true ;;
        2) bash "$LINUX_DIR/reset_devin.sh"                     || true ;;
        3) bash "$LINUX_DIR/reset_trae.sh"                      || true ;;
        4) bash "$LINUX_DIR/reset_qoder.sh"                     || true ;;
        5) bash "$LINUX_DIR/reset_qoderwork.sh"                 || true ;;
        6) bash "$LINUX_DIR/reset_zcode.sh"                     || true ;;
        7) bash "$LINUX_DIR/reset_minimax_opencode.sh"          || true ;;
        8) bash "$LINUX_DIR/change_device_id.sh" Fingerprint    || true ;;
        9) bash "$LINUX_DIR/change_device_id.sh" ResetMachineId || true ;;
        0) info "Goodbye."; exit 0                                     ;;
        *) err "Invalid option: $choice"                               ;;
    esac
    echo ""
    read -r -p "Press Enter to continue..." _dummy
done
