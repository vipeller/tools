#!/usr/bin/env bash
#
# discover_env.sh — discover the AIO-related resources in a given
# subscription + resource group and print a block of `export` lines
# suitable for `eval`-ing into your shell.
#
# Usage:
#   ./discover_env.sh <subscription-id> <resource-group>
#   SUBSCRIPTION_ID=... RESOURCE_GROUP=... ./discover_env.sh
#
# Typical workflow:
#   eval "$(./discover_env.sh <sub> <rg>)"
#
# What it discovers:
#   * The newest Microsoft.IoTOperations/instances in the RG
#     (→ INSTANCE_NAME, LOCATION).
#   * The newest Microsoft.DeviceRegistry/namespaces in the RG
#     (→ ADR_NAMESPACE_NAME).
#   * The Kubernetes namespace AIO is installed into
#     (defaults to `azure-iot-operations`, override via NAMESPACE).
#
# It does NOT touch Schema Registries, Fabric, or any of the other
# pieces the upstream `aio_gp_test/aio-tools/discover_env.sh` cares
# about — those are out of scope for the OPC simulator workflow.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

SUBSCRIPTION_ID="${1:-${SUBSCRIPTION_ID:-}}"
RESOURCE_GROUP="${2:-${RESOURCE_GROUP:-}}"

if [[ -z "$SUBSCRIPTION_ID" || -z "$RESOURCE_GROUP" ]]; then
  err "Usage: $0 <subscription-id> <resource-group>"
  err "Or set SUBSCRIPTION_ID and RESOURCE_GROUP environment variables."
  exit 1
fi

require_cmd az jq

azlogin "$SUBSCRIPTION_ID" >/dev/null

log "Discovering AIO resources in RG=$RESOURCE_GROUP, SUB=$SUBSCRIPTION_ID…"

# -------- AIO instance --------
log "Looking up Microsoft.IoTOperations/instances…"
AIO_LIST="$(az rest --method get \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.IoTOperations/instances?api-version=${API}" \
  -o json --only-show-errors)"

AIO_COUNT="$(jq -r '.value | length' <<<"$AIO_LIST")"
if [[ "$AIO_COUNT" -eq 0 ]]; then
  err "No Microsoft.IoTOperations/instances found in RG $RESOURCE_GROUP"
  exit 1
fi

# Pick the most-recently created instance — common pattern when an RG
# has been recycled between AIO installs.
INSTANCE_NAME="$(
  jq -r '
    .value
    | sort_by(.systemData.createdAt // "1970-01-01T00:00:00Z")
    | last
    | .name' <<<"$AIO_LIST"
)"
LOCATION="$(jq -r --arg n "$INSTANCE_NAME" '.value[] | select(.name==$n) | .location' <<<"$AIO_LIST")"
ok "AIO instance: $INSTANCE_NAME (location=$LOCATION)"

# -------- ADR namespace --------
log "Looking up Microsoft.DeviceRegistry/namespaces…"
ADR_LIST="$(az rest --method get \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.DeviceRegistry/namespaces?api-version=${API}" \
  -o json --only-show-errors)"
ADR_COUNT="$(jq -r '.value | length' <<<"$ADR_LIST")"
if [[ "$ADR_COUNT" -eq 0 ]]; then
  err "No ADR namespaces found in RG $RESOURCE_GROUP"
  exit 1
fi
ADR_NAMESPACE_NAME="$(jq -r '
  .value
  | sort_by(.systemData.createdAt // "1970-01-01T00:00:00Z")
  | last
  | .name' <<<"$ADR_LIST")"
ok "ADR namespace: $ADR_NAMESPACE_NAME"

# -------- Defaults --------
NAMESPACE="${NAMESPACE:-azure-iot-operations}"

# -------- Print env exports --------
echo >&2
log "Environment discovered. Eval the block below to load it:"
cat <<EOF
export SUBSCRIPTION_ID="$SUBSCRIPTION_ID"
export RESOURCE_GROUP="$RESOURCE_GROUP"
export INSTANCE_NAME="$INSTANCE_NAME"
export LOCATION="$LOCATION"
export ADR_NAMESPACE_NAME="$ADR_NAMESPACE_NAME"
export NAMESPACE="$NAMESPACE"
EOF
