#!/usr/bin/env bash
# ZCode LIGHT headless worker for Linux (GHOST v0.1, PR 8 of the 2026-11-17
# parity build-out) - the launch_zcode_cli_light.ps1 pattern: run the
# bundled CLI (resources/glm/zcode.cjs) under system node with the
# clone-home env levers, ~0.9 GB commit instead of a full desktop instance.
#
# VERIFIED LIMITS carried over from the Windows light worker
# (docs/ZCODE_LIGHT_MODE.md): the interactive TUI cannot run standalone
# (the @zcode/tui resolves only inside the app's Electron runtime), and a
# home without its own `zcode login zai` runs tasks on the FREE
# opencode-zen model, not the Start Plan - the one-time login recipe is
# printed below.
#
# DERIVED (printed loudly): the Linux app install layout. The zcode.cjs
# bundle lives under <install>/resources/glm/ in the desktop package;
# pass --app-dir when auto-detect misses (AppImage extract paths vary).
#
# Usage:
#   ./launch_zcode_cli_light.sh --instance Second [--app-dir /opt/ZCode] [-p "prompt"]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

show_banner "ZCode Light Worker (Linux)" "0.1"

INSTANCE=""
APP_DIR=""
PROMPT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance) INSTANCE="$2"; shift 2 ;;
        --app-dir)  APP_DIR="$2"; shift 2 ;;
        -p)         PROMPT="$2"; shift 2 ;;
        *) err "unknown argument: $1"; exit 1 ;;
    esac
done
if [[ -z "$INSTANCE" ]]; then
    err "--instance is required (Second|Third|Fourth|Fifth|Sixth)"
    exit 1
fi

declare -A CLONE_HOME_NAME=( [Second]=ZCodeSecondHome [Third]=ZCodeThirdHome [Fourth]=ZCodeFourthHome [Fifth]=ZCodeFifthHome [Sixth]=ZCodeSixthHome )
if [[ -z "${CLONE_HOME_NAME[$INSTANCE]:-}" ]]; then
    err "unknown instance '$INSTANCE'"
    exit 1
fi
CLONE_HOME="$HOME/${CLONE_HOME_NAME[$INSTANCE]}"
CLONE_CLI="$CLONE_HOME/.zcode"

# App resolve: --app-dir wins, then the common Linux roots (DERIVED).
if [[ -z "$APP_DIR" ]]; then
    for cand in /opt/ZCode /opt/zcode /usr/local/ZCode /usr/local/zcode \
                "$HOME/.local/opt/ZCode"; do
        if [[ -d "$cand/resources/glm" ]]; then APP_DIR="$cand"; break; fi
    done
fi
if [[ -z "$APP_DIR" || ! -f "$APP_DIR/resources/glm/zcode.cjs" ]]; then
    err "zcode.cjs bundle not found - pass --app-dir /path/to/install"
    err "(the bundle is <install>/resources/glm/zcode.cjs; AppImage users:"
    err "extract or mount the image first - DERIVED probe missed it)."
    exit 1
fi
command -v node >/dev/null 2>&1 || { err "node not found in PATH - install Node.js >= 18."; exit 1; }

if [[ ! -d "$CLONE_CLI" ]]; then
    err "clone CLI store missing: $CLONE_CLI - launch the desktop clone once"
    err "(launch_zcode_clone.sh --instance $INSTANCE) to seed it first."
    exit 1
fi

export ZCODE_HOME="$CLONE_CLI"
export ZCODE_DATA_BASE_DIR="$CLONE_HOME"
export ZCODE_STORAGE_DIR="$CLONE_HOME/.zcode-storage"
# The desktop-userData levers are irrelevant headless (no Electron) - the
# CLI resolves its state from ZCODE_HOME / ZCODE_DATA_BASE_DIR only.
# The builtin provider config lever (the Windows FIFTH lever, CLI >= 0.17.1):
# prefer the clone's app bundle copy over a runtime-cache fallback.
if [[ -f "$APP_DIR/resources/config/provider/zcode-builtin.json" ]]; then
    export ZCODE_BUILTIN_PROVIDER_CONFIG_FILE="$APP_DIR/resources/config/provider/zcode-builtin.json"
fi

warn "PROVENANCE: DERIVED - the Linux light-worker shape mirrors the"
warn "Windows-verified five env levers; no Linux host has live-run it yet."

if [[ -f "$CLONE_CLI/cli/.logged-in-marker" ]]; then
    info "clone account: logged-in marker present"
else
    warn "this home has no standalone login - tasks run on the FREE"
    warn "opencode-zen model, NOT the Start Plan. One-time login recipe:"
    warn "  cd $APP_DIR && ZCODE_HOME='$CLONE_CLI' node resources/glm/zcode.cjs login zai"
fi

# Light-worker PID-marker contract (the Windows ghost_light_marker.ps1
# twin): one JSON marker per clone home for the whole worker run, removed on
# exit. The shell pid ($$) is the liveness sentinel - node runs in the
# FOREGROUND (no exec, so the EXIT trap can clean up), and a hard kill that
# skips the trap leaves a stale marker the readers treat as not-running.
WORKER_MODE="repl"
if [[ -n "$PROMPT" ]]; then WORKER_MODE="prompt"; fi
MARKER="$CLONE_HOME/.ghost-light-worker.json"
printf '{"suite":"zcode","instance":"%s","pid":%d,"mode":"%s","startedAt":"%s"}\n' \
    "$INSTANCE" "$$" "$WORKER_MODE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
trap 'rm -f "$MARKER"' EXIT

if [[ -n "$PROMPT" ]]; then
    node "$APP_DIR/resources/glm/zcode.cjs" -p "$PROMPT" --mode cli --cwd "$PWD"
else
    info "interactive REPL on the clone's own state - empty input exits."
    node "$APP_DIR/resources/glm/zcode.cjs" --mode cli --cwd "$PWD"
fi
