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

# ── GHOST banner ────────────────────────────────────────────────────────
# Usage: show_banner [target] [version]
show_banner() {
    local target="${1:-Identity Reset}"
    local version="${2:-}"
    local target_label="$target"
    [[ -n "$version" ]] && target_label="$target (v$version)"

    local priv_label="USER" priv_color="$YELLOW"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        priv_label="ROOT"
        priv_color="$GREEN"
    fi

    local -a ghost_logo=(
        '  ____ _   _  ___  ____ _____ '
        ' / ___| | | |/ _ \/ ___|_   _|'
        '| |  _| |_| | | | \___ \ | |  '
        '| |_| |  _  | |_| |___) || |  '
        ' \____|_| |_|\___/|____/ |_|  '
    )

    local -a ghost_side=(
        "${WHITE}Guided Hardware & OS Scrubbing Toolkit${NC}"
        "${CYAN}Target : ${target_label}${NC}"
        "${priv_color}Privs  : [${priv_label}]${NC}"
        "${GRAY}Status : Ready${NC}"
    )

    echo ""
    echo -e "${CYAN}${ghost_logo[0]}${NC}"
    local i padded
    for ((i = 1; i < 5; i++)); do
        printf -v padded '%-31s' "${ghost_logo[$i]}"
        echo -e "${CYAN}${padded}${NC}  ${ghost_side[$((i - 1))]}"
    done
    echo ""
}

# ── ID generation ───────────────────────────────────────────────────────
generate_uuid() {
    uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

generate_hex() {
    local bytes="${1:-32}"
    openssl rand -hex "$bytes" 2>/dev/null || head -c "$bytes" /dev/urandom | xxd -p -c "$bytes"
}

# ── Helpers ─────────────────────────────────────────────────────────────
timestamp() {
    date +%Y%m%d_%H%M%S
}

has_python3() {    command -v python3 >/dev/null 2>&1
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
        local dest
        dest="$dir/${label}_$(timestamp).backup"
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
# Exported: callers (reset_cursor.sh / reset_windsurf.sh) read it after
# sourcing this library, and ShellCheck needs the export to see that.
export SYSTEM_MACHINE_ID_SKIPPED=false

reset_system_machine_id() {
    export SYSTEM_MACHINE_ID_SKIPPED=false
    local etc_id="/etc/machine-id"
    local dbus_id="/var/lib/dbus/machine-id"

    if [[ $EUID -ne 0 ]]; then
        export SYSTEM_MACHINE_ID_SKIPPED=true
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
    if command -v dbus-uuidgen >/dev/null 2>&1; then
        dbus-uuidgen --ensure >/dev/null 2>&1 || true
    fi

    ok "Updated system machine-id."
    if [[ -f "$etc_id" ]]; then
        dim "New machine-id: $(cat "$etc_id")"
    fi
}

# ── GHOST Python core bridge (2026-11-14) ───────────────────────────────
# The shared store-mutation logic lives in src/python/ghost (ONE copy for
# Windows + Linux). Linux resets resolve it repo-relative and route every
# mutation through the core verbs (base64 payload in, JSON report out);
# without python3 or the core file, callers fall back to their inline
# python3 heredocs - reported loudly, never silent.
GHOST_CLI_PATH=""

resolve_ghost_cli() {
    # Sets GHOST_CLI_PATH to the repo's ghost_cli.py when BOTH python3 and
    # the file exist; returns 1 otherwise (callers decide the fallback).
    if ! has_python3; then
        return 1
    fi
    local candidate="$SCRIPT_DIR/../python/ghost_cli.py"
    candidate="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
    if [[ -f "$candidate" ]]; then
        GHOST_CLI_PATH="$candidate"
        return 0
    fi
    return 1
}

b64_payload() {
    # Compact JSON on stdin -> base64 (no line breaks; GNU + busybox safe).
    base64 -w0 2>/dev/null || base64
}

core_backup() {
    # Backup via the core's timestamped-dir verb (lock retries + verify),
    # falling back to a plain copy. Echoes the backup destination, or
    # nothing when the source is absent. RESTORE_ENTRIES must be an array
    # declared by the caller.
    local src="$1" backup_root="$2" label="$3"
    if [[ ! -e "$src" ]]; then
        return 0
    fi
    if [[ -n "$GHOST_CLI_PATH" ]]; then
        local out
        if out=$(python3 "$GHOST_CLI_PATH" backup "$src" "$backup_root" "$label" 2>/dev/null); then
            local dest
            dest=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('destination',''))" "$out" 2>/dev/null || true)
            if [[ -n "$dest" ]]; then
                RESTORE_ENTRIES+=("$dest|$src")
                echo "$dest"
                return 0
            fi
        fi
        warn "core backup FAILED for $src - plain-copy fallback"
    fi
    local dest
    dest="$backup_root/${label}_$(timestamp).backup"
    mkdir -p "$backup_root"
    cp -f "$src" "$dest"
    RESTORE_ENTRIES+=("$dest|$src")
    echo "$dest"
}

# ── Audit (JSONL) ───────────────────────────────────────────────────────
AUDIT_FILE=""

audit_init() {
    # $1 = backup root; creates audit_<ts>.jsonl inside it.
    AUDIT_FILE="$1/audit_$(timestamp).jsonl"
    mkdir -p "$1"
    : > "$AUDIT_FILE"
}

audit_line() {
    # audit_line <file> <key> <before> <after> <ok:0|1> [detail]
    local file="$1" key="$2" before="$3" after="$4" okflag="$5" detail="${6:-}"
    [[ -n "$file" ]] || return 0
    if has_python3; then
        python3 - "$file" "$key" "$before" "$after" "$okflag" "$detail" <<'PY'
import json, sys
path, key, before, after, okflag, detail = sys.argv[1:7]
entry = {"key": key, "before": before, "after": after, "ok": okflag == "1", "detail": detail}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry) + "\n")
PY
    else
        printf '%s|%s|%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$before" "$after" "$okflag" "$detail" >> "$file"
    fi
}

