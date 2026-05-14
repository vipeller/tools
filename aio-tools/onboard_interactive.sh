#!/usr/bin/env bash
#
# onboard_interactive.sh — keep polling for discoveredAssets and ask
# the user, one by one, whether to onboard each newly-seen one.
#
# The script never exits on its own; it keeps polling until you hit
# Ctrl-C, answer "q" at a prompt, or pass --max-iterations to bound
# the run.
#
# Usage:
#   ./onboard_interactive.sh [--prefix PFX] [--interval SEC]
#                            [--max-iterations N] [--show-details]
#
# Required env (run discover_env.sh first):
#   SUBSCRIPTION_ID, RESOURCE_GROUP, INSTANCE_NAME, LOCATION,
#   ADR_NAMESPACE_NAME
#
# Per-asset prompt:
#   y    onboard this asset
#   n    skip this asset (won't ask again this run)
#   q    quit the script entirely
#
# By default the prompt shows just the asset name. Pass --show-details
# to also dump the discoveredAsset JSON before each prompt — handy
# when the connector emits many similar assets and you want to pick
# only the interesting ones.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# shellcheck source=onboard_lib.sh
. "${SCRIPT_DIR}/onboard_lib.sh"

PREFIX="${PREFIX:-}"
INTERVAL_SEC="${INTERVAL_SEC:-10}"
MAX_ITER="${MAX_ITER:-0}"          # 0 = unlimited
SHOW_DETAILS=0

usage() {
  cat <<'EOF' >&2
Usage: onboard_interactive.sh [options]

Options:
  -p, --prefix <pfx>          Only consider discoveredAssets with names
                              starting with <pfx>. Default: empty.
  -i, --interval <sec>        Discovery poll interval (default: 10).
      --max-iterations <n>    Stop after polling this many times
                              (0 = run until Ctrl-C or 'q'). Default: 0.
      --show-details          Dump the discoveredAsset JSON before each
                              prompt.
  -h, --help                  Show this help.

Per-asset prompt accepts: y (onboard), n (skip), q (quit).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prefix)         PREFIX="$2"; shift 2 ;;
    -i|--interval)       INTERVAL_SEC="$2"; shift 2 ;;
       --max-iterations) MAX_ITER="$2"; shift 2 ;;
       --show-details)   SHOW_DETAILS=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

onboard_init

log "Interactive onboard parameters:"
log "  prefix         : ${PREFIX:-<none>}"
log "  poll interval  : ${INTERVAL_SEC}s"
log "  max iterations : ${MAX_ITER:-unlimited}"
log "  show details   : ${SHOW_DETAILS}"
log "Press Ctrl-C or answer 'q' to quit at any prompt."

# Track previously-asked names so a still-present discoveredAsset
# doesn't keep prompting forever.
declare -A ASKED=()
ITER=0
ONBOARDED=0
SKIPPED=0
FAILED=0

# Pretty-print the relevant chunk of a discoveredAsset to stderr.
print_details() {
  local name="$1"
  local json
  json="$(az rest --method get \
    --url "${ADR_URL}/discoveredAssets/${name}?api-version=${API}" \
    --only-show-errors 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    warn "  (no details available for '$name')"
    return
  fi
  jq -C '{
    name: .name,
    displayName: .properties.displayName,
    model: .properties.model,
    manufacturer: .properties.manufacturer,
    deviceRef: .properties.deviceRef,
    discoveryId: .properties.discoveryId,
    assetTypeRefs: .properties.assetTypeRefs,
    datasetCount: (.properties.datasets | length? // 0),
    eventGroupCount: (.properties.eventGroups | length? // 0),
    streamCount: (.properties.streams | length? // 0)
  }' <<<"$json" >&2
}

# Prompt the user for each new discovered asset; loop forever (or
# until --max-iterations is hit or the user types 'q').
while :; do
  (( ITER++ )) || true

  mapfile -t NAMES < <(list_discovered_names "$PREFIX" || true)
  NEW_COUNT=0

  for name in "${NAMES[@]}"; do
    [[ -z "$name" ]] && continue
    [[ -n "${ASKED[$name]:-}" ]] && continue

    # Pre-filter: if it's already onboarded just remember it.
    if already_onboarded "$name"; then
      ASKED["$name"]="onboarded"
      log "  '$name' already onboarded — skipping."
      continue
    fi

    (( NEW_COUNT++ )) || true
    echo >&2
    log "Discovered asset: $name"
    if [[ "$SHOW_DETAILS" -eq 1 ]]; then
      print_details "$name"
    fi

    # The TTY is read directly so this works even when stderr/stdout
    # are redirected. If there's no TTY (e.g. piped input), fall back
    # to stdin.
    PROMPT="Onboard '$name'? [y/N/q] "
    if [[ -t 0 ]]; then
      read -r -p "$PROMPT" answer
    else
      read -r answer
      printf '%s%s\n' "$PROMPT" "$answer" >&2
    fi

    case "${answer,,}" in
      y|yes)
        if onboard_one_asset "$name"; then
          ASKED["$name"]="onboarded"
          (( ONBOARDED++ )) || true
        else
          ASKED["$name"]="failed"
          (( FAILED++ )) || true
        fi
        ;;
      q|quit|exit)
        log "User requested quit."
        break 2
        ;;
      *)
        ASKED["$name"]="skipped"
        (( SKIPPED++ )) || true
        log "Skipped '$name'."
        ;;
    esac
  done

  if (( MAX_ITER > 0 && ITER >= MAX_ITER )); then
    log "Reached max iterations ($MAX_ITER)."
    break
  fi

  if (( NEW_COUNT == 0 )); then
    log "Iteration $ITER: no new discovered assets. Sleeping ${INTERVAL_SEC}s…"
  fi
  sleep "$INTERVAL_SEC"
done

log "-------- Summary --------"
log "  Onboarded : $ONBOARDED"
log "  Skipped   : $SKIPPED"
log "  Failed    : $FAILED"
log "  Seen      : ${#ASKED[@]}"
