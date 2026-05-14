#!/usr/bin/env bash
#
# onboard_bulk.sh — poll the ADR namespace for discoveredAssets and
# onboard them in bulk. Stops as soon as the requested target count
# of *successful* onboardings has been reached, or when the timeout
# expires (in which case it onboards what it has found so far).
#
# Usage:
#   ./onboard_bulk.sh [--count N] [--timeout SEC] [--prefix PFX]
#                     [--interval SEC]
#
# Required env (run discover_env.sh first):
#   SUBSCRIPTION_ID, RESOURCE_GROUP, INSTANCE_NAME, LOCATION,
#   ADR_NAMESPACE_NAME
#
# Options (all optional):
#   --count N        Stop after onboarding this many assets. Default: 1.
#                     Use a large number with --timeout to "drain" the
#                     namespace.
#   --timeout SEC    Total wall-clock budget. Default: 600 (10 min).
#   --interval SEC   Poll period between discoveredAssets list calls.
#                     Default: 10.
#   --prefix PFX     Only consider discoveredAssets whose name starts
#                     with this prefix. Default: empty (match all).
#
# Exit status:
#   0  — reached --count successful onboardings.
#   1  — timeout expired and < --count assets were successfully onboarded
#        (some may still have been onboarded; see the summary).
#
# Idempotency: assets already present under /assets/ are skipped and
# counted toward the target, so re-running the script is safe.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# shellcheck source=onboard_lib.sh
. "${SCRIPT_DIR}/onboard_lib.sh"

COUNT="${COUNT:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"
PREFIX="${PREFIX:-}"

usage() {
  cat <<'EOF' >&2
Usage: onboard_bulk.sh [options]

Options:
  -c, --count <n>       Target number of successful onboardings (default: 1).
  -t, --timeout <sec>   Wall-clock budget in seconds (default: 600).
  -i, --interval <sec>  Discovery poll interval (default: 10).
  -p, --prefix <pfx>    Only onboard assets with names starting with <pfx>
                        (default: empty -> match every discovered asset).
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--count)    COUNT="$2"; shift 2 ;;
    -t|--timeout)  TIMEOUT_SEC="$2"; shift 2 ;;
    -i|--interval) INTERVAL_SEC="$2"; shift 2 ;;
    -p|--prefix)   PREFIX="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

onboard_init

log "Bulk onboard parameters:"
log "  target count : $COUNT"
log "  timeout      : ${TIMEOUT_SEC}s"
log "  poll interval: ${INTERVAL_SEC}s"
log "  prefix       : ${PREFIX:-<none>}"

# Track which assets we've already processed so a slow connector
# (re-listing the same name twice) doesn't make us double-count.
declare -A SEEN=()
SUCCEEDED=0
FAILED=0
DEADLINE=$(( $(date +%s) + TIMEOUT_SEC ))

while :; do
  # Fetch the current discovered-asset names. This is intentionally
  # done every cycle so newly-discovered assets show up.
  mapfile -t NAMES < <(list_discovered_names "$PREFIX" || true)

  for name in "${NAMES[@]}"; do
    [[ -z "$name" ]] && continue
    [[ -n "${SEEN[$name]:-}" ]] && continue
    SEEN["$name"]=1

    if already_onboarded "$name"; then
      ok "Asset '$name' already onboarded — counting it toward the target."
      (( SUCCEEDED++ )) || true
    elif onboard_one_asset "$name"; then
      (( SUCCEEDED++ )) || true
    else
      err "Failed to onboard '$name'"
      (( FAILED++ )) || true
    fi

    if (( SUCCEEDED >= COUNT )); then
      break
    fi
  done

  if (( SUCCEEDED >= COUNT )); then
    break
  fi

  NOW=$(date +%s)
  if (( NOW >= DEADLINE )); then
    err "Timed out after ${TIMEOUT_SEC}s — onboarded ${SUCCEEDED}/${COUNT}."
    log "Summary: succeeded=${SUCCEEDED} failed=${FAILED} discovered=${#SEEN[@]}"
    exit 1
  fi

  REMAIN=$(( DEADLINE - NOW ))
  log "Onboarded ${SUCCEEDED}/${COUNT} so far (discovered=${#SEEN[@]}, failed=${FAILED}). Sleeping ${INTERVAL_SEC}s (~${REMAIN}s left)…"
  sleep "$INTERVAL_SEC"
done

log "-------- Summary --------"
log "  Discovered    : ${#SEEN[@]}"
log "  Succeeded     : $SUCCEEDED"
log "  Failed        : $FAILED"
ok "Reached target of $COUNT successful onboarding(s)."