# ── Restore script emission ─────────────────────────────────────────────
RESTORE_ENTRIES=()

emit_restore_script() {
    # $1 = backup root. Writes restore.sh (copies every backup back to its
    # original path) from the RESTORE_ENTRIES collected during the run.
    local backup_root="$1"
    local script_path="$backup_root/restore.sh"
    {
        echo '#!/usr/bin/env bash'
        echo '# GHOST auto-generated restore script - copies the backups in this'
        echo '# ID_Backups directory back over the live files. Review, then run.'
        echo 'set -euo pipefail'
        local entry dest orig
        for entry in "${RESTORE_ENTRIES[@]}"; do
            dest="${entry%%|*}"
            orig="${entry#*|}"
            printf 'mkdir -p "$(dirname %q)"\n' "$orig"
            printf 'cp -f %q %q\n' "$dest" "$orig"
        done
        echo 'echo "Restore complete."'
    } > "$script_path"
    chmod +x "$script_path" 2>/dev/null || true
    echo "$script_path"
}

# ── Verify-after (never silent success) ─────────────────────────────────
verify_json_keys() {
    # verify_json_keys <file> <key=value> [...] - re-reads the JSON file and
    # compares every pair; returns 0 only when ALL match. Prints mismatches.
    local file="$1"
    shift
    if ! has_python3; then
        warn "python3 not found - verify-after SKIPPED for $file (unverified write!)"
        return 1
    fi
    python3 - "$file" "$@" <<'PY'
import json, sys
path, pairs = sys.argv[1], sys.argv[2:]
with open(path, encoding="utf-8-sig") as f:
    data = json.load(f)
bad = []
for pair in pairs:
    key, _, expected = pair.partition("=")
    actual = data
    for part in key.split("."):
        if not isinstance(actual, dict) or part not in actual:
            actual = None
            break
        actual = actual[part]
    if actual != expected:
        bad.append("%s (expected %r, got %r)" % (key, expected, actual))
if bad:
    print("VERIFY FAILED for %s: %s" % (path, "; ".join(bad)))
    sys.exit(1)
PY
}

verify_file_value() {
    # verify_file_value <file> <expected> - text file re-read compare.
    local file="$1" expected="$2"
    [[ -f "$file" ]] || { echo "VERIFY FAILED: $file missing"; return 1; }
    local actual
    actual=$(tr -d '[:space:]' < "$file")
    if [[ "$actual" != "$(printf '%s' "$expected" | tr -d '[:space:]')" ]]; then
        echo "VERIFY FAILED: $file does not hold the written value"
        return 1
    fi
}
