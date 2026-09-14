#!/usr/bin/env bash
# Common utilities for device ID reset scripts.
# Source this file: source "$(dirname "$0")/id_reset_common.sh"
# Not meant to be executed directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This file is meant to be sourced, not executed directly." >&2
    exit 1
fi

# ── Colors ──────────────────────────────────────────────────────────────
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

# ── ID generation ───────────────────────────────────────────────────────
generate_uuid() {
    uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

generate_hex() {
    local bytes="${1:-32}"
    openssl rand -hex "$bytes" 2>/dev/null || head -c "$bytes" /dev/urandom | xxd -p -c "$bytes"
}

# ── Hashing ─────────────────────────────────────────────────────────────
sha256_hex() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

# ── Helpers ─────────────────────────────────────────────────────────────
timestamp() {
    date +%Y%m%d_%H%M%S
}

has_python3() {
    command -v python3 >/dev/null 2>&1
}

# ── Backup ──────────────────────────────────────────────────────────────
backup_file() {
    local src="$1"
    if [[ -f "$src" ]]; then
        cp -f "$src" "${src}.backup"
        warn "Backup: ${src}.backup"
    fi
}

backup_to_dir() {
    local src="$1" dir="$2" label="$3"
    if [[ -f "$src" ]]; then
        mkdir -p "$dir"
        local dest="$dir/${label}_$(timestamp).backup"
        cp -f "$src" "$dest"
        warn "Backup: $dest"
    fi
}

# ── Process management ─────────────────────────────────────────────────
ensure_not_running() {
    local name="$1"
    local pattern="[${name:0:1}]${name:1}"
    if pgrep -x "$name" >/dev/null 2>&1 || pgrep -f "$pattern" >/dev/null 2>&1; then
        warn "$name is currently running. Please close it before continuing."
        read -r -p "Forcibly close $name now? (y/N): " response
        if [[ "${response,,}" == "y" ]]; then
            pkill -x "$name" 2>/dev/null || pkill -f "$pattern" 2>/dev/null || true
            sleep 2
        else
            err "Please close $name and run this script again."
            exit 1
        fi
    fi
}

# ── System machine-id ──────────────────────────────────────────────────
# Sets SYSTEM_MACHINE_ID_SKIPPED=true when not running as root.
SYSTEM_MACHINE_ID_SKIPPED=false

reset_system_machine_id() {
    SYSTEM_MACHINE_ID_SKIPPED=false
    local etc_id="/etc/machine-id"
    local dbus_id="/var/lib/dbus/machine-id"

    if [[ $EUID -ne 0 ]]; then
        SYSTEM_MACHINE_ID_SKIPPED=true
        warn "Not running as root; skipping system machine-id update."
        warn "Re-run with: sudo $0"
        return 0
    fi

    info "Updating system machine-id..."
    if [[ -f "$etc_id" ]]; then
        cp -f "$etc_id" "${etc_id}.backup"
        warn "Backup: ${etc_id}.backup"
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
        rm -f "$dbus_id"
    fi
    command -v dbus-uuidgen >/dev/null 2>&1 && dbus-uuidgen --ensure >/dev/null 2>&1 || true

    ok "Updated system machine-id."
    if [[ -f "$etc_id" ]]; then
        dim "New machine-id: $(cat "$etc_id")"
    fi
}
