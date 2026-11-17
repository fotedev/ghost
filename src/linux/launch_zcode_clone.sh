#!/usr/bin/env bash
# ZCode multi-instance clone launcher for Linux (GHOST v0.1, PR 8 of the
# 2026-11-17 parity build-out).
#
# Phase-0 research (2026-11-17, vendored ZCode/ tree - evidence-cited):
#   - Linux desktop builds are REAL (packages/desktop/electron-builder
#     config carries linux targets; executableName "zcode").
#   - Every isolation lever the Windows launcher uses is PLATFORM-
#     INDEPENDENT app code (packages/desktop/src/main/desktopRuntimeEnv.ts):
#       ZCODE_DESKTOP_HOME_DIR / ZCODE_DESKTOP_USER_DATA_DIR /
#       ZCODE_DESKTOP_SESSION_DATA_DIR  (desktop main), and the CLI side
#       honors ZCODE_HOME (~/.zcode root override, config-factory.ts +
#       runtimeEnv line ~528) + ZCODE_DATA_BASE_DIR - so a Linux clone is
#       redirected with the SAME five levers, minus the Windows-only HOME
#       override (ZCODE_HOME is the cleaner CLI root there).
#   - Identity: NO AppUserModel.ID on Linux (no property store) - clone
#     identity = window title (ZCODE_INSTANCE_NAME via the one-time asar
#     patch, platform-independent JS) + the per-color .desktop Name/Icon.
#     Taskbar grouping is not a Linux concept.
#
# Layout (FROZEN plumbing - mirrors the Windows launcher exactly):
#   clone home      ~/ZCode<Name>Home        (Second..Sixth = Blue..Orange)
#   CLI store       <home>/.zcode            (ZCODE_HOME + DATA_BASE_DIR)
#   desktop userData ~/ZCode-<Name>          (USER_DATA_DIR)
#   session dir     ~/ZCode-<Name>/session   (SESSION_DATA_DIR)
#
# First run: seed <home>/.zcode from the Primary's ~/.zcode (rsync/cp with
# the live-lock excludes) + identity scrub via the GHOST Python core when
# available (a clone must NEVER run on Primary identity - the Windows seed
# rule; without the core the launch FAILS CLOSED). Marker gates .zcode-
# seeding/.zcode-seeded mirror the Windows launcher. The Primary must be
# CLOSED during a first seed (its ~/.zcode holds the shared CLI db).
#
# DERIVED (printed loudly): the Linux running layout (window anatomy,
# .desktop integration) and the app binary location. --zcode-bin pins the
# binary; otherwise PATH + the common install roots are probed.
#
# Usage:
#   ./launch_zcode_clone.sh --instance Second [--zcode-bin /path/zcode] [--no-seed-scrub]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "ZCode Clone Launcher (Linux)" "0.1"

INSTANCE=""
ZCODE_BIN=""
NO_SEED_SCRUB=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance)  INSTANCE="$2"; shift 2 ;;
        --zcode-bin) ZCODE_BIN="$2"; shift 2 ;;
        --no-seed-scrub) NO_SEED_SCRUB=1; shift ;;
        *) err "unknown argument: $1"; exit 1 ;;
    esac
done
if [[ -z "$INSTANCE" ]]; then
    err "--instance is required (Second|Third|Fourth|Fifth|Sixth)"
    exit 1
fi

# Frozen instance map (MUST stay in sync with the Windows launcher + the
# shortcuts installers: Home/UserData names are shared cross-platform).
declare -A CLONE_HOME_NAME=( [Second]=ZCodeSecondHome [Third]=ZCodeThirdHome [Fourth]=ZCodeFourthHome [Fifth]=ZCodeFifthHome [Sixth]=ZCodeSixthHome )
declare -A CLONE_USERDATA_NAME=( [Second]=ZCode-Second [Third]=ZCode-Third [Fourth]=ZCode-Fourth [Fifth]=ZCode-Fifth [Sixth]=ZCode-Sixth )
declare -A CLONE_COLOR=( [Second]=Blue [Third]=Yellow [Fourth]=Green [Fifth]=Red [Sixth]=Orange )
declare -A CLONE_AUMID_SUFFIX=( [Second]=2 [Third]=3 [Fourth]=4 [Fifth]=5 [Sixth]=6 )
if [[ -z "${CLONE_HOME_NAME[$INSTANCE]:-}" ]]; then
    err "unknown instance '$INSTANCE' (known: Second Third Fourth Fifth Sixth)"
    exit 1
fi

CLONE_HOME="$HOME/${CLONE_HOME_NAME[$INSTANCE]}"
CLONE_CLI="$CLONE_HOME/.zcode"
CLONE_USERDATA="$HOME/${CLONE_USERDATA_NAME[$INSTANCE]}"
CLONE_SESSION="$CLONE_USERDATA/session"
BRANDING_DIR="$SCRIPT_DIR/../tools/zcode-${CLONE_COLOR[$INSTANCE],,}-branding"

