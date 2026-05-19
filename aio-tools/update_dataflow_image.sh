#!/usr/bin/env bash
#
# update_dataflow_image.sh — patch the dataflow operator image in the
# aio-dataflow-operator StatefulSet.
#
# This script updates the environment variables
#   DEFAULT_CONTAINER_REGISTRY, DEFAULT_REPOSITORY, DEFAULT_CONTAINER_TAG
# in the aio-dataflow-operator StatefulSet to point at a new container
# image, sets DEFAULT_IMAGE_PULL_POLICY to "Always", then re-applies
# the StatefulSet so the change rolls out.
#
# Usage:
#   ./update_dataflow_image.sh <new-image>
#   ./update_dataflow_image.sh --image <new-image> [--namespace <ns>] [--statefulset <name>]
#
# Examples:
#   ./update_dataflow_image.sh \
#       aioconnectorsdev.azurecr.io/aio-dataflows/dataflow-operator:1.4.6-pullrequest12345.42
#
# The image is parsed into its components:
#   aioconnectorsdev.azurecr.io/aio-dataflows/dataflow-operator:1.4.6-pr42
#   ├── registry:   aioconnectorsdev.azurecr.io
#   ├── repository: aio-dataflows/dataflow-operator
#   └── tag:        1.4.6-pr42
#
# Required:
#   <new-image>   Fully-qualified image reference for the dataflow operator.
#
# Optional:
#   --namespace / NAMESPACE         K8s namespace (default: azure-iot-operations).
#   --statefulset / STATEFULSET     StatefulSet name (default: aio-dataflow-operator).
#   --timeout / TIMEOUT_SECONDS     Rollout wait budget in seconds (default: 300).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

NAMESPACE="${NAMESPACE:-azure-iot-operations}"
STATEFULSET="${STATEFULSET:-aio-dataflow-operator}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
NEW_IMAGE=""

usage() {
  cat <<EOF >&2
Usage: update_dataflow_image.sh [options] <new-image>

Positional:
  <new-image>                 Fully-qualified image reference for the
                              dataflow operator (required).
                              Format: <registry>/<repository>:<tag>

Options:
  -i, --image <ref>           Same as positional <new-image>.
  -n, --namespace <ns>        Kubernetes namespace (default: azure-iot-operations).
  -s, --statefulset <name>    StatefulSet name (default: aio-dataflow-operator).
  -t, --timeout <secs>        Rollout wait timeout (default: 300).
  -h, --help                  Show this help.

Environment (lower precedence than flags):
  NAMESPACE, STATEFULSET, TIMEOUT_SECONDS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)       NEW_IMAGE="$2"; shift 2 ;;
    -n|--namespace)   NAMESPACE="$2"; shift 2 ;;
    -s|--statefulset) STATEFULSET="$2"; shift 2 ;;
    -t|--timeout)     TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               err "Unknown option: $1"; usage; exit 2 ;;
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

# -------- Parse image into registry / repository / tag --------
# Expected format: <registry>/<repo-path>:<tag>
# e.g. aioconnectorsdev.azurecr.io/aio-dataflows/dataflow-operator:1.4.6-pr42
#      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^
#      registry                       repository                          tag

if [[ "$NEW_IMAGE" != *:* ]]; then
  err "Image must include a tag (expected format: <registry>/<repository>:<tag>)."
  exit 1
fi

NEW_TAG="${NEW_IMAGE##*:}"
IMAGE_NO_TAG="${NEW_IMAGE%:*}"

