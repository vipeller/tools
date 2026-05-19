#!/usr/bin/env bash
#
# update_connector_image.sh — patch the OPC UA Commander image in the
# aio-opc-supervisor deployment.
#
# This script updates the environment variable
#   opcuabroker_SupervisorConfiguration__CommanderConfiguration__Image
# in the aio-opc-supervisor deployment to point at a new container
# image, then re-applies the deployment so that the change rolls out.
#
# Usage:
#   ./update_connector_image.sh <new-image>
#   ./update_connector_image.sh --image <new-image> [--namespace <ns>] [--deployment <name>]
#
# Examples:
#   ./update_connector_image.sh \
#       aioconnectorsdev.azurecr.io/aio-connectors/opcua-commander:1.3.0-pullrequest15774076.1866
#
# Required:
#   <new-image>   Fully-qualified image reference for the commander container.
#
# Optional:
#   --namespace / NAMESPACE       K8s namespace (default: azure-iot-operations).
#   --deployment / DEPLOYMENT     Deployment name (default: aio-opc-supervisor).
#   --timeout / TIMEOUT_SECONDS   Rollout wait budget in seconds (default: 300).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

NAMESPACE="${NAMESPACE:-azure-iot-operations}"
DEPLOYMENT="${DEPLOYMENT:-aio-opc-supervisor}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
NEW_IMAGE=""

ENV_VAR_NAME="opcuabroker_SupervisorConfiguration__CommanderConfiguration__Image"

usage() {
  cat <<EOF >&2
Usage: update_connector_image.sh [options] <new-image>

Positional:
  <new-image>                 Fully-qualified image reference for the
                              OPC UA Commander container (required).

Options:
  -i, --image <ref>           Same as positional <new-image>.
  -n, --namespace <ns>        Kubernetes namespace (default: azure-iot-operations).
  -d, --deployment <name>     Deployment name (default: aio-opc-supervisor).
  -t, --timeout <secs>        Rollout wait timeout (default: 300).
  -h, --help                  Show this help.

Environment (lower precedence than flags):
  NAMESPACE, DEPLOYMENT, TIMEOUT_SECONDS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)      NEW_IMAGE="$2"; shift 2 ;;
    -n|--namespace)  NAMESPACE="$2"; shift 2 ;;
    -d|--deployment) DEPLOYMENT="$2"; shift 2 ;;
    -t|--timeout)    TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    -*)              err "Unknown option: $1"; usage; exit 2 ;;
    *)
      # Positional argument — treat as the image if not already set.
      if [[ -z "$NEW_IMAGE" ]]; then
        NEW_IMAGE="$1"; shift
      else
        err "Unexpected argument: $1"; usage; exit 2
      fi
      ;;
  esac
done

if [[ -z "$NEW_IMAGE" ]]; then
  err "A new image reference is required."
  usage
  exit 1
fi

require_cmd kubectl jq

# -------- Verify deployment exists --------
log "Checking for deployment '$DEPLOYMENT' in namespace '$NAMESPACE'…"
if ! kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" >/dev/null 2>&1; then
  err "Deployment '$DEPLOYMENT' not found in namespace '$NAMESPACE'."
  err "Available deployments:"
  kubectl get deployments -n "$NAMESPACE" --no-headers 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
ok "Deployment '$DEPLOYMENT' exists."

# -------- Read current image value --------
OLD_IMAGE="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json \
  | jq -r --arg env "$ENV_VAR_NAME" '
      .spec.template.spec.containers[0].env[]
      | select(.name == $env) | .value // empty
    ')"

if [[ -z "$OLD_IMAGE" ]]; then
  err "Could not find env var '$ENV_VAR_NAME' in deployment '$DEPLOYMENT'."
  exit 1
fi

log "Current commander image:"
log "  $OLD_IMAGE"
log "New commander image:"
log "  $NEW_IMAGE"

if [[ "$OLD_IMAGE" == "$NEW_IMAGE" ]]; then
  ok "Image is already set to the requested value — nothing to do."
  exit 0
fi

# -------- Patch the deployment --------
# Use kubectl's JSON patch to surgically update the env var value.
# First, find the index of the env var in the container's env array.
ENV_INDEX="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o json \
  | jq -r --arg env "$ENV_VAR_NAME" '
      .spec.template.spec.containers[0].env
      | to_entries[]
      | select(.value.name == $env)
      | .key
    ')"

if [[ -z "$ENV_INDEX" ]]; then
  err "Failed to locate env var index for '$ENV_VAR_NAME'."
  exit 1
fi

log "Patching deployment '$DEPLOYMENT' (env index $ENV_INDEX)…"

kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/${ENV_INDEX}/value\",\"value\":\"${NEW_IMAGE}\"}]"

ok "Deployment patched successfully."

# -------- Wait for rollout --------
log "Waiting for rollout to complete (timeout: ${TIMEOUT_SECONDS}s)…"
if kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" \
    --timeout="${TIMEOUT_SECONDS}s"; then
  ok "Rollout complete."
else
  warn "Rollout did not complete within ${TIMEOUT_SECONDS}s."
  warn "Check status with: kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE"
  exit 1
fi

ok "Commander image updated: $OLD_IMAGE → $NEW_IMAGE"
