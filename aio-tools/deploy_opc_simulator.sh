#!/usr/bin/env bash
#
# deploy_opc_simulator.sh — install the OPC-Simulator helm chart into
# the cluster. One instance per release, idempotent: if the release
# already exists it is reported and left alone.
#
# Usage:
#   ./deploy_opc_simulator.sh \
#       [--image <registry>/<name>:<tag>] \
#       [--release <name>] \
#       [--namespace <ns>] \
#       [--chart <path>] \
#       [--values <file>] \
#       [--config <simulator.toml>]
#
# Required:
#   SUBSCRIPTION_ID, RESOURCE_GROUP — for az login + AKS context wiring.
#
# Optional:
#   --image / IMAGE              Fully-qualified image reference. Defaults
#                                  to DEFAULT_IMAGE below
#                                  (vipeller.azurecr.io/opc-simulator:0.1.0).
#                                  Override with the output of
#                                  deploy/scripts/build-and-push.sh when
#                                  testing your own build.
#   --release / RELEASE          Helm release name (default: "opc-simulator").
#                                  Note: the chart's fullname becomes
#                                  `<release>-opc-simulator` unless the
#                                  release name already contains
#                                  "opc-simulator". Pick accordingly.
#   --namespace / NAMESPACE      K8s namespace (default: azure-iot-operations).
#   --chart / CHART_PATH         Path to the helm chart. Resolution order:
#                                  1. --chart / CHART_PATH explicit.
#                                  2. <script-dir>/charts/<vendored .tgz>
#                                     (the bootstrap.sh default).
#                                  3. <repo>/deploy/helm/opc-simulator
#                                     (only when this folder is run
#                                     from inside the OPC-Simulator repo).
#                                  Either a chart directory or a packaged
#                                  .tgz is accepted.
#   --values / VALUES_FILE       Optional helm values file passed via -f.
#   --config / SIMULATOR_CONFIG  Path to a simulator.toml passed via
#                                  --set-file simulatorConfig=...
#                                  Defaults to the vendored
#                                  resources/opc-simulator/simulator.toml
#                                  (next to this script) when present.
#   --timeout / TIMEOUT_SECONDS  Helm wait budget (default: 300).
#
# After successful install, the resulting cluster service can be
# discovered with `./show_simulators.sh` and registered with
# `./register_device.sh --service <fullname>`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

RELEASE="${RELEASE:-opc-simulator}"
NAMESPACE="${NAMESPACE:-azure-iot-operations}"
# Default image points at the pre-built artifact in the shared ACR;
# override via --image / IMAGE when iterating on a local build.
DEFAULT_IMAGE="vipeller.azurecr.io/opc-simulator:0.1.0"
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"
# Default chart: vendored .tgz next to this script (shipped by
# bootstrap.sh). Override with --chart / CHART_PATH /
# OPC_SIMULATOR_CHART_PATH to point at a chart directory or a
# different .tgz — useful when iterating on the chart locally.
DEFAULT_CHART_FILE="opc-simulator-0.1.0.tgz"
DEFAULT_CHART_LOCAL="${SCRIPT_DIR}/charts/${DEFAULT_CHART_FILE}"
CHART_PATH="${CHART_PATH:-${OPC_SIMULATOR_CHART_PATH:-}}"
VALUES_FILE="${VALUES_FILE:-}"
# Default simulator config: vendored TOML next to this script. Used
# when --config / SIMULATOR_CONFIG is unset and the file is present
# (it ships via bootstrap.sh and lives in the repo at
#   aio-tools/resources/opc-simulator/simulator.toml).
DEFAULT_SIMULATOR_CONFIG="${SCRIPT_DIR}/resources/opc-simulator/simulator.toml"
SIMULATOR_CONFIG="${SIMULATOR_CONFIG:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"

usage() {
  cat <<EOF >&2
Usage: deploy_opc_simulator.sh [options]

Options:
  -i, --image <ref>           Fully-qualified image reference
                              (default: ${DEFAULT_IMAGE}).
  -r, --release <name>        Helm release name (default: opc-simulator).
  -n, --namespace <ns>        Kubernetes namespace (default: azure-iot-operations).
  -c, --chart <path>          Helm chart directory (defaults to the
                              OPC-Simulator repo's deploy/helm/opc-simulator).
  -f, --values <file>         Extra helm values file (-f).
      --config <file>         Path to a simulator.toml passed via --set-file.
                              Defaults to the vendored
                              resources/opc-simulator/simulator.toml when
                              present; otherwise the chart's built-in default.
  -t, --timeout <secs>        Helm wait timeout (default: 300).
  -h, --help                  Show this help.

Environment (lower precedence than flags):
  SUBSCRIPTION_ID, RESOURCE_GROUP   (required)
  IMAGE, RELEASE, NAMESPACE, CHART_PATH, VALUES_FILE, SIMULATOR_CONFIG,
  TIMEOUT_SECONDS, OPC_SIMULATOR_CHART_PATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--image)     IMAGE="$2"; shift 2 ;;
    -r|--release)   RELEASE="$2"; shift 2 ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -c|--chart)     CHART_PATH="$2"; shift 2 ;;
    -f|--values)    VALUES_FILE="$2"; shift 2 ;;
       --config)    SIMULATOR_CONFIG="$2"; shift 2 ;;
    -t|--timeout)   TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID (run discover_env.sh first)}"
