#!/usr/bin/env bash
#
# deploy_pump.sh — install one OPC Foundation PumpDeviceIntegrationServer
# per Helm release. Existing releases are reported and left alone.
# Upstream provides a container and Kubernetes manifest, not a pump chart;
# the chart in charts/ is maintained here. See charts/README.md for provenance.
#
# Required: SUBSCRIPTION_ID, RESOURCE_GROUP (from discover_env.sh).
# Optional flags/env: IMAGE, RELEASE, NAMESPACE, CHART_PATH, VALUES_FILE,
# PUMP_COUNT, TIMEOUT_SECONDS. Flags take precedence over environment.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

DEFAULT_IMAGE="ghcr.io/opcfoundation/uanetstandard/pumpserver:latest-master"
DEFAULT_CHART_FILE="pump-device-integration-server-0.1.1.tgz"
DEFAULT_CHART_LOCAL="${SCRIPT_DIR}/charts/${DEFAULT_CHART_FILE}"
DEFAULT_CHART_DIR="${SCRIPT_DIR}/charts/pump-device-integration-server"
RELEASE="${RELEASE:-pump}"
NAMESPACE="${NAMESPACE:-azure-iot-operations}"
IMAGE="${IMAGE:-}"
CHART_PATH="${CHART_PATH:-}"
VALUES_FILE="${VALUES_FILE:-}"
PUMP_COUNT="${PUMP_COUNT:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"

usage() {
  cat <<EOF >&2
Usage: deploy_pump.sh [options]

Options:
  -i, --image <ref>       Full image reference (chart default: ${DEFAULT_IMAGE}).
  -r, --release <name>    Helm release name (default: pump).
  -n, --namespace <ns>    Kubernetes namespace (default: azure-iot-operations).
  -c, --chart <path>      Chart directory or .tgz (default: vendored chart).
  -f, --values <file>     Extra Helm values file (-f).
      --pumps <count>     Pump instances per server, 1..100 (chart default: 2).
  -t, --timeout <secs>    Helm wait timeout (default: 300).
  -h, --help              Show this help.

Environment (lower precedence than flags):
  SUBSCRIPTION_ID, RESOURCE_GROUP (required)
  IMAGE, RELEASE, NAMESPACE, CHART_PATH, VALUES_FILE, PUMP_COUNT, TIMEOUT_SECONDS

The upstream default image follows master. Pin --image <tag-or-digest> for
repeatable deployments. Values-file image/pumps are used unless overridden
by the corresponding flag or environment variable.

The default chart mounts the AIO OPC UA CA certificate and CRL from
Secrets aio-opc-ua-gds-ca-cert and aio-opc-ua-gds-ca-crl in this namespace.
Override connectorTrust in --values if your Secret names differ.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image|-r|--release|-n|--namespace|-c|--chart|-f|--values|--pumps|-t|--timeout)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || {
        err "Missing value for $1"; usage; exit 2;
      }
      case "$1" in
        -i|--image)     IMAGE="$2" ;;
        -r|--release)   RELEASE="$2" ;;
        -n|--namespace) NAMESPACE="$2" ;;
        -c|--chart)     CHART_PATH="$2" ;;
        -f|--values)    VALUES_FILE="$2" ;;
           --pumps)    PUMP_COUNT="$2" ;;
        -t|--timeout)   TIMEOUT_SECONDS="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ -n "$PUMP_COUNT" ]] && ! [[ "$PUMP_COUNT" =~ ^([1-9]|[1-9][0-9]|100)$ ]]; then
  err "--pumps / PUMP_COUNT must be an integer between 1 and 100"; exit 2
fi
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  err "--timeout / TIMEOUT_SECONDS must be a positive integer"; exit 2;
}

: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID (run discover_env.sh first)}"
: "${RESOURCE_GROUP:?set RESOURCE_GROUP (run discover_env.sh first)}"
require_cmd az jq kubectl helm