# Binary resolve: --zcode-bin wins, then PATH, then the common install roots
# (DERIVED - AppImage extract locations vary by distro).
resolve_zcode_bin() {
    if [[ -n "$ZCODE_BIN" ]]; then
        [[ -x "$ZCODE_BIN" ]] || { err "--zcode-bin not executable: $ZCODE_BIN"; exit 1; }
        return 0
    fi
    if command -v zcode >/dev/null 2>&1; then ZCODE_BIN="$(command -v zcode)"; return 0; fi
    local cand
    for cand in /opt/ZCode*/zcode /opt/zcode*/zcode /usr/local/bin/zcode \
                "$HOME/Applications/zcode" "$HOME/.local/bin/zcode"; do
        if [[ -x "$cand" ]]; then ZCODE_BIN="$cand"; return 0; fi
    done
    err "zcode binary not found - pass --zcode-bin /path/to/zcode (DERIVED probe looked in PATH + /opt + user bins)."
    return 1
}

# ── Primary-closed gate (the shared CLI db is held by EVERY running instance)
PRIMARY_CLOSED_WAIT=180
if pgrep -x zcode >/dev/null 2>&1 || pgrep -f '[Z]Code' >/dev/null 2>&1; then
    if [[ ! -f "$CLONE_HOME/.zcode-seeded" ]]; then
        warn "A ZCode instance is RUNNING - the first seed copies ~/.zcode (held by"
        warn "every running instance). Waiting up to ${PRIMARY_CLOSED_WAIT}s for it to close..."
        waited=0
        while (( waited < PRIMARY_CLOSED_WAIT )); do
            pgrep -x zcode >/dev/null 2>&1 || pgrep -f '[Z]Code' >/dev/null 2>&1 || break
            sleep 5; waited=$((waited + 5))
        done
        if pgrep -x zcode >/dev/null 2>&1 || pgrep -f '[Z]Code' >/dev/null 2>&1; then
            err "Primary still running after ${PRIMARY_CLOSED_WAIT}s - FAILING CLOSED."
            err "First-time multi-clone seeding is one at a time: close ZCode, then relaunch."
            exit 1
        fi
    else
        warn "a ZCode instance is running - continuing (clone already seeded)."
    fi
fi

# ── Identity scrub (clone must never run on Primary identity) ───────────
scrub_clone_identity() {
    # Same stores as reset_zcode.sh v0.2's CLI steps, rooted at the clone.
    # Uses the shared core; $1 = the clone's .zcode root.
    local cli_root="$1"
    local backup_root
    backup_root="$CLONE_HOME/ID_Backups/$(timestamp)"
    mkdir -p "$backup_root"
    RESTORE_ENTRIES=()
    audit_init "$backup_root"
    local pass=0 fail=0 new_id
    new_id=$(generate_uuid)
    local ts="$cli_root/v2/telemetry-state.json"
    local cred="$cli_root/v2/credentials.json"
    local setting="$cli_root/v2/setting.json"
    if [[ -f "$ts" ]] \
        && core_json_set_kv "$ts" "telemetry-state" "deviceMid" "\"$new_id\"" \
        && verify_json_keys "$ts" "deviceMid=$new_id"; then
        audit_line "$AUDIT_FILE" "$ts" "-" "$new_id" 1; pass=$((pass + 1))
    elif [[ -f "$ts" ]]; then
        audit_line "$AUDIT_FILE" "$ts" "-" "failed" 0; fail=$((fail + 1))
    fi
    if [[ -f "$cred" ]] \
        && core_backup "$cred" "$backup_root" "credentials" >/dev/null \
        && python3 "$GHOST_CLI_PATH" json-remove "$cred" "$backup_root" "credentials-oauth" \
            "$(b64_remove_payload '["zcodejwttoken"]' '["oauth:"]')"; then
        audit_line "$AUDIT_FILE" "$cred" "-" "oauth-cleared" 1; pass=$((pass + 1))
    elif [[ -f "$cred" ]]; then
        audit_line "$AUDIT_FILE" "$cred" "-" "failed" 0; fail=$((fail + 1))
    fi
    if [[ -f "$setting" ]] \
        && core_json_set_kv "$setting" "setting-json" \
            "webRemoteControlExternalRelayDevice.deviceSid" "\"$new_id\"" \
        && verify_json_keys "$setting" "webRemoteControlExternalRelayDevice.deviceSid=$new_id"; then
        audit_line "$AUDIT_FILE" "$setting" "-" "$new_id" 1; pass=$((pass + 1))
    elif [[ -f "$setting" ]]; then
        audit_line "$AUDIT_FILE" "$setting" "-" "failed" 0; fail=$((fail + 1))
    fi
    emit_restore_script "$backup_root" >/dev/null
    (( fail == 0 )) || { err "seed identity scrub FAILED ($fail store(s)) - see $AUDIT_FILE"; return 1; }
    ok "seed identity scrub verified ($pass store(s))."
    return 0
}

