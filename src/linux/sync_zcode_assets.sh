#!/usr/bin/env bash
# ZCode clone MCP definitions sync - Linux (v0.1, MCP-ONLY).
# ghost.sh option 13 (2026-11-17).
#
# The Linux twin of the Windows sync_zcode_assets.ps1 MCP area
# (definitions-only): Primary ~/.zcode/cli/config.json is READ-ONLY; every
# clone's <CloneHome>/.zcode/cli/config.json gains the Primary's mcp.servers
# definitions via the core json-merge-defs verb (ghost/json_merge.py) -
# Primary definitions win, the clone-local per-server `enabled` toggle
# survives, clone-only servers are kept, the Primary is never mutated.
#
# SCOPE v0.1 (deliberate, mirrors how the Windows CS-1 sync shipped first):
# MCP definitions ONLY. The Windows tool's other areas (skills move-aside,
# .agents junction, plugin-cache mirror, installed_plugins.json rewrite)
# are NOT ported yet - they need live-layout evidence from a Linux host
# (LC-1 in docs/TASK_BACKLOG.md) before porting; the skills/.agents/
# plugin-cache shapes are Windows-specific mechanics (junctions, robocopy)
# whose Linux analogs (symlink, rsync) are unproven on the real layout.
#
# RUNNING-INSTANCE NOTE: no running-instance guard by design - the MCP
# area is the Windows-verified safe one (the app holds no handle on
# config.json, never rewrites it on exit, and re-reads mcp.servers at
# every app-server spawn = every new session; verified 2026-10-27 across
# all six instances + app.asar). A synced definition lands on each
# running clone's NEXT session; that is the same contract the Windows
# -McpOnly mode honors.
#
# Usage:
#   ./sync_zcode_assets.sh                       # all five clones
#   ./sync_zcode_assets.sh --instance Second     # one clone (Second..Sixth)
#
# Every write: backup (core backup verb) -> merge -> verify-after re-read
# -> JSONL audit at <CloneHome>/.zcode/asset-sync-audit.jsonl (key NAMES
# only - values never land in the audit). A config-less clone (first run
# anonymous) is a loud SKIP, never a failure.
set -euo pipefail

SYNC_INSTANCE="All"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Source BEFORE arg parsing: the shared ok/warn/err helpers must exist for
# the unknown-argument branch (sourcing after parsing would make an early
# err call a missing-function death under set -e - the b64_json lesson).
# shellcheck source=src/linux/id_reset_common.sh
source "$SCRIPT_DIR/id_reset_common.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance) SYNC_INSTANCE="$2"; shift 2 ;;
        --dry-run) SYNC_DRY_RUN=1; shift ;;
        *) err "unknown argument: $1"; exit 1 ;;
    esac
done
SYNC_DRY_RUN="${SYNC_DRY_RUN:-0}"

show_banner "ZCode Clone MCP Sync (definitions-only)" "0.1"

resolve_ghost_cli || {
    err "GHOST Python core unavailable (python3 or src/python/ghost_cli.py missing)."
    err "The merge rides the core json-merge-defs verb - aborting instead of guessing."
    exit 1
}

# Frozen clone layout - MUST match launch_zcode_clone.sh's CLONE_HOME_NAME
# map (the plumbing is frozen cross-platform per the clone-dirs decision;
# duplicated here on purpose + pinned by tests/linux_clone_layer.Tests.ps1).
declare -A CLONE_HOME_NAME=( [Second]=ZCodeSecondHome [Third]=ZCodeThirdHome [Fourth]=ZCodeFourthHome [Fifth]=ZCodeFifthHome [Sixth]=ZCodeSixthHome )

if [[ "$SYNC_INSTANCE" != "All" && -z "${CLONE_HOME_NAME[$SYNC_INSTANCE]:-}" ]]; then
    err "unknown --instance '$SYNC_INSTANCE' (known: Second Third Fourth Fifth Sixth All)"
    exit 1
fi

PRIMARY_CFG="$HOME/.zcode/cli/config.json"
if [[ ! -f "$PRIMARY_CFG" ]]; then
    warn "Primary config not found ($PRIMARY_CFG) - nothing to sync from."
    warn "(Launch the ZCode desktop app once, or pass --instance after seeding a clone.)"
    exit 0
fi

failures=0
for name in Second Third Fourth Fifth Sixth; do
    if [[ "$SYNC_INSTANCE" != "All" && "$SYNC_INSTANCE" != "$name" ]]; then
        continue
    fi
    clone_home="$HOME/${CLONE_HOME_NAME[$name]}"
    clone_cfg="$clone_home/.zcode/cli/config.json"
    audit_file="$clone_home/.zcode/asset-sync-audit.jsonl"
    AUDIT_FILE="$audit_file"

    echo ""
    echo "=== $name ==="
    if [[ ! -d "$clone_home" ]]; then
        warn "no clone home - skipped: $clone_home (launch its desktop clone once first)"
        continue
    fi
    if [[ ! -f "$clone_cfg" ]]; then
        warn "config-less clone - skipped (first run anonymous by design): $clone_cfg"
        continue
    fi

    verb_args=(json-merge-defs "$PRIMARY_CFG" "$clone_cfg"
        --base-path mcp.servers --preserve-keys enabled
        --backup-root "$clone_home/.zcode/mcp-sync-backups" --label "mcp-sync-$name")
    if [[ "$SYNC_DRY_RUN" -eq 1 ]]; then
        verb_args+=(--dry-run)
        echo "(dry-run - nothing will be written)"
    fi

    # set -e safety: a verb failure must be COUNTED, not abort the loop -
    # capture inside || true and branch on the parsed verdict.
    verdict=$(python3 "$GHOST_CLI_PATH" "${verb_args[@]}" 2>/dev/null) || true
    ok_flag=$(python3 -c "import json,sys; print('1' if json.loads(sys.argv[1]).get('ok') else '0')" "$verdict" 2>/dev/null || echo 0)
    if [[ "$ok_flag" != "1" ]]; then
        err "$name: merge FAILED - ${verdict:-<no verdict, see stderr of the verb>}"
        audit_line "$AUDIT_FILE" "mcp.servers" "-" "merge-failed" 0
        failures=$((failures + 1))
        continue
    fi

    added=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d['added']), len(d['updated']), len(d['clone_only']))" "$verdict")
    read -r n_added n_updated n_only <<< "$added"
    if [[ "$SYNC_DRY_RUN" -eq 1 ]]; then
        ok "$name: dry-run plan - +$n_added updated=$n_updated clone-only=$n_only (nothing written)"
    elif [[ "$n_added" == "0" && "$n_updated" == "0" ]]; then
        ok "$name: in sync (clone-only servers kept: $n_only)"
    else
        ok "$name: synced +$n_added new, $n_updated updated, $n_only clone-only kept (verify-after passed)"
        audit_line "$AUDIT_FILE" "mcp.servers" "-" "+$n_added/$n_updated" 1
    fi
done

echo ""
if [[ "$failures" -gt 0 ]]; then
    err "$failures clone(s) failed - see the verdicts above."
    exit 1
fi
ok "MCP definitions sync complete (MCP-only scope; skills/plugins areas need LC-1 evidence first)."