if [[ "$IMAGE_NO_TAG" != */* ]]; then
  err "Image must include a registry and repository path (expected format: <registry>/<repository>:<tag>)."
  exit 1
fi

NEW_REGISTRY="${IMAGE_NO_TAG%%/*}"
NEW_REPOSITORY="${IMAGE_NO_TAG#*/}"

if [[ -z "$NEW_REGISTRY" || -z "$NEW_REPOSITORY" || -z "$NEW_TAG" ]]; then
  err "Failed to parse image '$NEW_IMAGE'."
  err "Expected format: <registry>/<repository>:<tag>"
  exit 1
fi

log "Parsed image components:"
log "  Registry:   $NEW_REGISTRY"
log "  Repository: $NEW_REPOSITORY"
log "  Tag:        $NEW_TAG"

# -------- Verify StatefulSet exists --------
log "Checking for StatefulSet '$STATEFULSET' in namespace '$NAMESPACE'…"
if ! kubectl get statefulset "$STATEFULSET" -n "$NAMESPACE" >/dev/null 2>&1; then
  err "StatefulSet '$STATEFULSET' not found in namespace '$NAMESPACE'."
  err "Available statefulsets:"
  kubectl get statefulsets -n "$NAMESPACE" --no-headers 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi
ok "StatefulSet '$STATEFULSET' exists."

# -------- Read current values --------
CURRENT_JSON="$(kubectl get statefulset "$STATEFULSET" -n "$NAMESPACE" -o json)"

get_env_value() {
  local name="$1"
  jq -r --arg env "$name" '
    .spec.template.spec.containers[0].env[]
    | select(.name == $env) | .value // empty
  ' <<<"$CURRENT_JSON"
}

OLD_REGISTRY="$(get_env_value DEFAULT_CONTAINER_REGISTRY)"
OLD_REPOSITORY="$(get_env_value DEFAULT_REPOSITORY)"
OLD_TAG="$(get_env_value DEFAULT_CONTAINER_TAG)"
OLD_PULL_POLICY="$(get_env_value DEFAULT_IMAGE_PULL_POLICY)"

log "Current values:"
log "  DEFAULT_CONTAINER_REGISTRY : ${OLD_REGISTRY:-<not set>}"
log "  DEFAULT_REPOSITORY         : ${OLD_REPOSITORY:-<not set>}"
log "  DEFAULT_CONTAINER_TAG      : ${OLD_TAG:-<not set>}"
log "  DEFAULT_IMAGE_PULL_POLICY  : ${OLD_PULL_POLICY:-<not set>}"
log ""
log "New values:"
log "  DEFAULT_CONTAINER_REGISTRY : $NEW_REGISTRY"
log "  DEFAULT_REPOSITORY         : $NEW_REPOSITORY"
log "  DEFAULT_CONTAINER_TAG      : $NEW_TAG"
log "  DEFAULT_IMAGE_PULL_POLICY  : Always"

# -------- Build JSON patch --------
# Find the index of each env var in the container's env array.
get_env_index() {
  local name="$1"
  jq -r --arg env "$name" '
    .spec.template.spec.containers[0].env
    | to_entries[]
    | select(.value.name == $env)
    | .key
  ' <<<"$CURRENT_JSON"
}

IDX_REGISTRY="$(get_env_index DEFAULT_CONTAINER_REGISTRY)"
IDX_REPOSITORY="$(get_env_index DEFAULT_REPOSITORY)"
IDX_TAG="$(get_env_index DEFAULT_CONTAINER_TAG)"
IDX_PULL_POLICY="$(get_env_index DEFAULT_IMAGE_PULL_POLICY)"

for var_name in DEFAULT_CONTAINER_REGISTRY DEFAULT_REPOSITORY DEFAULT_CONTAINER_TAG DEFAULT_IMAGE_PULL_POLICY; do
  idx_var="IDX_${var_name#DEFAULT_}"
  # Normalize: DEFAULT_CONTAINER_REGISTRY -> IDX_REGISTRY, etc.
  case "$var_name" in
    DEFAULT_CONTAINER_REGISTRY) idx="$IDX_REGISTRY" ;;
    DEFAULT_REPOSITORY)         idx="$IDX_REPOSITORY" ;;
    DEFAULT_CONTAINER_TAG)      idx="$IDX_TAG" ;;
    DEFAULT_IMAGE_PULL_POLICY)  idx="$IDX_PULL_POLICY" ;;
  esac
  if [[ -z "$idx" ]]; then
    err "Could not find env var '$var_name' in StatefulSet '$STATEFULSET'."
    exit 1
  fi
done

PATCH="$(jq -c -n \
  --arg idx_reg "$IDX_REGISTRY" \
  --arg idx_repo "$IDX_REPOSITORY" \
  --arg idx_tag "$IDX_TAG" \
  --arg idx_pp "$IDX_PULL_POLICY" \
  --arg reg "$NEW_REGISTRY" \
  --arg repo "$NEW_REPOSITORY" \
  --arg tag "$NEW_TAG" \
  '[
    {op:"replace", path:("/spec/template/spec/containers/0/env/"+$idx_reg+"/value"), value:$reg},
    {op:"replace", path:("/spec/template/spec/containers/0/env/"+$idx_repo+"/value"), value:$repo},
    {op:"replace", path:("/spec/template/spec/containers/0/env/"+$idx_tag+"/value"), value:$tag},
    {op:"replace", path:("/spec/template/spec/containers/0/env/"+$idx_pp+"/value"), value:"Always"}
  ]'
)"

log "Patching StatefulSet '$STATEFULSET'…"

kubectl patch statefulset "$STATEFULSET" -n "$NAMESPACE" --type=json -p "$PATCH"

ok "StatefulSet patched successfully."

# -------- Wait for rollout --------
log "Waiting for rollout to complete (timeout: ${TIMEOUT_SECONDS}s)…"
if kubectl rollout status statefulset/"$STATEFULSET" -n "$NAMESPACE" \
    --timeout="${TIMEOUT_SECONDS}s"; then
  ok "Rollout complete."
else
  warn "Rollout did not complete within ${TIMEOUT_SECONDS}s."
  warn "Check status with: kubectl rollout status statefulset/$STATEFULSET -n $NAMESPACE"
  exit 1
fi

ok "Dataflow operator image updated:"
ok "  ${OLD_REGISTRY:-?}/${OLD_REPOSITORY:-?}:${OLD_TAG:-?} → ${NEW_REGISTRY}/${NEW_REPOSITORY}:${NEW_TAG}"
ok "  Pull policy: ${OLD_PULL_POLICY:-?} → Always"