: "${RESOURCE_GROUP:?set RESOURCE_GROUP (run discover_env.sh first)}"

require_cmd az jq kubectl helm

# -------- Resolve chart path --------
# Resolution order:
#   1. The explicit --chart / CHART_PATH / OPC_SIMULATOR_CHART_PATH
#      the caller gave us. Either a chart directory or a .tgz works.
#   2. The vendored .tgz that bootstrap.sh drops next to this script
#      (charts/opc-simulator-<version>.tgz). The default for users
#      who installed via the one-liner.
#   3. A sibling-up walk to <script>/../../deploy/helm/opc-simulator
#      — only useful when these tools are run from inside the
#      OPC-Simulator repo and you want to test chart edits without
#      repackaging.
#   4. Bail with a helpful error.
if [[ -z "$CHART_PATH" && -f "$DEFAULT_CHART_LOCAL" ]]; then
  CHART_PATH="$DEFAULT_CHART_LOCAL"
fi

if [[ -z "$CHART_PATH" ]]; then
  CANDIDATE="$(cd -- "${SCRIPT_DIR}/../../deploy/helm/opc-simulator" 2>/dev/null && pwd || true)"
  if [[ -n "$CANDIDATE" && -f "$CANDIDATE/Chart.yaml" ]]; then
    CHART_PATH="$CANDIDATE"
  fi
fi

# Accept either a directory (must contain Chart.yaml) or a .tgz file.
if [[ -z "$CHART_PATH" ]] \
   || { [[ -d "$CHART_PATH" && ! -f "$CHART_PATH/Chart.yaml" ]]; } \
   || { [[ ! -d "$CHART_PATH" && ! -f "$CHART_PATH" ]]; }; then
  err "Could not locate the opc-simulator helm chart."
  err "Pass --chart <path-to-chart-dir-or-tgz> or set OPC_SIMULATOR_CHART_PATH."
  err "Expected default: ${DEFAULT_CHART_LOCAL}"
  exit 1
fi
log "Using chart: $CHART_PATH"

azlogin "$SUBSCRIPTION_ID"
connect_kube "$RESOURCE_GROUP"

# -------- Idempotency --------
# `helm status` returns 0 only if the release exists in this NS.
if helm status -n "$NAMESPACE" "$RELEASE" >/dev/null 2>&1; then
  ok "Helm release '$RELEASE' already exists in namespace '$NAMESPACE' — nothing to do."
  log "  Use ./show_simulators.sh -n $NAMESPACE to see its service name."
  exit 0
fi

# -------- Resolve simulator config --------
# Resolution order:
#   1. --config / SIMULATOR_CONFIG (caller's explicit choice).
#   2. <script-dir>/resources/opc-simulator/simulator.toml (vendored).
#   3. None — the chart's built-in default `simulatorConfig` is used.
if [[ -z "$SIMULATOR_CONFIG" && -f "$DEFAULT_SIMULATOR_CONFIG" ]]; then
  SIMULATOR_CONFIG="$DEFAULT_SIMULATOR_CONFIG"
  log "Using vendored simulator config: $SIMULATOR_CONFIG"
fi

# -------- Install --------
HELM_ARGS=(
  upgrade -i "$RELEASE" "$CHART_PATH"
  --namespace "$NAMESPACE" --create-namespace
  --set "image=${IMAGE}"
  --wait --timeout "${TIMEOUT_SECONDS}s"
)
[[ -n "$VALUES_FILE" ]] && HELM_ARGS+=(-f "$VALUES_FILE")
if [[ -n "$SIMULATOR_CONFIG" ]]; then
  [[ -f "$SIMULATOR_CONFIG" ]] || { err "Config file not found: $SIMULATOR_CONFIG"; exit 1; }
  HELM_ARGS+=(--set-file "simulatorConfig=$SIMULATOR_CONFIG")
fi

log "Installing helm release '$RELEASE' into namespace '$NAMESPACE'…"
log "  image       : $IMAGE"
log "  values file : ${VALUES_FILE:-<none>}"
log "  config file : ${SIMULATOR_CONFIG:-<chart default>}"
helm "${HELM_ARGS[@]}"
ok "Helm release applied"

# -------- Wait for readiness --------
LABEL="app.kubernetes.io/instance=${RELEASE}"
log "Waiting for resources with label '$LABEL' in namespace '$NAMESPACE' to become Ready…"
DEPS="$(kubectl -n "$NAMESPACE" get deploy -l "$LABEL" -o name 2>/dev/null || true)"
if [[ -n "$DEPS" ]]; then
  while read -r d; do
    [[ -z "$d" ]] && continue
    log "  -> rollout $d"
    kubectl -n "$NAMESPACE" rollout status "$d" --timeout="${TIMEOUT_SECONDS}s"
  done <<< "$DEPS"
  ok "All deployments for $RELEASE are ready"
fi

# -------- Compute the resulting service name --------
# Mirrors the chart's _helpers.tpl `opc-simulator.fullname` logic so
# the user knows what to feed register_device.sh next.
if [[ "$RELEASE" == *opc-simulator* ]]; then
  SVC="$RELEASE"
else
  SVC="${RELEASE}-opc-simulator"
fi

ok "opc-simulator '$RELEASE' is up."
log "Cluster service: ${SVC}.${NAMESPACE}.svc.cluster.local:4840"
log "Next step: ./register_device.sh --service ${SVC}"
