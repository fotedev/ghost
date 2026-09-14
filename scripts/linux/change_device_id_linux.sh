#!/usr/bin/env bash
# Linux device identity tools (Fingerprint + system machine-id reset).
# Designed as the Linux counterpart to change_device_id.ps1 (Windows-only modes omitted).
set -euo pipefail

MODE="${1:-Fingerprint}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/LicenseIdentity"
STATE_PATH="${STATE_PATH:-$STATE_DIR/fingerprint_state.json}"

usage() {
    cat <<EOF
Usage: $0 [Fingerprint|ResetMachineId]
  Fingerprint       Print a stable hardware/OS fingerprint as JSON (default).
  ResetMachineId    Regenerate /etc/machine-id (requires root).

Environment:
  STATE_PATH        Override fingerprint state file (default: $STATE_PATH)
EOF
}

sha256_hex() {
    printf '%s' "$1" | sha256sum | awk '{print $1}'
}

read_signal() {
    local key="$1"
    local val="$2"
    [[ -n "$val" ]] && printf '%s' "${key}=${val};"
}

collect_signals() {
    local s=""
    [[ -r /etc/os-release ]] && s+=$(read_signal os.pretty_name "$(grep -E '^PRETTY_NAME=' /etc/os-release | head -1 | cut -d= -f2- | tr -d '"')")
    s+=$(read_signal os.id "$(grep -E '^ID=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')")
    s+=$(read_signal os.version_id "$(grep -E '^VERSION_ID=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')")
    s+=$(read_signal kernel "$(uname -r)")
    s+=$(read_signal arch "$(uname -m)")
    s+=$(read_signal hostname "$(hostname 2>/dev/null || true)")
    if [[ -r /etc/machine-id ]]; then
        s+=$(read_signal machine_id "$(cat /etc/machine-id)")
    fi
    if [[ -r /sys/class/dmi/id/product_name ]]; then
        s+=$(read_signal hw.product "$(cat /sys/class/dmi/id/product_name 2>/dev/null)")
        s+=$(read_signal hw.vendor "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)")
        s+=$(read_signal bios.version "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)")
    fi
    if [[ -r /proc/cpuinfo ]]; then
        local cpu_model cores
        cpu_model=$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')
        cores=$(nproc 2>/dev/null || echo "")
        s+=$(read_signal cpu.name "$cpu_model")
        s+=$(read_signal cpu.cores "$cores")
    fi
    local ram_gb
    if [[ -r /proc/meminfo ]]; then
        ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
        s+=$(read_signal hw.ram_gb_rounded "$ram_gb")
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        s+=$(read_signal tz.id "$(timedatectl show -p Timezone --value 2>/dev/null || true)")
    fi
    printf '%s' "$s"
}

fingerprint_mode() {
    local signals fingerprint
    signals=$(collect_signals)
    fingerprint=$(sha256_hex "$signals")
    mkdir -p "$(dirname "$STATE_PATH")"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$fingerprint" "$signals" "$now" "$STATE_PATH" <<'PY'
import json
import os
import sys
fp, signals, ts, state_path = sys.argv[1:5]
out = {
    "fingerprint": fp,
    "generated_at": ts,
    "platform": "linux",
    "signal_count": len([p for p in signals.split(";") if p]),
}
print(json.dumps(out, indent=2))
state = {"last_fingerprint": fp, "last_seen": ts, "history": []}
if os.path.isfile(state_path):
    try:
        with open(state_path, encoding="utf-8") as f:
            state = json.load(f)
    except (json.JSONDecodeError, OSError):
        pass
hist = state.get("history", [])
hist.append({"fingerprint": fp, "at": ts})
state["history"] = hist[-50:]
state["last_fingerprint"] = fp
state["last_seen"] = ts
os.makedirs(os.path.dirname(state_path), exist_ok=True)
with open(state_path, "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY
    else
        cat <<EOF
{
  "fingerprint": "$fingerprint",
  "generated_at": "$now",
  "platform": "linux"
}
EOF
    fi
}

reset_machine_id_mode() {
    if [[ $EUID -ne 0 ]]; then
        echo "ResetMachineId requires root. Run: sudo $0 ResetMachineId" >&2
        exit 1
    fi
    local etc_id="/etc/machine-id"
    if [[ -f "$etc_id" ]]; then
        cp -f "$etc_id" "${etc_id}.backup"
        echo "Backup: ${etc_id}.backup"
    fi
    if command -v systemd-machine-id-setup >/dev/null 2>&1; then
        rm -f "$etc_id"
        systemd-machine-id-setup
    elif command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen --ensure="$etc_id"
    else
        echo "No systemd-machine-id-setup or dbus-uuidgen available." >&2
        exit 1
    fi
    local dbus_id="/var/lib/dbus/machine-id"
    if [[ -e "$dbus_id" && ! -L "$dbus_id" ]]; then
        rm -f "$dbus_id"
    fi
    command -v dbus-uuidgen >/dev/null 2>&1 && dbus-uuidgen --ensure >/dev/null 2>&1 || true
    echo "System machine-id reset. New value:"
    cat "$etc_id"
    echo ""
    echo "A reboot may be required for all services to pick up the new ID."
}

case "$MODE" in
    -h|--help|help)
        usage
        exit 0
        ;;
    Fingerprint|fingerprint)
        fingerprint_mode
        ;;
    ResetMachineId|reset|Reset)
        reset_machine_id_mode
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        usage
        exit 1
        ;;
esac