# ── First-run seed ───────────────────────────────────────────────────────
if [[ ! -f "$CLONE_HOME/.zcode-seeded" ]]; then
    if [[ -f "$CLONE_HOME/.zcode-seeding" ]]; then
        warn "stale .zcode-seeding marker from an aborted seed - re-clearing and re-seeding."
        rm -f "$CLONE_HOME/.zcode-seeding"
        rm -rf "$CLONE_CLI"
    fi
    if [[ ! -d "$HOME/.zcode" ]]; then
        err "the Primary's ~/.zcode does not exist - nothing to seed from."
        exit 1
    fi
    touch "$CLONE_HOME/.zcode-seeding"
    mkdir -p "$CLONE_HOME" "$CLONE_USERDATA" "$CLONE_SESSION"
    info "seeding $CLONE_CLI from ~/.zcode (excluding live locks)..."
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude 'cli/db/db.sqlite*' --exclude 'v2/tasks-index.sqlite*' \
            "$HOME/.zcode/" "$CLONE_CLI/"
    else
        cp -a "$HOME/.zcode" "$CLONE_CLI"
        rm -f "$CLONE_CLI/cli/db/db.sqlite"* "$CLONE_CLI/v2/tasks-index.sqlite"* 2>/dev/null || true
    fi
    if [[ "$NO_SEED_SCRUB" -eq 1 ]]; then
        warn "--no-seed-scrub: identity scrub SKIPPED (dev escape hatch - never ship this flag to a real launch)."
    else
        resolve_ghost_cli || {
            err "GHOST Python core unavailable - the seed identity scrub cannot run."
            err "A clone must NEVER run on Primary identity - FAILING CLOSED."
            rm -f "$CLONE_HOME/.zcode-seeding"
            exit 1
        }
        if ! scrub_clone_identity "$CLONE_CLI"; then
            rm -f "$CLONE_HOME/.zcode-seeding"
            exit 1
        fi
    fi
    rm -f "$CLONE_HOME/.zcode-seeding"
    touch "$CLONE_HOME/.zcode-seeded"
    ok "seed complete (.zcode-seeded marker written)."
else
    info "clone already seeded ($CLONE_HOME/.zcode-seeded present)."
    mkdir -p "$CLONE_USERDATA" "$CLONE_SESSION"
fi

# ── Branding seed (per-color icons for .desktop integration) ─────────────
BRAND_DEST="$CLONE_HOME/branding"
if [[ -d "$BRANDING_DIR" ]] && [[ ! -f "$BRAND_DEST/tray_icon.ico" ]]; then
    mkdir -p "$BRAND_DEST"
    cp -f "$BRANDING_DIR"/tray_icon.ico "$BRAND_DEST/" 2>/dev/null || true
    cp -f "$BRANDING_DIR"/icon_windows.png "$BRAND_DEST/" 2>/dev/null || true
fi

# ── Launch (detached; identity via env - no property store on Linux) ────
resolve_zcode_bin
export ZCODE_HOME="$CLONE_CLI"
export ZCODE_DATA_BASE_DIR="$CLONE_HOME"
export ZCODE_DESKTOP_USER_DATA_DIR="$CLONE_USERDATA"
export ZCODE_DESKTOP_SESSION_DATA_DIR="$CLONE_SESSION"
export ZCODE_DESKTOP_HOME_DIR="$CLONE_HOME"
export ZCODE_AUMID_SUFFIX="${CLONE_AUMID_SUFFIX[$INSTANCE]}"
export ZCODE_INSTANCE_NAME="ZCode ${CLONE_COLOR[$INSTANCE]}"
if [[ -f "$BRAND_DEST/icon_windows.png" ]]; then
    export ZCODE_ICON_DIR="$BRAND_DEST"
fi
warn "PROVENANCE: the Linux running layout is DERIVED (no live Linux host"
warn "verified yet) - window identity rides ZCODE_INSTANCE_NAME + the asar"
warn "patch; taskbar grouping does not exist on Linux."

LOG_DIR="$SCRIPT_DIR/../tools/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launch_zcode_${INSTANCE}_linux.log"
nohup "$ZCODE_BIN" >>"$LOG_FILE" 2>&1 &
disown
NEW_PID=$!
sleep 3
if kill -0 "$NEW_PID" 2>/dev/null; then
    ok "launched pid $NEW_PID (ZCode ${CLONE_COLOR[$INSTANCE]})."
    dim "env: ZCODE_HOME=$ZCODE_HOME USER_DATA=$CLONE_USERDATA"
    dim "log: $LOG_FILE"
else
    err "launch FAILED within 3s - check $LOG_FILE"
    exit 1
fi