azlogin "$SUBSCRIPTION_ID"
connect_kube "$RESOURCE_GROUP"

# Read the actual service rather than guessing the chart fullname. This
# honours fullnameOverride/nameOverride and service.port in a values file.
show_endpoint() {
  local svc_json rows svc port
  svc_json="$(kubectl -n "$NAMESPACE" get svc \
    -l "app.kubernetes.io/instance=${RELEASE}" -o json)"
  rows="$(jq -r '.items[] | . as $svc | .spec.ports[]
    | select(.name == "opc-tcp") | [$svc.metadata.name, .port] | @tsv' <<<"$svc_json")"
  if [[ -z "$rows" ]]; then
    warn "No Service with an opc-tcp port found for release '$RELEASE'."
    warn "Use ./show_simulators.sh --namespace $NAMESPACE to inspect endpoints."
    return 0
  fi
  while IFS=$'\t' read -r svc port; do
    [[ -n "$svc" ]] || continue
    log "Cluster endpoint: opc.tcp://${svc}.${NAMESPACE}.svc.cluster.local:${port}/PumpDeviceIntegrationServer"
    log "Next step: ./register_device.sh --service ${svc} --namespace ${NAMESPACE} --port ${port} --endpoint-path /PumpDeviceIntegrationServer --security-mode SignAndEncrypt --security-policy 'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256' --asset-type 'nsu=http://opcfoundation.org/UA/Pumps/;i=1052'"
  done <<< "$rows"
}

if helm status -n "$NAMESPACE" "$RELEASE" >/dev/null 2>&1; then
  ok "Helm release '$RELEASE' already exists in namespace '$NAMESPACE' — nothing to do."
  show_endpoint
  exit 0
fi

# Explicit local chart, then vendored package, then the tracked chart source.
if [[ -z "$CHART_PATH" ]]; then
  if [[ -f "$DEFAULT_CHART_LOCAL" ]]; then
    CHART_PATH="$DEFAULT_CHART_LOCAL"
  else
    CHART_PATH="$DEFAULT_CHART_DIR"
  fi
fi
if { [[ -d "$CHART_PATH" && ! -f "$CHART_PATH/Chart.yaml" ]]; } \
   || { [[ ! -d "$CHART_PATH" && ! -f "$CHART_PATH" ]]; }; then
  err "Pump Helm chart not found: $CHART_PATH"
  err "Pass --chart <chart-directory-or-tgz> or run bootstrap.sh."
  exit 1
fi
[[ -z "$VALUES_FILE" || -f "$VALUES_FILE" ]] || {
  err "Values file not found: $VALUES_FILE"; exit 1;
}

HELM_ARGS=(
  upgrade -i "$RELEASE" "$CHART_PATH"
  --namespace "$NAMESPACE" --create-namespace
  --wait --timeout "${TIMEOUT_SECONDS}s"
)
[[ -n "$VALUES_FILE" ]] && HELM_ARGS+=(-f "$VALUES_FILE")
[[ -n "$IMAGE" ]] && HELM_ARGS+=(--set-string "image=${IMAGE}")
[[ -n "$PUMP_COUNT" ]] && HELM_ARGS+=(--set "pumps=${PUMP_COUNT}")

log "Installing pump Helm release '$RELEASE' into namespace '$NAMESPACE'…"
log "Using chart: $CHART_PATH"
helm "${HELM_ARGS[@]}"
ok "Helm release applied"

LABEL="app.kubernetes.io/instance=${RELEASE}"
DEPS="$(kubectl -n "$NAMESPACE" get deploy -l "$LABEL" -o name)"
if [[ -n "$DEPS" ]]; then
  while read -r d; do
    [[ -z "$d" ]] && continue
    kubectl -n "$NAMESPACE" rollout status "$d" --timeout="${TIMEOUT_SECONDS}s"
  done <<< "$DEPS"
fi

ok "Pump simulator '$RELEASE' is up."
show_endpoint
